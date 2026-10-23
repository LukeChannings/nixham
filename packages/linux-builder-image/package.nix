# The builder image: the NixOS system of ./base-profile.nix plus
# `modules`, as the oci-archive `container image load` takes. A single layer
# holds the system's closure; the archive is a streaming re-pack of it.
{
  callPackage,
  path,
  # The nix2container flake input (pinned in flake.lock).
  nix2container,
  modules ? [ ],
}:
let
  nixos = import (path + "/nixos/lib/eval-config.nix") {
    system = null;
    modules = [ ./base-profile.nix ] ++ modules;
  };

  inherit (nixos) pkgs;
  inherit (nixos.config.system.build) toplevel;
  n2c = import nix2container { inherit pkgs; };

  image = n2c.nix2container.buildImage {
    name = "linux-builder";
    tag = builtins.substring 0 32 (baseNameOf toplevel);
    # Seeds the Nix DB on boot (./persistent-store.nix).
    copyToRoot = pkgs.runCommand "linux-builder-root" { } ''
      mkdir $out
      cp ${pkgs.closureInfo { rootPaths = [ toplevel ]; }}/registration $out/nix-path-registration
    '';
    config = {
      Entrypoint = [ "${toplevel}/init" ];
      StopSignal = "SIGRTMIN+3";
    };
  };

  imageRef = "${image.imageName}:${image.imageTag}";

  linux-builder-image =
    pkgs.runCommand "linux-builder-oci.tar"
      {
        meta = {
          description = "OCI image of a NixOS Linux Nix builder";
          license = pkgs.lib.licenses.mit;
        };
        passthru = {
          nixosConfig = nixos.config;
          inherit imageRef image;
          inherit (image) imageTag;
          tests = callPackage ./tests { inherit linux-builder-image nix2container; };
        };
      }
      ''
        ${n2c.skopeo-nix2container}/bin/skopeo --insecure-policy copy --tmpdir "$TMPDIR" \
          nix:${image} oci-archive:$out:${imageRef}
      '';
in
linux-builder-image
