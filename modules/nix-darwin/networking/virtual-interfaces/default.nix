_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    any
    attrNames
    concatMapStringsSep
    concatStringsSep
    filter
    groupBy
    head
    length
    literalExpression
    mapAttrsToList
    mkIf
    mkOption
    mod
    removePrefix
    toInt
    toLower
    types
    unique
    ;

  cfg = config.networking.virtualInterfaces;

  label = config.launchd.daemons.virtual-interfaces.serviceConfig.Label;

  # On the root volume: legs come up long before a late /nix mounts.
  installedScript = "/usr/local/libexec/nix-darwin/virtual-interfaces";
  # /var/run is emptied at boot, so a leg without a stamp is (re)armed.
  stateDir = "/var/run/nix-darwin-virtual-interfaces";

  validName = name: builtins.match "feth(0|[1-9][0-9]*)" name != null;
  unitOf = name: toInt (removePrefix "feth" name);
  b2s = b: if b then "1" else "0";

  legs = mapAttrsToList (name: leg: {
    inherit name;
    inherit (leg) parent;
    tag = toString leg.vlanId;
    mac = toLower leg.macAddress;
    peer = "feth${toString (unitOf name + 1)}";
    dhcp = b2s leg.dhcp;
    ipv6 = b2s leg.ipv6;
  }) cfg;

  uplinks = mapAttrsToList (tag: tagLegs: {
    inherit tag;
    inherit (head tagLegs) parent;
    parents = unique (map (leg: leg.parent) tagLegs);
  }) (groupBy (leg: leg.tag) legs);

  script = pkgs.writeText "virtual-interfaces" ''
    #!/bin/sh
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    state_dir=${stateDir}
    stable_v6=${b2s (any (l: l.ipv6 == "1") legs)}
    uplinks='${concatMapStringsSep "\n" (u: "${u.tag} ${u.parent}") uplinks}'
    legs='${
      concatMapStringsSep "\n" (
        l: "${l.name} ${l.peer} ${l.tag} ${l.parent} ${l.mac} ${l.dhcp} ${l.ipv6}"
      ) legs
    }'
    ${builtins.readFile ./virtual-interfaces.sh}
  '';

  legModule = {
    options = {
      parent = mkOption {
        type = types.strMatching "[a-z]+[0-9]+";
        example = "en0";
        description = "The physical interface carrying the leg's 802.1Q uplink.";
      };

      vlanId = mkOption {
        type = types.ints.between 1 4094;
        example = 40;
        description = ''
          The 802.1Q tag of the network the leg joins. Legs sharing a tag
          share one `bridge<vlanId>` and one `vlan<vlanId>` uplink, so must
          share a `parent`.

          vmnet (apple-container, Virtualization.framework's shared
          networking) allocates `bridge100` and up, so prefer tags below 100.
        '';
      };

      macAddress = mkOption {
        type = types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}";
        example = "02:4c:4c:4d:00:01";
        description = ''
          The leg's unicast MAC address, ideally locally administered (e.g.
          `02:…`).

          It is the leg's identity on the network: the DHCP server's
          reservation for it decides the leg's addresses and DNS name.
          configd always sends the host's LocalHostName as the DHCP
          hostname, with no per-interface override.
        '';
      };

      dhcp = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to acquire an IPv4 address with DHCP. It is retried until
          a lease lands: a macOS DHCP client that gets no reply downs the
          interface and gives up.
        '';
      };

      ipv6 = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to arm IPv6 with `ipconfig set <if> AUTOMATIC-V6`. With a
          managed RA this takes a stateful DHCPv6 address; macOS SLAAC only
          forms RFC 7217 identifiers, never EUI-64. Without one the leg gets
          only SLAAC and link-local addresses.

          Any leg with IPv6 also pins the host to stable source addresses
          (`net.inet6.ip6.prefer_tempaddr=0`): temporary addresses
          regenerate every time a leg is re-armed, stranding established
          connections sourced from them.
        '';
      };
    };
  };

  badNames = filter (name: !validName name) (attrNames cfg);
  oddNames = filter (name: validName name && mod (unitOf name) 2 != 0) (attrNames cfg);
  multicastMacs = filter (leg: builtins.match ".[13579bdf]:.*" leg.mac != null) legs;
  conflictingTags = filter (uplink: length uplink.parents > 1) uplinks;
  macs = map (leg: leg.mac) legs;
in
{
  options.networking.virtualInterfaces = mkOption {
    type = types.attrsOf (types.submodule legModule);
    default = { };
    example = literalExpression ''
      {
        feth50 = {
          parent = "en0";
          vlanId = 40;
          macAddress = "02:4c:4c:4d:00:01";
        };
      }
    '';
    description = ''
      Per-service virtual network interfaces ("legs"), each with its own MAC
      address and DHCP lease on a tagged VLAN.

      Each name is the interface to create, an even-numbered `fethN`: macOS
      only creates interfaces through its cloners (never `enN`), and the
      unit numbers are the legs' identity. `fethN` holds the MAC and the
      lease; its peer, `feth(N+1)`, joins `bridge<vlanId>`, which carries a
      `vlan<vlanId>` uplink on `parent`.

      The `virtual-interfaces` launchd daemon plumbs the legs from a script
      on the root volume, so they come up seconds after boot rather than
      once /nix mounts. It runs again at every activation, and every 30
      seconds to repair legs vmnet detaches.

      A removed leg is no longer managed, but stays up until reboot.
    '';
  };

  config = {
    assertions = [
      {
        assertion = badNames == [ ];
        message = "networking.virtualInterfaces: interface names must be `fethN` (got ${concatStringsSep ", " badNames}); macOS can only create cloner-prefixed interfaces.";
      }
      {
        assertion = oddNames == [ ];
        message = "networking.virtualInterfaces: ${concatStringsSep ", " oddNames} must use an even unit number; the odd unit above each declared feth is its bridged peer.";
      }
      {
        assertion = multicastMacs == [ ];
        message = "networking.virtualInterfaces: ${
          concatMapStringsSep ", " (leg: "${leg.name} (${leg.mac})") multicastMacs
        } must have a unicast macAddress.";
      }
      {
        assertion = length (unique macs) == length macs;
        message = "networking.virtualInterfaces: every leg needs a distinct macAddress.";
      }
      {
        assertion = conflictingTags == [ ];
        message = "networking.virtualInterfaces: ${
          concatMapStringsSep "; " (
            uplink: "vlanId ${uplink.tag} is declared on parents ${concatStringsSep ", " uplink.parents}"
          ) conflictingTags
        }. Legs sharing a vlanId share bridge<vlanId>, so they must share a parent.";
      }
    ];

    # The ADR's exception: the daemon must run before /nix mounts, so it
    # needs a root-volume program, installed before launchd loads it, and
    # the script's store path in the plist so a new script reloads it.
    system.build.virtualInterfaces = script;

    launchd.daemons.virtual-interfaces = mkIf (cfg != { }) {
      serviceConfig = {
        Program = installedScript;
        RunAtLoad = true;
        StartInterval = 30;
        EnvironmentVariables.NIX_DARWIN_VIRTUAL_INTERFACES_SCRIPT = "${script}";
      };
    };

    system.activationScripts.preActivation.text = mkIf (cfg != { }) ''
      /usr/bin/install -d -m 0755 ${dirOf installedScript}
      /usr/bin/install -m 0755 ${script} ${installedScript}
    '';

    system.activationScripts.postActivation.text = mkIf (cfg != { }) ''
      echo "applying virtual network interfaces..." >&2
      /bin/launchctl kickstart -k system/${label} 2>/dev/null || true
    '';
  };
}
