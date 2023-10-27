  safe_target_orig="$(safe target --json | jq -r .name)"
  genesis "do" "${DEPLOY_ENV}" -- init
  genesis "do" "${DEPLOY_ENV}" -- status
  safe get secret/vault/seal/keys
  safe target "$safe_target_orig"
