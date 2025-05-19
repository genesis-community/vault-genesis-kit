# Cloud Provider Configuration

The Vault Genesis Kit supports deployment across various cloud providers. This document outlines the specific configurations and considerations for each supported provider.

## Supported Cloud Providers

The Vault Genesis Kit has been tested and supports the following cloud providers:

- AWS
- Azure
- Google Cloud Platform (GCP)
- VMware vSphere
- STACKIT
- OCFP (OpenShift Container Foundation Platform)

## General Configuration

Regardless of the cloud provider, the following parameters are applicable:

- `vault_network`: The network to deploy Vault into
- `vault_vm_type`: The VM type to use for Vault instances
- `vault_disk_type`: The disk type to use for Vault VMs

## AWS Configuration

For AWS deployments, standard BOSH cloud-config settings apply. No specific feature flag is required for AWS deployments.

Example:
```yaml
---
kit:
  name: vault
  version: 2.0.0

genesis:
  env: aws-us-east-1-prod

params:
  vault_network: vault
  vault_vm_type: m5.large
  vault_disk_type: gp2
  availability_zones: [us-east-1a, us-east-1b, us-east-1c]
```

## Azure Configuration

For Azure deployments, enable the `azure` feature to configure availability sets correctly:

```yaml
---
kit:
  name: vault
  version: 2.0.0

genesis:
  env: azure-eastus-prod

features:
  - azure

params:
  vault_network: vault
  vault_vm_type: Standard_DS2_v2
  vault_disk_type: Standard_LRS
  azure_availability_set: vault-as
```

## GCP Configuration

For GCP deployments, standard BOSH cloud-config settings apply. No specific feature flag is required for GCP deployments.

Example:
```yaml
---
kit:
  name: vault
  version: 2.0.0

genesis:
  env: gcp-us-central1-prod

params:
  vault_network: vault
  vault_vm_type: n1-standard-1
  vault_disk_type: pd-ssd
  availability_zones: [us-central1-a, us-central1-b, us-central1-c]
```

## vSphere Configuration

For vSphere deployments, standard BOSH cloud-config settings apply. No specific feature flag is required for vSphere deployments.

Example:
```yaml
---
kit:
  name: vault
  version: 2.0.0

genesis:
  env: vsphere-datacenter-prod

params:
  vault_network: vault
  vault_vm_type: medium
  vault_disk_type: medium
  availability_zones: [az1, az2, az3]
```

## STACKIT Configuration

STACKIT is a cloud provider based on OpenStack. Enable the `stackit` feature for deployments on this platform:

```yaml
---
kit:
  name: vault
  version: 2.0.0

genesis:
  env: stackit-eu-prod

features:
  - stackit

params:
  vault_network: vault-network
  vault_vm_type: medium
  vault_disk_type: large
```

## OCFP Configuration

OCFP (OpenShift Container Foundation Platform) provides a standardized infrastructure environment. Enable the `ocfp` feature to use the pre-defined configuration and naming conventions:

```yaml
---
kit:
  name: vault
  version: 2.0.0

genesis:
  env: ocfp-us-prod

features:
  - ocfp

params:
  ocfp-instances: 3  # Number of Vault instances to deploy
  ocfp-subnet-prefix: ocfp  # Optional, defaults to ocfp
```

The `ocfp` feature:
- Sets network, VM type, and disk type to unique names specific to the environment
- Provides IPs and availability zones from the OCFP configuration
- Generates and uploads a cloud config with the appropriate settings

## Custom Cloud Configurations

For other cloud providers or custom configurations, you can specify the necessary parameters directly:

```yaml
---
kit:
  name: vault
  version: 2.0.0

genesis:
  env: custom-cloud-prod

params:
  vault_network: custom-network
  vault_vm_type: custom-vm-type
  vault_disk_type: custom-disk-type
  availability_zones: [custom-az1, custom-az2, custom-az3]
  ips: [10.0.1.10, 10.0.1.11, 10.0.1.12]  # Optional: explicitly set IPs
```