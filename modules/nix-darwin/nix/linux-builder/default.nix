nixham:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nix.linux-builder;
  runtime = config.virtualisation.apple-container;
  container = config.virtualisation.oci-containers.containers.${cfg.name};

  inherit (lib)
    concatMapStrings
    escapeShellArg
    escapeShellArgs
    literalExpression
    mkDefault
    mkEnableOption
    mkIf
    mkOption
    optional
    optionals
    optionalString
    types
    ;

  packages = nixham.packages.${pkgs.stdenv.hostPlatform.system};
  user = config.system.primaryUser;
  inherit (cfg) stateDir;

  domain = runtime.system.dns.defaultDomain;
  host = if domain == null then cfg.name else "${cfg.name}.${domain}";

  # The ref the container runs; "" only when an assertion fails.
  ref =
    if cfg.imageFile != null then
      cfg.imageFile.imageRef or ""
    else if cfg.image != null then
      cfg.image
    else
      "";

  nixConfig =
    optionalString (cfg.imageFile != null) (
      cfg.imageFile.nixosConfig.system.build.shuttledNixConf or ""
    )
    + optionalString (cfg.nixConfSecretFile != null) "!include ${secretNixConf}\n";
  secretNixConf = "/secrets/nix.conf";

  ownerLabel = "org.nixos.managed-by";

  provision = pkgs.writeShellScript "linux-builder-provision" ''
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.openssh
      ]
    }
    ${builtins.readFile ./provision.sh}
  '';

  preStart = pkgs.writeShellScript "linux-builder-pre-start" ''
    PATH=${
      lib.makeBinPath [
        runtime.package
        pkgs.jq
      ]
    }:$PATH
    ${builtins.readFile ./pre-start.sh}
  '';
in
{
  disabledModules = [ "nix/linux-builder.nix" ];

  options.nix.linux-builder = {
    enable = mkEnableOption ''
      a Linux builder: a NixOS container, run by
      {option}`virtualisation.oci-containers`, that builds
      {option}`systems` for this host's Nix over SSH'';

    package = mkOption {
      type = types.package;
      default = packages.linux-builder-image;
      defaultText = literalExpression "nixham.packages.\${system}.linux-builder-image";
      apply =
        pkg:
        pkg.override (old: {
          modules = (old.modules or [ ]) ++ [ cfg.config ];
        });
      description = ''
        The builder image, with {option}`config` merged in through its
        `override { modules = …; }`, as `packages/linux-builder-image`
        takes. An aarch64-linux derivation: it builds on a Linux builder
        this host already has, unless a substituter has it.
      '';
    };

    config = mkOption {
      type = types.deferredModule;
      default = { };
      example = literalExpression ''
        { pkgs, ... }:
        {
          nix.settings.substituters = [ "https://cache.example.org" ];
          environment.systemPackages = [ pkgs.htop ];
        }
      '';
      description = ''
        NixOS configuration of the builder, on top of the image's base
        profile. Its Nix settings ({option}`nix.settings`,
        {option}`nix.extraOptions`) reach the builder at boot as
        `NIX_CONFIG`, so changing only them reuses the image; anything else
        rebuilds it. `NIX_CONFIG` is visible to {command}`container inspect`:
        use {option}`nixConfSecretFile` for secrets.

        CPUs, memory, Rosetta and SSH keys are the host's, set here in
        {option}`nix.linux-builder`. No effect when {option}`image` or
        {option}`imageFile` selects an image built out of band.
      '';
    };

    image = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ghcr.io/lukechannings/linux-builder:latest";
      description = ''
        A registry ref of an image built out of band, pulled when the
        builder starts. Excludes {option}`imageFile`.
      '';
    };

    imageFile = mkOption {
      type = types.nullOr types.package;
      default = if cfg.image == null then cfg.package else null;
      defaultText = literalExpression "if image == null then package else null";
      example = literalExpression ''archive // { imageRef = "linux-builder:prebuilt"; }'';
      description = ''
        An OCI image archive, loaded when the builder starts unless its
        `imageRef`, the ref the archive names, is already present. Its
        loaded predecessors in {option}`package`'s repository
        (`linux-builder`) are deleted then. Excludes {option}`image`.
      '';
    };

    sshKeyFile = mkOption {
      type = types.str;
      default = "${stateDir}/ssh_key";
      defaultText = literalExpression ''"/var/lib/linux-builder/ssh_key"'';
      example = "/run/secrets/linux-builder-ssh-key";
      description = ''
        Runtime path of the SSH private key root's Nix logs in with, never
        copied to the store. The default is generated at activation.
        Activation authorizes its public half for {option}`sshUser`.
      '';
    };

    userSshKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/linux-builder-ssh-key-users";
      description = ''
        Runtime path of an SSH private key for users other than root, e.g.
        readable by a group allowed to build on the builder; when null, only
        root can. Activation authorizes its public half too. A file of its
        own: ssh refuses a key that others can read, so
        {option}`sshKeyFile` can't be shared.
      '';
    };

    nixConfSecretFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/linux-builder-nix.conf";
      description = ''
        Runtime path of a nix.conf for the builder's secrets, e.g.
        `access-tokens`, included last. It is mounted read-only into the
        builder, so {command}`container inspect` shows its path, never its
        contents. The primary user, whose runtime mounts it, must be able to
        read it.
      '';
    };

    sshUser = mkOption {
      type = types.str;
      default = "builder";
      description = "User Nix logs in to the builder as: the image's trusted Nix user.";
    };

    cpus = mkOption {
      type = types.ints.positive;
      default = 6;
      description = "CPUs of the builder's VM.";
    };

    memory = mkOption {
      type = types.str;
      default = "12g";
      description = "Memory of the builder's VM.";
    };

    kernel = mkOption {
      type = types.package;
      default = packages.apple-container-kernel;
      defaultText = literalExpression "nixham.packages.\${system}.apple-container-kernel";
      description = ''
        Guest kernel the builder boots, whatever the runtime's default. It
        must have `CONFIG_EROFS_FS` for the image's `/etc`, and `CONFIG_KVM`
        for `kvm` builds, and hold {file}`vmlinux-arm64`.
      '';
    };

    onDemand = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Start the builder on Nix's first connection, to
          `127.0.0.1:`{option}`onDemand.port`, and stop it once idle, as
          {option}`virtualisation.oci-containers.containers.<name>.apple-container.onDemand`,
          which sets the timeouts; its `idleTimeout` defaults to 0 here, so the
          builder stops once no connection is open. When off, the builder runs from login and
          is reached by name, through the runtime's default DNS domain.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 22022;
        description = "Loopback port Nix connects to, which starts the builder.";
      };
    };

    ephemeral = mkEnableOption ''
      an ephemeral store: without the `linux-builder-store` volume, the
      builder's store is lost every time it stops'';

    extraVolumes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/var/lib/linux-builder/cache-key.pem:/run/cache-key.pem:ro" ];
      description = "Volumes of the builder, as {option}`virtualisation.oci-containers.containers.<name>.volumes`.";
    };

    systems = mkOption {
      type = types.listOf types.str;
      default = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      description = ''
        Systems the builder builds for: x86_64-linux runs through Rosetta.
        Sets `nix.buildMachines.*.systems`.
      '';
    };

    maxJobs = mkOption {
      type = types.ints.positive;
      default = cfg.cpus;
      defaultText = literalExpression "config.nix.linux-builder.cpus";
      description = "Sets `nix.buildMachines.*.maxJobs`.";
    };

    speedFactor = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Sets `nix.buildMachines.*.speedFactor`.";
    };

    protocol = mkOption {
      type = types.str;
      default = "ssh-ng";
      description = "Sets `nix.buildMachines.*.protocol`.";
    };

    virtualization = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Expose virtualization to the builder, for `kvm` and `nixos-test`
        builds, as
        {option}`virtualisation.oci-containers.containers.<name>.apple-container.virtualization`.
        It needs an M3 or later: on older hosts the builder fails to start,
        so turn it off.
      '';
    };

    supportedFeatures = mkOption {
      type = types.listOf types.str;
      default = [
        "big-parallel"
        "benchmark"
      ]
      ++ optionals cfg.virtualization [
        "kvm"
        "nixos-test"
      ];
      defaultText = literalExpression ''[ "big-parallel" "benchmark" ] ++ lib.optionals config.nix.linux-builder.virtualization [ "kvm" "nixos-test" ]'';
      description = "Sets `nix.buildMachines.*.supportedFeatures`.";
    };

    mandatoryFeatures = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Sets `nix.buildMachines.*.mandatoryFeatures`.";
    };

    name = mkOption {
      internal = true;
      type = types.str;
      default = "linux-builder";
      description = "The builder's container.";
    };

    stateDir = mkOption {
      internal = true;
      type = types.str;
      default = "/var/lib/linux-builder";
      description = "Where activation keeps the builder's keys and /config.";
    };

    provision = mkOption {
      internal = true;
      readOnly = true;
      type = types.package;
      default = provision;
      description = "Activation's script, which provisions the host-side material.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.nix.enable;
        message = "nix.linux-builder needs nix.enable.";
      }
      {
        assertion = cfg.image == null || cfg.imageFile == null;
        message = "nix.linux-builder.image and nix.linux-builder.imageFile exclude each other.";
      }
      {
        assertion = cfg.image != null || cfg.imageFile != null;
        message = "nix.linux-builder needs nix.linux-builder.imageFile or nix.linux-builder.image.";
      }
      {
        assertion = cfg.imageFile == null || cfg.imageFile ? imageRef;
        message = ''nix.linux-builder.imageFile needs the ref its archive names: `archive // { imageRef = "…"; }`.'';
      }
      {
        assertion = cfg.onDemand.enable || domain != null;
        message = "nix.linux-builder: without onDemand, the builder is reached by name, which needs virtualisation.apple-container.system.dns.defaultDomain.";
      }
    ];

    virtualisation.apple-container.volume = mkIf (!cfg.ephemeral) { "${cfg.name}-store" = { }; };

    virtualisation.oci-containers.containers.${cfg.name} = {
      image = ref;
      inherit (cfg) imageFile cpus memory;
      privileged = true;
      labels.${ownerLabel} = mkDefault "nixham";
      environment = mkIf (nixConfig != "") { NIX_CONFIG = nixConfig; };
      volumes = [
        "${stateDir}/config:/config:ro"
      ]
      ++ optional (cfg.nixConfSecretFile != null) "${cfg.nixConfSecretFile}:${secretNixConf}:ro"
      ++ optional (!cfg.ephemeral) "${cfg.name}-store:/persist"
      ++ cfg.extraVolumes;
      # Their mounts over /proc stop Nix's sandbox mounting its own.
      extraOptions = [
        "--masked-path"
        "NONE"
        "--read-only-path"
        "NONE"
      ];
      apple-container = {
        arch = "arm64";
        rosetta = true;
        inherit (cfg) virtualization;
        kernel = "${cfg.kernel}/vmlinux-arm64";
        preStart = "${preStart} ${
          escapeShellArgs [
            cfg.name
            ownerLabel
            container.labels.${ownerLabel}
            (cfg.package.imageName or "linux-builder")
            ref
          ]
        }";
        onDemand = mkIf cfg.onDemand.enable {
          enable = true;
          idleTimeout = mkDefault 0;
          ports = [ "127.0.0.1:${toString cfg.onDemand.port}:22" ];
        };
      };
    };

    system.activationScripts.postActivation.text = ''
      if [ -n "$(${provision} ${
        escapeShellArgs (
          [
            stateDir
            user
            cfg.sshUser
            host
            cfg.sshKeyFile
          ]
          ++ optional (cfg.userSshKeyFile != null) cfg.userSshKeyFile
        )
      })" ]; then
        echo >&2 "linux-builder: stopping the builder, whose /config changed"
        /bin/launchctl asuser "$(id -u ${escapeShellArg user})" /usr/bin/sudo -H -u ${escapeShellArg user} -- \
          ${runtime.package}/bin/container stop ${escapeShellArg cfg.name} >/dev/null 2>&1 || true
      fi
    '';

    environment.etc."ssh/ssh_config.d/100-linux-builder.conf".text =
      let
        block = header: lines: header + "\n" + concatMapStrings (l: "  ${l}\n") lines;
        options =
          optionals cfg.onDemand.enable [
            "HostName 127.0.0.1"
            "Port ${toString cfg.onDemand.port}"
          ]
          ++ [
            "User ${cfg.sshUser}"
            "HostKeyAlias ${host}"
            "UserKnownHostsFile ${stateDir}/known_hosts"
            "StrictHostKeyChecking yes"
            "IdentitiesOnly yes"
          ];
      in
      # originalhost: host would match the HostName above.
      if cfg.userSshKeyFile == null then
        block "Host ${host}" (options ++ [ "IdentityFile ${cfg.sshKeyFile}" ])
      else
        block "Host ${host}" options
        + block "Match originalhost ${host} localuser root" [ "IdentityFile ${cfg.sshKeyFile}" ]
        + block "Match originalhost ${host} !localuser root" [ "IdentityFile ${cfg.userSshKeyFile}" ];

    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;
    nix.buildMachines = [
      {
        hostName = host;
        inherit (cfg)
          mandatoryFeatures
          maxJobs
          protocol
          speedFactor
          sshUser
          supportedFeatures
          systems
          ;
      }
    ];
  };
}
