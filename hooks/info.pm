#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::Info::Vault v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use Genesis qw/bail info run describe/;
use parent qw(Genesis::Hook);
use lib $ENV{GENESIS_LIB} // "$ENV{HOME}/.genesis/lib";
use JSON::PP;

sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;

  # Display Vault deployment info header
  $env->notify("");
  describe("#B{Vault Deployment Information}");
  $env->notify("");

  # Get nodes information
  $self->display_vault_nodes();

  # Try to get Vault status information
  $self->display_vault_status();

  # Display deployment details
  $self->display_deployment_details();

  # Display usage instructions
  $self->display_usage_instructions();

  return $self->done();
}

sub display_vault_nodes {
  my ($self) = @_;
  my $env = $self->env;

  describe("Vault Nodes:");

  # Get IPs from BOSH VMs
  my ($out, $rc) = run('bosh vms --json | jq -r \'.Tables[0].Rows[] | (.ips)\'');

  if ($rc != 0) {
    describe("  #R{Could not retrieve Vault nodes from BOSH}");
    return;
  }

  my @ips = split(/\s+/, $out);
  if (@ips) {
    foreach my $ip (@ips) {
      describe("  #C{https://$ip}");
    }
  } else {
    describe("  #Y{No Vault nodes found}");
  }

  # Get custom domain if configured
  my $domain = $env->lookup('params.vault_domain', '');
  if ($domain) {
    $env->notify("");
    describe("Custom Domain:");
    describe("  #G{https://$domain}");
  }

  $env->notify("");
}

sub display_vault_status {
  my ($self) = @_;
  my $env = $self->env;

  describe("Vault Status:");

  # Try to get status from any available node
  my ($out, $rc) = run('bosh vms --json | jq -r \'.Tables[0].Rows[] | (.ips)\'');
  if ($rc != 0 || !$out) {
    describe("  #Y{Could not determine Vault status - no nodes found}");
    $env->notify("");
    return;
  }

  my @ips = split(/\s+/, $out);
  my $vault_status = undef;

  foreach my $ip (@ips) {
    # Try to get Vault status using safe
    my ($status_out, $status_rc) = run(
      { stderr => 0 },
      'SAFE_TARGET=\'\' safe target https://' . $ip . ' -k vault-status 2>/dev/null && ' .
      'safe -T vault-status status --json 2>/dev/null'
    );

    if ($status_rc == 0 && $status_out) {
      eval {
        $vault_status = decode_json($status_out);
      };
      last if $vault_status;
    }
  }

  if ($vault_status) {
    # Display sealed status
    my $sealed_status = $vault_status->{sealed} ? "#R{Sealed}" : "#G{Unsealed}";
    describe("  Sealed Status: $sealed_status");

    # Display initialized status
    my $init_status = $vault_status->{initialized} ? "#G{Initialized}" : "#R{Not Initialized}";
    describe("  Initialization: $init_status");

    # Display version if available
    if ($vault_status->{server_version}) {
      describe("  Version: #C{$vault_status->{server_version}}");
    }

    # Display HA status if available
    if (exists $vault_status->{ha_enabled}) {
      my $ha_status = $vault_status->{ha_enabled} ? "#G{Enabled}" : "#Y{Disabled}";
      describe("  High Availability: $ha_status");

      if ($vault_status->{ha_enabled}) {
        describe("  HA Mode: #C{$vault_status->{ha_mode}}") if $vault_status->{ha_mode};
      }
    }

    # Display key counts
    if (exists $vault_status->{n} && exists $vault_status->{t}) {
      describe("  Key Sharing: #C{$vault_status->{n}} keys, #C{$vault_status->{t}} threshold");
    }
  } else {
    describe("  #Y{Could not determine Vault status - authentication required}");
    describe("  #Y{Run:} #G{genesis do $env->{name} -- target} #Y{first, then try again}");
  }

  $env->notify("");
}

sub display_deployment_details {
  my ($self) = @_;
  my $env = $self->env;

  # Display auxiliary status
  my $auxiliary = $env->lookup('params.auxiliary_vault', 'false');
  if ($auxiliary eq "true") {
    describe("Deployment Type: #C{Auxiliary Vault}");
    describe("  #Y{This is an auxiliary Vault not used for Genesis credentials}");
  } else {
    describe("Deployment Type: #G{Genesis Vault}");
    describe("  #G{This Vault is configured to store Genesis credentials}");
  }

  $env->notify("");
}

sub display_usage_instructions {
  my ($self) = @_;
  my $env = $self->env;

  describe("#B{Available Commands}:");
  describe("  #G{genesis do $env->{name} -- init}        Initialize a new Vault");
  describe("  #G{genesis do $env->{name} -- target}      Target and authenticate to Vault");
  describe("  #G{genesis do $env->{name} -- status}      Check detailed Vault status");
  describe("  #G{genesis do $env->{name} -- unseal}      Unseal the Vault");
  describe("  #G{genesis do $env->{name} -- seal}        Seal the Vault");
  $env->notify("");
}

1;
