Vault Genesis Kit
=================

This is a Genesis kit for deploying [Vault][1] via the [safe-boshrelease][2].
It deploys a 3-node Vault cluster, using Consul as a backend. It also includes
the [strongbox API][3] to make sealing/unsealing the entire Vault cluster easier
to manage when using the [safe CLI][4].

Quick Start
-----------

To use it, you don't even need to clone this repository!  Just run
the following (using Genesis v2):

```
# create a vault-deployments repo using the latest version of the vault kit
genesis init --kit vault

# create a vault-deployments repo using v1.0.0 of the vault kit
genesis init --kit vault/1.0.0

# create a my-vault-configs repo using the latest version of the vault kit
genesis init --kit vault -d my-vault-configs
```

Learn More
----------

For more in-depth documentation, check out the [manual][5].

[1]: https://vaultproject.io
[2]: https://github.com/cloudfoundry-community/safe-boshrelease
[3]: https://github.com/jhunt/go-strongbox
[4]: https://github.com/starkandwayne/safe
[5]: MANUAL.md



