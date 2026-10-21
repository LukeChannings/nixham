#!/usr/bin/env bash
set -euo pipefail

exec bats "$(dirname "${BASH_SOURCE[0]}")/tests" "$@"
