# Upgrade Guide

This document provides guidance on upgrading your Vault deployment between different versions of the Vault Genesis Kit.

## General Upgrade Procedure

1. **Backup**: Always ensure you have a proper backup of your Vault data before upgrading
2. **Review Release Notes**: Check for any breaking changes or new features
3. **Update Kit Version**: Change the kit version in your deployment manifest
4. **Deploy**: Run the Genesis deploy command
5. **Unseal**: Use the unseal addon to unseal the Vault after deployment

```bash
# Example upgrade process
genesis deploy my-vault
genesis do my-vault -- unseal
```

## Upgrading from v1.x to v2.0.0

Version 2.0.0 introduces several new features and changes:

- Added support for STACKIT and OCFP cloud providers
- Updated to newer stemcell versions
- Refactored hooks into Perl modules with addon functions

### Breaking Changes

- The `shield` feature that was deprecated in v1.2.0 has been removed in v2.0.0
- Minimum Genesis version requirement is now 3.1.0 or higher

### Upgrade Steps

1. Update your deployment manifest to use kit version 2.0.0:

   ```yaml
   kit:
     name: vault
     version: 2.0.0
   ```

2. If you were using the deprecated `shield` feature, remove it from your manifest and instead use BOSH runtime configs to colocate addon jobs.

3. Ensure you're using Genesis 3.1.0 or higher:

   ```bash
   genesis --version
   ```

4. Deploy the updated version:

   ```bash
   genesis deploy my-vault
   ```

5. After deployment, the Vault will be sealed. Unseal it using:

   ```bash
   genesis do my-vault -- unseal
   ```

## Upgrading from v1.1.0 to v1.2.0

Version 1.2.0 introduced Genesis 2.6 hooks for addon scripts and improved `genesis info` support.

### Breaking Changes

- The `shield` feature was deprecated in v1.2.0 in favor of BOSH runtime configs

### Upgrade Steps

1. Update your deployment manifest to use kit version 1.2.0:

   ```yaml
   kit:
     name: vault
     version: 1.2.0
   ```

2. If you were using the `shield` feature, it will continue to work in v1.2.0, but consider migrating to BOSH runtime configs.

3. Deploy the updated version:

   ```bash
   genesis deploy my-vault
   ```

4. After deployment, the Vault will be sealed. Unseal it using:

   ```bash
   genesis do my-vault -- unseal
   ```

## Version Compatibility Matrix

| Vault Kit Version | Minimum Genesis Version | Supported Cloud Providers | Notes |
|-------------------|-------------------------|---------------------------|-------|
| 2.0.0             | 3.1.0                   | AWS, Azure, GCP, vSphere, STACKIT, OCFP | Removed deprecated `shield` feature |
| 1.2.0             | 2.6.0                   | AWS, Azure, GCP, vSphere  | Deprecated `shield` feature |
| 1.1.0             | 2.5.0                   | AWS, Azure, GCP, vSphere  | Last version with `shield` feature support |
| 1.0.0             | 2.0.0                   | AWS, Azure, GCP, vSphere  | Initial release |

## Important Notes

- Vault will always seal itself after deployment, regardless of version upgrade or not
- After any upgrade, you must explicitly unseal the Vault
- Keep your seal keys and root token in a secure external location (not in the Vault itself)
- Consider testing the upgrade in a non-production environment first