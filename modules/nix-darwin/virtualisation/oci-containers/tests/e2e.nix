# Runs an on-demand container through this user's runtime as launchd would,
# but as this user: the agent in this user's session, the listener as socat
# (inetd nowait) instead of a root daemon. Logs and stamps live under dir.
{
  makeTest,
  darwin,
  jq,
  socat,
}:
let
  name = "nixham-e2e";
  port = "29022";
  dir = "/tmp/nixham-e2e-oci-containers";
  # nix-build evaluates impurely; the agent finds its user by name.
  user =
    let
      u = builtins.getEnv "USER";
    in
    if u == "" then throw "oci-containers' end-to-end test needs USER" else u;
  label = "org.nixos.oci-container-${name}";

  s = darwin.eval [
    (
      { lib, ... }:
      {
        system.primaryUser = lib.mkForce user;
        virtualisation.apple-container.network.${name} = { };
        virtualisation.oci-containers = {
          logDir = "${dir}/log";
          stateDir = "${dir}/state";
          containers.${name} = {
            image = "alpine:3.19";
            cmd = [
              "nc"
              "-lk"
              "-p"
              "8080"
              "-e"
              "sh"
              "-c"
              "echo hello; sleep 10"
            ];
            apple-container.onDemand = {
              enable = true;
              ports = [ "127.0.0.1:${port}:8080" ];
              idleTimeout = 1;
              startTimeout = 120;
            };
          };
          containers."${name}-gated" = {
            image = "alpine:3.19";
            cmd = [
              "sleep"
              "600"
            ];
            networks = [ name ];
          };
        };
      }
    )
  ];
  inherit (s) config pkgs;
  agent = pkgs.writeText "${label}.plist" config.environment.userLaunchAgents."${label}.plist".text;
  idle = (s.agent "oci-container-${name}-idle").command;
  proxy = config.virtualisation.oci-containers.containers.${name}.apple-container.onDemand.proxy;
  gated = (s.agent "oci-container-${name}-gated").command;
in
makeTest {
  name = "oci-containers-e2e";
  kind = "e2e";
  inputs = [
    jq
    socat
  ];
  helpers = [
    ''
      NAME=${name} PORT=${port} LABEL=${label} DIR=${dir}

      # connect [nc args...]: as ssh does, keeping its half open: socat ends a
      # half-closed connection, proxy and all, within 0.5s. Without bats' fd 3,
      # which would keep bats waiting on the sleep.
      connect() {
        /usr/bin/nc "$@" 127.0.0.1 "$PORT" < <(exec sleep 60 3>&-) 3>&-
      }

      state() {
        container inspect "$1" 2>/dev/null | jq -r '.[0].status.state'
      }
    ''
  ];
  setupFile = ''
    rm -rf "$DIR"
    mkdir -p "$DIR/log" "$DIR/state/$NAME"
    container image inspect alpine:3.19 >/dev/null 2>&1 || container image pull alpine:3.19 >/dev/null
    # launchd loads only plists owned by the user.
    install -m 644 ${agent} "$DIR/$LABEL.plist"
    launchctl bootstrap "gui/$(id -u)" "$DIR/$LABEL.plist"
    # Execs the proxy by its store path, as launchd does, without putting that
    # path on the listener's command line, where the watchdog would see it.
    printf '#!/bin/sh\nexec %s 8080\n' ${proxy} >"$DIR/run-proxy"
    chmod +x "$DIR/run-proxy"
    socat "TCP4-LISTEN:$PORT,bind=127.0.0.1,fork,reuseaddr" EXEC:"$DIR/run-proxy" 3>&- &
    echo $! >"$DIR/listener.pid"
  '';
  teardownFile = ''
    kill "$(cat "$DIR/listener.pid")" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    container delete --force "$NAME" "$NAME-gated" >/dev/null 2>&1 || true
    container network delete "$NAME" >/dev/null 2>&1 || true
    rm -rf "$DIR"
  '';
  tests = {
    "a connection starts the container, a second is bridged without a start, and the watchdog stops it once idle" =
      ''
        container stop "$NAME" >/dev/null 2>&1 || true
        : >"$DIR/log/$NAME-proxy.log"

        run connect -w 150
        assert_output hello
        assert_equal "$(state "$NAME")" running
        run grep -c "starting $NAME" "$DIR/log/$NAME-proxy.log"
        assert_output 1

        run connect -w 3
        assert_output hello
        run grep -c "starting $NAME" "$DIR/log/$NAME-proxy.log"
        assert_output 1

        [ -e "$DIR/state/$NAME/last-activity" ]
        # As launchd's StartInterval, sooner: the last connection may yet be closing.
        deadline=$((SECONDS + 60))
        until [ "$(state "$NAME")" = stopped ]; do
          [ "$SECONDS" -lt "$deadline" ] || fail "still $(state "$NAME") after 60s"
          ${idle} >>"$DIR/idle.log" 2>&1
          sleep 1
        done
        run cat "$DIR/idle.log"
        assert_output --partial "$NAME idle for"
      '';
    "the watchdog leaves a container with an open connection alone" = ''
      # Open for the 10s the container keeps each connection.
      connect >/dev/null 3>&- &
      holder=$!
      until [ "$(state "$NAME")" = running ]; do sleep 1; done
      sleep 3
      run ${idle}
      kill "$holder" 2>/dev/null || true
      refute_output --partial 'idle for'
      assert_equal "$(state "$NAME")" running
    '';
    "a container waits for the runtime's networks it uses" = ''
      container network delete "$NAME" >/dev/null 2>&1 || true
      ${gated} >"$DIR/gated.log" 2>&1 3>&- &
      gated=$!
      sleep 5
      kill -0 "$gated"
      [ -z "$(state "$NAME-gated")" ]
      container network create "$NAME" >/dev/null
      deadline=$((SECONDS + 120))
      until [ "$(state "$NAME-gated")" = running ]; do
        [ "$SECONDS" -lt "$deadline" ] || fail "$NAME-gated never ran: $(cat "$DIR/gated.log")"
        sleep 1
      done
      container delete --force "$NAME-gated" >/dev/null
      kill "$gated" 2>/dev/null || true
    '';
  };
}
