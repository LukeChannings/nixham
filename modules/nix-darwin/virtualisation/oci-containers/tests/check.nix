{ makeTest, darwin }:
let
  inherit (darwin) esc json text;
  with' =
    containers: extra:
    darwin.eval ([ { virtualisation.oci-containers.containers = containers; } ] ++ extra);
  agent = s: name: s.agent "oci-container-${name}";
  script = s: name: text "oci-container-${name}" (s.script "oci-container-${name}");
  activation = s: name: text "${name}-activation" s.config.system.activationScripts.${name}.text;
  proxy =
    s: name:
    text "${name}-proxy"
      s.config.virtualisation.oci-containers.containers.${name}.apple-container.onDemand.proxy.text;
  listener = port: (full.daemon "oci-container-ssh-proxy-${toString port}").serviceConfig;

  webapp = {
    image = "nginx:1.25";
    imageFile = builtins.toFile "nginx.tar" "";
    ports = [
      "8080:80"
      "127.0.0.1:8443:443"
    ];
    volumes = [
      "/var/www:/usr/share/nginx/html:ro"
      "cache:/cache"
    ];
    environment.FOO = "bar";
    environmentFiles = [ "/run/secrets/webapp.env" ];
    labels."com.example.version" = "1.0";
    networks = [
      "v6"
      "default"
    ];
    cpus = 2;
    memory = "512m";
    privileged = true;
    capabilities = {
      CAP_NET_ADMIN = false;
      NET_RAW = false;
      MKNOD = null;
    };
    user = "1000:1000";
    workdir = "/srv";
    entrypoint = "/bin/sh";
    cmd = [
      "-c"
      "echo hello"
    ];
    extraOptions = [ "--ssh" ];
    apple-container = {
      arch = "amd64";
      rosetta = true;
      virtualization = true;
      init = true;
      initImage = "local/init:1";
      kernel = "/opt/kernels/vmlinux";
      mounts = [ "type=tmpfs,target=/scratch" ];
      tmpfs = [ "/run" ];
      shmSize = "1g";
      readOnly = true;
      ulimits = [ "nofile=1024:2048" ];
      dns = {
        servers = [ "1.1.1.1" ];
        domain = "example.com";
        searchDomains = [ "svc.example.com" ];
        options = [ "ndots:2" ];
      };
      preStart = "echo pre-start-hook";
    };
  };
  full =
    with'
      {
        inherit webapp;
        private = {
          image = "registry.example.test/app:1";
          login = {
            registry = "registry.example.test";
            username = "deploy";
            passwordFile = "/run/secrets/registry-password";
          };
        };
        worker = {
          image = "worker:1";
          dependsOn = [ "webapp" ];
          autoStart = false;
        };
        ssh = {
          image = "sshd:1";
          apple-container.onDemand = {
            enable = true;
            ports = [
              "127.0.0.1:2222:22"
              "8022:22"
            ];
            idleTimeout = 600;
          };
        };
      }
      [
        {
          virtualisation.apple-container.network.v6.subnetV6 = "fd00::/64";
          virtualisation.apple-container.volume.cache = { };
        }
      ];
  onDemandAutoStart = with' {
    ssh = {
      image = "sshd:1";
      autoStart = true;
      apple-container.onDemand = {
        enable = true;
        ports = [ "2222:22" ];
      };
    };
  } [ ];
  onDemandCollision = with' {
    ssh = {
      image = "sshd:1";
      ports = [ "127.0.0.1:2222:22" ];
      apple-container.onDemand = {
        enable = true;
        ports = [ "2222:22" ];
      };
    };
  } [ ];
  onDemandNoPorts = with' {
    ssh = {
      image = "sshd:1";
      apple-container.onDemand.enable = true;
    };
  } [ ];
  badDependsOn = with' {
    a = {
      image = "a";
      dependsOn = [ "nope" ];
    };
  } [ ];
  badDns = with' {
    a = {
      image = "a";
      apple-container.dns = {
        disable = true;
        servers = [ "1.1.1.1" ];
      };
    };
  } [ ];
  runtimeDisabled = with' { a.image = "a"; } [ { virtualisation.apple-container.enable = false; } ];
in
makeTest {
  name = "oci-containers";
  tests = {
    "the fixture passes every assertion, and enables the runtime" = ''
      assert_equal ${json full.failedAssertions} '[]'
      assert_equal ${json full.config.virtualisation.apple-container.enable} true
    '';
    "every script is valid bash" = ''
      for s in ${
        toString (
          map (script full) [
            "webapp"
            "private"
            "worker"
            "ssh"
            "ssh-idle"
          ]
        )
      }; do assert_bash "$s"; done
      assert_bash ${proxy full "ssh"}
      assert_bash ${activation full "postActivation"}
    '';
    "a container agent runs its container at login and keeps it running, logging to its own file" =
      let
        w = (agent full "webapp").serviceConfig;
        k = (agent full "worker").serviceConfig;
      in
      ''
        assert_equal ${
          json [
            w.Label
            w.RunAtLoad
            w.KeepAlive
            w.StandardOutPath
          ]
        } '["org.nixos.oci-container-webapp",true,true,"/var/log/oci-containers/webapp.log"]'
        assert_equal ${
          json [
            k.RunAtLoad
            k.KeepAlive
          ]
        } '[false,true]'
      '';
    "every option reaches container run" = ''
      run cat ${script full "webapp"}
      assert_line --regexp "bin/container run --name webapp --volume /var/www:/usr/share/nginx/html:ro --volume cache:/cache --mount 'type=tmpfs,target=/scratch' --tmpfs /run --publish 8080:80 --publish 127.0.0.1:8443:443 --env 'FOO=bar' --env-file /run/secrets/webapp.env --label 'com.example.version=1.0' --network v6 --network default --user 1000:1000 --workdir /srv --entrypoint /bin/sh .* --cpus 2 --memory 512m --arch amd64 --rosetta --virtualization --init --init-image local/init:1 --kernel /opt/kernels/vmlinux --shm-size 1g --read-only --ulimit 'nofile=1024:2048' --dns 1.1.1.1 --dns-domain example.com --dns-search svc.example.com --dns-option ndots:2 --ssh nginx:1.25 -c 'echo hello'$"
    '';
    "privileged adds CAP_SYS_ADMIN and CAP_NET_ADMIN, which capabilities override" = ''
      run cat ${script full "webapp"}
      assert_output --partial '--cap-add CAP_SYS_ADMIN --cap-drop CAP_NET_ADMIN --cap-drop NET_RAW --cpus'
      refute_output --partial MKNOD
      refute_output --partial -- --privileged
    '';
    "the agent waits for the apiserver, and the runtime's networks and volumes it uses, before anything else" =
      ''
        run cat ${script full "webapp"}
        assert_output --regexp 'container system status >/dev/null 2>&1 && [^ ]*container network inspect v6 >/dev/null 2>&1 && [^ ]*container volume inspect cache >/dev/null 2>&1'
        refute_output --partial 'network inspect default'
        ready="$(grep -n '^until ready' <<<"$output" | cut -d: -f1)"
        hook="$(grep -n '^echo pre-start-hook' <<<"$output" | cut -d: -f1)"
        load="$(grep -n 'image load' <<<"$output" | cut -d: -f1)"
        [ "$ready" -lt "$hook" ] && [ "$hook" -lt "$load" ]
        run cat ${script full "private"}
        assert_output --regexp 'ready\(\) \{'$'\n'"  [^ ]*container system status >/dev/null 2>&1"$'\n'"\}"
      '';
    "an image file is loaded only while its image is absent" = ''
      run cat ${script full "webapp"}
      assert_output --regexp 'if ! [^ ]*container image inspect nginx:1.25 >/dev/null 2>&1; then'$'\n'"  [^ ]*container image load --input /nix/store/[^ ]*-nginx.tar"
    '';
    "registry login reads the password from its file at runtime" = ''
      run cat ${script full "private"}
      assert_output --regexp "container registry login --username deploy --password-stdin registry.example.test </run/secrets/registry-password; then"
    '';
    "dependsOn waits for the dependency to run" = ''
      run cat ${script full "worker"}
      assert_output --partial 'waiting for container webapp'
      assert_output --partial "inspect webapp 2>/dev/null | "
      assert_output --partial "'.[0].status.state == \"running\"'"
    '';
    "an on-demand container is neither started at login nor kept alive" =
      let
        c = (agent full "ssh").serviceConfig;
      in
      ''
        assert_equal ${
          json [
            c.RunAtLoad
            c.KeepAlive
          ]
        } '[false,false]'
      '';
    "each listener is an inetd-nowait root daemon, running the proxy with the container's port" =
      let
        a = listener 2222;
        b = listener 8022;
      in
      ''
        assert_equal ${
          json [
            a.Label
            a.inetdCompatibility.Wait
            (builtins.tail a.ProgramArguments)
            a.Sockets.Listener.SockNodeName
            a.Sockets.Listener.SockServiceName
            a.Sockets.Listener.SockType
            a.Sockets.Listener.SockFamily
          ]
        } '["org.nixos.oci-container-ssh-proxy-2222",false,["22"],"127.0.0.1","2222","stream","IPv4"]'
        assert_equal ${
          json [
            b.Sockets.Listener.SockNodeName
            b.Sockets.Listener.SockServiceName
          ]
        } '[null,"8022"]'
        run echo ${esc (builtins.head a.ProgramArguments)}
        assert_output --regexp '^/nix/store/[^/]*-oci-container-ssh-proxy$'
      '';
    "the proxy logs before anything else, kickstarts the agent in the user's session, and dials the container's own IPv4 address" =
      ''
        run cat ${proxy full "ssh"}
        assert_line --index 1 'exec 2>>/var/log/oci-containers/ssh-proxy.log'
        assert_output --partial 'launchctl kickstart "gui/$uid/org.nixos.oci-container-ssh"'
        assert_output --partial '/bin/launchctl asuser "$uid" /usr/bin/sudo -H -u alice --'
        assert_output --regexp 'asUser [^ ]*/bin/container inspect ssh '
        assert_output --partial '.ipv4Address'
        assert_output --partial 'socat STDIO "TCP4:$ip:$port"'
        assert_output --partial 'deadline=$((SECONDS + 300))'
        assert_output --partial 'touch /var/run/oci-containers/ssh/last-activity'
        assert_output --partial 'trap stamp EXIT'
        assert_output --partial 'lock=/var/run/oci-containers/ssh/connect.lock'
        refute_output --partial 'exec socat'
      '';
    "the idle watchdog stops the container after idleTimeout, unless a connection or a session is open" =
      ''
        assert_equal ${json (agent full "ssh-idle").serviceConfig.StartInterval} 60
        run cat ${script full "ssh-idle"}
        assert_output --partial ${esc "pgrep -f ${builtins.head (listener 2222).ProgramArguments}"}
        assert_output --partial "pgrep -f 'container (exec|attach) .*ssh'"
        assert_output --partial '[ "$idle" -ge 600 ] || exit 0'
        assert_output --regexp 'bin/container stop ssh$'
      '';
    "activation stops an on-demand container that runs an older start script" = ''
      run cat ${activation full "postActivation"}
      assert_output --partial 'install -d -o alice /var/run/oci-containers/ssh'
      assert_output --regexp 'asUser [^ ]*/bin/container stop ssh'
      assert_output --regexp '!= /nix/store/[^ ]*-oci-container-ssh-start \]'
    '';
    "the log dir is the primary user's, before launchd loads the agents" = ''
      run cat ${activation full "preActivation"}
      assert_output --partial 'install -d -o alice /var/log/oci-containers'
    '';
    "on demand, autoStart is a contradiction" = ''
      run echo ${json onDemandAutoStart.failedAssertions}
      assert_output --partial 'neither autoStart nor keepAlive'
    '';
    "on demand, a listener may not take a published port" = ''
      run echo ${json onDemandCollision.failedAssertions}
      assert_output --partial 'host ports 2222 are both'
    '';
    "on demand, there must be listeners" = ''
      run echo ${json onDemandNoPorts.failedAssertions}
      assert_output --partial 'onDemand.ports needs listeners'
    '';
    "dependsOn, dns.disable and a disabled runtime are checked" = ''
      run echo ${json badDependsOn.failedAssertions}
      assert_output --partial 'undefined containers: nope'
      run echo ${json badDns.failedAssertions}
      assert_output --partial 'excludes the other'
      run echo ${json runtimeDisabled.failedAssertions}
      assert_output --partial 'which is disabled'
    '';
  };
}
