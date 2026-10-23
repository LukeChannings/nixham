{
  makeTest,
  linux-builder,
  ...
}:
makeTest {
  name = "linux-builder";
  tests = {
    "--help prints its usage" = ''
      run ${linux-builder}/bin/linux-builder --help
      assert_success
      assert_output --partial 'Usage: linux-builder [shell]'
    '';
    "without container on PATH, it says it needs it" = ''
      run env PATH=/usr/bin:/bin ${linux-builder}/bin/linux-builder shell
      assert_failure
      assert_output --partial "needs apple/container's \`container\` CLI"
    '';
  };
}
