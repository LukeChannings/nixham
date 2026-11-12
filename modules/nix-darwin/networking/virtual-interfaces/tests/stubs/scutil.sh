# Fake of macOS scutil(8) --prefs over SystemConfiguration's preferences, kept
# as JSON in $FAKE_PREFS. Each `set` is appended to $FAKE_LOG. Mirrors configd
# on apply: it creates each bridge it was just given, without members, which
# it cannot add. macOS adds a bridge's network service minutes later, so
# nothing here does.

[ "$1" = --prefs ] && [ $# = 1 ] || exit 1
# $FAKE_SCUTIL_FAIL stands in for preferences another process holds a lock on.
[ -z "$FAKE_SCUTIL_FAIL" ] || exit 1

set -f
prefs=$(cat "$FAKE_PREFS")
dict='{}'
bridges=()
while read -r cmd arg rest; do
  case $cmd in
  d.init) dict='{}' ;;
  get) dict=$(jq -c --arg p "$arg" 'getpath($p | ltrimstr("/") | split("/")) // {}' <<<"$prefs") ;;
  d.add)
    set -- $rest
    case $1 in
    '*') shift && value=$(jq -cn '$ARGS.positional' --args "$@") ;;
    '?') value=$([ "$2" = TRUE ] && echo true || echo false) ;;
    *) value=$(jq -cn --arg v "$*" '$v') ;;
    esac
    dict=$(jq -c --arg k "$arg" --argjson v "$value" '.[$k] = $v' <<<"$dict")
    ;;
  set)
    echo "scutil set $arg" >>"$FAKE_LOG"
    prefs=$(jq --arg p "$arg" --argjson d "$dict" 'setpath($p | ltrimstr("/") | split("/"); $d)' <<<"$prefs")
    case $arg in
    /VirtualNetworkInterfaces/Bridge/*) bridges+=("${arg##*/}") ;;
    esac
    ;;
  commit) echo "$prefs" >"$FAKE_PREFS" ;;
  apply) for b in "${bridges[@]}"; do mkdir -p "$FAKE_NET/$b"; done ;;
  esac
done

# scutil exits 0 whether or not the preferences took, and $FAKE_SCUTIL_LIES is
# the other half of that: the write lands and it still reports failure.
[ -z "$FAKE_SCUTIL_LIES" ]
