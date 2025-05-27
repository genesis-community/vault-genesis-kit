#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::PreDeploy::Vault v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use Genesis qw/bail info run/;
use parent qw(Genesis::Hook);
use lib $ENV{GENESIS_LIB} // "$ENV{HOME}/.genesis/lib";
use File::Basename qw/dirname/;
use File::Path qw/make_path/;

sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;
  my $datafile = $ENV{GENESIS_PREDEPLOY_DATAFILE};

  # Ensure datafile directory exists
  make_path(dirname($datafile)) unless -d dirname($datafile);

  # Check if this environment exists as a safe target
  my ($out, $rc) = run(
    { stderr => 0 },
    'safe targets --json | jq -e --arg alias "$1" \'.[] |select(.name == $alias)\' &>/dev/null',
    $ENV{GENESIS_ENVIRONMENT}
  );

  if ($rc == 0) {
    # Try to retrieve vault seal keys
    my $i = 1;
    open my $fh, '>', $datafile or bail("Cannot open $datafile for writing: $!");

    while (1) {
      # Check if the key exists
      my ($exists_out, $exists_rc) = run(
        { stderr => 0 },
        'safe exists "secret/vault/seal/keys:key' . $i . '"'
      );

      last if $exists_rc != 0;  # Stop if key doesn't exist

      # Read the key value and write to datafile
      my ($key_out, $key_rc) = run(
        { stderr => 0 },
        'safe -T "$1" read "secret/vault/seal/keys:key' . $i . '"',
        $ENV{GENESIS_ENVIRONMENT}
      );

      print $fh $key_out;
      $i++;
    }

    close $fh;

    # Remove empty datafile
    if (-z $datafile) {
      unlink $datafile;
    }
  }

  return $self->done();
}

1;
