#!/usr/bin/env bash
# niks3 --auth-token-script: exchanges (RFC 8693) the Kanidm CI token in
# NIKS3_CI_TOKEN for a short-lived aud=niks3 token, re-run by niks3 before expiry.
set -euo pipefail

printf '%s' "$NIKS3_CI_TOKEN" | curl -fsS https://id.channings.me/oauth2/token \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d audience=niks3 \
  -d scope=openid \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d client_id=niks3 \
  --data-urlencode subject_token@- |
  jq -e 'if .access_token then {token: .access_token, expires_at: (now + (.expires_in // 900) | todate)} else error("niks3 token exchange returned no access_token") end'
