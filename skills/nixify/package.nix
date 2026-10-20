{ lib, stdenvNoCC }:
stdenvNoCC.mkDerivation {
  pname = "nixham-skill-nixify";
  version = "0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference ./. ./package.nix;
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/skills/nixify
    cp -r . $out/share/skills/nixify
    runHook postInstall
  '';
}
