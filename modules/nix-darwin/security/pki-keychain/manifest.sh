# manifest.sh <dir> [<certificate> <policy>]...: each certificate as
# <dir>/<SHA-1>.crt, its policy beside it as <SHA-1>.policy.
set -euo pipefail

out=$1
shift
mkdir -p "$out"

while [ $# -gt 0 ]; do
  file=$1 policy=$2
  shift 2
  if [ "$(grep -c 'BEGIN CERTIFICATE' "$file")" != 1 ]; then
    echo "error: security.pki.keychainCertificates: $file must contain exactly one PEM certificate" >&2
    exit 1
  fi
  fp=$(openssl x509 -noout -fingerprint -sha1 -in "$file")
  fp=${fp#*=}
  fp=${fp//:/}
  if [ "$policy" = trustRoot ]; then
    subject=$(openssl x509 -noout -subject -in "$file")
    issuer=$(openssl x509 -noout -issuer -in "$file")
    if [ "${subject#subject=}" != "${issuer#issuer=}" ]; then
      echo "error: security.pki.keychainCertificates: policy \"trustRoot\" requires a self-signed certificate, but $file is not self-signed (use \"trustAsRoot\")" >&2
      exit 1
    fi
  fi
  cp "$file" "$out/$fp.crt"
  echo "$policy" >"$out/$fp.policy"
done
