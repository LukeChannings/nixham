printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/curl.args"
cat >"$BATS_TEST_TMPDIR/curl.stdin"
printf '%s' "$RESPONSE"
