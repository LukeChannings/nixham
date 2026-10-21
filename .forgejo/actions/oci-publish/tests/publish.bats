setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  registry="$BATS_TEST_TMPDIR/registry"
  mkdir -p "$registry" "$BATS_TEST_TMPDIR/bin"
  export registry

  cat >"$BATS_TEST_TMPDIR/bin/nix-instantiate" <<'EOF'
#!/usr/bin/env bash
echo '"closure"'
EOF
  cat >"$BATS_TEST_TMPDIR/bin/nix-build" <<'EOF'
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/built"
echo /nix/store/image
EOF
  # Registry tags are files under $registry holding their manifest digest.
  # Like the runners, there's no /var/tmp: skopeo needs --tmpdir to unpack.
  cat >"$BATS_TEST_TMPDIR/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/skopeo.log"
[ "$1" = --tmpdir ] && [ -d "$2" ] || { echo 'stat /var/tmp: no such file or directory' >&2; exit 1; }
case " $* " in
*" inspect "*)
  src=${*: -1:1}
  cat "$registry/${src##*:}" 2>/dev/null
  ;;
*" copy "*)
  src=${*: -2:1} dst=${*: -1:1}
  if [[ $src == docker://* ]]; then digest=$(cat "$registry/${src##*:}"); else digest=sha256:built; fi
  printf %s "$digest" >"$registry/${dst##*:}"
  ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export attr=image transport=oci-archive ref=registry.example/owner/image creds=user:secret
  publish="$BATS_TEST_DIRNAME/../publish.sh"
}

@test "publishes a new closure under its tag and latest" {
  run bash "$publish"

  assert_success
  assert [ -e "$BATS_TEST_TMPDIR/built" ]
  assert_equal "$(cat "$registry/closure")" sha256:built
  assert_equal "$(cat "$registry/latest")" sha256:built
}

@test "lowercases the repository, as registries require" {
  ref=registry.example/Owner/image run bash "$publish"

  assert_success
  run grep -c Owner "$BATS_TEST_TMPDIR/skopeo.log"
  assert_output 0
}

@test "skips an unchanged closure" {
  printf sha256:old >"$registry/closure"
  printf sha256:old >"$registry/latest"

  run bash "$publish"

  assert_success
  refute [ -e "$BATS_TEST_TMPDIR/built" ]
  run grep -c ' copy ' "$BATS_TEST_TMPDIR/skopeo.log"
  assert_output 0
}

@test "points latest back at an already published closure" {
  printf sha256:old >"$registry/closure"
  printf sha256:newer >"$registry/latest"

  run bash "$publish"

  assert_success
  refute [ -e "$BATS_TEST_TMPDIR/built" ]
  assert_equal "$(cat "$registry/latest")" sha256:old
}
