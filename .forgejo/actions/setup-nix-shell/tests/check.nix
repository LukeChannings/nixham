{ makeTest, jq }:
makeTest {
  name = "setup-nix-shell";
  inputs = [ jq ];
  helpers = [ ./helpers.sh ];
  # The real print-dev-env --json shape: exported variables (some multi-line,
  # some sandbox-only), plus unexported shell variables and arrays.
  setup = ''
    stub ${./stubs}
    export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
    : >"$GITHUB_ENV"
    export RESPONSE='{"bashFunctions":{},"variables":{
      "PATH":{"type":"exported","value":"/nix/store/aaa-just/bin:/nix/store/bbb-jq/bin"},
      "NIX_LDFLAGS":{"type":"exported","value":" -L/nix/store/ccc-libiconv/lib"},
      "shellHook":{"type":"exported","value":"line one\nline two"},
      "HOME":{"type":"exported","value":"/homeless-shelter"},
      "TMPDIR":{"type":"exported","value":"/build"},
      "phase":{"type":"var","value":"buildPhase"},
      "outputs":{"type":"array","value":["out"]}}}'
  '';
  tests = {
    "prepends the devshell PATH to the job PATH" = ''
      run bash ${../setup.sh}

      assert_success
      assert_equal "$(github_env PATH)" \
        "/nix/store/aaa-just/bin:/nix/store/bbb-jq/bin:$PATH"
    '';
    "exports the rest of the devshell environment" = ''
      run bash ${../setup.sh}

      assert_success
      assert_equal "$(github_env NIX_LDFLAGS)" " -L/nix/store/ccc-libiconv/lib"
    '';
    "keeps multi-line values intact" = ''
      run bash ${../setup.sh}

      assert_success
      assert_equal "$(github_env shellHook)" $'line one\nline two'
    '';
    "skips the sandbox variables nix develop ignores" = ''
      run bash ${../setup.sh}

      assert_success
      run github_env HOME
      assert_failure
      run github_env TMPDIR
      assert_failure
    '';
    "skips unexported shell variables and arrays" = ''
      run bash ${../setup.sh}

      assert_success
      run github_env phase
      assert_failure
      run github_env outputs
      assert_failure
    '';
    "materialises devShells.ci, falling back to devShells.default" = ''
      run bash ${../setup.sh}

      assert_success
      run cat "$BATS_TEST_TMPDIR/nix.args"
      assert_line -- print-dev-env
      assert_line -- --impure
      assert_line -- --json
      assert_line --partial 'devShell.ci or devShell.default'
    '';
    "fails hard and writes nothing when the devshell does not materialise" = ''
      NIX_ERROR='attribute missing' run bash ${../setup.sh}

      assert_failure
      assert_output --partial 'attribute missing'
      refute [ -s "$GITHUB_ENV" ]
    '';
    "fails hard on JSON without a PATH" = ''
      RESPONSE='{"variables":{}}' run bash ${../setup.sh}

      assert_failure
      refute [ -s "$GITHUB_ENV" ]
    '';
  };
}
