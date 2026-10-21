load helpers

setup_file() {
  REF="$(build_and_load bare pkg)"
  export REF CONTAINER=lbi-runtime-ssh
  authorize "$BATS_FILE_TMPDIR" builder "$SSH_KEY"
  authorize "$BATS_FILE_TMPDIR" root "$SSH_KEY"
  ssh-keygen -q -t ed25519 -N '' -C lbi-user-ca -f "$BATS_FILE_TMPDIR/user-ca"
  trust_user_ca "$BATS_FILE_TMPDIR"
  mount_host_key "$BATS_FILE_TMPDIR"
  ssh-keygen -q -t ed25519 -N '' -C lbi-host-ca -f "$BATS_FILE_TMPDIR/host-ca"
  ssh-keygen -q -s "$BATS_FILE_TMPDIR/host-ca" -h -I lbi-host -n lbi-builder "$BATS_FILE_TMPDIR/config/ssh/ssh_host_ed25519_key.pub"
  boot_mounted "$REF" "$BATS_FILE_TMPDIR" --rosetta
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

# Tests that restart a container get their own, and a volume to go with it.
teardown() {
  container rm -f "lbi-runtime-ssh-$BATS_TEST_NUMBER" >/dev/null 2>&1 || true
  container volume rm "lbi-runtime-ssh-$BATS_TEST_NUMBER" >/dev/null 2>&1 || true
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

# trust_user_ca <dir>: <dir>/config/ssh/trusted_user_ca_keys holds the file's
# user CA.
trust_user_ca() {
  mkdir -p "$1/config/ssh"
  cat "$BATS_FILE_TMPDIR/user-ca.pub" >"$1/config/ssh/trusted_user_ca_keys"
}

# mount_host_key <dir>: a fresh <dir>/config/ssh/ssh_host_ed25519_key.
mount_host_key() {
  mkdir -p "$1/config/ssh"
  ssh-keygen -q -t ed25519 -N '' -C lbi-host -f "$1/config/ssh/ssh_host_ed25519_key"
}

# The ed25519 host key $CONTAINER presents, as "<type> <base64>".
host_key() {
  /usr/bin/ssh-keyscan -t ed25519 "$(current_ip)" 2>/dev/null | awk '!/^#/ { print $2, $3 }'
}

# The public half of <dir>'s mounted host key, as host_key prints it.
mounted_host_key() {
  awk '{ print $1, $2 }' "$1/config/ssh/ssh_host_ed25519_key.pub"
}

# strict_r <known_hosts line> [-o option...] <command...>: r, trusting only
# that line.
strict_r() {
  local opts=()
  echo "$1" >"$BATS_TEST_TMPDIR/known_hosts"
  shift
  while [ "${1:-}" = -o ]; do opts+=("$1" "$2") && shift 2; done
  "$SSH" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$BATS_TEST_TMPDIR/known_hosts" "${opts[@]}" \
    "${SSHO[@]}" -i "$SSH_KEY" "$SSH_USER@$(current_ip)" "$@"
}

# new_key <name>: a fresh key in the test's temp dir; prints its path.
new_key() {
  ssh-keygen -q -t ed25519 -N '' -C "lbi-$1" -f "$BATS_TEST_TMPDIR/$1"
  echo "$BATS_TEST_TMPDIR/$1"
}

# new_cert <name> <principal>: new_key, with a certificate from the file's
# user CA for <principal> next to it, where ssh picks it up.
new_cert() {
  new_key "$1" >/dev/null
  ssh-keygen -q -s "$BATS_FILE_TMPDIR/user-ca" -I "lbi-$1" -n "$2" "$BATS_TEST_TMPDIR/$1.pub"
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

@test "a certificate from a trusted user CA, for principal builder, logs in as builder" {
  SSH_KEY="$(new_cert cert builder)" run r whoami
  assert_output builder
}

@test "a certificate from a trusted user CA for another principal is refused" {
  SSH_KEY="$(new_cert cert someone-else)" run r true
  assert_failure
}

@test "a new container without the trusted user CA refuses its certificates" {
  own_container
  trust_user_ca "$BATS_TEST_TMPDIR"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  key="$(new_cert cert builder)"
  SSH_KEY="$key" r true
  boot_container "$REF" --rosetta
  SSH_KEY="$key" run r true
  assert_failure
}

@test "the mounted host key is the one presented, and a client pinning it connects" {
  assert_equal "$(host_key)" "$(mounted_host_key "$BATS_FILE_TMPDIR")"
  run strict_r "$(current_ip) $(mounted_host_key "$BATS_FILE_TMPDIR")" whoami
  assert_output builder
}

@test "with a store volume, the persisted host key outlives a mounted one, which never reaches the volume" {
  own_container
  container volume create "$CONTAINER" >/dev/null
  authorize "$BATS_TEST_TMPDIR" builder "$SSH_KEY"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta -v "$CONTAINER:/persist"
  persisted="$(host_key)"
  assert [ -n "$persisted" ]

  mount_host_key "$BATS_TEST_TMPDIR"
  mounted="$(mounted_host_key "$BATS_TEST_TMPDIR")"
  digest="$(shasum -a 256 "$BATS_TEST_TMPDIR/config/ssh/ssh_host_ed25519_key" | cut -d' ' -f1)"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta -v "$CONTAINER:/persist"
  assert_equal "$(host_key)" "$mounted"

  rm "$BATS_TEST_TMPDIR"/config/ssh/ssh_host_ed25519_key*
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta -v "$CONTAINER:/persist"
  assert_equal "$(host_key)" "$persisted"
  run x "find /persist -type f -exec sha256sum {} + | grep -F $digest; grep -rlF '${mounted#* }' /persist"
  refute_output
}

@test "with the mounted host key's certificate, a client trusting only its CA connects" {
  run strict_r "@cert-authority * $(cat "$BATS_FILE_TMPDIR/host-ca.pub")" -o HostKeyAlias=lbi-builder whoami
  assert_output builder
}

@test "a host certificate without its host key is ignored, with a warning" {
  own_container
  authorize "$BATS_TEST_TMPDIR" builder "$SSH_KEY"
  cp "$BATS_FILE_TMPDIR/config/ssh/ssh_host_ed25519_key-cert.pub" "$BATS_TEST_TMPDIR/config/ssh/"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  run logs
  assert_output --regexp 'linux-builder: WARN .*ssh_host_ed25519_key-cert\.pub'
  assert_equal "$(host_key)" "$(x 'cut -d" " -f1,2 /persist/ssh/ssh_host_ed25519_key.pub')"
  r true
}
