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

	# Check if the vault is already targeted
	my ($targets_out, $targets_rc) = run({ stderr => 0 },
		'safe', 'targets', '--json'
	);

	if ($targets_rc == 0) {
		# Parse JSON to check if our environment is already targeted
		eval {
			require JSON::PP;
			my $targets = JSON::PP::decode_json($targets_out);

			foreach my $target (@$targets) {
				if ($target->{name} && $target->{name} eq $ENV{GENESIS_ENVIRONMENT}) {
					# Try to retrieve seal keys
					my $i = 1;
					my @keys;

					while (1) {
						my ($key, $rc) = run({ stderr => 0 },
							'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'exists', "secret/vault/seal/keys:key$i"
						);

						last if $rc != 0;

						($key, $rc) = run({ stderr => 0 },
							'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'read', "secret/vault/seal/keys:key$i"
						);

						if ($rc == 0 && $key) {
							chomp $key;
							push @keys, $key;
						}

						$i++;
					}

					# Write keys to datafile if we found any
					if (@keys) {
						open my $fh, '>', $ENV{GENESIS_PREDEPLOY_DATAFILE}
							or bail("Cannot open $ENV{GENESIS_PREDEPLOY_DATAFILE} for writing: $!");

						foreach my $key (@keys) {
							print $fh "$key\n";
						}

						close $fh;
					}

					# Remove empty datafile
					if (-e $ENV{GENESIS_PREDEPLOY_DATAFILE} && -z $ENV{GENESIS_PREDEPLOY_DATAFILE}) {
						unlink $ENV{GENESIS_PREDEPLOY_DATAFILE};
					}

					last;
				}
			}
		};
	}

	return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
