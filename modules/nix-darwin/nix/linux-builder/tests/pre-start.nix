# The script as the start script runs it, against a stub runtime.
{ makeTest, jq }:
makeTest {
  name = "linux-builder-pre-start";
  inputs = [ jq ];
  helpers = [
    ''
      pre_start() {
        bash ${../pre-start.sh} linux-builder org.nixos.managed-by nixham linux-builder "$1"
      }

      # images <ref...>: the runtime holds these images.
      images() {
        printf '%s\n' "$@" | jq -R '{ configuration: { name: . } }' | jq -s . >"$runtime/images.json"
      }

      # calls <command>: the arguments of each call of it.
      calls() {
        sed -n "s/^$1 //p" "$runtime/calls"
      }
    ''
  ];
  setup = ''
    stub ${./stubs}
    export runtime="$BATS_TEST_TMPDIR/runtime" runtime_busy=
    mkdir -p "$runtime"
    echo '[]' >"$runtime/containers.json"
    touch "$runtime/present"
    images
  '';
  tests = {
    "every other image of the repository is deleted, loaded or pulled" = ''
      images linux-builder:old docker.io/library/linux-builder:pulled linux-builder:new nginx:1
      run pre_start linux-builder:new
      assert_success
      assert_equal "$(calls 'image rm')" "$(printf '%s\n' linux-builder:old docker.io/library/linux-builder:pulled)"
      assert_output --partial 'deleted the stale image linux-builder:old (Reclaimed 1 MB in disk space)'
    '';
    "a registry ref keeps itself, and deletes every image of the repository" = ''
      images linux-builder:old ghcr.io/x/linux-builder:1
      run pre_start ghcr.io/x/linux-builder:1
      assert_equal "$(calls 'image rm')" linux-builder:old
    '';
    "lookalikes are someone else's" = ''
      images linux-builder-other:1 linux-builder:5000/x:1 ghcr.io/x/linux-builder:1 docker.io/library/linux-builder-x:1
      run pre_start linux-builder:new
      refute_output --partial deleted
      run calls 'image rm'
      refute_output
    '';
    "with its image present, nothing is deleted" = ''
      images linux-builder:old linux-builder:new
      echo linux-builder:new >"$runtime/present"
      run pre_start linux-builder:new
      assert_success
      run calls 'image rm'
      refute_output
    '';
    "an image that won't go is warned about, and the rest still go" = ''
      images linux-builder:a linux-builder:b
      export runtime_busy=linux-builder:a
      run pre_start linux-builder:new
      assert_success
      assert_output --partial 'WARN could not delete the stale image linux-builder:a: Error: busy'
      assert_output --partial 'deleted the stale image linux-builder:b'
    '';
    "other containers with the builder's label are deleted, and only they" = ''
      jq -n '[
        { configuration: { id: "linux-builder", labels: { "org.nixos.managed-by": "nixham" } } },
        { configuration: { id: "old-builder", labels: { "org.nixos.managed-by": "nixham" } } },
        { configuration: { id: "theirs", labels: { "org.nixos.managed-by": "nix-darwin" } } },
        { configuration: { id: "unlabelled", labels: {} } }
      ]' >"$runtime/containers.json"
      run pre_start linux-builder:new
      assert_success
      assert_equal "$(calls 'delete --force')" old-builder
    '';
    "an unreachable runtime is not an error" = ''
      rm "$runtime"/*.json
      run pre_start linux-builder:new
      assert_success
    '';
  };
}
