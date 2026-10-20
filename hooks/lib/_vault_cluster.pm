# Shared Vault cluster helpers, included into hook packages via:
#   do <hooks-dir>/lib/_vault_cluster.pm
#
# Seal state is read from every node's GET /v1/sys/seal-status, which needs
# neither a token nor a `vault` or `bao` binary on the deploy host.
#
# The hooks reach the deployment through the safe target named after the
# environment.  safe only walks the whole cluster for status, seal, and unseal
# when that target was made with --strongbox, so a target without it is
# rewritten at the same URL with the flag added, which keeps its token.  A
# target is only ever written when it is missing or lacks strongbox, and the
# operator's current target is put back afterwards.
#
# Targets the hooks make at a node address skip TLS verification (-k).  The
# kit's Vault certificate names only params.vault_domain (default vault.bosh)
# and 127.0.0.1, and safe has no way to verify one name while connecting to
# another, so the certificate never verifies against the kit CA at a node's
# IP.  The target addon points at params.vault_domain when it is set, and
# verifies against the kit CA there.
#
# Every read of a secret passes redact_output, and every secret written goes
# to safe on stdin rather than in argv.

use Genesis qw/info run read_json_from load_json/;
use JSON::PP ();
use Fcntl qw/O_WRONLY O_CREAT O_EXCL/;

use constant VAULT_SEAL_KEYS_PATH => 'secret/vault/seal/keys';

# _vault_node_url - the https base URL for a node address {{{
sub _vault_node_url {
	my ($ip) = @_;
	return $ip =~ /:/ ? "https://[$ip]" : "https://$ip";
}

# }}}
# _vault_node_ips - addresses of the deployment's vault instances {{{
# Empty when BOSH has no such deployment or cannot be asked.
sub _vault_node_ips {
	my ($self) = @_;
	my ($vms) = read_json_from($self->env->bosh->execute('vms', '--json'));
	return () unless ref($vms) eq 'HASH'
		&& ref($vms->{Tables}) eq 'ARRAY'
		&& ref($vms->{Tables}[0]) eq 'HASH'
		&& ref($vms->{Tables}[0]{Rows}) eq 'ARRAY';

	my (@ips, %seen);
	for my $row (@{$vms->{Tables}[0]{Rows}}) {
		next unless ref($row) eq 'HASH' && ($row->{instance} // '') =~ m{^vault/};
		my $ips = $row->{ips};
		push @ips, grep {/^[0-9A-Fa-f.:]+$/ && !$seen{$_}++}
			(ref($ips) eq 'ARRAY' ? @$ips : split(/[\s,]+/, $ips // ''));
	}
	return @ips;
}

# }}}
# _vault_node_urls - https base URLs of the deployment's vault instances {{{
sub _vault_node_urls {
	my ($self) = @_;
	return map {_vault_node_url($_)} $self->_vault_node_ips;
}

# }}}
# _vault_seal_states - read each node's seal status {{{
# Returns one hash per URL: {url, reachable, initialized, sealed} for a node
# that answered, or {url, reachable => 0, error} for one that did not.
sub _vault_seal_states {
	my ($self, @urls) = @_;
	my $timeout = ($ENV{TIMEOUT} // '') =~ /^[1-9][0-9]*$/ ? $ENV{TIMEOUT} : 5;

	my @states;
	for my $url (@urls) {
		my ($out, $rc, $err) = run({stderr => 0},
			'curl', '-sSk', '-m', $timeout, "$url/v1/sys/seal-status"
		);
		my $status = $rc == 0 ? eval {JSON::PP::decode_json($out)} : undef;
		if (ref($status) eq 'HASH' && exists($status->{sealed}) && exists($status->{initialized})) {
			push @states, {
				url         => $url,
				reachable   => 1,
				initialized => $status->{initialized} ? 1 : 0,
				sealed      => $status->{sealed} ? 1 : 0,
			};
			next;
		}
		($err //= '') =~ s/\s+/ /g;
		$err =~ s/^ | $//g;
		push @states, {
			url       => $url,
			reachable => 0,
			error     => $err ne '' ? $err
			           : $rc        ? "curl exited $rc"
			           :              'the response held no seal status',
		};
	}
	return @states;
}

# }}}
# _vault_cluster - summarize the seal state of every node {{{
# Reads the nodes BOSH reports when no URLs are given.
sub _vault_cluster {
	my ($self, @urls) = @_;
	@urls = $self->_vault_node_urls unless @urls;
	my @nodes = $self->_vault_seal_states(@urls);
	my @up = grep {$_->{reachable}} @nodes;
	return {
		nodes         => \@nodes,
		reachable     => [map {$_->{url}} @up],
		unreachable   => [map {$_->{url}} grep {!$_->{reachable}} @nodes],
		initialized   => (grep {$_->{initialized}} @up) ? 1 : 0,
		uninitialized => [map {$_->{url}} grep {!$_->{initialized}} @up],
		sealed        => [map {$_->{url}} grep {$_->{sealed}} @up],
		serving       => [map {$_->{url}} grep {$_->{initialized} && !$_->{sealed}} @up],
	};
}

# }}}
# _vault_env_cluster - seal state of the env's nodes, or of its target {{{
# BOSH lists the nodes.  When it lists none, as when it can't be reached,
# the address of the safe target named after the environment stands in.
sub _vault_env_cluster {
	my ($self, $name) = @_;
	my @urls = $self->_vault_node_urls;
	unless (@urls) {
		my $target = (_safe_targets() || {})->{$name};
		(my $url = $target ? ($target->{url} // '') : '') =~ s{/+$}{};
		@urls = ($url) if $url ne '';
	}
	return $self->_vault_cluster(@urls) if @urls;
	return {
		nodes => [], reachable => [], unreachable => [], initialized => 0,
		uninitialized => [], sealed => [], serving => [],
	};
}

# }}}
# _vault_report_nodes - print one line per node {{{
sub _vault_report_nodes {
	my ($self, $cluster) = @_;
	for my $node (@{$cluster->{nodes}}) {
		if (!$node->{reachable}) {
			info("[[    - >>#M{%s} #R{did not answer}: %s", $node->{url}, $node->{error});
		} elsif (!$node->{initialized}) {
			info("[[    - >>#M{%s} is #Y{uninitialized}", $node->{url});
		} elsif ($node->{sealed}) {
			info("[[    - >>#M{%s} is #Y{sealed}", $node->{url});
		} else {
			info("[[    - >>#M{%s} is #G{unsealed}", $node->{url});
		}
	}
}

# }}}
# _vault_wait_until_unsealed - re-read the nodes until none is sealed {{{
# Vault takes a moment to report a node unsealed after the last key, so poll
# for up to about ten seconds before giving the final state.
sub _vault_wait_until_unsealed {
	my ($self, @urls) = @_;
	my $cluster;
	for my $attempt (1..5) {
		$cluster = $self->_vault_cluster(@urls);
		last unless @{$cluster->{sealed}} || @{$cluster->{unreachable}};
		sleep(2) if $attempt < 5;
	}
	return $cluster;
}

# }}}
# _safe_env - environment that keeps safe from honouring a caller's override {{{
sub _safe_env {
	return {VAULT_ADDR => undef, SAFE_TARGET => undef};
}

# }}}
# _safe_targets - every safe target, keyed by alias {{{
# Returns undef when safe cannot list them.
sub _safe_targets {
	my ($out, $rc) = run({stderr => 0, env => _safe_env()}, 'safe', 'targets', '--json');
	return undef unless $rc == 0;
	my $targets = eval {JSON::PP::decode_json($out)};
	return undef unless ref($targets) eq 'ARRAY';
	return {map {($_->{name} => $_)} grep {ref($_) eq 'HASH' && defined($_->{name})} @$targets};
}

# }}}
# _safe_current_target - alias of the current safe target, or undef {{{
sub _safe_current_target {
	my ($out, $rc) = run({stderr => 0, env => _safe_env()}, 'safe', 'target', '--json');
	my $current = $rc == 0 ? eval {JSON::PP::decode_json($out)} : undef;
	return undef unless ref($current) eq 'HASH' && length($current->{name} // '');
	return $current->{name};
}

# }}}
# _safe_restore_current - make the previous current target current again {{{
# `safe target` makes the target it writes current, and Genesis checks the
# current target when it starts, so a sealed Vault left there stops every
# Genesis command on the host.
sub _safe_restore_current {
	my ($previous, $name) = @_;
	if (!defined($previous)) {
		info(
			"[[  #Y{warning:} >>No safe target was current before #C{%s} was ".
			"targeted, so #C{%s} is now the current target.  Target the Vault ".
			"you normally use again with #G{safe target <alias>}.",
			$name, $name
		);
		return 0;
	}
	return 1 if $previous eq $name;

	my ($out, $rc, $err) = run({stderr => 0, env => _safe_env()}, 'safe', 'target', $previous);
	return 1 if $rc == 0;
	($err = $err || $out || '') =~ s/\s+/ /g;
	info(
		"[[  #Y{warning:} >>Could not make #C{%s} the current safe target again ".
		"(safe exited %d%s).  #C{%s} is still current, so target your Vault ".
		"again with #G{safe target %s}.",
		$previous, $rc, ($err ne '' ? ": $err" : ''), $name, $previous
	);
	return 0;
}

# }}}
# _saferc_target - the ~/.saferc entry for a target alias, or undef {{{
# The entry holds the target's token, so the conversion's output is redacted
# from the trace log.
sub _saferc_target {
	my ($name) = @_;
	my $rc_file = ($ENV{HOME} // '') . '/.saferc';
	return undef unless -f $rc_file;
	my ($out, $rc) = run({stderr => 0, redact_output => 1}, 'spruce json < "$1"', $rc_file);
	return undef unless $rc == 0;
	my $config = eval {load_json($out)};
	return undef unless ref($config) eq 'HASH' && ref($config->{vaults}) eq 'HASH';
	my $entry = $config->{vaults}{$name};
	return ref($entry) eq 'HASH' ? $entry : undef;
}

# }}}
# _safe_write_target - write a strongbox target, keeping the current one {{{
# Options: insecure (adds -k), ca_certs (PEM strings), and namespace.
# Returns safe's exit code.
sub _safe_write_target {
	my ($name, $url, %opts) = @_;
	my $previous = _safe_current_target();

	my @cmd = ('safe');
	push @cmd, '-k' if $opts{insecure};
	push @cmd, 'target', '--strongbox';
	push @cmd, map {('--ca-cert', $_)} grep {defined && /\S/} @{$opts{ca_certs} || []};
	push @cmd, '-n', $opts{namespace} if length($opts{namespace} // '');
	push @cmd, $url, $name;

	my ($out, $rc, $err) = run({stderr => 0, env => _safe_env()}, @cmd);
	if ($rc != 0) {
		($err = $err || $out || '') =~ s/\s+/ /g;
		info(
			"[[  #R{error:} >>safe could not target #M{%s} as #C{%s} (exit %d)%s",
			$url, $name, $rc, ($err ne '' ? ": $err" : '')
		);
		return $rc;
	}
	_safe_restore_current($previous, $name);
	return 0;
}

# }}}
# _ensure_strongbox_target - make sure the env's safe target uses strongbox {{{
# Creates the target at the first given URL when it is missing, and rewrites
# it at its own URL with --strongbox when it lacks the flag.  Returns the
# target's entry from `safe targets --json`, or undef when there is no usable
# target.
sub _ensure_strongbox_target {
	my ($self, $name, @urls) = @_;

	my $targets = _safe_targets();
	unless ($targets) {
		info("[[  #R{error:} >>safe could not list its targets, so the #C{%s} target could not be checked", $name);
		return undef;
	}

	my $target = $targets->{$name};
	if (!$target) {
		my ($url) = @urls;
		unless ($url) {
			info("[[  #R{error:} >>There is no safe target named #C{%s}, and no Vault node answered to create one at", $name);
			return undef;
		}
		info("[[  - >>creating safe target #C{%s} at #M{%s} with strongbox", $name, $url);
		return undef unless _safe_write_target($name, $url, insecure => 1) == 0;
	} elsif (!$target->{strongbox}) {
		info(
			"[[  - >>safe target #C{%s} does not use strongbox, so safe would check and ".
			"unseal #M{%s} alone; re-targeting the same URL with strongbox",
			$name, $target->{url}
		);
		my $entry = _saferc_target($name) || {};
		my $ca_certs = $entry->{ca_certs};
		$ca_certs = [$ca_certs] if defined($ca_certs) && !ref($ca_certs);
		return undef unless _safe_write_target(
			$name, $target->{url},
			insecure  => !$target->{verify},
			ca_certs  => (ref($ca_certs) eq 'ARRAY' ? $ca_certs : []),
			namespace => $target->{namespace},
		) == 0;
	}

	$targets = _safe_targets() || {};
	$target = $targets->{$name};
	unless ($target && $target->{strongbox}) {
		info("[[  #R{error:} >>safe target #C{%s} still does not use strongbox after re-targeting it", $name);
		return undef;
	}

	# A target left over from an earlier deployment under the same name may
	# point at an address this one doesn't use.  Say so rather than rewrite it.
	# A target at a DNS name, such as params.vault_domain, can't be compared.
	my @node_urls = $self->_vault_node_urls;
	(my $target_url = lc($target->{url} // '')) =~ s{/+$}{};
	my $by_address = $target_url =~ m{^https?://(?:\[[0-9a-f:]+\]|[0-9.]+)(?::[0-9]+)?$};
	if ($by_address && @node_urls && !grep {lc($_) eq $target_url} @node_urls) {
		info(
			"[[  #Y{warning:} >>safe target #C{%s} points at #M{%s}, which is not one of ".
			"this deployment's nodes (%s).  If it no longer answers, re-target it with ".
			"#G{safe -k target --strongbox %s %s}.",
			$name, $target->{url}, join(', ', @node_urls), $node_urls[0], $name
		);
	}
	return $target;
}

# }}}
# _vault_path_state - whether a secret exists in a Service::Vault {{{
# `safe exists` exits 1 both when a secret is absent and when the Vault can't
# be asked, and only the second writes to stderr.  Returns 'present',
# 'absent', or 'unknown' and the error text.
sub _vault_path_state {
	my ($vault, $path) = @_;
	my (undef, $rc, $err) = $vault->query({stderr => 0}, 'exists', $path);
	return ('present') if $rc == 0;
	($err //= '') =~ s/^\s+|\s+$//g;
	return ('absent') if $rc == 1 && $err eq '';
	return ('unknown', $err ne '' ? $err : "safe exited $rc");
}

# }}}
# _vault_set_secret - write one secret value through safe on stdin {{{
# $query is called like Service::Vault::query: ($opts, @safe_args).  Extra
# key=value pairs, which must not be secret, go in the same write.
sub _vault_set_secret {
	my ($query, $path, $key, $value, @pairs) = @_;
	my ($out, $rc, $err) = $query->(
		{stdin => $value, stderr => 0, redact_output => 1},
		'set', $path, "$key\@-", @pairs
	);
	return wantarray ? ($rc, $err // '') : $rc;
}

# }}}
# _vault_read_seal_keys - read key1..keyN at secret/vault/seal/keys {{{
# $query is called like Service::Vault::query.  Returns the keys in order.
sub _vault_read_seal_keys {
	my ($query) = @_;
	my $path = VAULT_SEAL_KEYS_PATH;
	my ($paths, $rc) = $query->({stderr => 0}, 'paths', '--keys', $path);
	return () unless $rc == 0 && defined($paths);

	my @numbers = sort {$a <=> $b}
		map {m{^/?\Q$path\E:key([0-9]+)$} ? $1 : ()}
		split(/\n/, $paths);

	my @keys;
	for my $n (@numbers) {
		my ($value, $get_rc) = $query->({stderr => 0, redact_output => 1}, 'get', "$path:key$n");
		next unless $get_rc == 0 && defined($value);
		$value =~ s/^\s+|\s+$//g;
		push @keys, $value if $value ne '';
	}
	return @keys;
}

# }}}
# _vault_target_query - run safe against a named target {{{
sub _vault_target_query {
	my ($name) = @_;
	return sub {
		my ($opts, @args) = @_;
		return run({%$opts, env => {%{$opts->{env} || {}}, %{_safe_env()}, DEBUG => ''}},
			'safe', '-T', $name, @args
		);
	};
}

# }}}
# _vault_node_query - run safe against one node with a target's credentials {{{
# A safe target is bound to one URL, so reading through another node of the
# same cluster gives safe that node's address and the target's token in its
# environment, with HOME pointed at an empty directory so no ~/.saferc
# target overrides them.  Nothing reaches argv, and the environment is
# redacted from the trace log.  Returns undef when the target's token can't
# be read.
sub _vault_node_query {
	my ($self, $name, $url) = @_;
	my $entry = _saferc_target($name);
	return undef unless $entry && length($entry->{token} // '');

	my $home = $self->env->workpath(sprintf('safe-node-%06d', int(rand(1000000))));
	mkdir($home, 0700) or return undef unless -d $home;

	my %env = (
		%{_safe_env()},
		HOME        => $home,
		VAULT_ADDR  => $url,
		VAULT_TOKEN => $entry->{token},
		DEBUG       => '',
	);
	$env{VAULT_NAMESPACE} = $entry->{namespace} if length($entry->{namespace} // '');

	my $ca_certs = $entry->{ca_certs};
	$ca_certs = [$ca_certs] if defined($ca_certs) && !ref($ca_certs);
	my @flags;
	if ($entry->{skip_verify}) {
		@flags = ('-k');
	} elsif (ref($ca_certs) eq 'ARRAY' && @$ca_certs) {
		my $ca_file = "$home/ca.pem";
		open(my $fh, '>', $ca_file) or return undef;
		print $fh join("\n", @$ca_certs), "\n";
		close($fh);
		$env{VAULT_CACERT} = $ca_file;
	}

	return sub {
		my ($opts, @args) = @_;
		return run({%$opts, env => {%{$opts->{env} || {}}, %env}, redact_env => 1},
			'safe', @flags, @args
		);
	};
}

# }}}
# _write_private_file - create a new file readable by its owner only {{{
# Fails rather than replace a file that already exists.
sub _write_private_file {
	my ($file, $content) = @_;
	require File::Basename;
	my $dir = File::Basename::dirname($file);
	unless (-d $dir) {
		require File::Path;
		File::Path::make_path($dir, {mode => 0700, error => \my $errors});
		return (0, "could not create $dir") unless -d $dir;
	}
	sysopen(my $fh, $file, O_WRONLY | O_CREAT | O_EXCL, 0600)
		or return (0, "could not create $file: $!");
	print $fh $content or return (0, "could not write $file: $!");
	close($fh) or return (0, "could not write $file: $!");
	chmod(0600, $file);
	return (1);
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
