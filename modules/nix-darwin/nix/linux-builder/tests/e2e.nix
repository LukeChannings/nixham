# Runs a builder through this user's runtime as launchd and activation would,
# but as this user: the container agent in this user's session, the listener
# as socat (inetd nowait) instead of a root daemon, provisioning without root.
# Its container, image repository and label are its own, so it never touches
# a linux-builder this host runs. Everything else lives under dir.
{
  makeTest,
  darwin,
  jq,
  socat,
  linux-builder-image,
}:
let
  name = "nixham-e2e-lb";
  port = "29023";
  dir = "/tmp/nixham-e2e-linux-builder";
  host = "${name}.container";
  secret = "nixham-e2e-secret";
  # nix-build evaluates impurely; the agent finds its user by name.
  user =
    let
      u = builtins.getEnv "USER";
    in
    if u == "" then throw "linux-builder's end-to-end test needs USER" else u;
  label = "org.nixos.oci-container-${name}";

  s = darwin.eval [
    (
      { lib, ... }:
      {
        system.primaryUser = lib.mkForce user;
        nix.linux-builder = {
          enable = true;
          inherit name;
          stateDir = "${dir}/state";
          package = linux-builder-image.override { inherit name; };
          ephemeral = true;
          # Starts on any host: before M3, --virtualization fails to start.
          virtualization = false;
          cpus = 2;
          memory = "4g";
          onDemand.port = lib.toInt port;
          nixConfSecretFile = "${dir}/secret.conf";
          config.nix.settings.connect-timeout = 17;
        };
        virtualisation.oci-containers = {
          logDir = "${dir}/log";
          stateDir = "${dir}/oci";
          containers.${name} = {
            labels."org.nixos.managed-by" = lib.mkForce "nixham-e2e";
            apple-container.onDemand.idleTimeout = 1;
          };
        };
      }
    )
  ];
  inherit (s) config pkgs;
  cfg = config.nix.linux-builder;
  agent = pkgs.writeText "${label}.plist" config.environment.userLaunchAgents."${label}.plist".text;
  idle = (s.agent "oci-container-${name}-idle").command;
  inherit (config.virtualisation.oci-containers.containers.${name}.apple-container.onDemand) proxy;
  sshConfig =
    pkgs.writeText "ssh_config"
      config.environment.etc."ssh/ssh_config.d/100-linux-builder.conf".text;
in
makeTest {
  name = "linux-builder-module-e2e";
  kind = "e2e";
  inputs = [
    jq
    socat
  ];
  helpers = [
    ''
      NAME=${name} PORT=${port} LABEL=${label} DIR=${dir} HOST=${host} REF=${cfg.package.imageRef}

      provision() {
        ${cfg.provision} "$DIR/state" "$(id -un)" builder "$HOST" "$DIR/state/ssh_key" 2>/dev/null
      }

      # b <command>: runs it on the builder, through the listener, as Nix's ssh does.
      b() {
        /usr/bin/ssh -F ${sshConfig} -o BatchMode=yes "$HOST" "$@"
      }

      state() {
        container inspect "$NAME" 2>/dev/null | jq -r '.[0].status.state'
      }

      # probe <system>: a derivation for it, with a unique name, whose output reads "ok".
      probe() {
        echo "derivation { name = \"lb-e2e-$(date +%s)-$RANDOM\"; system = \"$1\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ok > \$out\" ]; }"
      }
    ''
  ];
  setupFile = ''
    rm -rf "$DIR"
    mkdir -p "$DIR/log" "$DIR/oci/$NAME"
    printf 'access-tokens = example.org=%s\n' ${secret} >"$DIR/secret.conf"
    provision >/dev/null
    # launchd loads only plists owned by the user.
    install -m 644 ${agent} "$DIR/$LABEL.plist"
    launchctl bootstrap "gui/$(id -u)" "$DIR/$LABEL.plist"
    # Execs the proxy by its store path, as launchd does, without putting that
    # path on the listener's command line, where the watchdog would see it.
    printf '#!/bin/sh\nexec %s 22\n' ${proxy} >"$DIR/run-proxy"
    chmod +x "$DIR/run-proxy"
    socat "TCP4-LISTEN:$PORT,bind=127.0.0.1,fork,reuseaddr" EXEC:"$DIR/run-proxy" 3>&- &
    echo $! >"$DIR/listener.pid"
  '';
  teardownFile = ''
    kill "$(cat "$DIR/listener.pid")" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    container delete --force "$NAME" >/dev/null 2>&1 || true
    container image ls --format json | jq -r --arg n "$NAME" '.[].configuration.name | select(startswith($n + ":"))' |
      while read -r ref; do container image rm "$ref" >/dev/null 2>&1 || true; done
    rm -rf "$DIR"
  '';
  tests = {
    "Nix builds aarch64-linux and x86_64-linux on it, through the listener, which starts it" = ''
      container stop "$NAME" >/dev/null 2>&1 || true
      run env PATH="/usr/bin:$PATH" NIX_SSHOPTS="-F ${sshConfig}" nix build --impure --no-link --print-out-paths \
        --eval-store auto --store "ssh-ng://$HOST" --expr "[ ($(probe aarch64-linux)) ($(probe x86_64-linux)) ]"
      assert_success
      mapfile -t outs < <(grep '^/nix/store/' <<<"$output")
      assert_equal "$(b cat "''${outs[@]}")" "$(printf 'ok\nok')"
    '';
    "its Nix daemon has the module's settings and the secret file's, whose contents container inspect never shows" =
      ''
        b true
        # As the daemon sees it: builder's own nix can't read the includes.
        run container exec "$NAME" /run/current-system/sw/bin/env -i /run/current-system/sw/bin/nix config show
        assert_line 'connect-timeout = 17'
        assert_line --partial ${secret}
        run container inspect "$NAME"
        assert_output --partial 'connect-timeout = 17'
        refute_output --partial ${secret}
      '';
    "a new host key is pinned, and the builder restarted with it" = ''
      b true
      cp "$DIR/state/known_hosts" "$DIR/old_known_hosts"
      rm "$DIR/state/config/ssh/ssh_host_ed25519_key"
      assert_equal "$(provision)" changed
      container stop "$NAME" >/dev/null
      run b true
      assert_success
      run b -o UserKnownHostsFile="$DIR/old_known_hosts" true
      assert_failure
      assert_output --partial 'HOST IDENTIFICATION HAS CHANGED'
    '';
    "its image is loaded once, and loading it deletes its predecessors" = ''
      b true
      container stop "$NAME" >/dev/null
      container image tag "$REF" "$NAME:stale"
      container image rm "$REF" >/dev/null
      b true
      container image inspect "$REF" >/dev/null
      run container image inspect "$NAME:stale"
      assert_failure
      run grep -c 'deleted the stale image' "$DIR/log/$NAME.log"
      assert_output 1
    '';
    "once idle, the watchdog stops it" = ''
      b true
      deadline=$((SECONDS + 60))
      until [ "$(state)" = stopped ]; do
        [ "$SECONDS" -lt "$deadline" ] || fail "still $(state) after 60s"
        ${idle} >>"$DIR/idle.log" 2>&1
        sleep 1
      done
    '';
  };
}
