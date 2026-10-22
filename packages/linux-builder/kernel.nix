# ../apple-container-kernel as CI built it, pinned by its NAR hash and fetched
# from the binary cache CI pushes to: unlike the kernel, this costs nothing
# to evaluate, and anyone can fetch it, trusting the hash, not the cache.
{
  fetchurl,
  nix,
  zstd,
}:
let
  narHash = "19ddfq1wwi3mahhzbjfikxsfwdyz9y6bi8p5qsyn1pngh74d54f6";
in
fetchurl {
  name = "apple-container-kernel-6.18.5";
  url = "https://nix.channings.me/nar/${narHash}.nar.zst";
  sha256 = narHash;
  recursiveHash = true;
  downloadToTemp = true;
  nativeBuildInputs = [
    nix
    zstd
  ];
  postFetch = ''
    zstd -d <"$downloadedFile" | nix-store --restore "$out"
  '';
}
