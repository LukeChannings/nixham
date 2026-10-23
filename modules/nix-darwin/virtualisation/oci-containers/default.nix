_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.virtualisation.oci-containers;
  runtime = config.virtualisation.apple-container;

  inherit (lib)
    attrNames
    concatMap
    concatMapStrings
    concatMapStringsSep
    concatStringsSep
    escapeShellArg
    escapeShellArgs
    filter
    filterAttrs
    head
    intersectLists
    length
    literalExpression
    mapAttrs'
    mapAttrsToList
    mkDefault
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optional
    optionalAttrs
    optionalString
    optionals
    splitString
    types
    ;

  container = "${runtime.package}/bin/container";
  jq = "${pkgs.jq}/bin/jq";
  user = config.system.primaryUser;
  inherit (cfg) logDir;
  stateDir = name: "${cfg.stateDir}/${name}";
  agentLabel = name: "org.nixos.oci-container-${name}";

  onDemandContainers = filterAttrs (_: c: c.apple-container.onDemand.enable) cfg.containers;

  # "[hostIP:]hostPort:containerPort[/protocol]" -> { hostIP; hostPort; containerPort; }
  parsePort =
    spec:
    let
      parts = splitString ":" (head (splitString "/" spec));
      n = length parts;
    in
    {
      hostIP = if n == 3 then head parts else null;
      hostPort = if n >= 2 then builtins.elemAt parts (n - 2) else null;
      containerPort = builtins.elemAt parts (n - 1);
    };
  validListener =
    spec:
    let
      p = parsePort spec;
      port = s: s != null && builtins.match "[0-9]+" s != null;
    in
    port p.hostPort && port p.containerPort && builtins.match ".*/.*" spec == null;

  flags =
    flag:
    concatMap (v: [
      flag
      v
    ]);
  flag =
    name: value:
    optionals (value != null) [
      name
      (toString value)
    ];
  pairs = mapAttrsToList (k: v: "${k}=${v}");

  capabilities =
    c:
    optionalAttrs c.privileged {
      CAP_SYS_ADMIN = true;
      CAP_NET_ADMIN = true;
    }
    // c.capabilities;
  capsSetTo = v: c: attrNames (filterAttrs (_: x: x == v) (capabilities c));

  runArgs =
    name: c:
    let
      a = c.apple-container;
    in
    [
      "--name"
      name
    ]
    ++ flags "--volume" c.volumes
    ++ flags "--mount" a.mounts
    ++ flags "--tmpfs" a.tmpfs
    ++ flags "--publish" c.ports
    ++ flags "--env" (pairs c.environment)
    ++ flags "--env-file" (map toString c.environmentFiles)
    ++ flags "--label" (pairs c.labels)
    ++ flags "--network" c.networks
    ++ flag "--user" c.user
    ++ flag "--workdir" c.workdir
    ++ flag "--entrypoint" c.entrypoint
    ++ flags "--cap-add" (capsSetTo true c)
    ++ flags "--cap-drop" (capsSetTo false c)
    ++ flag "--cpus" c.cpus
    ++ flag "--memory" c.memory
    ++ flag "--arch" a.arch
    ++ optional a.rosetta "--rosetta"
    ++ optional a.virtualization "--virtualization"
    ++ optional a.init "--init"
    ++ flag "--init-image" a.initImage
    ++ flag "--kernel" a.kernel
    ++ flag "--shm-size" a.shmSize
    ++ optional a.readOnly "--read-only"
    ++ flags "--ulimit" a.ulimits
    ++ optional a.dns.disable "--no-dns"
    ++ flags "--dns" a.dns.servers
    ++ flag "--dns-domain" a.dns.domain
    ++ flags "--dns-search" a.dns.searchDomains
    ++ flags "--dns-option" a.dns.options
    ++ c.extraOptions
    ++ [ c.image ]
    ++ c.cmd;

  # The runtime's own resources this container uses, which the runtime agent
  # creates once the apiserver is up.
  declaredNetworks = c: intersectLists c.networks (attrNames runtime.network);
  declaredVolumes =
    c: intersectLists (map (v: head (splitString ":" v)) c.volumes) (attrNames runtime.volume);

  readinessChecks =
    c:
    [ "system status" ]
    ++ map (n: "network inspect ${escapeShellArg n}") (declaredNetworks c)
    ++ map (v: "volume inspect ${escapeShellArg v}") (declaredVolumes c);
  readinessTimeout = 120;

  startScript =
    name: c:
    pkgs.writeShellScript "oci-container-${name}-start" ''
      set -euo pipefail
      PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

      # launchd has no ordering between jobs: wait for the runtime agent.
      ready() {
        ${concatMapStringsSep " && " (check: "${container} ${check} >/dev/null 2>&1") (readinessChecks c)}
      }
      deadline=$((SECONDS + ${toString readinessTimeout}))
      until ready; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo >&2 "oci-containers: the runtime is not ready after ${toString readinessTimeout}s"
          exit 1
        fi
        sleep 1
      done

      ${c.apple-container.preStart}

      ${optionalString (c.imageFile != null) ''
        if ! ${container} image inspect ${escapeShellArg c.image} >/dev/null 2>&1; then
          ${container} image load --input ${c.imageFile}
        fi
      ''}

      ${optionalString (c.login.registry != null) ''
        # As NixOS: a failed login is fine while the image is already here.
        if ! ${container} registry login ${
          escapeShellArgs (
            flag "--username" c.login.username
            ++ optional (c.login.passwordFile != null) "--password-stdin"
            ++ [ c.login.registry ]
          )
        } ${optionalString (c.login.passwordFile != null) "<${escapeShellArg c.login.passwordFile}"}; then
          echo >&2 "oci-containers: registry login failed; continuing if the image is present"
          ${container} image inspect ${escapeShellArg c.image} >/dev/null
        fi
      ''}

      ${concatMapStrings (dep: ''
        echo >&2 "oci-containers: waiting for container ${dep}"
        until ${container} inspect ${escapeShellArg dep} 2>/dev/null | ${jq} -e '.[0].status.state == "running"' >/dev/null; do
          sleep 2
        done
      '') c.dependsOn}

      ${container} delete --force ${escapeShellArg name} >/dev/null 2>&1 || true
      exec ${container} run ${escapeShellArgs (runArgs name c)}
    '';

  # Runs a command as the primary user, in their session, where the apiserver
  # is: root reaches it only through `launchctl asuser`.
  asUser = ''
    asUser() {
      if [ "$(id -u)" = "$uid" ]; then
        ${pkgs.coreutils}/bin/timeout 10 "$@"
      else
        ${pkgs.coreutils}/bin/timeout 10 /bin/launchctl asuser "$uid" /usr/bin/sudo -H -u ${escapeShellArg user} -- "$@"
      fi
    }
  '';

  # One per accepted connection (inetd nowait), with the container's port as
  # $1. A root daemon, as macOS's Local Network Privacy denies user agents the
  # containers' vmnet; it wakes the container agent in the user's session.
  proxyScript =
    name: c:
    let
      od = c.apple-container.onDemand;
      dir = stateDir name;
    in
    pkgs.writeShellScript "oci-container-${name}-proxy" ''
      exec 2>>${logDir}/${name}-proxy.log
      set -uo pipefail
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.socat
          pkgs.gnugrep
        ]
      }:$PATH
      port=$1

      log() { echo "${name}-proxy[$$] $(date -Is): $*" >&2; }

      stamp() { touch ${dir}/last-activity 2>/dev/null || true; }
      stamp
      trap stamp EXIT

      uid=$(id -u ${escapeShellArg user} 2>/dev/null) || {
        log "ERROR no uid for ${user}"
        exit 1
      }
      ${asUser}

      # Never through the resolver: it negative-caches the NXDOMAIN a
      # stopped container answers with for over a minute.
      containerIp() {
        asUser ${container} inspect ${escapeShellArg name} 2>/dev/null \
          | ${jq} -r 'first(.[0].status | select(.state == "running") | .networks[]?.ipv4Address // empty | split("/")[0]) // empty' \
          | grep -xE '[0-9]{1,3}(\.[0-9]{1,3}){3}'
      }
      probe() {
        ip=$(containerIp) || ip=""
        [ -n "$ip" ] && socat -u /dev/null "TCP4:$ip:$port,connect-timeout=2" 2>/dev/null
      }

      ip=""
      if ! probe; then
        log "starting ${name}"
        /bin/launchctl kickstart "gui/$uid/${agentLabel name}" >/dev/null 2>&1 \
          || log "kickstart failed (is ${user} logged in?)"
        deadline=$((SECONDS + ${toString od.startTimeout}))
        until probe; do
          if [ "$SECONDS" -ge "$deadline" ]; then
            log "ERROR ${name} did not answer on ''${ip:-<no IPv4 address>}:$port within ${toString od.startTimeout}s"
            exit 1
          fi
          sleep 1
        done
        log "${name} is up at $ip"
      fi

      # A cold start releases every waiting connection at once: space out
      # their connects (not their sessions) so a fresh server's pre-auth
      # limits (e.g. sshd's MaxStartups) see one or two at a time.
      lock=${dir}/connect.lock
      gate=$((SECONDS + 60))
      until mkdir "$lock" 2>/dev/null; do
        [ $(($(date +%s) - $(date -r "$lock" +%s 2>/dev/null || echo 0))) -lt 5 ] || rmdir "$lock" 2>/dev/null
        [ "$SECONDS" -lt "$gate" ] || break
        sleep 0.1
      done
      sleep 0.15
      rmdir "$lock" 2>/dev/null

      # Not exec: the idle watchdog finds open connections by this script.
      socat STDIO "TCP4:$ip:$port"
    '';

  idleScript =
    name: c:
    let
      od = c.apple-container.onDemand;
      dir = stateDir name;
    in
    pkgs.writeShellScript "oci-container-${name}-idle" ''
      set -uo pipefail
      PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

      ${container} inspect ${escapeShellArg name} 2>/dev/null \
        | ${jq} -e '.[0].status.state == "running"' >/dev/null || exit 0

      # Open connections, and sessions that bypass the listeners.
      /usr/bin/pgrep -f ${escapeShellArg "${c.apple-container.onDemand.proxy}"} >/dev/null && exit 0
      /usr/bin/pgrep -f ${escapeShellArg "container (exec|attach) .*${name}"} >/dev/null && exit 0

      # Started by other means: the clock starts now.
      [ -e ${dir}/last-activity ] || {
        touch ${dir}/last-activity
        exit 0
      }
      idle=$(($(date +%s) - $(date -r ${dir}/last-activity +%s)))
      [ "$idle" -ge ${toString od.idleTimeout} ] || exit 0

      echo >&2 "oci-containers: ${name} idle for ''${idle}s; stopping it"
      ${container} stop ${escapeShellArg name}
    '';

  containerOptions =
    { name, config, ... }:
    {
      options = {
        image = mkOption {
          type = types.str;
          example = "nginx:latest";
          description = "OCI image to run.";
        };

        imageFile = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = ''
            An OCI image archive, loaded ({command}`container image load`)
            unless {option}`image` is already present. {option}`image` must
            be the ref the archive names.
          '';
        };

        cmd = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Command line, overriding the image's.";
        };

        entrypoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Entrypoint, overriding the image's.";
        };

        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Environment variables.";
        };

        environmentFiles = mkOption {
          type = types.listOf types.path;
          default = [ ];
          description = "Files of `KEY=value` lines (`--env-file`).";
        };

        ports = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "127.0.0.1:8080:80" ];
          description = "Published ports, `[hostIP:]hostPort:containerPort[/protocol]`.";
        };

        volumes = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "/var/www:/usr/share/nginx/html:ro" ];
          description = ''
            Volumes, `source:target[:options]`: a host path (a directory or a
            single file) or a named volume, e.g. one in
            {option}`virtualisation.apple-container.volume`.
          '';
        };

        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "1000:1000";
          description = "User to run as, `user[:group]`.";
        };

        workdir = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Working directory.";
        };

        labels = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Labels.";
        };

        networks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Networks to attach to: the built-in `default`, or one in
            {option}`virtualisation.apple-container.network`, which the
            container waits for.
          '';
        };

        dependsOn = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Containers in {option}`virtualisation.oci-containers.containers`
            to wait for, until they run, before starting.
          '';
        };

        autoStart = mkOption {
          type = types.bool;
          default = !config.apple-container.onDemand.enable;
          defaultText = literalExpression "!apple-container.onDemand.enable";
          description = "Start the container at login: the runtime is per-user, so never at boot.";
        };

        keepAlive = mkOption {
          type = types.bool;
          default = !config.apple-container.onDemand.enable;
          defaultText = literalExpression "!apple-container.onDemand.enable";
          description = "Restart the container whenever it exits.";
        };

        privileged = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Add `CAP_SYS_ADMIN` and `CAP_NET_ADMIN`: the runtime has no
            privileged mode, each container being a VM of its own.
            {option}`capabilities` overrides either.
          '';
        };

        capabilities = mkOption {
          type = types.attrsOf (types.nullOr types.bool);
          default = { };
          example.CAP_SYS_ADMIN = true;
          description = "Capabilities to add (`true`) or drop (`false`).";
        };

        cpus = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          description = "CPUs of the container's VM.";
        };

        memory = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "2g";
          description = "Memory of the container's VM.";
        };

        login = {
          registry = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Registry to log in to before starting.";
          };
          username = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Username for {option}`login.registry`.";
          };
          passwordFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Runtime path of the password for {option}`login.registry`, never copied to the store.";
          };
        };

        extraOptions = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra arguments to {command}`container run`.";
        };

        # No equivalent upstream: apple-container's own flags.
        apple-container = {
          arch = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "amd64";
            description = "Architecture to run (`--arch`).";
          };
          rosetta = mkOption {
            type = types.bool;
            default = false;
            description = "Run x86-64 binaries through Rosetta (`--rosetta`).";
          };
          virtualization = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Expose virtualization to the container, e.g. {file}`/dev/kvm`
              (`--virtualization`). The container fails to start on a host
              without nested virtualization (before M3), and needs a kernel
              with `CONFIG_KVM`, such as `apple-container-kernel`.
            '';
          };
          init = mkOption {
            type = types.bool;
            default = false;
            description = "Run an init that forwards signals and reaps zombies (`--init`).";
          };
          initImage = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Init image (`--init-image`).";
          };
          kernel = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = literalExpression ''"''${pkgs.apple-container-kernel}/vmlinux-arm64"'';
            description = ''
              Uncompressed kernel to boot (`--kernel`), instead of
              {option}`virtualisation.apple-container.system.kernel`.
            '';
          };
          mounts = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "type=tmpfs,target=/cache" ];
            description = "Mounts (`--mount`).";
          };
          tmpfs = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "tmpfs mount points (`--tmpfs`).";
          };
          shmSize = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Size of /dev/shm (`--shm-size`).";
          };
          readOnly = mkOption {
            type = types.bool;
            default = false;
            description = "Mount the root file system read-only (`--read-only`).";
          };
          ulimits = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "nofile=1024:2048" ];
            description = "Resource limits (`--ulimit`).";
          };
          dns = {
            servers = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Nameservers (`--dns`).";
            };
            domain = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "DNS domain (`--dns-domain`).";
            };
            searchDomains = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Search domains (`--dns-search`).";
            };
            options = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Resolver options (`--dns-option`).";
            };
            disable = mkOption {
              type = types.bool;
              default = false;
              description = "Configure no DNS (`--no-dns`); excludes the other `dns` options.";
            };
          };

          preStart = mkOption {
            type = types.lines;
            default = "";
            description = "Shell commands run once the runtime is ready, before the image is loaded.";
          };

          onDemand = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Start the container on the first connection to one of
                {option}`ports`, and stop it after {option}`idleTimeout`
                without one. launchd owns the listeners, so they are up
                while the container is not; each connection waits for the
                container, then is bridged to the container's own address.

                Turns {option}`autoStart` and {option}`keepAlive` off.
              '';
            };
            ports = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "127.0.0.1:2222:22" ];
              description = ''
                TCP listeners, `[hostIP:]hostPort:containerPort`: on every
                address without a hostIP. Not in {option}`ports`, which would
                take the same host port.
              '';
            };
            idleTimeout = mkOption {
              type = types.ints.unsigned;
              default = 1800;
              description = ''
                Seconds since the last connection opened or closed after
                which the container is stopped; never while a connection, or
                a {command}`container exec`/{command}`attach`, is open. It is
                checked every minute, so 0 stops the container at the first
                check without one.
              '';
            };
            startTimeout = mkOption {
              type = types.ints.positive;
              default = 300;
              description = "Seconds a connection waits for the container to answer, e.g. through a first image pull.";
            };
            proxy = mkOption {
              internal = true;
              readOnly = true;
              type = types.package;
              default = proxyScript name config;
              description = "The script each accepted connection runs.";
            };
          };
        };
      };
    };

  assertionsFor =
    name: c:
    let
      a = c.apple-container;
      od = a.onDemand;
      prefix = "virtualisation.oci-containers.containers.${name}";
      hostPorts = specs: filter (p: p != null) (map (s: (parsePort s).hostPort) specs);
      collisions = intersectLists (hostPorts od.ports) (hostPorts c.ports);
    in
    [
      {
        assertion = builtins.all (d: cfg.containers ? ${d}) c.dependsOn;
        message = "${prefix}.dependsOn names undefined containers: ${
          toString (filter (d: !(cfg.containers ? ${d})) c.dependsOn)
        }.";
      }
      {
        assertion =
          !a.dns.disable
          || (
            a.dns.servers == [ ] && a.dns.domain == null && a.dns.searchDomains == [ ] && a.dns.options == [ ]
          );
        message = "${prefix}.apple-container.dns.disable excludes the other apple-container.dns options.";
      }
      {
        assertion = !od.enable || (!c.autoStart && !c.keepAlive);
        message = "${prefix}: an on-demand container is started by its listeners and stopped when idle, so it can be neither autoStart nor keepAlive.";
      }
      {
        assertion = !od.enable || (od.ports != [ ] && builtins.all validListener od.ports);
        message = "${prefix}.apple-container.onDemand.ports needs listeners, each `[hostIP:]hostPort:containerPort` (got: ${toString od.ports}).";
      }
      {
        assertion = !od.enable || collisions == [ ];
        message = "${prefix}: host ports ${toString collisions} are both on-demand listeners and published ports.";
      }
    ];
in
{
  options.virtualisation.oci-containers.logDir = mkOption {
    internal = true;
    type = types.str;
    default = "/var/log/oci-containers";
    description = "Where the containers' jobs log.";
  };

  options.virtualisation.oci-containers.stateDir = mkOption {
    internal = true;
    type = types.str;
    default = "/var/run/oci-containers";
    description = "Where on-demand containers keep their activity stamps.";
  };

  options.virtualisation.oci-containers.containers = mkOption {
    type = types.attrsOf (types.submodule containerOptions);
    default = { };
    example = literalExpression ''
      {
        nginx = {
          image = "nginx:latest";
          ports = [ "127.0.0.1:8080:80" ];
        };
      }
    '';
    description = "OCI containers, each run by a launchd agent of the primary user, through apple-container.";
  };

  config = mkIf (cfg.containers != { }) (mkMerge [
    {
      assertions = [
        {
          assertion = runtime.enable;
          message = "virtualisation.oci-containers runs containers through virtualisation.apple-container, which is disabled.";
        }
      ]
      ++ concatMap (n: assertionsFor n cfg.containers.${n}) (attrNames cfg.containers);

      virtualisation.apple-container.enable = mkDefault true;

      system.requiresPrimaryUser = [ "virtualisation.oci-containers" ];

      system.activationScripts.preActivation.text = ''
        install -d -o ${escapeShellArg user} ${logDir}
      '';

      launchd.user.agents = mapAttrs' (
        name: c:
        nameValuePair "oci-container-${name}" {
          command = startScript name c;
          serviceConfig = {
            RunAtLoad = c.autoStart;
            KeepAlive = c.keepAlive;
            ThrottleInterval = 10;
            StandardOutPath = "${logDir}/${name}.log";
            StandardErrorPath = "${logDir}/${name}.log";
          };
        }
      ) cfg.containers;
    }

    (mkIf (onDemandContainers != { }) {
      launchd.daemons = lib.listToAttrs (
        concatMap (
          name:
          let
            c = onDemandContainers.${name};
          in
          map (
            spec:
            let
              p = parsePort spec;
            in
            nameValuePair "oci-container-${name}-proxy-${p.hostPort}" {
              # Not through /bin/sh: fd 2 is the client's socket until the
              # script redirects it.
              allowBareStorePathProgram = true;
              serviceConfig = {
                ProgramArguments = [
                  "${c.apple-container.onDemand.proxy}"
                  p.containerPort
                ];
                inetdCompatibility.Wait = false;
                Sockets.Listener = {
                  SockServiceName = p.hostPort;
                  SockType = "stream";
                  SockFamily = "IPv4";
                  SockProtocol = "TCP";
                }
                // optionalAttrs (p.hostIP != null) { SockNodeName = p.hostIP; };
              };
            }
          ) c.apple-container.onDemand.ports
        ) (attrNames onDemandContainers)
      );

      launchd.user.agents = mapAttrs' (
        name: c:
        nameValuePair "oci-container-${name}-idle" {
          command = idleScript name c;
          serviceConfig = {
            StartInterval = 60;
            StandardOutPath = "${logDir}/${name}-idle.log";
            StandardErrorPath = "${logDir}/${name}-idle.log";
          };
        }
      ) onDemandContainers;

      # launchd restarts neither: stop one running an older start script.
      system.activationScripts.postActivation.text = ''
        uid=$(id -u ${escapeShellArg user})
        ${asUser}
        ${concatStringsSep "\n" (
          mapAttrsToList (name: c: ''
            install -d -o ${escapeShellArg user} ${stateDir name}
            if [ "$(cat ${stateDir name}/start-script 2>/dev/null)" != ${startScript name c} ]; then
              asUser ${container} stop ${escapeShellArg name} >/dev/null 2>&1 || true
              echo ${startScript name c} >${stateDir name}/start-script
            fi
          '') onDemandContainers
        )}
      '';
    })
  ]);
}
