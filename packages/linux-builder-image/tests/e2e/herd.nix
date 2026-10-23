# Its own container: other tests' sessions would count against MaxStartups.
{ scope, image, ... }:
scope {
  setupFile = ''
    export CONTAINER=lbi-herd
    REF="$(load_image ${image})"
    export REF
    boot_keyed "$REF" --rosetta
  '';
  teardownFile = ''
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  '';
  tests."100 simultaneous ssh sessions succeed after 20 banner-less probes" = ''
    local i
    for i in $(seq 20); do "$NC" -z -G 2 "$(current_ip)" 22 >/dev/null 2>&1 || true; done
    for i in $(seq 100); do
      ("$SSH" "''${SSHO[@]}" -i "$SSH_KEY" "$SSH_USER@$(current_ip)" 'sleep 2; echo ok' >"$BATS_TEST_TMPDIR/$i" 2>&1 || true) 3>&- &
    done
    wait
    run grep -lx ok "$BATS_TEST_TMPDIR"/*
    assert_equal "''${#lines[@]}" 100
  '';
}
