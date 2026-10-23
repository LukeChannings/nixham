setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/niks3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/niks3.calls"
n=$(wc -l <"$BATS_TEST_TMPDIR/niks3.calls")
[ "$n" -gt "${FAIL_CALLS:-0}" ] || exit 1
case "$1 $2" in
"pins list") printf '%s' "$PINS" ;;
"pins create") : ;;
*) exit 2 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/niks3"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export BACKOFF=0
  pin="$BATS_TEST_DIRNAME/../pin.sh"
}

@test "pins the path resolved from an existing pin" {
  export PINS='[{"name":"servant.abc","store_path":"/nix/store/aaa-x"}]'
  PIN_NAME=deployed.servant FROM_PIN=servant.abc run bash "$pin"

  assert_success
  run cat "$BATS_TEST_TMPDIR/niks3.calls"
  assert_line --index 0 --partial "pins list --json --auth-token-script"
  assert_line --index 1 --partial "deployed.servant /nix/store/aaa-x"
  assert_output --partial "niks3-push/token.sh"
  run cat "$GITHUB_OUTPUT"
  assert_line pinned=true
  assert_line store_path=/nix/store/aaa-x
}

@test "pins an explicit store path without listing" {
  PIN_NAME=deployed.servant STORE_PATH=/nix/store/bbb-y run bash "$pin"

  assert_success
  run cat "$BATS_TEST_TMPDIR/niks3.calls"
  assert_output --partial "pins create"
  refute_output --partial "pins list"
  run cat "$GITHUB_OUTPUT"
  assert_line pinned=true
  assert_line store_path=/nix/store/bbb-y
}

@test "succeeds with pinned=false when the source pin is absent" {
  export PINS='[]'
  PIN_NAME=deployed.servant FROM_PIN=servant.abc run bash "$pin"

  assert_success
  assert_output --partial "no pin named servant.abc"
  run cat "$BATS_TEST_TMPDIR/niks3.calls"
  refute_output --partial "pins create"
  run cat "$GITHUB_OUTPUT"
  assert_line pinned=false
  assert_line store_path=
}

@test "retries transient failures until a call succeeds" {
  export FAIL_CALLS=2
  PIN_NAME=p STORE_PATH=/nix/store/ccc-z ATTEMPTS=3 run bash "$pin"

  assert_success
  assert_output --partial "attempt 1/3"
  run cat "$GITHUB_OUTPUT"
  assert_line pinned=true
}

@test "fails after exhausting attempts" {
  export FAIL_CALLS=99
  PIN_NAME=p STORE_PATH=/nix/store/ccc-z ATTEMPTS=2 run bash "$pin"

  assert_failure
  assert_output --partial "could not pin p after 2 attempts"
}

@test "rejects neither or both of store_path and from_pin" {
  PIN_NAME=p run bash "$pin"
  assert_failure
  assert_output --partial "one of store_path or from_pin"

  PIN_NAME=p STORE_PATH=/nix/store/x FROM_PIN=y run bash "$pin"
  assert_failure
  assert_output --partial "mutually exclusive"
}
