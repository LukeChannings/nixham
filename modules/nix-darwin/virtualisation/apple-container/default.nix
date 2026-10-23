nixham:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.virtualisation.apple-container;

  inherit (lib)
    attrNames
    concatMap
    concatMapStrings
    concatStringsSep
    escapeShellArg
    escapeShellArgs
    hasPrefix
    literalExpression
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    optional
    optionals
    optionalString
    removeSuffix
    splitString
    types
    unique
    ;

  container = "${cfg.package}/bin/container";
  jq = "${pkgs.jq}/bin/jq";
  logDir = "/var/log/apple-container";

  # apple/container hardcodes its per-user volume store; nothing relocates it.
  volumesDir = "${config.system.primaryUserHome}/Library/Application Support/com.apple.container/volumes";
  volumesTarget = if cfg.volumesRoot == null then null else removeSuffix "/" cfg.volumesRoot;
  # The volume a /Volumes/<name>/... target lives on: while it is unmounted,
  # activation leaves the volumes dir alone rather than filling the root disk.
  volumesMountRoot =
    let
      parts = splitString "/" volumesTarget;
    in
    if hasPrefix "/Volumes/" volumesTarget && builtins.length parts >= 3 then
      "/Volumes/${builtins.elemAt parts 2}"
    else
      "";

  domains = unique (
    cfg.system.dns.domains
    ++ optional (cfg.system.dns.defaultDomain != null) cfg.system.dns.defaultDomain
  );

  kvFlags =
    flag: attrs:
    concatMap (kv: [
      flag
      kv
    ]) (mapAttrsToList (k: v: "${k}=${v}") attrs);

  networkCreateArgs =
    name: n:
    optionals (n.subnet != null) [
      "--subnet"
      n.subnet
    ]
    ++ optionals (n.subnetV6 != null) [
      "--subnet-v6"
      n.subnetV6
    ]
    ++ optional n.internal "--internal"
    ++ optionals (n.plugin != null) [
      "--plugin"
      n.plugin
    ]
    ++ kvFlags "--option" n.options
    ++ kvFlags "--label" n.labels
    ++ [ name ];

  volumeCreateArgs =
    name: v:
    optionals (v.size != null) [
      "-s"
      v.size
    ]
    ++ kvFlags "--opt" v.options
    ++ kvFlags "--label" v.labels
    ++ [ name ];

  # One marker per kernel, so a respawn never re-ingests the (large) archive.
  kernelMarker =
    arch: k:
    "kernel-${arch}-${
      builtins.substring 0 12 (builtins.hashString "sha256" "${k.tar}\n${k.binary}\n${toString k.digest}")
    }";

  configToml = "[dns]\ndomain = ${builtins.toJSON cfg.system.dns.defaultDomain}";

  # ensure <list command> <kind> <name> <create command...>: creates <name>
  # unless the JSON listing has it. Never updates or deletes.
  converge =
    kind: list: create: resources:
    optionalString (resources != { }) ''
      existing="$(${container} ${list} --format json)"
      ${concatStringsSep "\n" (
        mapAttrsToList (name: r: ''
          if ! ${jq} -e --arg id ${escapeShellArg name} 'any(.[]; .id == $id)' <<<"$existing" >/dev/null; then
            echo >&2 "apple-container: creating ${kind} ${name}"
            ${container} ${escapeShellArgs (create name r)}
          fi
        '') resources
      )}
    '';

  startScript = pkgs.writeShellScript "apple-container-start" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
    ${optionalString (cfg.system.dns.defaultDomain != null) ''
      conf="''${XDG_CONFIG_HOME:-$HOME/.config}/container/config.toml"
      toml=${escapeShellArg configToml}
      if [ "$(cat "$conf" 2>/dev/null)" != "$toml" ]; then
        mkdir -p "$(dirname "$conf")"
        printf '%s\n' "$toml" >"$conf"
      fi
    ''}
    # `system start` also snapshots config.toml for every later `container run`.
    ${container} system start ${
      if cfg.system.kernel == { } then "--enable-kernel-install" else "--disable-kernel-install"
    }
    # A running apiserver keeps its version until it restarts (e.g. at login).
    ${container} system status --format json | ${jq} -r '
      .client.version as $c
      | select(.server.version | contains(" version \($c) ") | not)
      | "apple-container: WARN the apiserver is \(.server.version), not \($c); run `container system stop` and restart this agent to upgrade it"
    ' >&2
    ${optionalString (cfg.system.kernel != { }) ''
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/apple-container"
      mkdir -p "$state"
      ${concatStringsSep "\n" (
        mapAttrsToList (arch: k: ''
          if [ ! -e "$state/${kernelMarker arch k}" ]; then
            echo >&2 "apple-container: installing the ${arch} kernel from ${k.tar}"
            ${container} system kernel set --force ${
              escapeShellArgs (
                [
                  "--arch"
                  arch
                  "--tar"
                  k.tar
                  "--binary"
                  k.binary
                ]
                ++ optionals (k.digest != null) [
                  "--digest"
                  k.digest
                ]
              )
            }
            touch "$state/${kernelMarker arch k}"
          fi
        '') cfg.system.kernel
      )}
    ''}
    ${converge "network" "network list" (
      name: n:
      [
        "network"
        "create"
      ]
      ++ networkCreateArgs name n
    ) cfg.network}
    ${converge "volume" "volume list" (
      name: v:
      [
        "volume"
        "create"
      ]
      ++ volumeCreateArgs name v
    ) cfg.volume}
  '';

  # Root only: a domain is a file in /etc/resolver.
  dnsScript = ''
    existing="$(${container} system dns list --format json 2>/dev/null || echo '[]')"
    ${concatMapStrings (d: ''
      if ! ${jq} -e --arg d ${escapeShellArg d} 'index($d) != null' <<<"$existing" >/dev/null; then
        echo >&2 "apple-container: creating DNS domain ${d}"
        ${container} system dns create ${escapeShellArg d} \
          || echo >&2 "apple-container: WARN could not create DNS domain ${d}"
      fi
    '') domains}
  '';

  volumesRootScript = pkgs.writeShellScript "apple-container-volumes-root" ''
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    ${builtins.readFile ./volumes-root.sh}
  '';

  kernelType = types.coercedTo types.str (tar: { inherit tar; }) (
    types.submodule {
      options = {
        tar = mkOption {
          type = types.str;
          description = "Tar archive holding the kernel: a local path or a URL (`--tar`).";
        };
        binary = mkOption {
          type = types.str;
          default = "./opt/kata/share/kata-containers/vmlinux.container";
          description = "Path of the kernel within {option}`tar` (`--binary`). Defaults to the Kata Containers layout.";
        };
        digest = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5";
          description = "Expected digest of {option}`tar` (`--digest`); the runtime requires it when {option}`tar` is a URL.";
        };
      };
    }
  );

  networkType = types.submodule {
    options = {
      subnet = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "192.168.66.0/24";
        description = "IPv4 subnet (`--subnet`); the runtime picks one when null.";
      };
      subnetV6 = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "fd12:3456:789a::/64";
        description = ''
          IPv6 prefix (`--subnet-v6`). The built-in `default` network gives
          containers only a link-local IPv6 address; one with a prefix gives
          them a global address and IPv6 egress.
        '';
      };
      internal = mkOption {
        type = types.bool;
        default = false;
        description = "Restrict the network to host-only traffic (`--internal`).";
      };
      plugin = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "container-network-vmnet";
        description = "Network plugin (`--plugin`); the runtime's default when null.";
      };
      options = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example.mtu = "1400";
        description = "Plugin-specific options (`--option key=value`).";
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Labels (`--label key=value`).";
      };
    };
  };

  volumeType = types.submodule {
    options = {
      size = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "512G";
        description = "Size, in bytes with an optional K, M, G, T or P suffix (`-s`); the runtime's default when null.";
      };
      options = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Driver-specific options (`--opt key=value`).";
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Labels (`--label key=value`).";
      };
    };
  };
in
{
  options.virtualisation.apple-container = {
    enable = mkEnableOption ''
      Apple's container runtime (apple/container). The runtime is per-user:
      it runs as launchd user agents of {option}`system.primaryUser`, so it is
      up only while that user is logged in. Requires macOS 15+ on Apple
      Silicon'';

    package = mkPackageOption pkgs "container" { };

    system.kernel = mkOption {
      type = types.attrsOf kernelType;
      default = { };
      example = literalExpression ''
        { arm64 = { tar = "''${pkgs.apple-container-kernel}/kernel.tar"; binary = "./vmlinux-arm64"; }; }
      '';
      description = ''
        The default guest kernel per architecture (`arm64` or `amd64`), as
        {command}`container system kernel set`. A bare string is the tar,
        with the Kata Containers layout.

        Empty installs the runtime's recommended kernel on first start. A
        changed kernel replaces the installed one (`--force`). A container
        can boot its own kernel instead, with
        {option}`virtualisation.oci-containers.containers.<name>.apple-container.kernel`.
      '';
    };

    system.dns = {
      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "test" ];
        description = ''
          Local DNS domains to create, as {command}`container system dns create`.
          {option}`defaultDomain` is always created. Domains are never deleted.
        '';
      };

      defaultDomain = mkOption {
        type = types.nullOr types.str;
        default = "container";
        description = ''
          The domain containers are registered under, so that the host
          resolves `<container>.<defaultDomain>`. The runtime has a single
          default domain, for all of the user's containers.

          The module owns the primary user's
          {file}`~/.config/container/config.toml` to set it (`[dns] domain`);
          null leaves that file alone.
        '';
      };
    };

    network = mkOption {
      type = types.attrsOf networkType;
      default = { };
      example.v6.subnetV6 = "fd12:3456:789a::/64";
      description = ''
        Networks to create, as {command}`container network create`. Never
        updated or deleted: delete one to have it recreated with new
        settings. Container-to-container networking requires macOS 26+.
      '';
    };

    volume = mkOption {
      type = types.attrsOf volumeType;
      default = { };
      example.cache.size = "64G";
      description = ''
        Named volumes to create, as {command}`container volume create`.
        Never updated or deleted.
      '';
    };

    volumesRoot = mkOption {
      type = types.nullOr (
        types.pathWith {
          absolute = true;
          inStore = false;
        }
      );
      default = null;
      example = "/Volumes/Virtual Machines/container-volumes";
      description = ''
        Directory to hold the primary user's volumes instead of
        {file}`~/Library/Application Support/com.apple.container/volumes`,
        e.g. to keep them off the internal disk.

        Activation symlinks the volumes directory to it, only while the
        volumes directory is absent or empty; otherwise it warns and leaves
        it alone. Under {file}`/Volumes/<name>`, it must be a subdirectory of
        the volume, and nothing happens while the volume is unmounted.
        Unsetting it leaves an existing symlink in place.
      '';
    };

    socktainer = {
      enable =
        mkEnableOption "socktainer, a Docker-compatible API socket on top of the runtime. Requires macOS 26+"
        // {
          default = true;
        };

      package = mkOption {
        type = types.package;
        default = nixham.inputs.socktainer.packages.${pkgs.stdenv.hostPlatform.system}.socktainer;
        defaultText = literalExpression "nixham.inputs.socktainer.packages.\${system}.socktainer";
        description = ''
          The socktainer package. It talks to the runtime as a `container`
          client of its own pinned version, so keep it in step with
          {option}`package`.
        '';
      };

      socketPath = mkOption {
        type = types.str;
        readOnly = true;
        default = "${config.system.primaryUserHome}/.socktainer/container.sock";
        defaultText = literalExpression ''"''${config.system.primaryUserHome}/.socktainer/container.sock"'';
        description = ''
          Where socktainer listens. Bind-mount it into a container at
          {file}`/var/run/docker.sock` (read-write) to give it the Docker API.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.isAarch64;
          message = "virtualisation.apple-container only runs on Apple Silicon (aarch64-darwin).";
        }
        {
          assertion = builtins.all (a: a == "arm64" || a == "amd64") (attrNames cfg.system.kernel);
          message = ''virtualisation.apple-container.system.kernel: architectures are "arm64" or "amd64", not: ${concatStringsSep ", " (attrNames cfg.system.kernel)}.'';
        }
        {
          assertion =
            cfg.volumesRoot == null
            || !(builtins.elem volumesTarget [
              ""
              "/Volumes"
              volumesMountRoot
            ]);
          message = ''virtualisation.apple-container.volumesRoot must be a directory below a volume, not "/", "/Volumes" or "/Volumes/<name>" (got "${toString cfg.volumesRoot}").'';
        }
      ];

      system.requiresPrimaryUser = [ "virtualisation.apple-container" ];

      environment.systemPackages = [ cfg.package ];

      # Before launchd loads the agents, which log here.
      system.activationScripts.preActivation.text = ''
        install -d -o ${escapeShellArg config.system.primaryUser} ${logDir}
      '';

      system.activationScripts.launchd.text = lib.mkBefore (
        optionalString (cfg.volumesRoot != null) ''
          echo "setting up apple-container volumes root..." >&2
          ${volumesRootScript} ${
            escapeShellArgs [
              volumesDir
              volumesTarget
              volumesMountRoot
              config.system.primaryUser
            ]
          }
        ''
      );

      system.activationScripts.postActivation.text = dnsScript;

      launchd.user.agents.apple-container = {
        command = startScript;
        serviceConfig = {
          RunAtLoad = true;
          # Converges once per load; retried only while it fails.
          KeepAlive.SuccessfulExit = false;
          ThrottleInterval = 10;
          StandardOutPath = "${logDir}/runtime.log";
          StandardErrorPath = "${logDir}/runtime.log";
        };
      };
    }

    (mkIf cfg.socktainer.enable {
      launchd.user.agents.socktainer = {
        # --no-docker-context: leave the user's ~/.docker alone.
        command = "${cfg.socktainer.package}/bin/socktainer --no-docker-context";
        path = [ cfg.package ];
        serviceConfig = {
          RunAtLoad = true;
          # Fails until the runtime is up; launchd has no ordering to wait with.
          KeepAlive = true;
          ThrottleInterval = 10;
          StandardOutPath = "${logDir}/socktainer.log";
          StandardErrorPath = "${logDir}/socktainer.log";
        };
      };
    })
  ]);
}
