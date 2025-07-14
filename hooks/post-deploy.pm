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
	unless ($ENV{GENESIS_DEPLOY_RC} == 0) {
		info("#R{Deployment failed} - skipping post-deploy actions");
		return $self->done(1);
	}

	info("");
	info("#M{$ENV{GENESIS_ENVIRONMENT}} Vault deployed successfully!");
	info("");

	# Check if this is an auxiliary vault
	if ($self->env->lookup('params.auxiliary_vault', '') eq "true") {
		info("This is an auxiliary vault deployment - skipping automatic unseal");
		info("");
		info("To unseal this vault, run:");
		info("  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}");
		return $self->done(1);
	}

	# Check if we have pre-deploy data for automatic unsealing
	if (-s $ENV{GENESIS_PREDEPLOY_DATAFILE}) {
		info("Found seal keys from pre-deploy, attempting automatic unseal...");

		# Read the seal keys from the datafile
		my $keys_content;
		if (open my $fh, '<', $ENV{GENESIS_PREDEPLOY_DATAFILE}) {
			local $/;
			$keys_content = <$fh>;
			close $fh;

			# Validate we have content
			if ($keys_content && $keys_content =~ /\S/) {
				my @keys = split(/\n/, $keys_content);
				my $key_count = grep { /\S/ } @keys;

				info("Using $key_count seal keys for unsealing...");

				# Unseal the vault using the keys
				my ($unseal_out, $unseal_rc) = run(
					{ stdin => $keys_content, stderr => 1 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'unseal'
				);

				if ($unseal_rc == 0) {
					info("#G{✓ Vault unsealed successfully!}");

					# Display vault status
					info("");
					info("Vault status:");
					run({ interactive => 1 },
						'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'status'
					);
				} else {
					info("#R{✗ Failed to unseal vault automatically}");
					info("Error output: $unseal_out") if $unseal_out;
					info("");
					info("You can try to unseal manually with:");
					info("  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}");
				}
			} else {
				info("#Y{WARNING:} Seal key file is empty");
				_show_manual_instructions();
			}
		} else {
			info("#R{ERROR:} Could not read seal keys from $ENV{GENESIS_PREDEPLOY_DATAFILE}: $!");
			_show_manual_instructions();
		}

		# Clean up the datafile
		unlink $ENV{GENESIS_PREDEPLOY_DATAFILE} if -e $ENV{GENESIS_PREDEPLOY_DATAFILE};
	} else {
		info("No seal keys found from pre-deploy phase");
		_show_manual_instructions();
	}

	info("");
	info("For details about the deployment, run:");
	info("  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}");
	info("");

	# Check if KV versioning needs to be enabled
	_check_kv_versioning($self);

	return $self->done(1);
}

sub _show_manual_instructions {
	info("");
	info("Unable to automatically unseal the vault.");
	info("");
	info("If this is a #Y{new deployment}, you need to initialize it first:");
	info("  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- init}");
	info("");
	info("If this is an #Y{existing deployment}, you need to unseal it manually:");
	info("  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}");
}

sub _check_kv_versioning {
	my ($self) = @_;

	# Only check if we can authenticate
	my ($auth_check, $auth_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'auth', 'status'
	);

	return unless $auth_rc == 0;

	my ($out, $rc) = run({ stderr => 0 },
		'safe', 'vault', 'secrets', 'list', '--detailed'
	);

	if ($rc == 0 && $out =~ /^secret\/.*map\[version:1\]/m) {
		info("---");
		info("");
		info("#Y{KV Version 2 Available}");
		info("");
		info("This Vault supports versioned secrets, but the 'secret/' mount");
		info("is still using version 1. To enable versioning, run:");
		info("");
		info("  #G{safe vault kv enable-versioning secret}");
		info("");
		info("You'll need to be authenticated with the root token.");
		info("");
		info("#Y{NOTE:} Once versioning is enabled, it cannot be disabled");
		info("      without recreating the secrets backend.");
		info("");
	}
}
# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
