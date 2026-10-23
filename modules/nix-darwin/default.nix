# Each module is keyed, so importing one that another also imports (e.g.
# linux-builder imports oci-containers) declares its options only once.
{ nixham }:
let
  module = name: dir: imports: {
    key = "nixham#modules.darwin.${name}";
    _file = dir + "/default.nix";
    imports = [ (import dir nixham) ] ++ imports;
  };
in
rec {
  apple-container = module "apple-container" ./virtualisation/apple-container [ ];
  oci-containers = module "oci-containers" ./virtualisation/oci-containers [
    apple-container
    launchd-wait4path
  ];
  linux-builder = module "linux-builder" ./nix/linux-builder [ oci-containers ];
  launchd-logging = module "launchd-logging" ./launchd/logging [ ];
  launchd-wait4path = module "launchd-wait4path" ./launchd/wait4path [ ];
  pki-keychain = module "pki-keychain" ./security/pki-keychain [ ];
  zsh = module "zsh" ./programs/zsh [ ];
  default.imports = [
    launchd-logging
    launchd-wait4path
    linux-builder
    pki-keychain
    zsh
  ];
}
