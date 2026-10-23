{ lib, stdenvNoCC }:
stdenvNoCC.mkDerivation {
  pname = "nixham-skill-nixify";
  version = "1";

  meta.description = "Agent skill that sets up or normalises Nix configuration in a repo";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference ./. ./package.nix;
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/skills/nixify
    cp -r . $out/skills/nixify
    runHook postInstall
  '';
}
