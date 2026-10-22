#!/usr/bin/env bash
set -euo pipefail

command -v container >/dev/null || {
  echo >&2 'skipping: no `container` CLI'
  exit 0
}

exec bats "$(dirname "${BASH_SOURCE[0]}")/tests" "$@"
