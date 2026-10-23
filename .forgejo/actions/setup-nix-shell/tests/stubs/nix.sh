printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/nix.args"
[ -z "${NIX_ERROR:-}" ] || {
  echo "error: $NIX_ERROR" >&2
  exit 1
}
printf '%s' "$RESPONSE"
