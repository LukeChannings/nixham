{ makeTest, jq }:
makeTest {
  name = "niks3-pin";
  inputs = [ jq ];
  setup = ''
    stub ${./stubs}
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
    export BACKOFF=0
  '';
  tests = {
    "pins the path resolved from an existing pin" = ''
      PINS='[{"name":"servant.abc","store_path":"/nix/store/aaa-x"}]' PIN_NAME=deployed.servant FROM_PIN=servant.abc run bash ${../pin.sh}

      assert_success
      run cat "$BATS_TEST_TMPDIR/niks3.calls"
      assert_line --index 0 --partial "pins list --json --auth-token-script"
      assert_line --index 1 --partial "deployed.servant /nix/store/aaa-x"
      assert_output --partial "niks3-push/token.sh"
      run cat "$GITHUB_OUTPUT"
      assert_line pinned=true
      assert_line store_path=/nix/store/aaa-x
    '';
    "pins an explicit store path without listing" = ''
      PIN_NAME=deployed.servant STORE_PATH=/nix/store/bbb-y run bash ${../pin.sh}

      assert_success
      run cat "$BATS_TEST_TMPDIR/niks3.calls"
      assert_output --partial "pins create"
      refute_output --partial "pins list"
      run cat "$GITHUB_OUTPUT"
      assert_line pinned=true
      assert_line store_path=/nix/store/bbb-y
    '';
    "succeeds with pinned=false when the source pin is absent" = ''
      PINS='[]' PIN_NAME=deployed.servant FROM_PIN=servant.abc run bash ${../pin.sh}

      assert_success
      assert_output --partial "no pin named servant.abc"
      run cat "$BATS_TEST_TMPDIR/niks3.calls"
      refute_output --partial "pins create"
      run cat "$GITHUB_OUTPUT"
      assert_line pinned=false
      assert_line store_path=
    '';
    "retries transient failures until a call succeeds" = ''
      FAIL_CALLS=2 PIN_NAME=p STORE_PATH=/nix/store/ccc-z ATTEMPTS=3 run bash ${../pin.sh}

      assert_success
      assert_output --partial "attempt 1/3"
      run cat "$GITHUB_OUTPUT"
      assert_line pinned=true
    '';
    "fails after exhausting attempts" = ''
      FAIL_CALLS=99 PIN_NAME=p STORE_PATH=/nix/store/ccc-z ATTEMPTS=2 run bash ${../pin.sh}

      assert_failure
      assert_output --partial "could not pin p after 2 attempts"
    '';
    "rejects neither or both of store_path and from_pin" = ''
      PIN_NAME=p run bash ${../pin.sh}
      assert_failure
      assert_output --partial "one of store_path or from_pin"

      PIN_NAME=p STORE_PATH=/nix/store/x FROM_PIN=y run bash ${../pin.sh}
      assert_failure
      assert_output --partial "mutually exclusive"
    '';
  };
}
