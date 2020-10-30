# Improvements

* If `params.vault_domain` is specified, the `target` addon will use the
  domain instead of the IP address in the safe target.

* The `target` addon will take a `<auth-type>` argument to specify how to
  authenticate to vault.  Defaults to `token` if unspecified, which is its
  previous exclusive method.

* Vault domain is now available in the exodus data.

* Adds support for explicit IPs by specifying a list under `params.ips` in the
  environment, and automatically calculates the number of instances based on
  that list of IPs.

* Update post-deploy output for new behaviour:

  Only print info about initializing and unsealing the vault if it wasn't
  able to be insealed automatically.

  KV Secrets Engine v2 is now on by default, but will not upgrade existing
  mounts.  Updated post-deploy text to let users know how to upgrade if
  they still have a v1 engine.

  Also prints out the status after insealing vault.

# Bug Fixes

* Fix predeploy to grab unseal keys from target vault (#16)

  Prior to this change, keys were being grabbed from the active vault
  being used to deploy this vault.  If that vault also had vault unseal
  keys, they would be grabbed, but fail to unseal this fault in the
  post-deploy hook.

* Failed cloud config checks will now exit non-zero.

  This is part of the solution to ensure that if cloud-config checks fail,
  the deployment won't continue.  The other half of this fix will be
  provided in genesis v2.7.19.

