{ scope, image, ... }:
scope {
  setupFile = ''
    export CONTAINER=lbi-bare
    REF="$(load_image ${image})"
    export REF
    boot_container "$REF" --rosetta
  '';
  teardownFile = ''
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  '';
  tests = {
    "the bare base-profile image refuses the login" = ''
      run r true
      assert_failure
    '';
    # Nix's sandbox probe: mount and PID namespaces in a user namespace, with
    # a fresh /proc, which nothing may cover.
    "Nix can sandbox builds" = ''
      run x 'unshare -Urmpf --mount-proc true'
      assert_success
    '';
  };
}
