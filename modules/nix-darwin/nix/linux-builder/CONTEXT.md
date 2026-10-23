# linux-builder

A Linux Nix builder that macOS delegates Linux builds to over SSH, realised as a NixOS container image run under apple-container. Spans the image (`packages/linux-builder-image`), the ephemeral CLI (`packages/linux-builder`), and the resident nix-darwin module (`modules/nix-darwin/nix/linux-builder`).

## Language

**linux-builder**:
The builder itself: the container named `linux-builder` that serves `aarch64-linux` (and, via Rosetta, `x86_64-linux`) builds over SSH.
_Avoid_: darwin-builder, builder VM

**linux-builder-image**:
The OCI image of a NixOS system purpose-built to act as the linux-builder. Configured at boot via the /config contract, never by rebuild alone.

**/config contract**:
The image's runtime configuration surface: a read-only bind mount at `/config` (SSH `authorized_keys.d/<user>`, host key + optional cert, `trusted_user_ca_keys`, `nix.conf`) plus `NIX_CONFIG`/`NIX_CONFIG_*` environment variables, snapshotted once at boot into root-only RAM.
