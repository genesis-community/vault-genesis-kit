#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::PostDeploy::Vault v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use Genesis qw/describe run/;
use parent qw(Genesis::Hook::PostDeploy);
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

  # Call the parent's perform method first to ensure base functionality
  $self->SUPER::perform();

  # Only proceed if deployment was successful
  if ($self->deploy_successful) {
    $env->notify("");
    describe("#M{$ENV{GENESIS_ENVIRONMENT}} Vault deployed!");
    $env->notify("");

    # Check if we have pre-deploy data for automatic unsealing
    if (-s "$ENV{GENESIS_PREDEPLOY_DATAFILE}" && $env->lookup('params.auxiliary_vault') ne "true") {
      $env->notify("Unsealing the vault...");

      # Unseal the vault using the keys from pre-deploy
      run(
        { interactive => 1 },
        'safe -T "$1" unseal < "$2"',
        $ENV{GENESIS_ENVIRONMENT},
        $ENV{GENESIS_PREDEPLOY_DATAFILE}
      );

      # Display vault status
      run(
        { interactive => 1 },
        'safe -T "$1" status',
        $ENV{GENESIS_ENVIRONMENT}
      );
    } else {
      # Provide instructions for manual initialization/unsealing
      describe(
        "Unable to unseal the vault.  If this is a new deployment, you will need to",
        "initalize the vault first.  To do so, run",
        "",
        "  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- init}",
        "",
        "If this was not the initial deployment of the Vault, you will need to unseal it:",
        "",
        "  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}"
      );
    }

    # Provide info command reminder
    describe(
      "",
      "For details about the deployment, run",
      "",
      "  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}",
      ""
    );

    # Check if KV versioning needs to be enabled
    my ($out, $rc) = run(
      { stderr => 0 },
      'safe vault secrets list --detailed | grep ^secret/ | grep -q \'map\[version:1\]\''
    );

    if ($rc == 0) {
      describe(
        "---",
        "",
        "This version of Vault supports versioning secrets, but it does not automatically",
        "update existing KV Secret Engine mounts.  To turn it on, you must run",
        "",
        "  #G{safe vault kv enable-versioning secret}",
        "",
        "You will need to be authorised with the root token, and have Vault v0.11.0 or",
        "higher installed locally to perform this.",
        "",
        "#Y{NOTE:} Once versioning is turned on for a secrets backend, it cannot be",
        "      turned off without deleting and recreating that backend.",
        ""
      );
    }
  }

  return $self->done();
}

1;

