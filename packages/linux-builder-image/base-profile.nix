{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  inherit (lib) mkDefault mkForce;

  # What `container run` passed in, read once at boot: /config, copied here,
  # and NIX_CONFIG plus NIX_CONFIG_* (systemd passes no environment on).
  # Root-only and in RAM, so private keys and tokens never reach a disk.
  snapshot = "/run/linux-builder";

  runtimeConfig = pkgs.writeShellScript "linux-builder-runtime-config" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    log() { echo "linux-builder: $*" >&2; }

    # warn_missing_includes <file> <as> [depth]: recursively, resolving as Nix
    # does; the depth bound keeps an include cycle from hanging the boot.
    warn_missing_includes() {
      local file=$1 as=$2 depth=''${3:-0} kw target
      while read -r kw target _; do
        [ "$kw" = include ] || [ "$kw" = '!include' ] || continue
        [[ $target == /* ]] || target="$(dirname "$file")/$target"
        if [ ! -e "$target" ]; then
          log "WARN $as includes $target, which does not exist"
        elif [ "$depth" -lt 8 ]; then
          warn_missing_includes "$target" "$target" $((depth + 1))
        fi
      done <"$file"
    }

    umask 077
    rm -rf ${snapshot}
    # Traversable, not listable: builder's own nix stats the root-only
    # includes (and skips them), sshd reads authorized_keys.d as the user.
    mkdir -m 0711 ${snapshot}
    if [ -d /config ]; then
      cp -RL /config ${snapshot}/config || log "WARN could not copy all of /config"
      chown -R 0:0 ${snapshot}/config
      chmod 0711 ${snapshot}/config
      if [ -d ${snapshot}/config/ssh/authorized_keys.d ]; then
        chmod 0711 ${snapshot}/config/ssh
        chmod -R go+rX ${snapshot}/config/ssh/authorized_keys.d
      fi
    fi

    applied=()
    {
      [ -z "''${NIX_CONFIG:-}" ] || { printf '%s\n' "$NIX_CONFIG"; applied+=(NIX_CONFIG); }
      for v in $(printf '%s\n' "''${!NIX_CONFIG_@}" | LC_ALL=C sort); do
        [ -z "''${!v}" ] || { printf '%s\n' "''${!v}"; applied+=("$v"); }
      done
    } >${snapshot}/environment.conf
    [ ''${#applied[@]} -eq 0 ] || log "applied Nix config from ''${applied[*]}"

    [ ! -f ${snapshot}/config/nix.conf ] || warn_missing_includes ${snapshot}/config/nix.conf /config/nix.conf
    warn_missing_includes ${snapshot}/environment.conf "the environment"
  '';
in
{
  imports = [
    "${modulesPath}/profiles/docker-container.nix"
    "${modulesPath}/profiles/perlless.nix"
    ./persistent-store.nix
  ];

  # x86_64-linux execution: apple/container exposes Rosetta as a virtiofs
  # share tagged `rosetta` -- present only when started with `--rosetta`.
  # The stock module registers it as the x86_64 binfmt interpreter with
  # preserveArgvZero; stock systemd-binfmt's flush drops apple/container's
  # own registration, whose missing P flag discards the caller's argv[0]
  # and silently breaks python.withPackages envs.
  virtualisation.rosetta.enable = true;
  # nofail: without the share the container still serves aarch64-linux
  # builds (x86_64 exec is simply unavailable; systemd-binfmt fails).
  fileSystems."/run/rosetta".options = [
    "ro"
    "nofail"
  ];
  # Mounted by stage 2 like /run/wrappers: as a plain fstab mount, systemd
  # holds the job back ~1s behind its mountinfo rate limit, delaying sysinit
  # and sshd (measured 2.6s to nix-daemon vs 1.7s). The fstab unit then
  # finds it mounted and queues nothing; it also guarantees the share is up
  # before systemd-binfmt opens the interpreter (the F flag).
  boot.specialFileSystems."/run/rosetta" = {
    device = "rosetta";
    fsType = "virtiofs";
    options = [ "ro" ];
  };
  # Stock systemd-binfmt reaches binfmt_misc through the automount trap,
  # whose triggered mount job stalls ~1s behind systemd's mountinfo rate
  # limit, holding back sysinit and sshd. Wanting the mount directly makes
  # it an early boot job instead.
  systemd.services.systemd-binfmt = {
    wants = [ "proc-sys-fs-binfmt_misc.mount" ];
    after = [ "proc-sys-fs-binfmt_misc.mount" ];
  };

  system.installer.channel.enable = false;
  installer.cloneConfig = false;

  nixpkgs.hostPlatform = mkDefault "aarch64-linux";
  system.stateVersion = mkDefault lib.trivial.release;

  networking.hostName = mkDefault "linux-builder";

  networking.useDHCP = false;
  networking.resolvconf.enable = false;

  # The runtime owns /etc/resolv.conf, writing it into the rootfs, where the
  # /etc overlay (perlless.nix) would hide it: carry it into the overlay's
  # upper before the overlay is mounted.
  system.activationScripts.runtime-resolv-conf.text = ''
    if [ -f /etc/resolv.conf ] && ! mountpoint -q /etc; then
      mkdir -p /.rw-etc/upper
      cp /etc/resolv.conf /.rw-etc/upper/resolv.conf
    fi
  '';
  system.activationScripts.etc.deps = [ "runtime-resolv-conf" ];

  systemd.suppressedSystemUnits = [
    "systemd-udevd.service"
    "systemd-udevd-control.socket"
    "systemd-udevd-kernel.socket"
    "systemd-udevd-varlink.socket"
  ];
  networking.firewall.enable = false;

  nix.channel.enable = false;
  boot.enableContainers = false;
  environment.defaultPackages = [ ];
  fonts.fontconfig.enable = false;
  programs.nano.enable = false;

  system.switch.enable = false;
  system.disableInstallerTools = true;
  systemd.shutdownRamfs.enable = false;
  boot.kexec.enable = false;
  boot.bcache.enable = false;
  users.manageLingering = false;
  security.sudo.enable = mkDefault false;

  boot.specialFileSystems."/run/wrappers" = {
    fsType = "tmpfs";
    options = [
      "nodev"
      "mode=755"
      "size=${config.security.wrapperDirSize}"
    ];
  };

  systemd.services.nix-daemon.wantedBy = [ "multi-user.target" ];

  security.pam.services.sshd.startSession = mkForce false;

  systemd.services.tcp-quickack = {
    description = "Disable delayed ACKs on the runtime's routes";
    wantedBy = [ "network.target" ];
    before = [ "network.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.iproute2 ];
    script = ''
      ip -4 route show | while read -r route; do
        ip route change $route quickack 1 || true
      done
    '';
  };

  services.openssh = {
    enable = true;
    startWhenNeeded = false;
    authorizedKeysFiles = [ "${snapshot}/config/ssh/authorized_keys.d/%u" ];
    settings = {
      PermitRootLogin = mkDefault "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AcceptEnv = [ "NIX_*" ];
      MaxStartups = "100:30:200";
      MaxSessions = 100;
      PerSourcePenalties = "no";
    };
  };

  # As nixpkgs' profiles/nix-builder.nix, the Darwin builder VM.
  users.users.builder.isNormalUser = true;

  # After ./persistent-store.nix's mkBefore: its seeding never sees this.
  boot.postBootCommands = ''
    ${runtimeConfig}
  '';

  nix.extraOptions = ''
    !include ${snapshot}/config/nix.conf
    !include ${snapshot}/environment.conf
  '';

  nix.settings = {
    trusted-users = [ "builder" ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    sandbox = true;
    min-free = mkDefault (40 * 1024 * 1024 * 1024);
    max-free = mkDefault (120 * 1024 * 1024 * 1024);
  };
}
