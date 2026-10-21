# Runs once per bats invocation, whichever files are selected.
setup_suite() {
  command -v container >/dev/null || { echo >&2 "no \`container\` CLI"; return 1; }

  LBI_REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # This tree's kernel, whose CONFIG_EROFS_FS the image's /etc overlay needs.
  LBI_KERNEL="$(nix-build --fallback --no-out-link -E \
    "(builtins.getFlake (toString $LBI_REPO)).packages.\${builtins.currentSystem}.apple-container-kernel")/vmlinux-arm64"
  export LBI_REPO LBI_KERNEL

  # One key for every file, and boot_keyed's /config authorizing it.
  ssh-keygen -q -t ed25519 -N '' -C lbi-probe -f "$BATS_SUITE_TMPDIR/key"
  mkdir -p "$BATS_SUITE_TMPDIR/keyed/config/ssh/authorized_keys.d"
  cp "$BATS_SUITE_TMPDIR/key.pub" "$BATS_SUITE_TMPDIR/keyed/config/ssh/authorized_keys.d/builder"
}

teardown_suite() {
  [ -e "$BATS_RUN_TMPDIR/images" ] || return 0
  sort -u "$BATS_RUN_TMPDIR/images" | while read -r ref; do
    container image rm "$ref" >/dev/null 2>&1 || true
  done
}
