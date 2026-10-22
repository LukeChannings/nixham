# nixham and kernel are set by ./package.nix.
image=ghcr.io/lukechannings/linux-builder:latest

usage() {
  cat <<EOF
Usage: linux-builder [shell] [FLAG...] [OPTION...] [-- COMMAND [ARG...]]
       linux-builder tty [FLAG...] [OPTION...]

Runs $image in apple/container, on a pinned kernel.

  shell  Runs COMMAND, or \$SHELL, with Nix building Linux derivations on a
         detached builder, which stops when it exits.
  tty    Logs in as root on the builder's console; exit stops it.

FLAGs build from this linux-builder's revision of nixham ($nixham):
  --build-kernel  its kernel, instead of the pinned one
  --build-image   its image, instead of pulling $image

OPTIONs go to \`container run\`, e.g. --cpus 8 --memory 16g, or
-v linux-builder:/persist to keep the builder's store across runs.
EOF
}

say() {
  echo "linux-builder: $*" >&2
}

die() {
  say "$@"
  exit 1
}

# build <attr>: nixham's <attr>. nix-build writes the closure's every .drv
# through the daemon even when <attr> is already built; evaluating is enough.
build() {
  local out
  out=$(nix-instantiate --eval --raw -A "$1.outPath" "$nixham")
  nix-store --check-validity "$out" >/dev/null 2>&1 ||
    nix-build --no-out-link -A "$1" "$nixham" >/dev/null
  echo "$out"
}

mode=shell
case ${1:-} in
-h | --help)
  usage
  exit
  ;;
shell | tty)
  mode=$1
  shift
  ;;
esac

build_kernel='' build_image='' options=()
while [ $# -gt 0 ] && [ "$1" != -- ]; do
  case $1 in
  --build-kernel) build_kernel=1 ;;
  --build-image) build_image=1 ;;
  *) options+=("$1") ;;
  esac
  shift
done
[ $# -eq 0 ] || shift
[ "$mode" = shell ] || [ $# -eq 0 ] || die "tty runs no COMMAND"
[ $# -gt 0 ] || set -- "${SHELL:-bash}"

command -v container >/dev/null ||
  die "needs apple/container's \`container\` CLI: https://github.com/apple/container"

dir=$(mktemp -d)
id=
trap '
  [ -z "$id" ] || { say "stopping the builder"; container stop "$id" >/dev/null; }
  rm -rf "$dir"' EXIT

if [ -n "$build_kernel" ]; then
  say "building the kernel from $nixham"
  kernel=$(build apple-container-kernel)/vmlinux-arm64
fi

if [ -n "$build_image" ]; then
  say "building the image from $nixham"
  image=$(container image load -i "$(build linux-builder-image)")
else
  say "pulling $image"
  container image pull "$image" >"$dir/pull.log" 2>&1 || {
    container image inspect "$image" >/dev/null 2>&1 || {
      cat "$dir/pull.log" >&2
      exit 1
    }
    say "could not pull $image; running the copy pulled before"
  }
fi

run=(container run --rm --rosetta --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN --kernel "$kernel")

if [ "$mode" = tty ]; then
  say "starting the builder's console; exit stops it"
  rm -rf "$dir"
  exec "${run[@]}" -it "${options[@]}" "$image"
fi

# The builder's /config: it authorizes key for builder and presents host_key,
# which pins the builder for both the probe below and Nix.
key=$dir/key
host_key=$dir/config/ssh/ssh_host_ed25519_key
mkdir -p "$dir/config/ssh/authorized_keys.d"
ssh-keygen -q -t ed25519 -N '' -C linux-builder -f "$key"
ssh-keygen -q -t ed25519 -N '' -C linux-builder -f "$host_key"
cp "$key.pub" "$dir/config/ssh/authorized_keys.d/builder"

say "starting the builder ($image)"
# Its progress lines only matter when it fails.
id=$("${run[@]}" -d --mount "type=bind,source=$dir/config,target=/config,readonly" \
  "${options[@]}" "$image" 2>"$dir/run.log") || {
  cat "$dir/run.log" >&2
  exit 1
}
ip=$(container inspect "$id" | jq -r '.[0].status.networks[0].ipv4Address | sub("/.*"; "")')
echo "$ip $(cut -d' ' -f1,2 "$host_key.pub")" >"$dir/known_hosts"

say "waiting for the builder at $ip"
# /usr/bin/ssh: only Apple's binaries get the macOS Local Network permission.
# The builder reports what it builds: its CPUs, systems and features.
deadline=$((SECONDS + 90))
until probe=$(/usr/bin/ssh -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none \
  -o UserKnownHostsFile="$dir/known_hosts" -o BatchMode=yes -o ConnectTimeout=5 \
  -o LogLevel=ERROR "builder@$ip" \
  'nproc; echo $(nix config show system) $(nix config show extra-platforms); nix config show system-features' \
  2>/dev/null); do
  [ "$SECONDS" -lt "$deadline" ] || die "the builder never answered on $ip:22"
  sleep 0.2
done
{
  read -r jobs
  read -r systems
  read -r features
} <<<"$probe"

machine="ssh-ng://builder@$ip ${systems// /,} $key $jobs 1 ${features// /,} - $(base64 -w0 <"$host_key.pub")"
say "ready: Nix in this shell builds ${systems// /, } on $id ($ip); exit stops it"

status=0
LINUX_BUILDER_CONTAINER=$id NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}builders = $machine
builders-use-substitutes = true" "$@" || status=$?
exit "$status"
