#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::New::Vault v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use Genesis qw/bail info run/;
use Genesis::UI qw/prompt_for/;
use parent qw(Genesis::Hook);
use lib $ENV{GENESIS_LIB} // "$ENV{HOME}/.genesis/lib";

sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;

  # Ask if this is the Genesis Vault (for storing deployment credentials)
  my $genesis_vault;
  prompt_for('genesis_vault', 'boolean',
    'Is this your Genesis Vault (for storing deployment credentials)?',
    \$genesis_vault);

  # Create the environment file
  my $env_file = "$ENV{GENESIS_ROOT}/$ENV{GENESIS_ENVIRONMENT}.yml";
  open my $fh, '>', $env_file or bail("Cannot open $env_file for writing: $!");

  # Write the environment file content
  print $fh "---\n";
  print $fh "kit:\n";
  print $fh "  name:    $ENV{GENESIS_KIT_NAME}\n";
  print $fh "  version: $ENV{GENESIS_KIT_VERSION}\n";
  print $fh "\n";

  # Get the genesis_config_block
  my ($out, $rc) = run('genesis_config_block');
  print $fh $out;

  # Add auxiliary_vault param if not a genesis vault
  if ($genesis_vault ne "true") {
    print $fh "params:\n";
    print $fh "  auxiliary_vault: true\n";
  } else {
    print $fh "params: {}\n";
  }

  close $fh;

  # Offer to open the environment file in an editor
  run({ interactive => 1 }, 'offer_environment_editor');

  return $self->done();
}

1;
