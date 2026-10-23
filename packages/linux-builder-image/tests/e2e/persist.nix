{
  scope,
  image,
  variant,
  ...
}:
let
  # Differs from image only by an /etc file: a different system, so a
  # different store-path closure under the same volume.
  imageB = variant [ { environment.etc.lbi-persist-b.text = "b"; } ];
in
scope {
  helpers = [ ./persist.sh ];
  setupFile = ''
    REF_A="$(load_image ${image})"
    REF_B="$(load_image ${imageB})"
    export REF_A REF_B LBI_PROBE_DRV=${./probe-drv.nix}
    [ "$REF_A" != "$REF_B" ]
  '';
  # Every test has a fresh volume and container of its own.
  setup = ''
    CONTAINER="lbi-persist-$BATS_TEST_NUMBER" VOLUME="lbi-persist-$BATS_TEST_NUMBER"
    teardown
    container volume create "$VOLUME" >/dev/null
  '';
  teardown = ''
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
    container volume rm "$VOLUME" >/dev/null 2>&1 || true
    if [ -e "$BATS_TEST_TMPDIR/imported" ]; then
      xargs nix-store --delete <"$BATS_TEST_TMPDIR/imported" >/dev/null 2>&1 || true
    fi
  '';
  tests = {
    "image A boots on a fresh volume and seeds the Nix DB onto it" = ''
      boot "$REF_A"
      run logs
      refute_output --partial 'STORE IS EPHEMERAL'
      assert_output --partial 'seeding the Nix DB'
      run x 'cat /nix/var/nix/linux-builder-seeded-system'
      assert_output "$(x 'readlink -f /run/booted-system')"
      x '[ -s /persist/upper/var/nix/db/db.sqlite ]'
    '';
    "/nix is an overlay with its upper on the volume, and /nix/store stays read-only" = ''
      boot "$REF_A"
      run x 'findmnt -n -o FSTYPE /nix'
      assert_output overlay
      run x 'findmnt -n -o OPTIONS /nix'
      assert_output --partial upperdir=/persist/upper
      run x 'findmnt -n -o OPTIONS --direction backward --first-only /nix/store | tr , "\n"'
      assert_line ro
    '';
    "outputs survive stop + restart" = ''
      boot "$REF_A"
      out="$(probe persist)"
      x "[ -e /persist/upper/store/''${out#/nix/store/} ]"
      hostKey="$(x 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub')"

      stop
      boot "$REF_A"

      assert_clean_previous_shutdown
      x "nix-store --check-validity $out && nix-store --verify-path $out"
      run x 'ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub'
      assert_output "$hostKey"
      run logs
      refute_output --partial 'seeding the Nix DB'
    '';
    "an output built just before an idle stop imports on the host without a hash mismatch" = ''
      boot "$REF_A"
      out="$(probe dirty)"
      stop
      boot "$REF_A"
      assert_clean_previous_shutdown

      run env PATH="/usr/bin:$PATH" NIX_SSHOPTS="''${SSHO[*]} -i $SSH_KEY" \
        nix copy --no-check-sigs --from "ssh-ng://$SSH_USER@$(current_ip)" "$out"
      echo "$out" >"$BATS_TEST_TMPDIR/imported"
      assert_success
      refute_output --partial 'hash mismatch'
      x "nix-store --verify-path $out"
    '';
    "the next boot flags a teardown that never reached the sync hook" = ''
      boot "$REF_A"
      container kill "$CONTAINER" >/dev/null
      boot "$REF_A"
      run logs
      assert_output --partial "$uncleanWarning"
    '';
    "image B under A's volume drops A's phantom entries and keeps the volume's outputs" = ''
      boot "$REF_A"
      sysA="$(x 'readlink -f /run/booted-system')"
      out="$(probe image-change)"
      stop
      boot "$REF_B"

      assert_clean_previous_shutdown
      sysB="$(x 'readlink -f /run/booted-system')"
      assert_not_equal "$sysA" "$sysB"
      run logs
      assert_output --partial 'reconciling the persisted Nix DB'
      run x 'cat /nix/var/nix/linux-builder-seeded-system'
      assert_output "$sysB"
      x "[ ! -e $sysA ]"
      run x "nix-store --check-validity $sysA"
      assert_failure
      x 'nix-store --verify'
      x "nix-store --check-validity $out"
    '';
    "GC keeps the baked closure, and the builder reboots cleanly after it" = ''
      boot "$REF_A"
      garbage="$(probe garbage)"
      x 'nix-collect-garbage -d' >/dev/null
      x "[ ! -e $garbage ]"
      x 'nix-store -qR /run/booted-system | while read -r p; do [ -e "$p" ] || { echo "missing $p"; exit 1; }; done'
      x 'nix-store --verify --check-contents'
      stop
      boot "$REF_A"
    '';
  };
}
