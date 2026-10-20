{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "git+https://git.lix.systems/lix-project/flake-compat";
    flake-compat.flake = false;
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        treefmt = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
      in
      {
        packages = { };

        formatter = treefmt.config.build.wrapper;

        checks.formatting = treefmt.config.build.check self;

        devShells.default = pkgs.mkShell { };
      }
    );
}
