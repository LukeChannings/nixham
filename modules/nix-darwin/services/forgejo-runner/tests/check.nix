{
  lib,
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
      };
    }
  ];
  daemon = (s.daemon "forgejo-runner").serviceConfig;
in
makeTest {
  name = "forgejo-runner";
  inputs = [ jq ];
  setup = ''
    stub ${./stubs}
    export calls="$BATS_TEST_TMPDIR/calls"
    printf 'secret\n' >"$BATS_TEST_TMPDIR/secret"
  '';
  tests = {
    "the fixture passes every assertion" = ''
      assert_equal ${json s.failedAssertions} '[]'
    '';
    "the runner registers itself, then runs, as forgejo-runner" = ''
      run echo ${esc (lib.last daemon.ProgramArguments)}
      assert_output --regexp "^/bin/wait4path /nix/store && exec /nix/store/[^ ]*-forgejo-runner-start /private/var/lib/forgejo-runner https://forge.example.com /run/secrets/runner mac '\[\"macos-arm64:host\"\]' /nix/store/[^ ]*-act_runner-config.yaml$"
      assert_equal ${
        json [
          daemon.UserName
          daemon.GroupName
          daemon.KeepAlive
          s.config.users.users.forgejo-runner.uid
        ]
      } '["forgejo-runner","forgejo-runner",true,4099]'
    '';
    "the runner file is recreated with the labels, before the daemon starts" = ''
      run bash ${../start.sh} "$BATS_TEST_TMPDIR/state" https://forge.example.com "$BATS_TEST_TMPDIR/secret" mac '["macos-arm64:host"]' /config.yaml
      assert_success
      assert_equal "$(cat "$calls")" "$(printf '%s\n' 'act_runner create-runner-file --instance https://forge.example.com --secret secret --name mac' 'act_runner daemon --config /config.yaml')"
      assert_equal "$(jq -c .labels "$BATS_TEST_TMPDIR/state/.runner")" '["macos-arm64:host"]'
    '';
  };
}
