# Vault Genesis Kit

This is a Genesis kit for deploying [Vault][1] via the [safe-boshrelease][2].
It deploys a multi-node Vault cluster, using Consul as a backend. It also includes
the [strongbox API][3] to make sealing/unsealing the entire Vault cluster easier
to manage when using the [safe CLI][4].

## Features

- Deploys a secure, highly-available Vault cluster
- Supports multiple cloud providers (AWS, Azure, GCP, vSphere, STACKIT, OCFP)
- Automatic certificate generation and management
- Integrated with the Safe CLI for credential management
- Strongbox API for simplified cluster seal/unseal operations
- Customizable VM and disk types
- Web UI support
- Comprehensive addon commands for cluster management

## Quick Start

To use it, you don't even need to clone this repository! Just run
the following (using Genesis v2+):

```
# create a vault-deployments repo using the latest version of the vault kit
genesis init --kit vault

# create a vault-deployments repo using v2.0.0 of the vault kit
genesis init --kit vault/2.0.0

# create a my-vault-configs repo using the latest version of the vault kit
genesis init --kit vault -d my-vault-configs
```

## Deployment

After creating a deployment repository, you can create a new environment:

```
# Create a new environment file
genesis new dev

# Deploy Vault
genesis deploy dev

# Initialize the Vault (first deployment only)
genesis do dev -- init

# Target the Vault with Safe
genesis do dev -- target

# Check Vault status
genesis do dev -- status
```

## Learn More

For more in-depth documentation, check out the [manual][5] and the documentation in the `docs/` directory.

[1]: https://vaultproject.io
[2]: https://github.com/cloudfoundry-community/safe-boshrelease
[3]: https://github.com/jhunt/go-strongbox
[4]: https://github.com/starkandwayne/safe
[5]: MANUAL.md