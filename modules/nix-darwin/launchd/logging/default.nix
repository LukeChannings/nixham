_nixham:
{
  config,
  lib,
  ...
}:
let
  inherit (lib)
    concatLists
    concatMapStrings
    elem
    escapeShellArg
    filter
    groupBy
    hasPrefix
    head
    length
    literalExpression
    mapAttrsToList
    mkBefore
    mkDefault
    mkEnableOption
    mkIf
    mkOption
    types
    unique
    ;

  cfg = config.launchd.logging;
  primaryUser = config.system.primaryUser;

  # inetd-style jobs are handed the client socket as fd 0, 1 and 2.
  claimModule =
    excluded:
    { name, config, ... }:
    let
      claim = cfg.enable && config.serviceConfig.inetdCompatibility == null && !excluded name;
      path = "${cfg.directory}/${config.serviceConfig.Label}.log";
    in
    {
      config.serviceConfig = {
        StandardOutPath = mkIf claim (mkDefault path);
        StandardErrorPath = mkIf claim (mkDefault path);
      };
    };

  # launchd opens a daemon's stdio as its UserName, so the file must be theirs.
  daemonOwnership = job: {
    owner = if job.serviceConfig.UserName != null then job.serviceConfig.UserName else "root";
    group = if job.serviceConfig.GroupName != null then job.serviceConfig.GroupName else "wheel";
  };

  # A knownUsers entry without a users.users one is a scheduled deletion,
  # which nix-darwin rejects for the primary user with its own message.
  primaryGroup =
    if
      primaryUser != null
      && elem primaryUser config.users.knownUsers
      && config.users.users ? ${primaryUser}
    then
      toString config.users.users.${primaryUser}.gid
    else
      "staff";

  agentOwnershipModule = {
    options.logging = {
      owner = mkOption {
        type = types.str;
        default = if primaryUser != null then primaryUser else "root";
        defaultText = literalExpression "config.system.primaryUser";
        description = ''
          Owner of this agent's log file under {option}`launchd.logging.directory`.

          launchd opens it as the session's user, and fails the spawn
          (`EX_CONFIG`) if that user can't. Activation creates it with this
          owner, and newsyslog recreates it with the same owner after
          rotation.
        '';
      };

      group = mkOption {
        type = types.str;
        default = primaryGroup;
        defaultText = literalExpression ''
          if elem config.system.primaryUser config.users.knownUsers
          then toString config.users.users.''${config.system.primaryUser}.gid
          else "staff"
        '';
        description = "Group of this agent's log file under {option}`launchd.logging.directory`.";
      };
    };
  };

  files =
    kind: ownership: jobs:
    concatLists (
      mapAttrsToList (
        name: job:
        map
          (path: {
            inherit path;
            inherit (ownership job) owner group;
            job = "launchd.${kind}.${name}";
          })
          (
            filter (hasPrefix "${cfg.directory}/") (
              unique (
                map toString (
                  filter (p: p != null) [
                    job.serviceConfig.StandardOutPath
                    job.serviceConfig.StandardErrorPath
                  ]
                )
              )
            )
          )
      ) jobs
    );

  filesByPath = groupBy (f: f.path) (
    files "daemons" daemonOwnership config.launchd.daemons
    ++ files "user.agents" (job: job.logging) config.launchd.user.agents
  );

  logFiles = mapAttrsToList (_: head) filesByPath;
in
{
  options.launchd = {
    logging = {
      enable = mkEnableOption ''
        funnelling every `launchd.daemons` and `launchd.user.agents` job's
        stdout and stderr into {file}`<directory>/<Label>.log`, rotated by
        {option}`system.newsyslog`.

        launchd discards a job's output unless it names a file. With this
        enabled, each job's `StandardOutPath` and `StandardErrorPath`
        default (`mkDefault`) to its log file; jobs that set their own at
        normal priority keep them, outside this directory and its rotation.
        That includes several of nix-darwin's modules, e.g.
        `services.netdata` and `services.wg-quick`. inetd-style jobs are
        never redirected.

        A module that wants a log path of its own, while letting this
        claim the job, should set it with `lib.mkOverride 1100`: below
        `mkDefault`, but above the option's `null` default'';

      directory = mkOption {
        type = types.str;
        default = "/var/log/launchd";
        description = ''
          Directory each job's {file}`<Label>.log` is written to. Created
          root-owned, mode 0755. A daemon's log file is owned by its
          `serviceConfig.UserName` and `GroupName` (default `root:wheel`), a
          user agent's by {option}`launchd.user.agents.<name>.logging.owner`
          and {option}`launchd.user.agents.<name>.logging.group`.
        '';
      };

      excludeDaemons = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "my-socket-activated-job" ];
        description = ''
          `launchd.daemons` to leave alone: those whose fd 1 or 2 must not be
          redirected, e.g. a socket-activated job handed its client socket
          without being inetd-compatible. Daemons that set
          `serviceConfig.inetdCompatibility` are left alone anyway.
        '';
      };

      rotation = {
        count = mkOption {
          type = types.ints.unsigned;
          default = 5;
          description = "Number of rotated archives newsyslog keeps per log file.";
        };

        size = mkOption {
          type = types.nullOr types.str;
          default = "1024";
          description = "Size in KB at which newsyslog rotates a log file, or `null` not to rotate by size.";
        };

        when = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "@T00";
          description = "newsyslog's schedule for rotating a log file, or `null` not to rotate by time.";
        };

        flags = mkOption {
          type = types.listOf types.str;
          default = [
            "J"
            "N"
          ];
          description = ''
            newsyslog flags for each log file: by default, compress with
            bzip2 (`J`) and don't signal syslogd (`N`), which isn't the writer.

            launchd jobs can't reopen their stdio, so a long-running job
            writes to the rotated file until it is next spawned.
          '';
        };
      };
    };

    daemons = mkOption {
      type = types.attrsOf (types.submodule (claimModule (name: elem name cfg.excludeDaemons)));
    };

    user.agents = mkOption {
      type = types.attrsOf (
        types.submodule [
          (claimModule (_: false))
          agentOwnershipModule
        ]
      );
    };
  };

  config = mkIf cfg.enable {
    assertions = mapAttrsToList (path: fs: {
      assertion = length (unique (map (f: "${f.owner}:${f.group}") fs)) == 1;
      message = ''
        launchd.logging: ${path} is written by jobs with different owners:
        ${concatMapStrings (f: "  ${f.job}: ${f.owner}:${f.group}\n") fs}
        A log file can have only one owner: give these jobs distinct Labels
        or log paths, or the same owner (a daemon's UserName and GroupName,
        an agent's logging.owner and logging.group).
      '';
    }) filesByPath;

    # After users and groups, before any plist is loaded. A job whose log
    # file can't be its owner's fails to spawn, so activation stops.
    system.activationScripts.launchd.text = mkBefore ''
      echo "setting up launchd log files in ${cfg.directory}..." >&2
      /usr/bin/install -d -m 0755 -o root -g wheel ${escapeShellArg cfg.directory}
      launchdLoggingFailed=0
      ${concatMapStrings (f: ''
        if ! { [ -e ${escapeShellArg f.path} ] || /usr/bin/touch ${escapeShellArg f.path}; } \
          || ! /usr/sbin/chown ${escapeShellArg "${f.owner}:${f.group}"} ${escapeShellArg f.path}; then
          printf >&2 'error: launchd.logging: could not create %s owned by %s\n' ${escapeShellArg f.path} ${escapeShellArg "${f.owner}:${f.group}"}
          launchdLoggingFailed=1
        fi
      '') logFiles}
      if [ "$launchdLoggingFailed" -ne 0 ]; then
        printf >&2 'error: launchd.logging: aborting before loading launchd jobs that could not open their logs\n'
        exit 1
      fi
    '';

    # Without an owner, newsyslog recreates the file as root, and a
    # non-root job's next spawn fails.
    system.newsyslog.enable = true;
    system.newsyslog.files.launchd-logging = map (f: {
      logfilename = f.path;
      inherit (f) owner group;
      mode = "644";
      inherit (cfg.rotation)
        count
        size
        when
        flags
        ;
    }) logFiles;
  };
}
