# The x86_64 binfmt interpreter the builder registers in place of
# apple/container's: see rosetta-argv0-shim.c. Static, so the LD_* variables a
# guest exec carries cannot reach the shim itself.
{
  stdenv,
  rosetta,
  qemuBinfmtP,
}:

stdenv.mkDerivation {
  name = "rosetta-argv0-shim";

  src = ./rosetta-argv0-shim.c;
  dontUnpack = true;
  dontInstall = true;

  buildInputs = [ (stdenv.cc.libc.static or null) ];

  buildPhase = ''
    runHook preBuild
    mkdir -p $out/bin
    $CC -o $out/bin/rosetta-argv0-shim -static -std=c99 -O2 \
        -DROSETTA='"${rosetta}"' \
        -DQEMU_BINFMT_P='"${qemuBinfmtP}"' \
        $src
    runHook postBuild
  '';

  passthru = { inherit rosetta qemuBinfmtP; };
}
