# launchd daemons wait for the store in the entrypoint

On hosts whose /nix is a late-mounting volume (a ZFS import can land ~13 minutes after boot), a daemon whose `Program` or `ProgramArguments[0]` is a /nix/store path fails its boot spawn with errno 2. launchd records that as EX_CONFIG (78) and penalty-boxes the job for good; `KeepAlive` never recovers it. So every daemon reaches its store-path executable through a root-volume entrypoint that *waits*: `/bin/sh -c "/bin/wait4path /nix/store && exec …"`, the wrapper nix-darwin already applies to `command` and `script`. Extra prerequisites, e.g. secrets installed at activation, are listed in `waitForPaths` and polled for (`until [ -e … ]; do /bin/sleep 1; done`) after the store. An assertion rejects a daemon whose executable is a store path, unless it sets `allowBareStorePathProgram`.

Agents are out of scope: they load into a login session, by which time /nix has mounted. They may still use `waitForPaths`, e.g. for secrets. That also keeps TCC-dependent agents (skhd, yabai, …), whose grants attach to the binary launchd executes, working unchanged.

## Considered Options

- **`KeepAlive.PathState` on the store path**: field-tested failure. PathState is polled, not an event: a host booted with the path present, and launchd had still not launched the daemon 14 hours later.
- **A wrapper installed on the root volume at activation**: works, but needs five coupled mechanisms per daemon (a preActivation install, a hand-rolled wait loop, a static `Program`, environment variables to dirty the plist, and a kickstart at activation). With wait4path the store path rides in `ProgramArguments`, which dirties the plist by itself.
- **`wait4path` for `waitForPaths` too**: field-tested failure (hartlandia/hartlandia#429). `wait4path` sleeps until the *mount table* changes, so it only waits correctly for a mount point. A secret written by sops-install-secrets or a socket created by another daemon appears without a mount: garage, restarted by activation before sops had written its renamed secrets, sat in `wait4path` until it was kickstarted by hand. Polling once a second costs nothing and wakes for any path.
- **`wait4path` in the entrypoint (chosen)**: the exec can never fail, as `/bin/sh` and `/bin/wait4path` are always on the root volume, so the penalty box is unreachable. The blocked wrapper counts as running, so `KeepAlive` does not thrash.

## Consequences

- A daemon that must act *before* /nix mounts, e.g. network plumbing using only /sbin, is the one case for a program installed on the root volume: wrapping it in wait4path would delay it by the whole mount latency. `networking.virtualInterfaces` is one.
- The opt-out also covers daemons that TCC requires launchd to execute directly: a permission such as Input Monitoring belongs to the job's executable, so `/bin/sh` in front would take it. The karabiner grabber and observer daemons are this case; they rely on a wait4path-wrapped helper that kickstarts them once the store is up.
- nixham can't change how nix-darwin's own modules start their daemons, so it opts out the ones that execute a store path directly: karabiner's, eternal-terminal's and wg-quick's. Only karabiner's opt-out is by design; eternal-terminal and wg-quick should start through `command` upstream.
