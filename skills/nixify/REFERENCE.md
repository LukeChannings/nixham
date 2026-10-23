# Converging existing nix config toward nix-base

Goal: the repo ends up structurally identical to [`templates/nix-base/`](templates/nix-base/) (bundled with this skill) while keeping every behavior it already had. Audit first, then propose the diff to the user before editing.

## The nix-base invariants

| File          | Invariant                                                                                                    |
| ------------- | ------------------------------------------------------------------------------------------------------------ |
| `flake.nix`   | Single source of truth. Inputs: nixpkgs, flake-parts, flake-compat (lix fork, `flake = false`), treefmt-nix. Outputs via `flake-parts.lib.mkFlake`, importing `treefmt-nix.flakeModule` (which provides `formatter` and `checks.treefmt` from `perSystem.treefmt = ./treefmt.nix`): `perSystem.packages`, `perSystem.devShells.default`. `packages` entries are `pkgs.callPackage` of per-package `package.nix` files, not inline derivations. |
| `package.nix` | One per in-repo package, at that package's root (repo root for a single-package repo). Receives its dependencies via `callPackage` injection. A central `packages/` directory is legitimate only for vendored out-of-repo software or packages implemented entirely within it. |
| `default.nix` | flake-compat shim. Pins flake-compat by reading `flake.lock` (no hardcoded rev), passing `fetchGit` its `narHash` too: without it, every evaluation announces `fetching git input …`, which is easily mistaken for the cost of whatever slow evaluation follows. Sets `copySourceTreeToStore = false` — the flake exists to pin inputs, but building/running goes through vanilla `nix-build`/`nix-shell`, because flake commands copy the whole source tree to the store per invocation. Returns `flake.defaultNix // packages.${system}` so `nix-build -A <pkg>` works. |
| `shell.nix`   | One line: `(import ./. { }).devShells.${builtins.currentSystem}.default` — delegates to the flake devshell. |
| `.envrc`      | `dotenv_if_exists`, `watch_file flake.nix flake.lock shell.nix default.nix treefmt.nix`, `use_nix` (never `use flake` — same store-copy cost). Watch every file the devshell is built from: nix-direnv serves a cached shell until a watched file changes, so an unwatched `treefmt.nix` leaves a stale treefmt that looks like it ignores its own config. |
| `treefmt.nix` | Standalone module, `projectRootFile = "flake.nix"`, at minimum the nix-base set: `nixfmt`, `deadnix`, `statix`, `just`, `shfmt`, `yamllint`, `actionlint`, plus the custom `forgejo-schema` formatter (`forgejo-runner validate` over `.forgejo/` workflows and actions; omitted in GitHub-only repos). |
| `.gitignore`  | Ignores `result` / `result-*` (nix-build symlinks), `.direnv/` (direnv cache), `.env` (loaded by `dotenv_if_exists`, never committed), `.worktrees/` (worktree checkouts). |
| `Justfile`    | Stable recipe names for common operations, each discretionary (omit what the project has no use for): `check` (alias `lint`), `build` (one package: `default`, or `just build <attr>`), `build-all` (every package; only with several), `run` (alias `start`), `format` (alias `fmt`), `test` (plus `test-unit`/`test-integration` when the suite distinguishes them; `test` runs both). Bodies use vanilla nix (`nix-build`) or the ecosystem's native dev commands, except `build`/`build-all`, which stay `nix-build`s (the Build workflow runs one). `just` and the treefmt wrapper are standard devShell dependencies. Meta recipes: `worktree <issue> <slug>` / `init-worktree` (worktrees under `.worktrees/<issue>-<slug>/`; priming = copy `.env` from the main worktree, `direnv allow`, `direnv reload`). |
| `.zed/tasks.json` | Title-case tasks for whichever core recipes exist (`Build`, `Check`, `Format`, `Test`, `Run` → `just <recipe>`), plus the `create_worktree` hook running `just init-worktree $ZED_WORKTREE_ROOT`. No `just <recipe>` labels (they collide with Zed's `just` extension tasks); meta/parameterised recipes aren't mapped. |

## Audit checklist

- [ ] Package derivations inlined in `flake.nix`? Move each to a `package.nix`, wired via `pkgs.callPackage`.
- [ ] Does anything in a central `packages/` directory package code that lives elsewhere in the repo (e.g. `src = ../some/dir`)? Move that file to a `package.nix` at that code's root and rewire. Entries that vendor out-of-repo software, or that are implemented entirely within `packages/`, stay put — and the `packages/` directory itself always stays in place, even if a move empties it.
- [ ] Has `flake.nix`? If not but has `shell.nix`/`default.nix` with real content → Scenario 2 shape: create the flake, hoist content in (below).
- [ ] Uses flake-compat? If `default.nix`/`shell.nix` hardcode a flake-compat rev or use the edolstra upstream, replace with nix-base's lock-file-reading `default.nix`. Already lock-file-reading, but `fetchGit` gets no `narHash`? Add it.
- [ ] `shell.nix` contains real config (packages, env vars, shellHooks)? Hoist into `devShells.default` in `flake.nix`, then reduce `shell.nix` to the one-line delegate.
- [ ] `.envrc` watches all four nix files? Uses `dotenv_if_exists`?
- [ ] `.gitignore` covers `result`, `result-*`, `.direnv/`, `.env`? Merge missing entries in.
- [ ] `.zed/tasks.json` present, with Title-case core-recipe tasks and the `create_worktree` hook? Rename any `just <recipe>` labels (they collide with Zed's `just` extension tasks, showing every task twice) and drop entries for meta/parameterised recipes.
- [ ] Has a `Justfile` using the standard names for the recipes it has? Don't add recipes the project has no use for, and drop the Zed tasks and CI workflows of any it omits. If the repo has ad-hoc scripts or a Makefile for check/build/run, mirror them as `just` recipes (keep the originals unless asked); ensure `just` is in the devShell.
- [ ] CI workflows present and matching [`templates/ci/`](templates/ci/)? See the CI section of [SKILL.md](SKILL.md#ci-workflows). Forgejo workflows need `.forgejo/actionlint.yaml` (runner labels, full-URL `uses:` ignore) passed to actionlint via `-config-file` in `treefmt.nix`; move an existing `.github/actionlint.yaml` there. Keep jobs the repo already has; converge Lint/Test/Build onto the `just` recipes and the niks3 push.
- [ ] Formatter wired up? If no treefmt, add `treefmt.nix` and import `treefmt-nix.flakeModule` with `perSystem.treefmt = ./treefmt.nix`. If the repo has its own formatter config (e.g. `.prettierrc`), enable the matching treefmt program rather than replacing config.
- [ ] Per-system boilerplate hand-rolled, or using flake-utils? Restructure onto flake-parts: move per-system outputs into `perSystem`, and anything system-independent (modules, overlays, configurations) under `flake`. Modules go through flake-parts' `modules` flake module; a hand-written overlay that only re-exports the flake's packages becomes `easyOverlay` — see the modules and overlays sections of [ECOSYSTEMS.md](ECOSYSTEMS.md).

## Hoisting a shell.nix into the flake

Given e.g.:

```nix
# old shell.nix
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  packages = [ pkgs.nodejs pkgs.jq ];
  shellHook = ''export FOO=bar'';
}
```

Move the `mkShell` body verbatim into `devShells.default` in `flake.nix`, keep env vars and hooks intact, and replace `shell.nix` with the delegate line. The visible behavior of `nix-shell` must not change (except nixpkgs now comes pinned from the lock, not `<nixpkgs>` — mention this to the user).

## Preservation rules

- Never drop inputs, overlays, packages, env vars, or shellHooks — relocate them.
- Keep extra outputs the repo defines (nixosConfigurations, overlays, apps) untouched.
- If the lock pins an old nixpkgs, do not bump it as part of nixify unless asked.

## Verify after converging

Vanilla commands only (flake commands copy the source tree to the store):

```sh
nix-shell --run true        # proves flake-compat + shell.nix delegate
nix-build -A <pkg>          # if packages exist (default.nix merges packages in)
direnv allow
```

Diff the devshell before/after if possible: `nix-shell --run 'env | sort'` compared against the old shell's env.
