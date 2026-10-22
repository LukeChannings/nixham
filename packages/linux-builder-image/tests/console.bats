load helpers

setup_file() {
  export CONTAINER=lbi-console
  REF="$(build_and_load console pkg)"
  export REF
}

teardown() {
  stop_console
}

teardown_file() {
  container rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

@test "container run -it drops into a root shell, with job control, on the console" {
  # script gives container run the terminal -it needs, and -F a live log.
  # macOS script rejects a fifo as its input; a coprocess's pipe it accepts.
  coproc CONSOLE {
    script -q -F "$BATS_FILE_TMPDIR/console.log" container run -it --name "$CONTAINER" \
      --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_ADMIN --kernel "$LBI_KERNEL" "$REF" \
      >/dev/null 2>&1 3>&-
  }

  wait_for_console 'root@linux-builder'
  # The echoed input reads uid=$(id -u); only the shell's output reads uid=0.
  # $- holds m while job control is on.
  printf '%s\n' 'echo "uid=$(id -u) flags=$-"' >&"${CONSOLE[1]}"
  wait_for_console 'uid=0 flags=[a-zA-Z]*m'

  run console
  refute_output --partial kbrequest
  refute_output --partial 'Getty on tty1'

  # Whatever the shell's status, leaving it ends container run.
  printf '%s\n' 'exit 3' >&"${CONSOLE[1]}"
  wait_for_exit "$CONSOLE_PID" || fail "container run outlived the console's shell"
}
