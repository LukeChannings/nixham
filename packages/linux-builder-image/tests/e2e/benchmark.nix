# Records into the checkout it runs in, when PR_NUMBER is set.
{ scope, image, ... }:
scope {
  kind = "benchmark";
  helpers = [ ./benchmark.sh ];
  setupFile = ''
    export CONTAINER=lbi-bench
    REF="$(load_image ${image})"
    export REF
  '';
  teardownFile = ''
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  '';
  tests."startup: container run until the nix-daemon answers over ssh" = ''
    local repo file rel pr="''${PR_NUMBER:-null}" system best t
    repo="$(git rev-parse --show-toplevel)"
    rel=packages/linux-builder-image/tests/benchmarks.jsonl
    file="$repo/$rel"
    system="$(bench_system)"

    for _ in 1 2 3; do
      t="$(boot_to_ready)"
      best="$(awk -v a="$t" -v b="''${best:-$t}" 'BEGIN { print (a < b) ? a : b }')"
    done

    git -C "$repo" show "main:$rel" >"$BATS_TEST_TMPDIR/main.jsonl" 2>/dev/null || : >"$BATS_TEST_TMPDIR/main.jsonl"
    base="$(bench_baseline "$BATS_TEST_TMPDIR/main.jsonl" "$system" "$pr")"

    echo "# system:   $system" >&3
    echo "# startup:  ''${best}s" >&3
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
        --arg rev "$(git -C "$repo" rev-parse HEAD)" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg container "$(container --version | sed -E 's/^[^0-9]*([0-9][^ ]*).*/\1/')" \
        --arg macos "$(sw_vers -productVersion)" \
        '{pr: $pr, rev: $rev, timestamp: $timestamp, system: $system, startup: $startup, container: $container, macos: $macos}')"
    fi
  '';
}
