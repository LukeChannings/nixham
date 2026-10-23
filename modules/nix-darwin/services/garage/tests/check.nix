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
      services.garage = {
        enable = true;
        package = writeShellScriptBin "garage" ''echo "garage $* $SECRET"'';
        logLevel = "debug";
        environmentFile = "/run/secrets/garage.env";
        extraEnvironment.RUST_BACKTRACE = "yes";
        settings.replication_factor = 1;
      };
    }
  ];
  daemon = (s.daemon "garage").serviceConfig;
in
makeTest {
  name = "garage";
  tests = {
    "the fixture passes every assertion" = ''
      assert_equal ${json s.failedAssertions} '[]'
    '';
    "garage runs as _garage, through the store's entrypoint" = ''
      run echo ${esc (lib.last daemon.ProgramArguments)}
      assert_output --regexp '^/bin/wait4path /nix/store && exec /nix/store/[^ ]*-garage-start$'
      assert_equal ${
        json [
          daemon.UserName
          daemon.RunAtLoad
          daemon.KeepAlive
          daemon.EnvironmentVariables
          s.config.users.users._garage.uid
        ]
      } '["_garage",true,true,{"GARAGE_CONFIG_FILE":"/etc/garage.toml","RUST_BACKTRACE":"yes","RUST_LOG":"garage=debug"},4098]'
    '';
    "garage serves with the environment file's variables" = ''
      cd "$BATS_TEST_TMPDIR"
      sed 's|/run/secrets/garage.env|garage.env|' ${(s.daemon "garage").command} >start
      echo SECRET=s3cr3t >garage.env
      run bash start
      assert_output 'garage server s3cr3t'
    '';
    "the settings are garage.toml" = ''
      run cat ${s.config.environment.etc."garage.toml".source}
      assert_line 'replication_factor = 1'
      assert_line 'metadata_dir = "/private/var/lib/garage/meta"'
    '';
  };
}
