{
  lib,
  makeTest,
  darwin,
  bzip2,
}:
let
  inherit (darwin) esc json text;
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
  rotate = s: text "launchd-log-rotate" s.config.system.build.launchdLogRotate.text;
  rotateDaemon = s.daemon "launchd-log-rotate";
in
makeTest {
  name = "launchd-logging";
  inputs = [ bzip2 ];
  helpers = [
    ''
      # log <name> <kb>: a log file of <kb> kilobytes.
      log() {
        head -c $(($2 * 1024)) /dev/zero >"$DIR/$1.log"
      }

      inode() {
        stat -c %i "$1"
      }

      kept() {
        (cd "$DIR" && echo *)
      }
    ''
  ];
  setup = ''
    export DIR="$BATS_TEST_TMPDIR/logs"
    mkdir -p "$DIR"
    sed -e "s|^PATH=.*|PATH=$PATH|" -e "s|^dir=.*|dir='$DIR'|" \
      ${rotate s} >"$BATS_TEST_TMPDIR/rotate"
    chmod +x "$BATS_TEST_TMPDIR/rotate"
  '';
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
    "the rotator runs over the log directory, on the configured interval" = ''
      assert_equal ${json rotateDaemon.serviceConfig.StartInterval} 900
      assert_equal ${esc rotateDaemon.command} ${esc s.config.system.build.launchdLogRotate}
      run cat ${rotate s}
      assert_line --index 0 '#!/bin/sh'
      assert_line 'dir=/var/log/launchd'
      assert_line 'limit=$((1024 * 1024))'
      assert_line 'keep=5'
    '';
    "a log under the threshold is left alone" = ''
      log small 1023
      "$BATS_TEST_TMPDIR/rotate"
      assert_equal "$(kept)" 'small.log'
    '';
    "an oversized log is archived, and keeps the inode its daemon holds" = ''
      log big 1024
      before="$(inode "$DIR/big.log")"
      "$BATS_TEST_TMPDIR/rotate"
      assert_equal "$(kept)" 'big.log big.log.0.bz2'
      assert_equal "$(inode "$DIR/big.log")" "$before"
      assert_equal "$(wc -c <"$DIR/big.log")" 0
      assert_equal "$(bzip2 -dc "$DIR/big.log.0.bz2" | wc -c)" $((1024 * 1024))
    '';
    "an archive keeps the mode of the log it came from" = ''
      log big 1024
      chmod 600 "$DIR/big.log"
      "$BATS_TEST_TMPDIR/rotate"
      assert_equal "$(stat -c %a "$DIR/big.log.0.bz2")" 600
    '';
    "archives shift down the chain, and the oldest is dropped" = ''
      for i in 0 1 2 3 4; do echo "archive $i" | bzip2 >"$DIR/big.log.$i.bz2"; done
      log big 1024
      "$BATS_TEST_TMPDIR/rotate"
      assert_equal "$(kept)" 'big.log big.log.0.bz2 big.log.1.bz2 big.log.2.bz2 big.log.3.bz2 big.log.4.bz2'
      assert_equal "$(bzip2 -dc "$DIR/big.log.4.bz2")" 'archive 3'
      assert_equal "$(bzip2 -dc "$DIR/big.log.1.bz2")" 'archive 0'
    '';
    "an agent's group is a managed primary user's gid, unless it says otherwise" = ''
      run cat ${activation managed}
      assert_output --partial 'chown alice:4242 /var/log/launchd/org.nixos.baz.log'
      assert_output --partial 'chown alice:other-group /var/log/launchd/org.nixos.qux.log'
    '';
    "only <Label>.log is rotated" = ''
      log big 1024
      cp "$DIR/big.log" "$DIR/big.log.1"
      cp "$DIR/big.log" "$DIR/notalog"
      "$BATS_TEST_TMPDIR/rotate"
      assert_equal "$(kept)" 'big.log big.log.0.bz2 big.log.1 notalog'
    '';
    "a log file written by jobs with different owners is rejected" = ''
      run echo ${json shared.failedAssertions}
      assert_output --partial '/var/log/launchd/shared.log is written by jobs with different owners'
    '';
  };
}
