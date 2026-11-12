# Fake of macOS plutil(1) -extract, over SystemConfiguration's preferences
# kept as JSON in $FAKE_PREFS. raw prints a dictionary's keys one per line, a
# boolean as true or false, and a string as itself; a missing key path fails.

case "$1 $3 $4 $5" in
"-extract json -o -") raw=() ;;
"-extract raw -o -") raw=(-r) ;;
*) exit 1 ;;
esac

exec jq -c "${raw[@]}" --arg path "$2" --arg fmt "$3" '
  getpath($path | split(".")) | if . == null then error("no value at that key path") end
  | if $fmt == "raw" and type == "object" then keys_unsorted[] else . end
' "$FAKE_PREFS" 2>/dev/null
