This is a major release. It adds the `resolute` feature for the Ubuntu 26.04 stemcell, and it moves the kit from Vault 1.14.7 and Consul 1.16.4 to Vault 2.2.0 and Consul 2.0.4. The kit version is now 3.0.0, so set `kit.version` to 3.0.0 in your environment files.

## Breaking changes and upgrade steps

Vault and Consul are now published under the Business Source License 1.1 instead of the Mozilla Public License. The licence allows production use, but it restricts offering the software as a competing hosted service, so read it before you adopt this release.

Work through these steps in order when you move an existing environment to this kit. The MANUAL's "Upgrading from Kit 2.x" section has the full commands and the recovery procedures.

1. Take a Consul snapshot, and keep the Vault unseal keys and root token somewhere outside the Vault. A Vault that a 2.x server has unsealed can't be rolled back to 1.14, so the snapshot is your only way back.

2. Know that the Consul upgrade is a direct jump from 1.16 to 2.0, which is further than Consul's guidance allows, because no release carries the versions in between. In our three-node test, one node came up with a corrupt `raft.db`, and we recovered it by moving its raft directory aside while the other two held quorum. The MANUAL gives the steps.

3. Upgrade Genesis to 3.1.0 or later, make sure the deploy host has `safe` 1.24 or later and `curl`, and then set `kit.version` to 3.0.0 in each environment file.

4. Plan for an outage. Every node restarts sealed, so the Vault is down until post-deploy unseals it, and environments that use it as their secrets provider can't deploy in that window.

5. Deploy one environment at a time. Post-deploy unseals every node when the deploy ends, so `genesis <env> do unseal` is only needed when it can't.

6. Expect existing Consul servers to keep their BoltDB raft log. Consul uses the WAL log store for new clusters, but a server with an existing `raft.db` file isn't migrated automatically. A rebuilt node picks up WAL.

7. Check any script that calls the Vault API directly. Vault 2.x rejects request paths that aren't cleaned, limits RSA keys to a modulus of 8192 bits, and requires a token to rekey or generate a root token.

## Improvements

* The new `resolute` feature deploys the Vault nodes on the `ubuntu-resolute` stemcell. It sets `params.stemcell_os` itself, so leave that parameter out. The Director needs bosh-dns 1.39.31 or later, and the kit was tested with stemcell 0.184.

* The kit refuses to build when the `resolute` feature is on and `params.stemcell_os` names a different operating system, and when `params.stemcell_os` is `ubuntu-resolute` without the feature.

* The safe release starts every process with `setpriv` in place of `chpst`, because the resolute stemcell does not ship runit. This applies on every stemcell.

* The Vault configuration now uses the `storage "consul"` stanza, and the Consul configuration takes its TLS settings from `tls.defaults` and no longer sets `start_join`. Neither server prints deprecation warnings for the kit's configuration.

* The kit pins safe 0.3.4. Each node now waits in post-start until its Consul server is a healthy voter in a full cluster, so a rolling deploy can't take Consul below quorum. Stopping Consul waits for it to exit, and a stopping server stays in raft.

* Post-deploy and the `unseal` addon unseal every node, not only the targeted one. They re-target the environment with strongbox when the safe target lacks it, and post-deploy also unseals the nodes after a failed deploy.

* The seal checks read each node's seal status with `curl`, so the deploy host no longer needs a `vault` or `bao` binary.

* The `target` addon verifies TLS against the kit's CA when `params.vault_domain` is set.

* The `stackit` and resolute spec environments now have generated results, and the kit's spec deployments declare the kit name and version that the test suite requires.

## Bug fixes

* Post-deploy no longer initializes a cluster when the secrets provider already holds seal keys, which could have replaced the only backup of an existing Vault's keys. It initializes only an empty cluster that every node answers for, prints no key or token while doing it, and refuses to overwrite a stored backup.

* Seal keys, the root token, and the Doomsday credentials no longer appear on command lines or in deploy output. The hooks pass them to safe on stdin, and pre-deploy writes the keys it reads to a mode 0600 file.

* Pre-deploy reads the seal keys from this environment's own path, instead of a path that could match another Vault's keys.

* The Doomsday AppRole credentials move to the provider's exodus data for the environment. Each deploy revokes the earlier secret IDs, so they no longer pile up.

* The hooks restore the operator's current safe target after they finish, and they warn when they can't.

* With the `resolute` feature on, pre-deploy refuses a manifest whose stemcells include another operating system.

* Consul no longer refuses to start on Directors that run a current bosh-dns. bosh-dns puts 169.254.0.2 on an interface of its own, which Consul counted as a second private address, so the kit now sets `safe.peer.force_bind_default_ip` and Consul binds to the instance's own IP. The new `params.consul_force_bind_default_ip` turns that off.

* The kit's spec suite passed none of its four environments, because the deployment files lacked `kit.name` and `kit.version`. They now carry both, and the whole suite passes.

* The `ubuntu-bionic` default named in the manual for `stemcell_os` was out of date. The default is `ubuntu-jammy`.
