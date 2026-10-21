load helpers

setup_file() {
  export NOROSETTA_NAME=lbi-norosetta
  REF="$(build_and_load norosetta "$(keyed_expr)")"
  export REF
  boot_container "$NOROSETTA_NAME" "$REF"
}

teardown_file() {
  container rm -f "$NOROSETTA_NAME" >/dev/null 2>&1 || true
  [ -z "${REF:-}" ] || container image rm "$REF" >/dev/null 2>&1 || true
}

@test "builder still logs in with the key" {
  run r true
  assert_success
}

@test "only the Rosetta units fail" {
  assert_no_failed_units 'systemd-binfmt\.service|run-rosetta\.mount'
}

@test "no Rosetta binfmt handler is registered" {
  run x '[ ! -e /proc/sys/fs/binfmt_misc/rosetta ]'
  assert_success
}

@test "the host still builds an aarch64-linux derivation on the builder over ssh-ng" {
  out="$(remote_build "$(probe_expr norosetta)")"
  run x "cat $out"
  assert_output ok
}
