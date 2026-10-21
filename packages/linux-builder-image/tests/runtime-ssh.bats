load helpers

setup_file() {
  REF="$(build_and_load bare pkg)"
  export REF CONTAINER=lbi-runtime-ssh
  authorize "$BATS_FILE_TMPDIR" builder "$SSH_KEY"
  authorize "$BATS_FILE_TMPDIR" root "$SSH_KEY"
  boot_mounted "$REF" "$BATS_FILE_TMPDIR" --rosetta
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

# Tests that restart a container get their own.
teardown() {
  container rm -f "lbi-runtime-ssh-$BATS_TEST_NUMBER" >/dev/null 2>&1 || true
}

own_container() {
  CONTAINER="lbi-runtime-ssh-$BATS_TEST_NUMBER"
}

# authorize <dir> <user> <key>: <dir>/config/ssh/authorized_keys.d/<user>
# authorizes only <key>.
authorize() {
  mkdir -p "$1/config/ssh/authorized_keys.d"
  cat "$3.pub" >"$1/config/ssh/authorized_keys.d/$2"
}

# new_key <name>: a fresh key in the test's temp dir; prints its path.
new_key() {
  ssh-keygen -q -t ed25519 -N '' -C "lbi-$1" -f "$BATS_TEST_TMPDIR/$1"
  echo "$BATS_TEST_TMPDIR/$1"
}

@test "builder logs in with a key from /config/ssh/authorized_keys.d" {
  run r whoami
  assert_output builder
}

@test "an unrelated key is refused" {
  SSH_KEY="$(new_key unrelated)" run r true
  assert_failure
}

@test "root is refused despite its authorized_keys.d file" {
  SSH_USER=root run r true
  assert_failure
}

@test "replacing the key file on the host while running changes nothing" {
  own_container
  authorize "$BATS_TEST_TMPDIR" builder "$SSH_KEY"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  key="$(new_key replacement)"
  authorize "$BATS_TEST_TMPDIR" builder "$key"
  r true
  SSH_KEY="$key" run r true
  assert_failure
}

@test "a new container takes the replaced key file, and refuses the old key" {
  own_container
  authorize "$BATS_TEST_TMPDIR" builder "$SSH_KEY"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  key="$(new_key replacement)"
  authorize "$BATS_TEST_TMPDIR" builder "$key"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  SSH_KEY="$key" r true
  run r true
  assert_failure
}
