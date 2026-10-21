load helpers

setup_file() {
  export CONTAINER=lbi-bench
  REF="$(build_and_load bench "$(keyed_expr)")"
  export REF
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

# Seconds from container run until the guest's nix-daemon answers over ssh,
# i.e. ready to take an offloaded build.
boot_to_ready() {
  local t0
  t0="$(now)"
  boot_container "$REF" --rosetta
  until r 'nix-store --store daemon -q --hash /run/current-system' >/dev/null 2>&1; do
    awk -v t="$(elapsed "$t0")" 'BEGIN { exit !(t > 30) }' && fail "nix-daemon never answered"
    sleep 0.01
  done
  elapsed "$t0"
}

@test "startup: container run until the nix-daemon answers over ssh" {
  local file="$BATS_TEST_DIRNAME/benchmarks.jsonl" pr="${PR_NUMBER:-null}" system best t i
  system="$(bench_system)"

  for i in 1 2 3; do
    t="$(boot_to_ready)"
    best="$(awk -v a="$t" -v b="${best:-$t}" 'BEGIN { print (a < b) ? a : b }')"
  done

  git -C "$BATS_TEST_DIRNAME" show main:./benchmarks.jsonl >"$BATS_TEST_TMPDIR/main.jsonl" 2>/dev/null || : >"$BATS_TEST_TMPDIR/main.jsonl"
  base="$(bench_baseline "$BATS_TEST_TMPDIR/main.jsonl" "$system" "$pr")"

  echo "# system:   $system" >&3
  echo "# startup:  ${best}s" >&3
  if [ -z "$base" ]; then
    echo "# baseline: no baseline" >&3
  else
    jq -r --argjson best "$best" '
      "# baseline: PR \(.pr) (\(.rev[:9])) \(.startup)s",
      "# delta:    \($best - .startup | . * 100 | round / 100)s (\(($best - .startup) / .startup * 100 | . * 10 | round / 10)%)"' <<<"$base" >&3
  fi

  if [ "$pr" != null ]; then
    bench_record "$file" "$(jq -cnS \
      --argjson pr "$pr" --argjson startup "$best" --arg system "$system" \
      --arg rev "$(git -C "$BATS_TEST_DIRNAME" rev-parse HEAD)" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg container "$(container --version | sed -E 's/^[^0-9]*([0-9][^ ]*).*/\1/')" \
      --arg macos "$(sw_vers -productVersion)" \
      '{pr: $pr, rev: $rev, timestamp: $timestamp, system: $system, startup: $startup, container: $container, macos: $macos}')"
  fi
}
