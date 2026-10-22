# List available recipes
default:
    @just --list

# Format the tree
format:
    treefmt

alias fmt := format

# The flake's checks.formatting output exists for CI, where a store copy
# is acceptable; day to day, check the live tree instead.

# Check the working tree directly (no store copy)
check:
    treefmt --ci

alias lint := check

# Live suites: they need macOS, apple/container and the host's builder;
# nix flake check cannot run them. A suite filtered down to nothing (e.g.
# `just test -- --filter 'some test'`) is not a failure.

# Run every test.sh in the repo, or those whose directory is named NAMES; bats arguments go after --
[positional-arguments]
test *NAMES:
    #!/usr/bin/env bash
    set -euo pipefail
    names=() args=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do names+=("$1"); shift; done
    [ $# -eq 0 ] || { shift; args=(--allow-empty-suite "$@"); }
    mapfile -t all < <(find . \( -name .git -o -name .worktree -o -name 'result*' \) -prune -o -name test.sh -print | sort)
    suites=()
    if [ ${#names[@]} -eq 0 ]; then
      suites=("${all[@]}")
    else
      for name in "${names[@]}"; do
        found=0
        for s in "${all[@]}"; do
          if [ "$(basename "$(dirname "$s")")" = "$name" ]; then suites+=("$s"); found=1; fi
        done
        [ "$found" = 1 ] || { echo "no test.sh in a directory named '$name'" >&2; exit 1; }
      done
    fi
    # bats exits 1 when interrupted, so without this ^C moves on to the next suite.
    trap 'exit 130' INT
    status=0
    for s in "${suites[@]}"; do
      echo "=== $s ===" >&2
      "$s" "${args[@]}" || status=1
    done
    exit "$status"

# Build all packages
build:
    nix-build -A skill-nixify -A apple-container-kernel -A linux-builder -A linux-builder-image

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

# Create a worktree at .worktree/<issue>-<slug> on a matching branch, then prime it
worktree issue slug:
    git worktree add .worktree/{{ issue }}-{{ slug }} -b {{ issue }}-{{ slug }}
    just init-worktree .worktree/{{ issue }}-{{ slug }}

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
