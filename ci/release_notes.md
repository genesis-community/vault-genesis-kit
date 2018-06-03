This release marks a milestone for the Vault Genesis Kit in
particular, and for Genesis as a larger ecosystem; this is the
first version of the Vault Genesis Kit to support the newfangled
features and capabilities of Genesis 2.6.

Genesis 2.6 is a backwards-compatible, yet forward-thinking
iteration on the Genesis v2 codebase.  While it maintains the
concept of kits and environment files (a mainstay of Genesis), it
expands upon the power given to kit authors, and helps them help
operators in a more constructive fashion.

This release of the Vault Genesis kit **requires** that you
upgrade to [Genesis v2.6.0 or greater][1].  (Obviously, for
security reasons and bug fixes, you'll want to choose the latest
available release)

## New Features

- Azure is now automatically detected by the kit, via the BOSH CPI
  reported by the targeted director.  This means that the swap-out
  of availability zones (a BOSH concept) for availability sets (an
  Azure concept) is seamless, and does not require a feature flag
  to be set in your environment files.

- The `genesis do <env> -- target` addon task sets up a safe
  target for you, by interrogating BOSH for the possible node IPs,
  and trying each in turn until one answers.

- The `genesis do <env> -- init` addon task allows you to
  initialize a newly-deployed Vault, with minimal hassle.

- The `genesis do <env> -- seal` and `genesis do <env> -- unseal`
  addons allow you to seal and unseal a deployed Vault, without
  having to remember the appropriate `safe` commands, and without
  mucking about with your current safe target.

- The `genesis do <env> -- status` addon will inform you of health
  and availability of the Vault nodes, and their seal status.

- New pre-deploy and post-deploy hooks now safely unseal the Vault
  after a successful deployment, without you having to provide
  concourse with the seal keys directly, and without storing them
  "in the clear" anywhere.

[1]: https://github.com/starkandwayne/genesis/releases/tag/v2.6.0
