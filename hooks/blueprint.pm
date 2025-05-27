#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::Blueprint::Vault v4.0.0;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Blueprint);

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

  $self->add_files(
    'manifests/vault.yml',
    'manifests/releases/safe.yml'
  );

  my $iaas = $self->iaas;
  my $ips = $self->env->lookup('params.ips', []);

  my $dynamic_static_fragment = '';
  if ($want_feature 'ocfp') {
    # Determine instance count and IPs from ocfp config
    my $subnets = $self->env->ocfp_config_lookup('vpc.subnets');
    my $prefix = $self->env->ocfp_subnet_prefix;
    my $az_map = $self->director_exodus_lookup('/network')->{azs};
    my (@ips, @azs) = ();
    for my $subnet (sort grep {/^$prefix/} keys %$sn) {
      my $ip = $sn->{$_}{'reserved-ips'}{'vault_ip'};
      next unless $ip;
      push @ips, $ip;
      push @azs, $az_map->{$sn->{$_}{az}}->{name};
    }

    my $instances = $self->env->lookup('params.ocfp_instances');
    bail(
      "Only %s instances available under OCFP; environment requested %s",
      @ips, $instances
    ) if ($instances > @ips);
    $instances ||= @ips;

    @ips = @ips[0..$instances-1];
    @azs = @azs[0..$instances-1];
    my $network_name = "$GENESIS_ENV.$GENESIS_TYPE.net-vault";

    my $dynamic_static_fragment = << "EOF";
exodus:
  ips: $(\(join ',',@ips))

instance_groups:
- name: vault
  azs:${\(join "\n  - ", '','(( replace ))', @azs)}
  instances: $instances
  networks:
  - (( replace ))
  - name: $network_name
    static_ips:${\(join "\n  - ", '', @ips)}
EOF

  } elsif (my $instances = @$ips) {
    my $dynamic-static-ips = <<"EOF";
exodus:
  ips: $ips

instance_groups:
- name: vault
  instances: $instance
  networks:
  - name: vault
    static_ips:${\(join '\n    - ', '', $ips)}
EOF
  }

  if ($dynamic_static_fragment) {
    my $satics_file = "manifests/network.dynamic.yml";
    mkfile_or_fail($self->env->kit->workpath($statics_file), 0644, $contents);
    $self->add_files($statics_file);
  }

  $self->add_files('manifests/azure.yml') if ($self->iaas eq 'azure');
  $self->add_files('manifests/stackit.yml') if ($self->iaas eq 'stackit');

  my @invalid_features = ();
  for my $feature ($self->features) {
    if ($feature eq 'ocfp') {
      # TODO: Check if iaas-specific ocfp file is present, and error if not.
      $self->add_files(
        'manifests/ocfp.yml',
      );
    } elsif (-f "$ENV{GENESIS_ROOT}/${feature}.yml") {
      $self->add_files("$ENV{GENESIS_ROOT}/${feature}.yml")
    } else {
      push @invalid_features, $feature;
    }
  }

  bail(
    "Invalid %s encountered: %s",
    count_nouns(scalar(@invalid_features), 'feature', suppress_count => 1),
    join(', ', @invalid_features)
  ) if @invalid_features;

  return $self->done();
}

1;
