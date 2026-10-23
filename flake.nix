{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    flake-compat.url = "git+https://git.lix.systems/lix-project/flake-compat";
    flake-compat.flake = false;
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
    # No nixpkgs follows: built on its own nixpkgs, socktainer is substituted
    # from its CI's cache rather than rebuilt against the host's Xcode.
    socktainer.url = "github:LukeChannings/socktainer";
    # Test-only: evaluates the nix-darwin modules.
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, ... }:
      {
        imports = [
          flake-parts.flakeModules.modules
          inputs.treefmt-nix.flakeModule
        ];

        systems = [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-darwin"
          "x86_64-linux"
        ];

        flake.modules.darwin = import ./modules/nix-darwin { nixham = self; };
        flake.darwinModules = self.modules.darwin;

        perSystem =
          {
            config,
            pkgs,
            lib,
            system,
            ...
          }:
          {
            packages = {
              apple-container-kernel = pkgs.callPackage ./packages/apple-container-kernel/package.nix {
                inherit (pkgs) path;
              };
              linux-builder = pkgs.callPackage ./packages/linux-builder/package.nix {
                nixham = self;
              };
              linux-builder-image = pkgs.callPackage ./packages/linux-builder-image/package.nix {
                inherit (pkgs) path;
                inherit (inputs) nix2container;
              };
              skill-nixify = pkgs.callPackage ./skills/nixify/package.nix { };
            };

            treefmt = ./treefmt.nix;

            # The configfile derivation asserts CONFIG_KVM/CONFIG_EROFS_FS survive
            # olddefconfig — a cheap regression check without building the kernel.
            checks = lib.optionalAttrs (system == "aarch64-linux") {
              apple-container-kernel-config = config.packages.apple-container-kernel.configfile;
            };

            devShells.default = pkgs.mkShell {
              packages = with pkgs; [
                (bats.withLibraries (p: [
                  p.bats-support
                  p.bats-assert
                ]))
                jq
                just
                # bats --jobs
                parallel
                config.treefmt.build.wrapper
              ];
            };
          };
      }
    );
}
