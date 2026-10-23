# apple/container runs as per-user launchd agents, never as a system daemon

apple/container is a per-user constellation of launchd jobs: `container system start` writes an ephemeral LaunchAgent plist (`~/Library/Application Support/com.apple.container/apiserver/apiserver.plist`) whose MachServices registration (`com.apple.container.apiserver`) is the XPC endpoint the CLI resolves through the caller's bootstrap namespace. All state is per-user under `CONTAINER_APP_ROOT`. The nix-darwin modules therefore run the runtime, socktainer, and every container as launchd **user agents** in the primary user's GUI session — containers start at login, not at boot — and any root-domain process (e.g. the linux-builder's socket-activation proxy daemon) reaches the runtime via `launchctl asuser <uid> sudo -u <user> container …`.

## Considered Options

- **LaunchDaemon as an arbitrary user**: tested empirically; the apiserver launches, then dies (`failed to do a bootstrap look-up: xpc_error=[3: No such process]`) — a non-root process in the system domain cannot bootstrap its helper jobs (image/machine plugins, vmnet helpers, per-container VM processes) into any launchd domain.
- **LaunchDaemon as root**: works (helpers bootstrap into the system domain, containers get vmnet IPs), but is unsupported upstream, requires a custom `CONTAINER_APP_ROOT`, and clients must escape the login-session namespace (`sudo launchctl asuser 0 …`). Rejected: upgrade friction.

## Consequences

- The apiserver rejects any XPC peer whose uid differs from its own — even root. `sudo container ls` in a user session reaches that user's agent and is refused. There is no global view across users.
- `virtualisation.oci-containers` cannot honour an "auto-start on boot" expectation; `autoStart` means at login.
- A kernel must be provisioned per app-root (`container system kernel set`, or `container run --kernel`).
