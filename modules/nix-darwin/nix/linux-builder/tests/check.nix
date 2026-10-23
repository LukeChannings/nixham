{
  lib,
  makeTest,
  darwin,
}:
let
  inherit (darwin) esc json text;
  with' =
    builder: extra:
    darwin.eval (
      [
        {
          nix.linux-builder = {
            enable = true;
          }
          // builder;
        }
      ]
      ++ extra
    );
  builder = s: s.config.virtualisation.oci-containers.containers.linux-builder;
  script = s: text "oci-container-linux-builder" (s.script "oci-container-linux-builder");
  activation = s: text "postActivation" s.config.system.activationScripts.postActivation.text;
  sshConfig = s: s.config.environment.etc."ssh/ssh_config.d/100-linux-builder.conf".text;
  nixConfig = s: (builder s).environment.NIX_CONFIG;

  # Never built: the check reads the scripts as text.
  tarball =
    name:
    derivation {
      inherit name;
      system = "aarch64-linux";
      builder = "/bin/false";
    };
  archive = tarball "linux-builder-oci.tar" // {
    imageRef = "linux-builder:prebuilt";
  };
  registryRef = "ghcr.io/example/linux-builder:1";
  cache = "https://cache.example.org";

  plain = with' { } [ ];
  full = with' {
    imageFile = archive;
    cpus = 4;
    memory = "8g";
    extraVolumes = [ "/var/lib/cache-key.pem:/run/cache-key.pem:ro" ];
    userSshKeyFile = "/run/secrets/users-key";
    nixConfSecretFile = "/run/secrets/nix.conf";
  } [ ];
  settings = with' {
    config.nix.settings.substituters = [ cache ];
    nixConfSecretFile = "/run/secrets/nix.conf";
  } [ ];
  # config is a deferredModule: its definitions merge.
  merged = with' { config.environment.etc.probe.text = "probe"; } [
    { nix.linux-builder.config.nix.settings.substituters = [ cache ]; }
  ];
  registry = with' { image = registryRef; } [ ];
  alwaysOn = with' { onDemand.enable = false; } [ ];
  ephemeral = with' { ephemeral = true; } [ ];
  noVirtualization = with' { virtualization = false; } [ ];
  both = with' {
    image = registryRef;
    imageFile = archive;
  } [ ];
  noRef = with' { imageFile = tarball "archive.tar"; } [ ];
  neither = with' { imageFile = null; } [ ];
  noDomain = with' { onDemand.enable = false; } [
    { virtualisation.apple-container.system.dns.defaultDomain = null; }
  ];
in
makeTest {
  name = "linux-builder-module";
  tests = {
    "the fixtures pass every assertion" = ''
      assert_equal ${
        json (
          lib.concatMap (s: s.failedAssertions) [
            plain
            full
            settings
            registry
            alwaysOn
            ephemeral
          ]
        )
      } '[]'
    '';
    "it replaces nix-darwin's linux-builder" = ''
      assert_equal ${json (plain.options.nix.linux-builder ? nixConfSecretFile)} true
    '';
    "every script is valid bash" = ''
      assert_bash ${script full}
      assert_bash ${script alwaysOn}
      assert_bash ${activation full}
    '';
    "the builder is an arm64 VM with Rosetta, virtualization and its own kernel, sized as declared" = ''
      run cat ${script full}
      assert_output --regexp ' --cpus 4 --memory 8g --arch arm64 --rosetta --virtualization --kernel /nix/store/[^ ]*-apple-container-kernel-[^ ]*/vmlinux-arm64 '
      assert_output --partial ' --cap-add CAP_NET_ADMIN --cap-add CAP_SYS_ADMIN '
      assert_output --partial ' --masked-path NONE --read-only-path NONE '
      assert_output --partial "--label 'org.nixos.managed-by=nixham'"
      refute_output --partial -- --publish
    '';
    "it mounts /config, the secret nix.conf, the store volume and extraVolumes" = ''
      run cat ${script full}
      assert_output --partial '--volume /var/lib/linux-builder/config:/config:ro --volume /run/secrets/nix.conf:/secrets/nix.conf:ro --volume linux-builder-store:/persist --volume /var/lib/cache-key.pem:/run/cache-key.pem:ro '
      assert_equal ${json (lib.attrNames plain.config.virtualisation.apple-container.volume)} '["linux-builder-store"]'
    '';
    "an ephemeral builder has no store volume" = ''
      run cat ${script ephemeral}
      refute_output --partial /persist
      assert_equal ${json ephemeral.config.virtualisation.apple-container.volume} '{}'
    '';
    "by default, it runs the in-tree image, with config merged in" = ''
      assert_equal ${esc (builder merged).image} ${esc merged.config.nix.linux-builder.package.imageRef}
      assert_equal ${esc merged.config.nix.linux-builder.package.nixosConfig.environment.etc.probe.text} probe
      run echo ${esc (nixConfig merged)}
      assert_line --partial ${esc "substituters = ${cache} "}
    '';
    "Nix settings reach the builder as NIX_CONFIG, the secret nix.conf last, and leave the image as it is" =
      ''
        assert_equal ${esc (builder settings).image} ${esc (builder plain).image}
        run echo ${esc (nixConfig settings)}
        assert_line --partial ${esc "substituters = ${cache} "}
        assert_line --index 0 '# WARNING: this file is generated from the nix.* options in'
        run tail -1 <<<"$output"
        assert_output '!include /secrets/nix.conf'
      '';
    "before its image loads, the start script deletes the image's predecessors, and stale builders" = ''
      run cat ${script full}
      assert_output --regexp "linux-builder-pre-start linux-builder org.nixos.managed-by nixham linux-builder linux-builder:prebuilt"$'\n'
      pre="$(grep -n 'linux-builder-pre-start' <<<"$output" | cut -d: -f1)"
      load="$(grep -n 'image load' <<<"$output" | cut -d: -f1)"
      [ "$pre" -lt "$load" ]
      assert_output --regexp "image load --input /nix/store/[^ ]*-linux-builder-oci.tar"
      assert_output --regexp "--read-only-path NONE linux-builder:prebuilt$"
    '';
    "a registry image is pulled, never loaded, and keeps itself" = ''
      assert_equal ${json registry.config.nix.linux-builder.imageFile} null
      run cat ${script registry}
      refute_output --partial 'image load'
      assert_output --partial ${esc "nixham linux-builder ${registryRef}"}
      assert_output --regexp ${esc "--read-only-path NONE ${registryRef}$"}
    '';
    "on demand, Nix's connections to 127.0.0.1:22022 start it" =
      let
        c = (plain.daemon "oci-container-linux-builder-proxy-22022").serviceConfig;
      in
      ''
        assert_equal ${
          json [
            c.Sockets.Listener.SockNodeName
            c.Sockets.Listener.SockServiceName
            (builtins.tail c.ProgramArguments)
            (plain.agent "oci-container-linux-builder").serviceConfig.RunAtLoad
          ]
        } '["127.0.0.1","22022",["22"],false]'
      '';
    "on demand, it stops once no connection is open" = ''
      assert_equal ${toString (builder plain).apple-container.onDemand.idleTimeout} 0
    '';
    "always on, it runs from login, and is reached by name" = ''
      assert_equal ${
        json (alwaysOn.config.launchd.daemons ? "oci-container-linux-builder-proxy-22022")
      } false
      assert_equal ${json (alwaysOn.agent "oci-container-linux-builder").serviceConfig.RunAtLoad} true
      run echo ${esc (sshConfig alwaysOn)}
      assert_line 'Host linux-builder.container'
      refute_output --partial HostName
      refute_output --partial Port
    '';
    "ssh reaches it through the listener, as the builder user, pinning its host key" = ''
      run printf %s ${esc (sshConfig plain)}
      assert_output "$(
        cat <<'EOF'
      Host linux-builder.container
        HostName 127.0.0.1
        Port 22022
        User builder
        HostKeyAlias linux-builder.container
        UserKnownHostsFile /var/lib/linux-builder/known_hosts
        StrictHostKeyChecking yes
        IdentitiesOnly yes
        IdentityFile /var/lib/linux-builder/ssh_key
      EOF
      )"
    '';
    "with userSshKeyFile, root gets sshKeyFile and everyone else the other" = ''
      run echo ${esc (sshConfig full)}
      assert_output --partial "$(printf '%s\n' 'Match originalhost linux-builder.container localuser root' '  IdentityFile /var/lib/linux-builder/ssh_key' 'Match originalhost linux-builder.container !localuser root' '  IdentityFile /run/secrets/users-key')"
    '';
    "Nix builds aarch64-linux and x86_64-linux on it, as many jobs at once as it has CPUs" = ''
      run printf %s ${esc full.config.environment.etc."nix/machines".text}
      assert_output 'ssh-ng://builder@linux-builder.container aarch64-linux,x86_64-linux - 4 1 big-parallel,benchmark,kvm,nixos-test - -'
      assert_equal ${json full.config.nix.distributedBuilds} true
      assert_equal ${json full.config.nix.settings.builders-use-substitutes} true
    '';
    "without virtualization, it claims neither kvm nor nixos-test" = ''
      run cat ${script noVirtualization}
      refute_output --partial -- --virtualization
      assert_equal ${json noVirtualization.config.nix.linux-builder.supportedFeatures} '["big-parallel","benchmark"]'
    '';
    "activation provisions /config, and stops the builder when it changes" = ''
      run cat ${activation full}
      assert_output --regexp 'linux-builder-provision /var/lib/linux-builder alice builder linux-builder.container /var/lib/linux-builder/ssh_key /run/secrets/users-key\)" \]; then'
      assert_output --partial '/bin/launchctl asuser "$(id -u alice)" /usr/bin/sudo -H -u alice --'
      assert_line --regexp '^ +/nix/store/[^ ]*/bin/container stop linux-builder '
    '';
    "image and imageFile exclude each other, and one is needed, with its ref" = ''
      run echo ${json both.failedAssertions}
      assert_output --partial 'exclude each other'
      run echo ${json neither.failedAssertions}
      assert_output --partial 'needs nix.linux-builder.imageFile or nix.linux-builder.image'
      run echo ${json noRef.failedAssertions}
      assert_output --partial 'needs the ref its archive names'
    '';
    "always on, it needs a default domain" = ''
      run echo ${json noDomain.failedAssertions}
      assert_output --partial 'defaultDomain'
    '';
  };
}
