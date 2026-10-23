{
  lib,
  makeTest,
  darwin,
}:
let
  inherit (darwin) esc json text;
  ollama = extra: {
    services.ollama = {
      enable = true;
      host = "[::]";
      port = 11111;
      environmentVariables.OLLAMA_KEEP_ALIVE = "24h";
      loadModels = [
        "model-a"
        "flaky"
        ""
      ];
    }
    // extra;
  };
  s = darwin.eval [
    (ollama { })
    { launchd.logging.enable = true; }
  ];
  external = darwin.eval [
    (ollama {
      user = "_litellm";
      home = "/private/var/lib/litellm/ollama";
    })
  ];
  noFunnel = darwin.eval [ (ollama { }) ];
  renamed = darwin.eval [ (ollama { models = "/srv/models"; }) ];
  daemon = s: (s.daemon "ollama").serviceConfig;
  activation = s: text "activation" s.config.system.activationScripts.script.text;
in
makeTest {
  name = "ollama";
  helpers = [
    ''
      # serve [<model>...]: the script, in the background, against the stub.
      serve() {
        ollama='ollama' bash ${../start.sh} "$@" >"$FAKE_STATE/log" 2>&1 3>&- &
        pid=$!
      }
    ''
  ];
  setup = ''
    stub ${./stubs}
    export FAKE_STATE="$BATS_TEST_TMPDIR"
  '';
  teardown = ''
    kill -TERM "$pid" 2>/dev/null || true
  '';
  tests = {
    "the fixtures pass every assertion" = ''
      assert_equal ${json (s.failedAssertions ++ external.failedAssertions)} '[]'
    '';
    "ollama serves as _ollama, and is told what to load" = ''
      run echo ${esc (lib.last (daemon s).ProgramArguments)}
      assert_output --regexp '^/bin/wait4path /nix/store && exec /nix/store/[^ ]*-ollama-start model-a flaky$'
      assert_equal ${
        json (
          lib.attrVals [
            "UserName"
            "GroupName"
            "WorkingDirectory"
            "EnvironmentVariables"
            "StandardErrorPath"
          ] (daemon s)
        )
      } '["_ollama","_ollama","/private/var/lib/ollama",{"HOME":"/private/var/lib/ollama","OLLAMA_HOST":"[::]:11111","OLLAMA_KEEP_ALIVE":"24h","OLLAMA_MODELS":"/private/var/lib/ollama/models"},"/var/log/launchd/org.nixos.ollama.log"]'
    '';
    "its directories are _ollama's before launchd loads it" = ''
      run cat ${activation s}
      assert_output --partial 'chown _ollama:_ollama /private/var/lib/ollama /private/var/lib/ollama/models'
      assert_output --partial 'chown _ollama:_ollama /var/log/launchd/org.nixos.ollama.log'
      refute_output --partial /var/log/ollama
      created="$(grep -n 'chown _ollama:_ollama /private/var/lib/ollama' <<<"$output" | head -1 | cut -d: -f1)"
      loaded="$(grep -n 'launchctl load' <<<"$output" | head -1 | cut -d: -f1)"
      [ "$created" -lt "$loaded" ]
      assert_equal ${json s.config.users.users._ollama.uid} 4102
    '';
    "another user is used, not created" = ''
      assert_equal ${
        json [
          (daemon external).UserName
          (daemon external).GroupName
          (daemon external).EnvironmentVariables.OLLAMA_MODELS
          (external.config.users.users ? _ollama)
          (lib.elem "_ollama" external.config.users.knownUsers)
        ]
      } '["_litellm","_litellm","/private/var/lib/litellm/ollama/models",false,false]'
      run cat ${activation external}
      assert_output --partial 'chown _litellm:_litellm /private/var/lib/litellm/ollama /private/var/lib/litellm/ollama/models'
    '';
    "without the log funnel, ollama logs to /var/log/ollama, which is the user's" = ''
      assert_equal ${esc (daemon noFunnel).StandardErrorPath} /var/log/ollama/ollama.log
      run cat ${activation noFunnel}
      assert_output --partial 'chown _ollama:_ollama /var/log/ollama'
    '';
    "models is modelsDir's old name" = ''
      assert_equal ${esc (daemon renamed).EnvironmentVariables.OLLAMA_MODELS} /srv/models
    '';
    "without models, the server is all there is" = ''
      ollama='echo' run bash ${../start.sh}
      assert_output serve
    '';
    "models are pulled once the server answers, failures retried, while it serves" = ''
      serve model-a flaky
      for _ in $(seq 100); do
        [ "$(wc -l <"$FAKE_STATE/pulled" 2>/dev/null)" -ge 2 ] && break
        sleep 0.1
      done
      assert_equal "$(sort "$FAKE_STATE/pulled" | tr '\n' ' ')" "flaky model-a "
      [ ! -e "$FAKE_STATE/errors" ] && [ -e "$FAKE_STATE/flaky-tried" ]
      kill -0 "$pid"
      [ ! -e "$FAKE_STATE/stopped" ]
    '';
    "SIGTERM stops the server, whose status is the script's" = ''
      serve model-a
      for _ in $(seq 100); do
        [ -e "$FAKE_STATE/pulled" ] && break
        sleep 0.1
      done
      kill -TERM "$pid"
      code=0
      wait "$pid" || code=$?
      assert_equal "$code" 3
      [ -e "$FAKE_STATE/stopped" ]
    '';
  };
}
