{
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
    passthru = {
      inherit kernel;
      tests = callPackage ./tests { inherit linux-builder nixham; };
    };
  };
in
linux-builder
