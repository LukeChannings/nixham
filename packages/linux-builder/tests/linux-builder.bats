load ../../linux-builder-image/tests/helpers

teardown() {
  stop_console
  container rm -f lb-tty >/dev/null 2>&1 || true
  [ ! -e "$BATS_TEST_TMPDIR/outs" ] || xargs nix-store --delete <"$BATS_TEST_TMPDIR/outs" >/dev/null 2>&1 || true
}

# probe <system>: a derivation for <system>, with a unique name, whose output reads "ok".
probe() {
  echo "derivation { name = \"lb-probe-$(date +%s)-$RANDOM\"; system = \"$1\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ok > \$out\" ]; }"
}

@test "--help prints its usage" {
  run "$LINUX_BUILDER" --help
  assert_success
  assert_output --partial 'Usage: linux-builder [shell]'
}

@test "without container on PATH, it says it needs it" {
  run env PATH=/usr/bin:/bin "$LINUX_BUILDER" shell
  assert_failure
  assert_output --partial "needs apple/container's \`container\` CLI"
}

# The kernel release a builder runs, as its command prints it.
release() {
  sed -n 's/^release=//p' <<<"$output"
}

@test "the pinned kernel is this tree's apple-container-kernel" {
  pinned="$(nix-build --no-out-link -A linux-builder.kernel "$LB_REPO")"
  built="$(nix-build --no-out-link -A apple-container-kernel "$LB_REPO")"
  [ "$(nix-store -q --hash "$pinned")" = "$(nix-store -q --hash "$built")" ] ||
    fail "pin $(nix-store -q --hash "$built") in packages/linux-builder/kernel.nix"
}

@test "with --build-kernel and --build-image, shell builds aarch64-linux and x86_64-linux on this tree's builder, and stops it on exit" {
  # --max-jobs 0: nothing builds on the host.
  run "$LINUX_BUILDER" shell --build-kernel --build-image -- bash -c 'echo "container=$LINUX_BUILDER_CONTAINER"
    echo "release=$(container exec "$LINUX_BUILDER_CONTAINER" /run/current-system/sw/bin/uname -r)"
    nix build --impure --no-link --print-out-paths --max-jobs 0 --expr "$1"' _ \
    "[ ($(probe aarch64-linux)) ($(probe x86_64-linux)) ]"
  assert_success
  assert_line "linux-builder: building the kernel from $LB_REPO"
  assert_line "linux-builder: building the image from $LB_REPO"
  assert_line --regexp '^linux-builder: starting the builder \(linux-builder:[a-z0-9]{32}\)$'
  [[ "$(nix-build --no-out-link -A apple-container-kernel "$LB_REPO")" == *-"$(release)" ]]
  grep '^/nix/store/' <<<"$output" >"$BATS_TEST_TMPDIR/outs"
  assert_equal "$(xargs cat <"$BATS_TEST_TMPDIR/outs")" "$(printf 'ok\nok')"

  run container inspect "$(sed -n 's/^container=//p' <<<"$output")"
  assert_failure
}

@test "by default, shell runs ghcr.io's image on the pinned kernel, says what it is doing, and exits with the command's status" {
  run "$LINUX_BUILDER" -- sh -c 'echo "release=$(container exec "$LINUX_BUILDER_CONTAINER" /run/current-system/sw/bin/uname -r)"; exit 3'
  assert_failure 3
  assert_line 'linux-builder: pulling ghcr.io/lukechannings/linux-builder:latest'
  assert_line 'linux-builder: starting the builder (ghcr.io/lukechannings/linux-builder:latest)'
  [[ "$(nix-build --no-out-link -A linux-builder.kernel "$LB_REPO")" == *-"$(release)" ]]
  assert_line --regexp '^linux-builder: waiting for the builder at [0-9.]+$'
  assert_line --regexp '^linux-builder: ready: Nix in this shell builds aarch64-linux, x86_64-linux on [^ ]+ \([0-9.]+\); exit stops it$'
  assert_line --regexp '^linux-builder: stopping the builder$'
  refute_output --partial 'Starting container'
}

@test "tty logs in as root on the console, and exit stops the builder" {
  # As ../../linux-builder-image/tests/console.bats. --build-image: exit
  # stopping it is the image's doing, so test this tree's.
  coproc CONSOLE {
    script -q -F "$BATS_FILE_TMPDIR/console.log" "$LINUX_BUILDER" tty --build-image --name lb-tty \
      >/dev/null 2>&1 3>&-
  }

  wait_for_console 'root@linux-builder'
  printf '%s\n' 'echo "uid=$(id -u)"' >&"${CONSOLE[1]}"
  wait_for_console 'uid=0$'
  printf '%s\n' exit >&"${CONSOLE[1]}"
  wait_for_exit "$CONSOLE_PID" || fail "linux-builder tty outlived the console's shell"
}
