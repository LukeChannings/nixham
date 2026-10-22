setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/nix.args"
[ -z "${NIX_ERROR:-}" ] || { echo "error: $NIX_ERROR" >&2; exit 1; }
printf '%s' "$RESPONSE"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/nix"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : >"$GITHUB_ENV"

  # The real print-dev-env --json shape: PATH among other exported variables,
  # some multi-line.
  export RESPONSE='{"bashFunctions":{},"variables":{
    "PATH":{"type":"exported","value":"/nix/store/aaa-just/bin:/nix/store/bbb-jq/bin"},
    "shellHook":{"type":"exported","value":"line one\nline two"},
    "HOME":{"type":"exported","value":"/homeless-shelter"}}}'

  setup_sh="$BATS_TEST_DIRNAME/../setup.sh"
}

@test "prepends the devshell PATH to the job PATH via GITHUB_ENV" {
  run bash "$setup_sh"

  assert_success
  assert_equal "$(cat "$GITHUB_ENV")" \
    "PATH=/nix/store/aaa-just/bin:/nix/store/bbb-jq/bin:$PATH"
}

@test "materialises devShells.ci, falling back to devShells.default" {
  run bash "$setup_sh"

  assert_success
  run cat "$BATS_TEST_TMPDIR/nix.args"
  assert_line -- print-dev-env
  assert_line -- --impure
  assert_line -- --json
  assert_line --partial 'devShell.ci or devShell.default'
}

@test "fails hard and writes nothing when the devshell does not materialise" {
  NIX_ERROR='attribute missing' run bash "$setup_sh"

  assert_failure
  assert_output --partial 'attribute missing'
  refute [ -s "$GITHUB_ENV" ]
}

@test "fails hard on JSON without a PATH" {
  RESPONSE='{"variables":{}}' run bash "$setup_sh"

  assert_failure
  refute [ -s "$GITHUB_ENV" ]
}
