# apple-container

Apple's lightweight container runtime (`apple/container`) on macOS, managed declaratively through nix-darwin.

## Language

**apple-container**:
Apple's container runtime, where each container runs in its own VM. Always singular: the module is `virtualisation.apple-container`, and runtime-specific per-container options elsewhere live under `apple-container.*`.
_Avoid_: apple-containers, apple.\*, Apple Containers

**apiserver**:
The per-user apple-container daemon (`container-apiserver`), a launchd user agent registered at the XPC endpoint `com.apple.container.apiserver`. User-scoped and GUI-session-bound: it exists only while its user is logged in, and refuses XPC peers of any other uid (see ADR-0001).

**socktainer**:
An add-on daemon that exposes a Docker-compatible API socket on top of apple-container.
_Avoid_: docker shim, docker socket proxy
