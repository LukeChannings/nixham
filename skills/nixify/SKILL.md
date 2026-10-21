---
name: nixify
description: Set up or normalize Nix configuration in a directory — from a minimal direnv dev shell to a full flake with packages, devshell, treefmt, and flake-compat. Use when user runs /nixify, asks to "nixify" a repo, wants a nix dev shell or flake.nix added, or wants existing nix config aligned with the nix-base template.
---

# Nixify

Templates are bundled under [`templates/`](templates/) (resolve relative to this skill directory): `nix-base/` for flake scenarios, `simple-shell/` for scenario 1a, `ci/` for [CI workflows](#ci-workflows). `nix-base` is the source of truth for conventions. Read every template file before acting: `flake.nix`, `default.nix`, `shell.nix`, `.envrc`, `treefmt.nix`, `Justfile`, `.gitignore`, `.zed/tasks.json` (Title-case recipe tasks + the `create_worktree` hook).

**Config files are stored inert** so that git, direnv, and Zed don't treat the templates as live config in the repo hosting this skill: dotfiles carry a `dot-` prefix (`dot-envrc`, `dot-gitignore`; rename `dot-*` → `.*` on copy), and `zed-tasks.json` is flat (copy to `.zed/tasks.json`).

**Core convention — flakes for inputs, vanilla nix for everything else.** The flake exists to pin inputs (`flake.lock`); day-to-day building and running goes through the flake-compat shim with `nix-build` / `nix-shell`, never `nix build` / `nix develop` / `nix flake check`. Flake commands copy the entire source tree to the store on every invocation, which is very expensive; `default.nix` sets `copySourceTreeToStore = false` to avoid exactly that. `.envrc` uses `use_nix` (not `use flake`) for the same reason. `nix flake lock` is fine — it only manages the lock file.

**Common operations are standardised with [`just`](https://just.systems/man/).** `just` is a standard dependency in every devShell, and a `Justfile` provides stable recipe names wrapping the appropriate commands: `check` (alias `lint`), `build`, `run` (alias `start`), `format` (alias `fmt`), and `test`. When the project distinguishes unit from integration tests, add `test-unit` and `test-integration`, with `test` running both. Every recipe is discretionary: the names are standard, not their presence. Keep only those the project has a use for (no `run` when nothing is runnable, no `build` without packages), and drop the matching Zed task and CI workflow with them.

Two meta recipes ride along: `worktree <issue> <slug>` creates a git worktree under `.worktree/<issue>-<slug>/` on a matching branch and primes it via `init-worktree`. `init-worktree` is the single entry point for priming any new worktree/checkout: it copies `.env` from the main worktree (gitignored, so absent otherwise), then runs `direnv allow` + `direnv reload`.

`.zed/tasks.json` maps whichever core recipes exist to Title-case task labels — `Build` → `just build`, `Check`, `Format`, `Test`, `Run` — never `just <recipe>` labels (those collide with the tasks Zed's `just` extension generates, duplicating every picker entry). Meta/parameterised recipes (`default`, `worktree`, `init-worktree`) are not mapped. The file also carries a [`create_worktree` hook](https://zed.dev/docs/tasks#hooks) running `just init-worktree $ZED_WORKTREE_ROOT`, so Zed-created worktrees are primed automatically.

## Decide which scenario applies

1. **Empty / bare directory** → ask the user: simple dev shell, or full flake?
2. **Code repo with no nix files** → full flake from nix-base, plus a package derivation for the project.
3. **Directory with existing nix config** → converge toward nix-base conventions. See [REFERENCE.md](REFERENCE.md).

Re-running nixify is always scenario 3: re-assess the current structure against these standards, even if nixify set it up originally.

## Scenario 1a: Simple dev shell (no flake)

Ask which programs they want available. Copy [`templates/simple-shell/`](templates/simple-shell/) (`shell.nix`, `dot-envrc`, `dot-gitignore` — renaming `dot-*` → `.*`), fill the requested programs into `packages`, then `direnv allow`. No flake, no lock file — uses the system's `<nixpkgs>`.

## Scenario 1b: Full flake in empty directory

1. Copy the full nix-base template (renaming `dot-*` → `.*`; `zed-tasks.json` → `.zed/tasks.json`). In an existing repo, merge the `.gitignore` entries (`result`, `result-*`, `.direnv/`, `.env`) into any existing ignore file instead of overwriting.
2. If not a git repo, ask whether to `git init` (flakes require tracked files; without git, plain directories work but warn about it).
3. In a git repo: `git add` the nix files **before** locking — flakes ignore untracked files.
4. Run `nix flake lock`. `default.nix` reads `flake.lock`, so the lock must exist before `nix-shell`/`shell.nix` works.
5. Verify: `nix-shell --run true` and `direnv allow`.

## Scenario 2: Package an existing project

Start from Scenario 1b, then:

1. Detect the ecosystem (package.json, Cargo.toml, go.mod, pyproject.toml, *.cabal, etc.).
2. Follow [ECOSYSTEMS.md](ECOSYSTEMS.md) for the builder, devshell toolchain, and formatter for that ecosystem (JS/TS → buildNpmPackage + biome, Rust → crane, Python → nixpkgs python devshell + pyproject.nix, Go → buildGoModule). The packaging rule is **colocation**: a derivation that packages an in-repo source tree lives with that tree, as a `package.nix` at its root (repo root for a single-package repo), wired in `flake.nix` with `pkgs.callPackage ./path/to/package.nix { }` — never inlined in `flake.nix`. A central `packages/` directory is for everything else: vendored out-of-repo software and packages implemented entirely within it (`packages/<foo>/package.nix` whose source *is* there is fine; `packages/foo.nix` reaching into `../some/dir` is not). Set `packages.default`.
3. Extend `treefmt.nix` with formatters already used by the project — consult the treefmt-nix repo for available programs; don't introduce new formatters uninvited beyond the nix-base set.
4. Fill in the `Justfile`: drop recipes the project has no use for, set the binary name in `run`, wire `test` to the project's test runner (splitting into `test-unit`/`test-integration` if the suite distinguishes them, with `test` running both), and adapt recipe bodies to the ecosystem's native commands where that's the better dev loop (e.g. `cargo build`) — but keep the recipe names stable.
5. If the package is a daemon/service, offer an accompanying NixOS or nix-darwin module (pattern in [ECOSYSTEMS.md](ECOSYSTEMS.md)).
6. Verify: every recipe kept (`just build`, `just check`, `just test`, …) and `nix-shell --run '<toolchain> --version'`.

## Scenario 3: Existing nix config

Audit the repo's config against nix-base conventions and converge. Full checklist and hoisting recipes: [REFERENCE.md](REFERENCE.md). Never discard existing inputs, packages, or shell hooks — relocate them.

## CI workflows

Every flake repo (scenarios 1b, 2, 3) gets Lint, Test, and Build workflows from [`templates/ci/`](templates/ci/), each only if what it wraps exists: drop `lint.yaml` without a `check` recipe, `test.yaml` without `test`. Read them before acting.

1. Find the host from `git remote get-url origin`: `forge.channings.me` → Forgejo, `github.com` → GitHub. No remote, or another host → ask.
2. Forgejo repo → ask whether it's mirrored to GitHub. If so, add both sets: Forgejo ignores `.github/workflows` when `.forgejo/workflows` exists, so nothing runs twice on the forge.
3. Copy `ci/forgejo/*.yaml` → `.forgejo/workflows/`, `ci/github/*.yaml` → `.github/workflows/`.
4. Forgejo workflows → copy `ci/actionlint.yaml` → `.github/actionlint.yaml`: actionlint also lints `.forgejo/workflows/` and rejects the Forgejo runner labels otherwise. GitHub-only repo → delete the `forgejo-schema` formatter from `treefmt.nix`.

The workflows run on pushes to `main` and on PRs:

- **Lint** and **Test** run `just check` and `just test` in `nix-shell`, so the Justfile stays the single definition. `just check` lints the workflows themselves too (actionlint, yamllint, and `forgejo-runner validate` via the `forgejo-schema` formatter), so keep edits to them yamllint-clean.
- Test suites that need host-only tooling (e.g. a macOS-only CLI) must skip — exit 0 with a message — when it's missing, so `just test` passes on the runners.
- **Build** `nix-build`s every `packages.<system>` and pushes the closures to `nix.channings.me` with nixham's [`niks3-push`](https://forge.channings.me/hartlandia/nixham/src/branch/main/.forgejo/actions/niks3-push) action (secret `NIKS3_CI_TOKEN`; fork PRs are skipped). Drop `build.yaml` if the flake has no packages. Pick `runs-on` to match the packages' system: Forgejo `nixos-latest` (`-x86_64`/`-arm64` to pin the arch, `macos-arm64` for darwin), GitHub `ubuntu-latest` / `ubuntu-24.04-arm` / `macos-latest`.
- **Publish** (a job in `build.yaml`) pushes OCI images to a registry on `main` only, tagged with the commit SHA and `latest`: Forgejo → `forge.channings.me/<owner>/<name>` (secret `FORGE_PAT`), GitHub → `ghcr.io/<owner>/<name>`. Their closures already reached `nix.channings.me` in Build, with everything else. If no package builds a container image, delete the job. Otherwise:
  - Add one matrix entry per image: `name` (registry image name), `attr` (`nix-build -A` attribute), `transport` (`oci-archive` for OCI archive tarballs, `docker-archive` for `dockerTools` images).
  - Add `skopeo` to `devShells.default`. For a nix2container image, use transport `nix` and nix2container's `skopeo-nix2container` instead.

## Verification (all scenarios)

Vanilla commands only — see the core convention above.

- [ ] `nix-shell --run true` works (proves the flake-compat path)
- [ ] Every recipe kept in the `Justfile` succeeds
- [ ] `direnv allow` succeeds and loads the shell
- [ ] nix files are git-tracked (if repo)
- [ ] `just check` lints the workflows (actionlint, yamllint, forgejo-schema) — no separate linter runs needed
