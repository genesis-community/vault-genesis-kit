# Improvements

- Added `auxiliary-vault` parameter, which when set to `true` will skip the
  automatic initialization and unseal after deploy. This should be set to `true`
  when deploying a Vault for non-Genesis related secret storage. The default is
  `false`.
