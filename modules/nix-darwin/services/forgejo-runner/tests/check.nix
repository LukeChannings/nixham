{
  makeTest,
  darwin,
  jq,
}:
let
  inherit (darwin) esc json;
  s = darwin.eval [
    {
      services.forgejo-runner = {
        enable = true;
        url = "https://forge.example.com";
        name = "mac";
        secretFile = "/run/secrets/runner";
        labels = [ "macos-arm64:host" ];
        settings.runner.timeout = "24h";
      };
    }
  ];
  # A host adding to the plist is the regression the fixed plist exists to
  # prevent, so the module has to catch it.
  leaked = darwin.eval [
    {
      services.forgejo-runner = {
        enable = true;
        url = "https://forge.example.com";
        name = "mac";
        secretFile = "/run/secrets/runner";
      };
      launchd.daemons.forgejo-runner.environment.GIT_CONFIG_SYSTEM = "${jq}/etc/gitconfig";
    }
  ];
  daemon = (s.daemon "forgejo-runner").serviceConfig;
  reconcileDaemon = (s.daemon "forgejo-runner-reconcile").serviceConfig;
  runner = s.config.services.forgejo-runner;
in
makeTest {
  name = "forgejo-runner";
  inputs = [ jq ];
  setup = ''
    stub ${./stubs}
    export calls="$BATS_TEST_TMPDIR/calls"
    export state="$BATS_TEST_TMPDIR/state"
    mkdir -p "$state"
    printf 'secret\n' >"$BATS_TEST_TMPDIR/secret"
  '';
  tests = {
    "the fixture passes every assertion" = ''
      assert_equal ${json s.failedAssertions} '[]'
    '';
    "the daemon starts from a fixed path, so no deploy can reload it" = ''
      assert_equal ${json daemon.Program} '"/usr/local/libexec/nix-darwin/forgejo-runner-launch"'
      run echo ${esc s.config.environment.launchDaemons."${daemon.Label}.plist".text}
      refute_output --partial /nix/store
      assert_equal ${
        json [
          daemon.UserName
          daemon.GroupName
          daemon.KeepAlive
          s.config.users.users.forgejo-runner.uid
        ]
      } '["forgejo-runner","forgejo-runner",true,4099]'
    '';
    "a store path reaching the plist is an eval error" = ''
      run echo ${json leaked.failedAssertions}
      assert_output --partial "nix-darwin will reload the runner"
    '';
    "the launcher waits for the generation's start script, then execs it" = ''
      assert_bash ${../launch.sh}
      run cat ${../launch.sh}
      assert_output --partial 'start=/run/current-system/sw/bin/forgejo-runner-start'
      assert_output --partial 'until [ -x "$start" ]; do /bin/sleep 1; done'
      assert_output --partial 'exec "$start"'
    '';
    "launchd outwaits the drain, and the host's own settings survive it" = ''
      assert_equal ${
        json [
          runner.settings.runner.shutdown_timeout
          runner.settings.runner.timeout
          runner.settings.runner.capacity
          daemon.ExitTimeOut
        ]
      } '["600s","24h",1,660]'
    '';
    "the runner file is recreated with the labels, before the daemon starts" = ''
      run bash ${../start.sh} "$state" https://forge.example.com "$BATS_TEST_TMPDIR/secret" mac '["macos-arm64:host"]' /config.yaml /nix/store/aaa-generation
      assert_success
      assert_equal "$(cat "$calls")" "$(printf '%s\n' 'act_runner create-runner-file --instance https://forge.example.com --secret secret --name mac' 'act_runner daemon --config /config.yaml')"
      assert_equal "$(jq -c .labels "$state/.runner")" '["macos-arm64:host"]'
    '';
    "the running daemon records which generation it is, and its own pid" = ''
      run bash ${../start.sh} "$state" https://forge.example.com "$BATS_TEST_TMPDIR/secret" mac '[]' /config.yaml /nix/store/aaa-generation
      assert_success
      assert_equal "$(cat "$state/.runner-closure")" /nix/store/aaa-generation
      assert_equal "$(cat "$state/.runner-pid")" "$(cat "$state/.daemon-pid")"
    '';
    "a runner already on the wanted generation is left alone" = ''
      printf '%s\n' /nix/store/aaa-generation >"$state/.runner-closure"
      run bash ${../reconcile.sh} "$state" org.nixos.forgejo-runner /nix/store/aaa-generation
      assert_success
      assert_equal "$(cat "$calls" 2>/dev/null || true)" ""
    '';
    "a stale runner is rolled onto the wanted generation once idle" = ''
      printf '%s\n' /nix/store/aaa-generation >"$state/.runner-closure"
      printf '%s\n' $$ >"$state/.runner-pid"
      run bash ${../reconcile.sh} "$state" org.nixos.forgejo-runner /nix/store/bbb-generation
      assert_success
      run cat "$calls"
      assert_line "pgrep -P $$"
      assert_line 'launchctl kickstart -k system/org.nixos.forgejo-runner'
    '';
    "a stale runner with jobs in flight is deferred to the next tick" = ''
      printf '%s\n' /nix/store/aaa-generation >"$state/.runner-closure"
      printf '%s\n' $$ >"$state/.runner-pid"
      export JOBS_IN_FLIGHT=1
      run bash ${../reconcile.sh} "$state" org.nixos.forgejo-runner /nix/store/bbb-generation
      assert_success
      run cat "$calls"
      refute_output --partial launchctl
    '';
    "the idle check runs on a timer, not at load" = ''
      assert_equal ${
        json [
          reconcileDaemon.StartInterval
          reconcileDaemon.RunAtLoad
        ]
      } '[300,null]'
    '';
  };
}
