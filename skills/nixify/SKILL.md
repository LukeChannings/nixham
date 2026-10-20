---
name: nixify
description: Set up or normalize Nix configuration in a directory — from a minimal direnv dev shell to a full flake with packages, devshell, treefmt, and flake-compat. Use when user runs /nixify, asks to "nixify" a repo, wants a nix dev shell or flake.nix added, or wants existing nix config aligned with the nix-base template.
---

# Nixify

Templates are bundled under [`templates/`](templates/) (resolve relative to this skill directory): `nix-base/` for flake scenarios, `simple-shell/` for scenario 1a. `nix-base` is the source of truth for conventions. Read every template file before acting: `flake.nix`, `default.nix`, `shell.nix`, `.envrc`, `treefmt.nix`, `Justfile`, `.gitignore`, `.zed/tasks.json` (Title-case recipe tasks + the `create_worktree` hook).

**Core convention — flakes for inputs, vanilla nix for everything else.** The flake exists to pin inputs (`flake.lock`); day-to-day building and running goes through the flake-compat shim with `nix-build` / `nix-shell`, never `nix build` / `nix develop` / `nix flake check`. Flake commands copy the entire source tree to the store on every invocation, which is very expensive; `default.nix` sets `copySourceTreeToStore = false` to avoid exactly that. `.envrc` uses `use_nix` (not `use flake`) for the same reason. `nix flake lock` is fine — it only manages the lock file.

**Common operations are standardised with [`just`](https://just.systems/man/).** `just` is a standard dependency in every devShell, and a `Justfile` provides stable recipe names wrapping the appropriate commands: `check` (alias `lint`), `build`, `run` (alias `start`), `format` (alias `fmt`), and `test`. When the project distinguishes unit from integration tests, add `test-unit` and `test-integration`, with `test` running both.

Two meta recipes ride along: `worktree <issue> <slug>` creates a git worktree under `.worktree/<issue>-<slug>/` on a matching branch and primes it via `init-worktree`. `init-worktree` is the single entry point for priming any new worktree/checkout: it copies `.env` from the main worktree (gitignored, so absent otherwise), then runs `direnv allow` + `direnv reload`.

`.zed/tasks.json` maps the core recipes to Title-case task labels — `Build` → `just build`, `Check`, `Format`, `Test`, `Run` — never `just <recipe>` labels (those collide with the tasks Zed's `just` extension generates, duplicating every picker entry). Meta/parameterised recipes (`default`, `worktree`, `init-worktree`) are not mapped. The file also carries a [`create_worktree` hook](https://zed.dev/docs/tasks#hooks) running `just init-worktree $ZED_WORKTREE_ROOT`, so Zed-created worktrees are primed automatically.

## Decide which scenario applies

1. **Empty / bare directory** → ask the user: simple dev shell, or full flake?
2. **Code repo with no nix files** → full flake from nix-base, plus a package derivation for the project.
3. **Directory with existing nix config** → converge toward nix-base conventions. See [REFERENCE.md](REFERENCE.md).

Re-running nixify is always scenario 3: re-assess the current structure against these standards, even if nixify set it up originally.

## Scenario 1a: Simple dev shell (no flake)

Ask which programs they want available. Copy [`templates/simple-shell/`](templates/simple-shell/) (`shell.nix`, `.envrc`, `.gitignore`), fill the requested programs into `packages`, then `direnv allow`. No flake, no lock file — uses the system's `<nixpkgs>`.

## Scenario 1b: Full flake in empty directory

1. Copy the full nix-base template verbatim (including `.zed/tasks.json`). In an existing repo, merge the `.gitignore` entries (`result`, `result-*`, `.direnv/`, `.env`) into any existing ignore file instead of overwriting.
2. If not a git repo, ask whether to `git init` (flakes require tracked files; without git, plain directories work but warn about it).
3. In a git repo: `git add` the nix files **before** locking — flakes ignore untracked files.
4. Run `nix flake lock`. `default.nix` reads `flake.lock`, so the lock must exist before `nix-shell`/`shell.nix` works.
5. Verify: `nix-shell --run true` and `direnv allow`.

## Scenario 2: Package an existing project

Start from Scenario 1b, then:

1. Detect the ecosystem (package.json, Cargo.toml, go.mod, pyproject.toml, *.cabal, etc.).
2. Follow [ECOSYSTEMS.md](ECOSYSTEMS.md) for the builder, devshell toolchain, and formatter for that ecosystem (JS/TS → buildNpmPackage + biome, Rust → crane, Python → nixpkgs python devshell + pyproject.nix, Go → buildGoModule). The packaging rule is **colocation**: a derivation that packages an in-repo source tree lives with that tree, as a `package.nix` at its root (repo root for a single-package repo), wired in `flake.nix` with `pkgs.callPackage ./path/to/package.nix { }` — never inlined in `flake.nix`. A central `packages/` directory is for everything else: vendored out-of-repo software and packages implemented entirely within it (`packages/<foo>/package.nix` whose source *is* there is fine; `packages/foo.nix` reaching into `../some/dir` is not). Set `packages.default`.
3. Extend `treefmt.nix` with formatters already used by the project — consult the treefmt-nix repo for available programs; don't introduce new formatters uninvited.
4. Fill in the `Justfile`: set the binary name in `run`, wire `test` to the project's test runner (splitting into `test-unit`/`test-integration` if the suite distinguishes them, with `test` running both), and adapt recipe bodies to the ecosystem's native commands where that's the better dev loop (e.g. `cargo build`) — but keep the recipe names stable.
5. If the package is a daemon/service, offer an accompanying NixOS or nix-darwin module (pattern in [ECOSYSTEMS.md](ECOSYSTEMS.md)).
6. Verify: `just build`, `just check`, `just test`, and `nix-shell --run '<toolchain> --version'`.

## Scenario 3: Existing nix config

Audit the repo's config against nix-base conventions and converge. Full checklist and hoisting recipes: [REFERENCE.md](REFERENCE.md). Never discard existing inputs, packages, or shell hooks — relocate them.

## Verification (all scenarios)

Vanilla commands only — see the core convention above.

- [ ] `nix-shell --run true` works (proves the flake-compat path)
- [ ] `just check` passes and `just build` builds (if packages exist)
- [ ] `direnv allow` succeeds and loads the shell
- [ ] nix files are git-tracked (if repo)
