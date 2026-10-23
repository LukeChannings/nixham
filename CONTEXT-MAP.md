# Context Map

Nixham hosts many unrelated components (nix-darwin modules, NixOS modules, home-manager modules, packages, skills, CI actions). Each cohesive component is its own context, documented where it lives.

## Contexts

- [nixham](./CONTEXT.md) — language shared by every context, e.g. testing. Repo-wide decisions live in [docs/adr](./docs/adr/).
- [apple-container](./modules/nix-darwin/virtualisation/apple-container/CONTEXT.md) — Apple's `container` runtime on macOS: the runtime module, kernel provisioning, and the socktainer Docker-API shim. Also home of `packages/apple-container-kernel`.
- oci-containers (`modules/nix-darwin/virtualisation/oci-containers/`) — declarative OCI containers for nix-darwin, built on apple-container; option-compatible with NixOS's `virtualisation.oci-containers`.
- [linux-builder](./modules/nix-darwin/nix/linux-builder/CONTEXT.md) — a Linux Nix builder for macOS hosts, built on oci-containers. Spans `packages/linux-builder-image` (the image), `packages/linux-builder` (the ephemeral CLI), and `modules/nix-darwin/nix/linux-builder` (the resident nix-darwin module).

## Relationships

- **linux-builder → oci-containers**: the module declares `virtualisation.oci-containers.containers.linux-builder`, consuming generic lifecycle features (socket activation, auto-off); it owns only Nix-builder semantics (nix config, SSH material, buildMachines). The CLI drives `container run` directly and does not consume the modules.
- **oci-containers → apple-container**: containers run through `virtualisation.apple-container.package`; the runtime (apiserver) must be enabled. oci-containers owns container *lifecycle* only; runtime-level resources (kernels, DNS domains, networks) belong to apple-container.
- **apple-container ↔ the `container` CLI**: `virtualisation.apple-container.*` mirrors the runtime's own command tree (`system.dns`, `system.kernel`, `network`, …) rather than inventing a Nix-side taxonomy.
- **apple-container ← apple-container-kernel**: the runtime boots guest VMs with a kernel; `packages/apple-container-kernel` provides one with `CONFIG_KVM` and `CONFIG_EROFS_FS`, which the linux-builder requires.
