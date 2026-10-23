{
  lib,
  makeTest,
  darwin,
}:
let
  inherit (darwin) json text;
  s = darwin.eval [
    {
      launchd.logging = {
        enable = true;
        excludeDaemons = [ "excluded" ];
      };
      launchd.daemons = {
        foo.command = "foo";
        bar = {
          command = "bar";
          serviceConfig.UserName = "_bar";
          serviceConfig.GroupName = "_bar";
        };
        moduledefault = {
          command = "moduledefault";
          serviceConfig.StandardOutPath = lib.mkOverride 1100 "/var/log/moduledefault/out.log";
          serviceConfig.StandardErrorPath = lib.mkOverride 1100 "/var/log/moduledefault/err.log";
        };
        pinned = {
          command = "pinned";
          serviceConfig.StandardOutPath = "/var/log/pinned.log";
        };
        excluded.command = "excluded";
        inetd = {
          serviceConfig.ProgramArguments = [ "/usr/bin/true" ];
          serviceConfig.inetdCompatibility.Wait = false;
        };
      };
      launchd.user.agents = {
        baz.command = "baz";
        qux = {
          command = "qux";
          logging.owner = "other-user";
          logging.group = "other-group";
        };
      };
    }
  ];
  managed = darwin.eval [
    {
      launchd.logging.enable = true;
      users.knownUsers = [ "alice" ];
      users.users.alice = {
        uid = 42100;
        gid = 4242;
      };
      launchd.user.agents = {
        baz.command = "baz";
        qux = {
          command = "qux";
          logging.group = "other-group";
        };
      };
    }
  ];
  shared = darwin.eval [
    {
      launchd.logging.enable = true;
      launchd.daemons = {
        a = {
          command = "a";
          serviceConfig.StandardOutPath = "/var/log/launchd/shared.log";
        };
        b = {
          command = "b";
          serviceConfig.UserName = "_b";
          serviceConfig.StandardOutPath = "/var/log/launchd/shared.log";
        };
      };
    }
  ];
  disabled = darwin.eval [ { launchd.daemons.foo.command = "foo"; } ];

  paths =
    job:
    json [
      job.serviceConfig.StandardOutPath
      job.serviceConfig.StandardErrorPath
    ];
  activation = s: text "activation" s.config.system.activationScripts.script.text;
  newsyslog = s: text "newsyslog" s.config.environment.etc."newsyslog.d/launchd-logging.conf".text;
in
makeTest {
  name = "launchd-logging";
  helpers = [
    ''
      # rotated <file> <log> <owner:group>: <file> rotates <log> as its owner.
      rotated() {
        grep -qxF "$(printf '%s\t%s\t644\t5\t1024\t*\tJN' "$2" "$3")" "$1" || fail "$2 is not rotated as $3"
      }
    ''
  ];
  tests = {
    "the fixtures pass every assertion" = ''
      assert_equal ${json (s.failedAssertions ++ managed.failedAssertions)} '[]'
    '';
    "a daemon logs to <directory>/<Label>.log, over a module's fallback" = ''
      assert_equal ${paths (s.daemon "foo")} '["/var/log/launchd/org.nixos.foo.log","/var/log/launchd/org.nixos.foo.log"]'
      assert_equal ${paths (s.daemon "bar")} '["/var/log/launchd/org.nixos.bar.log","/var/log/launchd/org.nixos.bar.log"]'
      assert_equal ${paths (s.daemon "moduledefault")} '["/var/log/launchd/org.nixos.moduledefault.log","/var/log/launchd/org.nixos.moduledefault.log"]'
    '';
    "a path set at normal priority wins" = ''
      assert_equal ${paths (s.daemon "pinned")} '["/var/log/pinned.log","/var/log/launchd/org.nixos.pinned.log"]'
    '';
    "excluded and inetd daemons are left alone" = ''
      assert_equal ${paths (s.daemon "excluded")} '[null,null]'
      assert_equal ${paths (s.daemon "inetd")} '[null,null]'
    '';
    "a user agent logs to <directory>/<Label>.log" = ''
      assert_equal ${paths (s.agent "baz")} '["/var/log/launchd/org.nixos.baz.log","/var/log/launchd/org.nixos.baz.log"]'
    '';
    "disabled, nothing is claimed" = ''
      assert_equal ${paths (disabled.daemon "foo")} '[null,null]'
    '';
    "log files are created with their owners, after users and before any plist is loaded" = ''
      run cat ${activation s}
      assert_output --partial 'install -d -m 0755 -o root -g wheel /var/log/launchd'
      assert_output --partial 'chown root:wheel /var/log/launchd/org.nixos.foo.log'
      assert_output --partial 'chown _bar:_bar /var/log/launchd/org.nixos.bar.log'
      assert_output --partial 'chown alice:staff /var/log/launchd/org.nixos.baz.log'
      assert_output --partial 'chown other-user:other-group /var/log/launchd/org.nixos.qux.log'
      refute_output --partial /var/log/pinned.log
      created="$(grep -n 'chown root:wheel /var/log/launchd/org.nixos.foo.log' <<<"$output" | head -1 | cut -d: -f1)"
      loaded="$(grep -n 'launchctl load' <<<"$output" | head -1 | cut -d: -f1)"
      users="$(grep -n 'setting up users' <<<"$output" | head -1 | cut -d: -f1)"
      [ "$created" -lt "$loaded" ]
      [ -z "$users" ] || [ "$users" -lt "$created" ]
    '';
    "a log file that can't be created stops activation" = ''
      run bash -c "$(awk '/^launchdLoggingFailed=0/ { p = 1 } p { print } /aborting/ { a = 1 } a && /^fi$/ { exit }' ${text "launchd" s.config.system.activationScripts.launchd.text} | sed 's|/usr/sbin/chown|false|; s|/usr/bin/touch|true|')"
      assert_failure
      assert_output --partial 'could not create /var/log/launchd/org.nixos.foo.log owned by root:wheel'
      assert_output --partial 'aborting before loading launchd jobs'
    '';
    "log files are rotated as their owners" = ''
      rotated ${newsyslog s} /var/log/launchd/org.nixos.foo.log root:wheel
      rotated ${newsyslog s} /var/log/launchd/org.nixos.bar.log _bar:_bar
      rotated ${newsyslog s} /var/log/launchd/org.nixos.baz.log alice:staff
      rotated ${newsyslog s} /var/log/launchd/org.nixos.qux.log other-user:other-group
      run grep -E '/var/log/pinned.log|excluded|inetd' ${newsyslog s}
      assert_failure
    '';
    "an agent's group is a managed primary user's gid, unless it says otherwise" = ''
      rotated ${newsyslog managed} /var/log/launchd/org.nixos.baz.log alice:4242
      rotated ${newsyslog managed} /var/log/launchd/org.nixos.qux.log alice:other-group
    '';
    "a log file written by jobs with different owners is rejected" = ''
      run echo ${json shared.failedAssertions}
      assert_output --partial '/var/log/launchd/shared.log is written by jobs with different owners'
    '';
  };
}
