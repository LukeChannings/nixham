{
  lib,
  makeTest,
  darwin,
  nginx,
  openssl,
  runCommand,
}:
let
  inherit (darwin) esc json;
  certs = runCommand "nginx-test-cert" { nativeBuildInputs = [ openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=tls.internal \
      -keyout $out/key.pem -out $out/cert.pem
  '';
  tls = {
    sslCertificate = "${certs}/cert.pem";
    sslCertificateKey = "${certs}/key.pem";
  };

  eval =
    nginx:
    darwin.evalNative [
      {
        services.nginx = nginx // {
          enable = true;
        };
      }
    ];
  # With its context: the config is built for the test.
  script = s: lib.escapeShellArg s.config.launchd.daemons.nginx.script;

  s = eval {
    prependConfig = ''
      # prepend-marker
      worker_rlimit_nofile 4096;
    '';
    appendHttpConfig = ''
      # append-http-marker
      server_tokens off;
    '';
    recommendedProxySettings = true;
    proxyTimeout = "30s";
    resolver = {
      addresses = [ "127.0.0.1:5353" ];
      valid = "10s";
      ipv6 = false;
    };
    upstreams.cache = {
      servers."garage-a.invalid:3900".resolve = true;
      servers."garage-b.invalid:3900" = {
        resolve = true;
        backup = true;
        max_fails = 3;
      };
      extraConfig = "zone cache 1m;";
    };
    upstreams.static.servers."127.0.0.1:8080" = { };
    virtualHosts = {
      "gate.internal" = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8081;
          }
        ];
        locations."/" = {
          proxyPass = "http://cache";
          extraConfig = "proxy_set_header Authorization \"\";";
        };
        locations."/ws" = {
          proxyPass = "http://static";
          proxyWebsockets = true;
        };
        locations."/raw" = {
          proxyPass = "http://static";
          recommendedProxySettings = false;
        };
      };
      "sock.internal".listen = [ { addr = "unix:/tmp/nginx-test.sock"; } ];
      "port-only.internal".listen = [ { port = 8082; } ];
      "tls.internal" = tls // {
        forceSSL = true;
        listen = [
          {
            addr = "127.0.0.1";
            port = 8443;
            ssl = true;
          }
          {
            addr = "127.0.0.1";
            port = 8080;
          }
        ];
      };
      "default.internal" = tls // {
        forceSSL = true;
      };
      "plain.internal" = { };
      "addrs.internal" = tls // {
        addSSL = true;
        listenAddresses = [ "127.0.0.2" ];
      };
    };
  };
  noIPv6 = eval {
    enableIPv6 = false;
    virtualHosts."default.internal" = tls // {
      addSSL = true;
    };
    virtualHosts."addrs.internal".listenAddresses = [ "[::1]" ];
  };
  missing = eval {
    upstreams.cache.servers."a.invalid:3900".resolve = true;
  };
  acme = darwin.eval [
    {
      security.acme = {
        acceptTerms = true;
        defaults.email = "admin@example.com";
      };
      services.nginx = {
        enable = true;
        virtualHosts."acme.example.com" = {
          enableACME = true;
          forceSSL = true;
        };
      };
    }
  ];
  acmeHost = acme.config.security.acme.certs."acme.example.com";
in
makeTest {
  name = "nginx";
  inputs = [ nginx ];
  helpers = [
    ''
      # conf <script>: the nginx.conf the daemon's script runs nginx with.
      conf() {
        grep -o '/nix/store/[^ ]*-nginx.conf' <<<"$1" | head -1
      }

      # nginx_t <conf>: nginx -t, which binds the listens, with the paths
      # nginx writes in the test's, and unprivileged ports.
      nginx_t() {
        mkdir -p "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/run"
        sed -e "s|/var/log/nginx|$BATS_TEST_TMPDIR/log|g" -e "s|/var/run/nginx|$BATS_TEST_TMPDIR/run|g" \
          -e 's/:80;/:10080;/' -e 's/:443 ssl;/:10443 ssl;/' "$1" >"$BATS_TEST_TMPDIR/nginx.conf"
        nginx -t -p "$BATS_TEST_TMPDIR" -e "$BATS_TEST_TMPDIR/log/error.log" -c "$BATS_TEST_TMPDIR/nginx.conf"
      }
    ''
  ];
  setup = ''
    conf="$(conf ${script s})"
  '';
  tests = {
    "nginx accepts the config" = ''
      run nginx_t "$conf"
      assert_success
    '';
    "a valid config raises nothing" = ''
      assert_equal ${json (s.failedAssertions ++ s.config.warnings)} '[]'
    '';
    "the daemon recreates the dirs /var/run loses at boot, then runs nginx in the foreground" = ''
      run echo ${script s}
      assert_line '/bin/mkdir -p /var/log/nginx /var/run/nginx'
      assert_line --partial '/usr/sbin/chown _nginx:_nginx /var/log/nginx /var/run/nginx'
      assert_line --regexp "^exec /nix/store/[^ ]*/bin/nginx -g 'daemon off;' -c /nix/store/[^ ]*-nginx.conf$"
    '';
    "prependConfig opens the config, appendHttpConfig closes the http block" = ''
      head -n 5 "$conf" | grep -F '# prepend-marker'
      tail -n 5 "$conf" | grep -F 'server_tokens off;'
      [ "$(grep -n append-http-marker "$conf" | cut -d: -f1)" -gt "$(grep -n 'server_name gate.internal' "$conf" | cut -d: -f1)" ]
    '';
    "resolver and upstreams" = ''
      run cat "$conf"
      assert_line --partial 'resolver 127.0.0.1:5353 valid=10s ipv6=off;'
      assert_line --partial 'server garage-a.invalid:3900 resolve;'
      assert_line --partial 'server garage-b.invalid:3900 backup max_fails=3 resolve;'
      assert_line --partial 'zone cache 1m;'
      assert_line --partial 'server 127.0.0.1:8080;'
    '';
    "a resolve upstream without a zone or resolver is warned about" = ''
      run echo ${json missing.config.warnings}
      assert_output --partial 'cache use `resolve`\nwithout a `zone` directive'
      assert_output --partial 'cache use `resolve`\nbut no resolver is configured'
    '';
    "recommendedProxySettings, in the http block and each proxied location that keeps them" = ''
      run cat "$conf"
      assert_line --partial 'proxy_connect_timeout   30s;'
      assert_line --partial 'proxy_set_header        "Connection" "";'
      headers="$(grep -o '/nix/store/[^;]*-nginx-recommended-proxy_set_header-headers.conf' "$conf" | head -1)"
      run cat "$headers"
      assert_line --partial 'X-Forwarded-Server $hostname;'
      assert_equal "$(grep -c "include $headers;" "$conf")" 3
    '';
    "websockets are upgraded" = ''
      grep -F 'proxy_set_header Connection $connection_upgrade;' "$conf"
    '';
    "explicit listens" = ''
      run cat "$conf"
      assert_line --partial 'listen 127.0.0.1:8081;'
      assert_line --partial 'listen unix:/tmp/nginx-test.sock;'
      assert_line --partial 'listen 8082;'
      assert_line --partial 'listen 127.0.0.1:8443 ssl;'
      assert_equal "$(grep -c 'listen 127.0.0.1:8080;' "$conf")" 1
      run grep -E 'listen (80|443)( ssl)?;' "$conf"
      assert_failure
    '';
    "listens from defaultListenAddresses, IPv6 too, or listenAddresses" = ''
      assert_equal "$(grep -c 'listen 0.0.0.0:443 ssl;' "$conf")" 1
      assert_equal "$(grep -c 'listen \[::0\]:443 ssl;' "$conf")" 1
      assert_equal "$(grep -c 'listen 0.0.0.0:80;' "$conf")" 2
      assert_equal "$(grep -c 'listen \[::0\]:80;' "$conf")" 2
      grep -F 'listen 127.0.0.2:443 ssl;' "$conf"
      grep -F 'listen 127.0.0.2:80;' "$conf"
    '';
    "without IPv6, defaultListenAddresses are IPv4 only" = ''
      run cat "$(conf ${script noIPv6})"
      assert_line --partial 'listen 0.0.0.0:443 ssl;'
      refute_output --partial '[::0]'
      assert_line --partial 'listen [::1]:80;'
    '';
    "enableACME issues the vhost's certificate, served from its directory" = ''
      assert_equal ${
        json [
          acmeHost.webroot
          acmeHost.reloadServices
          acme.config.users.groups._acme.members
          acme.failedAssertions
        ]
      } '["/var/lib/acme/acme-challenge",["nginx"],["_nginx"],[]]'
      run cat "$(conf ${lib.escapeShellArg acme.config.launchd.daemons.nginx.script})"
      assert_line --partial 'ssl_certificate     /private/var/lib/acme/acme.example.com/fullchain.pem;'
      assert_line --partial 'ssl_certificate_key /private/var/lib/acme/acme.example.com/key.pem;'
      assert_line --partial 'root /var/lib/acme/acme-challenge;'
    '';
    "nginx runs as _nginx" = ''
      assert_equal ${
        json [
          s.config.users.users._nginx.uid
          (lib.elem "_nginx" s.config.users.knownUsers)
        ]
      } '[4097,true]'
      run echo ${esc (toString (lib.elem "_nginx" s.config.users.knownGroups))}
      assert_output 1
    '';
  };
}
