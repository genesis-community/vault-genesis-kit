package Genesis::Hook::Info::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info run/;
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

	my ($data, $rc, $stderr) = read_json_from($self->env->bosh->execute(
			{interactive => 0}, 'bosh', 'vms', '--json'
		));
  bail("Failed to get VMs: $stderr") if $rc;

  info("Vault Nodes:");
  my @ips;
	for my $row ($data->{Tables}[0]{Rows}->@*) {
		next unless $row->{ips};
		info("  https://%s", split(/,/, $row->{ips}) );
	}
  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
