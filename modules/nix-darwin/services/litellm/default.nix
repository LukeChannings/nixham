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
    literalExpression
    mkBefore
    mkOption
    mkEnableOption
    mkPackageOption
    mkIf
    optional
    optionalString
    types
    ;

  cfg = config.services.litellm;
  settingsFormat = pkgs.formats.yaml { };
  configFile = settingsFormat.generate "litellm-config.yaml" cfg.settings;

  redisDir = "${cfg.stateDir}/redis";

  # No TCP listener: the 0700 socket directory is the only access control.
  redisConfig = pkgs.writeText "litellm-redis.conf" ''
    port 0
    unixsocket "${cfg.redis.unixSocket}"
    unixsocketperm 700
    dir "${redisDir}"
    save ""
    appendonly no
  '';

  redisStartScript = pkgs.writeShellScript "litellm-redis-start" ''
    set -eu
    umask 077
    mkdir -p ${escapeShellArg redisDir}
    chmod 700 ${escapeShellArg redisDir}
    exec ${lib.getExe' cfg.redis.package "redis-server"} ${redisConfig}
  '';

  tiktokenEncodings = {
    cl100k_base = {
      url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
      hash = "sha256-Ijkht27pm96ZW3/3OFE+7xAPtR0YyTWXoRO8/+hlsqc=";
    };
  };

  tiktokenCacheEntries = lib.mapAttrsToList (
    _: encoding:
    let
      cacheKey = builtins.hashString "sha1" encoding.url;
      sourceFile = pkgs.fetchurl {
        inherit (encoding) url hash;
      };
    in
    {
      inherit cacheKey sourceFile;
    }
  ) tiktokenEncodings;
in
{
  options.services.litellm = {
    enable = mkEnableOption "LiteLLM server";

    package = mkPackageOption pkgs "litellm" { };

    stateDir = mkOption {
      type = types.path;
      default = "/private/var/lib/litellm";
      description = "State directory of LiteLLM.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        The host address which the LiteLLM server HTTP interface listens to.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      example = 11111;
      description = ''
        Which port the LiteLLM server listens to.
      '';
    };

    settings = mkOption {
      type = types.submodule {
        freeformType = settingsFormat.type;
        options = {
          model_list = mkOption {
            inherit (settingsFormat) type;
            default = [ ];
            description = ''
              List of supported models on the server, with model-specific configs.
            '';
          };

          router_settings = mkOption {
            inherit (settingsFormat) type;
            default = { };
            description = ''
              LiteLLM Router settings.
            '';
          };

          litellm_settings = mkOption {
            inherit (settingsFormat) type;
            default = { };
            description = ''
              LiteLLM Module settings.
            '';
          };

          general_settings = mkOption {
            inherit (settingsFormat) type;
            default = { };
            description = ''
              LiteLLM Server settings.
            '';
          };

          environment_variables = mkOption {
            inherit (settingsFormat) type;
            default = { };
            description = ''
              Environment variables to pass to the LiteLLM process.
            '';
          };
        };
      };
      default = { };
      description = ''
        Configuration for LiteLLM.
        See <https://docs.litellm.ai/docs/proxy/configs> for more.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
      };
      example = {
        NO_DOCS = "True";
      };
      description = ''
        Extra environment variables for LiteLLM.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/var/lib/secrets/liteLLMSecrets";
      description = ''
        File of KEY=VALUE pairs sourced before LiteLLM starts.
        Useful for passing secrets to the service to prevent them from being
        world-readable in the Nix store.
      '';
    };

    redis = {
      enable = mkEnableOption ''
        a private Redis sidecar for LiteLLM (`launchd.daemons.litellm-redis`).

        Redis runs as the LiteLLM user with no TCP listener, on a unix socket
        at {option}`services.litellm.redis.unixSocket` inside a 0700
        directory, which is its only access control. Nothing is persisted
        (`save ""`). `REDIS_URL` in LiteLLM's environment points at the
        socket, and LiteLLM waits for the socket before starting; reference
        it from {option}`services.litellm.settings`, e.g.
        `litellm_settings.cache_params.url = "os.environ/REDIS_URL"`.

        This is a 1:1 sidecar, independent of {option}`services.redis`
        (a per-user agent singleton)'';

      package = mkPackageOption pkgs "redis" { };

      unixSocket = mkOption {
        type = types.str;
        readOnly = true;
        default = "${redisDir}/redis.sock";
        defaultText = literalExpression ''"''${config.services.litellm.stateDir}/redis/redis.sock"'';
        description = "Path of the Redis sidecar's unix socket.";
      };
    };
  };

  config = mkIf cfg.enable {
    launchd.daemons.litellm =
      let
        startScript = pkgs.writeShellScript "litellm-start" ''
          set -eu

          ${lib.optionalString (cfg.environmentFile != null) ''
            set -a
            source ${cfg.environmentFile}
            set +a
          ''}

          # LiteLLM would download them at every start.
          mkdir -p "$CUSTOM_TIKTOKEN_CACHE_DIR"
          ${lib.concatMapStringsSep "\n" (entry: ''
            ln -sf ${entry.sourceFile} "$CUSTOM_TIKTOKEN_CACHE_DIR/${entry.cacheKey}"
          '') tiktokenCacheEntries}

          # LiteLLM may have copied UI assets read-only in a previous run.
          mkdir -p "$LITELLM_UI_PATH"
          chmod -R u+rwX "$LITELLM_UI_PATH"

          exec ${lib.getExe cfg.package} \
            --host "${cfg.host}" \
            --port ${toString cfg.port} \
            --config ${configFile}
        '';
      in
      {
        command = "${startScript}";
        # Only for ordering: KeepAlive recovers from a stale socket.
        waitForPaths = optional cfg.redis.enable cfg.redis.unixSocket;
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive = true;
          UserName = "_litellm";
          WorkingDirectory = cfg.stateDir;
          EnvironmentVariables = {
            # LiteLLM rewrites its UI at startup; the store's is read-only.
            LITELLM_NON_ROOT = "true";
            LITELLM_UI_PATH = "${cfg.stateDir}/ui";
            CUSTOM_TIKTOKEN_CACHE_DIR = "${cfg.stateDir}/tiktoken-cache";
            HOME = cfg.stateDir;
          }
          // lib.optionalAttrs cfg.redis.enable {
            REDIS_URL = "unix://${cfg.redis.unixSocket}";
          }
          // cfg.environment;
          StandardOutPath = lib.mkOverride 1100 "/var/log/litellm/stdout.log";
          StandardErrorPath = lib.mkOverride 1100 "/var/log/litellm/stderr.log";
        };
      };

    launchd.daemons.litellm-redis = mkIf cfg.redis.enable {
      command = "${redisStartScript}";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        UserName = "_litellm";
        GroupName = "_litellm";
        WorkingDirectory = redisDir;
        StandardOutPath = lib.mkOverride 1100 "/var/log/litellm/redis.log";
        StandardErrorPath = lib.mkOverride 1100 "/var/log/litellm/redis.log";
      };
    };

    ids.uids._litellm = 4101;
    ids.gids._litellm = 4101;

    users.users._litellm = {
      uid = config.ids.uids._litellm;
      gid = config.ids.gids._litellm;
      description = "LiteLLM server";
      home = cfg.stateDir;
      createHome = true;
      shell = "/usr/bin/false";
    };
    users.groups._litellm = {
      gid = config.ids.gids._litellm;
      description = "System group for LiteLLM";
    };
    users.knownUsers = [ "_litellm" ];
    users.knownGroups = [ "_litellm" ];

    # After users, before launchd loads the daemons.
    system.activationScripts.launchd.text = mkBefore ''
      mkdir -p '${cfg.stateDir}/ui' '${cfg.stateDir}/tiktoken-cache' /var/log/litellm ${optionalString cfg.redis.enable "'${redisDir}'"}
      chown -R _litellm:_litellm '${cfg.stateDir}' /var/log/litellm
      chmod 700 '${cfg.stateDir}/ui' '${cfg.stateDir}/tiktoken-cache' ${optionalString cfg.redis.enable "'${redisDir}'"}
    '';
  };
}
