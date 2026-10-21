# The persistent store volume: the builder's /nix outlives both container
# restarts and image upgrades by living in an overlay whose writable upper is
# on the apple/container volume mounted at /persist.
#
# All of it happens in stage 2's postBootCommands, after activation and
# before systemd is exec'd, so nothing that touches /nix (nix-daemon, GC
# roots via tmpfiles, sshd-keygen, …) can start before the overlay is up.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) concatStringsSep mkBefore mkForce;

  persist = "/persist";

  # Written into the image root by ./default.nix. Unlike
  # docker-container.nix's register-nix-paths it is never consumed: the DB it
  # seeds may live on the volume, and a fresh volume under the same image needs
  # seeding again.
  registration = "/nix-path-registration";

  # Which system the Nix DB was last seeded (and reconciled) for. It sits next
  # to the DB, so it lives exactly as long as the DB does: on the volume when
  # persistent, in the container's rootfs when not.
  seededStamp = "/nix/var/nix/linux-builder-seeded-system";

  # Written through /nix by the shutdown hook, so it lands in the overlay's
  # upper: by then systemd has unmounted /persist itself (the overlay holds
  # only a private clone of it), but the volume is still reachable via /nix.
  cleanMarker = "var/nix/linux-builder-clean-shutdown";

  nixBin = "${config.nix.package.out}/bin";

  storeMountOpts = concatStringsSep "," config.boot.nixStoreMountOpts;

  persistStore = pkgs.writeShellScript "linux-builder-persistent-store" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
      ]
    }
    # Nothing here builds, and userborn has yet to create the nixbld group.
    export NIX_CONFIG="build-users-group ="

    log() { echo "linux-builder: $*" >&2; }

    # /nix as an overlay: the image's /nix (bind-mounted aside) is the
    # read-only lower, the volume holds upper and work. Stage 2 already applied
    # the store mount options to the image's /nix/store; the overlay hides
    # that mount, so apply them again on top.
    persistent=""
    if mountpoint -q ${persist}; then
      # Left by the shutdown hook below. A used volume without it was last
      # torn down without systemd's shutdown path reaching the hook.
      if [ -d ${persist}/upper ] && [ ! -e ${persist}/upper/${cleanMarker} ]; then
        log "WARN the store volume's previous shutdown was not clean (no /nix/${cleanMarker})"
      fi
      rm -f ${persist}/upper/${cleanMarker}
      mkdir -p ${persist}/upper ${persist}/work /nix/.ro
      if mount --bind /nix /nix/.ro \
        && mount -t overlay overlay \
          -o lowerdir=/nix/.ro,upperdir=${persist}/upper,workdir=${persist}/work /nix; then
        persistent=1
        chown -f 0:30000 /nix/store
        chmod -f 1775 /nix/store
        ${lib.optionalString (storeMountOpts != "") ''
          mount --bind /nix/store /nix/store \
            && mount -o remount,${storeMountOpts},bind /nix/store \
            || log "WARN could not apply the store mount options (${storeMountOpts}) to the overlay"
        ''}
      else
        umount /nix/.ro 2>/dev/null || true
        log "ERROR could not mount the ${persist} overlay over /nix; THE STORE IS EPHEMERAL"
      fi
    else
      log "WARN ${persist} is not a mountpoint (no store volume attached); THE STORE IS EPHEMERAL and is lost when the container is removed"
    fi

    # Seed the DB with the image closure. Without it the baked closure is
    # unknown to the (possibly volume-backed) DB, and a GC would delete the
    # builder's own system out of the merged view. Only needed when the DB
    # has not yet been seeded for this system, which keeps it off every
    # same-image restart's path to sshd.
    system="$(readlink -f /run/booted-system)"
    if [ "$(cat ${seededStamp} 2>/dev/null || true)" != "$system" ]; then
      log "seeding the Nix DB for $system"
      if ${nixBin}/nix-store --load-db < ${registration}; then
        # nixos-rebuild-style "system" profile; older generations point at
        # previous images' systems, which are gone from this image's store.
        ${nixBin}/nix-env -p /nix/var/nix/profiles/system --set "$system" \
          && ${nixBin}/nix-env -p /nix/var/nix/profiles/system --delete-generations old >/dev/null \
          || log "WARN could not set the system profile"

        # The volume outlives the image it is layered on: an image change swaps
        # the lower for different store paths, leaving the previous image's
        # paths valid in the persisted DB but absent from the store. Nix trusts
        # validity without re-hashing, so these phantoms would later surface on
        # the host as `hash mismatch importing path`. --repair without
        # --check-contents only stats paths: drop the ones nothing references,
        # re-substitute the ones still referenced.
        if [ -n "$persistent" ]; then
          log "reconciling the persisted Nix DB against the new image"
          ${nixBin}/nix-store --verify --repair || log "WARN DB reconcile incomplete"
        fi

        mkdir -p "$(dirname ${seededStamp})"
        printf '%s\n' "$system" > ${seededStamp}
      else
        log "ERROR could not seed the Nix DB from ${registration}"
      fi
    fi
  '';

  # systemd, detecting a container, neither syncs nor unmounts file systems on
  # its way out (src/shutdown/shutdown.c): whatever is still in the page cache
  # when it exits is the runtime's to flush, and a volume torn down dirty has
  # Nix serving damaged store paths as valid (the hand-rolled image's `hash
  # mismatch importing path`). apple/container 1.1.0's vminitd does unmount
  # the volume cleanly once the container exits, but that is not a contract;
  # this is. The system-shutdown hooks run in containers too, after every
  # other process is gone and just before systemd-shutdown exits, so this is
  # the last word on the volume. It leaves the clean-shutdown marker the next
  # boot checks for.
  syncVolume = pkgs.writeShellScript "linux-builder-sync-volume" ''
    echo "$1" > /nix/${cleanMarker}
    ${pkgs.coreutils}/bin/sync
  '';
in
{
  boot.postBootCommands = mkBefore ''
    ${persistStore}
  '';

  # Superseded by the seeding above, which has to run against the overlay.
  systemd.services.register-nix-paths.enable = mkForce false;

  systemd.shutdown.linux-builder-sync-volume = syncVolume;

  # Stable across restarts and image upgrades when the volume is attached;
  # without it /persist is a plain rootfs directory and the key as ephemeral
  # as the store.
  services.openssh.hostKeys = [
    {
      type = "ed25519";
      path = "${persist}/ssh/ssh_host_ed25519_key";
    }
  ];
}
