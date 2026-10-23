# x86_64-linux derivations for the builder to build under Rosetta, each built
# afresh for a fresh tag.
{
  nixpkgs,
  tag ? "",
}:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  env = pkgs.python3.withPackages (ps: [ ps.six ]);
in
{
  inherit env;
  uname = pkgs.runCommand "lbi-x86-probe-${tag}" { } "uname -m > $out";
  argv0 = pkgs.runCommand "lbi-argv0-probe-${tag}" { } ''
    ${env}/bin/python3 -c 'import sys; print(sys.prefix)' > $out
    ${env}/bin/python3 -c 'import six' >> $out
  '';
}
