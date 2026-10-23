{ makeTest }:
makeTest {
  name = "oci-publish";
  setup = ''
    stub ${./stubs}
    export registry="$BATS_TEST_TMPDIR/registry"
    mkdir -p "$registry"
    export attr=image transport=oci-archive ref=registry.example/owner/image creds=user:secret
  '';
  tests = {
    "publishes a new closure under its tag and latest" = ''
      run bash ${../publish.sh}

      assert_success
      assert [ -e "$BATS_TEST_TMPDIR/built" ]
      assert_equal "$(cat "$registry/closure")" sha256:built
      assert_equal "$(cat "$registry/latest")" sha256:built
    '';
    "lowercases the repository, as registries require" = ''
      ref=registry.example/Owner/image run bash ${../publish.sh}

      assert_success
      run grep -c Owner "$BATS_TEST_TMPDIR/skopeo.log"
      assert_output 0
    '';
    "skips an unchanged closure" = ''
      printf sha256:old >"$registry/closure"
      printf sha256:old >"$registry/latest"

      run bash ${../publish.sh}

      assert_success
      refute [ -e "$BATS_TEST_TMPDIR/built" ]
      run grep -c ' copy ' "$BATS_TEST_TMPDIR/skopeo.log"
      assert_output 0
    '';
    "points latest back at an already published closure" = ''
      printf sha256:old >"$registry/closure"
      printf sha256:newer >"$registry/latest"

      run bash ${../publish.sh}

      assert_success
      refute [ -e "$BATS_TEST_TMPDIR/built" ]
      assert_equal "$(cat "$registry/latest")" sha256:old
    '';
  };
}
