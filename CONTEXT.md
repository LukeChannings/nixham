# nixham

Language shared by every context in the repo.

## Language

### Testing

**check**:
A hermetic derivation that passes when it builds. Runs wherever Nix does, CI included. A check that tests something is a bats suite; others assert formatting or configuration.
_Avoid_: eval test, unit test, sandbox test

**end-to-end test**:
A bats suite that drives the real apple/container runtime from the developer's own login session. Never a **check**: the runtime is unreachable from a Nix build (see ADR-0001).
_Avoid_: live test, integration test

**benchmark**:
A measurement taken through the real runtime, like an **end-to-end test**, and recorded in the repo per PR and host. Never a pass/fail gate, so neither a **check** nor an **end-to-end test**.
_Avoid_: perf test, benchmark test

## Example dialogue

> **Dev:** "The proxy script change broke nothing in CI, but the on-demand container no longer starts on first connection."
> **Expert:** "CI only builds the **checks**: they prove the agent's script says the right thing. Whether launchd and the runtime actually do it is the **end-to-end test**'s job; run it on your Mac."
