load helpers

setup_file() {
  REF="$(build_and_load runtime-nix "$(keyed_expr)")"
  export REF CONTAINER=lbi-runtime-nix
  write_config "$BATS_FILE_TMPDIR"
  boot_mounted "$REF" "$BATS_FILE_TMPDIR" --rosetta
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

# Tests that restart a container get their own.
teardown() {
  container rm -f "lbi-runtime-nix-$BATS_TEST_NUMBER" >/dev/null 2>&1 || true
}

own_container() {
  CONTAINER="lbi-runtime-nix-$BATS_TEST_NUMBER"
}

# write_config <dir> [substituter]: <dir>/config/nix.conf, which includes
# <dir>/secrets/nested.conf from its /secrets mount.
write_config() {
  mkdir -p "$1/config" "$1/secrets"
  cat >"$1/config/nix.conf" <<CONF
extra-substituters = ${2:-https://lbi-config.invalid}
extra-sandbox-paths = /lbi-probe=/etc/resolv.conf
!include /secrets/nested.conf
CONF
  echo 'narinfo-cache-negative-ttl = 4242' >"$1/secrets/nested.conf"
}

nix_config() {
  x 'nix config show'
}

@test "/config's nix.conf, and the /secrets file it includes, are in effect" {
  run nix_config
  assert_line --regexp '^substituters = .*https://lbi-config\.invalid'
  assert_line 'narinfo-cache-negative-ttl = 4242'
}

@test "the daemon applies /config's nix.conf to builds as builder over ssh-ng" {
  out="$(remote_build "derivation { name = \"lbi-sandbox-probe-$(date +%s)-$RANDOM\"; system = \"aarch64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"read -r l < /lbi-probe; echo \$l > \$out\" ]; }")"
  run x "cat $out"
  assert_output "$(x 'head -1 /etc/resolv.conf')"
}

@test "builder's own nix works, without reading the root-only config" {
  run r 'nix config show'
  assert_success
  refute_output --partial lbi-config.invalid
  refute_line 'narinfo-cache-negative-ttl = 4242'
}

@test "the system is running with no failed units" {
  assert_no_failed_units
}

@test "editing /config on the host while running changes nothing" {
  own_container
  write_config "$BATS_TEST_TMPDIR"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  write_config "$BATS_TEST_TMPDIR" https://lbi-edited.invalid
  run nix_config
  assert_line --regexp '^substituters = .*https://lbi-config\.invalid'
  refute_output --partial lbi-edited
}

@test "a new container picks up the edited /config" {
  own_container
  write_config "$BATS_TEST_TMPDIR"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  write_config "$BATS_TEST_TMPDIR" https://lbi-edited.invalid
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  run nix_config
  assert_line --regexp '^substituters = .*https://lbi-edited\.invalid'
  refute_output --partial lbi-config.invalid
}

@test "a new container without the mounts keeps none of their settings" {
  own_container
  write_config "$BATS_TEST_TMPDIR"
  boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
  boot_container "$REF" --rosetta
  run nix_config
  refute_output --partial lbi-config.invalid
  refute_output --partial lbi-probe
  refute_line 'narinfo-cache-negative-ttl = 4242'
}
