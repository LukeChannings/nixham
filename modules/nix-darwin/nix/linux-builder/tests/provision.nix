# The script as activation runs it, but as this user.
{
  makeTest,
  coreutils,
  openssh,
}:
makeTest {
  name = "linux-builder-provision";
  inputs = [
    coreutils
    openssh
  ];
  helpers = [
    ''
      # Its log goes to stderr.log, its output to stdout.
      provision() {
        bash ${../provision.sh} "$dir" "$(id -un)" builder linux-builder.container "$@" 2>>"$BATS_TEST_TMPDIR/stderr.log"
      }

      authorized() {
        cat "$dir/config/ssh/authorized_keys.d/builder"
      }

      pub() {
        cut -d' ' -f1,2 "$1.pub"
      }
    ''
  ];
  setup = ''
    dir="$BATS_TEST_TMPDIR/state"
  '';
  tests = {
    "the first run makes both keys, authorizes the client's and pins the host's" = ''
      run provision
      assert_success
      assert_output changed
      assert_equal "$(authorized)" "$(pub "$dir/ssh_key")"
      assert_equal "$(cat "$dir/known_hosts")" "linux-builder.container $(pub "$dir/config/ssh/ssh_host_ed25519_key")"
    '';
    "/config is the user's alone, the client key root's, known_hosts anyone's" = ''
      provision
      assert_equal "$(stat -c '%U %a' "$dir" "$dir/config" "$dir/config/ssh/ssh_host_ed25519_key" "$dir/ssh_key" "$dir/known_hosts")" \
        "$(printf "$(id -un) %s\n" 755 700 600 600 644)"
    '';
    "a second run changes nothing" = ''
      provision
      cp -R "$dir" "$BATS_TEST_TMPDIR/before"
      run provision
      assert_success
      refute_output
      diff -r "$BATS_TEST_TMPDIR/before" "$dir"
    '';
    "given keys are authorized too, once each" = ''
      ssh-keygen -q -t ed25519 -N "" -f "$BATS_TEST_TMPDIR/k"
      provision
      run provision "$BATS_TEST_TMPDIR/k" "$BATS_TEST_TMPDIR/k" "$dir/ssh_key"
      assert_output changed
      assert_equal "$(authorized)" "$(sort <<<"$(pub "$dir/ssh_key")"$'\n'"$(pub "$BATS_TEST_TMPDIR/k")")"
    '';
    "a deleted host key is replaced, and pinned" = ''
      provision
      old="$(cat "$dir/known_hosts")"
      rm "$dir/config/ssh/ssh_host_ed25519_key"
      run provision
      assert_output changed
      assert_not_equal "$(cat "$dir/known_hosts")" "$old"
      assert_equal "$(cat "$dir/known_hosts")" "linux-builder.container $(pub "$dir/config/ssh/ssh_host_ed25519_key")"
    '';
    "an unreadable key fails the run" = ''
      run provision "$BATS_TEST_TMPDIR/absent"
      assert_failure
    '';
  };
}
