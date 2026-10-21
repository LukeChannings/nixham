#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
system="${SYSTEM:-aarch64-darwin}"
herd="${HERD:-100}"

# Regression budgets, in seconds. Targets measured on an M-series host under
# apple/container 1.1.0, with headroom for run-to-run noise.
#
# container run → the guest's nix-daemon answering over ssh, i.e. ready to
# take an offloaded build (measured 1.7–1.9). The best of up to three fresh
# boots counts: noise (the builder still busy from the image builds, say) only
# ever adds time, and once pushed a single boot past 2.8.
MAX_STARTUP=2.5
# Realising an image whose configuration differs by one /etc file from a
# cached one: the ~17 derivations downstream of the toplevel (each a remote
# build through the aarch64-linux builder), the re-pack, and copying the
# archive back to the host (measured 9–33; the spread is remote-build round
# trips). Evaluation, another ~27 s, is not included.
MAX_PARTIAL_REBUILD=45

SSH=/usr/bin/ssh
NC=/usr/bin/nc
PERL=/usr/bin/perl
command -v container >/dev/null || { echo >&2 "FAIL: no \`container\` CLI"; exit 1; }
command -v jq >/dev/null || { echo >&2 "FAIL: jq is required"; exit 1; }

# The guest kernel: this tree's apple-container-kernel, whose CONFIG_EROFS_FS
# the image's /etc overlay needs, rather than whatever the runtime defaults
# to. KERNEL=<Image> boots another; KERNEL= (empty) the runtime's default.
KERNEL="${KERNEL-$(nix-build --no-out-link -E "(builtins.getFlake (toString $repo)).packages.$system.apple-container-kernel")/vmlinux-arm64}"
kernelFlags=()
[ -z "$KERNEL" ] || kernelFlags=(--kernel "$KERNEL")
capFlags=(--cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN "${kernelFlags[@]}")
runFlags=(--rosetta "${capFlags[@]}")

work="$(mktemp -d)"
keyed=lbi-probe-keyed
bare=lbi-probe-bare
norosetta=lbi-probe-norosetta
broken=lbi-probe-broken
images=()

cleanup() {
  if [ "${KEEP:-}" = 1 ]; then
    echo >&2 "KEEP=1: leaving $keyed running; key at $work/key"
    container rm -f "$bare" "$norosetta" "$broken" >/dev/null 2>&1 || true
    return
  fi
  container rm -f "$keyed" "$bare" "$norosetta" "$broken" >/dev/null 2>&1 || true
  for i in "${images[@]}"; do container image rm "$i" >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT

pass() { echo >&2 "PASS: $*"; }
fail() { echo >&2 "FAIL: $*"; exit 1; }

ssh-keygen -q -t ed25519 -N '' -C lbi-probe -f "$work/key"
SSHO=(-i "$work/key" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes
  -o ConnectTimeout=20)

pkgExpr="(builtins.getFlake (toString $repo)).packages.$system.linux-builder-image"

build() {
  nix-build -o "$1" -E "let pkg = $pkgExpr; in $2"
}

load() {
  container image load -i "$1" >/dev/null
  ref="$(nix-instantiate --eval --raw -E "let pkg = $pkgExpr; in ($2).imageRef")"
  images+=("$ref")
  container image inspect "$ref" >/dev/null || fail "the archive's embedded ref is not $ref"
}

ipOf() {
  container inspect "$1" | jq -r '.[0].status.networks[0].ipv4Address // empty' | cut -d/ -f1
}

now() {
  if [ -n "${EPOCHREALTIME:-}" ]; then echo "$EPOCHREALTIME"; else "$PERL" -MTime::HiRes=time -e 'printf "%.6f\n", time'; fi
}

since() {
  awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2fs", b - a }'
}

elapsed() {
  awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'
}

overBudget() {
  awk -v t="$1" -v m="$2" 'BEGIN { exit !(t > m) }'
}

# withinBudget <what> <seconds> <max>
withinBudget() {
  ! overBudget "$2" "$3" || fail "$1 took ${2}s, over its ${3}s budget"
  pass "$1 took ${2}s (budget ${3}s)"
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

herdOk() {
  local ip=$1 d i
  d="$(mktemp -d "$work/herd.XXXX")"
  for i in $(seq 20); do "$NC" -z -G 2 "$ip" 22 >/dev/null 2>&1 || true; done
  for i in $(seq "$herd"); do
    ("$SSH" "${SSHO[@]}" root@"$ip" 'sleep 2; echo ok' >"$d/$i" 2>&1 || true) &
  done
  wait
  { grep -lx ok "$d"/* 2>/dev/null || true; } | wc -l | tr -d ' '
}

keyModule="{ users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile $work/key.pub) ]; }"
keyExpr="pkg.override { modules = [ $keyModule ]; }"
# The shim's registration fails (F opens a missing interpreter), and the
# FailureAction is defused so the guest's binfmt state can be inspected.
brokenExpr="pkg.override { modules = [ $keyModule ({ lib, ... }: {
  boot.binfmt.registrations.rosetta-argv0.interpreter = lib.mkForce \"/nonexistent/rosetta-argv0-shim\";
  systemd.services.rosetta.unitConfig.FailureAction = lib.mkForce \"none\";
}) ]; }"

x86="let pkgs = import (builtins.getFlake (toString $repo)).inputs.nixpkgs { system = \"x86_64-linux\"; }; in"

remoteBuild() {
  PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]}" \
    nix build --impure --no-link --print-out-paths --eval-store auto --store "ssh-ng://root@$ip" --expr "$1" \
    2>"$work/remote-build.log" | tail -1
}

waitStopped() {
  local i
  for i in $(seq "$2"); do
    [ "$(container inspect "$1" | jq -r '.[0].status.state')" = stopped ] && return 0
    sleep 1
  done
  return 1
}

echo >&2 "=== building images (offloaded to the aarch64-linux builder) ==="
build "$work/keyed.tar" "$keyExpr"
build "$work/bare.tar" "pkg"
build "$work/broken.tar" "$brokenExpr"

echo >&2 "=== partial rebuild ==="
# A configuration no earlier run has built, so its system is a cache miss.
ts="$(date +%s)"
drv="$(nix-instantiate -E "let pkg = $pkgExpr; in pkg.override { modules = [
  { environment.etc.\"lbi-probe-$ts\".text = \"$ts\"; } ]; }")"
t0="$(now)"
nix-build --no-out-link "$drv" >/dev/null
withinBudget "a partial rebuild (one /etc file changed)" "$(elapsed "$t0")" "$MAX_PARTIAL_REBUILD"

echo >&2 "=== keyed image ==="
load "$work/keyed.tar" "$keyExpr"
keyedRef="$ref"
pass "container image load accepted $ref"
r() { "$SSH" "${SSHO[@]}" root@"$ip" "$@"; }

# A fresh keyed container; sets ip, and tStartup to the seconds from
# container run until its nix-daemon answers over ssh.
bootKeyed() {
  local t0 tPort tSsh
  container rm -f "$keyed" >/dev/null 2>&1 || true
  t0="$(now)"
  container run -d --name "$keyed" "${runFlags[@]}" "$keyedRef" >/dev/null
  ip="$(ipOf "$keyed")"
  [ -n "$ip" ] || fail "no IPv4 address for $keyed"
  waitForPort "$ip" 22 || fail "sshd never answered on $ip:22"
  tPort="$(elapsed "$t0")"
  r true || fail "root key login refused"
  tSsh="$(elapsed "$t0")"
  until r 'nix-store --store daemon -q --hash /run/current-system' >/dev/null 2>&1; do
    ! overBudget "$(elapsed "$t0")" 30 || fail "nix-daemon never answered"
    sleep 0.01
  done
  tStartup="$(elapsed "$t0")"
  echo >&2 "TIME: nix-daemon answering ${tStartup}s from container run (sshd port ${tPort}s, login ${tSsh}s)"
}

best=
for _ in 1 2 3; do
  bootKeyed
  best="$(awk -v a="$tStartup" -v b="${best:-$tStartup}" 'BEGIN { print (a < b) ? a : b }')"
  overBudget "$best" "$MAX_STARTUP" || break
done
pass "root logs in with the key provided via modules"
withinBudget "startup (container run → nix-daemon answering over ssh)" "$best" "$MAX_STARTUP"

[ "$(r 'ps -o comm= -p 1')" = systemd ] || fail "PID 1 is not systemd"
pass "systemd is PID 1"

state="$(r 'systemctl is-system-running --wait' || true)"
failed="$(r 'systemctl --failed --plain --no-legend' | awk '{print $1}')"
if [ -n "$failed" ]; then
  r 'systemctl --failed --no-pager' >&2 || true
  fail "failed units: $(echo $failed)"
fi
[ "$state" = running ] || fail "system state: $state"
r 'systemctl is-active multi-user.target' >/dev/null || fail "multi-user.target not active"
pass "multi-user.target reached; system state '$state', no failed units"

routes="$(r 'ip -4 route show')"
if [ -z "$routes" ] || grep -v 'quickack 1' <<<"$routes" >/dev/null; then
  fail "routes lack quickack: $routes"
fi
pass "every IPv4 route has quickack"

r 'getent hosts cache.nixos.org' >/dev/null || fail "DNS lookup failed inside the builder"
pass "DNS resolves via the runtime-provided resolv.conf"

r 'nix-store -q --hash "$(readlink -f /run/current-system)"' >/dev/null \
  || fail "the system closure is not registered in the Nix DB"
container logs "$keyed" 2>/dev/null | grep -q 'THE STORE IS EPHEMERAL' \
  || fail "no ephemeral-store warning without a volume at /persist"
[ "$(r 'findmnt -n -o FSTYPE /nix || true')" != overlay ] || fail "/nix is an overlay without a volume"
pass "without a store volume, stage 2 warns the store is ephemeral"

r '[ "$(cat /nix/var/nix/linux-builder-seeded-system)" = "$(readlink -f /run/booted-system)" ]' \
  || fail "stage 2 did not record the DB as seeded for the booted system"
r '[ "$(readlink -f /nix/var/nix/profiles/system)" = "$(readlink -f /run/current-system)" ]' \
  || fail "system profile not set"
pass "Nix DB seeded with the image closure; system profile set"

eff="$(r 'sshd -T')"
for want in "maxstartups 100:30:200" "maxsessions 100" "persourcepenalties no" \
  "acceptenv NIX_*" "permitrootlogin prohibit-password" \
  "passwordauthentication no" "kbdinteractiveauthentication no"; do
  grep -qixF "$want" <<<"$eff" || fail "sshd -T lacks '$want'"
done
pass "sshd effective config carries the scar tissue"

conf="$(r 'nix config show')"
for want in "sandbox = true" "min-free = $((40 << 30))" "max-free = $((120 << 30))"; do
  grep -qxF "$want" <<<"$conf" || fail "nix config lacks '$want'"
done
grep -qE '^trusted-users = .*\broot\b' <<<"$conf" || fail "root is not a trusted user"
grep -qE '^experimental-features = .*\bflakes\b' <<<"$conf" || fail "flakes not enabled"
pass "nix.settings carry the generic builder settings"

probeDrv="derivation { name = \"lbi-probe-$(date +%s)\"; system = \"aarch64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ok > \$out\" ]; }"
out="$(PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]}" \
  nix build --no-link --print-out-paths --eval-store auto --store "ssh-ng://root@$ip" --expr "$probeDrv" 2>/dev/null | tail -1)"
[ -n "$out" ] && [ "$(r "cat $out")" = ok ] || fail "remote build over ssh-ng failed"
pass "host builds a derivation on the builder over ssh-ng"

echo >&2 "=== Rosetta ==="
r 'mountpoint -q /run/rosetta && [ -x /run/rosetta/rosetta ]' || fail "/run/rosetta is not the Rosetta share"
[ "$(r 'systemctl is-active rosetta.service')" = active ] || fail "rosetta.service is not active"
pass "the rosetta virtiofs share is mounted at /run/rosetta"

reg="$(r 'cat /proc/sys/fs/binfmt_misc/rosetta-argv0' || true)"
grep -qx enabled <<<"$reg" && grep -qx 'flags: PF' <<<"$reg" \
  || fail "argv0-preserving handler not registered with PF: $reg"
r '[ ! -e /proc/sys/fs/binfmt_misc/x86_64 ]' || fail "apple/container's argv0-discarding handler is still registered"
pass "x86_64 binfmt handler is the argv0 shim (PF); apple/container's is gone"

grep -qE '^extra-platforms = .*\bx86_64-linux\b' <<<"$conf" || fail "x86_64-linux not in extra-platforms"
grep -qE '^sandbox-paths = .*/run/rosetta\b' <<<"$conf" || fail "/run/rosetta not in sandbox-paths"
grep -qE '^sandbox-paths = .*-qemu-x86_64-binfmt-P\b' <<<"$conf" || fail "qemu shim not in sandbox-paths"
pass "nix advertises x86_64-linux and sandboxes the Rosetta share and qemu shim"

ts="$(date +%s)"
out="$(remoteBuild "$x86 pkgs.runCommand \"lbi-x86-probe-$ts\" { } \"uname -m > \$out\"")" \
  || { cat "$work/remote-build.log" >&2; fail "x86_64-linux build failed"; }
[ "$(r "cat $out")" = x86_64 ] || fail "x86_64-linux build ran as $(r "cat $out")"
pass "an x86_64-linux derivation builds on the builder under Rosetta"

envExpr="pkgs.python3.withPackages (ps: [ ps.six ])"
envPath="$(nix-instantiate --eval --raw -E "$x86 ($envExpr).outPath")"
out="$(remoteBuild "$x86 let env = $envExpr; in pkgs.runCommand \"lbi-argv0-probe-$ts\" { } ''
  \${env}/bin/python3 -c 'import sys; print(sys.prefix)' > \$out
  \${env}/bin/python3 -c 'import six' >> \$out
''")" || { cat "$work/remote-build.log" >&2; fail "argv0 probe build failed (did the env collapse?)"; }
prefix="$(r "cat $out")"
[ "$prefix" = "$envPath" ] || fail "x86_64 python.withPackages resolved sys.prefix to $prefix, not $envPath"
pass "x86_64 python.withPackages env resolves its own prefix (argv0 preserved)"

echo >&2 "=== parallel-connection herd ($herd sessions after 20 banner-less probes) ==="
n="$(herdOk "$ip")"
[ "$n" = "$herd" ] || fail "only $n/$herd herd sessions succeeded"
pass "$n/$herd herd sessions succeeded"

echo >&2 "=== bare base-profile image ==="
load "$work/bare.tar" pkg
pass "container image load accepted $ref"
container rm -f "$bare" >/dev/null 2>&1 || true
t0="$(now)"
container run -d --name "$bare" "${runFlags[@]}" "$ref" >/dev/null
bip="$(ipOf "$bare")"
waitForPort "$bip" 22 || fail "bare image's sshd never answered"
echo >&2 "TIME: time-to-sshd-port $(since "$t0") from container run"
if "$SSH" "${SSHO[@]}" root@"$bip" true 2>/dev/null; then
  fail "bare base-profile image accepted a login"
fi
pass "bare base-profile image refuses the login"

echo >&2 "=== keyed image without --rosetta ==="
container rm -f "$norosetta" >/dev/null 2>&1 || true
container run -d --name "$norosetta" "${capFlags[@]}" "$keyedRef" >/dev/null
waitStopped "$norosetta" 60 || fail "the builder kept running without --rosetta"
boot="$(container logs --boot "$norosetta")"
grep -qF "FATAL: no 'rosetta' virtiofs share" <<<"$boot" || fail "no FATAL in the boot log"
grep -qF "Dependency failed for SSH Daemon" <<<"$boot" || fail "sshd was not held back"
grep -qE "id: $norosetta, status: [1-9][0-9]* managed process exit" <<<"$boot" || fail "container exited zero"
pass "without --rosetta the builder stops non-zero, FATAL in the boot log, sshd never started"

echo >&2 "=== shim registration fails ==="
bb="$(nix-build --no-out-link -E "$x86 pkgs.busybox-sandbox-shell")/bin/busybox"
load "$work/broken.tar" "$brokenExpr"
container rm -f "$broken" >/dev/null 2>&1 || true
container run -d --name "$broken" "${runFlags[@]}" "$ref" >/dev/null
x() { container exec "$broken" /run/current-system/sw/bin/sh -c "PATH=/run/current-system/sw/bin; $1"; }
for i in $(seq 60); do
  [ "$(x 'systemctl is-failed rosetta.service' 2>/dev/null || true)" = failed ] && break
  sleep 1
done
[ "$(x 'systemctl is-failed rosetta.service' || true)" = failed ] || fail "rosetta.service did not fail on a broken registration"
x '[ ! -e /proc/sys/fs/binfmt_misc/rosetta-argv0 ]' || fail "the broken handler registered anyway"
[ "$(x 'head -n1 /proc/sys/fs/binfmt_misc/x86_64')" = enabled ] \
  || fail "apple/container's handler was dropped before ours registered"
[ "$(container exec -i "$broken" /run/current-system/sw/bin/sh -c \
  'PATH=/run/current-system/sw/bin; cat > /tmp/busybox && chmod +x /tmp/busybox && /tmp/busybox sh -c "echo x86-ok"' <"$bb")" = x86-ok ] \
  || fail "the guest cannot execute x86_64 after a failed registration"
x '! systemctl is-active -q sshd.service' || fail "sshd started despite rosetta.service failing"
pass "a failed shim registration leaves apple/container's handler, so the guest still runs x86_64; sshd held back"

echo >&2 "=== all checks passed ==="
