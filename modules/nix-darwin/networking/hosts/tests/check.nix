{
  lib,
  makeTest,
  darwin,
  dash,
}:
let
  inherit (darwin) esc text;
  hosts = {
    "172.20.32.251" = [
      "nix.example.org"
      "s3.example.org"
    ];
    "10.0.0.9" = [ ];
  };
  s = darwin.eval [ { networking.hosts = hosts; } ];
  script = s: text "hosts" s.config.system.build.hosts.text;
  postActivation = text "postActivation" s.config.system.activationScripts.postActivation.text;

  scenarios = {
    "the block is appended after the file's own lines, and the cache flushed" = ''
      apply
      assert_equal "$(cat "$HOSTS")" "$(printf '%s\n' "$ORIGINAL" "$BLOCK")"
      assert_equal "$(cat "$FAKE_LOG")" "$(printf '%s\n' 'dscacheutil -flushcache' 'killall -HUP mDNSResponder')"
    '';
    "a second run writes and flushes nothing" = ''
      apply
      : >"$FAKE_LOG"
      touch -t 200001010000 "$HOSTS"
      apply
      assert_equal "$(cat "$FAKE_LOG")" ""
      [ -z "$(find "$HOSTS" -newermt 2000-01-02)" ]
    '';
    "a stale block is replaced, and the lines around it kept" = ''
      printf '%s\n' "$BEGIN" '10.0.0.1 old.example.org' "$END" '192.168.1.1 router' >>"$HOSTS"
      apply
      assert_equal "$(cat "$HOSTS")" "$(printf '%s\n' "$ORIGINAL" '192.168.1.1 router' "$BLOCK")"
    '';
    "without entries, the block is removed" = ''
      printf '%s\n' "$BLOCK" >>"$HOSTS"
      $sh "$BATS_TEST_TMPDIR/empty"
      assert_equal "$(cat "$HOSTS")" "$ORIGINAL"
    '';
    "the file stays world-readable" = ''
      apply
      assert_equal "$(stat -c %a "$HOSTS")" 644
    '';
  };
  shells = {
    bash = "bash --posix";
    dash = "dash";
  };
in
makeTest {
  name = "networking-hosts";
  inputs = [ dash ];
  helpers = [
    ''
      apply() {
        $sh "$BATS_TEST_TMPDIR/hosts"
      }
    ''
  ];
  setup = ''
    stub ${./stubs}
    export HOSTS="$BATS_TEST_TMPDIR/etc-hosts" FAKE_LOG="$BATS_TEST_TMPDIR/log"
    for f in hosts:${script s} empty:${script (darwin.eval [ ])}; do
      sed -e "s|^PATH=.*|PATH=$PATH|" -e "s|^hosts_file=.*|hosts_file=$HOSTS|" "''${f#*:}" >"$BATS_TEST_TMPDIR/''${f%%:*}"
    done
    ORIGINAL=$(printf '%s\n' '127.0.0.1 localhost' '255.255.255.255 broadcasthost')
    BEGIN='# BEGIN nix-darwin networking.hosts'
    END='# END nix-darwin networking.hosts'
    BLOCK=$(printf '%s\n' "$BEGIN" '172.20.32.251 nix.example.org s3.example.org' "$END")
    printf '%s\n' "$ORIGINAL" >"$HOSTS"
    : >"$FAKE_LOG"
  '';
  tests = {
    "entries render one line per address, skipping addresses without names" = ''
      run cat ${script s}
      assert_line "entries='172.20.32.251 nix.example.org s3.example.org'"
    '';
    "activation applies the block" = ''
      run cat ${postActivation}
      assert_output --regexp '/bin/sh /nix/store/[^ ]*-hosts'
    '';
  }
  // lib.concatMapAttrs (
    shell: sh:
    lib.mapAttrs' (name: body: lib.nameValuePair "${name} (${shell})" "sh=${esc sh}\n${body}") scenarios
  ) shells;
}
