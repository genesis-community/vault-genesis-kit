# Vault Genesis Kit Manual

The **Vault Genesis Kit** deploys a consul-backed Vault cluster.
Vault provides secure storage of and access to sensitive
credentials used elsewhere in deployments and applications.

# Base Parameters

- `vault_disk_pool` - The persistent disk pool that Vault VMs will
  use.  This pool must exist in your cloud config.  Defaults to
  `default`.

- `vault_vm_type` - What type of VM to deploy.  This type must
  exist in your cloud config.  Defaults to `default`.

- `vault_network` - What network to deploy Vault into.  This
  network must be defined in your cloud config.  Defaults to
  `vault`.

- `availability_zones` - What BOSH HA availability zones to deploy
  the Vault across.  The chosen network must have at least one
  subnet in each of the listed zones, and the zones themselves
  must be defined in your cloud config.  Defaults to `z1`, `z2`,
  and `z3`.

- `azure_availability_set` - In Microsoft Azure, this parameter
  names the availability set to deploy the Vault nodes across.
  This parameter does not have any effect on other platforms.

# Cloud Configuration

By default, Vault uses the following VM types/networks/disk pools from your
cloud config. Feel free to override them in your environment, if you would
rather they use entities already existing in your cloud config:

```
params:
  vault_network:   vault
  vault_disk_pool: default # should be at least 1GB
  vault_vm_type:   default # VMs should have at least 1 CPU, and 1GB of memory
```


# Available Addons

- `init` - Initializes the Vault cluster.  This can only be run
  once, as it formats the Vault storage and generates seal keys
  for protecting the Vault.

- `target` - Sets up a `safe` target for this Vault, named after
  the environment, and prompts for initial root token
  authentication.

- `status` - Determine Vault status: health, availability, and
  sealed / unsealed state.

- `seal` - Seals the Vault.

- `unseal` - Unseals the Vault.

# Examples

To use custom cloud config types:

```
---
kit:
  name: vault
  version: 1.2.0

params:
  env: acme-us-east-1-prod

  vault_network:   credstore
  vault_disk_pool: encrypted
  vault_vm_type:   std.small.1c.2gb
```

# Caveats

Each Vault installation will have its own seal keys and initial
root token.  The natural inclination will be to store these _in_
the Vault, but that's a bad idea.  Use an external password
manager instead, like 1password or LastPass.

Every time Vault is deployed, whether to pick up configuration
changes or to upgrade the operating system (stemcell), the Vault
will protectively seal itself.  An operator **must** intervene to
unseal it, or it will remain inaccessible.

# History

Version 1.2.0 was the first version to support Genesis 2.6 hooks
for addon scripts and `genesis info`.

Up through version 1.1.0 of this kit, there was a subkit / feature
called `shield` which colocated the SHIELD agent for performing
local backups of the consul cluster.  As of version 1.2.0, this
model is no longer supported; operators are encouraged to use BOSH
runtime configs to colocate addon jobs instead.
