{
  lib,
  makeTest,
  darwin,
  writeShellScriptBin,
}:
let
  inherit (darwin) esc json text;
  socket = "/private/var/lib/litellm/redis/redis.sock";
  litellm = cfg: {
    services.litellm = {
      enable = true;
      redis = {
        enable = true;
        package = writeShellScriptBin "redis-server" ''echo "redis-server $*"'';
      };
    }
    // cfg;
  };
  s = darwin.evalNative [
    (litellm { })
    { launchd.logging.enable = true; }
  ];
  noRedis = darwin.eval [ (litellm { redis.enable = false; }) ];
  noFunnel = darwin.eval [ (litellm { }) ];
  daemon = name: (s.daemon name).serviceConfig;
  activation = text "launchd" s.config.system.activationScripts.script.text;
in
makeTest {
  name = "litellm";
  tests = {
    "the fixture passes every assertion" = ''
      assert_equal ${json s.failedAssertions} '[]'
    '';
    "redis runs beside litellm, as _litellm" = ''
      run echo ${esc (lib.last (daemon "litellm-redis").ProgramArguments)}
      assert_output --regexp '^/bin/wait4path /nix/store && exec /nix/store/[^ ]*-litellm-redis-start$'
      assert_equal ${
        json (
          lib.attrVals [
            "UserName"
            "GroupName"
            "RunAtLoad"
            "KeepAlive"
            "StandardErrorPath"
          ] (daemon "litellm-redis")
        )
      } '["_litellm","_litellm",true,true,"/var/log/launchd/org.nixos.litellm-redis.log"]'
    '';
    "redis listens only on a socket in a 0700 directory" = ''
      cd "$BATS_TEST_TMPDIR"
      sed 's|/private/var/lib/litellm|state|g' ${(s.daemon "litellm-redis").command} >start
      run bash start
      assert_output --regexp '^redis-server /nix/store/[^ ]*-litellm-redis.conf$'
      assert_equal "$(stat -c %a state/redis)" 700
      run cat "''${output#redis-server }"
      assert_line 'port 0'
      assert_line 'unixsocket "${socket}"'
      assert_line 'unixsocketperm 700'
      assert_line 'save ""'
      refute_line --partial bind
    '';
    "litellm is given REDIS_URL, and waits for the socket" = ''
      assert_equal ${esc (daemon "litellm").EnvironmentVariables.REDIS_URL} unix://${socket}
      run echo ${esc (lib.last (daemon "litellm").ProgramArguments)}
      assert_output --regexp '^/bin/wait4path /nix/store && until \[ -e ${socket} \]; do /bin/sleep 1; done && exec /nix/store/[^ ]*-litellm-start$'
    '';
    "the directories are made before launchd loads the daemons" = ''
      run cat ${activation}
      assert_output --regexp "chmod 700 .*'/private/var/lib/litellm/redis'"
      created="$(grep -n 'chown -R _litellm:_litellm' <<<"$output" | head -1 | cut -d: -f1)"
      loaded="$(grep -n 'launchctl load' <<<"$output" | head -1 | cut -d: -f1)"
      [ "$created" -lt "$loaded" ]
      assert_output --partial 'chown _litellm:_litellm /var/log/launchd/org.nixos.litellm-redis.log'
    '';
    "without redis, nothing is wired to it" = ''
      assert_equal ${
        json [
          (noRedis.config.launchd.daemons ? litellm-redis)
          ((noRedis.daemon "litellm").serviceConfig.EnvironmentVariables ? REDIS_URL)
          (noRedis.daemon "litellm").waitForPaths
        ]
      } '[false,false,[]]'
    '';
    "without the log funnel, the daemons log to /var/log/litellm" = ''
      assert_equal ${json (noFunnel.daemon "litellm-redis").serviceConfig.StandardErrorPath} '"/var/log/litellm/redis.log"'
      assert_equal ${json (noFunnel.daemon "litellm").serviceConfig.StandardErrorPath} '"/var/log/litellm/stderr.log"'
    '';
  };
}
