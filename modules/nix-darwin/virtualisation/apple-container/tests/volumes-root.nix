# The script as activation runs it, but as this user, with GNU coreutils.
{ makeTest, coreutils }:
makeTest {
  name = "apple-container-volumes-root";
  inputs = [ coreutils ];
  helpers = [
    ''
      redirect() {
        bash ${../volumes-root.sh} "$vols" "''${1:-$target}" "''${2:-}" "$me"
      }

      owned() {
        [ "$(stat -c %U:%g -- "$1")" = "$me:$group" ] || fail "$1 is not $me:$group's"
      }
    ''
  ];
  setup = ''
    me="$(id -un)"
    group="$(id -g)"
    vols="$BATS_TEST_TMPDIR/home/Library/Application Support/com.apple.container/volumes"
    target="$BATS_TEST_TMPDIR/big disk/container-volumes"
    mkdir -p "$BATS_TEST_TMPDIR/home/Library/Application Support"
  '';
  tests = {
    "an absent volumes dir becomes a link to the target, which is created, all the user's" = ''
      run redirect
      assert_success
      assert_equal "$(readlink -- "$vols")" "$target"
      owned "$target"
      owned "$vols"
      owned "$(dirname -- "$vols")"
    '';
    "re-running is idempotent" = ''
      redirect
      touch "$target/a-volume"
      run redirect
      assert_success
      refute_output
      [ -e "$vols/a-volume" ]
    '';
    "an existing state dir keeps its mode" = ''
      mkdir -m 700 "$(dirname -- "$vols")"
      redirect
      assert_equal "$(stat -c %a -- "$(dirname -- "$vols")")" 700
    '';
    "a link to the target spelled differently is accepted" = ''
      mkdir -p "$target" "$(dirname -- "$vols")"
      ln -s "$target/" "$vols"
      run redirect
      refute_output
      assert_equal "$(readlink -- "$vols")" "$target/"
    '';
    "an empty volumes dir is replaced" = ''
      mkdir -p "$vols"
      redirect
      assert_equal "$(readlink -- "$vols")" "$target"
    '';
    "a populated volumes dir is left alone" = ''
      mkdir -p "$vols"
      touch "$vols/existing"
      run redirect
      assert_output --partial 'it is not empty'
      [ ! -L "$vols" ] && [ -e "$vols/existing" ]
    '';
    "a link elsewhere is left alone" = ''
      mkdir -p "$(dirname -- "$vols")"
      ln -s "$BATS_TEST_TMPDIR/elsewhere" "$vols"
      run redirect
      assert_output --partial 'already links to'
      assert_equal "$(readlink -- "$vols")" "$BATS_TEST_TMPDIR/elsewhere"
    '';
    "without Application Support, nothing happens" = ''
      rm -r "''${BATS_TEST_TMPDIR:?}/home"
      run redirect
      assert_success
      [ ! -e "$BATS_TEST_TMPDIR/home" ] && [ ! -e "$target" ]
    '';
    "an unmounted volume, missing or a plain directory, is a no-op" = ''
      run redirect "$BATS_TEST_TMPDIR/Volumes/Gone/v" "$BATS_TEST_TMPDIR/Volumes/Gone"
      assert_output --partial 'is not mounted'
      mkdir -p "$BATS_TEST_TMPDIR/Volumes/Unmounted"
      run redirect "$BATS_TEST_TMPDIR/Volumes/Unmounted/v" "$BATS_TEST_TMPDIR/Volumes/Unmounted"
      assert_output --partial 'is not mounted'
      [ ! -e "$vols" ] && [ ! -e "$BATS_TEST_TMPDIR/Volumes/Unmounted/v" ]
    '';
    "a mounted volume is claimed" = ''
      # /dev is its own file system on macOS, /proc on Linux.
      mounted=/dev
      [ ! -d /proc/self ] || mounted=/proc
      redirect "$target" "$mounted"
      assert_equal "$(readlink -- "$vols")" "$target"
    '';
    "a target that is not a directory is a no-op" = ''
      touch "$BATS_TEST_TMPDIR/a-file"
      run redirect "$BATS_TEST_TMPDIR/a-file"
      assert_output --partial 'is not a directory'
      [ ! -e "$vols" ]
    '';
  };
}
