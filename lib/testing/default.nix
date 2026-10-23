{
  lib,
  callPackage,
  stdenv,
}:
let
  # tests.<component>.<scope> -> { "<component>-<scope>" = test; }, for the
  # tests of `kind` that run on this platform. Plain derivations are checks.
  ofKind =
    kind:
    lib.concatMapAttrs (
      component:
      lib.concatMapAttrs (
        scope: test:
        lib.optionalAttrs
          (
            lib.isDerivation test
            && (test.kind or "check") == kind
            && lib.meta.availableOn stdenv.hostPlatform test
          )
          {
            "${component}-${scope}" = test;
          }
      )
    );
in
{
  makeTest = callPackage ./make-test.nix { };

  inherit ofKind;

  # select <tests> <kind> [ "<component>" "<component>.<scope>" ... ]: all
  # tests of `kind` when none are named.
  select =
    tests: kind: names:
    ofKind kind (
      if names == [ ] then
        tests
      else
        lib.foldl' lib.recursiveUpdate { } (
          map (
            name:
            let
              path = lib.splitString "." name;
            in
            lib.setAttrByPath path (lib.getAttrFromPath path tests)
          ) names
        )
    );
}
