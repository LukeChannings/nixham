_nixham:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.security.pki;

  inherit (lib)
    concatMap
    escapeShellArgs
    literalExpression
    mkAfter
    mkIf
    mkOption
    types
    ;

  manifest = pkgs.runCommand "security-pki-keychain" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    bash ${./manifest.sh} $out/keychain ${
      escapeShellArgs (
        concatMap (c: [
          "${c.file}"
          c.policy
        ]) cfg.keychainCertificates
      )
    }
  '';

  keychain = pkgs.writeShellScript "security-pki-keychain" ''
    PATH=/usr/bin:/bin
    ${builtins.readFile ./keychain.sh}
  '';
in
{
  options.security.pki.keychainCertificates = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          file = mkOption {
            type = types.path;
            description = "A file holding exactly one CA certificate, in PEM.";
          };
          policy = mkOption {
            type = types.enum [
              "trustRoot"
              "trustAsRoot"
            ];
            example = "trustRoot";
            description = ''
              The trust policy the keychain records: `trustRoot` for a
              self-signed root, `trustAsRoot` for a certificate that isn't
              (e.g. an intermediate) but is trusted as if it were a root. The
              build fails if a `trustRoot` certificate isn't self-signed.
            '';
          };
        };
      }
    );
    default = [ ];
    example = literalExpression ''
      [
        { file = ./root_ca.crt; policy = "trustRoot"; }
        { file = ./intermediate_ca.crt; policy = "trustAsRoot"; }
      ]
    '';
    description = ''
      CA certificates to trust in the macOS System keychain
      ({file}`/Library/Keychains/System.keychain`), for TLS stacks that
      ignore `SSL_CERT_FILE` (Security.framework, Go). Each is also added to
      {option}`security.pki.certificateFiles`.

      Activation trusts them idempotently, and removes those dropped from
      this list since the previous generation. Certificates added to the
      keychain otherwise are never touched.
    '';
  };

  config = {
    # The next generation's activation diffs against this one's manifest.
    system.systemBuilderCommands = "ln -s ${manifest} $out/pki";

    security.pki.certificateFiles = mkIf cfg.installCACerts (map (c: c.file) cfg.keychainCertificates);

    # After /etc, before launchd starts the daemons that need the trust.
    system.activationScripts.etc.text = mkIf cfg.installCACerts (mkAfter ''
      ${keychain} ${manifest}/keychain /run/current-system/pki/keychain /Library/Keychains/System.keychain
    '');
  };
}
