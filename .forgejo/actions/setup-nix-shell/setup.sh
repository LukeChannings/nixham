#!/usr/bin/env bash
set -euo pipefail

expr='let devShell = (import ./. { }).devShells.${builtins.currentSystem}; in devShell.ci or devShell.default'
json=$(nix print-dev-env --impure --expr "$expr" --json)

# The ignored variables mirror nix develop's ignoreVars:
# https://github.com/NixOS/nix/blob/master/src/nix/develop.cc
env=$(jq -r --arg path "$PATH" --arg eof "EOF_$RANDOM$RANDOM$RANDOM" '
  .variables
  | if .PATH then .PATH.value += ":" + $path else error("devshell has no PATH") end
  | del(.BASHOPTS, .HOME, .NIX_BUILD_TOP, .NIX_ENFORCE_PURITY, .NIX_LOG_FD,
      .NIX_REMOTE, .PPID, .SHELLOPTS, .SSL_CERT_FILE, .TEMP, .TEMPDIR, .TERM,
      .TMP, .TMPDIR, .TZ, .UID)
  | to_entries[]
  | select(.value.type == "exported")
  | "\(.key)<<\($eof)\n\(.value.value)\n\($eof)"
' <<<"$json")
echo "$env" >>"$GITHUB_ENV"
