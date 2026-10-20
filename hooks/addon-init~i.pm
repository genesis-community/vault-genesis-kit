package Genesis::Hook::Addon::Vault::Init v2.0.0;

use v5.20;
use warnings;    # Genesis min perl version is 5.20

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . '/.genesis/lib' }

use Genesis qw/bail info run read_json_from /;

use parent qw(Genesis::Hook::Addon);
use JSON::PP;

# Include the shared seal-status and safe target helpers
BEGIN {
	require File::Basename;
	require File::Spec;
	my $mixin_file = File::Basename::dirname( File::Spec->rel2abs(__FILE__) ) . '/lib/_vault_cluster.pm';
	do $mixin_file or die "Failed to include addon mixin $mixin_file: " . ( $@ || $! || 'unknown error' );
}

sub init {
	my $class = shift;
	my $obj   = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.20');
	return $obj;
}

sub cmd_details {
	return
"Initialize a new Vault cluster, setting up a new set of seal keys and an initial root token.\n"
	  . "This should only be done once per deployment.\n";
}

# quiet - true when post-deploy runs the init {{{
# A deploy's output lands in CI logs, so post-deploy passes quiet => 1, and
# then nothing here prints a seal key or the root token.
sub quiet { $_[0]->{quiet} ? 1 : 0 }

# }}}
sub perform {
	my ($self) = @_;
	my $env = $self->env;

	info("");

	# Find the Vault nodes, and make sure none of them is initialized already
	my @urls = $self->_vault_node_urls;
	bail("No Vault VMs found in deployment") unless @urls;

	my $cluster = $self->_vault_cluster(@urls);
	bail("Could not find any reachable Vault nodes to initialize.")
		unless @{ $cluster->{reachable} };
	if ( $cluster->{initialized} ) {
		info("#R{Vault is already initialized} - refusing to initialize it again:");
		$self->_vault_report_nodes($cluster);
		return $self->done(0);
	}

	my $url = $cluster->{reachable}[0];
	info("Attempting to #Y{initialize} Vault via node $url");

	# safe unseals every node after init only through strongbox
	my $target = $self->_ensure_strongbox_target( $env->name, @{ $cluster->{reachable} } );
	unless ($target) {
		info( "#R{Failed to target Vault at $url}" );
		return $self->done(0);
	}

	# Initialize the Vault while its target is current, so that the root
	# token safe saves can only land on that target, then put the operator's
	# current target back.  The output holds every seal key and the root
	# token, so it is redacted from the trace log.
	info("Initializing Vault cluster...");
	my $previous = _safe_current_target();
	my ( $switch_out, $switch_rc, $switch_err ) =
	  run( { stderr => 0, env => _safe_env() }, 'safe', 'target', $env->name );
	if ( $switch_rc != 0 ) {
		info( "#R{Failed to make the %s safe target current:} %s", $env->name, $switch_err || $switch_out || "safe exited $switch_rc" );
		return $self->done(0);
	}
	my ( $init_out, $init_rc ) =
	  run( { redact_output => 1, env => _safe_env() }, 'safe', '-T', $env->name, 'init' );
	_safe_restore_current( $previous, $env->name );

	# safe can fail after Vault has handed out the keys, for instance while
	# mounting secret/, and those keys exist nowhere else, so look for them
	# whatever the exit code says.
	my ( $seal_keys, $root_token ) = $self->_parse_seal_keys( $init_out, $init_rc == 0 );

	# Output that can't be parsed is never printed, since it may still hold
	# keys in a form the parser didn't expect.  When Vault was initialized, or
	# the output names keys, it is the only copy of them, so it goes to a file
	# only the operator can read.
	if ( !$seal_keys ) {
		info( "#R{Failed to initialize Vault:} %s", _without_secrets($init_out) ) if $init_rc != 0;
		if ( $init_rc == 0 || ( $init_out // '' ) =~ /Unseal Key|Root Token/i ) {
			info("#Y{WARNING:} The seal keys and root token could not be read from safe's output.");
			$self->_save_recovery_file( $init_out, "safe's unparsed init output" );
		}
		return $self->done(0);
	}
	if ( $init_rc != 0 ) {
		info( "#Y{WARNING:} safe reported an error after Vault was initialized: %s", _without_secrets($init_out) );
	}

	# Check if safe init already stored the keys
	my $safe_stored_keys = 0;
	if ( $init_out =~ /safe has written the unseal keys at ([^\s]+)/ ) {
		my $stored_path = $1;
		info("#G{Note:} safe has already stored seal keys at $stored_path");

		# Verify they're accessible
		my ( undef, $check_rc ) = run( { stderr => 0, env => _safe_env() }, 'safe', '-T', $env->name, 'exists', $stored_path );
		if ( $check_rc == 0 ) {
			$safe_stored_keys = 1;
			info("#G{Verified:} Seal keys are accessible in Vault");
		}
	}

	my $stored = $safe_stored_keys;
	if ( !$safe_stored_keys ) {
		# Only try to store seal keys if safe didn't already do it
		if ( $self->_store_seal_keys( $seal_keys, $root_token, $env->name ) ) {
			$stored = 1;
			info("#G{Vault initialized successfully!}");
			info("Seal keys have been stored in the Vault for automatic unsealing.");
		}
		else {
			info("#Y{WARNING:} Vault initialized but seal keys could not be stored.");
			info("You will need to manually unseal the vault after redeployments.");
		}
	}
	else {
		info("#G{Vault initialized successfully!}");
		info("Seal keys have been automatically stored by safe for automatic unsealing.");
	}

	# Back the keys up to the deploying vault too, whichever path stored the
	# primary copy - the same custody guarantee either way.
	my $backed_up = $self->_backup_seal_keys_to_provider( $seal_keys, $target->{url} );

	if ( !$self->quiet ) {
		# Always print the initialization output for backup
		info("");
		info("#C{IMPORTANT: Save these credentials securely!}");
		info( "#C{" . "=" x 60 . "}" );
		print $init_out . "\n";
		info( "#C{" . "=" x 60 . "}" );
	}
	else {
		$self->_report_quiet_custody( $seal_keys, $root_token, $stored, $backed_up );
	}

	return $self->done(1);
}

# _without_secrets - safe init output minus the seal keys and root token {{{
sub _without_secrets {
	my ($output) = @_;
	my @lines = grep { /\S/ && !/^\s*(Unseal Key|Initial Root Token|Root Token)\b/i } split( /\n/, $output // '' );
	return @lines ? join( ' ', map { s/^\s+|\s+$//gr } @lines ) : 'no other output';
}

# }}}
# _report_quiet_custody - tell the operator where the new secrets went {{{
# Nothing printed here is secret.  When the keys didn't reach the deploying
# vault, they are written to a file only the operator can read, since the
# deployed Vault can't hand over its own keys once it seals again.
sub _report_quiet_custody {
	my ( $self, $seal_keys, $root_token, $stored, $backed_up ) = @_;
	my $name = $self->env->name;

	info("");
	info("#C{The seal keys and root token were not printed.}");
	info( "  Seal keys in the deployed Vault: %s", $stored ? "#C{" . VAULT_SEAL_KEYS_PATH . "}" : "#R{not stored}" );
	info( "  Seal-key backup in the deploying vault: %s",
		$backed_up ? "#C{" . $self->env->secrets_base . "vault/seal/keys}" : "#R{not written}" );
	info( "  Root token: saved by safe in #C{~/.saferc} on this host, under the #C{%s} target", $name );
	info("  Move the root token into your secrets custody and revoke it once you have other admin access.");

	return if $backed_up;

	info("\n#Y{WARNING:} The seal keys are not backed up outside the deployed Vault.");
	my $content = join( "",
		map( { sprintf( "Unseal Key #%d: %s\n", $_ + 1, $seal_keys->[$_] ) } 0 .. $#$seal_keys ),
		( defined($root_token) ? "Initial Root Token: $root_token\n" : '' ) );
	$self->_save_recovery_file( $content, "the seal keys and root token" )
	  or info(
		"While the Vault is still unsealed, copy the keys out with #G{safe -T %s get %s}.",
		$name, VAULT_SEAL_KEYS_PATH
	  );
}

# }}}
# _save_recovery_file - keep init secrets in a file only the operator can read {{{
# Returns the file's path, or undef when it could not be written.
sub _save_recovery_file {
	my ( $self, $content, $what ) = @_;
	return undef unless defined($content) && $content =~ /\S/;

	my $file = sprintf( "%s/.genesis/vault-init-recovery/%s-%d.txt", $ENV{HOME} // '.', $self->env->name, time() );
	my ( $ok, $err ) = _write_private_file( $file, $content );
	if ($ok) {
		info(
			"#Y{WARNING:} Wrote %s to #C{%s} (mode 0600).  Move them into your secrets ".
			"custody and delete the file.",
			$what, $file
		);
		return $file;
	}
	info( "#R{ERROR:} Could not write %s to a recovery file: %s", $what, $err );
	return undef;
}

# }}}
# _parse_seal_keys - Parse seal keys and root token out of safe init output {{{
# Returns (\@seal_keys, $root_token) on success, or (undef, undef) if no seal
# keys could be parsed.  Shared by both of perform()'s storage paths, so both
# back the keys up to the deploying vault the same way.  $report says whether
# a parse failure should be reported; nothing reports the output itself.
sub _parse_seal_keys {
	my ( $self, $init_output, $report ) = @_;
	$report //= 1;

	unless ($init_output) {
		info("#R{ERROR:} No output from vault initialization") if $report;
		return ( undef, undef );
	}

	my @seal_keys;
	my $root_token;

	foreach my $line ( split /\n/, $init_output ) {

		# Match seal key pattern: "Unseal Key #N: <key>"
		if ( $line =~ /^Unseal Key #?(\d+):\s*(.+)$/i || $line =~ /^Unseal Key():\s*(.+)$/i ) {
			my ( $number, $key ) = ( $1, $2 );
			$key =~ s/^\s+|\s+$//g;    # trim whitespace

			# Validate key format (should be base64 or hex - allowing longer hex keys)
			if ( $key =~ /^[A-Fa-f0-9]+$/ || $key =~ /^[A-Za-z0-9+\/=]+$/ ) {
				push @seal_keys, $key;
			}
			elsif ( $self->quiet ) {
				info( "#Y{WARNING:} Invalid seal key format detected, skipping key %s", $number || scalar(@seal_keys) + 1 );
			}
			else {
				info("#Y{WARNING:} Invalid seal key format detected, skipping: $key");
			}
		}

		# Capture root token for validation
		elsif ( $line =~ /^Initial Root Token:\s*(.+)$/i || $line =~ /^Root Token:\s*(.+)$/i ) {
			$root_token = $1;
			$root_token =~ s/^\s+|\s+$//g;
		}
	}

	unless (@seal_keys) {
		if ($report) {
			my $lines = scalar( grep { /\S/ } split( /\n/, $init_output ) );
			info("#R{ERROR:} No seal keys found in initialization output");
			info( "The output had %d non-blank line(s), and none of them held an unseal key.", $lines );
		}
		return ( undef, undef );
	}

	unless ($root_token) {
		info("#R{ERROR:} No root token found in initialization output") if $report;
		return ( undef, undef );
	}

	return ( \@seal_keys, $root_token );
}

# }}}

# _store_seal_keys - store parsed seal keys in the newly initialized vault {{{
sub _store_seal_keys {
	my ( $self, $seal_keys, $root_token, $target_name ) = @_;

	my @seal_keys = @$seal_keys;
	my $path      = VAULT_SEAL_KEYS_PATH;

	info( "Found " . scalar(@seal_keys) . " seal keys to store" );

	# Check if vault is sealed and unseal if necessary.  `status -e` exits
	# non-zero when any node is sealed, and names each unsealed node.
	unless ( _all_unsealed($target_name) ) {
		info("Vault is sealed, unsealing to enable storage...");

		my ( $unseal_out, $unseal_rc ) =
		  run( { stdin => join( "\n", @seal_keys ) . "\n", env => _safe_env() }, 'safe', '-T', $target_name, 'unseal' );
		info( "#R{ERROR:} Failed to unseal vault: %s", $unseal_out || "safe exited $unseal_rc" )
		  if $unseal_rc != 0;

		# Wait a moment for vault to fully initialize
		sleep(2);

		# Verify vault is now unsealed
		unless ( _all_unsealed($target_name) ) {
			info("#R{ERROR:} Vault is still sealed after unseal attempts");
			return 0;
		}

		info("#G{Vault successfully unsealed}");
	}

	# Authenticate with the root token to store the keys
	info("Authenticating with root token...");
	my ( $auth_out, $auth_rc ) =
	  run( { stdin => $root_token, stderr => 0, env => _safe_env() }, 'safe', '-T', $target_name, 'auth', 'token' );

	if ( $auth_rc != 0 ) {
		info( "#R{ERROR:} Failed to authenticate with root token: %s", $auth_out || "safe exited $auth_rc" );
		return 0;
	}

	info("#G{Successfully authenticated with root token}");

	# Store each seal key, through stdin so no key reaches argv
	my $stored_count = 0;
	my @failed_keys;
	my $query = _vault_target_query($target_name);

	for ( my $i = 0 ; $i < @seal_keys ; $i++ ) {
		my $key_num = $i + 1;
		my ( $store_rc, $store_err ) = _vault_set_secret( $query, $path, "key$key_num", $seal_keys[$i] );

		# Read it back: a write that reports failure may still have landed
		my ( $verify_out, $verify_rc ) = $query->( { stderr => 0, redact_output => 1 }, 'get', "$path:key$key_num" );
		my $readback = defined($verify_out) ? $verify_out =~ s/^\s+|\s+$//gr : '';
		my $success  = $verify_rc == 0 && $readback eq $seal_keys[$i];

		if ($success) {
			$stored_count++;
			info("  #G{✓} Stored seal key $key_num");
			info("  #Y{Note:} Key $key_num appears to be stored despite error message")
			  if $store_rc != 0;
		}
		else {
			push @failed_keys, $key_num;
			( my $err_msg = $store_err || ( $store_rc ? "safe exited $store_rc" : "it did not read back" ) ) =~ s/\n/ /g;
			info("  #R{✗} Failed to store seal key $key_num: $err_msg");
		}
	}

	# Verify storage was successful
	my $result;
	if ( $stored_count == @seal_keys ) {
		info("#G{Successfully stored all $stored_count seal keys}");
		info("#G{Verified:} Seal keys are accessible in Vault");

		# Store a marker to indicate the vault has been initialized
		run(
			{ stderr => 0 },
			'safe', '-T', $target_name, 'set',
			'secret/vault/seal/initialized',
			"at=" . localtime(),
			"keys=$stored_count"
		);

		$result = 1;
	}
	elsif ( $stored_count > 0 ) {
		info(
			"#Y{WARNING:} Only stored $stored_count out of " . scalar(@seal_keys) . " seal keys" );
		info( "#Y{Failed keys:} " . join( ", ", @failed_keys ) ) if @failed_keys;

		# Return success if we stored at least 3 keys (minimum needed to unseal)
		$result = ( $stored_count >= 3 ) ? 1 : 0;
	}
	else {
		info("#R{ERROR:} Failed to store any seal keys");
		$result = 0;
	}

	return $result;
}

# _all_unsealed - true when safe reports every node unsealed {{{
# Strongbox lists no nodes while Vault can't reach Consul, and safe then
# exits zero, so also require it to name an unsealed node.
sub _all_unsealed {
	my ($target_name) = @_;
	my ( $out, $rc ) = run( { stderr => 0, env => _safe_env() }, 'safe', '-T', $target_name, 'status', '-e' );
	return $rc == 0 && ( $out // '' ) =~ /is unsealed/;
}

# }}}
# }}}

# _backup_seal_keys_to_provider - copy seal keys into the deploying vault {{{
# The primary copy above lives in the freshly-initialized target Vault
# itself (addressed via the ad-hoc `safe -T $target_name` alias) - that is
# circular custody: once that target Vault seals (e.g. after a restart before
# auto-unseal is wired up, or if the VM is rebuilt), the keys needed to
# unseal it are unreachable. This writes a second copy into the Genesis
# "deploying" vault for this environment - the same secrets provider Genesis
# itself targets to store this env's manifest params (available inside a
# hook via $self->vault, per Genesis::Hook::Addon), under this env's own
# secrets_base path, mirroring how the rest of this kit paths env secrets.
#
# An existing backup is never replaced: it may be the only copy of the keys
# for data that a snapshot restore will bring back.  Nor is anything written
# when the deploying vault can't say whether a backup exists.
#
# This is a best-effort backup: it must never fail hook init, since the
# keys are already durably stored in the target vault.
sub _backup_seal_keys_to_provider {
	my ( $self, $seal_keys, $target_url ) = @_;

	return 0 unless $seal_keys && @$seal_keys;

	my $provider;
	eval { $provider = $self->vault; };
	if ( $@ || !$provider ) {
		my $err = $@ || 'no deploying vault is configured for this environment';
		$err =~ s/\n/ /g;
		info("#Y{WARNING:} Could not resolve the deploying vault to back up seal keys: $err");
		info("#Y{WARNING:} Seal keys remain available only in the target vault.");
		return 0;
	}

	# Guard: if the deploying provider and the freshly-initialized target
	# vault are the same endpoint (e.g. this hook is re-run post-migration
	# once the target vault has become the environment's own deploying
	# vault), a second write would be circular/redundant - skip it.
	my $provider_url = $provider->url // '';
	( my $norm_provider_url = lc($provider_url) ) =~ s{/+$}{};
	( my $norm_target_url   = lc( $target_url // '' ) ) =~ s{/+$}{};

	if ( $norm_provider_url ne '' && $norm_provider_url eq $norm_target_url ) {
		info("#Y{Note:} Deploying vault and target vault are the same endpoint ($provider_url) - skipping backup seal-key copy.");
		return 0;
	}

	my $backup_path = $self->env->secrets_base() . 'vault/seal/keys';

	my ( $state, $state_err ) = _vault_path_state( $provider, $backup_path );
	if ( $state eq 'present' ) {
		info(
			"#Y{WARNING:} The deploying vault at #M{%s} already holds a seal-key backup at #C{%s}, ".
			"so it was left in place rather than replaced with the new keys.  It may be the only ".
			"copy of the keys for data that a snapshot restore would bring back.",
			$provider_url, $backup_path
		);
		info("#Y{WARNING:} Seal keys remain available only in the target vault.");
		return 0;
	}
	if ( $state ne 'absent' ) {
		$state_err =~ s/\n/ /g;
		info(
			"#Y{WARNING:} Could not tell whether the deploying vault at #M{%s} already holds a ".
			"seal-key backup at #C{%s}, so none was written: %s",
			$provider_url, $backup_path, $state_err
		);
		info("#Y{WARNING:} Seal keys remain available only in the target vault.");
		return 0;
	}

	# One key per write, each on stdin, so no key reaches argv
	my $query = sub { $provider->query(@_) };
	for ( my $i = 0 ; $i < @$seal_keys ; $i++ ) {
		my ( $rc, $err ) = _vault_set_secret( $query, $backup_path, 'key' . ( $i + 1 ), $seal_keys->[$i] );
		next if $rc == 0;
		$err =~ s/\n/ /g;
		info( "#Y{WARNING:} Failed to back up seal key %d to the deploying vault at #M{%s}: %s",
			$i + 1, $provider_url, $err || "safe exited $rc" );
		info(
			"#Y{WARNING:} The backup at #C{%s} is incomplete.  Remove it with #G{safe rm %s} once ".
			"the keys are safe elsewhere, so that a later init can write a whole one.",
			$backup_path, $backup_path
		) if $i > 0;
		info("#Y{WARNING:} Seal keys remain available only in the target vault.");
		return 0;
	}

	info( "#G{Backed up} " . scalar(@$seal_keys) . " seal key(s) to the deploying vault at #M{$provider_url} (#C{$backup_path})" );
	return 1;
}

# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
