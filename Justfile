# List available recipes
default:
    @just --list

# Format the tree
format:
    treefmt

alias fmt := format

# checks.treefmt is for `nix flake check`: it can't build from the live
# tree default.nix evaluates.

# Lint the working tree directly
lint:
    treefmt --ci

# Build the checks, or those of components (or component.scope) NAMES
test *NAMES:
    #!/usr/bin/env bash
    set -euo pipefail
    names=""
    for n in {{ NAMES }}; do names+="\"$n\" "; done
    nix-build --no-out-link -E "(import ./. { }).selectTests \"check\" [ $names]" >/dev/null

# End-to-end tests (docs/adr/0001) run here, in this user's session: they need
# macOS and apple/container. A selection filtered down to nothing (e.g.
# `just test-e2e -- --filter 'some test'`) is not a failure.

# Run the end-to-end tests, or those of components (or component.scope) NAMES; bats arguments go after --
[positional-arguments]
test-e2e *ARGS:
    @just _run e2e "$@"

# Run the benchmarks, or those of components (or component.scope) NAMES; bats arguments go after --
[positional-arguments]
bench *ARGS:
    @just _run benchmark "$@"

[positional-arguments]
_run KIND *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    kind=$1
    shift
    names="" args=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do names+="\"$1\" "; shift; done
    [ $# -eq 0 ] || { shift; args=(--allow-empty-suite "$@"); }
    runners=()
    while read -r r; do runners+=("$r"); done < <(nix-build --no-out-link -E "(import ./. { }).selectTests \"$kind\" [ $names]")
    [ ${#runners[@]} -gt 0 ] || { echo "no $kind tests here" >&2; exit 1; }
    # bats exits 1 when interrupted, so without this ^C moves on to the next runner.
    trap 'exit 130' INT
    status=0
    for r in "${runners[@]}"; do
      for bin in "$r"/bin/*; do
        echo "=== $(basename "$bin") ===" >&2
        "$bin" ${args[@]+"${args[@]}"} || status=1
      done
    done
    exit "$status"

# Build package NAME, e.g. `just build linux-builder`
build NAME:
    nix-build -A {{ NAME }}

# Build every package for this system
build-all:
    nix-build -E 'builtins.getAttr builtins.currentSystem (import ./. { }).packages'

# Run the package NAME's program of the same name with ARGS, e.g. `just run linux-builder shell`
[positional-arguments]
run NAME *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    # nix-build writes every .drv of the closure through the daemon even when
    # the output is cached (~15s for linux-builder); evaluating is enough then.
    out="$(nix-instantiate --eval --raw -A "$1.outPath")"
    nix-store --check-validity "$out" 2>/dev/null || nix-build --no-out-link -A "$1" >/dev/null
    exec "$out/bin/$1" "${@:2}"

# Create a worktree at .worktrees/<issue>-<slug> on a matching branch, then prime it
worktree issue slug:
    git worktree add .worktrees/{{ issue }}-{{ slug }} -b {{ issue }}-{{ slug }}
    just init-worktree .worktrees/{{ issue }}-{{ slug }}

# Copies .env from the main worktree (gitignored, so absent in fresh
# worktrees), then direnv allow + reload. Zed runs this automatically via
# its create_worktree hook (see .zed/tasks.json).

# Prime a freshly created worktree (or any new checkout)
init-worktree dir=".":
    #!/usr/bin/env bash
    set -euo pipefail
    main="$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)"
    if [ -f "$main/.env" ] && [ ! -e "{{ dir }}/.env" ]; then
      cp "$main/.env" "{{ dir }}/.env"
    fi
    cd "{{ dir }}" && direnv allow && direnv reload
