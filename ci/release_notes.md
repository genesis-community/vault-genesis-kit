This is a major release. It adds the `resolute` feature for the Ubuntu 26.04 stemcell, and it moves the kit from Vault 1.14.7 and Consul 1.16.4 to Vault 2.2.0 and Consul 2.0.4. The kit version is now 3.0.0, so set `kit.version` to 3.0.0 in your environment files.

## Breaking changes and upgrade steps

Vault and Consul are now published under the Business Source License 1.1 instead of the Mozilla Public License. The licence allows production use, but it restricts offering the software as a competing hosted service, so read it before you adopt this release.

Work through these steps in order when you move an existing environment to this kit.

1. Take a Consul snapshot, and keep the Vault unseal keys and root token somewhere outside the Vault. A Vault that a 2.x server has unsealed cannot be rolled back to 1.14, so the snapshot is your only way back.

2. Plan the Consul jump. Consul supports upgrading across at most two major versions in one step, and going from 1.16 to 2.0 is further than that. Either deploy through intermediate kit versions that carry Consul 1.18, 1.20, and 1.22 in turn, or build a new environment on this kit and restore the Consul snapshot into it.

3. Upgrade Genesis to 3.1.0 or later, then set `kit.version` to 3.0.0 in each environment file.

4. Upload the safe release that the kit pins. It is a development build with the version `0.3.2+dev.1` and no download URL, so the Director must hold it before you deploy.

5. Deploy one environment at a time, and unseal the Vault with `genesis <env> do unseal` once each deploy finishes.

6. Expect existing Consul servers to keep their BoltDB raft log. Consul uses the WAL log store for new clusters, but a server with an existing `raft.db` file is not migrated automatically. A rebuilt node picks up WAL.

7. Check any script that calls the Vault API directly. Vault 2.x rejects request paths that are not cleaned, limits RSA keys to a modulus of 8192 bits, and requires a token to rekey or generate a root token.

## Improvements

* The new `resolute` feature deploys the Vault nodes on the `ubuntu-resolute` stemcell. It sets `params.stemcell_os` itself, so leave that parameter out. The Director needs bosh-dns 1.39.31 or later, and the kit was tested with stemcell 0.184.

* The kit refuses to build when the `resolute` feature is on and `params.stemcell_os` names a different operating system, and when `params.stemcell_os` is `ubuntu-resolute` without the feature.

* The safe release starts every process with `setpriv` in place of `chpst`, because the resolute stemcell does not ship runit. This applies on every stemcell.

* The Vault configuration now uses the `storage "consul"` stanza, and the Consul configuration takes its TLS settings from `tls.defaults` and no longer sets `start_join`. Neither server prints deprecation warnings for the kit's configuration.

* The `stackit` and resolute spec environments now have generated results, and the kit's spec deployments declare the kit name and version that the test suite requires.

## Bug fixes

* Consul no longer refuses to start on Directors that run a current bosh-dns. bosh-dns puts 169.254.0.2 on an interface of its own, which Consul counted as a second private address, so the kit now sets `safe.peer.force_bind_default_ip` and Consul binds to the instance's own IP. The new `params.consul_force_bind_default_ip` turns that off.

* The kit's spec suite passed none of its four environments, because the deployment files lacked `kit.name` and `kit.version`. They now carry both, and the whole suite passes.

* The `ubuntu-bionic` default named in the manual for `stemcell_os` was out of date. The default is `ubuntu-jammy`.
