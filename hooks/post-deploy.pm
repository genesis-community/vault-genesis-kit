package Genesis::Hook::PostDeploy::Vault v2.0.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info run/;
use Service::Vault;
use JSON::PP;

# Include the shared seal-status and safe target helpers
BEGIN {
	require File::Basename;
	require File::Spec;
	my $mixin_file = File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/lib/_vault_cluster.pm';
	do $mixin_file or die "Failed to include hook mixin $mixin_file: " . ($@ || $! || 'unknown error');
}

# init - Initialize the hook {{{
sub init {
	my ($class, %ops) = @_;
	my $obj = $class->SUPER::init(%ops);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}
# }}}

# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $name = $self->env->name;

	my $cluster = $self->_vault_env_cluster($name);
	my @keys = _predeploy_keys();

	# A failed deploy can still have restarted some nodes, and a restarted node
	# comes back sealed.  Unseal those before reporting the failure, so the
	# cluster doesn't stay degraded until the next successful deploy.
	unless ($self->deploy_successful) {
		if (@{$cluster->{sealed}} && @keys) {
			info("");
			info("The deployment failed, but some Vault nodes are #Y{sealed} - unsealing them with the pre-deploy keys...");
			$self->_unseal_cluster($cluster, \@keys);
		}
		info("#R{Deployment failed} - skipping the remaining post-deploy actions");
		return $self->done(1);
	}

	info("");
	info("#M{$name} Vault deployed successfully!");
	info("");

	# One read of every node decides between initializing, unsealing, and
	# nothing.
	if (!@{$cluster->{reachable}}) {
		info("#Y{Unable to reach any Vault node} - cannot check whether the cluster is sealed");
		$self->_vault_report_nodes($cluster);
		$self->_show_manual_instructions;
	} elsif (!$cluster->{initialized}) {
		# A new deployment.  Initializing it also unseals it.
		$self->_auto_init($cluster);
	} elsif (@{$cluster->{sealed}} || @{$cluster->{unreachable}}) {
		info("Vault is currently #Y{sealed} on some nodes - unsealing is required to access secrets");
		$self->_vault_report_nodes($cluster);
		if (!@{$cluster->{sealed}}) {
			info("No reachable node is sealed; the nodes that did not answer may need to be unsealed once they are back.");
		} elsif (@keys) {
			info("Found unseal keys from pre-deploy, attempting automatic unseal...");
			$self->_unseal_cluster($cluster, \@keys);
		} else {
			info("No pre-deploy seal keys found - cannot unseal automatically");
			$self->_show_manual_instructions;
		}
	} else {
		info("Vault is currently #G{unsealed} on every node - no further action is needed");
	}

	# The steps below need a node that is initialized and unsealed
	my @urls = map {$_->{url}} @{$cluster->{nodes}};
	$cluster = $self->_vault_cluster(@urls) if @urls;
	if (@urls && @{$cluster->{serving}}) {
		# Setup doomsday approle if vault is initialized and unsealed
		$self->_setup_doomsday_approle();
	}

	info(
		"\nFor details about the deployment, run:\n".
		"  #G{genesis info $name}\n"
	);

	# Check if KV versioning needs to be enabled
	$self->_check_kv_versioning() if @urls && @{$cluster->{serving}};

	return $self->done(1);
}
# }}}

# _predeploy_keys - the unseal keys pre-deploy saved, in order {{{
sub _predeploy_keys {
	my $file = $ENV{GENESIS_PREDEPLOY_DATAFILE};
	return () unless defined($file) && -s $file;
	open(my $fh, '<', $file) or return ();
	my @keys = grep {$_ ne ''} map {s/^\s+|\s+$//gr} <$fh>;
	close($fh);
	return @keys;
}
# }}}

# _unseal_cluster - unseal every sealed node through strongbox {{{
# safe reads the keys on stdin, so they never reach argv or the trace log.
# Returns true when no node is left sealed.
sub _unseal_cluster {
	my ($self, $cluster, $keys) = @_;
	my $name = $self->env->name;

	my $target = $self->_ensure_strongbox_target($name, @{$cluster->{reachable}});
	unless ($target) {
		info(
			"  #R{\@{x} Failed to unseal vault automatically}\n\n".
			"You can try to unseal manually with:\n".
			"  #G{genesis $name do unseal}"
		);
		return 0;
	}

	my ($out, $rc) = run(
		{stdin => join("\n", @$keys)."\n", env => _safe_env()},
		'safe', '-T', $name, 'unseal'
	);
	my @urls = map {$_->{url}} @{$cluster->{nodes}};
	my $after = $self->_vault_wait_until_unsealed(@urls);

	if (@{$after->{sealed}} || @{$after->{unreachable}}) {
		($out //= '') =~ s/\s+$//;
		info("  #R{\@{x} Failed to unseal every Vault node automatically}%s", $rc ? " (safe exited $rc)" : '');
		$self->_vault_report_nodes($after);
		info(
			"\nYou can try to unseal manually with:\n".
			"  #G{genesis $name do unseal}"
		);
		return 0;
	}
	info("  #g{#\@{+} Vault unsealed successfully on every node!}");
	return 1;
}
# }}}

sub _show_manual_instructions {
	info(
		"\nUnable to automatically unseal the vault.".
		"\nIf this is a #Y{new deployment}, you need to initialize it first:\n".
		"  #G{genesis $ENV{GENESIS_ENVIRONMENT} do init}".
		"\nIf this is an #Y{existing deployment}, you need to unseal it manually:\n".
		"  #G{genesis $ENV{GENESIS_ENVIRONMENT} do unseal}\n"
	)
}

sub _check_kv_versioning {
	my ($self) = @_;
	my $name = $self->env->name;

	# Only check if we can authenticate
	my ($auth_check, $auth_rc) = run({ stderr => 0, env => _safe_env() },
		'safe', '-T', $name, 'auth', 'status'
	);

	return unless $auth_rc == 0;

	my ($out, $rc) = run({ stderr => 0, env => _safe_env() },
		'safe', '-T', $name, 'vault', 'secrets', 'list', '--detailed'
	);

	if ($rc == 0 && $out =~ /^secret\/.*map\[version:1\]/m) {
		info(
			"---\n\n".
			"#Y{KV Version 2 Available}\n\n".
			"This Vault supports versioned secrets, but the 'secret/' mount\n".
			"is still using version 1. To enable versioning, run:\n\n".
			"[[  >>#G{safe vault kv enable-versioning secret}\n\n".
			"You'll need to be authenticated with the root token.\n\n".
			"[[#Y{NOTE:} >>Once versioning is enabled, it cannot be disabled".
			"without recreating the secrets backend.\n"
		);
	}
}

# _setup_doomsday_approle - give doomsday read-only credentials in exodus {{{
# The credentials are written to this environment's exodus data in the
# deploying vault, where `genesis lookup --exodus` and the doomsday kit read
# them.  Genesis rewrites that exodus data on every deploy, so a fresh
# secret_id is minted each time, and every earlier secret_id of the role is
# destroyed first, so at most one is ever valid.
sub _setup_doomsday_approle {
	my ($self) = @_;
	my $name = $self->env->name;
	my $vault = _vault_target_query($name);

	# Check if we can authenticate (need to be authenticated to create approles)
	my ($auth_check, $auth_rc) = $vault->({ stderr => 0 }, 'auth', 'status');

	unless ($auth_rc == 0) {
		info("Skipping doomsday approle setup - not authenticated with vault");
		return;
	}

	my $provider = eval {$self->env->vault};
	unless ($provider) {
		my $err = ($@ || 'no deploying vault is configured for this environment') =~ s/\s+/ /gr;
		info("Skipping doomsday approle setup - could not resolve the deploying vault to store its credentials in: $err");
		return;
	}
	my $exodus_base = $ENV{GENESIS_EXODUS_BASE} // $self->env->exodus_base;
	(my $exodus_path = $exodus_base) =~ s{/+$}{};

	info("");
	info("Setting up doomsday monitoring approle...");

	# Enable approle auth if not already enabled
	my ($enable_out, $enable_rc) = $vault->({ stderr => 1 },
		'vault', 'auth', 'enable', 'approle'
	);
	$enable_out //= '';

	if ($enable_out =~ /Success\! Enabled approle auth method/ || $enable_out =~ /path is already in use/) {
		info("#G{[ok]} AppRole auth enabled");
	} else {
		info("#Y{WARNING:} Could not enable approle auth: $enable_out");
		return;
	}

	# Check if doomsday approle already exists with credentials in exodus
	my ($list_out, $list_rc) = $vault->({ stderr => 0 },
		'vault', 'list', '-format=json', 'auth/approle/role'
	);
	my $roles = $list_rc == 0 && $list_out ? eval {JSON::PP::decode_json($list_out)} : undef;
	if (ref($roles) eq 'ARRAY' && grep {$_ eq 'doomsday'} @$roles) {
		if ($provider->has($exodus_path, 'doomsday_approle_id')
			&& $provider->has($exodus_path, 'doomsday_approle_secret')) {
			info("#G{[ok]} Doomsday approle already exists with credentials in exodus");
			return;
		}
	}

	# Create doomsday read-only policy
	info("Creating doomsday read-only policy...");

	my $policy = <<'EOF';
# Read-only access for doomsday monitoring
path "sys/health" {
	capabilities = ["read"]
}

path "sys/seal-status" {
	capabilities = ["read"]
}

path "sys/host-info" {
	capabilities = ["read"]
}

path "sys/mounts" {
	capabilities = ["read", "list"]
}

path "sys/auth" {
	capabilities = ["read", "list"]
}

# Allow listing all paths to discover what's available
path "*" {
	capabilities = ["list"]
}

# Read-only access to all secrets
path "secret/*" {
	capabilities = ["read", "list"]
}

path "secret/data/*" {
	capabilities = ["read", "list"]
}

path "secret/metadata/*" {
	capabilities = ["read", "list"]
}
EOF

	my (undef, $policy_rc) = $vault->({ stdin => $policy, stderr => 1 },
		'vault', 'policy', 'write', 'doomsday', '-'
	);

	unless ($policy_rc == 0) {
		info("#R{ERROR:} Failed to create doomsday policy");
		return;
	}
	info("#G{[ok]} Doomsday policy created");

	# Create doomsday approle.  safe set would read the role back and rewrite
	# every field, and Vault 2 refuses the empty alias_metadata it returns.
	info("Creating doomsday approle...");

	my ($create_out, $create_rc) = $vault->({ stderr => 1 },
		'vault', 'write',
		'auth/approle/role/doomsday',
		'secret_id_ttl=0',
		'token_num_uses=0',
		'token_ttl=1h',
		'token_max_ttl=24h',
		'secret_id_num_uses=0',
		'policies=doomsday'
	);

	unless ($create_rc == 0) {
		info("#R{ERROR:} Failed to create doomsday approle: %s", ($create_out // '') =~ s/\s+/ /gr);
		return;
	}

	# Get role ID
	my ($role_id, $role_rc) = $vault->({ stderr => 0, redact_output => 1 },
		'get', 'auth/approle/role/doomsday/role-id:role_id'
	);
	$role_id = defined($role_id) ? $role_id =~ s/^\s+|\s+$//gr : '';

	unless ($role_rc == 0 && $role_id ne '') {
		info("#R{ERROR:} Failed to get doomsday role ID");
		return;
	}

	# The secret_ids never expire, so destroy every earlier one before
	# minting the next.  The accessors can't authenticate, so they may appear
	# on argv.
	my @accessors = _doomsday_secret_id_accessors($vault);
	unless (defined($accessors[0])) {
		info("#R{ERROR:} Failed to list the doomsday approle's secret IDs: %s", $accessors[1]);
		return;
	}
	shift @accessors;
	for my $accessor (@accessors) {
		unless (_destroy_doomsday_secret_id($vault, $accessor)) {
			info("#R{ERROR:} Failed to destroy an earlier doomsday secret ID (accessor %s), so no new one was minted", $accessor);
			return;
		}
	}
	info("#G{[ok]} Destroyed %d earlier doomsday secret ID(s)", scalar(@accessors)) if @accessors;

	# Generate secret ID
	my ($secret_out, $secret_rc) = $vault->({ stderr => 0, redact_output => 1 },
		'vault', 'write', '-format=json', '-f', 'auth/approle/role/doomsday/secret-id'
	);
	my $minted = $secret_rc == 0 ? eval {JSON::PP::decode_json($secret_out)} : undef;
	my $secret_id = ref($minted) eq 'HASH' && ref($minted->{data}) eq 'HASH' ? $minted->{data}{secret_id} : undef;
	my $secret_accessor = ref($minted) eq 'HASH' && ref($minted->{data}) eq 'HASH' ? $minted->{data}{secret_id_accessor} : undef;

	unless (length($secret_id // '') && length($secret_accessor // '')) {
		info("#R{ERROR:} Failed to generate doomsday secret ID");
		return;
	}

	# Store in exodus, each secret through stdin
	info("Storing doomsday approle credentials in exodus...");

	my $provider_query = sub {$provider->query(@_)};
	my ($id_rc, $id_err) = _vault_set_secret($provider_query, $exodus_path, 'doomsday_approle_id', $role_id);
	my ($store_rc, $store_err) = $id_rc == 0
		? _vault_set_secret($provider_query, $exodus_path, 'doomsday_approle_secret', $secret_id,
			"doomsday_approle_secret_accessor=$secret_accessor")
		: ($id_rc, $id_err);

	if ($store_rc == 0) {
		info("#G{#\@{+} Doomsday approle created successfully!}");
		info("  Credentials stored in exodus at: #C{%s} in the deploying vault #M{%s}", $exodus_path, $provider->url // '');
		info("  - doomsday_approle_id");
		info("  - doomsday_approle_secret");
		info("  - doomsday_approle_secret_accessor");
	} else {
		$store_err =~ s/\s+/ /g;
		info("#R{ERROR:} Failed to store doomsday credentials in exodus: %s", $store_err || "safe exited $store_rc");
		# Nobody holds the new secret ID, so don't leave it valid
		if (_destroy_doomsday_secret_id($vault, $secret_accessor)) {
			info("  Destroyed the doomsday secret ID that could not be stored");
		} else {
			info("  #Y{WARNING:} Could not destroy the doomsday secret ID that could not be stored (accessor %s)", $secret_accessor);
		}
	}
}
# }}}

# _doomsday_secret_id_accessors - accessors of every doomsday secret_id {{{
# Returns (1, @accessors), or (undef, $error) when they can't be listed.
# Vault answers a list with nothing in it with "No value found".
sub _doomsday_secret_id_accessors {
	my ($vault) = @_;
	my ($out, $rc, $err) = $vault->({ stderr => 0 },
		'vault', 'list', '-format=json', 'auth/approle/role/doomsday/secret-id'
	);
	my $text = join(' ', grep {defined} $out, $err);
	return (1) if $rc != 0 && $text =~ /No value found/i;
	my $list = $rc == 0 ? eval {JSON::PP::decode_json($out)} : undef;
	return (1, grep {defined && !ref && /\S/} @$list) if ref($list) eq 'ARRAY';
	$text =~ s/\s+/ /g;
	return (undef, $text =~ /\S/ ? $text : "safe exited $rc");
}
# }}}

# _destroy_doomsday_secret_id - destroy one secret_id by its accessor {{{
sub _destroy_doomsday_secret_id {
	my ($vault, $accessor) = @_;
	my (undef, $rc) = $vault->({ stderr => 0 },
		'vault', 'write', 'auth/approle/role/doomsday/secret-id-accessor/destroy',
		"secret_id_accessor=$accessor"
	);
	return $rc == 0;
}
# }}}

# _auto_init - initialize a new Vault, unless that could strand older keys {{{
# A seal-key backup already in the deploying vault belongs to an earlier
# Vault under this environment's name.  When that Vault's data comes back,
# for instance from a Consul snapshot, those are the only keys that open it,
# so the cluster is left uninitialized for the operator to decide.
sub _auto_init {
	my ($self, $cluster) = @_;
	my $name = $self->env->name;

	info("");
	info("Detected #Y{uninitialized Vault}");

	if (@{$cluster->{unreachable}}) {
		info("Not every Vault node answered, so automatic initialization was skipped:");
		$self->_vault_report_nodes($cluster);
		info("Once every node is up, initialize the Vault with: #G{genesis $name do init}");
		return;
	}

	my $provider = eval {$self->env->vault};
	my $backup_path = $self->env->secrets_base . 'vault/seal/keys';
	my ($state, $state_err) = $provider
		? _vault_path_state($provider, $backup_path)
		: ('unknown', ($@ || 'no deploying vault is configured for this environment') =~ s/\s+/ /gr);

	if ($state eq 'present') {
		info(
			"#Y{Automatic initialization was skipped:} the deploying vault #M{%s} already holds a ".
			"seal-key backup at #C{%s}, from an earlier Vault deployed as #C{%s}.  A new init ".
			"would leave that backup describing a Vault that no longer exists.\n\n".
			"If you are restoring that Vault's data, restore it, then unseal with the backed-up ".
			"keys (read them with #G{safe get %s}):\n".
			"  #G{genesis %s do unseal}\n\n".
			"If this really is a new Vault, move the old backup aside, then initialize:\n".
			"  #G{safe mv %s %s-retired-%s}\n".
			"  #G{genesis %s do init}\n",
			$provider->url // '', $backup_path, $name,
			$backup_path,
			$name,
			$backup_path, $backup_path, _today(),
			$name
		);
		return;
	}
	if ($state ne 'absent') {
		info(
			"#Y{Automatic initialization was skipped:} could not tell whether the deploying vault ".
			"holds a seal-key backup at #C{%s} (%s), and initializing could strand older keys.\n".
			"Check that path, then initialize with: #G{genesis %s do init}",
			$backup_path, $state_err, $name
		);
		return;
	}

	info("Running automatic initialization...");

	# Run the init addon.  Its module lives at a kit path that isn't on @INC,
	# so load it from the file the way Genesis loads addon hooks.  Quiet mode
	# keeps the seal keys and root token out of the deploy output.
	my $init_file = $self->kit->path('hooks/addon-init~i.pm');
	require $init_file unless Genesis::Hook::Addon::Vault::Init->can('perform');
	my $init_hook = Genesis::Hook::Addon::Vault::Init->init(
		env    => $self->env,
		kit    => $self->kit,
		script => 'init',
		args   => [],
		file   => $init_file,
		label  => 'init',
		quiet  => 1,
	);

	my $init_rc = $init_hook->perform();

	unless ($init_rc) {
		info("#R{ERROR:} Automatic initialization failed");
		info("You can initialize manually with: #G{genesis $name do init}");
		return;
	}
	info("#G{#\@{+} Vault initialized successfully!}");

	# Init unseals the nodes strongbox knew about.  Unseal any it missed with
	# the keys init stored in the new Vault.
	my @urls = map {$_->{url}} @{$cluster->{nodes}};
	my $after = $self->_vault_wait_until_unsealed(@urls);
	return unless @{$after->{sealed}};

	info("");
	info("Attempting to unseal the remaining nodes of the newly initialized vault...");
	my @keys = _vault_read_seal_keys(_vault_target_query($name));
	if (@keys) {
		$self->_unseal_cluster($after, \@keys);
	} else {
		info("#Y{WARNING:} Could not read the seal keys back from the new Vault");
		$self->_vault_report_nodes($after);
		info("You can unseal manually with: #G{genesis $name do unseal}");
	}
}
# }}}

sub _today {
	my @t = localtime();
	return sprintf('%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
