package Genesis::Hook::Addon::Vault::Init;

use v5.20;
use warnings; # Genesis min perl version is 5.20
use Genesis qw/bail info run read_json_from /;
# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'./.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.20');
	return $obj;
}

sub cmd_details {
	return
	"Initialize a new Vault cluster, setting up a new set of seal keys and an initial root token.\n".
	"This should only be done once per deployment.\n";
}

sub perform {
	my ($self) = @_;
	my $env = $self->env;

	info("");

	# Try to find a Vault node to initialize
	my ($out, $rc) = read_json_from($self->env->bosh->execute('vms','--json'));
	bail("Failed to get VM information from BOSH") unless $rc;

	my @ips = map {$_->{ips}} $out->{Tables}[0]{Rows}->@*;  # TODO handle possible VIPs
	bail("No Vault VMs found in deployment") unless @ips;

	foreach my $ip (@ips) {
		# Test connectivity to the Vault node
		my $curl_opts = $ENV{CURLOPTS} // '';
		my $timeout = $ENV{TIMEOUT} // 3;
		my ($curl_out, $curl_rc) = run(
			{ stderr => 0 },
			"curl -Lsk $curl_opts -m$timeout https://$ip"
		);

		if ($curl_rc == 0) {
			info("Attempting to #Y{initialize} Vault via node $ip");

			# Target the Vault node
			my ($target_out, $target_rc) = run(
				{ stderr => 1 },
				'safe', 'target', "https://$ip", '-k', $env->name
			);

			if ($target_rc != 0) {
				info("#R{Failed to target Vault at $ip}, trying next node...");
				next;
			}

			# Initialize the Vault and capture output
			info("Initializing Vault cluster...");
			my ($init_out, $init_rc) = run(
				{ stderr => 1 },
				'safe', '-T', $env->name, 'init'
			);

			if ($init_rc == 0) {
				# Parse and store seal keys
				if ($self->_store_seal_keys($init_out, $env->name)) {
					info("#G{Vault initialized successfully!}");
					info("Seal keys have been stored in the Vault for automatic unsealing.");
					return $self->done(1);
				} else {
					info("#Y{WARNING:} Vault initialized but seal keys could not be stored.");
					info("You will need to manually unseal the vault after redeployments.");
					return $self->done(1);
				}
			} else {
				info("#R{Failed to initialize Vault:} $init_out");
				return $self->done(0);
			}
		}
	}

	bail("Could not find any reachable Vault nodes to initialize.");
}

# _store_seal_keys - Parse and store seal keys from safe init output {{{
sub _store_seal_keys {
	my ($self, $init_output, $target_name) = @_;

	# Validate input
	unless ($init_output) {
		info("#R{ERROR:} No output from vault initialization");
		return 0;
	}

	# Parse seal keys from the output
	my @seal_keys;
	my $root_token;

	foreach my $line (split /\n/, $init_output) {
		# Match seal key pattern: "Unseal Key N: <key>"
		if ($line =~ /^Unseal Key \d+:\s*(.+)$/i) {
			my $key = $1;
			$key =~ s/^\s+|\s+$//g; # trim whitespace

			# Validate key format (should be base64-ish)
			if ($key =~ /^[A-Za-z0-9+\/=]+$/) {
				push @seal_keys, $key;
			} else {
				info("#Y{WARNING:} Invalid seal key format detected, skipping: $key");
			}
		}
		# Capture root token for validation
		elsif ($line =~ /^Initial Root Token:\s*(.+)$/i) {
			$root_token = $1;
			$root_token =~ s/^\s+|\s+$//g;
		}
	}

	# Validate we found seal keys
	unless (@seal_keys) {
		info("#R{ERROR:} No seal keys found in initialization output");
		info("Output was: $init_output");
		return 0;
	}

	info("Found " . scalar(@seal_keys) . " seal keys to store");

	# Authenticate with the root token to store the keys
	if ($root_token) {
		my ($auth_out, $auth_rc) = run(
			{ stdin => $root_token, stderr => 0 },
			'safe', '-T', $target_name, 'auth', 'token'
		);

		if ($auth_rc != 0) {
			info("#R{ERROR:} Failed to authenticate with root token");
			return 0;
		}
	} else {
		info("#Y{WARNING:} No root token found, attempting to store keys anyway");
	}

	# Store each seal key
	my $stored_count = 0;
	for (my $i = 0; $i < @seal_keys; $i++) {
		my $key_num = $i + 1;
		my $key_path = "secret/vault/seal/keys:key$key_num";

		my ($store_out, $store_rc) = run(
			{ stderr => 0 },
			'safe', '-T', $target_name, 'set', $key_path, "value=$seal_keys[$i]"
		);

		if ($store_rc == 0) {
			$stored_count++;
			info("  #G{✓} Stored seal key $key_num");
		} else {
			info("  #R{✗} Failed to store seal key $key_num: $store_out");
		}
	}

	# Verify storage was successful
	if ($stored_count == @seal_keys) {
		info("#G{Successfully stored all $stored_count seal keys}");

		# Store a marker to indicate the vault has been initialized
		run(
			{ stderr => 0 },
			'safe', '-T', $target_name, 'set', 'secret/vault/seal/initialized',
			"at=" . localtime(),
			"keys=$stored_count"
		);

		return 1;
	} else {
		info("#Y{WARNING:} Only stored $stored_count out of " . scalar(@seal_keys) . " seal keys");
		return $stored_count > 0 ? 1 : 0;
	}
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
