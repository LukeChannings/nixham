# shellcheck shell=bash

# Boot $1 against the store volume, the way the module does it: a fresh
# container (rm + run) every time, the volume is the only state carried over.
boot() {
  boot_keyed "$1" --rosetta -v "$VOLUME:/persist"
  r true
  assert_no_failed_units
}

stop() {
  container stop "$CONTAINER" >/dev/null
}

uncleanWarning="previous shutdown was not clean"
assert_clean_previous_shutdown() {
  run logs
  refute_output --partial "$uncleanWarning"
}

probe() {
  remote_build "import $LBI_PROBE_DRV { tag = \"$1-$(date +%s)-$RANDOM\"; }"
}
