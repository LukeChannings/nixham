load helpers

setup_file() {
  export CONTAINER=lbi-bare
  REF="$(build_and_load bare pkg)"
  export REF
  boot_container "$REF" --rosetta
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

@test "the archive's embedded ref equals passthru.imageRef" {
  run container image inspect "$REF"
  assert_success
}

@test "the bare base-profile image refuses the login" {
  run r true
  assert_failure
}
