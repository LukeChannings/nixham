# End-to-end tests run in the user's session, not as Nix derivations

Tests are bats suites. Hermetic ones are **checks**: derivations, built like any other. Those that drive apple/container are **end-to-end tests**: Nix builds their runner, and the developer runs it from their own login session, because no Nix build can reach the runtime.

## Considered Options

Both tried as `_nixbld` with `pkgs.container` 1.5.0 under a `sandbox = false` daemon:

- **`container system start` in the build**: the CLI picks its launchd domain from `launchctl managername`. A build's is `System`, so it bootstraps the apiserver into `system/`, which only root may do (`Bootstrap failed: 5`). `user/<uid>` refuses for the same reason, and `gui/<uid>` doesn't exist without a login.
- **Spawning `container-apiserver` and its plugins directly**: every component finds the others with `xpc_connection_create_mach_service(name)` ([`XPCClient.swift`](https://github.com/apple/container/blob/1.5.0/Sources/ContainerXPC/XPCClient.swift)). Only launchd registers named Mach services, so this would mean forking the runtime's IPC.

`__noChroot` changes neither, and even with `sandbox = false` Nix still applies a minimal seatbelt profile on darwin. The other option, a root-run runtime that builds could reach, is the topology apple-container ADR-0001 rejects, and it would test something users don't run.

## Consequences

- CI runs only checks. End-to-end tests are a local, macOS-only gate.
- A check's result is cached until its inputs change; an end-to-end test reruns every time.
