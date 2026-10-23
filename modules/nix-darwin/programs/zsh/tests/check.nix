{
  lib,
  makeTest,
  darwin,
}:
let
  inherit (darwin) json;
  zsh = derivation {
    name = "zsh-custom";
    system = "aarch64-darwin";
    builder = "/bin/false";
  };
  installed =
    s:
    map (p: {
      inherit (p) name;
      priority = p.meta.priority or 5;
    }) (lib.filter (p: lib.hasPrefix "zsh-" p.name) s.config.environment.systemPackages);
in
makeTest {
  name = "zsh";
  tests = {
    "the package shadows nix-darwin's zsh" = ''
      run echo ${json (installed (darwin.eval [ { programs.zsh.package = zsh; } ]))}
      assert_output --partial '{"name":"zsh-custom","priority":-10}'
    '';
    "without zsh, no zsh is installed" = ''
      assert_equal ${json (installed (darwin.eval [ { programs.zsh.enable = false; } ]))} '[]'
    '';
  };
}
