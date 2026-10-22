load helpers

setup_file() {
  export CONTAINER=lbi-console
  REF="$(build_and_load console pkg)"
  export REF
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

console() {
  tr -d '\r' 2>/dev/null <"$BATS_FILE_TMPDIR/console.log"
}

# wait_for_console <regex>: until the console log matches, or 90s pass.
wait_for_console() {
  local deadline=$((SECONDS + 90))
  until console | grep -Eq "$1"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "no '$1' on the console, which ends: $(console | tail -5)"
    sleep 0.2
  done
}

@test "container run -it drops into a root shell on the console" {
  # script gives container run the terminal -it needs, and -F a live log.
  # macOS script rejects a fifo as its input; a coprocess's pipe it accepts.
  coproc CONSOLE {
    script -q -F "$BATS_FILE_TMPDIR/console.log" container run -it --name "$CONTAINER" \
      --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN --kernel "$LBI_KERNEL" "$REF" \
      >/dev/null 2>&1 3>&-
  }

  wait_for_console 'root@linux-builder'
  # The echoed input reads uid=$(id -u); only the shell's output reads uid=0.
  printf '%s\n' 'echo "uid=$(id -u)"' >&"${CONSOLE[1]}"
  wait_for_console 'uid=0$'
}
