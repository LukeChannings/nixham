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
  tests."the bare base-profile image refuses the login" = ''
    run r true
    assert_failure
  '';
}
