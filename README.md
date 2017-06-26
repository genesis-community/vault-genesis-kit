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

Subkits
-------

#### Shield

The SHIELD subit adds the SHIELD agent to the Vault deployment, so that its data
can be backed up via SHIELD.

#### Azure

When deploying Vault on azure, you may want to consider the `azure` subkit for
reconfiguring the availability zones in play. Since Azure uses availability sets,
rather than zones, there is typically only one zone in play for networks/VMs,
and the availability set would be defined by the Azure CPI automatically, or via
`cloud_properties` in your Cloud Config.

Params
------

#### Base Params

- **params.vault_disk_pool** - used to define the persistent disk pool that the Vault VMs will
  be given. This pool must exist in the Cloud Config of the BOSH director that deploys
  Vault. This defaults to `vault`.
- **params.vault_vm_type** - used to define the Cloud Config VM type that the Vault VM
  will be given. This VM type must exist in the Cloud config of the BOSH director that
  deploys Vault. This defaults to `small`.
- **params.vault_network** - used to define the Cloud Config network that the Vault
  VM will be located on. This network must exist in the Cloud Config of the BOSH director
  that deploys Vault. It defaults to `vault`, but typically this can be located
  on a shared-infrastructure network.
- **params.availability_zones** - defines the availability zones that VMs will be placed into.
  Defaults to a list of `z1`, `z2`, and `z3`. 

#### Shield Params

- **params.shield_key_vault_path** - A Vault path to the SHIELD daemon's public SSH key
  This is used to authenticate the SHIELD daemon to the agent, when running tasks.

  For example: `secret/us/proto/shield/agent:public`

[1]: https://vaultproject.io
[2]: https://github.com/cloudfoundry-community/safe-boshrelease
[3]: https://github.com/jhunt/go-strongbox
[4]: https://github.com/starkandwayne/safe
