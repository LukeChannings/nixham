#!/usr/bin/env bash
# Live probe of the persistent store volume (packages/linux-builder-image/
# persistent-store.nix).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
system="${SYSTEM:-aarch64-darwin}"

SSH=/usr/bin/ssh
PERL=/usr/bin/perl
command -v container >/dev/null || { echo >&2 "FAIL: no \`container\` CLI"; exit 1; }
command -v jq >/dev/null || { echo >&2 "FAIL: jq is required"; exit 1; }

# The guest kernel: this tree's apple-container-kernel, whose CONFIG_EROFS_FS
# the image's /etc overlay needs, rather than whatever the runtime defaults
# to. KERNEL=<Image> boots another; KERNEL= (empty) the runtime's default.
KERNEL="${KERNEL-$(nix-build --no-out-link -E "(builtins.getFlake (toString $repo)).packages.$system.apple-container-kernel")/vmlinux-arm64}"
kernelFlags=()
[ -z "$KERNEL" ] || kernelFlags=(--kernel "$KERNEL")

work="$(mktemp -d)"
name=lbi-persist
volume=lbi-persist-store
images=()
imported=()

cleanup() {
  if [ "${KEEP:-}" = 1 ]; then
    echo >&2 "KEEP=1: leaving $name and volume $volume; key at $work/key"
    return
  fi
  container rm -f "$name" >/dev/null 2>&1 || true
  container volume rm "$volume" >/dev/null 2>&1 || true
  for i in "${images[@]}"; do container image rm "$i" >/dev/null 2>&1 || true; done
  for p in "${imported[@]}"; do nix-store --delete "$p" >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT

pass() { echo >&2 "PASS: $*"; }
fail() { echo >&2 "FAIL: $*"; exit 1; }

ssh-keygen -q -t ed25519 -N '' -C lbi-persist -f "$work/key"
SSHO=(-i "$work/key" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes
  -o ConnectTimeout=20)

pkgExpr="(builtins.getFlake (toString $repo)).packages.$system.linux-builder-image"
keyMod="{ users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile $work/key.pub) ]; }"
# Image B differs from A only by an /etc file: a different system, so a
# different store-path closure under the same volume.
exprA="pkg.override { modules = [ ($keyMod) ]; }"
exprB="pkg.override { modules = [ ($keyMod) { environment.etc.lbi-persist-b.text = \"b\"; } ]; }"

build() {
  nix-build -o "$1" -E "let pkg = $pkgExpr; in $2"
}

load() {
  container image load -i "$1" >/dev/null
  nix-instantiate --eval --raw -E "let pkg = $pkgExpr; in ($2).imageRef"
}

ipOf() {
  container inspect "$1" | jq -r '.[0].status.networks[0].ipv4Address // empty' | cut -d/ -f1
}

waitForPort() {
  "$PERL" -MIO::Socket::INET -MTime::HiRes=time,sleep -e '
    my ($ip, $port) = @ARGV;
    my $deadline = time + 90;
    until (IO::Socket::INET->new(PeerAddr => $ip, PeerPort => $port, Proto => "tcp", Timeout => 0.1)) {
      exit 1 if time > $deadline;
      sleep 0.01;
    }' "$1" "$2"
}

# Boot $1 against the store volume, the way the module does it: a fresh
# container (rm + run) every time, the volume is the only state carried over.
boot() {
  container rm -f "$name" >/dev/null 2>&1 || true
  container run -d --name "$name" --rosetta --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN "${kernelFlags[@]}" \
    -v "$volume:/persist" "$1" >/dev/null
  ip="$(ipOf "$name")"
  [ -n "$ip" ] || fail "no IPv4 address for $name"
  waitForPort "$ip" 22 || fail "sshd never answered on $ip:22"
  r true || fail "root key login refused"
  local state failed
  state="$(r 'systemctl is-system-running --wait' || true)"
  failed="$(r 'systemctl --failed --plain --no-legend' | awk '{print $1}')"
  [ -z "$failed" ] || { r 'systemctl --failed --no-pager' >&2 || true; fail "failed units: $(echo $failed)"; }
  [ "$state" = running ] || fail "system state: $state"
}

stop() {
  container stop "$name" >/dev/null
}

uncleanWarning="previous shutdown was not clean"
assertCleanPreviousShutdown() {
  if logs | grep -q "$uncleanWarning"; then fail "the previous shutdown did not reach the sync hook"; fi
}

r() { "$SSH" "${SSHO[@]}" root@"$ip" "$@"; }
logs() { container logs "$name" 2>/dev/null || true; }

# Builds on the builder over ssh-ng, as the host's nix-daemon offloads.
remoteBuild() {
  PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]}" \
    nix build --no-link --print-out-paths --impure --eval-store auto --store "ssh-ng://root@$ip" \
    --expr "import $here/probe-drv.nix { tag = \"$1-$(date +%s)-$RANDOM\"; }" \
    2>/dev/null | tail -1
}

echo >&2 "=== building images (offloaded to the aarch64-linux builder) ==="
build "$work/a.tar" "$exprA"
build "$work/b.tar" "$exprB"
refA="$(load "$work/a.tar" "$exprA")"; images+=("$refA")
refB="$(load "$work/b.tar" "$exprB")"; images+=("$refB")
[ "$refA" != "$refB" ] || fail "images A and B have the same ref"

container rm -f "$name" >/dev/null 2>&1 || true
container volume rm "$volume" >/dev/null 2>&1 || true
container volume create "$volume" >/dev/null

echo >&2 "=== image A on a fresh volume ==="
boot "$refA"
sysA="$(r 'readlink -f /run/booted-system')"
[ "$(r 'findmnt -n -o FSTYPE /nix')" = overlay ] || fail "/nix is not the overlay"
r 'findmnt -n -o OPTIONS /nix | grep -q upperdir=/persist/upper' || fail "overlay upper is not on the volume"
r 'findmnt -n -o OPTIONS --direction backward --first-only /nix/store | tr , "\n" | grep -qx ro' \
  || fail "/nix/store is not read-only on top of the overlay"
pass "/nix is an overlay with its upper on the volume; /nix/store stays read-only"
if logs | grep -q 'STORE IS EPHEMERAL'; then fail "ephemeral warning with the volume attached"; fi
logs | grep -q 'seeding the Nix DB' || fail "first boot on a fresh volume did not seed the DB"
r "[ \"\$(cat /nix/var/nix/linux-builder-seeded-system)\" = $sysA ]" || fail "seeded stamp not written"
r '[ -s /persist/upper/var/nix/db/db.sqlite ]' || fail "Nix DB is not on the volume"
pass "DB seeded for $sysA and kept on the volume"
hostKey="$(r 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub')"

echo >&2 "=== outputs survive stop + restart ==="
out1="$(remoteBuild persist)"
[ -n "$out1" ] || fail "remote build failed"
r "[ -e /persist/upper/store/${out1#/nix/store/} ]" || fail "$out1 did not land in the volume"
stop
boot "$refA"
assertCleanPreviousShutdown
pass "container stop ran systemd's shutdown path through the volume sync hook"
r "nix-store --check-validity $out1 && nix-store --verify-path $out1" || fail "$out1 lost across restart"
pass "$out1 survived container stop + rm + run"
[ "$(r 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub')" = "$hostKey" ] || fail "host key changed"
pass "ssh host key persisted under /persist/ssh"
if logs | grep -q 'seeding the Nix DB'; then fail "same-image restart re-seeded the DB"; fi
pass "same-image restart skipped the DB seed"

echo >&2 "=== dirty-volume regression: build, stop while idle, restart, import on the host ==="
out2="$(remoteBuild dirty)"
[ -n "$out2" ] || fail "remote build failed"
stop
boot "$refA"
assertCleanPreviousShutdown
importLog="$work/import.log"
if ! PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]}" \
  nix copy --no-check-sigs --from "ssh-ng://root@$ip" "$out2" >"$importLog" 2>&1; then
  cat "$importLog" >&2
  fail "importing $out2 on the host failed"
fi
imported+=("$out2")
if grep -q 'hash mismatch' "$importLog"; then fail "hash mismatch importing $out2"; fi
r "nix-store --verify-path $out2" || fail "$out2 is corrupt on the builder"
pass "$out2 imported on the host without a hash mismatch"

echo >&2 "=== a teardown that bypasses systemd is detected ==="
container kill "$name" >/dev/null
boot "$refA"
logs | grep -q "$uncleanWarning" || fail "container kill went unnoticed by the next boot"
pass "the next boot flags a teardown that never reached the sync hook"

echo >&2 "=== image change: B under A's volume ==="
stop
boot "$refB"
assertCleanPreviousShutdown
sysB="$(r 'readlink -f /run/booted-system')"
[ "$sysA" != "$sysB" ] || fail "image B booted A's system"
logs | grep -q 'reconciling the persisted Nix DB' || fail "image change did not reconcile the DB"
r "[ \"\$(cat /nix/var/nix/linux-builder-seeded-system)\" = $sysB ]" || fail "seeded stamp not updated"
r "[ ! -e $sysA ]" || fail "A's system is still in B's store"
if r "nix-store --check-validity $sysA" 2>/dev/null; then fail "phantom: A's system is still valid in the DB"; fi
r 'nix-store --verify' || fail "nix-store --verify still finds errors after the reconcile"
r "nix-store --check-validity $out1 $out2" || fail "volume outputs lost across the image change"
pass "A's phantom entries were dropped; volume outputs kept"

echo >&2 "=== GC never deletes the baked closure ==="
garbage="$(remoteBuild garbage)"
[ -n "$garbage" ] || fail "remote build failed"
r 'nix-collect-garbage -d' >/dev/null
r "[ ! -e $garbage ]" || fail "GC did not collect the unrooted $garbage"
r 'nix-store -qR /run/booted-system | while read -r p; do [ -e "$p" ] || { echo "missing $p"; exit 1; }; done' \
  || fail "GC deleted part of the booted system"
r 'nix-store --verify --check-contents' || fail "store contents do not match the DB after GC"
stop
boot "$refB"
pass "GC kept the baked closure; the builder reboots cleanly after it"

echo >&2 "=== all checks passed ==="
