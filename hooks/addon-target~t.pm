package Genesis::Hook::Addon::Vault::Target v2.0.0;
use v5.20;
use warnings; # Genesis min perl version is 5.20

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use Genesis qw/bail info run read_json_from/;
use parent qw(Genesis::Hook::Addon);

# Include the shared seal-status and safe target helpers
BEGIN {
  require File::Basename;
  require File::Spec;
  my $mixin_file = File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/lib/_vault_cluster.pm';
  do $mixin_file or die "Failed to include addon mixin $mixin_file: " . ($@ || $! || 'unknown error');
}

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub cmd_details {
  return
    "Target the Vault and authenticate via a specified auth method (defaults to token), interactively if needed.\n"
  . "Usage: target [METHOD]\n";
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;
  my $env_name = $env->name;

  # Get the authentication method (default to 'token')
  my $method = $self->{args}[0] || 'token';
  info("Using auth method: $method");

  # Reuse the env's target when it has one, so its token survives, and give
  # it strongbox when it lacks it.  Otherwise create it.
  my $targets = _safe_targets();
  bail("safe could not list its targets") unless $targets;

  if ($targets->{$env_name}) {
    bail("Could not prepare the #C{%s} safe target", $env_name)
      unless $self->_ensure_strongbox_target($env_name);
  } else {
    my ($url, %opts) = $self->_new_target_url;
    info("Creating safe target #C{%s} at #M{%s}", $env_name, $url);
    bail("safe target failed")
      unless _safe_write_target($env_name, $url, %opts) == 0;
  }

  # Make it the current target, which is what this addon is for
  my (undef, $t_rc, $t_err) = run({ stderr=>0, env=>_safe_env() }, 'safe', 'target', $env_name);
  bail("safe target failed: %s", $t_err || "exit $t_rc") if $t_rc;

  # Authenticate (interactive if needed)
  my $auth_cmd = "safe -T $env_name auth $method";
  info("Running: $auth_cmd");
  # interactive auth, capture exit code
  my (undef, $auth_rc) = run({ interactive => 1 }, 'safe', '-T', $env_name, 'auth', $method);
  if ($auth_rc != 0) {
    info("Authentication failed (exit code $auth_rc)");
    return $self->done(0);
  }


  # Verify handshake & status
  my (undef, $h_rc) = run({ stderr=>0 }, 'safe', '-T', $env_name, 'read', 'secret/handshake');
  if ($h_rc == 0) {
    info("Vault is successfully targeted and authenticated.");
    return $self->done(1);
  }

  info("Authentication failed or secret/handshake missing");
  return $self->done(0);
}

# _new_target_url - where a new target points, and how it verifies TLS {{{
# The kit's certificate names params.vault_domain, so a target at that name
# verifies against the kit CA.  Without a domain the target has to use a node
# address, which the certificate doesn't name, so it skips verification.
sub _new_target_url {
  my ($self) = @_;
  my $env = $self->env;

  my $domain = $env->lookup('params.vault_domain', '');
  if ($domain) {
    my $ca = eval { $self->vault->get($env->secrets_base . 'certs/ca', 'certificate') } // '';
    return ("https://$domain", ca_certs => [$ca]) if $ca =~ /BEGIN CERTIFICATE/;
    info(
      "#Y{WARNING:} Could not read the kit CA at #C{%scerts/ca}, so the target will not verify TLS",
      $env->secrets_base
    );
    return ("https://$domain", insecure => 1);
  }

  my @urls = $self->_vault_node_urls;
  bail("No Vault VMs found") unless @urls;
  my $cluster = $self->_vault_cluster(@urls);
  my ($url) = (@{$cluster->{serving}}, @{$cluster->{reachable}});
  bail("Could not find a valid Vault IP to connect to.") unless $url;
  return ($url, insecure => 1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
