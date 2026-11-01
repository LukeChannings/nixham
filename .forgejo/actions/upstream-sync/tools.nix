let
  pkgs = (import ../../.. { }).inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
in
pkgs.buildEnv {
  name = "upstream-sync-tools";
  paths = with pkgs; [
    curl
    git
    jq
    openssh
  ];
}
