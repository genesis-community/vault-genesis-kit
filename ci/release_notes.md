# Kit Breaking Changes

* Moved properties for vault job from instance-group level to job level. This
	is due to support for instance-group level properties being dropped by new
	versions of BOSH.

# Updates

* Bumped version of Vault to 1.4.0
* Added `params.vault_domain` to allow setting the DNS SAN for the vault certs.
* Certificates for Vault are now generted by genesis for a TTL of 2y to satisfy new browser certificate constraints
	* You may need to run `genesis add-secrets` when upgrading to this version of the kit.