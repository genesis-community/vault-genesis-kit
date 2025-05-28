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
      info(
        "\nUnable to unseal the vault.  If this is a new deployment, you will need to\n",
        "\ninitalize the vault first.  To do so, run\n",
        "\t#G{genesis do $ENV{GENESIS_ENVIRONMENT} -- init}\n",
        "\nIf this was not the initial deployment of the Vault, you will need to unseal it:\n",
        "\t#G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}"
      );
    }

    # Provide info command reminder
    info(
      "\n\nFor details about the deployment, run\n",
      "\t#G{genesis info $ENV{GENESIS_ENVIRONMENT}}\n\n",
    );

    # Check if KV versioning needs to be enabled
    my ($out, $rc) = run(
      { stderr => 0 },
      'safe vault secrets list --detailed | grep ^secret/ | grep -q \'map\[version:1\]\''
    );

    if ($rc == 0) {
      info(
        "---",
        "",
        "\n\nThis version of Vault supports versioning secrets, but it does not automatically",
        "\update existing KV Secret Engine mounts.  To turn it on, you must run",
        "\t#G{safe vault kv enable-versioning secret}",
        "\n\nYou will need to be authorised with the root token, and have Vault v0.11.0 or",
        "\nhigher installed locally to perform this.",
        "\n#Y{NOTE:} Once versioning is turned on for a secrets backend, it cannot be\n",
        "\tturned off without deleting and recreating that backend.\n\n",
      );
    }
  }

  return $self->done();
}

1;

