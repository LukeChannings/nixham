# Builds the kernel, so only where it builds natively.
{
  makeTest,
  linux-builder,
  apple-container-kernel,
  nix,
  ...
}:
makeTest {
  name = "linux-builder-kernel";
  inputs = [ nix ];
  meta.platforms = [ "aarch64-linux" ];
  tests."the pinned kernel is this tree's apple-container-kernel" = ''
    built="$(nix-hash --type sha256 --base32 ${apple-container-kernel})"
    [ "$built" = ${linux-builder.kernel.outputHash} ] ||
      fail "pin $built in packages/linux-builder/kernel.nix"
  '';
}
