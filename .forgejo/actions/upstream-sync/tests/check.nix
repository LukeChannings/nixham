{
  makeTest,
  git,
  jq,
  openssh,
}:
makeTest {
  name = "upstream-sync";
  inputs = [
    git
    jq
    openssh
  ];
  helpers = [
    ''
      commit() {
        printf '%s\n' "$3" >"$1/$2"
        git -C "$1" add "$2"
        git -C "$1" commit -qm "$2: $3"
      }
      sync_head() { git -C "$forge" rev-parse "sync/upstream$1"; }
      calls() { cat "$BATS_TEST_TMPDIR/curl.calls" 2>/dev/null || true; }
      on_sync_branch() {
        git -C "$dev" fetch -q
        git -C "$dev" switch -q sync/upstream
      }
    ''
  ];
  setup = ''
    stub ${./stubs}
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git config --global user.name Dev
    git config --global user.email dev@example.com
    git config --global init.defaultBranch main

    up="$BATS_TEST_TMPDIR/upstream"
    forge="$BATS_TEST_TMPDIR/forge.git"
    dev="$BATS_TEST_TMPDIR/dev"
    git init -q "$up"
    commit "$up" a.txt one
    git clone -q --bare "$up" "$forge"
    git clone -q "$forge" "$dev"
    commit "$dev" fork.txt ours
    git -C "$dev" push -q

    ssh-keygen -q -t ed25519 -N "" -C bot -f "$BATS_TEST_TMPDIR/key"
    SIGNING_KEY=$(cat "$BATS_TEST_TMPDIR/key")
    export SIGNING_KEY UPSTREAM="$up" FORGE_REMOTE="$forge" FORGE_TOKEN=secret \
      GITHUB_API_URL=https://forge.example/api/v1 GITHUB_REPOSITORY=owner/fork \
      GIT_NAME=Bot GIT_EMAIL=bot@example.com
    export open_pr='[{"number":7,"head":{"ref":"sync/upstream"}}]'
  '';
  tests = {
    "does nothing when upstream has nothing new" = ''
      run bash ${../sync.sh}

      assert_success
      run git -C "$forge" rev-parse -q --verify sync/upstream
      assert_failure
      assert_equal "$(calls)" ""
    '';
    "merges upstream into the sync branch with a signed merge and opens a PR" = ''
      commit "$up" b.txt two

      run bash ${../sync.sh}

      assert_success
      assert_equal "$(sync_head ^1)" "$(git -C "$forge" rev-parse main)"
      assert_equal "$(sync_head ^2)" "$(git -C "$up" rev-parse HEAD)"
      run git -C "$forge" cat-file commit sync/upstream
      assert_line --regexp '^gpgsig '
      assert_line --regexp '^committer Bot <bot@example.com> '
      run calls
      assert_line --index 1 --regexp '^POST pulls .*"head":"sync/upstream","base":"main"'
      assert_line --index 1 --partial 'b.txt: two'
    '';
    "adds newer upstream commits to an open sync PR, keeping what was pushed" = ''
      commit "$up" b.txt two
      bash ${../sync.sh}
      on_sync_branch
      commit "$dev" nix.txt reconciled
      git -C "$dev" push -q
      commit "$up" c.txt three

      PULLS=$open_pr run bash ${../sync.sh}

      assert_success
      assert_equal "$(sync_head ^1)" "$(git -C "$dev" rev-parse HEAD)"
      assert_equal "$(sync_head ^2)" "$(git -C "$up" rev-parse HEAD)"
      run grep -c '^POST pulls' "$BATS_TEST_TMPDIR/curl.calls"
      assert_output 1
    '';
    "opens the PR at upstream's head when the merge conflicts" = ''
      commit "$dev" a.txt ours
      git -C "$dev" push -q
      commit "$up" a.txt theirs

      run bash ${../sync.sh}

      assert_success
      assert_equal "$(sync_head)" "$(git -C "$up" rev-parse HEAD)"
      run calls
      assert_line --regexp '^POST pulls '
      assert_line --regexp '^POST issues/1/comments .*a\.txt'
    '';
    "leaves a conflicting sync branch alone, commenting once per upstream head" = ''
      commit "$up" b.txt two
      bash ${../sync.sh}
      on_sync_branch
      commit "$dev" a.txt ours
      git -C "$dev" push -q
      commit "$up" a.txt theirs
      pushed=$(sync_head)

      PULLS=$open_pr run bash ${../sync.sh}

      assert_success
      assert_equal "$(sync_head)" "$pushed"
      run calls
      assert_line --regexp '^POST issues/7/comments .*a\.txt'

      marker="<!-- upstream-sync $(git -C "$up" rev-parse HEAD) -->"
      PULLS=$open_pr COMMENTS="[{\"body\":\"$marker\"}]" run bash ${../sync.sh}

      assert_success
      run grep -c '^POST issues/7/comments' "$BATS_TEST_TMPDIR/curl.calls"
      assert_output 1
    '';
    "starts again from the default branch once the sync PR has merged" = ''
      commit "$up" b.txt two
      bash ${../sync.sh}
      git -C "$dev" fetch -q
      git -C "$dev" merge -q --no-ff -m merged origin/sync/upstream
      git -C "$dev" push -q
      commit "$up" c.txt three

      run bash ${../sync.sh}

      assert_success
      assert_equal "$(sync_head ^1)" "$(git -C "$forge" rev-parse main)"
      run grep -c '^POST pulls' "$BATS_TEST_TMPDIR/curl.calls"
      assert_output 2
    '';
    "refuses to make unsigned merges" = ''
      commit "$up" b.txt two

      SIGNING_KEY="" run bash ${../sync.sh}

      assert_failure
      assert_output --partial SIGNING_KEY
    '';
  };
}
