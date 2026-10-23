#!/usr/bin/env bash
# niks3 --auth-token-script: exchanges (RFC 8693) the CI token in
# NIKS3_CI_TOKEN for a short-lived access token, re-run by niks3 before expiry.
set -euo pipefail

client=${NIKS3_CLIENT:-niks3}
printf '%s' "$NIKS3_CI_TOKEN" |
  curl -fsS "${NIKS3_TOKEN_URL:-https://id.channings.me/oauth2/token}" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d "audience=$client" \
    -d scope=openid \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d "client_id=$client" \
    --data-urlencode subject_token@- |
  jq -e 'if .access_token then {token: .access_token, expires_at: (now + (.expires_in // 900) | todate)} else error("niks3 token exchange returned no access_token") end'
