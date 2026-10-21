load helpers

# Its own container: other tests' sessions would count against MaxStartups.
setup_file() {
  export CONTAINER=lbi-herd
  REF="$(build_and_load herd "$(keyed_expr)")"
  export REF
  boot_container "$REF" --rosetta
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

@test "100 simultaneous ssh sessions succeed after 20 banner-less probes" {
  local i
  for i in $(seq 20); do "$NC" -z -G 2 "$(current_ip)" 22 >/dev/null 2>&1 || true; done
  for i in $(seq 100); do
    ("$SSH" "${SSHO[@]}" "$SSH_USER@$(current_ip)" 'sleep 2; echo ok' >"$BATS_TEST_TMPDIR/$i" 2>&1 || true) 3>&- &
  done
  wait
  run grep -lx ok "$BATS_TEST_TMPDIR"/*
  assert_equal "${#lines[@]}" 100
}
