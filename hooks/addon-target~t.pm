package Genesis::Hook::Addon::Vault::Target;

use v5.20;
use warnings; # Genesis min perl version is 5.20
use Genesis qw/bail info run describe/;
# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'./.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0-rc.20');
  return $obj;
}

sub cmd_details {
  return
  "Target the Vault and authenticate via a specified auth method (defaults to token).\n".
  "Usage: target [METHOD]\n";
}

sub perform {
  my ($self) = @_;
  my $env = $self->env;

  # Get the authentication method (default to 'token')
  my $method = $self->{args}[0] || 'token';

  $env->notify("");

  # Find the domain to connect to
  my $domain = $env->lookup('params.vault_domain', '');

  if (!$domain) {
    my ($out, $rc) = run(
      'bosh vms --json | jq -r \'.Tables[0].Rows[] | (.ips)\''
    );

    my $curl_opts = $ENV{CURLOPTS} || '';
    my $timeout = $ENV{TIMEOUT} || 3;

    for my $ip (split(/\s+/, $out)) {
      my ($curl_out, $curl_rc) = run(
        { stderr => 0 },
        'curl -Lsk ' . $curl_opts . ' -m' . $timeout . ' https://' . $ip . ' >/dev/null 2>&1'
      );

      if ($curl_rc == 0) {
        $domain = $ip;
        last;
      }
    }

    if (!$domain) {
      bail("Could not find a valid Vault IP to connect to.");
    }
  }

  # Target and authenticate to Vault
  my $env_name = $env->name;
  run('SAFE_TARGET=\'\' safe target https://' . $domain . ' -k ' . $env_name);
  run('safe -T ' . $env_name . ' auth ' . $method);

  # Check if authentication was successful
  my ($handshake_out, $handshake_rc) = run(
    { stderr => 0 },
    'safe -T ' . $env_name . ' read secret/handshake >/dev/null 2>&1'
  );

  if ($handshake_rc == 0) {
    describe("", "Retrieving #Y{status} of Vault");
    run('safe -T ' . $env_name . ' status');
    return $self->done(1);
  }

  describe("#R{Authentication Failed} (or secret/handshake doesn't exist)");

  return $self->done();
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
