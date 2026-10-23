# shellcheck shell=bash

# The host machine, e.g. "Apple M1 Max (MacBookPro18,2)": the only key benchmark
# results are compared on.
bench_system() {
  echo "$(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.model))"
}

# bench_baseline <jsonl> <system> <pr|null>: the last line of the highest PR
# other than <pr> measured on <system>; prints nothing when there is none.
bench_baseline() {
  jq -sc --arg system "$2" --argjson pr "$3" '
    map(select(.system == $system and .pr != $pr))
    | group_by(.pr) | map(last) | max_by(.pr) // empty' "$1"
}

# bench_record <jsonl> <line>: replaces the line's (pr, system) entry with it,
# keeping only the 10 highest PRs for each system.
bench_record() {
  local tmp="$1.tmp"
  jq -sc --argjson new "$2" '
    (map(select((.system == $new.system and .pr == $new.pr) | not)) + [$new]) as $lines
    | ($lines | group_by(.system)
        | map({key: .[0].system, value: (map(.pr) | unique | reverse | .[:10])})
        | from_entries) as $keep
    | $lines[] | . as $l | select($l.pr | IN($keep[$l.system][]))' "$1" >"$tmp"
  mv "$tmp" "$1"
}

# Seconds from container run until the guest's nix-daemon answers over ssh,
# i.e. ready to take an offloaded build.
boot_to_ready() {
  local t0
  t0="$(now)"
  boot_keyed "$REF" --rosetta
  until r 'nix-store --store daemon -q --hash /run/current-system' >/dev/null 2>&1; do
    awk -v t="$(elapsed "$t0")" 'BEGIN { exit !(t > 30) }' && fail "nix-daemon never answered"
    sleep 0.01
  done
  elapsed "$t0"
}
