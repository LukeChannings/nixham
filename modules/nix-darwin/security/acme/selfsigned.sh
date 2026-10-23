# selfsigned.sh <state dir> <domain> <group>: a self-signed placeholder in
# <state dir>/<domain>, unless it holds a key already.
set -euo pipefail
dir="$1/$2" group=$3

[ ! -f "$dir/key.pem" ] || exit 0

mkdir -p "$dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && minica --domains "$2")
cp "$tmp/$2/cert.pem" "$dir/fullchain.pem"
cp "$tmp/$2/key.pem" "$dir/key.pem"
cp "$tmp/minica.pem" "$dir/chain.pem"
ln -sf fullchain.pem "$dir/cert.pem"
chown "_acme:$group" "$dir" "$dir"/*
chmod 750 "$dir"
chmod 640 "$dir/key.pem"
chmod 644 "$dir/fullchain.pem" "$dir/chain.pem"
