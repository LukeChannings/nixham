{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "git+https://git.lix.systems/lix-project/flake-compat";
    flake-compat.flake = false;
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      nix2container,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        treefmt = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

        packages = {
          apple-container-kernel = pkgs.callPackage ./packages/apple-container-kernel/package.nix {
            inherit (pkgs) path;
          };
          linux-builder-image = pkgs.callPackage ./packages/linux-builder-image/package.nix {
            inherit (pkgs) path;
            inherit nix2container;
          };
          skill-nixify = pkgs.callPackage ./skills/nixify/package.nix { };
        };
      in
      {
        inherit packages;

        formatter = treefmt.config.build.wrapper;

        checks = {
          formatting = treefmt.config.build.check self;
        }
        # The configfile derivation asserts CONFIG_KVM/CONFIG_EROFS_FS survive
        # olddefconfig — a cheap regression check without building the kernel.
        // pkgs.lib.optionalAttrs (system == "aarch64-linux") {
          apple-container-kernel-config = packages.apple-container-kernel.configfile;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            (pkgs.bats.withLibraries (p: [
              p.bats-support
              p.bats-assert
            ]))
            pkgs.jq
            pkgs.just
            treefmt.config.build.wrapper
          ];
        };
      }
    );
}
