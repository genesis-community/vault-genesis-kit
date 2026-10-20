package Genesis::Hook::Addon::Vault::Status v2.0.0;

use v5.20;
use warnings; # Genesis min perl version is 5.20

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use Genesis qw/bail info run/;

use parent qw(Genesis::Hook::Addon);

# Include the shared seal-status and safe target helpers
BEGIN {
  require File::Basename;
  require File::Spec;
  my $mixin_file = File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/lib/_vault_cluster.pm';
  do $mixin_file or die "Failed to include addon mixin $mixin_file: " . ($@ || $! || 'unknown error');
}

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub cmd_details {
  return
  "Determine Vault status: health, availability, and sealed/unsealed state.\n";
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;

  info("");

  # Without strongbox, safe would only report on the one node the target points at
  my $cluster = $self->_vault_env_cluster($env->name);
  return $self->done(0)
    unless $self->_ensure_strongbox_target($env->name, @{$cluster->{reachable}});

  # Run the safe status command on the targeted Vault
  run(
    { interactive => 1 },
    'safe -T ' . $env->name . ' status'
  );

  return $self->done();
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
