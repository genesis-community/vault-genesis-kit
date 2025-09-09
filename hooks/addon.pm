package Genesis::Hook::Addon::Vault v2.0.0;

use v5.20;
use warnings;

# allow loading your development libs
BEGIN {
  push @INC,
    $ENV{GENESIS_LIB}
      ? $ENV{GENESIS_LIB}
      : $ENV{HOME}.'/.genesis/lib'
}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/bail/;

# init — enforce a minimum Genesis version
sub init {
  my ($class, %ops) = @_;
  my $self = $class->SUPER::init(%ops);

  # match the version your individual files check against
  $self->check_minimum_genesis_version('3.1.0');
  return $self;
}
1;
