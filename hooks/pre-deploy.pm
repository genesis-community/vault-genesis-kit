package Genesis::Hook::PreDeploy::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/info run mkfile_or_fail/;
use Service::Vault;

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

	# We're just grabbing the vault unseal keys for post-deploy unsealing
	my @matching_vaults = Service::Vault->find_by_target($self->env->name);
	$self->done() unless @matching_vaults;
	my $vault = $matching_vaults[0];
	$self->env->notify(" #iu{pre-deploy}: Retrieving vault unseal keys for post-deploy unsealing");
	my $vault_seal_path = (grep {$_ =~ m{/vault/seal/keys$}} $vault->paths())[0];
	if (!$vault_seal_path) {
		info(
			'[[  - >>#Yr{[#@{!} warning]}: Vault seal keys path not found - '.
			'automatic unseal will not be available'
		);
		return $self->done(1);
	}

	my $keys = [values %{$vault->get($vault_seal_path)}];
	if (!@$keys) {
		info(
			'[[  - >>#Yr{[#@{!} warning]}: No vault unseal keys found at '.
			'[#C{%s}:key[1-N]] - '.
			'automatic unseal will not be available',
			$vault_seal_path
		);
		return $self->done(1);
	}

	info(
		'[[  - >>#g{[#@{+} success]}: Found %d vault unseal keys at '.
		'[#C{%s}:key[1-N]] - '.
		'automatic unseal will be available after deployment',
		scalar(@$keys), $vault_seal_path
	);
	mkfile_or_fail($ENV{GENESIS_PREDEPLOY_DATAFILE}, join("\n", @$keys));

	return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
