# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
package Genesis::Hook::Blueprint::Vault;

use v5.20;
use warnings; # Genesis min perl version is 5.20

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Blueprint);

use Genesis qw/bail info warning error mkfile_or_fail/;

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
  if ($self->want_feature('ocfp')) {
    # Determine instance count and IPs from ocfp config
    my $subnets = $self->env->ocfp_config_lookup('net.subnets');
    my $prefix = $self->env->ocfp_subnet_prefix;
    my $az_map = $self->env->director_exodus_lookup('/network')->{azs};

    my (@ips, @azs) = ();
    for my $subnet (sort grep {/^$prefix/} keys %$subnets) {
      my $ip = $subnets->{$subnet}{'reserved-ips'}{'vault_ip'};
      next unless $ip;
      push @ips, $ip;
      
      # Fetch AZ from vault based on environment type
      my $env_type = $self->env->type;
      my $az_path = sprintf("secret/config/%s/%s/net/subnets/%s:az",
        $self->env->ocfp_config_lookup('base'),
        $env_type,
        $subnet
      );
      
      my $az = eval { $self->env->vault->get($az_path) };
      if (!$az) {
        warning("Could not retrieve AZ for subnet %s from vault path %s", $subnet, $az_path);
        push @azs, undef;
      } else {
        push @azs, $az_map->{$az}{name} || undef;
      }
    }

    # FIXME: Should we error out if ips are explicitly stated in the env file?

    my $instances = $self->env->lookup('params.ocfp_instances') || @ips;
    bail(
      "Only %s instances available under OCFP; environment requested %s",
      @ips, $instances
    ) if $instances > @ips;

    @ips = @ips[0..$instances-1];
    @azs = @azs[0..$instances-1];
    my $network_name = "$ENV{GENESIS_ENVIRONMENT}.$ENV{GENESIS_TYPE}.net-vault";
    
    # Filter out undefined AZs and provide a default if all are undefined
    my @valid_azs = grep { defined $_ } @azs;
    if (!@valid_azs) {
      bail("No valid availability zones found for Vault instances");
    }

    $dynamic_static_fragment = << "EOF";
exodus:
  ips: ${\(join ',', @ips)}

instance_groups:
- name: vault
  azs:${\(join "\n  - ", '','(( replace ))', @valid_azs)}
  instances: $instances
  networks:
  - (( replace ))
  - name: $network_name
    static_ips:${\(join "\n    - ", '', @ips)}
EOF

  } elsif (my $instances = @$ips) {
    $dynamic_static_fragment = <<"EOF";
exodus:
  ips: ${\(join ',', @$ips)}

instance_groups:
- name: vault
  instances: $instances
  networks:
  - name: (( grab params.vault_network || "vault" ))
    static_ips:${\(join "\n    - ", '', @$ips)}
EOF
  }
  # TODO: What about ips that aren't specified or in OCFP?  What should go in exodus?

  if ($dynamic_static_fragment) {
    my $statics_file = "manifests/network.dynamic.yml";
    mkfile_or_fail($self->env->kit->path($statics_file), 0644, $dynamic_static_fragment);
    $self->add_files($statics_file);
  }

  $self->add_files('manifests/azure.yml') if ($self->iaas eq 'azure');

  my @invalid = ();
  for my $feature ($self->features) {
    if ($feature eq 'ocfp') {
      # TODO: Check if iaas-specific ocfp file is present, and error if not.
      $self->add_files(
        'manifests/ocfp.yml',
      );
    } elsif (-f "$ENV{GENESIS_ROOT}/${feature}.yml") {
      $self->add_files("$ENV{GENESIS_ROOT}/${feature}.yml")
    } else {
      push @invalid, $feature;
    }
  }

  bail(
    "Invalid %s encountered: %s",
    count_nouns(scalar(@invalid), 'feature', suppress_count => 1),
    join(', ', @invalid)
  ) if @invalid;

  return $self->done(1);
}

1;
