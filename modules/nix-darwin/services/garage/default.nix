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
    mkEnableOption
    mkIf
    mkOption
    mkOverride
    optionalString
    types
    ;

  cfg = config.services.garage;
  toml = pkgs.formats.toml { };

  start = pkgs.writeShellScript "garage-start" ''
    ${optionalString (cfg.environmentFile != null) ''
      set -a
      source ${escapeShellArg cfg.environmentFile}
      set +a
    ''}
    exec ${cfg.package}/bin/garage server
  '';
in
{
  options.services.garage = {
    enable = mkEnableOption "Garage, the S3-compatible object store";

    package = mkOption {
      type = types.package;
      description = "The Garage package. Set explicitly: check the release notes before a major upgrade.";
    };

    logLevel = mkOption {
      type = types.enum [
        "error"
        "warn"
        "info"
        "debug"
        "trace"
      ];
      default = "info";
      description = "Log level, as `RUST_LOG=garage=<level>`.";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        RUST_BACKTRACE = "yes";
      };
      description = "Extra environment variables for Garage.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File of KEY=VALUE pairs sourced before Garage starts.";
    };

    settings = mkOption {
      type = types.submodule {
        freeformType = toml.type;
        options = {
          metadata_dir = mkOption {
            type = types.path;
            default = "/private/var/lib/garage/meta";
            description = "Metadata directory. Put it on a fast disk if possible.";
          };
          data_dir = mkOption {
            type = with types; either path (listOf attrs);
            default = "/private/var/lib/garage/data";
            description = "Data directory, or a list of `{ path, capacity }`.";
          };
        };
      };
      description = "Garage's configuration: <https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/>.";
    };
  };

  config = mkIf cfg.enable {
    environment.etc."garage.toml".source = toml.generate "garage.toml" cfg.settings;

    launchd.daemons.garage = {
      command = "${start}";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        UserName = "_garage";
        EnvironmentVariables = {
          RUST_LOG = "garage=${cfg.logLevel}";
          GARAGE_CONFIG_FILE = "/etc/garage.toml";
        }
        // cfg.extraEnvironment;
        StandardOutPath = mkOverride 1100 "/var/log/garage/stdout.log";
        StandardErrorPath = mkOverride 1100 "/var/log/garage/stderr.log";
      };
    };

    ids.uids._garage = 4098;
    ids.gids._garage = 4098;

    users.users._garage = {
      uid = config.ids.uids._garage;
      gid = config.ids.gids._garage;
      description = "Garage object store";
      home = "/private/var/lib/garage";
      createHome = true;
      shell = "/usr/bin/false";
    };
    users.groups._garage = {
      gid = config.ids.gids._garage;
      description = "System group for Garage";
    };
    users.knownUsers = [ "_garage" ];
    users.knownGroups = [ "_garage" ];

    system.activationScripts.postActivation.text = ''
      mkdir -p /private/var/lib/garage/meta /private/var/lib/garage/data /var/log/garage
      chown -R _garage:_garage /private/var/lib/garage /var/log/garage
    '';
  };
}
