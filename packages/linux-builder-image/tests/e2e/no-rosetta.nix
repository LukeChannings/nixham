{ scope, image, ... }:
scope {
  setupFile = ''
    export CONTAINER=lbi-norosetta
    REF="$(load_image ${image})"
    export REF
    boot_keyed "$REF"
  '';
  teardownFile = ''
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  '';
  tests = {
    "builder still logs in with the key" = ''
      run r true
      assert_success
    '';
    "only the Rosetta units fail" = ''
      assert_no_failed_units 'systemd-binfmt\.service|run-rosetta\.mount'
    '';
    "no Rosetta binfmt handler is registered" = ''
      run x '[ ! -e /proc/sys/fs/binfmt_misc/rosetta ]'
      assert_success
    '';
    "the host still builds an aarch64-linux derivation on the builder over ssh-ng" = ''
      out="$(remote_build "$(probe_expr norosetta)")"
      run x "cat $out"
      assert_output ok
    '';
  };
}
