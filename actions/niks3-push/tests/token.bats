setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/curl.args"
cat >"$BATS_TEST_TMPDIR/curl.stdin"
printf '%s' "$RESPONSE"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export NIKS3_CI_TOKEN=ci-secret
  token="$BATS_TEST_DIRNAME/../token.sh"
}

@test "exchanges the CI token for an aud=niks3 token" {
  RESPONSE='{"access_token":"niks3-token","expires_in":900}' run bash "$token"

  assert_success
  assert_equal "$(jq -r .token <<<"$output")" niks3-token
  jq -e '.expires_at | fromdate > now' <<<"$output"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/curl.stdin")" ci-secret
  run cat "$BATS_TEST_TMPDIR/curl.args"
  assert_line audience=niks3
  assert_line subject_token@-
  refute_output --partial ci-secret
}

@test "fails when the exchange returns no access token" {
  RESPONSE='{"error":"invalid_grant"}' run bash "$token"

  assert_failure
  assert_output --partial "no access_token"
}
