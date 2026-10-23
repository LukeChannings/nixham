# oci-containers

Declarative OCI containers for nix-darwin, option-compatible with NixOS's `virtualisation.oci-containers`, executed through apple-container.

## Language

**container agent**:
The launchd user agent that owns one declared container: it gates on apiserver readiness, ensures networks and images exist, then `container run`s. One agent per `containers.<name>`. Agents start at login, never at boot (see apple-container ADR-0001).

**on-demand container**:
A container whose launchd-owned loopback listeners start it on first connection and whose idle watchdog stops it after `idleTimeout`. apple-container-specific (per-container VMs boot fast enough to hide the cold start), so it lives under `containers.<name>.apple-container.onDemand`. Mutually exclusive with `autoStart`.

**apiserver readiness**:
The hard start-gate every container agent polls for (`container system status`) before touching the runtime. launchd provides no inter-job ordering, so readiness is checked in-script, not declared.
