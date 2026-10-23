_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    attrsToList
    concatMapStrings
    escapeShellArg
    escapeShellArgs
    filter
    length
    literalExpression
    makeBinPath
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    mkOverride
    nameValuePair
    optionalString
    optionals
    types
    ;

  cfg = config.security.acme;
  inherit (cfg) stateDir;

  defaultOption =
    name: description:
    mkOption {
      type = types.str;
      default = cfg.defaults.${name};
      defaultText = literalExpression "config.security.acme.defaults.${name}";
      inherit description;
    };

  certModule =
    { name, ... }:
    {
      options = {
        email = defaultOption "email" "Email address for the ACME account.";
        server = defaultOption "server" "ACME directory URL.";
        group = defaultOption "group" "Group that owns the certificate files.";

        webroot = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Directory to serve HTTP-01 challenges from. Exclusive of `dnsProvider` and `listenHTTP`.";
        };

        listenHTTP = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = ":80";
          description = ''
            Interface and port of lego's own HTTP-01 server, which only
            listens while the certificate is renewed: for hosts without a web
            server on :80 to serve a webroot. Exclusive of `webroot` and
            `dnsProvider`.
          '';
        };

        dnsProvider = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "cloudflare";
          description = "lego's DNS provider for DNS-01 challenges. Exclusive of `webroot` and `listenHTTP`.";
        };

        credentialFiles = mkOption {
          type = types.attrsOf types.path;
          default = { };
          example = {
            CLOUDFLARE_DNS_API_TOKEN = "/run/secrets/cf-token";
          };
          description = "Environment variables for lego, each read from a file.";
        };

        environmentFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "File of KEY=VALUE pairs sourced before lego runs. Prefer `credentialFiles`.";
        };

        reloadServices = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "nginx" ];
          description = "`launchd.daemons` to send SIGHUP once the certificate is renewed.";
        };

        postRun = mkOption {
          type = types.lines;
          default = "";
          description = "Shell commands to run once the certificate is issued or renewed.";
        };

        keyType = mkOption {
          type = types.enum [
            "ec256"
            "ec384"
            "rsa2048"
            "rsa4096"
          ];
          default = "ec256";
          description = "Key algorithm.";
        };

        validMinDays = mkOption {
          type = types.int;
          default = 30;
          description = "Minimum days of validity left before the certificate is renewed.";
        };

        renewInterval = mkOption {
          type = types.enum [
            "daily"
            "hourly"
          ];
          default = "daily";
          description = "How often to check whether the certificate needs renewing.";
        };

        extraLegoFlags = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra flags passed verbatim to lego.";
        };

        directory = mkOption {
          type = types.str;
          default = "${stateDir}/${name}";
          defaultText = literalExpression ''"''${config.security.acme.stateDir}/<name>"'';
          readOnly = true;
          description = ''
            Directory holding the certificate, laid out as on NixOS:
            {file}`key.pem`, {file}`fullchain.pem`, {file}`chain.pem`, and
            {file}`cert.pem`, a link to {file}`fullchain.pem`.
          '';
        };
      };
    };

  renew =
    name: c:
    pkgs.writeShellScript "acme-${name}" ''
      set -euo pipefail
      PATH=${makeBinPath [ pkgs.lego ]}:$PATH
      ${optionalString (c.environmentFile != null) ''
        set -a
        source ${escapeShellArg c.environmentFile}
        set +a
      ''}
      ${concatMapStrings (v: ''
        export ${v.name}="$(cat ${escapeShellArg v.value})"
      '') (attrsToList c.credentialFiles)}
      ${builtins.readFile ./renew.sh}
      ${concatMapStrings (svc: ''
        launchctl kill HUP system/${config.launchd.labelPrefix}.${svc} 2>/dev/null || true
      '') c.reloadServices}
      ${c.postRun}
    '';

  legoFlags =
    name: c:
    [
      "--path"
      stateDir
      "--email"
      c.email
      "--server"
      c.server
      "--key-type"
      c.keyType
      "--domains"
      name
      "--accept-tos"
    ]
    ++ optionals (c.dnsProvider != null) [
      "--dns"
      c.dnsProvider
    ]
    ++ optionals (c.webroot != null) [
      "--http"
      "--http.webroot"
      "${c.webroot}"
    ]
    ++ optionals (c.listenHTTP != null) [
      "--http"
      "--http.port"
      c.listenHTTP
    ]
    ++ c.extraLegoFlags;

  selfsigned = pkgs.writeShellScript "acme-selfsigned" ''
    PATH=${makeBinPath [ pkgs.minica ]}:$PATH
    ${builtins.readFile ./selfsigned.sh}
  '';

  calendar = {
    daily = [
      {
        Hour = 2;
        Minute = 37;
      }
    ];
    hourly = [ { Minute = 13; } ];
  };

  log = path: {
    StandardOutPath = mkOverride 1100 path;
    StandardErrorPath = mkOverride 1100 path;
  };
in
{
  options.security.acme = {
    stateDir = mkOption {
      type = types.str;
      default = "/private/var/lib/acme";
      description = "Directory the certificates are kept in.";
    };

    acceptTerms = mkOption {
      type = types.bool;
      default = false;
      description = "Accept the CA's terms of service. Required.";
    };

    preliminarySelfsigned = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to put a self-signed certificate in place until the real one is issued, so its users can start.";
    };

    defaults = {
      email = mkOption {
        type = types.str;
        default = "";
        description = "Email address for every certificate's ACME account.";
      };
      server = mkOption {
        type = types.str;
        default = "https://acme-v02.api.letsencrypt.org/directory";
        description = "ACME directory URL for every certificate.";
      };
      group = mkOption {
        type = types.str;
        default = "_acme";
        description = "Group that owns every certificate's files.";
      };
    };

    certs = mkOption {
      type = types.attrsOf (types.submodule certModule);
      default = { };
      description = "Certificates, by domain, issued and renewed with lego.";
    };
  };

  config = mkIf (cfg.certs != { }) {
    assertions = [
      {
        assertion = cfg.acceptTerms;
        message = "security.acme: you must set acceptTerms = true to accept the CA's terms of service.";
      }
    ]
    ++ mapAttrsToList (name: c: {
      assertion =
        length (
          filter (x: x != null) [
            c.webroot
            c.dnsProvider
            c.listenHTTP
          ]
        ) <= 1;
      message = "security.acme.certs.\"${name}\": webroot, dnsProvider and listenHTTP are mutually exclusive.";
    }) cfg.certs;

    ids.uids._acme = 4096;
    ids.gids._acme = 4096;

    users.users._acme = {
      uid = config.ids.uids._acme;
      gid = config.ids.gids._acme;
      description = "ACME certificate manager";
      home = stateDir;
      createHome = true;
      shell = "/usr/bin/false";
    };
    users.groups._acme = {
      gid = config.ids.gids._acme;
      description = "System group for ACME";
    };
    users.knownUsers = [ "_acme" ];
    users.knownGroups = [ "_acme" ];

    system.build.acme = mapAttrs renew cfg.certs;

    system.activationScripts.postActivation.text = ''
      mkdir -p /var/log/acme ${escapeShellArg stateDir}/acme-challenge
      chown -R _acme:_acme ${escapeShellArg stateDir} 2>/dev/null || true
    '';

    launchd.daemons = mkMerge [
      (mkIf cfg.preliminarySelfsigned (
        mapAttrs' (
          name: c:
          nameValuePair "acme-selfsigned-${name}" {
            command = "${selfsigned} ${
              escapeShellArgs [
                stateDir
                name
                c.group
              ]
            }";
            serviceConfig = {
              RunAtLoad = true;
            }
            // log "/var/log/acme/selfsigned-${name}.log";
          }
        ) cfg.certs
      ))
      (mapAttrs' (
        name: c:
        nameValuePair "acme-${name}" {
          command = "${config.system.build.acme.${name}} ${
            escapeShellArgs (
              [
                stateDir
                name
                c.group
                (toString c.validMinDays)
              ]
              ++ legoFlags name c
            )
          }";
          serviceConfig = {
            RunAtLoad = true;
            StartCalendarInterval = calendar.${c.renewInterval};
          }
          // log "/var/log/acme/${name}.log";
        }
      ) cfg.certs)
    ];
  };
}
