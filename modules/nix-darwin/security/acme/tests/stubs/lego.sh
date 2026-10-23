# Issues for --domains into --path's certificates/, as lego does.
set -eu
echo "lego $*" >>"$calls"
while [ $# -gt 0 ]; do
  case $1 in
  --path) path=$2 ;;
  --domains) domain=$2 ;;
  esac
  shift
done
mkdir -p "$path/certificates"
for f in crt key issuer.crt json; do
  echo "$f" >"$path/certificates/$domain.$f"
done
