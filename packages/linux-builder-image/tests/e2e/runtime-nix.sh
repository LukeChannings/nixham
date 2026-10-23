# shellcheck shell=bash

own_container() {
  CONTAINER="lbi-runtime-nix-$BATS_TEST_NUMBER"
}

# write_config <dir> [substituter]: authorize, then <dir>/config/nix.conf,
# which includes <dir>/secrets/nested.conf from its /secrets mount, and
# <dir>/builder.env, whose NIX_CONFIG_A includes <dir>/secrets/env.conf. Two
# includes are absent: NIX_CONFIG_C's, and nested.conf's, relative to /secrets.
write_config() {
  authorize "$1"
  mkdir -p "$1/secrets"
  cat >"$1/config/nix.conf" <<CONF
extra-substituters = ${2:-https://lbi-config.invalid}
extra-sandbox-paths = /lbi-probe=/etc/resolv.conf
narinfo-cache-positive-ttl = 1111
!include /secrets/nested.conf
CONF
  printf '%s\n' 'narinfo-cache-negative-ttl = 4242' '!include absent-nested.conf' >"$1/secrets/nested.conf"
  cat >"$1/builder.env" <<ENV
NIX_CONFIG_B=http-connections = 37
NIX_CONFIG_A=!include /secrets/env.conf
NIX_CONFIG_C=!include /secrets/absent.conf
ENV
  echo 'download-attempts = 7' >"$1/secrets/env.conf"
}

# NIX_CONFIG's two lines; the second overrides /config's nix.conf.
NIX_CONFIG_LINES="connect-timeout = 17
narinfo-cache-positive-ttl = 2222"

# boot_configured <dir>: $CONTAINER with all of <dir>'s write_config, as
# mounts and environment.
boot_configured() {
  boot_mounted "$REF" "$1" --rosetta -e "NIX_CONFIG=$NIX_CONFIG_LINES" --env-file "$1/builder.env"
}

nix_config() {
  x 'nix config show'
}
