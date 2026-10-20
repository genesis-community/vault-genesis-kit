package Genesis::Hook::Check::Vault v2.0.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Check);

use Genesis qw/info/;

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
  my $ok = 1;

  # Cloud Config checks.  An OCFP environment gets a generated cloud config
  # that the cloud-config hook uploads before the deploy, so there is nothing
  # to look up in the one the Director holds now.
  if ($ENV{GENESIS_CLOUD_CONFIG} && !$self->want_feature('ocfp')) {
    $self->start_check('cloud-config');

    if (!$self->env->has_config('cloud')) {
      $ok = 0 unless $self->check_result('cloud-config', 'failed', 'no cloud config found');
    } else {
      $self->has_entry('cloud-config', 'vm_type',
        $self->env->lookup('params.vault_vm_type', 'default'));
      $self->has_entry('cloud-config', 'network',
        $self->env->lookup('params.vault_network', 'vault'));
      $self->has_entry('cloud-config', 'disk_type',
        $self->env->lookup('params.vault_disk_type',
          $self->env->lookup('params.vault_disk_pool', 'default')));

      if ($self->iaas eq 'azure') {
        $self->has_entry('cloud-config', 'vm_extension',
          $self->env->lookup('params.azure_availability_set', 'vault_as'));
      }

      $ok = 0 unless $self->check_result('cloud-config');
    }
  }

  return $self->done($ok);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
