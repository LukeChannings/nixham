_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    escapeShellArg
    escapeShellArgs
    getExe
    mkEnableOption
    mkIf
    mkOption
    mkOverride
    mkPackageOption
    optionalString
    types
    ;

  cfg = config.services.alloy;
  log = "${cfg.stateDir}/alloy.log";
in
{
  options.services.alloy = {
    enable = mkEnableOption "Grafana Alloy";

    package = mkPackageOption pkgs "grafana-alloy" { };

    configPath = mkOption {
      type = types.path;
      default = "/etc/alloy";
      description = ''
        Alloy's configuration: a file, or a directory of `*.alloy` files. By
        default, configure it with `environment.etc."alloy/config.alloy"`.

        Component names must be unique across the files. Alloy keeps
        running when a reload fails, in its last valid state.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/private/var/lib/alloy";
      description = "Directory Alloy keeps its state in.";
    };

    environmentFile = mkOption {
      type = with types; nullOr path;
      default = null;
      example = "/run/secrets/alloy.env";
      description = "File of KEY=VALUE pairs sourced before Alloy starts.";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--server.http.listen-addr=127.0.0.1:12346"
        "--disable-reporting"
      ];
      description = "Extra flags of [`alloy run`](https://grafana.com/docs/alloy/latest/reference/cli/run/).";
    };
  };

  config = mkIf cfg.enable {
    ids.uids._alloy = 536;
    ids.gids._alloy = 536;

    users.users._alloy = {
      uid = config.ids.uids._alloy;
      gid = config.ids.gids._alloy;
      home = cfg.stateDir;
      createHome = true;
      shell = "/usr/bin/false";
      description = "System user for Grafana Alloy";
    };
    users.groups._alloy = {
      gid = config.ids.gids._alloy;
      description = "System group for Grafana Alloy";
    };
    users.knownGroups = [ "_alloy" ];
    users.knownUsers = [ "_alloy" ];

    launchd.daemons.alloy = {
      script = ''
        ${optionalString (cfg.environmentFile != null) ''
          set -a
          source ${escapeShellArg cfg.environmentFile}
          set +a
        ''}
        exec ${
          escapeShellArgs (
            [
              (getExe cfg.package)
              "run"
              (toString cfg.configPath)
            ]
            ++ cfg.extraFlags
          )
        }
      '';
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        StandardErrorPath = mkOverride 1100 log;
        StandardOutPath = mkOverride 1100 log;
        GroupName = "_alloy";
        UserName = "_alloy";
        WorkingDirectory = cfg.stateDir;
      };
    };
  };
}
