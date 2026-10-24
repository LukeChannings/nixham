{
  callPackage,
  bashInteractive,
  fish,
  zsh,
  symlinkJoin,
  writeShellScriptBin,
  launchctl-completions,
}:
let
  makeTest = callPackage ../../../lib/testing/make-test.nix { };
  share = "${launchctl-completions}/share";
  stubs = symlinkJoin {
    name = "launchctl-completions-stubs";
    paths = [
      (writeShellScriptBin "launchctl" ''
        emit_domain() {
          printf '%s = {\n\ttype = stub\n\tservices = {\n' "$1"
          shift
          for s in "$@"; do
            printf '\t\t       0      -\t%s\n' "$s"
          done
          printf '\t}\n}\n'
        }
        case "$1" in
          print)
            case "''${2%/}" in
              system) emit_domain system com.stub.system-daemon com.example.shared ;;
              gui/501) emit_domain gui/501 com.stub.gui-agent com.example.shared ;;
              user/501) emit_domain user/501 com.stub.user-agent ;;
              pid/42) emit_domain pid/42 com.stub.xpc ;;
              session/7) emit_domain session/7 com.stub.session ;;
              user/777)
                if [ -n "$LAUNCHCTL_PRIVILEGED" ]; then
                  emit_domain user/777 com.stub.secret
                else
                  echo "Could not find domain for user/777" >&2
                  exit 9
                fi
                ;;
              *) exit 9 ;;
            esac
            ;;
          list)
            printf 'PID\tStatus\tLabel\n'
            printf -- '-\t0\tcom.stub.legacy-job\n'
            printf '123\t0\tcom.stub.other-job\n'
            ;;
          *) exit 64 ;;
        esac
      '')
      (writeShellScriptBin "sudo" ''
        [ "$1" = "-n" ] && shift
        LAUNCHCTL_PRIVILEGED=1 exec "$@"
      '')
      (writeShellScriptBin "dscl" ''
        printf 'root 0\nluke 501\ndeploy 555\n'
      '')
      (writeShellScriptBin "id" ''
        [ "$1" = "-u" ] && { echo 501; exit 0; }
        exit 1
      '')
    ];
  };
  # Hermetic fish: no config (the default config reorders PATH via
  # path_helper on darwin), and `complete -e` before sourcing to block
  # autoloading of fish's own bundled launchctl completions.
  fishComplete = line: ''
    run fish --no-config -c '
      set -gx PATH ${stubs}/bin $PATH
      complete -c launchctl -e
      source ${share}/fish/vendor_completions.d/launchctl.fish
      complete -C"${line}"'
  '';
  bashComplete = words: ''
    run bash -c '
      source ${share}/bash-completion/completions/launchctl.bash
      COMP_WORDS=(${words}); COMP_CWORD=$((''${#COMP_WORDS[@]} - 1))
      _launchctl
      printf "%s\n" "''${COMPREPLY[@]}"
    '
  '';
  # /etc/zshenv is always sourced and may reorder PATH, so prepend the
  # stubs inside the script.
  zshHelper = body: ''
    run zsh -c 'path=(${stubs}/bin $path); source ${share}/zsh/site-functions/_launchctl; ${body}'
  '';
in
makeTest {
  name = "launchctl-completions";
  inputs = [
    bashInteractive
    fish
    zsh
  ];
  setup = ''
    export PATH=${stubs}/bin:$PATH
  '';
  tests = {
    "zsh finds the completion, and it parses" = ''
      zsh -n ${share}/zsh/site-functions/_launchctl
    '';
    "fish finds the completion, and it parses" = ''
      fish --no-execute ${share}/fish/vendor_completions.d/launchctl.fish
    '';
    "bash finds the completion, and it parses" = ''
      bash -n ${share}/bash-completion/completions/launchctl.bash
    '';
    "fish completes the current subcommands" = ''
      ${fishComplete "launchctl "}
      assert_line --regexp '^attach[[:blank:]]'
      assert_line --regexp '^bootstrap[[:blank:]]'
      refute_output --partial runstats
    '';
    "fish offers domain prefixes for service targets" = ''
      ${fishComplete "launchctl print "}
      assert_line --regexp '^system/[[:blank:]]'
      assert_line --regexp '^user/501/[[:blank:]]'
      assert_line --regexp '^gui/501/[[:blank:]]'
      assert_line --regexp '^pid/[[:blank:]]'
      assert_line --regexp '^session/[[:blank:]]'
    '';
    "fish enumerates services within a domain" = ''
      ${fishComplete "launchctl print gui/501/"}
      assert_line 'gui/501/com.stub.gui-agent'
      refute_output --partial com.stub.user-agent
    '';
    "fish enumerates pid and session domains" = ''
      ${fishComplete "launchctl print pid/42/"}
      assert_line 'pid/42/com.stub.xpc'
      ${fishComplete "launchctl print session/7/"}
      assert_line 'session/7/com.stub.session'
    '';
    "fish searches labels across domains" = ''
      ${fishComplete "launchctl print com.example"}
      assert_line 'system/com.example.shared'
      assert_line 'gui/501/com.example.shared'
    '';
    "fish falls back to sudo for unreadable domains" = ''
      ${fishComplete "launchctl print user/777/"}
      assert_line 'user/777/com.stub.secret'
    '';
    "fish restricts enable to persistent domains" = ''
      ${fishComplete "launchctl enable "}
      assert_line --regexp '^system/[[:blank:]]'
      refute_output --partial pid/
      refute_output --partial session/
    '';
    "fish completes uids for asuser" = ''
      ${fishComplete "launchctl asuser "}
      assert_line --regexp '^501[[:blank:]]luke$'
      assert_line --regexp '^0[[:blank:]]root$'
    '';
    "fish completes bare labels for legacy subcommands" = ''
      ${fishComplete "launchctl list "}
      assert_line 'com.stub.legacy-job'
      assert_line 'com.stub.other-job'
    '';
    "fish completes signals then service targets for kill" = ''
      ${fishComplete "launchctl kill "}
      assert_line SIGTERM
      ${fishComplete "launchctl kill SIGTERM gui/501/"}
      assert_line 'gui/501/com.stub.gui-agent'
    '';
    "fish completes help topics" = ''
      ${fishComplete "launchctl help kick"}
      assert_line --regexp '^kickstart[[:blank:]]'
    '';
    "zsh enumerates services within a domain" = ''
      ${zshHelper "__launchctl_services_in gui/501"}
      assert_line com.stub.gui-agent
    '';
    "zsh falls back to sudo for unreadable domains" = ''
      ${zshHelper "__launchctl_services_in user/777"}
      assert_line com.stub.secret
    '';
    "zsh completes uids for asuser" = ''
      ${zshHelper "__launchctl_uids"}
      assert_line '501:luke'
    '';
    "zsh completes bare labels for legacy subcommands" = ''
      ${zshHelper "__launchctl_labels"}
      assert_line com.stub.legacy-job
    '';
    "bash completes the current subcommands" = ''
      ${bashComplete "launchctl pri"}
      assert_line print
      assert_line print-disabled
      refute_output --partial runstats
    '';
    "bash offers domain prefixes for service targets" = ''
      ${bashComplete ''launchctl print ""''}
      assert_line system/
      assert_line gui/501/
      assert_line pid/
    '';
    "bash enumerates services within a domain" = ''
      ${bashComplete "launchctl print gui/501/"}
      assert_line 'gui/501/com.stub.gui-agent'
    '';
    "bash searches labels across domains" = ''
      ${bashComplete "launchctl print com.example"}
      assert_line 'system/com.example.shared'
      assert_line 'gui/501/com.example.shared'
    '';
    "bash restricts enable to persistent domains" = ''
      ${bashComplete ''launchctl enable ""''}
      refute_output --partial pid/
    '';
    "bash completes uids for asuser" = ''
      ${bashComplete ''launchctl asuser ""''}
      assert_line 501
      assert_line 0
    '';
  };
}
