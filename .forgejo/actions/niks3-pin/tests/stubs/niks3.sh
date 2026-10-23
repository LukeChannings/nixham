printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/niks3.calls"
n=$(wc -l <"$BATS_TEST_TMPDIR/niks3.calls")
[ "$n" -gt "${FAIL_CALLS:-0}" ] || exit 1
case "$1 $2" in
"pins list") printf '%s' "$PINS" ;;
"pins create") : ;;
*) exit 2 ;;
esac
