# keychain.sh <manifest> <previous manifest> <keychain>: trusts the
# manifest's certificates in the keychain, and removes those only the
# previous manifest has. Certificates of neither are never touched.
set -uo pipefail

new=$1 old=$2 keychain=$3

any() {
  local f
  for f; do [ -e "$f" ] && return; done
  return 1
}
any "$new"/*.crt "$old"/*.crt || exit 0

echo "setting up keychain certificates..." >&2

settings=$(mktemp -d)
trap 'rm -rf "$settings"' EXIT
security trust-settings-export -d "$settings/admin.plist" >/dev/null 2>&1 || true

# trusted <SHA-1> <kSecTrustSettingsResult>: present, with that trust result.
# An entry without a result means trustRoot (1).
trusted() {
  local got
  security find-certificate -a -Z "$keychain" 2>/dev/null | grep -x "SHA-1 hash: $1" >/dev/null || return 1
  plutil -extract "trustList.$1" xml1 -o /dev/null "$settings/admin.plist" 2>/dev/null || return 1
  got=$(plutil -extract "trustList.$1.trustSettings.0.kSecTrustSettingsResult" raw -o - "$settings/admin.plist" 2>/dev/null) || got=1
  [ "$got" = "$2" ]
}

for crt in "$old"/*.crt; do
  [ -e "$crt" ] || break
  fp=$(basename "$crt" .crt)
  [ ! -e "$new/$fp.crt" ] || continue
  echo "removing keychain certificate $fp" >&2
  security remove-trusted-cert -d "$crt" 2>/dev/null ||
    echo "warning: failed to remove trust settings for $fp" >&2
  security delete-certificate -Z "$fp" "$keychain" >/dev/null 2>&1 ||
    echo "warning: failed to delete certificate $fp from $keychain" >&2
done

for crt in "$new"/*.crt; do
  [ -e "$crt" ] || break
  fp=$(basename "$crt" .crt)
  policy=$(cat "$new/$fp.policy")
  case $policy in
  trustRoot) result=1 ;;
  trustAsRoot) result=2 ;;
  esac
  trusted "$fp" "$result" && continue
  echo "trusting keychain certificate $fp ($policy)" >&2
  security add-trusted-cert -d -r "$policy" -k "$keychain" "$crt" ||
    echo "warning: failed to trust certificate $fp in $keychain" >&2
done
