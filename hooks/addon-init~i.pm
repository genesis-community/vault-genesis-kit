package Genesis::Hook::Addon::Vault::Init v2.0.0;

use v5.20;
use warnings;    # Genesis min perl version is 5.20

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . '/.genesis/lib' }

use Genesis qw/bail info run read_json_from /;

use parent qw(Genesis::Hook::Addon);
use JSON::PP;

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

sub perform {
	my ($self) = @_;
	my $env = $self->env;

	info("");

	# Try to find a Vault node to initialize
	my ( $out, $rc ) = read_json_from( $self->env->bosh->execute( 'vms', '--json' ) );
	bail("Failed to get VM information from BOSH") unless $out;

	my @ips = map { $_->{ips} } $out->{Tables}[0]{Rows}->@*;    # TODO handle possible VIPs
	bail("No Vault VMs found in deployment") unless @ips;

	foreach my $ip (@ips) {

		# Test connectivity to the Vault node
		my $curl_opts = $ENV{CURLOPTS} // '';
		my $timeout   = $ENV{TIMEOUT}  // 3;
		my ( $curl_out, $curl_rc ) =
		  run( { stderr => 0 }, "curl -Lsk $curl_opts -m$timeout https://$ip" );

		if ( $curl_rc == 0 ) {
			info("Attempting to #Y{initialize} Vault via node $ip");

			# Target the Vault node
			my ( $target_out, $target_rc ) =
			  run( { stderr => 1 }, 'safe', 'target', "https://$ip", '-k', $env->name );

			if ( $target_rc != 0 ) {
				info("#R{Failed to target Vault at $ip}, trying next node...");
				next;
			}

			# Initialize the Vault and capture output
			info("Initializing Vault cluster...");
			my ( $init_out, $init_rc ) = run( { stderr => 1 }, 'safe', '-T', $env->name, 'init' );

			if ( $init_rc == 0 ) {

				# Check if safe init already stored the keys
				my $safe_stored_keys = 0;
				if ( $init_out =~ /safe has written the unseal keys at ([^\s]+)/ ) {
					my $stored_path = $1;
					info("#G{Note:} safe has already stored seal keys at $stored_path");
					
					# Verify they're accessible
					my ( $check_out, $check_rc ) = run( { stderr => 0 }, 'safe', '-T', $env->name, 'get', $stored_path );
					if ( $check_rc == 0 ) {
						$safe_stored_keys = 1;
						info("#G{Verified:} Seal keys are accessible in Vault");
					}
				}

				# Only try to store seal keys if safe didn't already do it
				if ( !$safe_stored_keys ) {
					# Parse and store seal keys
					if ( $self->_store_seal_keys( $init_out, $env->name, "https://$ip" ) ) {
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

					# safe already stored the primary copy, but the keys have not
					# gone through _store_seal_keys() in this branch, so back
					# them up to the deploying vault here too - same custody
					# guarantee regardless of which path stored the primary copy.
					my ( $seal_keys, undef ) = $self->_parse_seal_keys($init_out);
					$self->_backup_seal_keys_to_provider( $seal_keys, "https://$ip" )
						if $seal_keys && @$seal_keys;
				}

				# Always print the initialization output for backup
				info("");
				info("#C{IMPORTANT: Save these credentials securely!}");
				info( "#C{" . "=" x 60 . "}" );
				print $init_out . "\n";
				info( "#C{" . "=" x 60 . "}" );

				return $self->done(1);
			}
			else {
				info("#R{Failed to initialize Vault:} $init_out");
				return $self->done(0);
			}
		}
	}

	bail("Could not find any reachable Vault nodes to initialize.");
}

# _parse_seal_keys - Parse seal keys and root token out of safe init output {{{
# Returns (\@seal_keys, $root_token) on success, or (undef, undef) if no seal
# keys could be parsed. Shared by _store_seal_keys() and the "safe already
# stored the keys" branch in perform(), so both paths can back the keys up to
# the deploying vault via the same code.
sub _parse_seal_keys {
	my ( $self, $init_output ) = @_;

	unless ($init_output) {
		info("#R{ERROR:} No output from vault initialization");
		return ( undef, undef );
	}

	my @seal_keys;
	my $root_token;

	foreach my $line ( split /\n/, $init_output ) {

		# Match seal key pattern: "Unseal Key #N: <key>"
		if ( $line =~ /^Unseal Key #?\d+:\s*(.+)$/i || $line =~ /^Unseal Key:\s*(.+)$/i ) {
			my $key = $1;
			$key =~ s/^\s+|\s+$//g;    # trim whitespace

			# Validate key format (should be base64 or hex - allowing longer hex keys)
			if ( $key =~ /^[A-Fa-f0-9]+$/ || $key =~ /^[A-Za-z0-9+\/=]+$/ ) {
				push @seal_keys, $key;
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
		info("#R{ERROR:} No seal keys found in initialization output");
		info( "Debug: First 500 chars of output: " . substr( $init_output, 0, 500 ) );
		return ( undef, undef );
	}

	unless ($root_token) {
		info("#R{ERROR:} No root token found in initialization output");
		return ( undef, undef );
	}

	return ( \@seal_keys, $root_token );
}

# }}}

# _store_seal_keys - Parse and store seal keys from safe init output {{{
sub _store_seal_keys {
	my ( $self, $init_output, $target_name, $target_url ) = @_;

	my ( $seal_keys_ref, $root_token ) = $self->_parse_seal_keys($init_output);
	return 0 unless $seal_keys_ref;

	my @seal_keys = @$seal_keys_ref;

	info( "Found " . scalar(@seal_keys) . " seal keys to store" );

	# Check if vault is sealed and unseal if necessary
	my ( $status_out, $status_rc ) = run( { stderr => 0 }, 'safe', '-T', $target_name, 'status' );

	my $sealed = ( $status_out =~ /sealed:\s*true/i || $status_rc != 0 );

	if ($sealed) {
		info("Vault is sealed, unsealing to enable storage...");

		# Unseal with minimum required keys (usually 3 out of 5)
		my $keys_to_use    = ( @seal_keys >= 3 ) ? 3 : scalar(@seal_keys);
		my $unseal_success = 0;

		for ( my $i = 0 ; $i < $keys_to_use ; $i++ ) {
			info( "  Unsealing with key " . ( $i + 1 ) . " of $keys_to_use..." );
			my ( $unseal_out, $unseal_rc ) =
			  run( { stderr => 1 }, "echo '$seal_keys[$i]' | safe -T $target_name unseal" );
			if ( $unseal_rc == 0 ) {
				$unseal_success++;
			}
			else {
				info( "#R{ERROR:} Failed to unseal with key " . ( $i + 1 ) . ": $unseal_out" );
			}
		}

		if ( $unseal_success < $keys_to_use ) {
			info(
"#R{ERROR:} Failed to unseal vault (only $unseal_success of $keys_to_use keys worked)"
			);
			return 0;
		}

		# Wait a moment for vault to fully initialize
		sleep(2);

		# Verify vault is now unsealed
		( $status_out, $status_rc ) = run( { stderr => 0 }, 'safe', '-T', $target_name, 'status' );

		if ( $status_out =~ /sealed:\s*true/i ) {
			info("#R{ERROR:} Vault is still sealed after unseal attempts");
			return 0;
		}

		info("#G{Vault successfully unsealed}");
	}

	# Authenticate with the root token to store the keys
	info("Authenticating with root token...");
	my ( $auth_out, $auth_rc ) =
	  run( { stderr => 1 }, "echo '$root_token' | safe -T $target_name auth token" );

	if ( $auth_rc != 0 ) {
		info("#R{ERROR:} Failed to authenticate with root token: $auth_out");

		# Try alternate auth method
		( $auth_out, $auth_rc ) =
		  run( { stderr => 1 }, 'safe', '-T', $target_name, 'auth', 'token', $root_token );

		if ( $auth_rc != 0 ) {
			info("#R{ERROR:} Failed to authenticate with alternate method: $auth_out");
			return 0;
		}
	}

	info("#G{Successfully authenticated with root token}");

	# Store each seal key
	my $stored_count = 0;
	my @failed_keys;

	for ( my $i = 0 ; $i < @seal_keys ; $i++ ) {
		my $key_num  = $i + 1;
		my $key_path = "secret/vault/seal/keys:key$key_num";

		my ( $store_out, $store_rc ) = run( { stderr => 1 },
			'safe', '-T', $target_name, 'set', $key_path, "value=$seal_keys[$i]" );

		# Check if the command succeeded (rc 0) or if we can verify the key was stored
		my $success = 0;
		
		# Debug output
		if ($ENV{DEBUG}) {
			info("  Debug: store_rc=$store_rc");
			info("  Debug: store_out='$store_out'");
		}
		
		if ( $store_rc == 0 ) {
			$success = 1;
		}
		elsif ( !$store_out || $store_out eq '' ) {
			# Empty output might indicate success for some versions of safe
			# Try to verify if the key was actually stored
			my ( $verify_out, $verify_rc ) = run( { stderr => 0 }, 'safe', '-T', $target_name, 'get', "${key_path}:value" );
			if ( $verify_rc == 0 && $verify_out ) {
				# Trim whitespace for comparison
				$verify_out =~ s/^\s+|\s+$//g;
				if ( $verify_out eq $seal_keys[$i] ) {
					$success = 1;
				}
			}
		}
		elsif ( $store_out =~ /(wrote|updated|created|success|stored)/i ) {
			$success = 1;
		}
		
		if ( $success ) {
			$stored_count++;
			info("  #G{✓} Stored seal key $key_num");
		}
		else {
			push @failed_keys, $key_num;
			my $err_msg = $store_out || "No output from safe set command";
			$err_msg =~ s/\n/ /g;
			info("  #R{✗} Failed to store seal key $key_num: $err_msg");
			
			# Always try to verify if key was stored despite error
			my ( $verify_out, $verify_rc ) = run( { stderr => 0 }, 'safe', '-T', $target_name, 'get', "${key_path}:value" );
			if ( $verify_rc == 0 && $verify_out ) {
				$verify_out =~ s/^\s+|\s+$//g;
				if ( $verify_out eq $seal_keys[$i] ) {
					info("  #Y{Note:} Key $key_num appears to be stored despite error message");
					$stored_count++;
					pop @failed_keys;  # Remove from failed list
				}
			}
		}
	}

	# Try to verify the stored keys
	if ( $stored_count > 0 ) {
		my ( $check_out, $check_rc ) =
		  run( { stderr => 0 }, 'safe', '-T', $target_name, 'get', 'secret/vault/seal/keys' );

		if ( $check_rc == 0 ) {
			info("#G{Verified:} Seal keys are accessible in Vault");
		}
	}

	# Verify storage was successful
	my $result;
	if ( $stored_count == @seal_keys ) {
		info("#G{Successfully stored all $stored_count seal keys}");

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

	# Belt-and-suspenders: also back the seal keys up to the deploying
	# vault, so they remain recoverable even if this freshly-initialized
	# target vault is later lost or rebuilt before an out-of-band backup
	# runs. Best-effort only - never fails init (see
	# _backup_seal_keys_to_provider).
	$self->_backup_seal_keys_to_provider( \@seal_keys, $target_url ) if $result;

	return $result;
}

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
# This is a best-effort backup: it must never fail hook init, since the
# keys are already durably stored in the target vault and printed to the
# console above.
sub _backup_seal_keys_to_provider {
	my ( $self, $seal_keys, $target_url ) = @_;

	return 0 unless $seal_keys && @$seal_keys;

	my $provider;
	eval { $provider = $self->vault; };
	if ( $@ || !$provider ) {
		my $err = $@ || 'no deploying vault is configured for this environment';
		$err =~ s/\n/ /g;
		info("#Y{WARNING:} Could not resolve the deploying vault to back up seal keys: $err");
		info("#Y{WARNING:} Seal keys remain available only in the target vault and the console output above.");
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

	my %data;
	for ( my $i = 0 ; $i < @$seal_keys ; $i++ ) {
		$data{ 'key' . ( $i + 1 ) } = $seal_keys->[$i];
	}

	eval { $provider->set_path( $backup_path, \%data ); };
	if ($@) {
		my $err = $@;
		$err =~ s/\n/ /g;
		info("#Y{WARNING:} Failed to back up seal keys to the deploying vault at #M{$provider_url}: $err");
		info("#Y{WARNING:} Seal keys remain available only in the target vault and the console output above.");
		return 0;
	}

	info( "#G{Backed up} " . scalar(@$seal_keys) . " seal key(s) to the deploying vault at #M{$provider_url} (#C{$backup_path})" );
	return 1;
}

# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
