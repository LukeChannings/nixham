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
  acme = module "acme" ./security/acme [ ];
  apple-container = module "apple-container" ./virtualisation/apple-container [ ];
  nginx = module "nginx" ./services/nginx [ acme ];
  oci-containers = module "oci-containers" ./virtualisation/oci-containers [
    apple-container
    launchd-wait4path
  ];
  linux-builder = module "linux-builder" ./nix/linux-builder [ oci-containers ];
  garage = module "garage" ./services/garage [ ];
  launchd-logging = module "launchd-logging" ./launchd/logging [ ];
  launchd-wait4path = module "launchd-wait4path" ./launchd/wait4path [ ];
  virtual-interfaces = module "virtual-interfaces" ./networking/virtual-interfaces [ ];
  pki-keychain = module "pki-keychain" ./security/pki-keychain [ ];
  zsh = module "zsh" ./programs/zsh [ ];
  default.imports = [
    acme
    garage
    launchd-logging
    launchd-wait4path
    linux-builder
    nginx
    pki-keychain
    virtual-interfaces
    zsh
  ];
}
