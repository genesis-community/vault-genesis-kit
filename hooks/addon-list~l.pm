package Genesis::Hook::Addon::Vault::List;

# TODO: Isn't `list` now handled by Genesis itself?
use v5.20;
use warnings; # Genesis min perl version is 5.20
use Genesis qw/bail info/;
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
  "Lists all available Vault addons and their purposes.\n";
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;

  $env->notify("The following addons are defined:");
  $env->notify("");
  $env->notify("  init     Initialize a new Vault cluster, setting up a");
  $env->notify("           new set of seal keys, and an initial root token.");
  $env->notify("           This should only be done once per deployment.");
  $env->notify("");
  $env->notify("  target   Target the Vault and authenticate via root token.");
  $env->notify("");
  $env->notify("  status   Determine Vault status: health, availability,");
  $env->notify("           and sealed / unsealed state.");
  $env->notify("");
  $env->notify("  seal     Seal the Vault.");
  $env->notify("");
  $env->notify("  unseal   Unseal the Vault.");
  $env->notify("");

  return $self->done();
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
