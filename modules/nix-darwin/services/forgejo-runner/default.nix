_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    escapeShellArg
    escapeShellArgs
    hasInfix
    isDerivation
    literalExpression
    mapAttrsToList
    mkDefault
    mkEnableOption
    mkIf
    mkOption
    mkOverride
    optionalAttrs
    types
    ;

  cfg = config.services.forgejo-runner;
  yaml = pkgs.formats.yaml { };

  label = config.launchd.daemons.forgejo-runner.serviceConfig.Label;
  plist = config.environment.launchDaemons."${label}.plist".text;

  # On the root volume, so launchd can spawn it before /nix is mounted, and at
  # a fixed path, so the plist naming it is generation-stable.
  launcher = "/usr/local/libexec/nix-darwin/forgejo-runner-launch";

  configFile = yaml.generate "act_runner-config.yaml" cfg.settings;

  # The generation-specific half of the daemon, reached through
  # /run/current-system/sw/bin so that switching generations does not touch the
  # plist. Its own store path is the runner's generation identity, which
  # start.sh records and reconcile.sh compares against.
  start = pkgs.writeShellScriptBin "forgejo-runner-start" ''
    export PATH=${cfg.path}:$PATH
    ${concatStringsSep "\n" (
      mapAttrsToList (name: value: "export ${name}=${escapeShellArg value}") cfg.environment
    )}
    set -- ${
      escapeShellArgs [
        cfg.stateDir
        cfg.url
        "${cfg.secretFile}"
        cfg.name
        (builtins.toJSON cfg.labels)
        "${configFile}"
      ]
    } ${builtins.placeholder "out"}
    ${builtins.readFile ./start.sh}
  '';

  reconcile = pkgs.writeShellScript "forgejo-runner-reconcile" ''
    set -- ${
      escapeShellArgs [
        cfg.stateDir
        label
      ]
    } ${start}
    ${builtins.readFile ./reconcile.sh}
  '';
in
{
  options.services.forgejo-runner = {
    enable = mkEnableOption "the Forgejo Actions runner";

    package = mkOption {
      type = types.package;
      default = pkgs.forgejo-runner;
      defaultText = literalExpression "pkgs.forgejo-runner";
      description = "The forgejo-runner package.";
    };

    url = mkOption {
      type = types.str;
      example = "https://forge.example.com";
      description = "URL of the Forgejo instance.";
    };

    name = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = literalExpression "config.networking.hostName";
      description = "Name the runner registers as.";
    };

    secretFile = mkOption {
      type = types.path;
      description = "File holding the runner's shared secret, for `act_runner create-runner-file --secret`.";
    };

    labels = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "macos-arm64:host" ];
      description = "Labels the runner advertises to Forgejo, which routes jobs by them.";
    };

    settings = mkOption {
      type = types.submodule {
        freeformType = yaml.type;
        options = {
          runner = mkOption {
            type = types.submodule {
              freeformType = yaml.type;
              options = {
                capacity = mkOption {
                  type = types.ints.positive;
                  default = 1;
                  description = "Maximum number of concurrent jobs.";
                };

                shutdown_timeout = mkOption {
                  type = types.str;
                  default = "${toString cfg.drainTimeout}s";
                  defaultText = literalExpression ''"''${toString config.services.forgejo-runner.drainTimeout}s"'';
                  description = "How long a stopping runner finishes its claimed jobs for. Set {option}`drainTimeout` instead: launchd's patience is derived from it.";
                };
              };
            };
            default = { };
            description = "The config.yaml `runner` section.";
          };

          log.level = mkOption {
            type = types.str;
            default = "info";
            description = "The runner's log level.";
          };

          cache.enabled = mkOption {
            type = types.bool;
            default = false;
            description = "Whether the runner serves actions/cache from its own cache server.";
          };
        };
      };
      default = { };
      description = "The runner's config.yaml: <https://forgejo.org/docs/latest/admin/actions/#configuration>.";
    };

    path = mkOption {
      type = types.listOf (types.either types.path types.str);
      default = [ ];
      example = literalExpression "lib.mkAfter [ pkgs.git ]";
      apply = concatMapStringsSep ":" (p: if isDerivation p then "${p}/bin" else p);
      description = ''
        Packages added to the runner's {env}`PATH`, after the module's own and
        before launchd's. A `:host` runner executes jobs with no container, so
        this is the environment every step on this host starts from.

        Deliberately not {option}`launchd.daemons.forgejo-runner.path`: that
        lands in the plist, and the plist must stay generation-stable.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        GIT_CONFIG_SYSTEM = "/etc/gitconfig";
      };
      description = ''
        Environment variables exported to the runner, and so to the jobs it
        executes.

        Deliberately not {option}`launchd.daemons.forgejo-runner.environment`:
        that lands in the plist, and the plist must stay generation-stable.
      '';
    };

    drainTimeout = mkOption {
      type = types.ints.positive;
      default = 600;
      description = ''
        Seconds a stopping runner is given to finish the jobs it has claimed
        before it cancels them.

        It bounds the race the idle check cannot see: a task CLAIMED but not
        yet spawned has no process, so it reads as idle. At zero -- act_runner's
        own default -- a restart landing in that window kills the job with
        "context canceled". Drives both `runner.shutdown_timeout` and launchd's
        `ExitTimeOut`, which gets a further minute before it SIGKILLs.
      '';
    };

    reconcile = {
      enable = mkEnableOption "rolling the runner onto the current generation once it is idle" // {
        default = true;
      };

      interval = mkOption {
        type = types.ints.positive;
        default = 300;
        description = "Seconds between idle checks.";
      };
    };

    stateDir = mkOption {
      type = types.str;
      default = "/private/var/lib/forgejo-runner";
      description = "Directory the runner keeps its state, e.g. its .runner file, in.";
    };
  };

  config = mkIf cfg.enable {
    users.users.forgejo-runner = {
      uid = mkDefault 4099;
      gid = mkDefault 4099;
      home = cfg.stateDir;
      shell = "/bin/bash";
      description = "Forgejo Actions runner";
    };
    users.groups.forgejo-runner = {
      gid = mkDefault 4099;
      description = "Forgejo Actions runner";
    };
    users.knownUsers = [ "forgejo-runner" ];
    users.knownGroups = [ "forgejo-runner" ];

    services.forgejo-runner = {
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        cfg.package
      ];
      environment.HOME = mkDefault cfg.stateDir;
    };

    environment.systemPackages = [ start ];

    # A rollout must never kill its own executor. nix-darwin reloads a daemon
    # exactly when its plist differs, so every store path the plist used to
    # carry -- the start script, the rendered config, PATH -- cancelled the
    # jobs this runner was executing on each deploy that changed one of them,
    # the deploy's own job included.
    assertions = [
      {
        assertion = !hasInfix builtins.storeDir plist;
        message = ''
          launchd.daemons.forgejo-runner's plist carries a Nix store path, so
          nix-darwin will reload the runner -- cancelling every job it is
          running -- on any deploy that changes it. Move whatever added it to
          services.forgejo-runner.path or .environment, which reach the daemon
          through /run/current-system instead.
        '';
      }
    ];

    system.activationScripts.preActivation.text = ''
      /usr/bin/install -d -m 0755 ${dirOf launcher}
      /usr/bin/install -m 0755 ${./launch.sh} ${launcher}
    '';

    system.activationScripts.postActivation.text = ''
      mkdir -p ${escapeShellArg cfg.stateDir} /var/log/forgejo-runner
      chown forgejo-runner:forgejo-runner ${escapeShellArg cfg.stateDir} /var/log/forgejo-runner 2>/dev/null || true
    '';

    launchd.daemons = {
      forgejo-runner.serviceConfig = {
        Program = launcher;
        KeepAlive = true;
        RunAtLoad = true;
        ThrottleInterval = 30;
        ExitTimeOut = cfg.drainTimeout + 60;
        StandardOutPath = mkOverride 1100 "/var/log/forgejo-runner/runner.log";
        StandardErrorPath = mkOverride 1100 "/var/log/forgejo-runner/runner-error.log";
        UserName = "forgejo-runner";
        GroupName = "forgejo-runner";
        WorkingDirectory = cfg.stateDir;
        WatchPaths = [
          "/etc/resolv.conf"
          "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
        ];
      };
    }
    // optionalAttrs cfg.reconcile.enable {
      forgejo-runner-reconcile = {
        command = "${reconcile}";
        serviceConfig = {
          StartInterval = cfg.reconcile.interval;
          StandardOutPath = mkOverride 1100 "/var/log/forgejo-runner/reconcile.log";
          StandardErrorPath = mkOverride 1100 "/var/log/forgejo-runner/reconcile.log";
        };
      };
    };
  };
}
