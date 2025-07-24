package Genesis::Hook::PreDeploy::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info run/;

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

	# Skip automatic unseal for auxiliary vaults
	if ($self->env->lookup('params.auxiliary_vault', '') eq 'true') {
		info("Skipping seal key retrieval for auxiliary vault deployment");
		return $self->done(1);
	}

	# Check if the vault is already targeted
	info("Checking for existing Vault target: #C{$ENV{GENESIS_ENVIRONMENT}}");
	my ($targets_out, $targets_rc) = run({ stderr => 0 },
		'safe', 'targets', '--json'
	);

	if ($targets_rc != 0) {
		info("#Y{WARNING:} Could not retrieve safe targets - automatic unseal will not be available");
		return $self->done(1);
	}

	# Parse JSON to check if our environment is already targeted
	eval {
		require JSON::PP;
		my $targets = JSON::PP::decode_json($targets_out);
		my $found_target = 0;

		foreach my $target (@$targets) {
			if ($target->{name} && $target->{name} eq $ENV{GENESIS_ENVIRONMENT}) {
				$found_target = 1;
				info("Found existing Vault target, retrieving seal keys...");

				# Check if vault is initialized
				my ($init_check, $init_rc) = run({ stderr => 0 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'exists', 'secret/vault/seal/keys'
				);

				if ($init_rc != 0) {
					info("Vault does not appear to be initialized - skipping seal key retrieval");
					last;
				}

				# Try to retrieve seal keys
				my @keys;
				my $errors = 0;

				for (my $i = 1; $i <= 10; $i++) { # Check up to 10 keys (reasonable upper limit)
					my $key_path = "secret/vault/seal/keys:key$i";

					# Check if key exists
					my ($exists_out, $exists_rc) = run({ stderr => 0 },
						'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'exists', $key_path
					);

					last if $exists_rc != 0; # No more keys

					# Read the key value
					my ($key_data, $read_rc) = run({ stderr => 0 },
						'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', $key_path
					);

					if ($read_rc == 0 && $key_data) {
						# Extract just the value from the output
						# safe get outputs in format: key:value
						my $key_value;
						if ($key_data =~ /^[^:]+:(.+)$/m) {
							$key_value = $1; # YAML style
						} else {
							($key_value) = $key_data =~ /(.+)/; # raw single-line
						}
						$key_value =~ s/^\s+|\s+$//g;	# trim

						if ($key_value =~ /^[A-Za-z0-9+\/=]+$/) {
								push @keys, $key_value;
								info("  #G{Ok} Retrieved seal key $i");
							} else {
								info("  #Y{!} Skipping invalid seal key $i");
								$errors++;
							}
						}
					 else {
						info("  #R{✗} Failed to read seal key $i");
						$errors++;
					}
				}

				# Write keys to datafile if we found any
				if (@keys) {
					info("Retrieved " . scalar(@keys) . " seal keys" . ($errors ? " with $errors errors" : ""));

					open my $fh, '>', $ENV{GENESIS_PREDEPLOY_DATAFILE}
						or bail("Cannot open $ENV{GENESIS_PREDEPLOY_DATAFILE} for writing: $!");

					foreach my $key (@keys) {
						print $fh "$key\n";
					}

					close $fh;

					info("#G{Seal keys saved for automatic post-deploy unseal}");
				} else {
					info("#Y{No seal keys found} - automatic unseal will not be available");
					info("You will need to manually unseal the vault after deployment");
				}

				last;
			}
		}

		unless ($found_target) {
			info("Vault target #C{$ENV{GENESIS_ENVIRONMENT}} not found - this appears to be a new deployment");
			info("Automatic unseal will be available after initialization");
		}
	};

	if ($@) {
		info("#Y{WARNING:} Error processing vault targets: $@");
		info("Automatic unseal may not be available");
	}

	# Clean up empty datafile
	if (-e $ENV{GENESIS_PREDEPLOY_DATAFILE} && -z $ENV{GENESIS_PREDEPLOY_DATAFILE}) {
		unlink $ENV{GENESIS_PREDEPLOY_DATAFILE};
	}

	return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
