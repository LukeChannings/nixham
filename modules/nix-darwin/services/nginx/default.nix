_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mapAttrs
    filterAttrs
    types
    concatStringsSep
    concatMapStringsSep
    mapAttrsToList
    optionalString
    literalExpression
    filter
    any
    all
    attrNames
    attrValues
    concatMap
    optional
    optionals
    splitString
    hasPrefix
    ;

  cfg = config.services.nginx;

  # A file, so locations can include it again: a location's own
  # proxy_set_header drops the http block's.
  recommendedProxyConfig = pkgs.writeText "nginx-recommended-proxy_set_header-headers.conf" ''
    proxy_set_header        Host $host;
    proxy_set_header        X-Real-IP $remote_addr;
    proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Proto $scheme;
    proxy_set_header        X-Forwarded-Host $host;
    proxy_set_header        X-Forwarded-Server $hostname;
  '';

  locationOpts = {
    options = {
      proxyPass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Upstream URL to proxy to.";
      };

      proxyWebsockets = mkOption {
        type = types.bool;
        default = false;
        description = "Add Upgrade/Connection headers for WebSocket proxying.";
      };

      recommendedProxySettings = mkOption {
        type = types.bool;
        default = cfg.recommendedProxySettings;
        defaultText = literalExpression "config.services.nginx.recommendedProxySettings";
        description = "Include the recommended proxy_set_header set in this location (only when proxyPass is set).";
      };

      root = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Serve files from this directory.";
      };

      return = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Return a status/redirect, e.g. \"301 https://\\$host\\$request_uri\".";
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra nginx directives for this location block.";
      };
    };
  };

  vhostOpts =
    { name, ... }:
    {
      options = {
        serverName = mkOption {
          type = types.nullOr types.str;
          default = name;
          description = "server_name directive value. Defaults to the attrset key.";
        };

        serverAliases = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional server_name entries.";
        };

        listen = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                addr = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "127.0.0.1";
                  description = ''
                    Listen address. IPv6 addresses must be enclosed in square
                    brackets; `unix:` socket paths are accepted. When null, nginx
                    listens on all IPv4 addresses only (`*:port`).
                  '';
                };
                port = mkOption {
                  type = types.nullOr types.port;
                  default = null;
                  description = ''
                    Port to listen on. If null, nginx's default applies (80 for
                    an address; unused for a `unix:` socket). At least one of
                    `addr` and `port` must be set.
                  '';
                };
                ssl = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Enable SSL on this port.";
                };
                extraParameters = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Extra parameters appended to the listen directive.";
                };
              };
            }
          );
          default = [ ];
          description = ''
            Explicit listen directives. If empty, derived from `listenAddresses`
            (or {option}`services.nginx.defaultListenAddresses`) and
            forceSSL/addSSL/onlySSL.
            With forceSSL, only the `ssl = true` entries are used for the main
            server and the non-SSL entries for the HTTP redirect server.
          '';
        };

        listenAddresses = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "127.0.0.1"
            "[::1]"
          ];
          description = ''
            Listen addresses for this virtual host.
            Compared to `listen` this only sets the addresses
            and the ports are chosen automatically.

            Note: This option overrides {option}`services.nginx.enableIPv6`
          '';
        };

        forceSSL = mkOption {
          type = types.bool;
          default = false;
          description = "Redirect all HTTP to HTTPS and serve on 443 SSL.";
        };

        addSSL = mkOption {
          type = types.bool;
          default = false;
          description = "Enable HTTPS in addition to HTTP.";
        };

        onlySSL = mkOption {
          type = types.bool;
          default = false;
          description = "Only listen on HTTPS, no HTTP.";
        };

        enableACME = mkOption {
          type = types.bool;
          default = false;
          description = "Obtain a cert via ACME for this vhost. Requires security.acme to be configured.";
        };

        useACMEHost = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Reuse a security.acme.certs.<name> cert. Auto-sets ssl_certificate paths.";
        };

        acmeRoot = mkOption {
          type = types.str;
          default = "/var/lib/acme/acme-challenge";
          description = "Webroot directory for HTTP-01 ACME challenges.";
        };

        sslCertificate = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to SSL certificate (fullchain). Auto-set when useACMEHost or enableACME is used.";
        };

        sslCertificateKey = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to SSL private key. Auto-set when useACMEHost or enableACME is used.";
        };

        locations = mkOption {
          type = types.attrsOf (types.submodule locationOpts);
          default = { };
          description = "Location blocks keyed by path prefix.";
        };

        extraConfig = mkOption {
          type = types.lines;
          default = "";
          description = "Extra directives inside the server block.";
        };
      };
    };

  resolvedVhost =
    name: vhost:
    let
      certName =
        if vhost.useACMEHost != null then
          vhost.useACMEHost
        else if vhost.enableACME then
          name
        else
          null;
      certDir =
        if certName != null then
          (config.security.acme.certs.${certName}.directory or "/var/lib/acme/${certName}")
        else
          null;
    in
    vhost
    // (
      if certDir != null then
        {
          sslCertificate =
            if vhost.sslCertificate != null then vhost.sslCertificate else "${certDir}/fullchain.pem";
          sslCertificateKey =
            if vhost.sslCertificateKey != null then vhost.sslCertificateKey else "${certDir}/key.pem";
        }
      else
        { }
    );

  listenString =
    l:
    let
      target =
        if l.addr == null then
          toString l.port
        else
          l.addr + optionalString (l.port != null) ":${toString l.port}";
    in
    "listen ${target}${optionalString l.ssl " ssl"}${
      optionalString (l.extraParameters != [ ]) (" " + concatStringsSep " " l.extraParameters)
    };";

  # As on NixOS: listen, else listenAddresses, else defaultListenAddresses.
  vhostListen =
    vhost:
    if vhost.listen != [ ] then
      vhost.listen
    else
      let
        addrs = if vhost.listenAddresses != [ ] then vhost.listenAddresses else cfg.defaultListenAddresses;
        hasSSL = vhost.onlySSL || vhost.addSSL || vhost.forceSSL;
        entry = port: ssl: addr: {
          inherit addr ssl;
          port = if hasPrefix "unix:" addr then null else port;
          extraParameters = [ ];
        };
      in
      optionals hasSSL (map (entry 443 true) addrs)
      ++ optionals (!vhost.onlySSL) (map (entry 80 false) addrs);

  hostListen =
    vhost:
    let
      entries = vhostListen vhost;
    in
    if vhost.forceSSL then filter (l: l.ssl) entries else entries;

  listenLines = vhost: concatMapStringsSep "\n    " listenString (hostListen vhost);

  locationBlock =
    path: loc:
    let
      wsExtra = optionalString loc.proxyWebsockets ''
        proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;'';
    in
    ''
      location ${path} {
        ${optionalString (loc.proxyPass != null) "proxy_pass ${loc.proxyPass};"}
        ${wsExtra}
        ${optionalString (loc.root != null) "root ${loc.root};"}
        ${optionalString (loc.return != null) "return ${loc.return};"}
        ${loc.extraConfig}
        ${optionalString (
          loc.proxyPass != null && loc.recommendedProxySettings
        ) "include ${recommendedProxyConfig};"}
      }'';

  serverBlock =
    name: rawVhost:
    let
      vhost = resolvedVhost name rawVhost;
      serverNames = concatStringsSep " " (
        [ (if vhost.serverName != null then vhost.serverName else name) ] ++ vhost.serverAliases
      );
      sslDirectives = optionalString (vhost.sslCertificate != null) ''
        ssl_certificate     ${vhost.sslCertificate};
        ssl_certificate_key ${vhost.sslCertificateKey};'';
      redirectListen = filter (l: !l.ssl) (vhostListen vhost);
      httpRedirectServer = optionalString vhost.forceSSL ''
        server {
          ${
            if redirectListen != [ ] then
              concatMapStringsSep "\n    " listenString redirectListen
            else
              "listen 80;"
          }
          server_name ${serverNames};
          location /.well-known/acme-challenge/ {
            root ${vhost.acmeRoot};
          }
          location / {
            return 301 https://$host$request_uri;
          }
        }
      '';
      locationBlocks = concatStringsSep "\n" (mapAttrsToList locationBlock vhost.locations);
    in
    ''
      ${httpRedirectServer}
      server {
        ${listenLines vhost}
        server_name ${serverNames};
        ${sslDirectives}
        ${locationBlocks}
        ${vhost.extraConfig}
      }
    '';

  toUpstreamParameter =
    key: value: if builtins.isBool value then optionalString value key else "${key}=${toString value}";

  upstreamConfig = concatStringsSep "\n" (
    mapAttrsToList (name: upstream: ''
      upstream ${name} {
        ${concatStringsSep "\n    " (
          mapAttrsToList (
            server: params:
            "server ${
              concatStringsSep " " ([ server ] ++ filter (p: p != "") (mapAttrsToList toUpstreamParameter params))
            };"
          ) upstream.servers
        )}
        ${upstream.extraConfig}
      }'') cfg.upstreams
  );

  resolverConfig =
    optionalString (cfg.resolver.addresses != [ ])
      "resolver ${
        concatStringsSep " " (
          cfg.resolver.addresses
          ++ optional (cfg.resolver.valid != "") "valid=${cfg.resolver.valid}"
          ++ optional (!cfg.resolver.ipv4) "ipv4=off"
          ++ optional (!cfg.resolver.ipv6) "ipv6=off"
        )
      };";

  hasDirective =
    directive: lines:
    any (line: builtins.match "[[:space:]]*${directive}[[:space:]].*" line != null) (
      splitString "\n" lines
    );

  resolvingUpstreams = filterAttrs (
    _: upstream: any (s: s.resolve or false) (attrValues upstream.servers)
  ) cfg.upstreams;

  # Warnings, not assertions: NixOS evaluates such configs, though nginx
  # rejects them.
  upstreamsMissingZone = attrNames (
    filterAttrs (_: upstream: !(hasDirective "zone" upstream.extraConfig)) resolvingUpstreams
  );

  upstreamsMissingResolver = attrNames (
    filterAttrs (
      _: upstream:
      cfg.resolver.addresses == [ ]
      && !(any (hasDirective "resolver") [
        upstream.extraConfig
        cfg.commonHttpConfig
        cfg.appendHttpConfig
      ])
    ) resolvingUpstreams
  );

  explicitListens = concatMap (v: v.listen) (attrValues cfg.virtualHosts);

  nginxConf = pkgs.writeText "nginx.conf" ''
    ${cfg.prependConfig}

    user ${cfg.user} ${cfg.group};
    worker_processes auto;
    error_log /var/log/nginx/error.log;
    pid /var/run/nginx/nginx.pid;

    events {
      worker_connections 1024;
    }

    http {
      include       ${cfg.package}/conf/mime.types;
      default_type  application/octet-stream;
      access_log    /var/log/nginx/access.log;
      sendfile      on;

      ${resolverConfig}
      ${upstreamConfig}

      ${optionalString cfg.recommendedProxySettings ''
        proxy_redirect          off;
        proxy_connect_timeout   ${cfg.proxyTimeout};
        proxy_send_timeout      ${cfg.proxyTimeout};
        proxy_read_timeout      ${cfg.proxyTimeout};
        proxy_http_version      1.1;
        proxy_set_header        "Connection" "";
        include ${recommendedProxyConfig};
      ''}

      map $http_upgrade $connection_upgrade {
        default upgrade;
        '''      close;
      }

      client_max_body_size ${cfg.clientMaxBodySize};
      ${cfg.commonHttpConfig}

      ${concatStringsSep "\n" (mapAttrsToList serverBlock cfg.virtualHosts)}

      ${cfg.appendHttpConfig}
    }
  '';

  vhostsWithACME = filterAttrs (_: v: v.enableACME) cfg.virtualHosts;
in
{
  options.services.nginx = {
    enable = mkEnableOption "nginx web server";

    package = lib.mkPackageOption pkgs "nginx" { };

    user = mkOption {
      type = types.str;
      default = "_nginx";
      description = "User account nginx runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "_nginx";
      description = "Group nginx runs as. Also added to the acme group when certs are used.";
    };

    enableIPv6 = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether virtual hosts without `listen` or `listenAddresses` also
        listen on IPv6, by adding `[::0]` to
        {option}`services.nginx.defaultListenAddresses`. Stands in for
        NixOS's `networking.enableIPv6`, which nix-darwin does not have.
      '';
    };

    defaultListenAddresses = mkOption {
      type = types.listOf types.str;
      default = [ "0.0.0.0" ] ++ optional cfg.enableIPv6 "[::0]";
      defaultText = literalExpression ''[ "0.0.0.0" ] ++ lib.optional config.services.nginx.enableIPv6 "[::0]"'';
      example = literalExpression ''[ "10.0.0.12" "[2002:a00:1::]" ]'';
      description = ''
        If vhosts do not specify listenAddresses, use these addresses by default.
      '';
    };

    clientMaxBodySize = mkOption {
      type = types.str;
      default = "10m";
      description = "client_max_body_size directive. Use \"0\" to disable.";
    };

    commonHttpConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Additional directives in the http{} block, placed before the virtual hosts.";
    };

    prependConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Configuration lines prepended to the generated nginx configuration
        file, e.g. to load modules. Can be specified more than once.
      '';
    };

    appendHttpConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Configuration lines appended to the generated http{} block, after the virtual hosts.";
    };

    recommendedProxySettings = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable NixOS' recommended proxy settings (timeouts, HTTP/1.1 keep-alive
        to upstreams, and the Host/X-Real-IP/X-Forwarded-* header set) for the
        http block and, by default, every location with a proxyPass.
      '';
    };

    proxyTimeout = mkOption {
      type = types.str;
      default = "60s";
      example = "20s";
      description = "Proxy connect/send/read timeout used by recommendedProxySettings.";
    };

    resolver = mkOption {
      type = types.submodule {
        options = {
          addresses = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = literalExpression ''[ "[::1]" "127.0.0.1:5353" ]'';
            description = "List of resolvers to use.";
          };
          valid = mkOption {
            type = types.str;
            default = "";
            example = "30s";
            description = "Override the TTL nginx caches answers for.";
          };
          ipv4 = mkOption {
            type = types.bool;
            default = true;
            description = "Look up IPv4 addresses (`ipv4=off` when false).";
          };
          ipv6 = mkOption {
            type = types.bool;
            default = true;
            description = "Look up IPv6 addresses (`ipv6=off` when false).";
          };
        };
      };
      default = { };
      description = ''
        Name servers used to resolve upstream server names, required by
        upstream servers with `resolve = true`.
      '';
    };

    upstreams = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            servers = mkOption {
              type = types.attrsOf (
                types.submodule {
                  freeformType = types.attrsOf (
                    types.oneOf [
                      types.bool
                      types.int
                      types.str
                    ]
                  );
                  options = {
                    backup = mkOption {
                      type = types.bool;
                      default = false;
                      description = ''
                        Marks the server as a backup server. It will be passed
                        requests when the primary servers are unavailable.
                      '';
                    };
                  };
                }
              );
              default = { };
              description = ''
                Upstream servers keyed by address, with their parameters.
                Booleans render as bare flags (e.g. `resolve = true;`), other
                values as `key=value`. See
                <https://nginx.org/en/docs/http/ngx_http_upstream_module.html#server>.
              '';
            };
            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Lines appended to the upstream block verbatim (e.g. `zone`, `keepalive`).";
            };
          };
        }
      );
      default = { };
      example = literalExpression ''
        {
          cache = {
            servers."garage-a.internal:3900" = { resolve = true; };
            servers."garage-b.internal:3900" = { resolve = true; backup = true; };
            extraConfig = "zone cache 1m;";
          };
        }
      '';
      description = "Groups of servers usable as proxy_pass targets.";
    };

    enableReload = mkOption {
      type = types.bool;
      default = false;
      description = "Send SIGHUP to nginx after darwin-rebuild switch when config changes.";
    };

    virtualHosts = mkOption {
      type = types.attrsOf (types.submodule vhostOpts);
      default = { };
      description = "Virtual host definitions. Keys used as default server_name.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = all (l: l.addr != null || l.port != null) explicitListens;
        message = "services.nginx.virtualHosts.<name>.listen entries need at least one of addr and port.";
      }
      {
        assertion = cfg.resolver.ipv4 || cfg.resolver.ipv6;
        message = "At least one of services.nginx.resolver.ipv4 and services.nginx.resolver.ipv6 must be true.";
      }
    ];

    warnings =
      optional (upstreamsMissingZone != [ ]) ''
        services.nginx.upstreams: ${concatStringsSep ", " upstreamsMissingZone} use `resolve`
        without a `zone` directive in extraConfig; nginx will reject this config.
      ''
      ++ optional (upstreamsMissingResolver != [ ]) ''
        services.nginx.upstreams: ${concatStringsSep ", " upstreamsMissingResolver} use `resolve`
        but no resolver is configured (services.nginx.resolver.addresses or a `resolver`
        directive); nginx will reject this config.
      '';

    ids.uids._nginx = 4097;
    ids.gids._nginx = 4097;

    users.users._nginx = {
      uid = config.ids.uids._nginx;
      gid = config.ids.gids._nginx;
      description = "nginx web server";
      home = "/var/empty";
      shell = "/usr/bin/false";
    };
    users.groups._nginx = {
      gid = config.ids.gids._nginx;
      description = "System group for nginx";
    };
    users.knownUsers = [ "_nginx" ];
    users.knownGroups = [ "_nginx" ];

    users.groups._acme.members = mkIf (any (v: v.useACMEHost != null || v.enableACME) (
      attrValues cfg.virtualHosts
    )) [ cfg.user ];

    security.acme.certs = mapAttrs (name: _: {
      webroot = cfg.virtualHosts.${name}.acmeRoot;
      reloadServices = [ "nginx" ];
    }) vhostsWithACME;

    launchd.daemons.nginx = {
      # /var/run is emptied at boot, and nginx won't create its pid dir.
      script = ''
        /bin/mkdir -p /var/log/nginx /var/run/nginx
        /usr/sbin/chown ${cfg.user}:${cfg.group} /var/log/nginx /var/run/nginx 2>/dev/null || true
        exec ${cfg.package}/bin/nginx -g 'daemon off;' -c ${nginxConf}
      '';
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = lib.mkOverride 1100 "/var/log/nginx/stdout.log";
        StandardErrorPath = lib.mkOverride 1100 "/var/log/nginx/stderr.log";
      };
    };

    system.activationScripts.postActivation.text = ''
      mkdir -p /var/log/nginx /var/run/nginx
      chown ${cfg.user}:${cfg.group} /var/log/nginx /var/run/nginx 2>/dev/null || true
    ''
    + optionalString cfg.enableReload ''
      launchctl kill HUP system/${config.launchd.daemons.nginx.serviceConfig.Label} 2>/dev/null || true
    '';
  };
}
