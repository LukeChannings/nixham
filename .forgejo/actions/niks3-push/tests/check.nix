{ makeTest, jq }:
makeTest {
  name = "niks3-push";
  inputs = [ jq ];
  setup = ''
    stub ${./stubs}
    export NIKS3_CI_TOKEN=ci-secret
  '';
  tests = {
    "exchanges the CI token for an aud=niks3 token" = ''
      RESPONSE='{"access_token":"niks3-token","expires_in":900}' run bash ${../token.sh}

      assert_success
      assert_equal "$(jq -r .token <<<"$output")" niks3-token
      jq -e '.expires_at | fromdate > now' <<<"$output"
      assert_equal "$(cat "$BATS_TEST_TMPDIR/curl.stdin")" ci-secret
      run cat "$BATS_TEST_TMPDIR/curl.args"
      assert_line audience=niks3
      assert_line subject_token@-
      refute_output --partial ci-secret
    '';
    "honours token endpoint and client overrides" = ''
      export NIKS3_TOKEN_URL=https://sso.example/token NIKS3_CLIENT=cache
      RESPONSE='{"access_token":"t","expires_in":900}' run bash ${../token.sh}

      assert_success
      run cat "$BATS_TEST_TMPDIR/curl.args"
      assert_line https://sso.example/token
      assert_line audience=cache
      assert_line client_id=cache
    '';
    "fails when the exchange returns no access token" = ''
      RESPONSE='{"error":"invalid_grant"}' run bash ${../token.sh}

      assert_failure
      assert_output --partial "no access_token"
    '';
  };
}
