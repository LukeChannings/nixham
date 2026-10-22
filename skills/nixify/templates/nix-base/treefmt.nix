{ lib, pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;
  programs.deadnix.enable = true;
  programs.statix.enable = true;
  # `nix-build -A` only auto-calls a `{ ... }:` default.nix, not `_:`.
  programs.statix.disabled-lints = [ "empty_pattern" ];
  programs.just.enable = true;
  programs.shfmt.enable = true;
  programs.yamllint.enable = true;
  programs.actionlint.enable = true;
  settings.formatter.actionlint.options = [
    "-config-file"
    ".forgejo/actionlint.yaml"
  ];

  settings.formatter.forgejo-schema = {
    command = lib.getExe (
      pkgs.writeShellApplication {
        name = "forgejo-schema-validate";
        runtimeInputs = [ pkgs.forgejo-runner ];
        text = ''
          for f in "$@"; do
            case "$f" in
              */action.yaml | */action.yml)
                forgejo-runner validate --action --path "$f" ;;
              *)
                forgejo-runner validate --workflow --path "$f" ;;
            esac
          done
        '';
      }
    );
    includes = [
      ".forgejo/workflows/*.yaml"
      ".forgejo/workflows/*.yml"
      ".forgejo/**/action.yaml"
      ".forgejo/**/action.yml"
    ];
  };
}
