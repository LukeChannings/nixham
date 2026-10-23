# Reads security.sh's trust-settings-export: "<SHA-1> <result>" lines.
set -eu
key=$2 file=${*: -1}
fp=${key#trustList.}
fp=${fp%%.*}
result=$(sed -n "s/^$fp //p" "$file")
[ -n "$result" ] || exit 1
case $key in
*.kSecTrustSettingsResult) echo "$result" ;;
esac
