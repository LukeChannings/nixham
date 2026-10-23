# The keychain is $keychain_state: a file per certificate, named by its
# SHA-1, holding its trust result, if any. Calls are logged to $calls.
set -eu
echo "security $*" >>"$calls"
case $1 in
find-certificate)
  for f in "$keychain_state"/*; do
    [ ! -e "$f" ] || echo "SHA-1 hash: $(basename "$f")"
  done
  ;;
trust-settings-export)
  for f in "$keychain_state"/*; do
    [ ! -s "$f" ] || echo "$(basename "$f") $(cat "$f")"
  done >"$3"
  ;;
add-trusted-cert)
  case $4 in
  trustRoot) echo 1 ;;
  trustAsRoot) echo 2 ;;
  esac >"$keychain_state/$(basename "$7" .crt)"
  ;;
remove-trusted-cert)
  f="$keychain_state/$(basename "$3" .crt)"
  [ ! -e "$f" ] || : >"$f"
  ;;
delete-certificate)
  rm "$keychain_state/$3"
  ;;
esac
