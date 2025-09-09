package Genesis::Hook::Addon::Vault::Init v2.0.0;

use v5.20;
use warnings;    # Genesis min perl version is 5.20
use Genesis qw/bail info run read_json_from /;

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . './.genesis/lib' }

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
					if ( $self->_store_seal_keys( $init_out, $env->name ) ) {
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

# _store_seal_keys - Parse and store seal keys from safe init output {{{
sub _store_seal_keys {
	my ( $self, $init_output, $target_name ) = @_;

	# Validate input
	unless ($init_output) {
		info("#R{ERROR:} No output from vault initialization");
		return 0;
	}

	# Parse seal keys from the output
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

	# Validate we found seal keys
	unless (@seal_keys) {
		info("#R{ERROR:} No seal keys found in initialization output");
		info( "Debug: First 500 chars of output: " . substr( $init_output, 0, 500 ) );
		return 0;
	}

	unless ($root_token) {
		info("#R{ERROR:} No root token found in initialization output");
		return 0;
	}

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

		return 1;
	}
	elsif ( $stored_count > 0 ) {
		info(
			"#Y{WARNING:} Only stored $stored_count out of " . scalar(@seal_keys) . " seal keys" );
		info( "#Y{Failed keys:} " . join( ", ", @failed_keys ) ) if @failed_keys;

		# Return success if we stored at least 3 keys (minimum needed to unseal)
		return ( $stored_count >= 3 ) ? 1 : 0;
	}
	else {
		info("#R{ERROR:} Failed to store any seal keys");
		return 0;
	}
}

# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
