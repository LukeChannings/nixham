load helpers

setup_file() {
  export CONTAINER=lbi-keyed
  REF="$(build_and_load keyed "pkg.override { modules = [ $(key_module builder root) ]; }")"
  export REF
  boot_container "$REF" --rosetta
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

x86() {
  echo "let pkgs = import (builtins.getFlake (toString $LBI_REPO)).inputs.nixpkgs { system = \"x86_64-linux\"; }; in"
}

@test "root is refused despite a key provided via modules" {
  SSH_USER=root run r true
  assert_failure
}

@test "builder logs in with the key provided via modules" {
  run r whoami
  assert_output builder
}

@test "builder is a trusted Nix user" {
  run r 'nix store info --store daemon'
  assert_line --regexp '^Trusted: 1$'
}

@test "systemd is PID 1" {
  run x 'ps -o comm= -p 1'
  assert_output systemd
}

@test "the system is running with no failed units" {
  assert_no_failed_units
  run x 'systemctl is-active multi-user.target'
  assert_success
}

@test "every IPv4 route has quickack" {
  routes="$(x 'ip -4 route show')"
  assert [ -n "$routes" ]
  run grep -v 'quickack 1' <<<"$routes"
  assert_failure
}

@test "DNS resolves via the runtime-provided resolv.conf" {
  run x 'getent hosts cache.nixos.org'
  assert_success
}

@test "without a store volume, stage 2 warns the store is ephemeral" {
  run logs
  assert_output --partial 'THE STORE IS EPHEMERAL'
  run x 'findmnt -n -o FSTYPE /nix || true'
  refute_output overlay
}

@test "the Nix DB is seeded with the image closure and the system profile is set" {
  run x 'nix-store -q --hash "$(readlink -f /run/current-system)"'
  assert_success
  run x '[ "$(cat /nix/var/nix/linux-builder-seeded-system)" = "$(readlink -f /run/booted-system)" ]'
  assert_success
  run x '[ "$(readlink -f /nix/var/nix/profiles/system)" = "$(readlink -f /run/current-system)" ]'
  assert_success
}

@test "sshd's effective config carries the scar tissue" {
  eff="$(x 'sshd -T')"
  for want in "maxstartups 100:30:200" "maxsessions 100" "persourcepenalties no" \
    "acceptenv NIX_*" "permitrootlogin no" \
    "passwordauthentication no" "kbdinteractiveauthentication no"; do
    run grep -ixF "$want" <<<"$eff"
    assert_success
  done
}

@test "nix.settings carry the generic builder settings" {
  run x 'nix config show'
  assert_success
  assert_line "sandbox = true"
  assert_line "min-free = $((40 << 30))"
  assert_line "max-free = $((120 << 30))"
  assert_line --regexp '^trusted-users = (.* )?root( .*)?$'
  assert_line --regexp '^experimental-features = (.* )?flakes( .*)?$'
}

@test "the host builds an aarch64-linux derivation on the builder over ssh-ng" {
  out="$(remote_build "$(probe_expr keyed)")"
  run x "cat $out"
  assert_output ok
}

@test "the rosetta virtiofs share is mounted at /run/rosetta" {
  run x 'mountpoint -q /run/rosetta && [ -x /run/rosetta/rosetta ]'
  assert_success
}

@test "the x86_64 binfmt handler is Rosetta with argv0 preserved (POCF), and apple/container's is gone" {
  run x 'cat /proc/sys/fs/binfmt_misc/rosetta'
  assert_line enabled
  assert_line 'flags: POCF'
  run x '[ ! -e /proc/sys/fs/binfmt_misc/x86_64 ]'
  assert_success
}

@test "nix advertises x86_64-linux and sandboxes the Rosetta share" {
  run x 'nix config show'
  assert_line --regexp '^extra-platforms = (.* )?x86_64-linux( .*)?$'
  assert_line --regexp '^sandbox-paths = .*/run/rosetta([^[:alnum:]_]|$)'
}

@test "an x86_64-linux derivation builds on the builder under Rosetta" {
  expr="$(x86) pkgs.runCommand \"lbi-x86-probe-$(date +%s)\" { } \"uname -m > \$out\""
  out="$(remote_build "$expr")"
  run x "cat $out"
  assert_output x86_64
}

@test "an x86_64 python.withPackages env resolves its own prefix (argv0 preserved)" {
  envExpr="pkgs.python3.withPackages (ps: [ ps.six ])"
  envPath="$(nix-instantiate --eval --raw -E "$(x86) ($envExpr).outPath")"
  expr="$(x86) let env = $envExpr; in pkgs.runCommand \"lbi-argv0-probe-$(date +%s)\" { } ''
  \${env}/bin/python3 -c 'import sys; print(sys.prefix)' > \$out
  \${env}/bin/python3 -c 'import six' >> \$out
''"
  out="$(remote_build "$expr")"
  run x "cat $out"
  assert_output "$envPath"
}
