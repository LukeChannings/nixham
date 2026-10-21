#!/usr/bin/env bash
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
capFlags=(--cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN "${kernelFlags[@]}")
runFlags=(--rosetta "${capFlags[@]}")

work="$(mktemp -d)"
keyed=lbi-probe-keyed
norosetta=lbi-probe-norosetta
images=()

cleanup() {
  if [ "${KEEP:-}" = 1 ]; then
    echo >&2 "KEEP=1: leaving $keyed running; key at $work/key"
    container rm -f "$norosetta" >/dev/null 2>&1 || true
    return
  fi
  container rm -f "$keyed" "$norosetta" >/dev/null 2>&1 || true
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

waitForPort() {
  "$PERL" -MIO::Socket::INET -MTime::HiRes=time,sleep -e '
    my ($ip, $port) = @ARGV;
    my $deadline = time + 90;
    until (IO::Socket::INET->new(PeerAddr => $ip, PeerPort => $port, Proto => "tcp", Timeout => 0.1)) {
      exit 1 if time > $deadline;
      sleep 0.01;
    }' "$1" "$2"
}

keyModule="{ users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile $work/key.pub) ]; }"
keyExpr="pkg.override { modules = [ $keyModule ]; }"

echo >&2 "=== building images (offloaded to the aarch64-linux builder) ==="
build "$work/keyed.tar" "$keyExpr"

echo >&2 "=== keyed image ==="
load "$work/keyed.tar" "$keyExpr"
keyedRef="$ref"
r() { "$SSH" "${SSHO[@]}" root@"$ip" "$@"; }

echo >&2 "=== keyed image without --rosetta ==="
# No share: the rosetta mount (nofail) and systemd-binfmt fail, nothing
# else; the container keeps serving aarch64-linux builds.
container rm -f "$norosetta" >/dev/null 2>&1 || true
container run -d --name "$norosetta" "${capFlags[@]}" "$keyedRef" >/dev/null
ip="$(ipOf "$norosetta")"
[ -n "$ip" ] || fail "no IPv4 address for $norosetta"
waitForPort "$ip" 22 || fail "sshd never answered without --rosetta"
r true || fail "root key login refused without --rosetta"
r 'systemctl is-system-running --wait' >/dev/null 2>&1 || true
failed="$(r 'systemctl --failed --plain --no-legend' | awk '{print $1}')"
[ -z "$(grep -vE '^(systemd-binfmt\.service|run-rosetta\.mount)$' <<<"$failed")" ] \
  || fail "unexpected failed units without --rosetta: $(echo $failed)"
r '[ ! -e /proc/sys/fs/binfmt_misc/rosetta ]' || fail "Rosetta registered without its share"
out="$(PATH="/usr/bin:$PATH" NIX_SSHOPTS="${SSHO[*]}" \
  nix build --no-link --print-out-paths --eval-store auto --store "ssh-ng://root@$ip" \
  --expr "derivation { name = \"lbi-norosetta-$(date +%s)\"; system = \"aarch64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ok > \$out\" ]; }" 2>/dev/null | tail -1)"
[ -n "$out" ] && [ "$(r "cat $out")" = ok ] || fail "aarch64 build failed without --rosetta"
pass "without --rosetta the builder still serves aarch64-linux; x86_64 is simply unregistered"

echo >&2 "=== all checks passed ==="
