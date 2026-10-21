bats_load_library bats-support
bats_load_library bats-assert

SSH=/usr/bin/ssh
NC=/usr/bin/nc
PERL=/usr/bin/perl

SSHO=(-i "$BATS_SUITE_TMPDIR/key" -o IdentitiesOnly=yes -o IdentityAgent=none
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o BatchMode=yes -o ConnectTimeout=20)

# Expressions are evaluated with `pkg` bound to the linux-builder-image package.
with_pkg() {
  echo "let pkg = (builtins.getFlake (toString $LBI_REPO)).packages.\${builtins.currentSystem}.linux-builder-image; in $1"
}

key_module() {
  echo "{ users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile $BATS_SUITE_TMPDIR/key.pub) ]; }"
}

keyed_expr() {
  echo "pkg.override { modules = [ $(key_module) ]; }"
}

# build_and_load <label> <expr>: loads the image into the runtime, prints its ref.
build_and_load() {
  nix-build -o "$BATS_FILE_TMPDIR/$1.tar" -E "$(with_pkg "$2")" >/dev/null
  container image load -i "$BATS_FILE_TMPDIR/$1.tar" >/dev/null
  nix-instantiate --eval --raw -E "$(with_pkg "($2).imageRef")"
}

container_ip() {
  container inspect "$1" | jq -r '.[0].status.networks[0].ipv4Address // empty' | cut -d/ -f1
}

wait_for_port() {
  "$PERL" -MIO::Socket::INET -MTime::HiRes=time,sleep -e '
    my ($ip, $port) = @ARGV;
    my $deadline = time + 90;
    until (IO::Socket::INET->new(PeerAddr => $ip, PeerPort => $port, Proto => "tcp", Timeout => 0.1)) {
      exit 1 if time > $deadline;
      sleep 0.01;
    }' "$1" "$2"
}

now() {
  if [ -n "${EPOCHREALTIME:-}" ]; then echo "$EPOCHREALTIME"; else "$PERL" -MTime::HiRes=time -e 'printf "%.6f\n", time'; fi
}

elapsed() {
  awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'
}

# The IP of the file's container, as recorded by boot_container.
current_ip() {
  cat "$BATS_FILE_TMPDIR/ip"
}

# Runs a command in the file's container as root, through the runtime: no ssh.
x() {
  container exec -e PATH=/run/wrappers/bin:/run/current-system/sw/bin \
    "$(cat "$BATS_FILE_TMPDIR/name")" /run/current-system/sw/bin/bash -c "$*"
}

# Runs a command in the file's container as root. /usr/bin/ssh: only Apple's
# binaries are granted the macOS Local Network privacy permission.
r() {
  "$SSH" "${SSHO[@]}" root@"$(current_ip)" "$@"
}

# boot_container <name> <ref> [container run flags...]: a fresh container
# (rm + run) whose sshd answers; records its name for x and its IP for r.
boot_container() {
  local name=$1 ref=$2 addr
  shift 2
  container rm -f "$name" >/dev/null 2>&1 || true
  container run -d --name "$name" --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN \
    --kernel "$LBI_KERNEL" "$@" "$ref" >/dev/null
  addr="$(container_ip "$name")"
  [ -n "$addr" ] || fail "no IPv4 address for $name"
  echo "$name" >"$BATS_FILE_TMPDIR/name"
  echo "$addr" >"$BATS_FILE_TMPDIR/ip"
  wait_for_port "$addr" 22 || fail "sshd never answered on $addr:22"
}

# assert_no_failed_units [allowed-unit-regex]
assert_no_failed_units() {
  local state failed
  state="$(x 'systemctl is-system-running --wait' || true)"
  failed="$(x 'systemctl --failed --plain --no-legend' | awk '{print $1}')"
  if [ -n "${1:-}" ]; then failed="$(grep -vE "^($1)\$" <<<"$failed" || true)"; fi
  if [ -n "$failed" ]; then
    x 'systemctl --failed --no-pager' >&2 || true
    fail "failed units: $(echo $failed)"
  fi
  [ -n "${1:-}" ] || [ "$state" = running ] || fail "system state: $state"
}

# remote_build <nix expression>: builds on the file's container over ssh-ng,
# as the host's nix-daemon offloads; prints the out path.
remote_build() {
  local out
  out="$(PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]}" \
    nix build --impure --no-link --print-out-paths --eval-store auto \
    --store "ssh-ng://root@$(current_ip)" --expr "$1")" || return 1
  tail -1 <<<"$out"
}

# An aarch64-linux derivation with a unique name, whose output reads "ok".
probe_expr() {
  echo "derivation { name = \"lbi-$1-$(date +%s)-$RANDOM\"; system = \"aarch64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ok > \$out\" ]; }"
}

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
