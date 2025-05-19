# Troubleshooting Guide

This document provides solutions for common issues encountered when deploying and managing a Vault cluster with the Vault Genesis Kit.

## Deployment Issues

### Failed BOSH Deployment

**Symptom**: The `genesis deploy` command fails with BOSH errors.

**Possible Causes and Solutions**:

1. **Cloud config mismatch**:
   - Ensure that the networks, VM types, and disk types specified in your deployment manifest exist in your BOSH cloud config.
   - Use `bosh cloud-config` to verify available resources.

2. **Network connectivity issues**:
   - Verify that the specified network has proper connectivity.
   - Check security groups and firewall rules to ensure VM-to-VM communication is allowed.

3. **Resource constraints**:
   - Ensure your IaaS has sufficient resources to deploy the VMs.

**Resolution Steps**:
```bash
# Check the detailed deployment errors
bosh -d vault task-result <task-id>

# Validate your cloud config against your deployment needs
bosh cloud-config | grep <resource-name>
```

## Vault Operation Issues

### Vault Remains Sealed After Deployment

**Symptom**: The Vault remains in a sealed state after deployment.

**Solution**: This is normal and expected behavior. For security reasons, Vault always starts in a sealed state after deployment. You must explicitly unseal it:

```bash
genesis do my-vault -- unseal
```

### Cannot Unseal Vault

**Symptom**: The unseal operation fails.

**Possible Causes**:

1. **Missing or incorrect seal keys**:
   - Ensure you have the correct seal keys from when the Vault was initialized.

2. **Network connectivity issues**:
   - Verify connectivity to all Vault nodes.

3. **Auxiliary Vault parameter**:
   - If you're deploying a secondary Vault with `auxiliary_vault: true`, automatic unsealing is disabled.

**Resolution Steps**:
```bash
# Check Vault status first
genesis do my-vault -- status

# Manually unseal if needed, using your seal keys
safe target my-vault
safe unseal
```

### Consul Consensus Issues

**Symptom**: Consul cluster is not forming properly, causing Vault to malfunction.

**Possible Causes**:

1. **Not enough nodes available**:
   - Consul requires a quorum (N/2+1) of nodes to be operational.

2. **Network connectivity issues between nodes**:
   - Verify connectivity between all Consul nodes.

**Resolution Steps**:
```bash
# SSH into one of the Vault VMs
bosh -d vault ssh vault/0

# Check Consul cluster status
consul members

# Check Consul logs
sudo tail -f /var/vcap/sys/log/consul/consul.log
```

## Authentication Issues

### Cannot Target Vault with Safe

**Symptom**: The `safe target` command fails to connect to Vault.

**Possible Causes**:

1. **Vault is sealed**:
   - Verify if Vault is unsealed using the status addon.

2. **Network connectivity issues**:
   - Check if you can reach the Vault API endpoint.

3. **Certificate issues**:
   - Verify that the Vault certificate is valid and trusted.

**Resolution Steps**:
```bash
# Check Vault status
genesis do my-vault -- status

# Try using the target addon with debug logging
SAFE_DEBUG=1 genesis do my-vault -- target
```

### Lost Root Token

**Symptom**: You've lost the root token and cannot administer Vault.

**Solution**: If you've lost the root token, you can generate a new one using the seal keys:

```bash
# SSH into one of the Vault VMs
bosh -d vault ssh vault/0

# Generate a new root token
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=1
vault operator generate-root -init
# Follow the prompts to create a new root token using your seal keys
```

## BOSH Connectivity Issues

### Cannot SSH to Vault VMs

**Symptom**: Unable to SSH to Vault VMs using BOSH.

**Possible Causes**:

1. **BOSH connectivity issues**:
   - Ensure your BOSH CLI is properly configured.

2. **VM state issues**:
   - The VM might be in a bad state.

**Resolution Steps**:
```bash
# Check VM states
bosh -d vault instances

# Attempt to recreate problematic VMs
bosh -d vault recreate vault/<index>
```

## Genesis Addon Issues

### Addons Not Working

**Symptom**: Genesis addons for Vault (init, seal, unseal, etc.) are not working properly.

**Possible Causes**:

1. **Outdated Genesis version**:
   - Ensure you're using Genesis 3.1.0 or higher for Vault Kit 2.0.0.

2. **Incorrect deployment**:
   - Verify that the deployment was created with the Vault Genesis Kit.

**Resolution Steps**:
```bash
# Check Genesis version
genesis --version

# Verify kit version in deployment manifest
grep -A 3 "kit:" my-vault-deployments/my-vault.yml
```

## Performance Issues

### Slow Vault Operations

**Symptom**: Vault operations are unusually slow.

**Possible Causes**:

1. **Inadequate resources**:
   - VM size may be too small for the workload.

2. **Consul backend issues**:
   - Consul might be experiencing performance problems.

**Resolution Steps**:
```bash
# Check VM resource utilization
bosh -d vault ssh vault/0 -c "top -bn1"

# Check Consul health
bosh -d vault ssh vault/0 -c "consul info"
```

## Getting Additional Help

If you continue to experience issues after trying the troubleshooting steps above, consider the following resources:

1. Open an issue on the [Vault Genesis Kit GitHub repository](https://github.com/genesis-community/vault-genesis-kit)
2. Consult the [HashiCorp Vault documentation](https://www.vaultproject.io/docs) for Vault-specific issues
3. Check the [Genesis Project documentation](https://genesisproject.io/docs/) for Genesis-specific issues