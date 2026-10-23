{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  jq,
  openssh,
  # This revision of nixham, whose kernel and image --build-* build.
  nixham,
}:
let
  kernel = callPackage ./kernel.nix { };
  linux-builder = writeShellApplication {
    name = "linux-builder";
    runtimeInputs = [
      coreutils
      jq
      openssh
    ];
    text = ''
      nixham=${nixham}
      kernel=${kernel}/vmlinux-arm64
    ''
    + builtins.readFile ./linux-builder.sh;
    meta = {
      description = "Run a shell or console against an ephemeral Linux Nix builder in Apple's container runtime";
      license = lib.licenses.mit;
    };
    passthru = {
      inherit kernel;
      tests = callPackage ./tests { inherit linux-builder nixham; };
    };
  };
in
linux-builder
