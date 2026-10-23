_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    escapeShellArgs
    makeBinPath
    mkDefault
    mkEnableOption
    mkIf
    mkOption
    mkOverride
    types
    ;

  cfg = config.services.forgejo-runner;

  configFile = (pkgs.formats.yaml { }).generate "act_runner-config.yaml" (
    {
      runner.capacity = cfg.capacity;
      log.level = "info";
      cache.enabled = false;
    }
    // cfg.settings
  );

  start = pkgs.writeShellScript "forgejo-runner-start" ''
    PATH=${
      makeBinPath [
        cfg.package
        pkgs.jq
      ]
    }:$PATH
    ${builtins.readFile ./start.sh}
  '';
in
{
  options.services.forgejo-runner = {
    enable = mkEnableOption "the Forgejo Actions runner";

    package = mkOption {
      type = types.package;
      default = pkgs.forgejo-runner;
      defaultText = lib.literalExpression "pkgs.forgejo-runner";
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
      defaultText = lib.literalExpression "config.networking.hostName";
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

    capacity = mkOption {
      type = types.int;
      default = 1;
      description = "Maximum number of concurrent jobs.";
    };

    settings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Extra keys of the runner's config.yaml.";
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

    system.activationScripts.postActivation.text = ''
      mkdir -p ${lib.escapeShellArg cfg.stateDir} /var/log/forgejo-runner
      chown forgejo-runner:forgejo-runner ${lib.escapeShellArg cfg.stateDir} /var/log/forgejo-runner 2>/dev/null || true
    '';

    launchd.daemons.forgejo-runner = {
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        cfg.package
      ];
      environment.HOME = cfg.stateDir;
      command = "${start} ${
        escapeShellArgs [
          cfg.stateDir
          cfg.url
          "${cfg.secretFile}"
          cfg.name
          (builtins.toJSON cfg.labels)
          "${configFile}"
        ]
      }";
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        ThrottleInterval = 30;
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
    };
  };
}
