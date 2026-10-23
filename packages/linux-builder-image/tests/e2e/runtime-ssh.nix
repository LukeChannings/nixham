{ scope, image, ... }:
scope {
  helpers = [ ./runtime-ssh.sh ];
  setupFile = ''
    REF="$(load_image ${image})"
    export REF CONTAINER=lbi-runtime-ssh
    authorize "$BATS_FILE_TMPDIR"
    authorize "$BATS_FILE_TMPDIR" root
    ssh-keygen -q -t ed25519 -N "" -C lbi-user-ca -f "$BATS_FILE_TMPDIR/user-ca"
    trust_user_ca "$BATS_FILE_TMPDIR"
    mount_host_key "$BATS_FILE_TMPDIR"
    ssh-keygen -q -t ed25519 -N "" -C lbi-host-ca -f "$BATS_FILE_TMPDIR/host-ca"
    ssh-keygen -q -s "$BATS_FILE_TMPDIR/host-ca" -h -I lbi-host -n lbi-builder "$BATS_FILE_TMPDIR/config/ssh/ssh_host_ed25519_key.pub"
    boot_mounted "$REF" "$BATS_FILE_TMPDIR" --rosetta
  '';
  teardownFile = ''
    container rm -f "$CONTAINER" >/dev/null 2>&1 || true
  '';
  # Tests that restart a container get their own, and a volume to go with it.
  teardown = ''
    container rm -f "lbi-runtime-ssh-$BATS_TEST_NUMBER" >/dev/null 2>&1 || true
    container volume rm "lbi-runtime-ssh-$BATS_TEST_NUMBER" >/dev/null 2>&1 || true
  '';
  tests = {
    "builder logs in with a key from /config/ssh/authorized_keys.d" = ''
      run r whoami
      assert_output builder
    '';
    "an unrelated key is refused" = ''
      SSH_KEY="$(new_key unrelated)" run r true
      assert_failure
    '';
    "root is refused despite its authorized_keys.d file" = ''
      SSH_USER=root run r true
      assert_failure
    '';
    "replacing the key file on the host while running changes nothing" = ''
      own_container
      authorize "$BATS_TEST_TMPDIR"
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      key="$(new_key replacement)"
      authorize "$BATS_TEST_TMPDIR" builder "$key"
      r true
      SSH_KEY="$key" run r true
      assert_failure
    '';
    "a new container takes the replaced key file, and refuses the old key" = ''
      own_container
      authorize "$BATS_TEST_TMPDIR"
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      key="$(new_key replacement)"
      authorize "$BATS_TEST_TMPDIR" builder "$key"
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      SSH_KEY="$key" r true
      run r true
      assert_failure
    '';
    "a certificate from a trusted user CA, for principal builder, logs in as builder" = ''
      SSH_KEY="$(new_cert cert builder)" run r whoami
      assert_output builder
    '';
    "a certificate from a trusted user CA for another principal is refused" = ''
      SSH_KEY="$(new_cert cert someone-else)" run r true
      assert_failure
    '';
    "a new container without the trusted user CA refuses its certificates" = ''
      own_container
      trust_user_ca "$BATS_TEST_TMPDIR"
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      key="$(new_cert cert builder)"
      SSH_KEY="$key" r true
      boot_container "$REF" --rosetta
      SSH_KEY="$key" run r true
      assert_failure
    '';
    "the mounted host key is the one presented, and a client pinning it connects" = ''
      assert_equal "$(host_key)" "$(mounted_host_key "$BATS_FILE_TMPDIR")"
      run strict_r "$(current_ip) $(mounted_host_key "$BATS_FILE_TMPDIR")" whoami
      assert_output builder
    '';
    "with a store volume, the persisted host key outlives a mounted one, which never reaches the volume" =
      ''
        own_container
        container volume create "$CONTAINER" >/dev/null
        authorize "$BATS_TEST_TMPDIR"
        boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta -v "$CONTAINER:/persist"
        persisted="$(host_key)"
        assert [ -n "$persisted" ]

        mount_host_key "$BATS_TEST_TMPDIR"
        mounted="$(mounted_host_key "$BATS_TEST_TMPDIR")"
        digest="$(shasum -a 256 "$BATS_TEST_TMPDIR/config/ssh/ssh_host_ed25519_key" | cut -d' ' -f1)"
        boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta -v "$CONTAINER:/persist"
        assert_equal "$(host_key)" "$mounted"

        rm "$BATS_TEST_TMPDIR"/config/ssh/ssh_host_ed25519_key*
        boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta -v "$CONTAINER:/persist"
        assert_equal "$(host_key)" "$persisted"
        run x "find /persist -type f -exec sha256sum {} + | grep -F $digest; grep -rlF \"''${mounted#* }\" /persist"
        refute_output
      '';
    "with the mounted host key's certificate, a client trusting only its CA connects" = ''
      run strict_r "@cert-authority * $(cat "$BATS_FILE_TMPDIR/host-ca.pub")" -o HostKeyAlias=lbi-builder whoami
      assert_output builder
    '';
    "a host certificate without its host key is ignored, with a warning" = ''
      own_container
      authorize "$BATS_TEST_TMPDIR"
      cp "$BATS_FILE_TMPDIR/config/ssh/ssh_host_ed25519_key-cert.pub" "$BATS_TEST_TMPDIR/config/ssh/"
      boot_mounted "$REF" "$BATS_TEST_TMPDIR" --rosetta
      run logs
      assert_output --regexp 'linux-builder: WARN .*ssh_host_ed25519_key-cert\.pub'
      assert_equal "$(host_key)" "$(x 'cut -d" " -f1,2 /persist/ssh/ssh_host_ed25519_key.pub')"
      r true
    '';
  };
}
