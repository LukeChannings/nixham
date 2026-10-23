# Runs the runtime agent's script against this user's runtime: it sets the
# default kernel (restored afterwards) and the default DNS domain (restored by
# re-running `container system start`), and creates resources named
# nixham-e2e, which teardown deletes.
{
  makeTest,
  darwin,
  jq,
  apple-container-kernel,
}:
let
  name = "nixham-e2e";
  s = darwin.eval [
    {
      virtualisation.apple-container = {
        enable = true;
        system.kernel.arm64 = {
          tar = "${apple-container-kernel}/kernel.tar";
          binary = "./vmlinux-arm64";
        };
        system.dns.defaultDomain = name;
        network.${name} = { };
        volume.${name}.size = "1G";
      };
    }
  ];
  start = (s.agent "apple-container").command;
  dns = s.pkgs.writeShellScript "apple-container-dns" s.config.system.activationScripts.postActivation.text;
in
makeTest {
  name = "apple-container-e2e";
  kind = "e2e";
  inputs = [ jq ];
  helpers = [
    ''
      NAME=${name}
      KERNELS="$HOME/Library/Application Support/com.apple.container/kernels"
    ''
  ];
  setupFile = ''
    if [ -e "$KERNELS/default.kernel-arm64" ]; then
      mkdir "$BATS_FILE_TMPDIR/previous-kernel"
      cp -L "$KERNELS/default.kernel-arm64" "$BATS_FILE_TMPDIR/previous-kernel/$(basename "$(readlink "$KERNELS/default.kernel-arm64")")"
    fi
    export XDG_CONFIG_HOME="$BATS_FILE_TMPDIR/config" XDG_STATE_HOME="$BATS_FILE_TMPDIR/state"
    ${start} >"$BATS_FILE_TMPDIR/first.log" 2>&1
  '';
  teardownFile = ''
    container network delete "$NAME" >/dev/null 2>&1 || true
    container volume delete "$NAME" >/dev/null 2>&1 || true
    ! sudo -n true 2>/dev/null || sudo -n container system dns delete "$NAME" >/dev/null 2>&1 || true
    for k in "$BATS_FILE_TMPDIR"/previous-kernel/*; do
      [ ! -e "$k" ] || container system kernel set --force --binary "$k" >/dev/null
    done
    env -u XDG_CONFIG_HOME container system start >/dev/null
  '';
  tests = {
    "the runtime is up" = ''
      run container system status --format json
      assert_success
      assert_equal "$(jq -r .status <<<"$output")" running
    '';
    "the kernel is the declared one, and is set once" = ''
      cmp "$KERNELS/default.kernel-arm64" ${apple-container-kernel}/vmlinux-arm64
      run cat "$BATS_FILE_TMPDIR/first.log"
      assert_output --partial 'installing the arm64 kernel'
      run ${start}
      assert_success
      refute_output --partial 'installing'
    '';
    "the network and the volume are created, once" = ''
      container network list --format json | jq -e --arg n "$NAME" 'any(.[]; .id == $n)'
      container volume list --format json | jq -e --arg n "$NAME" 'any(.[]; .id == $n)'
      run cat "$BATS_FILE_TMPDIR/first.log"
      assert_output --partial "creating network $NAME"
      assert_output --partial "creating volume $NAME"
      run ${start}
      assert_success
      refute_output --partial creating
    '';
    "the default domain is in config.toml, and in effect" = ''
      assert_equal "$(cat "$XDG_CONFIG_HOME/container/config.toml")" "$(printf '[dns]\ndomain = "%s"' "$NAME")"
      assert_equal "$(container system property list --format json | jq -r .dns.domain)" "$NAME"
    '';
    "DNS domains are created, once, as root" = ''
      sudo -n true 2>/dev/null || skip 'needs passwordless sudo'
      run sudo -n ${dns}
      assert_success
      assert_output --partial "creating DNS domain $NAME"
      container system dns list --format json | jq -e --arg d "$NAME" 'index($d) != null'
      run sudo -n ${dns}
      refute_output --partial creating
    '';
  };
}
