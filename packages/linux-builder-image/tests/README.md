# Builder image — live boot probe

A **live integration test** for `packages/linux-builder-image`, not part of
`nix flake check`: it needs a real apple/container runtime and an
aarch64-linux builder (the host's existing linux-builder) to build the image.

`nix.linux-builder` — the nix-darwin module that runs this image — is tested
next to the module, not here.

## Running

```bash
./run.sh            # builds, boots, checks, cleans up
KEEP=1 ./run.sh     # leaves the keyed container running for inspection
./persist.sh        # the persistent store volume (see below)
BASE_REV=<rev> ./bench.sh   # time-to-nix-daemon vs a baseline (see below)
KERNEL=<Image> ./run.sh     # boot on another guest kernel
```

Everything boots on this tree's `pkgs.apple-container-kernel` (built first),
not the runtime's default kernel: the image's `/etc` overlay needs its
`CONFIG_EROFS_FS`. `KERNEL=` (empty) uses the runtime's default instead.

It builds three images — the bare base profile, the base profile plus a
throwaway key injected through the `modules` seam:

```nix
pkgs.linux-builder-image.override {
  modules = [ { users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 …" ]; } ];
}
```

Expected tail:

```
PASS: a partial rebuild (one /etc file changed) took …s (budget 45s)
…
PASS: startup (container run → nix-daemon answering over ssh) took …s (budget 2.5s)
…
PASS: 100/100 herd sessions succeeded
=== bare base-profile image ===
PASS: container image load accepted linux-builder:…
PASS: bare base-profile image refuses the login
=== keyed image without --rosetta ===
PASS: without --rosetta the builder still serves aarch64-linux; x86_64 is simply unregistered
=== all checks passed ===
```

## What it proves

- **Time budgets.** `MAX_STARTUP` (`container run` until the guest's
  nix-daemon answers over ssh, the best of up to three fresh boots) and
  `MAX_PARTIAL_REBUILD` (realising an image
  whose configuration differs by one `/etc` file from a cached one;
  evaluation excluded) are constants at the top of `run.sh`, holding the
  measured targets plus headroom. Exceeding either fails the run; when a
  change legitimately moves a target, update the constant and its comment.
- `container image load` accepts the oci-archive, under the ref in the
  package's `passthru.imageRef` (`linux-builder:<toplevel-hash>`).
- Booted with `container run --rosetta --cap-add CAP_SYS_ADMIN --cap-add
  CAP_NET_ADMIN`, stage 2 runs activation
  and exec's systemd, which is **PID 1** of the container's PID namespace
  (under the VM's vminitd). `systemctl is-system-running --wait` reports
  `running` with **no failed units**.
- DNS works via the runtime-written `/etc/resolv.conf`.
- Booted without a volume at `/persist`, stage 2 warns `THE STORE IS
  EPHEMERAL` (in `container logs`) and the builder still builds.
- The Nix DB is seeded with the image closure from `/nix-path-registration`
  by stage 2 (before systemd, so before nix-daemon), and
  `/nix/var/nix/profiles/system` points at the booted system.
- Root logs in with the key from `modules`; the bare image refuses the same
  key.
- The host's Nix builds a derivation on the builder over `ssh-ng` (sandboxed,
  as `nixbld` users) — the same protocol the host's nix-daemon offloads with.
- `sshd -T` shows the scar tissue (`MaxStartups 100:30:200`, `MaxSessions
  100`, `PerSourcePenalties no`, `AcceptEnv NIX_*`, key-only root login).
- **The herd check.** 20 banner-less TCP probes (what the host's on-demand
  proxy does to test liveness) followed by 100 simultaneous ssh sessions, all
  of which must succeed.

### Rosetta

- The `rosetta` virtiofs share is mounted at `/run/rosetta`, and
  `virtualisation.rosetta`'s registration is the x86_64 handler:
  `/proc/sys/fs/binfmt_misc/rosetta` is enabled with `flags: POCF`
  (Rosetta honors the kernel's preserve-argv0 protocol; `C` implies `O`).
  apple/container's own `x86_64` entry (flags `OCF`, argv0-discarding) is
  gone, flushed by stock `systemd-binfmt` before it registers ours.
- `nix config show` advertises `x86_64-linux` in `extra-platforms`, and
  `sandbox-paths` carries `/run/rosetta`.
- **x86_64 builds.** An x86_64-linux `runCommand` built over ssh-ng reports
  `uname -m` = `x86_64`.
- **The argv0 regression.** An x86_64-linux derivation runs an x86_64
  `python3.withPackages (ps: [ ps.six ])` env's `python3` and records
  `sys.prefix`, which must be the env, not the base interpreter. The env's
  `bin/python3` is a binary wrapper exec'ing the base interpreter under the
  env's own argv[0]; under apple/container's argv0-discarding handler it
  collapses to the base `python3-3.x`.
- **Without `--rosetta`** the builder keeps working, aarch64-only: the
  `nofail` mount and `systemd-binfmt` fail (the latter is the only failed
  unit tolerated here), no x86_64 handler is registered, root still logs
  in, and an aarch64-linux build over ssh-ng succeeds.

## Observed boot behaviour (apple/container 1.1.0)

- `/proc`, `/sys` (rw), devtmpfs `/dev`, `/dev/pts`, `/dev/shm`, `/dev/mqueue`
  and a **writable cgroup2** `/sys/fs/cgroup` are provided by the runtime;
  systemd mounts `/run` itself. systemd detects `container-other`; PID 1 sits
  in `0::/init.scope`.
- `container stop` honours the image's `StopSignal` (`SIGRTMIN+3`): the
  previous boot's journal ends at `Reached target System Halt` / `Shutting
  down.` well inside the 5 s default timeout. `container start` on the same
  rootfs boots cleanly again.
- Running services: `sshd`, `systemd-journald`, `systemd-logind`,
  `dbus-broker`, `nscd`, `console-getty`, `getty@tty1`, `nix-daemon`
  (started at boot, so the first ssh-ng connection doesn't pay socket
  activation). sshd logins open no logind
  session: the first login would otherwise start a `user@0.service`
  manager (~100 ms), and every login pays ~30 ms of session setup.

### Tolerated noise

No failed units. The only `-p warning` journal lines are:

| Message | Why it's harmless |
|---|---|
| `systemd-sysctl: Couldn't write '16' to 'vm/mmap_rnd_compat_bits'` | The guest kernel has no 32-bit compat; the NixOS ASLR sysctl targets it. |
| `systemd-tmpfiles: Cannot set file attributes for '/var/empty' … Operation not permitted` | `chattr +i` needs `CAP_LINUX_IMMUTABLE`; `/var/empty` is still root-owned 0555. |
| `kernel: check access for rdinit=/init failed` | VM-level boot of vminitd, before the container exists. |

`container logs` shows only stage 2's own output (the greeting, `running
activation script...`, `setting up /etc...`, `starting systemd...`) and then
goes quiet. That is not a hang: systemd, as PID 1, reopens its stdio to
`/dev/null`, and its `[  OK  ]` status output goes to `/dev/console`, which
apple/container routes to the VM's boot log. Watch the boot with
`container logs --boot <name>`.

### Perlless `/etc`

The image imports nixpkgs' `profiles/perlless.nix`. Stage 2's activation
mounts `/etc` as an overlay: an erofs metadata image plus a store data layer
as lowers, `/.rw-etc/upper` (on the container's rootfs) as the writable upper.
The runtime writes `/etc/resolv.conf` into the rootfs, beneath where the
overlay goes, so an activation snippet ordered before `etc` copies it into
the upper. Users come from `userborn.service` early in systemd, which is after
stage 2's DB seeding, so that seeding runs with `build-users-group` unset.

### Fixed during bring-up

- **DNS.** With resolvconf enabled, stage 2 stashes the runtime's
  resolv.conf under `/run` *before* systemd mounts a fresh tmpfs over `/run`,
  so `resolvconf.service` wrote a resolv.conf with no nameserver. The base
  profile disables resolvconf; the runtime owns `/etc/resolv.conf`.
- **udev.** `/sys` is writable here (unlike nspawn/docker), so `systemd-udevd`
  started and failed every uevent broadcast with `EPERM`. Its units are
  suppressed.
- **Delayed ACKs.** Every ssh handshake stalled ~45 ms: the guest delayed
  its ACK while the macOS client Nagle-held its next packet. `tcp-quickack`
  rewrites the runtime's routes with `quickack 1`, halving a warm login
  (~107 → ~52 ms). It needs `CAP_NET_ADMIN`; without it the unit logs
  `Operation not permitted` and the boot is otherwise unchanged.
- **`CAP_SYS_ADMIN`.** Without it stage 2 can't mount, and systemd dies as
  PID 1, which stops the container.
- **The argv0 shim era.** The image used to carry a C shim registered in
  place of apple/container's handler, with a qemu-user fallback for execs
  whose argv[0] differed from the binary, on the belief that Rosetta could
  not preserve argv[0]. Rosetta honors the kernel's preserve-argv0 binfmt
  protocol (verified live: the `withPackages` probe passes under a plain
  `POCF` registration), so the shim, qemu, the patched `systemd-binfmt`
  and the fail-fast `rosetta.service` are gone — `virtualisation.rosetta`
  does the whole job.
- **`systemd-binfmt` vs the share.** The `F` flag opens the interpreter at
  registration, and upstream `systemd-binfmt` orders only against
  `binfmt_misc`, not `run-rosetta.mount`; the base profile adds the
  ordering.
- **`/run/rosetta` via fstab once cost ~1 s.** In the shim era, as a
  `fileSystems` entry, systemd held `run-rosetta.mount` back behind its
  mountinfo rate limit (the same stall `/run/wrappers` hit), delaying
  `sysinit.target` and sshd to ~2.8 s time-to-ssh, so stage 2 mounted it
  instead. The stock module's fstab mount is back; `bench.sh` is the tool
  to re-measure, and `run.sh`'s startup budget catches a regression.

## Persistent store volume — `persist.sh`

Boots two keyed images, A and B (B adds one `/etc` file, so its system
closure differs), against a throwaway volume `lbi-persist-store` at
`/persist`, the way the module runs the builder: every start is a fresh
container (`rm` + `run`), the volume is the only state carried over. All
builds go over `ssh-ng`, as the host's nix-daemon offloads.

- **Overlay.** `/nix` is an overlay whose upper is on the volume;
  `/nix/store` is read-only on top of it again; the DB is on the volume.
- **Survives restart.** A build output lands in the volume's upper and is
  still valid (and verifies) after `container stop` + `rm` + `run`. The ssh
  host key under `/persist/ssh` is unchanged. A same-image restart skips
  the DB seed.
- **Dirty-volume regression.** Build a ~36 MiB output, `container stop`
  straight away (the idle stop), restart, and import the path on the host
  with `nix copy --from ssh-ng://…`: no `hash mismatch importing path`, and
  `nix-store --verify-path` passes on the builder.
- **Shutdown sync.** Every `container stop` must reach the
  `linux-builder-sync-volume` system-shutdown hook (the next boot finds its
  marker); after a `container kill`, which bypasses systemd, the next boot
  must warn `previous shutdown was not clean`.
- **Image change.** B boots on A's volume: stage 2 reconciles the DB, A's
  system — present in A's image, absent from B's — is no longer valid,
  `nix-store --verify` is clean, and the volume's build outputs are kept.
- **GC.** `nix-collect-garbage -d` collects an unrooted build output but
  leaves every path of the booted system in place; `nix-store --verify
  --check-contents` passes and the builder reboots cleanly afterwards.

### Teardown

systemd detects the container and so neither syncs nor unmounts file
systems on its way out (`src/shutdown/shutdown.c`); the hand-rolled image's
PID-1 trap (`sync` + lazy unmount) is gone, and the sync is now a
`systemd.shutdown` hook run after the final kill. During shutdown systemd
unmounts `/persist` itself — the overlay holds only a private clone of that
mount — and fails to unmount `/nix/.ro` (the overlay's lower), which shows
as `[FAILED] Failed unmounting /nix/.ro.` in `container logs --boot`; both
are harmless. The hook writes its marker through `/nix`, into the upper.

On apple/container 1.1.0 vminitd also unmounts the volume cleanly once the
container exits (`EXT4-fs (vdc): unmounting filesystem` in the boot log),
so even `container kill` with ~80 MiB dirty did not lose data in testing,
with or without the hook. The dirty-volume check therefore guards the
end-to-end property; the marker check is what proves the hook runs.

## Time-to-nix-daemon — `bench.sh`

Boots the working tree's image and `BASE_REV`'s, `ROUNDS` times each
(interleaved), and reports medians of: host time from `container run` until
a query through the guest's nix-daemon socket succeeds over ssh, and the
guest's own monotonic timestamps (seconds since the VM's kernel booted) for
`nix-daemon.service` and `sshd.service` becoming active and for systemd
starting. Scenarios: no volume, a fresh volume, a same-image restart (the
idle-stop/on-demand-start cycle), and an image change under a used volume.

Measured in the package's previous home (nix-darwin), against a baseline
that seeded the DB via `register-nix-paths` inside systemd, ROUNDS=5, two
runs:

| scenario | host run→daemon | guest nix-daemon active | guest sshd active |
|---|---|---|---|
| baseline, no volume | 1.61–1.74 | 1.10–1.20 | 1.04–1.14 |
| no volume | 1.70–1.79 | 1.08–1.19 | 1.11–1.21 |
| fresh volume | 1.75–1.82 | 1.15–1.23 | 1.18–1.26 |
| same-image restart | 1.51–1.70 | 1.04–1.12 | 1.05–1.14 |
| image change | 1.69–1.76 | 1.15–1.20 | 1.17–1.21 |

nix-daemon was already ordered after the DB seed, so moving the seed into
stage 2 leaves its start unchanged, and the same-image restart — which now
skips the seed — reaches it ~70 ms sooner. sshd, which used to start
alongside the seed, now starts after it: ~70 ms later whenever a seed runs
(every boot without a volume; once per image with one).

## Host quirk: Local Network privacy

macOS refuses TCP connections from **non-Apple binaries** to the container
network with `No route to host` (ICMP still works), so `ssh` from the Nix
store can't reach the builder from an unprivileged terminal session. The
script uses `/usr/bin/ssh` and `/usr/bin/nc`.
