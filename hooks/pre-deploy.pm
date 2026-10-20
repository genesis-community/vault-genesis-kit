package Genesis::Hook::PreDeploy::Vault v2.0.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info run load_json/;
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

	$self->_check_resolute_stemcells if $self->want_feature('resolute');

	# We're just grabbing the vault unseal keys for post-deploy unsealing
	my @matching_vaults = Service::Vault->find_by_target($self->env->name);
	return $self->done() unless @matching_vaults;
	my $vault = $matching_vaults[0];

	# A sealed or uninitialized Vault can't hand over its keys, and connecting
	# to one bails the deploy, so check every node before reading anything.
	# A deployment BOSH doesn't know yet has no nodes to list, so fall back
	# to the address the target points at.
	my @urls = $self->_vault_node_urls;
	(my $target_url = $vault->url // '') =~ s{/+$}{};
	@urls = ($target_url) if !@urls && $target_url ne '';
	my $cluster = $self->_vault_cluster(@urls);
	unless (@{$cluster->{serving}}) {
		info(
			'[[  - #Yr{#@{!} warning} >>no Vault node is both initialized and unsealed - '.
			'automatic unseal will not be available'
		);
		$self->_vault_report_nodes($cluster);
		return $self->done(1);
	}
	$self->env->notify(" #iu{pre-deploy}: Retrieving vault unseal keys for post-deploy unsealing");

	# Read through the target first.  When the node it points at is the one
	# that is sealed, read through a node that is serving instead.
	my $vault_seal_path = VAULT_SEAL_KEYS_PATH;
	my @keys = _vault_read_seal_keys(sub {$vault->query(@_)});
	for my $url (@{$cluster->{serving}}) {
		last if @keys;
		next if lc($url) eq lc($target_url);
		my $query = $self->_vault_node_query($vault->name, $url) or last;
		@keys = _vault_read_seal_keys($query);
		info('[[  - >>read the vault unseal keys through #M{%s}', $url) if @keys;
	}

	if (!@keys) {
		info(
			'[[  - #Yr{#@{!} warning} >>no vault unseal keys found at '.
			'[#C{%s}:key[1-N]] - '.
			'automatic unseal will not be available',
			$vault_seal_path
		);
		return $self->done(1);
	}

	info(
		'[[  - >>found %d vault unseal keys at '.
		'[#C{%s}:key[1-N]] - '.
		'automatic unseal will be available after deployment',
		scalar(@keys), $vault_seal_path
	);
	# Created 0600 from the start, so the keys are never readable by others,
	# even for the moment a chmod after the write would leave open.
	my $data_file = $ENV{GENESIS_PREDEPLOY_DATAFILE};
	unlink($data_file) if -e $data_file;
	my ($ok, $err) = _write_private_file($data_file, join("\n", @keys)."\n");
	unless ($ok) {
		info(
			'[[  - #Yr{#@{!} warning} >>could not save the vault unseal keys for '.
			'post-deploy (%s) - automatic unseal will not be available', $err
		);
	}

	return $self->done(1);
}
# }}}

# _check_resolute_stemcells - every stemcell must be ubuntu-resolute {{{
# The blueprint gate reads params only, so a stemcells override in an env
# file or a feature fragment can still slip another OS past it.  The merged
# manifest is the last word, so check that.  The manifest holds secrets, so
# its conversion is redacted from the trace log.
sub _check_resolute_stemcells {
	my ($self) = @_;
	my $file = $ENV{GENESIS_MANIFEST_FILE};
	bail(
		"The #c{resolute} feature is enabled, but Genesis did not pass the ".
		"manifest to the pre-deploy hook, so its stemcells cannot be checked."
	) unless defined($file) && -f $file && -r $file;

	my ($out, $rc, $err) = run({stderr => 0, redact_output => 1}, 'spruce json < "$1"', $file);
	my $manifest = $rc == 0 ? eval {load_json($out)} : undef;
	bail(
		"The #c{resolute} feature is enabled, but the manifest at #C{%s} could ".
		"not be read to check its stemcells: %s",
		$file, ($err // '') =~ s/\s+$//r || "spruce exited $rc"
	) unless ref($manifest) eq 'HASH';

	my $stemcells = $manifest->{stemcells};
	bail(
		"The #c{resolute} feature is enabled, but the manifest lists no stemcells."
	) unless ref($stemcells) eq 'ARRAY' && @$stemcells;

	my @wrong = map {
		ref($_) eq 'HASH'
			? sprintf("%s (#R{%s})", $_->{alias} // '?', $_->{os} // 'no os')
			: '#R{an entry that is not a stemcell}'
	} grep {
		ref($_) ne 'HASH' || ($_->{os} // '') ne 'ubuntu-resolute'
	} @$stemcells;
	bail(
		"The #c{resolute} feature is enabled, but the manifest deploys these ".
		"stemcells on another OS: %s.  Remove the override that sets them.",
		join(', ', @wrong)
	) if @wrong;
	return 1;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
