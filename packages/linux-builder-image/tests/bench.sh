#!/usr/bin/env bash
# Time-to-nix-daemon of the working tree's builder image against a baseline
# revision, across the store-volume scenarios. See README.md.
#
#   BASE_REV=<rev> ROUNDS=5 ./bench.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
system="${SYSTEM:-aarch64-darwin}"
base="${BASE_REV:?set BASE_REV to the baseline commit}"
rounds="${ROUNDS:-5}"

# The guest kernel: this tree's apple-container-kernel, whose CONFIG_EROFS_FS
# the image's /etc overlay needs, rather than whatever the runtime defaults
# to. KERNEL=<Image> boots another; KERNEL= (empty) the runtime's default.
KERNEL="${KERNEL-$(nix-build --no-out-link -E "(builtins.getFlake (toString $repo)).packages.$system.apple-container-kernel")/vmlinux-arm64}"
kernelFlags=()
[ -z "$KERNEL" ] || kernelFlags=(--kernel "$KERNEL")

SSH=/usr/bin/ssh
PERL=/usr/bin/perl
work="$(mktemp -d)"
name=lbi-bench
volumes=(lbi-bench-restart lbi-bench-swap lbi-bench-fresh)
images=()

cleanup() {
  container rm -f "$name" >/dev/null 2>&1 || true
  container volume rm "${volumes[@]}" >/dev/null 2>&1 || true
  for i in "${images[@]}"; do container image rm "$i" >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -C lbi-bench -f "$work/key"
SSHO=(-i "$work/key" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=2)

# image <rev|""> <extra module expr>  → loads it, prints its ref
image() {
  local flake="git+file://$repo" expr
  [ -z "$1" ] || flake="$flake?rev=$1"
  expr="((builtins.getFlake \"$flake\").packages.$system.linux-builder-image.override { modules = [
    { users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile $work/key.pub) ]; } $2 ]; })"
  nix-build -o "$work/img.tar" -E "$expr" >&2 || exit 1
  container image load -i "$work/img.tar" >/dev/null || exit 1
  nix-instantiate --eval --raw -E "$expr.imageRef" 2>/dev/null
}

now() { "$PERL" -MTime::HiRes=time -e 'printf "%.3f", time'; }
waitForPort() {
  "$PERL" -MIO::Socket::INET -MTime::HiRes=time,sleep -e '
    my $d = time + 90;
    until (IO::Socket::INET->new(PeerAddr => $ARGV[0], PeerPort => 22, Proto => "tcp", Timeout => 0.1)) {
      exit 1 if time > $d; sleep 0.01;
    }' "$1"
}

# run <label> <ref> [volume]: one fresh-container boot; prints
#   label  host-run→daemon-query  guest-nix-daemon-active  guest-sshd-active  guest-systemd-start
# (guest columns are seconds since the VM's kernel booted)
run() {
  local label=$1 ref=$2 v=() ip t0 t1 g
  [ -z "${3:-}" ] || v=(-v "$3:/persist")
  container rm -f "$name" >/dev/null 2>&1 || true
  t0="$(now)"
  container run -d --name "$name" --rosetta --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN "${kernelFlags[@]}" "${v[@]}" "$ref" >/dev/null 2>&1 \
    || { echo >&2 "FAIL: $label: container run"; exit 1; }
  ip="$(container inspect "$name" | jq -r '.[0].status.networks[0].ipv4Address // empty' | cut -d/ -f1)"
  waitForPort "$ip" || { echo >&2 "FAIL: $label: sshd never answered"; exit 1; }
  until "$SSH" "${SSHO[@]}" root@"$ip" 'nix-store --store daemon -q --hash /run/current-system' >/dev/null 2>&1; do
    sleep 0.01
  done
  t1="$(now)"
  g="$("$SSH" "${SSHO[@]}" root@"$ip" '
    for u in nix-daemon.service sshd.service; do systemctl show -p ActiveEnterTimestampMonotonic --value $u; done
    systemctl show -p UserspaceTimestampMonotonic --value')"
  # shellcheck disable=SC2086
  set -- $g
  awk -v l="$label" -v a="$t0" -v b="$t1" -v d="$1" -v s="$2" -v u="$3" \
    'BEGIN { printf "%s %.3f %.3f %.3f %.3f\n", l, b - a, d / 1e6, s / 1e6, u / 1e6 }'
  container stop "$name" >/dev/null 2>&1 || true
}

echo >&2 "=== building images ==="
old="$(image "$base" "")"; images+=("$old")
new="$(image "" "")"; images+=("$new")
newB="$(image "" "{ environment.etc.lbi-bench-b.text = \"b\"; }")"; images+=("$newB")

container volume rm "${volumes[@]}" >/dev/null 2>&1 || true
container volume create lbi-bench-restart >/dev/null
container volume create lbi-bench-swap >/dev/null
run prime "$new" lbi-bench-restart >/dev/null
run prime "$newB" lbi-bench-swap >/dev/null

results="$work/results"
for i in $(seq "$rounds"); do
  echo >&2 "=== round $i/$rounds ==="
  run base-novol "$old" "" | tee -a "$results"
  run base-vol "$old" lbi-bench-restart | tee -a "$results"
  run novol "$new" "" | tee -a "$results"
  container volume rm lbi-bench-fresh >/dev/null 2>&1 || true
  container volume create lbi-bench-fresh >/dev/null
  run vol-fresh "$new" lbi-bench-fresh | tee -a "$results"
  run vol-restart "$new" lbi-bench-restart | tee -a "$results"
  if [ $((i % 2)) = 1 ]; then swap="$new"; else swap="$newB"; fi
  run vol-image-change "$swap" lbi-bench-swap | tee -a "$results"
done

echo >&2 "=== medians over $rounds rounds (s) ==="
{
  echo "scenario host-run→daemon guest-daemon-active guest-sshd-active guest-systemd-start"
  awk '{ print $1 }' "$results" | awk '!seen[$0]++' | while read -r l; do
    row="$l"
    for c in 2 3 4 5; do
      row="$row $(awk -v l="$l" -v c="$c" '$1 == l { print $c }' "$results" | sort -n \
        | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }')"
    done
    echo "$row"
  done
} | column -t
