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
    literalExpression
    mkBefore
    mkEnableOption
    mkIf
    mkOption
    mkOverride
    mkPackageOption
    optionalString
    types
    ;

  cfg = config.services.ollama;
  daemon = config.launchd.daemons.ollama.serviceConfig;

  # A null user is the managed _ollama, as NixOS's DynamicUser.
  managedUser = cfg.user == null;
  user = if managedUser then "_ollama" else cfg.user;
  group = if managedUser then "_ollama" else cfg.group;
  owner = user + optionalString (group != null) ":${group}";

  fallbackLog = "/var/log/ollama/ollama.log";
  ownsFallbackLog = daemon.StandardErrorPath == fallbackLog || daemon.StandardOutPath == fallbackLog;

  start = pkgs.writeShellScript "ollama-start" ''
    ollama=${lib.getExe cfg.package}
    ${builtins.readFile ./start.sh}
  '';
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "services" "ollama" "models" ] [ "services" "ollama" "modelsDir" ])
  ];

  options.services.ollama = {
    enable = mkEnableOption "ollama server for local large language models";

    package = mkPackageOption pkgs "ollama" { };

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "_litellm";
      description = ''
        User account under which to run ollama.

        When `null`, nix-darwin creates and manages a dedicated `_ollama`
        user and group. Unlike the NixOS module, a non-null user is *not*
        created automatically (darwin accounts need a fixed uid); declare it
        yourself via {option}`users.users` or point this at an existing
        service account.
      '';
    };

    group = mkOption {
      type = types.nullOr types.str;
      default = cfg.user;
      defaultText = literalExpression "config.services.ollama.user";
      example = "_litellm";
      description = ''
        Group under which to run ollama. Only used when
        {option}`services.ollama.user` is set; `null` runs under the user's
        primary group.

        The default (a group named like the user) must exist: for a user
        whose primary group is named differently, e.g. a regular account in
        `staff`, set this to `null` or that group, or launchd cannot spawn
        the daemon.
      '';
    };

    home = mkOption {
      type = types.str;
      default = "/private/var/lib/ollama";
      example = "/private/var/lib/litellm/ollama";
      description = ''
        The home directory that the ollama service is started in. Created at
        activation and owned by the service user.
      '';
    };

    modelsDir = mkOption {
      type = types.str;
      default = "${cfg.home}/models";
      defaultText = literalExpression ''"''${config.services.ollama.home}/models"'';
      example = "/path/to/ollama/models";
      description = ''
        The directory that the ollama service will read models from and
        download new models to. Created at activation and owned by the
        service user.
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "[::]";
      description = ''
        The host address which the ollama server HTTP interface listens to.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 11434;
      example = 11111;
      description = ''
        Which port the ollama server listens to.
      '';
    };

    environmentVariables = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        OLLAMA_KEEP_ALIVE = "24h";
        OLLAMA_FLASH_ATTENTION = "1";
      };
      description = ''
        Set arbitrary environment variables for the ollama service.

        These are only seen by the ollama server (and the model loader), not
        by interactive invocations like `ollama run`.
      '';
    };

    loadModels = mkOption {
      type = types.listOf types.str;
      apply = builtins.filter (model: model != "");
      default = [ ];
      example = [
        "gemma3"
        "mxbai-embed-large"
        "deepseek-r1:1.5b"
      ];
      description = ''
        Download these models using `ollama pull` once the server is up.

        The daemon starts `ollama serve`, waits until it answers, then pulls
        each model (idempotently; already-present models are only checked
        for updates) while the server keeps serving. Failed pulls, e.g. when
        the network is not up yet at boot, are retried with exponential
        backoff capped at ten minutes.

        Search for models of your choice from: <https://ollama.com/library>
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    launchd.daemons.ollama = {
      command = escapeShellArgs ([ "${start}" ] ++ cfg.loadModels);
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        UserName = user;
        GroupName = group;
        WorkingDirectory = cfg.home;
        EnvironmentVariables = cfg.environmentVariables // {
          HOME = cfg.home;
          OLLAMA_MODELS = cfg.modelsDir;
          OLLAMA_HOST = "${cfg.host}:${toString cfg.port}";
        };
        StandardOutPath = mkOverride 1100 fallbackLog;
        StandardErrorPath = mkOverride 1100 fallbackLog;
      };
    };

    ids.uids._ollama = 4102;
    ids.gids._ollama = 4102;

    users = mkIf managedUser {
      users._ollama = {
        uid = config.ids.uids._ollama;
        gid = config.ids.gids._ollama;
        description = "Ollama server";
        inherit (cfg) home;
        createHome = true;
        shell = "/usr/bin/false";
      };
      groups._ollama = {
        gid = config.ids.gids._ollama;
        description = "System group for Ollama";
      };
      knownUsers = [ "_ollama" ];
      knownGroups = [ "_ollama" ];
    };

    # After users, before launchd loads the daemon, which opens its log as
    # the user.
    system.activationScripts.launchd.text = mkBefore ''
      mkdir -p ${escapeShellArg cfg.home} ${escapeShellArg cfg.modelsDir}
      chown ${escapeShellArg owner} ${escapeShellArg cfg.home} ${escapeShellArg cfg.modelsDir}
      ${optionalString ownsFallbackLog ''
        mkdir -p /var/log/ollama
        chown ${escapeShellArg owner} /var/log/ollama
      ''}
    '';
  };
}
