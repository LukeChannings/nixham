# shellcheck shell=bash
bats_load_library bats-support
bats_load_library bats-assert

# stub <dir>: each <dir>/<name>.sh runs as <name>, first on PATH.
stub() {
  local f
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for f in "$1"/*.sh; do
    printf '#!%s\nexec %q %q "$@"\n' "$BASH" "$BASH" "$f" >"$BATS_TEST_TMPDIR/bin/$(basename "$f" .sh)"
    chmod +x "$BATS_TEST_TMPDIR/bin/$(basename "$f" .sh)"
  done
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# assert_bash <file>: it parses as bash.
assert_bash() {
  bash -n "$1" || fail "$1 is not valid bash"
}
