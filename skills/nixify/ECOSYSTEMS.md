# Per-ecosystem packaging guidance

How to fill in `packages`, `devShells.default`, and `treefmt.nix` once you've detected the project's language. Consult [treefmt-nix](https://github.com/numtide/treefmt-nix) (`programs/` directory) for the full list of available formatter modules before wiring any formatter.

Every devShell below also carries `just` (standard dependency), and the `Justfile`'s `run`/`check`/`test` recipes should wrap the ecosystem's native commands where that makes the better dev loop — recipe names stay stable across projects.

## JavaScript / TypeScript

- **Package** with [`buildNpmPackage`](https://nixos.org/manual/nixpkgs/stable/#javascript-tool-specific) (needs `npmDepsHash`; run the build once with `lib.fakeHash` to obtain it).
- **Format/lint** with `biome`. Wire biome as a *custom* treefmt formatter (`settings.formatter.biome` pointing at `${pkgs.biome}/bin/biome format --write`) instead of treefmt-nix's `programs.biome` module — the module generates a store-side biome.json, which hides config from editors; the custom wiring keeps the committed `biome.json` the single source of truth. Only run `format`, never `check` (check applies lint fixes and fails on lint debt).
- **Devshell**: `nodejs`, `biome`, plus the package manager the lockfile implies.

## Rust

- **Package** with [crane](https://crane.dev). Add input `crane.url = "github:ipetkov/crane"`, then `craneLib = crane.mkLib pkgs`, `craneLib.buildPackage { src = craneLib.cleanCargoSource ./.; }`. Crane caches the dependency build (`buildDepsOnly`) separately from the crate build.
- If a pinned/custom toolchain is needed, add `rust-overlay` and `craneLib.overrideToolchain`.
- **Format**: `programs.rustfmt.enable` in treefmt (respects the repo's `rustfmt.toml`); `taplo` for Cargo.toml.
- **Devshell**: `craneLib.devShell` or mkShell with the toolchain, `rust-analyzer`, `cargo-watch` as wanted.

## Python

- **Devshell first**: nixpkgs python with its dependency set — `python3.withPackages (ps: [ ps.requests ... ])` per the [NixOS wiki](https://wiki.nixos.org/wiki/Python). Map `pyproject.toml`/requirements onto `ps.*` names where they exist.
- **Package** with [pyproject.nix](https://github.com/pyproject-nix/pyproject.nix): `project = pyproject-nix.lib.project.loadPyproject { projectRoot = ./.; }`, then `python.pkgs.buildPythonPackage (project.renderers.buildPythonPackage { inherit python; })`. Only reach for it when the project has a `pyproject.toml`; otherwise stay devshell-only and say so.
- **Format**: `programs.ruff-format.enable` (or `black` if the repo already uses it).

## Go

- **Package** with `buildGoModule` per the [NixOS wiki](https://wiki.nixos.org/wiki/Go) (`vendorHash` from a `lib.fakeHash` first build; `null` if deps are vendored).
- **Format**: `programs.gofmt.enable`.
- **Devshell**: `go`, `gopls`, `gotools`.

## Accompanying NixOS / nix-darwin modules

When the package is a daemon/service meant to run under systemd or launchd, ship a module alongside it:

```
nix/modules/
├── options.nix      # shared option declarations (one source of truth)
├── nixos.nix        # systemd service, imports options.nix
└── nix-darwin.nix   # launchd service, imports options.nix
```

Export modules (or configurations) through flake-parts' [`modules` flake module](https://flake.parts/options/flake-parts-modules.html): add `flake-parts.flakeModules.modules` to nix-base's `imports` and declare under `flake.modules.<class>.<name>` — flake-parts then exposes them as the conventional flake outputs (`nixosModules`, `darwinModules`, and likewise `nixosConfigurations`/`darwinConfigurations`):

```nix
outputs = inputs@{ flake-parts, ... }:
  flake-parts.lib.mkFlake { inherit inputs; } {
    imports = [
      inputs.flake-parts.flakeModules.modules
      inputs.treefmt-nix.flakeModule
    ];

    flake.modules.nixos.default = ./nix/modules/nixos.nix;
    flake.modules.darwin.default = ./nix/modules/nix-darwin.nix;

    systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    perSystem = { pkgs, ... }: { /* packages, devShells, treefmt */ };
  };
```

Ask the user whether they deploy via NixOS, nix-darwin, or both before writing modules — don't scaffold both speculatively.

## Overlays

Avoid overlays unless consumers need the packages inside their own `pkgs`. To export one, import flake-parts' [`easyOverlay`](https://flake.parts/options/flake-parts-easyoverlay.html) (`flake-parts.flakeModules.easyOverlay`) and set `perSystem.overlayAttrs` (e.g. `overlayAttrs = { inherit (config.packages) foo; };`); it becomes `overlays.default`. Don't use it to consume overlays — set `perSystem._module.args.pkgs = import inputs.nixpkgs { inherit system; overlays = [ … ]; }` instead.
