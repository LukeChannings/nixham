# renew.sh <state dir> <domain> <group> <valid days> <lego flag>...: issues
# or renews the certificate, then lays it out as NixOS does, in
# <state dir>/<domain>.
state=$1 domain=$2 group=$3 days=$4
shift 4

# lego's metadata, not the key, which may be a self-signed placeholder.
if [ -f "$state/certificates/$domain.json" ]; then
  lego "$@" renew --days "$days"
else
  lego "$@" run
fi

dir="$state/$domain"
mkdir -p "$dir"
cp -f "$state/certificates/$domain.crt" "$dir/fullchain.pem"
cp -f "$state/certificates/$domain.key" "$dir/key.pem"
if [ -f "$state/certificates/$domain.issuer.crt" ]; then
  cp -f "$state/certificates/$domain.issuer.crt" "$dir/chain.pem"
  chmod 644 "$dir/chain.pem"
fi
ln -sf fullchain.pem "$dir/cert.pem"
chown "_acme:$group" "$dir" "$dir"/*
chmod 750 "$dir"
chmod 640 "$dir/key.pem"
chmod 644 "$dir/fullchain.pem"
