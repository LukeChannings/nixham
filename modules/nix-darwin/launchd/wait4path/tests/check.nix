{
  lib,
  makeTest,
  darwin,
}:
let
  inherit (darwin) esc json;
  fake =
    name:
    derivation {
      inherit name;
      system = "aarch64-darwin";
      builder = "/bin/false";
    };
  program = "${fake "program"}/bin/program";

  s = darwin.eval [
    {
      launchd.daemons.with-secrets = {
        command = "foo";
        waitForPaths = [
          "./ready a"
          "./ready b"
        ];
      };
      launchd.daemons.plain.command = "foo";
      launchd.user.agents.with-secrets = {
        script = "bar";
        waitForPaths = [ "/run/secrets/bar" ];
      };
    }
  ];
  args = name: (s.daemon name).serviceConfig.ProgramArguments;

  failed = daemon: (darwin.eval [ { launchd.daemons.probe = daemon; } ]).failedAssertions;

  upstream = darwin.eval [
    {
      services.eternal-terminal.enable = true;
      services.karabiner-elements = {
        enable = true;
        package = fake "karabiner-elements" // {
          driver = fake "karabiner-driver";
        };
      };
      networking.wg-quick.interfaces = {
        wg0.privateKeyFile = "/run/secrets/wg0";
        wg1 = {
          privateKeyFile = "/run/secrets/wg1";
          autostart = false;
        };
      };
    }
  ];
in
makeTest {
  name = "launchd-wait4path";
  tests = {
    "a daemon waits for the store, then polls for each path" = ''
      assert_equal ${json (args "with-secrets")} ${
        json [
          "/bin/sh"
          "-c"
          "/bin/wait4path /nix/store && until [ -e './ready a' ]; do /bin/sleep 1; done && until [ -e './ready b' ]; do /bin/sleep 1; done && exec foo"
        ]
      }
    '';
    "without paths, the job starts as nix-darwin starts it" = ''
      assert_equal ${json (args "plain")} '["/bin/sh","-c","/bin/wait4path /nix/store && exec foo"]'
    '';
    "an agent's script waits for its paths" = ''
      run echo ${esc (lib.last (s.agent "with-secrets").serviceConfig.ProgramArguments)}
      assert_output --regexp '^/bin/wait4path /nix/store && until \[ -e /run/secrets/bar \]; do /bin/sleep 1; done && exec /nix/store/[^ ]*-with-secrets-start$'
    '';
    "the entrypoint wakes for paths created without a mount" = ''
      entry=${esc (lib.last (args "with-secrets"))}
      entry="''${entry#/bin/wait4path /nix/store && }"
      entry="''${entry//\/bin\/sleep/sleep}"
      entry="''${entry%exec foo}touch started"
      cd "$BATS_TEST_TMPDIR"
      sh -c "$entry" &
      sleep 1
      [ ! -e started ]
      touch 'ready a'
      sleep 1.5
      [ ! -e started ]
      touch 'ready b'
      for _ in $(seq 30); do [ -e started ] && break; sleep 0.1; done
      [ -e started ]
    '';
    "a daemon executing a store path is rejected" = ''
      run echo ${
        json (failed {
          serviceConfig.Program = program;
        })
      }
      assert_output --partial "launchd.daemons.probe: the job's executable is the Nix store path"
      run echo ${
        json (failed {
          serviceConfig.ProgramArguments = [
            program
            "--flag"
          ];
        })
      }
      assert_output --partial "launchd.daemons.probe: the job's executable is the Nix store path"
    '';
    "waitForPaths without command or script is rejected" = ''
      run echo ${
        json (failed {
          serviceConfig.ProgramArguments = [ "/usr/bin/true" ];
          waitForPaths = [ "/run/secrets/x" ];
        })
      }
      assert_output --partial 'launchd.daemons.probe.waitForPaths only takes effect with'
    '';
    "an opted-out store path, or a program off the store, is accepted" = ''
      assert_equal ${
        json (
          failed {
            serviceConfig.Program = program;
            allowBareStorePathProgram = true;
          }
          ++ failed { serviceConfig.ProgramArguments = [ "/usr/bin/true" ]; }
        )
      } '[]'
    '';
    "nix-darwin's own store-path daemons are opted out" = ''
      assert_equal ${json upstream.failedAssertions} '[]'
      assert_equal ${json (upstream.config.launchd.daemons ? wg-quick-wg1)} false
    '';
  };
}
