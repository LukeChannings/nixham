load helpers

setup_file() {
  export PERSIST_NAME=lbi-persist VOLUME=lbi-persist-store
  # Image B differs from A only by an /etc file: a different system, so a
  # different store-path closure under the same volume.
  REF_A="$(build_and_load a "$(keyed_expr)")"
  REF_B="$(build_and_load b "pkg.override { modules = [ $(key_module) { environment.etc.lbi-persist-b.text = \"b\"; } ]; }")"
  export REF_A REF_B
  [ "$REF_A" != "$REF_B" ]

  container rm -f "$PERSIST_NAME" >/dev/null 2>&1 || true
  container volume rm "$VOLUME" >/dev/null 2>&1 || true
  container volume create "$VOLUME" >/dev/null
}

teardown_file() {
  container rm -f "$PERSIST_NAME" >/dev/null 2>&1 || true
  container volume rm "$VOLUME" >/dev/null 2>&1 || true
  for i in "${REF_A:-}" "${REF_B:-}"; do
    [ -z "$i" ] || container image rm "$i" >/dev/null 2>&1 || true
  done
  if [ -e "$BATS_FILE_TMPDIR/imported" ]; then
    while read -r p; do nix-store --delete "$p" >/dev/null 2>&1 || true; done <"$BATS_FILE_TMPDIR/imported"
  fi
}

# The tests are a story: once one fails, the rest have nothing to stand on.
setup() {
  [ ! -e "$BATS_FILE_TMPDIR/failed" ] || skip "an earlier test failed"
}

teardown() {
  [ -n "${BATS_TEST_COMPLETED:-}" ] || touch "$BATS_FILE_TMPDIR/failed"
}

# Values shared between tests.
put() { echo "$2" >"$BATS_FILE_TMPDIR/$1"; }
get() { cat "$BATS_FILE_TMPDIR/$1"; }

# Boot $1 against the store volume, the way the module does it: a fresh
# container (rm + run) every time, the volume is the only state carried over.
boot() {
  boot_container "$PERSIST_NAME" "$1" --rosetta -v "$VOLUME:/persist"
  r true
  assert_no_failed_units
}

stop() {
  container stop "$PERSIST_NAME" >/dev/null
}

logs() {
  container logs "$PERSIST_NAME" 2>/dev/null || true
}

uncleanWarning="previous shutdown was not clean"
assert_clean_previous_shutdown() {
  run logs
  refute_output --partial "$uncleanWarning"
}

probe() {
  remote_build "import $BATS_TEST_DIRNAME/probe-drv.nix { tag = \"$1-$(date +%s)-$RANDOM\"; }"
}

@test "image A boots on a fresh volume" {
  boot "$REF_A"
  put sysA "$(x 'readlink -f /run/booted-system')"
}

@test "/nix is an overlay with its upper on the volume, and /nix/store stays read-only" {
  run x 'findmnt -n -o FSTYPE /nix'
  assert_output overlay
  run x 'findmnt -n -o OPTIONS /nix'
  assert_output --partial upperdir=/persist/upper
  run x 'findmnt -n -o OPTIONS --direction backward --first-only /nix/store | tr , "\n"'
  assert_line ro
}

@test "the Nix DB is seeded onto the volume" {
  run logs
  refute_output --partial 'STORE IS EPHEMERAL'
  assert_output --partial 'seeding the Nix DB'
  run x 'cat /nix/var/nix/linux-builder-seeded-system'
  assert_output "$(get sysA)"
  x '[ -s /persist/upper/var/nix/db/db.sqlite ]'
}

@test "outputs survive stop + restart" {
  out1="$(probe persist)"
  put out1 "$out1"
  x "[ -e /persist/upper/store/${out1#/nix/store/} ]"
  put hostKey "$(x 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub')"

  stop
  boot "$REF_A"

  assert_clean_previous_shutdown
  x "nix-store --check-validity $out1 && nix-store --verify-path $out1"
  run x 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub'
  assert_output "$(get hostKey)"
  run logs
  refute_output --partial 'seeding the Nix DB'
}

@test "an output built just before an idle stop imports on the host without a hash mismatch" {
  out2="$(probe dirty)"
  put out2 "$out2"
  stop
  boot "$REF_A"
  assert_clean_previous_shutdown

  run env PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]}" \
    nix copy --no-check-sigs --from "ssh-ng://$SSH_USER@$(current_ip)" "$out2"
  echo "$out2" >>"$BATS_FILE_TMPDIR/imported"
  assert_success
  refute_output --partial 'hash mismatch'
  x "nix-store --verify-path $out2"
}

@test "the next boot flags a teardown that never reached the sync hook" {
  container kill "$PERSIST_NAME" >/dev/null
  boot "$REF_A"
  run logs
  assert_output --partial "$uncleanWarning"
}

@test "image B under A's volume drops A's phantom entries and keeps the volume's outputs" {
  local sysA
  sysA="$(get sysA)"
  stop
  boot "$REF_B"

  assert_clean_previous_shutdown
  sysB="$(x 'readlink -f /run/booted-system')"
  assert_not_equal "$sysA" "$sysB"
  run logs
  assert_output --partial 'reconciling the persisted Nix DB'
  run x 'cat /nix/var/nix/linux-builder-seeded-system'
  assert_output "$sysB"
  x "[ ! -e $sysA ]"
  run x "nix-store --check-validity $sysA"
  assert_failure
  x 'nix-store --verify'
  x "nix-store --check-validity $(get out1) $(get out2)"
}

@test "GC keeps the baked closure, and the builder reboots cleanly after it" {
  garbage="$(probe garbage)"
  x 'nix-collect-garbage -d' >/dev/null
  x "[ ! -e $garbage ]"
  x 'nix-store -qR /run/booted-system | while read -r p; do [ -e "$p" ] || { echo "missing $p"; exit 1; }; done'
  x 'nix-store --verify --check-contents'
  stop
  boot "$REF_B"
}
