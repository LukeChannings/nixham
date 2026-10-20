{ lib, stdenvNoCC }:
stdenvNoCC.mkDerivation {
  pname = "nixham-skill-nixify";
  version = "1";

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
