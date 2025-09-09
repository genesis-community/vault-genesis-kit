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

  # Cloud Config checks
  if ($ENV{GENESIS_CLOUD_CONFIG}) {
    unless ($self->has_feature('proto')) {
      $self->start_check("Checking cloud config");

      my @errors;

      # Check required cloud config resources
      push @errors, $self->env->missing_cloud_config_keys(
        vm_type   => [$self->env->lookup('params.vault_vm_type',   'default')],
        network   => [$self->env->lookup('params.vault_network',   'vault')],
        disk_type => [$self->env->lookup('params.vault_disk_type', 'default')]
      );

      # Azure-specific checks
      if ($self->env->cpi eq 'azure') {
        push @errors, $self->env->missing_cloud_config_keys(
          vm_extension => [$self->env->lookup('params.azure_availability_set', 'vault_as')]
        );
      }

      if (@errors) {
        $self->check_result(0, join("\n", @errors));
        $ok = 0;
      } else {
        $self->check_result(1);
      }
    }
  }

  return $self->done($ok);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
