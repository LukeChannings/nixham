{
  callPackage,
  path,
  linux-builder,
  nixham,
}:
let
  makeTest = callPackage ../../../lib/testing/make-test.nix { };
  apple-container-kernel = callPackage ../../apple-container-kernel/package.nix { inherit path; };
  args = { inherit makeTest linux-builder apple-container-kernel; };
in
{
  check = callPackage ./check.nix args;
  kernel = callPackage ./kernel.nix args;
  e2e = callPackage ./e2e.nix (args // { inherit nixham; });
}
