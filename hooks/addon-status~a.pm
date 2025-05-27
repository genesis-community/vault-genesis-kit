#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::Addon::Vault::Status v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use Genesis qw/bail info run/;
use parent qw(Genesis::Hook::Addon);
use lib $ENV{GENESIS_LIB} // "$ENV{HOME}/.genesis/lib";

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
