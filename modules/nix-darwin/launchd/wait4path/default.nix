_nixham:
{
  config,
  lib,
  ...
}:
let
  cfg = config.launchd;

  inherit (lib)
    attrNames
    concatMapStrings
    escapeShellArg
    filterAttrs
    genAttrs
    hasPrefix
    head
    mapAttrsToList
    mkForce
    mkIf
    mkOption
    optional
    optionals
    types
    ;

  executable =
    sc:
    if sc.Program != null then
      toString sc.Program
    else if sc.ProgramArguments != null && sc.ProgramArguments != [ ] then
      head sc.ProgramArguments
    else
      null;

  inStore = p: p != null && hasPrefix "${builtins.storeDir}/" p;

  # wait4path(1) only wakes on mount-table changes: a file or socket that
  # appears without a mount would never wake it.
  waitForPath = p: "until [ -e ${escapeShellArg p} ]; do /bin/sleep 1; done && ";

  waitForPathsModule =
    { config, ... }:
    {
      options.waitForPaths = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "/run/secrets/my-service-env" ];
        description = ''
          Paths the job waits for after the Nix store is mounted and before
          its `command` or `script` is executed, e.g. secrets installed at
          activation. Each is polled for once a second. Only effective
          together with `command` or `script`.
        '';
      };

      config.serviceConfig.ProgramArguments =
        mkIf (config.command != "" && config.waitForPaths != [ ])
          (mkForce [
            "/bin/sh"
            "-c"
            (
              "/bin/wait4path /nix/store && "
              + concatMapStrings waitForPath config.waitForPaths
              + "exec ${config.command}"
            )
          ]);
    };

  bareStorePathModule = {
    options.allowBareStorePathProgram = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this daemon's executable (`serviceConfig.Program` or
        `serviceConfig.ProgramArguments[0]`) may be a Nix store path.

        It is rejected by default: when /nix mounts late, launchd's spawn
        at boot fails and the job is penalty-boxed for good. Use `command`
        or `script`, which wait for the store first. Only opt out for
        daemons that cannot run anything before their own entrypoint, e.g.
        inetd-style jobs whose stderr is the client socket, or binaries
        launchd must execute directly for TCC.
      '';
    };
  };

  bareStorePathAssertion = name: daemon: {
    assertion = daemon.allowBareStorePathProgram || !inStore (executable daemon.serviceConfig);
    message = ''
      launchd.daemons.${name}: the job's executable is the Nix store path
        ${executable daemon.serviceConfig}
      If /nix mounts late at boot, launchd's spawn fails with ENOENT and
      penalty-boxes the job for good. Set `launchd.daemons.${name}.command`
      (or `script`) instead, so the job waits for the store. Daemons that
      cannot run anything before their own entrypoint may set
      `launchd.daemons.${name}.allowBareStorePathProgram = true`.
    '';
  };

  waitForPathsAssertion = prefix: name: job: {
    assertion = job.waitForPaths == [ ] || job.command != "";
    message = ''
      ${prefix}.${name}.waitForPaths only takes effect with `command` or
      `script`; set one of those instead of `serviceConfig.Program` or
      `serviceConfig.ProgramArguments`.
    '';
  };

  # nix-darwin's own daemons that start from the store directly.
  upstreamBareStorePathDaemons =
    optionals config.services.karabiner-elements.enable [
      "karabiner_grabber"
      "karabiner_observer"
    ]
    ++ optional config.services.eternal-terminal.enable "eternal-terminal"
    ++ map (name: "wg-quick-${name}") (
      attrNames (filterAttrs (_: i: i.autostart) config.networking.wg-quick.interfaces)
    );
in
{
  options.launchd = {
    daemons = mkOption {
      type = types.attrsOf (
        types.submodule [
          waitForPathsModule
          bareStorePathModule
        ]
      );
    };
    agents = mkOption { type = types.attrsOf (types.submodule waitForPathsModule); };
    user.agents = mkOption { type = types.attrsOf (types.submodule waitForPathsModule); };
  };

  config = {
    assertions =
      mapAttrsToList bareStorePathAssertion cfg.daemons
      ++ mapAttrsToList (waitForPathsAssertion "launchd.daemons") cfg.daemons
      ++ mapAttrsToList (waitForPathsAssertion "launchd.agents") cfg.agents
      ++ mapAttrsToList (waitForPathsAssertion "launchd.user.agents") cfg.user.agents;

    launchd.daemons = genAttrs upstreamBareStorePathDaemons (_: {
      allowBareStorePathProgram = true;
    });
  };
}
