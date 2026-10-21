# Rosetta execution: the builder advertises x86_64-linux and runs those
# derivations under Rosetta, which apple/container exposes as a virtiofs share
# tagged `rosetta` -- present ONLY when the container was started with
# `--rosetta`.
#
# apple/container registers Rosetta with binfmt flags OCF -- no P -- so the
# kernel discards the caller's argv[0] on every x86_64 exec, and a
# python.withPackages env (argv[0] is how CPython finds its own prefix)
# silently collapses to the base interpreter. We register an argv0-preserving
# shim in its place (see rosetta-argv0-shim.c).
#
# Two invariants:
#
# - Never serve a broken x86_64 builder. Without the share, or without our
#   registration, `rosetta.service` fails and its FailureAction stops the
#   container; sshd and nix-daemon require it, so nothing is served meanwhile.
# - A failed registration never leaves the guest unable to execute x86_64 at
#   all. binfmt_misc matches the most recently registered entry first, so ours
#   is added alongside apple/container's, and apple/container's is dropped only
#   once ours is verified. Stock systemd-binfmt would flush every entry
#   (apple/container's included) *before* registering, so it is pointed at our
#   file explicitly, which skips the flush, and never unregisters on stop.
{
  config,
  pkgs,
  utils,
  ...
}:

let
  rosettaDir = "/run/rosetta";
  binfmtDir = "/proc/sys/fs/binfmt_misc";
  entry = "rosetta-argv0";

  # Name of apple/container's own x86_64 registration.
  appleEntry = "x86_64";

  qemuBinfmtP = pkgs.wrapQemuBinfmtP "qemu-x86_64-binfmt-P" "${pkgs.qemu-user}/bin/qemu-x86_64";

  shim = pkgs.callPackage ./rosetta-argv0-shim.nix {
    rosetta = "${rosettaDir}/rosetta";
    qemuBinfmtP = "${qemuBinfmtP}/bin/qemu-x86_64-binfmt-P";
  };
in
{
  # Mounted by stage 2 like /run/wrappers: as an fstab mount, systemd holds the
  # job back ~1s behind its mountinfo rate limit, delaying sysinit and sshd.
  # A failed mount here is only reported; rosetta.service is what stops the
  # container.
  boot.specialFileSystems.${rosettaDir} = {
    device = "rosetta";
    fsType = "virtiofs";
    options = [ "ro" ];
  };

  boot.binfmt.registrations.${entry} = {
    inherit (utils.binfmtMagics.x86_64-linux) magicOrExtension mask;
    interpreter = "${shim}/bin/rosetta-argv0-shim";
    # P hands the shim the caller's argv[0]; F opens it at registration, so
    # build sandboxes need not contain it (only what it execs: see nix.settings).
    preserveArgvZero = true;
    fixBinary = true;
    wrapInterpreterInShell = false;
  };

  systemd.services.systemd-binfmt = {
    wants = [ "proc-sys-fs-binfmt_misc.mount" ];
    after = [ "proc-sys-fs-binfmt_misc.mount" ];
    serviceConfig = {
      ExecStart = [
        ""
        "${config.systemd.package}/lib/systemd/systemd-binfmt /etc/binfmt.d/nixos.conf"
      ];
      ExecStop = [ "" ];
    };
  };

  # Wants, not Requires, on systemd-binfmt: a failed dependency would only
  # cancel this unit, never fail it, and FailureAction would not fire.
  systemd.services.rosetta = {
    description = "Rosetta x86_64-linux execution";
    wantedBy = [ "sysinit.target" ];
    requiredBy = [
      "sshd.service"
      "nix-daemon.service"
    ];
    wants = [ "systemd-binfmt.service" ];
    after = [ "systemd-binfmt.service" ];
    before = [
      "sysinit.target"
      "shutdown.target"
      "sshd.service"
      "nix-daemon.service"
    ];
    conflicts = [ "shutdown.target" ];
    unitConfig = {
      DefaultDependencies = false;
      FailureAction = "exit";
      FailureActionExitStatus = 1;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [ pkgs.util-linux ];
    script = ''
      fatal() {
        echo "linux-builder: FATAL: $*" >&2
        exit 1
      }

      mountpoint -q ${rosettaDir} \
        || fatal "no 'rosetta' virtiofs share at ${rosettaDir}; start the container with --rosetta"
      [ -x ${rosettaDir}/rosetta ] || fatal "${rosettaDir} has no rosetta binary"

      if [ "$(head -n1 ${binfmtDir}/${entry} 2>/dev/null)" != enabled ]; then
        fatal "the argv0-preserving x86_64 binfmt handler is not registered; see systemd-binfmt.service"
      fi
      grep -qx 'flags: PF' ${binfmtDir}/${entry} \
        || fatal "${entry} is registered without flags PF: $(grep '^flags' ${binfmtDir}/${entry})"

      # Ours already matches first; dropping apple/container's is tidiness.
      if [ -e ${binfmtDir}/${appleEntry} ]; then
        echo -1 > ${binfmtDir}/${appleEntry} \
          || echo "linux-builder: WARN: could not drop apple/container's x86_64 binfmt handler" >&2
      fi
    '';
  };

  nix.settings = {
    extra-platforms = [ "x86_64-linux" ];
    # What the shim execs inside a build sandbox. Nix expands a store path
    # listed here to its whole closure, so qemu rides along with its wrapper.
    extra-sandbox-paths = [
      rosettaDir
      "${qemuBinfmtP}"
    ];
  };
}
