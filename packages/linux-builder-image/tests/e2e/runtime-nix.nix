{ scope, image, ... }:
scope {
  helpers = [ ./runtime-nix.sh ];
  setupFile = ''
    REF="$(load_image ${image})"
    export REF CONTAINER=lbi-runtime-nix
    write_config "$BATS_FILE_TMPDIR"
    boot_configured "$BATS_FILE_TMPDIR"
  '';
  teardownFile = ''
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  '';
  # Tests that restart a container get their own.
  teardown = ''
    container rm -f "lbi-runtime-nix-$BATS_TEST_NUMBER" >/dev/null 2>&1 || true
  '';
  tests = {
    "/config's nix.conf, and the /secrets file it includes, are in effect" = ''
      run nix_config
      assert_line --regexp '^substituters = .*https://lbi-config\.invalid'
      assert_line 'narinfo-cache-negative-ttl = 4242'
    '';
    "the daemon applies /config's nix.conf to builds as builder over ssh-ng" = ''
      out="$(remote_build "derivation { name = \"lbi-sandbox-probe-$(date +%s)-$RANDOM\"; system = \"aarch64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"read -r l < /lbi-probe; echo \$l > \$out\" ]; }")"
      run x "cat $out"
      assert_output "$(x 'head -1 /etc/resolv.conf')"
    '';
    "NIX_CONFIG's lines and each NIX_CONFIG_*, includes and all, are in effect" = ''
      run nix_config
      assert_line 'connect-timeout = 17'
      assert_line 'http-connections = 37'
      assert_line 'download-attempts = 7'
    '';
    "the environment wins over /config's nix.conf" = ''
      run nix_config
      assert_line 'narinfo-cache-positive-ttl = 2222'
    '';
    "the logs name the environment variables applied, never their values" = ''
      run logs
      assert_output --regexp 'linux-builder: .*NIX_CONFIG NIX_CONFIG_A NIX_CONFIG_B NIX_CONFIG_C'
      refute_output --partial 'connect-timeout'
      refute_output --partial 'http-connections'
      refute_output --partial '/secrets/env.conf'
    '';
    "missing include targets are warned about, wherever they are in the chain" = ''
      run logs
      assert_output --regexp 'linux-builder: WARN .*/secrets/absent\.conf'
      assert_output --regexp 'linux-builder: WARN .*/secrets/absent-nested\.conf'
    '';
    "builder's own nix works, without reading the root-only config" = ''
      run r 'nix config show'
      assert_success
      refute_output --partial lbi-config.invalid
      refute_line 'narinfo-cache-negative-ttl = 4242'
      refute_line 'connect-timeout = 17'
    '';
    "the system is running with no failed units" = ''
      assert_no_failed_units
    '';
    "editing /config on the host while running changes nothing" = ''
      own_container
      write_config "$BATS_TEST_TMPDIR"
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      write_config "$BATS_TEST_TMPDIR" https://lbi-edited.invalid
      run nix_config
      assert_line --regexp '^substituters = .*https://lbi-config\.invalid'
      refute_output --partial lbi-edited
    '';
    "a new container picks up the edited /config" = ''
      own_container
      write_config "$BATS_TEST_TMPDIR"
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      write_config "$BATS_TEST_TMPDIR" https://lbi-edited.invalid
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      run nix_config
      assert_line --regexp '^substituters = .*https://lbi-edited\.invalid'
      refute_output --partial lbi-config.invalid
    '';
    "a new container without the mounts or the environment keeps none of their settings" = ''
      own_container
      write_config "$BATS_TEST_TMPDIR"
      boot_configured "$BATS_TEST_TMPDIR"
      boot_container "$REF" --rosetta
      run nix_config
      refute_output --partial lbi-config.invalid
      refute_output --partial lbi-probe
      refute_line 'narinfo-cache-negative-ttl = 4242'
      refute_line 'narinfo-cache-positive-ttl = 1111'
      refute_line 'connect-timeout = 17'
      refute_line 'http-connections = 37'
      refute_line 'download-attempts = 7'
    '';
  };
}
