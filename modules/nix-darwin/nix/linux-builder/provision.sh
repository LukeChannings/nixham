# provision.sh <dir> <user> <ssh user> <host> [key...]: the builder's host-side
# material in <dir>. Its /config (the user's, as their runtime mounts it)
# authorizes <dir>/ssh_key and each key for <ssh user>, and holds its host
# key, pinned for <host> in <dir>/known_hosts. Both keys are generated once.
# Prints "changed" when /config did. Run as root, with ssh-keygen on PATH.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo >&2 "usage: $0 <dir> <user> <ssh user> <host> [key...]"
  exit 2
fi
dir=$1 user=$2 sshUser=$3 host=$4
shift 4
config=$dir/config
hostKey=$config/ssh/ssh_host_ed25519_key

digest() {
  cat "$config/ssh/authorized_keys.d/$sshUser" "$hostKey.pub" 2>/dev/null || true
}

install -d -m 755 "$dir"
umask 077
install -d -m 700 -o "$user" "$config" "$config/ssh" "$config/ssh/authorized_keys.d"
before=$(digest)

if [ ! -e "$dir/ssh_key" ]; then
  echo >&2 "linux-builder: generating the client key"
  ssh-keygen -q -t ed25519 -N '' -C linux-builder -f "$dir/ssh_key"
fi
if [ ! -e "$hostKey" ]; then
  echo >&2 "linux-builder: generating the host key"
  rm -f "$hostKey.pub"
  ssh-keygen -q -t ed25519 -N '' -C "$host" -f "$hostKey"
fi
chown "$user" "$hostKey" "$hostKey.pub"

for key in "$dir/ssh_key" "$@"; do
  ssh-keygen -y -f "$key" | cut -d' ' -f1,2
done | sort -u >"$config/ssh/authorized_keys.d/$sshUser"
chown "$user" "$config/ssh/authorized_keys.d/$sshUser"
chmod 644 "$config/ssh/authorized_keys.d/$sshUser"

echo "$host $(cut -d' ' -f1,2 "$hostKey.pub")" >"$dir/known_hosts"
chmod 644 "$dir/known_hosts"

[ "$before" = "$(digest)" ] || echo changed
