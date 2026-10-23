{
  lib,
  makeTest,
  darwin,
  writeShellScriptBin,
}:
let
  inherit (darwin) esc json;
  s = darwin.evalNative [
    {
      services.alloy = {
        enable = true;
        package = writeShellScriptBin "alloy" ''echo "alloy $* $SECRET"'';
        environmentFile = "/run/secrets/alloy.env";
        extraFlags = [ "--disable-reporting" ];
      };
    }
  ];
  daemon = (s.daemon "alloy").serviceConfig;
in
makeTest {
  name = "alloy";
  tests = {
    "the fixture passes every assertion" = ''
      assert_equal ${json s.failedAssertions} '[]'
    '';
    "alloy runs as _alloy, logging to its state" = ''
      run echo ${esc (lib.last daemon.ProgramArguments)}
      assert_output --regexp '^/bin/wait4path /nix/store && exec /nix/store/[^ ]*-alloy-start$'
      assert_equal ${
        json [
          daemon.UserName
          daemon.WorkingDirectory
          daemon.StandardErrorPath
          s.config.users.users._alloy.uid
        ]
      } '["_alloy","/private/var/lib/alloy","/private/var/lib/alloy/alloy.log",536]'
    '';
    "alloy runs the config with the environment file's variables" = ''
      cd "$BATS_TEST_TMPDIR"
      echo SECRET=s3cr3t >alloy.env
      sed 's|/run/secrets/alloy.env|alloy.env|' ${(s.daemon "alloy").command} >start
      run bash start
      assert_output 'alloy run /etc/alloy --disable-reporting s3cr3t'
    '';
  };
}
