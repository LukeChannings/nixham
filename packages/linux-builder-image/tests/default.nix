{
  lib,
  callPackage,
  runCommand,
  jq,
  openssh,
  path,
  nix2container,
  linux-builder-image,
}:
let
  makeTest = callPackage ../../../lib/testing/make-test.nix { };
  apple-container-kernel = callPackage ../../apple-container-kernel/package.nix { inherit path; };

  # A test-only key, which no scope ever lets out of its builders.
  key = runCommand "linux-builder-image-test-key" { nativeBuildInputs = [ openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C lbi-probe -f $out/key
  '';

  # A scope: one file's worth of tests, booting the builders it needs.
  scope =
    name:
    {
      kind ? "e2e",
      helpers ? [ ],
      inputs ? [ ],
      setupFile ? "",
      teardownFile ? "",
      ...
    }@args:
    makeTest (
      args
      // {
        name = "linux-builder-image-${name}";
        inherit kind;
        helpers = [ ./helpers.sh ] ++ helpers;
        inputs = [ jq ] ++ inputs;
        setupFile = ''
          export LBI_KERNEL=${apple-container-kernel}/vmlinux-arm64 LBI_KEY=${key}
          use_key
        ''
        + setupFile;
        teardownFile = teardownFile + "unload_images\n";
      }
    );

  args = {
    inherit key path;
    image = linux-builder-image;
    variant = modules: callPackage ../package.nix { inherit path nix2container modules; };
  };
in
{
  check = callPackage ./check.nix { inherit makeTest linux-builder-image; };
}
// lib.genAttrs [
  "bare"
  "benchmark"
  "console"
  "herd"
  "keyed"
  "no-rosetta"
  "persist"
  "runtime-nix"
  "runtime-ssh"
] (name: import ./e2e/${name}.nix (args // { scope = scope name; }))
