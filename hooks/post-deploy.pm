package Genesis::Hook::PostDeploy::Vault;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info run slurp lines/;
use Service::Vault;
use JSON::PP;

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

	# Check if we have pre-deploy data for automatic unsealing
	my $lines = lines(run("safe -T $ENV{GENESIS_ENVIRONMENT} status 2>/dev/null | grep 'is sealed'"));
	if ($lines) {
		info("Vault is currently #Y{sealed} - unsealing is required to access secrets");
		if (-s $ENV{GENESIS_PREDEPLOY_DATAFILE}) {
			info("Found unseal keys from pre-deploy, attempting automatic unseal...");
			my $ok = run({interactive => 1, passfail => 1},
				"safe -T $ENV{GENESIS_ENVIRONMENT} unseal < $ENV{GENESIS_PREDEPLOY_DATAFILE}"
			);
			if (!$ok) {
				info(
					"  #R{\@{x} Failed to unseal vault automatically}\n\n".
					"You can try to unseal manually with:\n".
					"  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}");
			} else {
				info("  #g{#\@{+} Vault unsealed successfully!}");
			}
		} else {
			info("No pre-deploy seal keys found - cannot unseal automatically");
			$self->_show_manual_instructions;
		}
	} else {
		info("Vault is currently #G{unsealed} - no further action is needed");
	}

	# Check if this is the first deployment and auto-initialize if needed
	$self->_auto_init_if_needed();

	# Setup doomsday approle if vault is initialized and unsealed
	$self->_setup_doomsday_approle();

	info(
		"\nFor details about the deployment, run:\n".
		"  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}\n"
	);

	# Check if KV versioning needs to be enabled
	$self->_check_kv_versioning();

	return $self->done(1);
}

sub _show_manual_instructions {
	info(
		"\nUnable to automatically unseal the vault.".
		"\nIf this is a #Y{new deployment}, you need to initialize it first:\n".
		"  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- init}".
		"\nIf this is an #Y{existing deployment}, you need to unseal it manually:\n".
		"  #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}\n"
	)
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
		info(
			"---\n\n".
			"#Y{KV Version 2 Available}\n\n".
			"This Vault supports versioned secrets, but the 'secret/' mount\n".
			"is still using version 1. To enable versioning, run:\n\n".
			"[[  >>#G{safe vault kv enable-versioning secret}\n\n".
			"You'll need to be authenticated with the root token.\n\n".
			"[[#Y{NOTE:} >>Once versioning is enabled, it cannot be disabled".
			"without recreating the secrets backend.\n"
		);
	}
}

sub _setup_doomsday_approle {
	my ($self) = @_;

	# Check if vault is initialized and unsealed
	my ($status_out, $status_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'status'
	);

	# Parse status to check if initialized and unsealed
	return unless $status_rc == 0;
	return if $status_out =~ /Initialized\s+false/;
	return if $status_out =~ /Sealed\s+true/;

	# Check if we can authenticate (need to be authenticated to create approles)
	my ($auth_check, $auth_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'auth', 'status'
	);

	unless ($auth_rc == 0) {
		info("Skipping doomsday approle setup - not authenticated with vault");
		return;
	}

	info("");
	info("Setting up doomsday monitoring approle...");

	# Enable approle auth if not already enabled
	my ($enable_out, $enable_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'auth', 'enable', 'approle', '2>&1', '||', 'true'
	);

	if ($enable_out =~ /Success\! Enabled approle auth method/ || $enable_out =~ /path is already in use/) {
		info("#G{[ok]} AppRole auth enabled");
	} else {
		info("#Y{WARNING:} Could not enable approle auth: $enable_out");
		return;
	}

	# Check if doomsday approle already exists
	my ($list_out, $list_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'list', '-format=json', 'auth/approle/role'
	);

	if ($list_rc == 0 && $list_out) {
		eval {
			require JSON::PP;
			my $roles = JSON::PP::decode_json($list_out);
			if (ref($roles) eq 'ARRAY' && grep { $_ eq 'doomsday' } @$roles) {
				my ($exodus_id, $id_rc) = run({ stderr => 0 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', $ENV{GENESIS_EXODUS_MOUNT} . ':doomsday_approle_id'
				);
				my ($exodus_secret, $secret_rc) = run({ stderr => 0 },
					'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', $ENV{GENESIS_EXODUS_MOUNT} . ':doomsday_approle_secret'
				);

				if ($id_rc == 0 && $secret_rc == 0 && $exodus_id && $exodus_secret) {
					info("#G{[ok]} Doomsday approle already exists with credentials in exodus");
					return;
				}
			}
		};
	}

	# Create doomsday read-only policy
	info("Creating doomsday read-only policy...");

	my $policy = <<'EOF';
# Read-only access for doomsday monitoring
path "sys/health" {
	capabilities = ["read"]
}

path "sys/seal-status" {
	capabilities = ["read"]
}

path "sys/host-info" {
	capabilities = ["read"]
}

path "sys/mounts" {
	capabilities = ["read", "list"]
}

path "sys/auth" {
	capabilities = ["read", "list"]
}

# Allow listing all paths to discover what's available
path "*" {
	capabilities = ["list"]
}

# Read-only access to all secrets
path "secret/*" {
	capabilities = ["read", "list"]
}

path "secret/data/*" {
	capabilities = ["read", "list"]
}

path "secret/metadata/*" {
	capabilities = ["read", "list"]
}
EOF

	my ($policy_rc) = run({ stdin => $policy, stderr => 1 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'policy', 'write', 'doomsday', '-'
	);

	unless ($policy_rc == 0) {
		info("#R{ERROR:} Failed to create doomsday policy");
		return;
	}
	info("#G{[ok]} Doomsday policy created");

	# Create doomsday approle
	info("Creating doomsday approle...");

	my ($create_rc) = run({ stderr => 1 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'set',
		'auth/approle/role/doomsday',
		'secret_id_ttl=0',
		'token_num_uses=0',
		'token_ttl=1h',
		'token_max_ttl=24h',
		'secret_id_num_uses=0',
		'policies=doomsday'
	);

	unless ($create_rc == 0) {
		info("#R{ERROR:} Failed to create doomsday approle");
		return;
	}

	# Get role ID
	my ($role_id, $role_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', 'auth/approle/role/doomsday/role-id:role_id'
	);

	unless ($role_rc == 0 && $role_id) {
		info("#R{ERROR:} Failed to get doomsday role ID");
		return;
	}

	# Generate secret ID
	my ($secret_id, $secret_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'write', '-field=secret_id', '-f',
		'auth/approle/role/doomsday/secret-id'
	);

	unless ($secret_rc == 0 && $secret_id) {
		info("#R{ERROR:} Failed to generate doomsday secret ID");
		return;
	}

	# Store in exodus
	info("Storing doomsday approle credentials in exodus...");

	chomp($role_id);
	chomp($secret_id);

	my ($store_rc) = run({ stderr => 1 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'set',
		$ENV{GENESIS_EXODUS_MOUNT},
		"doomsday_approle_id=$role_id",
		"doomsday_approle_secret=$secret_id"
	);

	if ($store_rc == 0) {
		info("#G{#@{+} Doomsday approle created successfully!}");
		info("  Credentials stored in exodus at: $ENV{GENESIS_EXODUS_MOUNT}");
		info("  - doomsday_approle_id");
		info("  - doomsday_approle_secret");
	} else {
		info("#R{ERROR:} Failed to store doomsday credentials in exodus");
	}
}

sub _auto_init_if_needed {
	my ($self) = @_;

	# Check if vault is initialized
	my ($status_out, $status_rc) = run({ stderr => 0 },
		'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'status'
	);

	# If we can't get status, try to find a reachable vault node
	if ($status_rc != 0) {
		# Get VMs to find vault IPs
		my ($out, $rc) = run({ stderr => 0 },
			'bosh', '-e', $self->env->bosh->alias, '-d', $self->env->bosh->deployment,
			'vms', '--json'
		);

		if ($rc == 0 && $out) {
			eval {
				require JSON::PP;
				my $data = JSON::PP::decode_json($out);
				my @ips = map {$_->{ips}} @{$data->{Tables}[0]{Rows}};

				# Try to target a vault node
				foreach my $ip (@ips) {
					my ($target_out, $target_rc) = run({ stderr => 0 },
						'safe', 'target', "https://$ip", '-k', $ENV{GENESIS_ENVIRONMENT}
					);

					if ($target_rc == 0) {
						# Try status again
						($status_out, $status_rc) = run({ stderr => 0 },
							'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'vault', 'status'
						);
						last if $status_rc == 0;
					}
				}
			};
		}
	}

	# Parse status to check if initialized
	if ($status_rc == 0 && $status_out =~ /Initialized\s+false/) {
		info("");
		info("Detected #Y{uninitialized Vault} - running automatic initialization...");

		# Run the init addon using the Hook system
		require Genesis::Hook::Addon::Vault::Init;
		my $init_hook = Genesis::Hook::Addon::Vault::Init->init(
			kit => $self->{kit},
			env => $self->{env},
			command => 'init',
			args => []
		);

		my $init_rc = $init_hook->perform();

		if ($init_rc) {
			info("#G{#@{+} Vault initialized successfully!}");

			# The init addon stores seal keys, so we should be able to unseal now
			# Check if we have seal keys stored
			my ($check_out, $check_rc) = run({ stderr => 0 },
				'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'exists', 'secret/vault/seal/keys'
			);

			if ($check_rc == 0) {
				info("");
				info("Attempting to unseal the newly initialized vault...");

				# Get seal keys and unseal
				my @keys;
				for (my $i = 1; $i <= 5; $i++) {
					my ($key_out, $key_rc) = run({ stderr => 0 },
						'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'get', "secret/vault/seal/keys:key$i"
					);
					if ($key_rc == 0 && $key_out) {
						chomp($key_out);
						push @keys, $key_out;
					}
				}

				if (@keys) {
					my $keys_content = join("\n", @keys);
					my ($unseal_out, $unseal_rc) = run(
						{ stdin => $keys_content, stderr => 1 },
						'safe', '-T', $ENV{GENESIS_ENVIRONMENT}, 'unseal'
					);

					if ($unseal_rc == 0) {
						info("#G{#@{+} Vault unsealed successfully!}");
					} else {
						info("#Y{WARNING:} Failed to unseal vault automatically");
						info("You can unseal manually with: #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- unseal}");
					}
				}
			}
		} else {
			info("#R{ERROR:} Automatic initialization failed");
			info("You can initialize manually with: #G{genesis do $ENV{GENESIS_ENVIRONMENT} -- init}");
		}
	}
}
# }}}

1;

# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
