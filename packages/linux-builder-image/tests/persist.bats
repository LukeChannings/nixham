load helpers

setup_file() {
  # Image B differs from A only by an /etc file: a different system, so a
  # different store-path closure under the same volume.
  REF_A="$(build_and_load a "$(keyed_expr)")"
  REF_B="$(build_and_load b "pkg.override { modules = [ $(key_module) { environment.etc.lbi-persist-b.text = \"b\"; } ]; }")"
  export REF_A REF_B
  [ "$REF_A" != "$REF_B" ]
}

# Every test has a fresh volume and container of its own.
setup() {
  CONTAINER="lbi-persist-$BATS_TEST_NUMBER" VOLUME="lbi-persist-$BATS_TEST_NUMBER"
  teardown
  container volume create "$VOLUME" >/dev/null
}

teardown() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  container volume rm "$VOLUME" >/dev/null 2>&1 || true
  if [ -e "$BATS_TEST_TMPDIR/imported" ]; then
    xargs nix-store --delete <"$BATS_TEST_TMPDIR/imported" >/dev/null 2>&1 || true
  fi
}

# Boot $1 against the store volume, the way the module does it: a fresh
# container (rm + run) every time, the volume is the only state carried over.
boot() {
  boot_container "$1" --rosetta -v "$VOLUME:/persist"
  r true
  assert_no_failed_units
}

stop() {
  container stop "$CONTAINER" >/dev/null
}

uncleanWarning="previous shutdown was not clean"
assert_clean_previous_shutdown() {
  run logs
  refute_output --partial "$uncleanWarning"
}

probe() {
  remote_build "import $BATS_TEST_DIRNAME/probe-drv.nix { tag = \"$1-$(date +%s)-$RANDOM\"; }"
}

@test "image A boots on a fresh volume and seeds the Nix DB onto it" {
  boot "$REF_A"
  run logs
  refute_output --partial 'STORE IS EPHEMERAL'
  assert_output --partial 'seeding the Nix DB'
  run x 'cat /nix/var/nix/linux-builder-seeded-system'
  assert_output "$(x 'readlink -f /run/booted-system')"
  x '[ -s /persist/upper/var/nix/db/db.sqlite ]'
}

@test "/nix is an overlay with its upper on the volume, and /nix/store stays read-only" {
  boot "$REF_A"
  run x 'findmnt -n -o FSTYPE /nix'
  assert_output overlay
  run x 'findmnt -n -o OPTIONS /nix'
  assert_output --partial upperdir=/persist/upper
  run x 'findmnt -n -o OPTIONS --direction backward --first-only /nix/store | tr , "\n"'
  assert_line ro
}

@test "outputs survive stop + restart" {
  boot "$REF_A"
  out="$(probe persist)"
  x "[ -e /persist/upper/store/${out#/nix/store/} ]"
  hostKey="$(x 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub')"

  stop
  boot "$REF_A"

  assert_clean_previous_shutdown
  x "nix-store --check-validity $out && nix-store --verify-path $out"
  run x 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub'
  assert_output "$hostKey"
  run logs
  refute_output --partial 'seeding the Nix DB'
}

@test "an output built just before an idle stop imports on the host without a hash mismatch" {
  boot "$REF_A"
  out="$(probe dirty)"
  stop
  boot "$REF_A"
  assert_clean_previous_shutdown

  run env PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]} -i $SSH_KEY" \
    nix copy --no-check-sigs --from "ssh-ng://$SSH_USER@$(current_ip)" "$out"
  echo "$out" >"$BATS_TEST_TMPDIR/imported"
  assert_success
  refute_output --partial 'hash mismatch'
  x "nix-store --verify-path $out"
}

@test "the next boot flags a teardown that never reached the sync hook" {
  boot "$REF_A"
  container kill "$CONTAINER" >/dev/null
  boot "$REF_A"
  run logs
  assert_output --partial "$uncleanWarning"
}

@test "image B under A's volume drops A's phantom entries and keeps the volume's outputs" {
  boot "$REF_A"
  sysA="$(x 'readlink -f /run/booted-system')"
  out="$(probe image-change)"
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
  x "nix-store --check-validity $out"
}

@test "GC keeps the baked closure, and the builder reboots cleanly after it" {
  boot "$REF_A"
  garbage="$(probe garbage)"
  x 'nix-collect-garbage -d' >/dev/null
  x "[ ! -e $garbage ]"
  x 'nix-store -qR /run/booted-system | while read -r p; do [ -e "$p" ] || { echo "missing $p"; exit 1; }; done'
  x 'nix-store --verify --check-contents'
  stop
  boot "$REF_A"
}
