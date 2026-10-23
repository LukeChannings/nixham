#!/usr/bin/env bash
# Each niks3 call re-mints a fresh aud=niks3 token (token.sh): the usual
# seeded token lives ~15m, shorter than many jobs that pin at their end.
set -euo pipefail

: "${PIN_NAME:?PIN_NAME is required}"
if [ -n "${STORE_PATH:-}" ] && [ -n "${FROM_PIN:-}" ]; then
  echo "::error::store_path and from_pin are mutually exclusive" >&2
  exit 1
fi
if [ -z "${STORE_PATH:-}" ] && [ -z "${FROM_PIN:-}" ]; then
  echo "::error::one of store_path or from_pin is required" >&2
  exit 1
fi

niks3=${NIKS3_BIN:-niks3}
mint="${BASH:-bash} $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../niks3-push/token.sh"
attempts=${ATTEMPTS:-5}
backoff=${BACKOFF:-10}

emit() {
  printf 'pinned=%s\nstore_path=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"
}

attempt() {
  local path=${STORE_PATH:-} pins
  if [ -z "$path" ]; then
    pins=$("$niks3" pins list --json --auth-token-script "$mint") || return
    path=$(jq -r --arg n "$FROM_PIN" \
      '.[] | select(.name == $n) | .store_path' <<<"$pins" | head -n1)
    if [ -z "$path" ]; then
      echo "::warning::no pin named $FROM_PIN; nothing to pin as $PIN_NAME" >&2
      emit false ""
      exit 0
    fi
  fi
  "$niks3" pins create --auth-token-script "$mint" "$PIN_NAME" "$path" || return
  echo "Pinned $PIN_NAME -> $path"
  emit true "$path"
  exit 0
}

for i in $(seq 1 "$attempts"); do
  [ "$i" -eq 1 ] || sleep $(((i - 1) * backoff))
  attempt || true
  echo "::warning::pinning $PIN_NAME failed (attempt $i/$attempts)" >&2
done
echo "::error::could not pin $PIN_NAME after $attempts attempts" >&2
exit 1
