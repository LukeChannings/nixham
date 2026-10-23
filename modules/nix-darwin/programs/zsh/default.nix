_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.zsh;
in
{
  options.programs.zsh.package = lib.mkPackageOption pkgs "zsh" { };

  # nix-darwin's zsh module installs pkgs.zsh unconditionally; the higher
  # priority shadows it in the system profile.
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ (lib.hiPrio cfg.package) ];
  };
}
