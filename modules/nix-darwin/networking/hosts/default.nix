_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    escapeShellArg
    filterAttrs
    mapAttrsToList
    mkAfter
    mkOption
    types
    ;

  entries = concatStringsSep "\n" (
    mapAttrsToList (ip: names: "${ip} ${concatStringsSep " " names}") (
      filterAttrs (_: names: names != [ ]) config.networking.hosts
    )
  );
in
{
  options.networking.hosts = mkOption {
    type = types.attrsOf (types.listOf types.str);
    default = { };
    example = {
      "192.168.0.2" = [
        "fileserver.local"
        "nameserver.local"
      ];
    };
    description = ''
      Static host entries, kept in a marked block of `/etc/hosts`. Lines
      outside the block are left alone, and the block is removed when no
      entries are declared.
    '';
  };

  config = {
    system.build.hosts = pkgs.writeText "hosts" ''
      PATH=/usr/bin:/bin:/usr/sbin:/sbin
      hosts_file=/etc/hosts
      entries=${escapeShellArg entries}
      ${builtins.readFile ./hosts.sh}
    '';

    system.activationScripts.postActivation.text = mkAfter ''
      /bin/sh ${config.system.build.hosts}
    '';
  };
}
