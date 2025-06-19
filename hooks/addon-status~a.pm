package Genesis::Hook::Addon::Vault::Status;

use v5.20;
use warnings; # Genesis min perl version is 5.20
use Genesis qw/bail info run/;
# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'./.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
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

  $env->notify("");

  # Run the safe status command on the targeted Vault
  run(
    { interactive => 1 },
    'safe -T ' . $env->name . ' status'
  );

  return $self->done();
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
