# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
package Genesis::Hook::Info::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Info);

use Genesis qw/bail info run describe/;
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
  
  # Simple implementation matching bash version
  info("vault nodes:");
  
  my ($out, $rc, $err) = run('bosh', 'vms', '--json');
  bail("Failed to get VMs: $err") if $rc;
  
  my $data = decode_json($out);
  my @ips;
  
  if ($data->{Tables} && @{$data->{Tables}} && $data->{Tables}[0]{Rows}) {
    foreach my $row (@{$data->{Tables}[0]{Rows}}) {
      push @ips, split(/,/, $row->{ips}) if $row->{ips};
    }
  }
  
  foreach my $ip (@ips) {
    info("  https://$ip");
  }
  
  return $self->done();
}
# }}}

1;
