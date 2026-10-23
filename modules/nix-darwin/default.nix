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
  default.imports = [ apple-container ];
}
