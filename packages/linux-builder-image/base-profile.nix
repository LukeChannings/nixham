{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  inherit (lib) mkDefault mkForce;
in
{
  imports = [
    "${modulesPath}/profiles/docker-container.nix"
    "${modulesPath}/profiles/perlless.nix"
    ./persistent-store.nix
    ./rosetta.nix
  ];

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
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AcceptEnv = [ "NIX_*" ];
      MaxStartups = "100:30:200";
      MaxSessions = 100;
      PerSourcePenalties = "no";
    };
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    sandbox = true;
    min-free = mkDefault (40 * 1024 * 1024 * 1024);
    max-free = mkDefault (120 * 1024 * 1024 * 1024);
  };
}
