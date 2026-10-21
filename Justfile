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

# If the project distinguishes unit and integration tests, split into
# `test-unit` and `test-integration` recipes and make `test` run both:
#   test: test-unit test-integration

# Run the test suite
test:
    @echo 'No tests: this repo only ships Nix packages (see `just check`)'

# Build all packages
build:
    nix-build -A skill-nixify -A apple-container-kernel -A linux-builder-image

# Nothing in this repo is runnable
run *ARGS:
    @echo 'No runnable package in this repo' >&2; exit 1

alias start := run

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
