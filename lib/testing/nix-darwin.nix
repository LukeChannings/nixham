# nix-darwin systems with nixham's modules, for the modules' tests.
{
  lib,
  writeText,
  nix-darwin,
  darwinModules,
}:
let
  # A check reads the config as text: it must not build the darwin closure.
  plain = s: builtins.unsafeDiscardStringContext (toString s);
in
{
  eval =
    modules:
    let
      system = nix-darwin.lib.darwinSystem {
        modules = [
          darwinModules.default
          {
            nixpkgs.hostPlatform = "aarch64-darwin";
            system.stateVersion = 6;
            system.primaryUser = "alice";
          }
        ]
        ++ modules;
      };
      inherit (system) config;
    in
    system
    // {
      failedAssertions = map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
      agent = name: config.launchd.user.agents.${name};
      daemon = name: config.launchd.daemons.${name};
      script =
        name:
        plain (
          config.launchd.user.agents.${name}.command.text or config.launchd.user.agents.${name}.command
        );
    };

  # esc <string>: one shell word. json <value>: its JSON, as one shell word.
  # text <name> <string>: a file holding it.
  esc = s: lib.escapeShellArg (plain s);
  json = v: lib.escapeShellArg (plain (builtins.toJSON v));
  text = name: s: writeText name (plain s);
}
