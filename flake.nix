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
            ...
          }:
          let
            testing = pkgs.callPackage ./lib/testing { };
          in
          {
            packages = {
              apple-container-kernel = pkgs.callPackage ./packages/apple-container-kernel/package.nix {
                inherit (pkgs) path;
              };
              docs = pkgs.callPackage ./lib/docs {
                nixham = self;
                treefmt = config.treefmt.package;
                treefmtConfig = config.treefmt.build.configFile;
                revision = self.rev or null;
              };
              launchctl-completions = pkgs.callPackage ./packages/launchctl-completions/package.nix { };
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

            legacyPackages.tests =
              let
                callTest =
                  path:
                  lib.callPackageWith (
                    pkgs
                    // config.packages
                    // {
                      inherit (testing) makeTest;
                      darwin = pkgs.callPackage ./lib/testing/nix-darwin.nix {
                        inherit (inputs) nix-darwin;
                        inherit (self) darwinModules;
                      };
                    }
                  ) path { };
                module = ./modules/nix-darwin/virtualisation;
              in
              {
                niks3-pin.check = callTest ./.forgejo/actions/niks3-pin/tests/check.nix;
                niks3-push.check = callTest ./.forgejo/actions/niks3-push/tests/check.nix;
                oci-publish.check = callTest ./.forgejo/actions/oci-publish/tests/check.nix;
                setup-nix-shell.check = callTest ./.forgejo/actions/setup-nix-shell/tests/check.nix;
                acme.check = callTest ./modules/nix-darwin/security/acme/tests/check.nix;
                apple-container = {
                  check = callTest (module + "/apple-container/tests/check.nix");
                  volumes-root = callTest (module + "/apple-container/tests/volumes-root.nix");
                  e2e = callTest (module + "/apple-container/tests/e2e.nix");
                };
                nginx.check = callTest ./modules/nix-darwin/services/nginx/tests/check.nix;
                oci-containers = {
                  check = callTest (module + "/oci-containers/tests/check.nix");
                  e2e = callTest (module + "/oci-containers/tests/e2e.nix");
                };
                launchctl-completions = config.packages.launchctl-completions.tests;
                launchd = {
                  logging = callTest ./modules/nix-darwin/launchd/logging/tests/check.nix;
                  wait4path = callTest ./modules/nix-darwin/launchd/wait4path/tests/check.nix;
                };
                pki-keychain.check = callTest ./modules/nix-darwin/security/pki-keychain/tests/check.nix;
                virtual-interfaces.check = callTest ./modules/nix-darwin/networking/virtual-interfaces/tests/check.nix;
                zsh.check = callTest ./modules/nix-darwin/programs/zsh/tests/check.nix;
                linux-builder = config.packages.linux-builder.tests // {
                  module = callTest ./modules/nix-darwin/nix/linux-builder/tests/check.nix;
                  pre-start = callTest ./modules/nix-darwin/nix/linux-builder/tests/pre-start.nix;
                  provision = callTest ./modules/nix-darwin/nix/linux-builder/tests/provision.nix;
                  module-e2e = callTest ./modules/nix-darwin/nix/linux-builder/tests/e2e.nix;
                };
              }
              // lib.mapAttrs (_: p: p.tests) {
                inherit (config.packages) apple-container-kernel linux-builder-image;
              };

            legacyPackages.selectTests = testing.select config.legacyPackages.tests;

            checks = testing.ofKind "check" config.legacyPackages.tests;

            devShells.default = pkgs.mkShell {
              packages = with pkgs; [
                just
                config.treefmt.build.wrapper
              ];
            };
          };
      }
    );
}
