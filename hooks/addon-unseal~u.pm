package Genesis::Hook::Addon::Vault::Unseal v2.0.0;

use v5.20;
use warnings; # Genesis min perl version is 5.20

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use Genesis qw/bail info run/;

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
	"Unseal the Vault, making it available for use.\n".
	"If seal keys are stored in the vault, they will be used automatically.\n".
	"Otherwise, you will need to provide the unseal keys when prompted.\n";
}

sub perform {
	my ($self) = @_;
	my $env = $self->env;

	info("");

	# safe only reaches every node through strongbox, so make sure the target
	# uses it before anything is unsealed through it.
	my $cluster = $self->_vault_env_cluster($env->name);
	my $target = $self->_ensure_strongbox_target($env->name, @{$cluster->{reachable}});

	# First check if every node is already unsealed.  Each node answers for
	# itself, so this needs no token, no strongbox, and no vault binary.
	unless (@{$cluster->{nodes}}) {
		info("#R{✗ BOSH lists no Vault nodes for this deployment, and there is no safe target for it}");
		return $self->done(0);
	}
	if (!@{$cluster->{sealed}} && !@{$cluster->{unreachable}}) {
		info("#G{✓ Vault is already unsealed}");
		info("");
		$self->_vault_report_nodes($cluster);
		return $self->done(1);
	}
	unless ($target) {
		info("#R{✗ No usable safe target named} #C{".$env->name."}#R{, so nothing can be unsealed}");
		$self->_vault_report_nodes($cluster);
		return $self->done(0);
	}

	# Try to retrieve seal keys automatically
	my $keys_found = 0;
	my $keys_content = '';

	info("Checking for stored seal keys...");

	# Check if we can access the vault's seal keys
	my ($check_auth, $auth_rc) = run({ stderr => 0 },
		'safe', '-T', $env->name, 'auth', 'status'
	);

	if ($auth_rc == 0) {
		# We're authenticated, try to get seal keys
		my @keys;
		my $errors = 0;

		for (my $i = 1; $i <= 10; $i++) {
			my $key_path = "secret/vault/seal/keys:key$i";

			# Check if key exists
			my ($exists_out, $exists_rc) = run({ stderr => 0 },
				'safe', '-T', $env->name, 'exists', $key_path
			);

			last if $exists_rc != 0;

			# Read the key value
			my ($key_data, $read_rc) = run({ stderr => 0, redact_output => 1 },
				'safe', '-T', $env->name, 'get', $key_path
			);

			if ($read_rc == 0 && $key_data) {
				# `safe get path:key` prints the bare value
				my $key_value = $key_data;
				$key_value =~ s/^\s+|\s+$//g;

				# Validate key format
				if ($key_value =~ /^[A-Za-z0-9+\/=]+$/) {
					push @keys, $key_value;
					info("  #G{✓} Found seal key $i");
				} else {
					info("  #Y{⚠} Invalid seal key $i format");
					$errors++;
				}
			} else {
				info("  #R{✗} Failed to read seal key $i");
				$errors++;
			}
		}

		if (@keys) {
			$keys_found = scalar(@keys);
			$keys_content = join("\n", @keys) . "\n";
			info("");
			info("Found $keys_found seal keys" . ($errors ? " with $errors errors" : ""));
		}
	} else {
		info("Not authenticated - will prompt for seal keys manually");
	}

	# Attempt to unseal
	if ($keys_found > 0) {
		info("");
		info("Attempting automatic unseal with stored keys...");

		my ($unseal_out, $unseal_rc) = run(
			{ stdin => $keys_content, stderr => 1 },
			'safe', '-T', $env->name, 'unseal'
		);

		# safe can exit zero having reached only some of the nodes, so the
		# nodes themselves decide whether the unseal worked.
		my $after = $self->_vault_wait_until_unsealed(map {$_->{url}} @{$cluster->{nodes}});
		if ($unseal_rc == 0 && !@{$after->{sealed}} && !@{$after->{unreachable}}) {
			info("#G{✓ Vault unsealed successfully!}");
			info("");
			$self->_vault_report_nodes($after);
			return $self->done(1);
		} else {
			info("#R{✗ Automatic unseal failed}");
			info("Error: $unseal_out") if $unseal_out;
			$self->_vault_report_nodes($after);
			info("");
			info("Falling back to manual unseal...");
		}
	}

	# Fall back to manual unseal
	info("");
	info("Please enter the unseal keys when prompted:");

	run(
		{ interactive => 1 },
		'safe', '-T', $env->name, 'unseal'
	);

	my $after = $self->_vault_wait_until_unsealed(map {$_->{url}} @{$cluster->{nodes}});
	$self->_vault_report_nodes($after);
	if (@{$after->{sealed}} || @{$after->{unreachable}}) {
		info("#R{✗ Some Vault nodes are still sealed or did not answer}");
		return $self->done(0);
	}
	info("#G{✓ Vault unsealed successfully!}");
	return $self->done(1);
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
