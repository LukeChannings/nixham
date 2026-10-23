# pki-keychain

Trust in the macOS System keychain for CA certificates the host declares, alongside nix-darwin's OpenSSL bundle.

## Language

**User-supplied CA certificate**:
A certificate added through `security.pki.certificates` or `security.pki.certificateFiles`, typically a private CA. Only these are eligible for keychain installation.
_Avoid_: extra certs, custom certs

**Mozilla trust store**:
The default root bundle (`pkgs.cacert`) nix-darwin puts in the OpenSSL bundle. Never installed into the keychain: macOS trusts these roots natively.

**Keychain installation**:
Adding a certificate to the System keychain with an explicit trust policy, so TLS stacks that ignore `SSL_CERT_FILE` (Security.framework, Go) trust it. Always an explicit per-certificate opt-in, never a side effect of bundle membership.

**Trust policy**:
What the keychain records for an installed certificate: `trustRoot`, a self-signed anchor trusted as a root, or `trustAsRoot`, a certificate that isn't self-signed (e.g. an intermediate) trusted as if it were a root. Declared, never inferred.

**Keychain certificate**:
A user-supplied CA certificate declared for keychain installation, with its trust policy. Every keychain certificate is also in the OpenSSL bundle.
