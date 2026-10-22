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

  # The real print-dev-env --json shape: exported variables (some multi-line,
  # some sandbox-only), plus unexported shell variables and arrays.
  export RESPONSE='{"bashFunctions":{},"variables":{
    "PATH":{"type":"exported","value":"/nix/store/aaa-just/bin:/nix/store/bbb-jq/bin"},
    "NIX_LDFLAGS":{"type":"exported","value":" -L/nix/store/ccc-libiconv/lib"},
    "shellHook":{"type":"exported","value":"line one\nline two"},
    "HOME":{"type":"exported","value":"/homeless-shelter"},
    "TMPDIR":{"type":"exported","value":"/build"},
    "phase":{"type":"var","value":"buildPhase"},
    "outputs":{"type":"array","value":["out"]}}}'

  setup_sh="$BATS_TEST_DIRNAME/../setup.sh"
}

# Reads NAME back out of $GITHUB_ENV, as the runner parses it: NAME=VALUE
# lines and NAME<<DELIMITER heredocs.
github_env() {
  local line key delim value
  while IFS= read -r line; do
    if [[ $line == *'<<'* ]]; then
      key=${line%%<<*} delim=${line#*<<} value=
      while IFS= read -r line && [ "$line" != "$delim" ]; do
        value+=${value:+$'\n'}$line
      done
    else
      key=${line%%=*} value=${line#*=}
    fi
    [ "$key" != "$1" ] || { printf '%s' "$value"; return; }
  done <"$GITHUB_ENV"
  return 1
}

@test "prepends the devshell PATH to the job PATH" {
  run bash "$setup_sh"

  assert_success
  assert_equal "$(github_env PATH)" \
    "/nix/store/aaa-just/bin:/nix/store/bbb-jq/bin:$PATH"
}

@test "exports the rest of the devshell environment" {
  run bash "$setup_sh"

  assert_success
  assert_equal "$(github_env NIX_LDFLAGS)" " -L/nix/store/ccc-libiconv/lib"
}

@test "keeps multi-line values intact" {
  run bash "$setup_sh"

  assert_success
  assert_equal "$(github_env shellHook)" $'line one\nline two'
}

@test "skips the sandbox variables nix develop ignores" {
  run bash "$setup_sh"

  assert_success
  run github_env HOME
  assert_failure
  run github_env TMPDIR
  assert_failure
}

@test "skips unexported shell variables and arrays" {
  run bash "$setup_sh"

  assert_success
  run github_env phase
  assert_failure
  run github_env outputs
  assert_failure
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
