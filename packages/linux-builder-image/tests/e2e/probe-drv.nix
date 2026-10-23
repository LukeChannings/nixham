# A ~36 MiB output written in one go by the sandbox's /bin/sh alone (no
# coreutils): big enough that a teardown which drops the page cache loses part
# of it while the DB already holds it valid.
{ tag }:
derivation {
  name = "lbi-persist-${tag}";
  system = "aarch64-linux";
  builder = "/bin/sh";
  args = [
    "-c"
    ''
      s="lbi-persist ${tag} 0123456789abcdef"
      i=0
      while [ $i -lt 20 ]; do s="$s$s"; i=$((i + 1)); done
      printf '%s\n' "$s" > $out
    ''
  ];
}
