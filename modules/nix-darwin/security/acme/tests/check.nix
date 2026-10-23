{
  lib,
  makeTest,
  darwin,
  minica,
}:
let
  inherit (darwin) esc json text;
  acme = certs: {
    security.acme = {
      acceptTerms = true;
      defaults.email = "admin@example.com";
      inherit certs;
    };
  };
  s = darwin.eval [
    (acme {
      "example.com" = {
        webroot = "/var/lib/acme/acme-challenge";
        reloadServices = [ "nginx" ];
        credentialFiles.TOKEN = "/run/secrets/token";
        postRun = "echo renewed";
      };
      "dns.example.com" = {
        dnsProvider = "cloudflare";
        server = "https://acme-staging-v02.api.letsencrypt.org/directory";
        group = "certs";
        renewInterval = "hourly";
      };
      "standalone.example.com".listenHTTP = ":80";
    })
  ];
  calendar =
    name: map (lib.filterAttrs (_: v: v != null)) (s.daemon name).serviceConfig.StartCalendarInterval;
  args = name: (s.daemon name).serviceConfig.ProgramArguments;
  renewal = name: text "acme-${name}" s.config.system.build.acme.${name}.text;
  noTerms = darwin.eval [
    {
      security.acme.certs."example.com" = {
        webroot = "/srv";
        dnsProvider = "cloudflare";
      };
    }
  ];
in
makeTest {
  name = "acme";
  inputs = [ minica ];
  helpers = [
    ''
      renew() {
        bash ${../renew.sh} "$state" example.com certs 30 --path "$state" --domains example.com
      }
      selfsigned() {
        bash ${../selfsigned.sh} "$state" example.com certs
      }
    ''
  ];
  setup = ''
    stub ${./stubs}
    export calls="$BATS_TEST_TMPDIR/calls" state="$BATS_TEST_TMPDIR/acme"
    touch "$calls"
  '';
  tests = {
    "the fixture passes every assertion" = ''
      assert_equal ${json s.failedAssertions} '[]'
    '';
    "each certificate is renewed daily or hourly, from boot, through the store's entrypoint" = ''
      run echo ${esc (lib.last (args "acme-example.com"))}
      assert_output --regexp '^/bin/wait4path /nix/store && exec /nix/store/[^ ]*-acme-example.com /private/var/lib/acme example.com _acme 30 '
      assert_equal ${
        json [
          (s.daemon "acme-example.com").serviceConfig.RunAtLoad
          (calendar "acme-example.com")
          (calendar "acme-dns.example.com")
          (s.daemon "acme-example.com").serviceConfig.StandardErrorPath
        ]
      } '[true,[{"Hour":2,"Minute":37}],[{"Minute":13}],"/var/log/acme/example.com.log"]'
    '';
    "lego is told the challenge, account and server" = ''
      run echo ${esc (lib.last (args "acme-example.com"))}
      assert_output --partial "--email admin@example.com --server https://acme-v02.api.letsencrypt.org/directory --key-type ec256 --domains example.com --accept-tos --http --http.webroot /var/lib/acme/acme-challenge"
      run echo ${esc (lib.last (args "acme-dns.example.com"))}
      assert_output --partial "dns.example.com certs 30 --path /private/var/lib/acme --email admin@example.com --server https://acme-staging-v02.api.letsencrypt.org/directory"
      assert_output --partial "--dns cloudflare"
      run echo ${esc (lib.last (args "acme-standalone.example.com"))}
      assert_output --partial "--http --http.port :80"
    '';
    "renewal loads credentials, then reloads services and runs postRun" = ''
      run cat ${renewal "example.com"}
      assert_line 'export TOKEN="$(cat /run/secrets/token)"'
      assert_line 'launchctl kill HUP system/org.nixos.nginx 2>/dev/null || true'
      assert_line 'echo renewed'
      assert_bash ${renewal "example.com"}
    '';
    "a new certificate is issued, and laid out as on NixOS" = ''
      run renew
      assert_success
      assert_equal "$(cat "$calls")" "$(printf '%s\n' "lego --path $state --domains example.com run" "chown _acme:certs $state/example.com $state/example.com/cert.pem $state/example.com/chain.pem $state/example.com/fullchain.pem $state/example.com/key.pem")"
      assert_equal "$(readlink "$state/example.com/cert.pem")" fullchain.pem
      assert_equal "$(cat "$state/example.com/fullchain.pem") $(cat "$state/example.com/key.pem") $(cat "$state/example.com/chain.pem")" "crt key issuer.crt"
      assert_equal "$(stat -c %a "$state/example.com" "$state/example.com/key.pem" "$state/example.com/fullchain.pem")" "$(printf '750\n640\n644')"
    '';
    "an issued certificate is renewed" = ''
      renew
      : >"$calls"
      renew
      assert_equal "$(head -1 "$calls")" "lego --path $state --domains example.com renew --days 30"
    '';
    "a self-signed placeholder stands in until the certificate is issued" = ''
      run selfsigned
      assert_success
      assert_equal "$(readlink "$state/example.com/cert.pem")" fullchain.pem
      [ -s "$state/example.com/key.pem" ] && [ -s "$state/example.com/chain.pem" ]
      : >"$calls"
      run selfsigned
      assert_equal "$(cat "$calls")" ""
      renew
      assert_equal "$(grep -c lego "$calls")" 1
      assert_equal "$(tail -1 "$calls" | cut -d' ' -f1)" chown
      grep -q '^lego .* run$' "$calls"
    '';
    "the self-signed placeholder is optional" = ''
      assert_equal ${json (s.config.launchd.daemons ? "acme-selfsigned-example.com")} true
      assert_equal ${
        json (
          (darwin.eval [
            (acme { "example.com".webroot = "/srv"; })
            { security.acme.preliminarySelfsigned = false; }
          ]).config.launchd.daemons
            ? "acme-selfsigned-example.com"
        )
      } false
    '';
    "the terms must be accepted, and only one challenge chosen" = ''
      run echo ${json noTerms.failedAssertions}
      assert_output --partial 'you must set acceptTerms = true'
      assert_output --partial 'webroot, dnsProvider and listenHTTP are mutually exclusive'
    '';
    "certificates run as _acme" = ''
      assert_equal ${
        json [
          s.config.users.users._acme.uid
          s.config.users.groups._acme.gid
          (lib.elem "_acme" s.config.users.knownUsers)
        ]
      } '[4096,4096,true]'
    '';
  };
}
