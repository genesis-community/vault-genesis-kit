# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
package Genesis::Hook::PostDeploy::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info run describe/;

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
    describe("#M{$ENV{GENESIS_ENVIRONMENT}} Vault deployed!");
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
    
    describe(
      "",
      "For details about the deployment, run",
      "",
      "  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}",
      ""
    );
    
    # Check if KV versioning needs to be enabled
    my ($out, $rc) = run({ stderr => 0 },
      'safe', 'vault', 'secrets', 'list', '--detailed'
    );
    
    if ($rc == 0 && $out =~ /^secret\/.*map\[version:1\]/m) {
      describe(
        "--",
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
# }}}

1;

