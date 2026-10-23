# shellcheck shell=bash

own_container() {
  CONTAINER="lbi-runtime-ssh-$BATS_TEST_NUMBER"
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
