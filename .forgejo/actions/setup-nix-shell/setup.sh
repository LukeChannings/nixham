#!/usr/bin/env bash
set -euo pipefail

expr='let devShell = (import ./. { }).devShells.${builtins.currentSystem}; in devShell.ci or devShell.default'
path=$(nix print-dev-env --impure --expr "$expr" --json | jq -re '.variables.PATH.value')
echo "PATH=$path:$PATH" >>"$GITHUB_ENV"
