# shellcheck shell=bash
# Every scope's setup_file exports LBI_KERNEL, and LBI_KEY: a store path whose
# key use_key copies, as ssh refuses a world-readable one.

SSH=/usr/bin/ssh
# shellcheck disable=SC2034 # for some scopes only
NC=/usr/bin/nc
PERL=/usr/bin/perl

# Who r, remote_build and the herd log in as, and with which key.
SSH_USER=builder
SSH_KEY="$BATS_FILE_TMPDIR/key"

SSHO=(-o IdentitiesOnly=yes -o IdentityAgent=none
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o BatchMode=yes -o ConnectTimeout=20)

# use_key: SSH_KEY, and the /config dir boot_keyed mounts, authorizing it.
use_key() {
  install -m 600 "$LBI_KEY/key" "$SSH_KEY"
  install -m 644 "$LBI_KEY/key.pub" "$SSH_KEY.pub"
  authorize "$BATS_FILE_TMPDIR/keyed"
}

# load_image <archive>: loads it into the runtime, prints its ref, and
# remembers it for unload_images.
load_image() {
  local ref
  ref="$(container image load -i "$1")" || return
  echo "$ref" >>"$BATS_FILE_TMPDIR/images"
  echo "$ref"
}

unload_images() {
  [ -e "$BATS_FILE_TMPDIR/images" ] || return 0
  sort -u "$BATS_FILE_TMPDIR/images" | while read -r ref; do
    container image rm "$ref" >/dev/null 2>&1 || true
  done
}

# The console a test runs under `script -F "$BATS_FILE_TMPDIR/console.log"`.
console() {
  tr -d '\r' 2>/dev/null <"$BATS_FILE_TMPDIR/console.log"
}

# wait_for_console <regex>: until the console log matches, or 90s pass.
wait_for_console() {
  local deadline=$((SECONDS + 90))
  until console | grep -Eq "$1"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "no '$1' on the console, which ends: $(console | tail -5)"
    sleep 0.2
  done
}

# For teardown: ends a test's CONSOLE coprocess which, as any background job,
# ignores ^C, and would keep bats from exiting until its container stops.
stop_console() {
  [ -z "${CONSOLE_PID:-}" ] || kill "$CONSOLE_PID" 2>/dev/null || true
}

# wait_for_exit <pid>: until the child <pid> exits, or fails after 60s.
wait_for_exit() {
  local deadline=$((SECONDS + 60))
  while kill -0 "$1" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
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

# The IP of $CONTAINER, as recorded by boot_container.
current_ip() {
  cat "$BATS_RUN_TMPDIR/$CONTAINER.ip"
}

# Runs a command in $CONTAINER as root, through the runtime: no ssh. In a
# clean environment, as systemd's services: exec passes on `container run -e`.
x() {
  container exec "$CONTAINER" /run/current-system/sw/bin/env -i HOME=/root \
    PATH=/run/wrappers/bin:/run/current-system/sw/bin /run/current-system/sw/bin/bash -c "$*"
}

# Runs a command in $CONTAINER over ssh as $SSH_USER. /usr/bin/ssh:
# only Apple's binaries are granted the macOS Local Network privacy permission.
r() {
  "$SSH" "${SSHO[@]}" -i "$SSH_KEY" "$SSH_USER@$(current_ip)" "$@"
}

# boot_container <ref> [container run flags...]: $CONTAINER, fresh (rm + run),
# once its sshd answers. Names are unique per file, or per test where a test
# needs its own, so that tests can run in any order and in parallel (--jobs).
boot_container() {
  local ref=$1 addr
  shift
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  container run -d --name "$CONTAINER" --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN \
    --kernel "$LBI_KERNEL" "$@" "$ref" >/dev/null
  addr="$(container_ip "$CONTAINER")"
  [ -n "$addr" ] || fail "no IPv4 address for $CONTAINER"
  echo "$addr" >"$BATS_RUN_TMPDIR/$CONTAINER.ip"
  wait_for_port "$addr" 22 || fail "sshd never answered on $addr:22"
}

# boot_mounted <ref> <dir> [container run flags...]: boot_container, with
# whichever of <dir>/config and <dir>/secrets exist bind-mounted read-only at
# /config and /secrets.
boot_mounted() {
  local ref=$1 dir=$2 mounts=() d
  shift 2
  for d in config secrets; do
    [ ! -d "$dir/$d" ] || mounts+=(--mount "type=bind,source=$dir/$d,target=/$d,readonly")
  done
  boot_container "$ref" "${mounts[@]}" "$@"
}

# boot_keyed <ref> [container run flags...]: boot_mounted, with a /config
# that authorizes SSH_KEY for builder.
boot_keyed() {
  boot_mounted "$1" "$BATS_FILE_TMPDIR/keyed" "${@:2}"
}

# authorize <dir> [user] [key]: <dir>/config/ssh/authorized_keys.d/<user>
# (builder) authorizes only <key> (SSH_KEY).
authorize() {
  mkdir -p "$1/config/ssh/authorized_keys.d"
  cat "${3:-$SSH_KEY}.pub" >"$1/config/ssh/authorized_keys.d/${2:-builder}"
}

# The container logs of $CONTAINER.
logs() {
  container logs "$CONTAINER" 2>/dev/null || true
}

# assert_no_failed_units [allowed-unit-regex]
assert_no_failed_units() {
  local state failed
  state="$(x 'systemctl is-system-running --wait' || true)"
  failed="$(x 'systemctl --failed --plain --no-legend' | awk '{print $1}')"
  if [ -n "${1:-}" ]; then failed="$(grep -vE "^($1)\$" <<<"$failed" || true)"; fi
  if [ -n "$failed" ]; then
    x 'systemctl --failed --no-pager' >&2 || true
    fail "failed units: $(xargs <<<"$failed")"
  fi
  [ -n "${1:-}" ] || [ "$state" = running ] || fail "system state: $state"
}

# remote_build <nix expression>: builds on the file's container over ssh-ng,
# as the host's nix-daemon offloads; prints the out path.
remote_build() {
  local out
  out="$(PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]} -i $SSH_KEY" \
    nix build --impure --no-link --print-out-paths --eval-store auto \
    --store "ssh-ng://$SSH_USER@$(current_ip)" --expr "$1")" || return 1
  tail -1 <<<"$out"
}

# An aarch64-linux derivation with a unique name, whose output reads "ok".
probe_expr() {
  echo "derivation { name = \"lbi-$1-$(date +%s)-$RANDOM\"; system = \"aarch64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ok > \$out\" ]; }"
}
