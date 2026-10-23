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
  oci-containers = module "oci-containers" ./virtualisation/oci-containers [ apple-container ];
  linux-builder = module "linux-builder" ./nix/linux-builder [ oci-containers ];
  zsh = module "zsh" ./programs/zsh [ ];
  default.imports = [
    linux-builder
    zsh
  ];
}
