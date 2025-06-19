package Genesis::Hook::PostDeploy::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info run/;

# init - Initialize the hook {{{
sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;

  # Only proceed if deployment was successful
  if ($ENV{GENESIS_DEPLOY_RC} == 0) {
    info("");
    info("#M{$ENV{GENESIS_ENVIRONMENT}} Vault deployed!");
    info("");

    # Check if we have pre-deploy data for automatic unsealing
    if (-s $ENV{GENESIS_PREDEPLOY_DATAFILE} && $self->env->lookup('params.auxiliary_vault', '') ne "true") {
      info("Unsealing the vault...");

      # Unseal the vault using the keys from pre-deploy
      run({ interactive => 1 },
        'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'unseal',
        { stdin => $ENV{GENESIS_PREDEPLOY_DATAFILE} }
      );

      # Display vault status
      run({ interactive => 1 },
        'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'status'
      );
    } else {
      info(
        "Unable to unseal the vault.  If this is a new deployment, you will need to\n".
        "initalize the vault first.  To do so, run\n\n".
        "  #G{genesis do %s -- init}\n\n".
        "If this was not the initial deployment of the Vault, you will need to unseal it:\n\n".
        "  #G{genesis do %s -- unseal}\n",
        $ENV{GENESIS_ENVIRONMENT}, $ENV{GENESIS_ENVIRONMENT}
      );
    }

    info(
      "\n".
      "For details about the deployment, run\n\n".
      "  #G{genesis info %s}\n\n",
      $ENV{GENESIS_ENVIRONMENT}
    );

    # Check if KV versioning needs to be enabled
    my ($out, $rc) = run({ stderr => 0 },
      'safe', 'vault', 'secrets', 'list', '--detailed'
    );

    if ($rc == 0 && $out =~ /^secret\/.*map\[version:1\]/m) {
      info(
        "---\n".
        "\n\n".
        "This version of Vault supports versioning secrets, but it does not automatically\n".
        "update existing KV Secret Engine mounts.  To turn it on, you must run\n".
        "\n".
        "  #G{safe vault kv enable-versioning secret}\n".
        "\n".
        "You will need to be authorised with the root token, and have Vault v0.11.0 or\n".
        "higher installed locally to perform this.\n".
        "\n".
        "#Y{NOTE:} Once versioning is turned on for a secrets backend, it cannot be\n".
        "      turned off without deleting and recreating that backend.\n"
      );
    }
  }

  return $self->done(1);
}
# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
