package Genesis::Hook::PostDeploy::Vault v2.0.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info run slurp lines read_json_from/;
use Service::Vault;
use JSON::PP;

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

	# Only proceed if deployment was successful
	unless ($ENV{GENESIS_DEPLOY_RC} == 0) {
		info("#R{Deployment failed} - skipping post-deploy actions");
		return $self->done(1);
	}

	info("");
	info("#M{$ENV{GENESIS_ENVIRONMENT}} Vault deployed successfully!");
	info("");

	# One status read decides between initializing, unsealing, and nothing.
	my $status = $self->_vault_status;
	if (!$status) {
		info("#Y{Unable to reach the Vault} - cannot check whether it is sealed");
		$self->_show_manual_instructions;
	} elsif (!$status->{initialized}) {
		# A new deployment.  Initializing it also unseals it.
		$self->_auto_init;
	} elsif ($status->{sealed} || !$self->_all_unsealed) {
		info("Vault is currently #Y{sealed} - unsealing is required to access secrets");
		if (-s $ENV{GENESIS_PREDEPLOY_DATAFILE}) {
			info("Found unseal keys from pre-deploy, attempting automatic unseal...");
			my $ok = run({interactive => 1, passfail => 1},
				"safe -T $ENV{GENESIS_ENVIRONMENT} unseal < $ENV{GENESIS_PREDEPLOY_DATAFILE}"
			);
			if (!$ok) {
				info(
					"  #R{\@{x} Failed to unseal vault automatically}\n\n".
					"You can try to unseal manually with:\n".
					"  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}");
			} else {
				info("  #g{#\@{+} Vault unsealed successfully!}");
			}
		} else {
			info("No pre-deploy seal keys found - cannot unseal automatically");
			$self->_show_manual_instructions;
		}
	} else {
		info("Vault is currently #G{unsealed} - no further action is needed");
	}

	# Setup doomsday approle if vault is initialized and unsealed
	$self->_setup_doomsday_approle();

	info(
		"\nFor details about the deployment, run:\n".
		"  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}\n"
	);

	# Check if KV versioning needs to be enabled
	$self->_check_kv_versioning();

	return $self->done(1);
}

sub _show_manual_instructions {
	info(
		"\nUnable to automatically unseal the vault.".
		"\nIf this is a #Y{new deployment}, you need to initialize it first:\n".
		"  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- init}".
		"\nIf this is an #Y{existing deployment}, you need to unseal it manually:\n".
		"  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}\n"
	)
}

sub _check_kv_versioning {
	my ($self) = @_;

	# Only check if we can authenticate
	my ($auth_check, $auth_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'auth', 'status'
	);

	return unless $auth_rc == 0;

	my ($out, $rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'secrets', 'list', '--detailed'
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

sub _setup_doomsday_approle {
	my ($self) = @_;

	# Check if vault is initialized and unsealed
	my ($status_out, $status_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'status'
	);

	# Parse status to check if initialized and unsealed
	return unless $status_rc == 0;
	return if $status_out =~ /Initialized\s+false/;
	return if $status_out =~ /Sealed\s+true/;

	# Check if we can authenticate (need to be authenticated to create approles)
	my ($auth_check, $auth_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'auth', 'status'
	);

	unless ($auth_rc == 0) {
		info("Skipping doomsday approle setup - not authenticated with vault");
		return;
	}

	info("");
	info("Setting up doomsday monitoring approle...");

	# Enable approle auth if not already enabled
	my ($enable_out, $enable_rc) = run(
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'auth', 'enable', 'approle'
	);

	if ($enable_out =~ /Success\! Enabled approle auth method/ || $enable_out =~ /path is already in use/) {
		info("#G{[ok]} AppRole auth enabled");
	} else {
		info("#Y{WARNING:} Could not enable approle auth: $enable_out");
		return;
	}

	# Check if doomsday approle already exists
	my ($list_out, $list_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'list', '-format=json', 'auth/approle/role'
	);

	if ($list_rc == 0 && $list_out) {
		eval {
			require JSON::PP;
			my $roles = JSON::PP::decode_json($list_out);
			if (ref($roles) eq 'ARRAY' && grep { $_ eq 'doomsday' } @$roles) {
				my ($exodus_id, $id_rc) = run({ stderr => 0 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', $ENV{GENESIS_EXODUS_MOUNT} . ':doomsday_approle_id'
				);
				my ($exodus_secret, $secret_rc) = run({ stderr => 0 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', $ENV{GENESIS_EXODUS_MOUNT} . ':doomsday_approle_secret'
				);

				if ($id_rc == 0 && $secret_rc == 0 && $exodus_id && $exodus_secret) {
					info("#G{[ok]} Doomsday approle already exists with credentials in exodus");
					return;
				}
			}
		};
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

	my (undef, $policy_rc) = run({ stdin => $policy, stderr => 1 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'policy', 'write', 'doomsday', '-'
	);

	unless ($policy_rc == 0) {
		info("#R{ERROR:} Failed to create doomsday policy");
		return;
	}
	info("#G{[ok]} Doomsday policy created");

	# Create doomsday approle
	info("Creating doomsday approle...");

	my (undef, $create_rc) = run({ stderr => 1 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'set',
		'auth/approle/role/doomsday',
		'secret_id_ttl=0',
		'token_num_uses=0',
		'token_ttl=1h',
		'token_max_ttl=24h',
		'secret_id_num_uses=0',
		'policies=doomsday'
	);

	unless ($create_rc == 0) {
		info("#R{ERROR:} Failed to create doomsday approle");
		return;
	}

	# Get role ID
	my ($role_id, $role_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', 'auth/approle/role/doomsday/role-id:role_id'
	);

	unless ($role_rc == 0 && $role_id) {
		info("#R{ERROR:} Failed to get doomsday role ID");
		return;
	}

	# Generate secret ID
	my ($secret_id, $secret_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'write', '-field=secret_id', '-f',
		'auth/approle/role/doomsday/secret-id'
	);

	unless ($secret_rc == 0 && $secret_id) {
		info("#R{ERROR:} Failed to generate doomsday secret ID");
		return;
	}

	# Store in exodus
	info("Storing doomsday approle credentials in exodus...");

	chomp($role_id);
	chomp($secret_id);

	my (undef, $store_rc) = run({ stderr => 1 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'set',
		$ENV{GENESIS_EXODUS_MOUNT},
		"doomsday_approle_id=$role_id",
		"doomsday_approle_secret=$secret_id"
	);

	if ($store_rc == 0) {
		info("#G{#\@{+} Doomsday approle created successfully!}");
		info("  Credentials stored in exodus at: $ENV{GENESIS_EXODUS_MOUNT}");
		info("  - doomsday_approle_id");
		info("  - doomsday_approle_secret");
	} else {
		info("#R{ERROR:} Failed to store doomsday credentials in exodus");
	}
}

# _add_target - create a safe target without changing the current one {{{
# `safe target` makes the new target current, and Genesis checks the current
# target when it starts, so a sealed Vault there stops every Genesis command on
# the host.  Put the previous current target back afterwards.
sub _add_target {
	my ($url, $name) = @_;
	my ($current_out) = run({stderr => 0, env => {VAULT_ADDR => '', SAFE_TARGET => ''}},
		'safe', 'target', '--json'
	);
	my $current = eval {decode_json($current_out)} || {};
	my (undef, $rc) = run({stderr => 0}, 'safe', '-k', 'target', '--strongbox', $url, $name);
	run({stderr => 0}, 'safe', 'target', $current->{name})
		if $rc == 0 && $current->{name} && $current->{name} ne $name;
	return $rc;
}
# }}}

# _vault_status - report the cluster's seal status as {initialized, sealed} {{{
# Uses the safe target named after the environment, and creates it from the
# deployment's VM addresses when it is missing or no longer answers.  `vault
# status` exits 2 for a sealed Vault, so its JSON is read whatever the exit
# code.  Returns undef when no node answers.
sub _vault_status {
	my ($self) = @_;
	my $name = $ENV{GENESIS_ENVIRONMENT};

	my $status = _read_status($name);
	return $status if $status;

	my ($vms) = read_json_from($self->env->bosh->execute('vms', '--json'));
	my @ips = $vms ? map {$_->{ips}} @{$vms->{Tables}[0]{Rows}} : ();
	for my $ip (@ips) {
		next unless _add_target("https://$ip", $name) == 0;
		$status = _read_status($name);
		return $status if $status;
	}
	return undef;
}

# _all_unsealed - true when no node in the cluster is sealed {{{
# A status read covers only the node the target points at.  After a rolling
# deploy the others come back sealed, so ask safe, which reads every node
# through strongbox and exits non-zero with -e if any of them is sealed.
# Strongbox lists no nodes while Vault can't reach Consul, and safe then exits
# zero, so also require it to name an unsealed node.
sub _all_unsealed {
	my ($self) = @_;
	my ($out, $rc) = run({stderr => 0}, 'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'status', '-e');
	return $rc == 0 && $out =~ /is unsealed/;
}
# }}}

sub _read_status {
	my ($name) = @_;
	my ($out) = run({stderr => 0}, 'safe', '-T', $name, 'vault', 'status', '-format=json');
	my $status = eval {decode_json($out)};
	return undef unless ref($status) eq 'HASH' && exists($status->{sealed});
	return {
		initialized => $status->{initialized} ? 1 : 0,
		sealed      => $status->{sealed}      ? 1 : 0,
	};
}
# }}}

sub _auto_init {
	my ($self) = @_;

	info("");
	info("Detected #Y{uninitialized Vault} - running automatic initialization...");

	# Run the init addon.  Its module lives at a kit path that isn't on @INC,
	# so load it from the file the way Genesis loads addon hooks.
	my $init_file = $self->kit->path('hooks/addon-init~i.pm');
	require $init_file unless Genesis::Hook::Addon::Vault::Init->can('init');
	my $init_hook = Genesis::Hook::Addon::Vault::Init->init(
		env    => $self->env,
		kit    => $self->kit,
		script => 'init',
		args   => [],
		file   => $init_file,
		label  => 'init',
	);

	my $init_rc = $init_hook->perform();

	if ($init_rc) {
		info("#G{#\@{+} Vault initialized successfully!}");

		# The init addon stores seal keys, so we should be able to unseal now
		# Check if we have seal keys stored
		my ($check_out, $check_rc) = run({ stderr => 0 },
			'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'exists', 'secret/vault/seal/keys'
		);

		if ($check_rc == 0) {
			info("");
			info("Attempting to unseal the newly initialized vault...");

			# Get seal keys and unseal
			my @keys;
			for (my $i = 1; $i <= 5; $i++) {
				my ($key_out, $key_rc) = run({ stderr => 0 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', "secret/vault/seal/keys:key$i"
				);
				if ($key_rc == 0 && $key_out) {
					chomp($key_out);
					push @keys, $key_out;
				}
			}

			if (@keys) {
				my $keys_content = join("\n", @keys);
				my ($unseal_out, $unseal_rc) = run(
					{ stdin => $keys_content, stderr => 1 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'unseal'
				);

				if ($unseal_rc == 0) {
					info("#G{#\@{+} Vault unsealed successfully!}");
				} else {
					info("#Y{WARNING:} Failed to unseal vault automatically");
					info("You can unseal manually with: #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}");
				}
			}
		}
	} else {
		info("#R{ERROR:} Automatic initialization failed");
		info("You can initialize manually with: #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- init}");
	}
}
# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
