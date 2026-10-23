{
  lib,
  bats,
  container,
  runCommand,
  shellcheck-minimal,
  writeShellApplication,
  writeTextFile,
}:
{
  name,
  # Test name -> bats body. Unordered: no test may depend on another.
  tests,
  # check: passes when built. e2e and benchmark: a runner, run in the user's
  # session (docs/adr/0001-end-to-end-tests-run-in-the-user-session.md).
  kind ? "check",
  setupFile ? "",
  teardownFile ? "",
  setup ? "",
  teardown ? "",
  # Shell, as files or strings, inlined before the hooks.
  helpers ? [ ],
  inputs ? [ ],
  meta ? { },
}:
assert lib.elem kind [
  "check"
  "e2e"
  "benchmark"
];
let
  bats' = bats.withLibraries (p: [
    p.bats-support
    p.bats-assert
  ]);
  hook = fn: body: lib.optionalString (body != "") "${fn}() {\n${body}\n}\n";
  quote = s: ''"${lib.escape [ "\\" "\"" "$" "`" ] s}"'';
  suite = writeTextFile {
    name = "${name}.bats";
    text =
      lib.concatMapStrings (h: if lib.isPath h then builtins.readFile h else h + "\n") (
        [ ./helpers.sh ] ++ helpers
      )
      + hook "setup_file" setupFile
      + hook "teardown_file" teardownFile
      + hook "setup" setup
      + hook "teardown" teardown
      + lib.concatStrings (lib.mapAttrsToList (n: body: "@test ${quote n} {\n${body}\n}\n") tests);
    # SC2016: tests expect literal $s, in single quotes. SC2119/SC2120:
    # shellcheck can't see the arguments `run` passes.
    checkPhase = "${lib.getExe shellcheck-minimal} -s bats -e SC2016,SC2119,SC2120 $target";
  };
  passthru = { inherit kind suite; };
in
if kind == "check" then
  runCommand name
    {
      nativeBuildInputs = [ bats' ] ++ inputs;
      inherit passthru meta;
    }
    ''
      export HOME="$TMPDIR"
      bats ${suite}
      touch $out
    ''
else
  writeShellApplication {
    inherit name passthru;
    runtimeInputs = [
      bats'
      container
    ]
    ++ inputs;
    text = ''exec bats ${suite} "$@"'';
    meta = {
      inherit (container.meta) platforms;
    }
    // meta;
  }
