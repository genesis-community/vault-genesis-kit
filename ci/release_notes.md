# Kit Breaking Changes

* Moved properties for vault job from instance-group level to job level. This
	is due to support for instance-group level properties being dropped by new
	versions of BOSH.

# Update to Genesis v2.7.0

* In order to use the alternate secrets mounts provided by Genesis v2.7.0, the
  kit has been updated to comply with its requirements.  You will need to use
  Genesis v2.7.0 or later to use this kit version.

# Updates

* Bumped version of Vault to 1.4.0
* Added `params.vault_domain` to allow setting the DNS SAN for the vault certs.
* Certificates for Vault are now generted by genesis for a TTL of 2y to satisfy new browser certificate constraints
	* You may need to run `genesis add-secrets` when upgrading to this version of the kit.
