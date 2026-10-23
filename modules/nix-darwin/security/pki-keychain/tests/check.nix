{
  lib,
  makeTest,
  darwin,
  openssl,
}:
let
  inherit (darwin) esc json text;
  certs = [
    {
      file = ./fixtures/root.crt;
      policy = "trustRoot";
    }
    {
      file = ./fixtures/intermediate.crt;
      policy = "trustAsRoot";
    }
  ];
  s = darwin.eval [ { security.pki.keychainCertificates = certs; } ];
  noCACerts = darwin.eval [
    {
      security.pki.keychainCertificates = certs;
      security.pki.installCACerts = false;
    }
  ];
in
makeTest {
  name = "pki-keychain";
  inputs = [ openssl ];
  helpers = [
    ''
      fingerprint() {
        local fp
        fp=$(openssl x509 -noout -fingerprint -sha1 -in "$1")
        fp=''${fp#*=}
        echo "''${fp//:/}"
      }

      manifest() {
        bash ${../manifest.sh} "$@"
      }

      keychain() {
        bash ${../keychain.sh} "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/old" /Library/Keychains/System.keychain
      }

      # trusted <SHA-1> <result>: the stub keychain holds it, with that result.
      trusted() {
        assert_equal "$(cat "$keychain_state/$1")" "$2"
      }
    ''
  ];
  setup = ''
    stub ${./stubs}
    export calls="$BATS_TEST_TMPDIR/calls" keychain_state="$BATS_TEST_TMPDIR/keychain"
    mkdir "$keychain_state"
    touch "$calls"
    root=$(fingerprint ${./fixtures/root.crt})
    intermediate=$(fingerprint ${./fixtures/intermediate.crt})
  '';
  tests = {
    "the manifest names each certificate by its SHA-1, beside its policy" = ''
      manifest "$BATS_TEST_TMPDIR/m" ${./fixtures/root.crt} trustRoot ${./fixtures/intermediate.crt} trustAsRoot
      cmp ${./fixtures/root.crt} "$BATS_TEST_TMPDIR/m/$root.crt"
      assert_equal "$(cat "$BATS_TEST_TMPDIR/m/$root.policy")" trustRoot
      assert_equal "$(cat "$BATS_TEST_TMPDIR/m/$intermediate.policy")" trustAsRoot
    '';
    "a trustRoot certificate that isn't self-signed fails the build" = ''
      run manifest "$BATS_TEST_TMPDIR/m" ${./fixtures/intermediate.crt} trustRoot
      assert_failure
      assert_output --partial 'requires a self-signed certificate'
    '';
    "a file of other than one certificate fails the build" = ''
      cat ${./fixtures/root.crt} ${./fixtures/intermediate.crt} >"$BATS_TEST_TMPDIR/both.crt"
      run manifest "$BATS_TEST_TMPDIR/m" "$BATS_TEST_TMPDIR/both.crt" trustAsRoot
      assert_failure
      assert_output --partial 'must contain exactly one PEM certificate'
    '';
    "certificates are trusted with their policies, once" = ''
      manifest "$BATS_TEST_TMPDIR/new" ${./fixtures/root.crt} trustRoot ${./fixtures/intermediate.crt} trustAsRoot
      run keychain
      assert_success
      trusted "$root" 1
      trusted "$intermediate" 2
      : >"$calls"
      run keychain
      assert_success
      run grep add-trusted-cert "$calls"
      assert_failure
    '';
    "a certificate with the wrong policy, or none, is trusted again" = ''
      manifest "$BATS_TEST_TMPDIR/new" ${./fixtures/root.crt} trustRoot ${./fixtures/intermediate.crt} trustAsRoot
      echo 1 >"$keychain_state/$intermediate"
      touch "$keychain_state/$root"
      keychain
      trusted "$root" 1
      trusted "$intermediate" 2
    '';
    "a certificate dropped since the previous generation is removed, and only it" = ''
      manifest "$BATS_TEST_TMPDIR/old" ${./fixtures/root.crt} trustRoot ${./fixtures/intermediate.crt} trustAsRoot
      manifest "$BATS_TEST_TMPDIR/new" ${./fixtures/root.crt} trustRoot
      echo 1 >"$keychain_state/$root"
      echo 2 >"$keychain_state/$intermediate"
      echo 1 >"$keychain_state/HANDINSTALLED"
      run keychain
      assert_output --partial "removing keychain certificate $intermediate"
      [ ! -e "$keychain_state/$intermediate" ]
      trusted "$root" 1
      trusted HANDINSTALLED 1
    '';
    "with nothing declared, now or before, the keychain isn't read" = ''
      mkdir "$BATS_TEST_TMPDIR/new"
      run keychain
      assert_success
      refute_output
      assert_equal "$(cat "$calls")" ""
    '';
    "the certificates join the OpenSSL bundle" = ''
      run printf '%s\n' ${lib.escapeShellArgs (map toString s.config.security.pki.certificateFiles)}
      assert_line ${esc (toString ./fixtures/root.crt)}
      assert_line ${esc (toString ./fixtures/intermediate.crt)}
    '';
    "activation diffs against the current system's manifest, after /etc" = ''
      run cat ${text "etc" s.config.system.activationScripts.etc.text}
      assert_line --regexp '^/nix/store/[^ ]*-security-pki-keychain /nix/store/[^ ]*-security-pki-keychain/keychain /run/current-system/pki/keychain /Library/Keychains/System.keychain$'
      run echo ${esc s.config.system.systemBuilderCommands}
      assert_output --regexp 'ln -s /nix/store/[^ ]*-security-pki-keychain \$out/pki'
    '';
    "without installCACerts, the keychain is left alone" = ''
      run cat ${text "etc" noCACerts.config.system.activationScripts.etc.text}
      refute_output --partial security-pki-keychain
      assert_equal ${json (lib.elem ./fixtures/root.crt noCACerts.config.security.pki.certificateFiles)} false
    '';
  };
}
