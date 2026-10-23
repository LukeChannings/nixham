# launchd

Extensions of nix-darwin's `launchd.daemons`, `launchd.agents` and `launchd.user.agents`, for hosts whose /nix mounts late.

## Language

**entrypoint**:
The root-volume command launchd executes for a job: `/bin/sh -c "/bin/wait4path /nix/store && exec …"`, which nix-darwin gives every job declared with `command` or `script`. It waits for the store, then for the job's `waitForPaths`, before executing anything in it (see ADR-0001).
_Avoid_: wrapper, launcher

**bare store-path daemon**:
A daemon whose `Program` or `ProgramArguments[0]` is a /nix/store path, so launchd executes it without an entrypoint. Rejected unless it sets `allowBareStorePathProgram`.
