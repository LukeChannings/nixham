{
  lib,
  callPackage,
  installShellFiles,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "launchctl-completions";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./_launchctl
      ./launchctl.fish
    ];
  };
  nativeBuildInputs = [ installShellFiles ];
  installPhase = ''
    runHook preInstall
    installShellCompletion --zsh _launchctl --fish launchctl.fish
    runHook postInstall
  '';
  passthru.tests.check = callPackage ./tests/check.nix {
    launchctl-completions = finalAttrs.finalPackage;
  };
  meta = {
    description = "zsh and fish completions for macOS's launchctl";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
