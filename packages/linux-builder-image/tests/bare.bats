load helpers

setup_file() {
  export BARE_NAME=lbi-bare
  REF="$(build_and_load bare pkg)"
  export REF
  boot_container "$BARE_NAME" "$REF" --rosetta
}

teardown_file() {
  container rm -f "$BARE_NAME" >/dev/null 2>&1 || true
  [ -z "${REF:-}" ] || container image rm "$REF" >/dev/null 2>&1 || true
}

@test "the archive's embedded ref equals passthru.imageRef" {
  run container image inspect "$REF"
  assert_success
}

@test "the bare base-profile image refuses the login" {
  run r true
  assert_failure
}
