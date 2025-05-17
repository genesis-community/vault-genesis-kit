#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::Addon::Vault::Init v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use Genesis qw/bail info run describe/;
use parent qw(Genesis::Hook::Addon);
use lib $ENV{GENESIS_LIB} // "$ENV{HOME}/.genesis/lib";
use JSON::PP;

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub cmd_details {
  return
  "Initialize a new Vault cluster, setting up a new set of seal keys and an initial root token.\n".
  "This should only be done once per deployment.\n";
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;

  # Check if we were called with the init command
  if ($self->{script} ne 'init') {
    bail("This addon only supports the 'init' command.");
  }

  $env->notify("");

  # Try to find a Vault node to initialize
  my ($out, $rc) = run('bosh vms --json | jq -r \'.Tables[0].Rows[] | (.ips)\'');
  my @ips = split(/\s+/, $out);

  foreach my $ip (@ips) {
    my ($curl_out, $curl_rc) = run(
      { stderr => 0 },
      'curl -Lsk ${CURLOPTS:-} -m${TIMEOUT:-3} https://' . $ip . ' >/dev/null 2>&1'
    );

    if ($curl_rc == 0) {
      describe("Attempting to #Y{initialize} Vault via node $ip");

      # Target the Vault node
      run('safe target https://' . $ip . ' -k ' . $env->name);

      # Initialize the Vault
      my ($init_out, $init_rc) = run({ interactive => 1 }, 'safe -T ' . $env->name . ' init');

      return $init_rc == 0 ? 1 : 0;
    }
  }

  bail("Could not find a valid Vault node to initialize.");
  return 0;
}

1;

