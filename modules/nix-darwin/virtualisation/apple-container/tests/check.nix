{
  lib,
  makeTest,
  darwin,
}:
let
  inherit (darwin) esc json text;
  enabled =
    cfg:
    darwin.eval [
      {
        virtualisation.apple-container = {
          enable = true;
        }
        // cfg;
      }
    ];
  activation = s: name: text "${name}-activation" s.config.system.activationScripts.${name}.text;
  runtime = s: text "apple-container-runtime" (s.script "apple-container");

  plain = enabled { };
  full = enabled {
    system.kernel = {
      arm64 = "https://example.org/kata.tar.zst";
      amd64 = {
        tar = "/opt/kernels/amd64.tar";
        binary = "./vmlinux";
        digest = "sha256:abc";
      };
    };
    system.dns.domains = [ "test" ];
    network.v6 = {
      subnetV6 = "fd12:3456:789a::/64";
      internal = true;
      options.mtu = "1400";
      labels.role = "ipv6";
    };
    volume.cache = {
      size = "64G";
      labels.role = "cache";
    };
    socktainer.enable = false;
  };
  noDefaultDomain = enabled { system.dns.defaultDomain = null; };
  volumesRoot = enabled { volumesRoot = "/Volumes/Virtual Machines/container-volumes/"; };
  badKernelArch = enabled { system.kernel.x86_64 = "/k.tar"; };
  badVolumesRoot = enabled { volumesRoot = "/Volumes/Virtual Machines"; };
in
makeTest {
  name = "apple-container";
  tests = {
    "the defaults pass every assertion" = ''
      assert_equal ${json (plain.failedAssertions ++ full.failedAssertions)} '[]'
    '';
    "the runtime agent runs at load, and is relaunched only while it fails" =
      let
        c = (plain.agent "apple-container").serviceConfig;
      in
      ''
        assert_equal ${
          json [
            c.Label
            c.RunAtLoad
            c.KeepAlive.SuccessfulExit
            c.StandardErrorPath
          ]
        } '["org.nixos.apple-container",true,false,"/var/log/apple-container/runtime.log"]'
      '';
    "the runtime agent's scripts are valid bash" = ''
      assert_bash ${runtime plain}
      assert_bash ${runtime full}
      assert_bash ${activation full "postActivation"}
    '';
    "without a kernel, the runtime installs its recommended one" = ''
      run cat ${runtime plain}
      assert_output --regexp 'bin/container system start --enable-kernel-install'
      refute_output --partial 'kernel set'
    '';
    "a declared kernel disables the interactive install and is set, by force, once" = ''
      run cat ${runtime full}
      assert_output --regexp 'bin/container system start --disable-kernel-install'
      assert_output --regexp "kernel set --force --arch arm64 --tar https://example.org/kata.tar.zst --binary ./opt/kata/share/kata-containers/vmlinux.container"$'\n'
      assert_output --partial 'kernel set --force --arch amd64 --tar /opt/kernels/amd64.tar --binary ./vmlinux --digest sha256:abc'
      assert_output --regexp 'if \[ ! -e "\$state/kernel-arm64-[0-9a-f]{12}" \]'
      assert_output --regexp 'touch "\$state/kernel-amd64-[0-9a-f]{12}"'
    '';
    "networks and volumes are created after the runtime starts, only when missing" = ''
      run cat ${runtime full}
      assert_output --partial "network create --subnet-v6 fd12:3456:789a::/64 --internal --option 'mtu=1400' --label 'role=ipv6' v6"
      assert_output --partial "volume create -s 64G --label 'role=cache' cache"
      assert_output --partial "network list --format json"
      assert_output --partial "--arg id v6 'any(.[]; .id == \$id)'"
      start="$(grep -n 'system start' <<<"$output" | head -1 | cut -d: -f1)"
      create="$(grep -n 'network create' <<<"$output" | head -1 | cut -d: -f1)"
      [ "$start" -lt "$create" ]
    '';
    "the default domain is written to config.toml before the runtime starts" = ''
      run cat ${runtime plain}
      assert_line --partial "toml='[dns]"
      assert_line 'domain = "container"'"'"
      [ "$(grep -n 'printf' <<<"$output" | cut -d: -f1)" -lt "$(grep -n 'system start' <<<"$output" | head -1 | cut -d: -f1)" ]
    '';
    "a null default domain leaves config.toml alone" = ''
      run cat ${runtime noDefaultDomain}
      refute_output --partial 'toml='
    '';
    "DNS domains, the default among them, are created as root at activation, only when missing" = ''
      run cat ${activation full "postActivation"}
      assert_output --partial 'system dns list --format json'
      assert_output --regexp 'bin/container system dns create test '
      assert_output --regexp 'bin/container system dns create container '
      run cat ${activation noDefaultDomain "postActivation"}
      refute_output --partial 'dns create'
    '';
    "the log dir is the primary user's, before launchd loads the agents" = ''
      run cat ${activation plain "preActivation"}
      assert_output --partial 'install -d -o alice /var/log/apple-container'
    '';
    "the CLI is installed" = ''
      run printf '%s\n' ${
        lib.concatMapStringsSep " " (p: esc p.name) plain.config.environment.systemPackages
      }
      assert_line --regexp '^container-'
    '';
    "socktainer is on by default, keeps no docker context, and listens in the primary user's home" =
      let
        c = (plain.agent "socktainer").serviceConfig;
      in
      ''
        run echo ${esc (builtins.elemAt c.ProgramArguments 2)}
        assert_output --regexp 'socktainer-[^ ]*/bin/socktainer --no-docker-context$'
        assert_equal ${json c.KeepAlive} true
        assert_equal ${esc plain.config.virtualisation.apple-container.socktainer.socketPath} /Users/alice/.socktainer/container.sock
        assert_equal ${json (full.config.launchd.user.agents ? socktainer)} false
      '';
    "volumesRoot redirects the volumes dir before launchd loads the agents" = ''
      run cat ${activation volumesRoot "launchd"}
      assert_output --regexp "apple-container-volumes-root '/Users/alice/Library/Application Support/com.apple.container/volumes' '/Volumes/Virtual Machines/container-volumes' '/Volumes/Virtual Machines' alice"
      run cat ${activation plain "launchd"}
      refute_output --partial volumes-root
    '';
    "assertions reject unknown kernel architectures and volume mount roots" = ''
      run echo ${json badKernelArch.failedAssertions}
      assert_output --partial 'not: x86_64'
      run echo ${json badVolumesRoot.failedAssertions}
      assert_output --partial 'must be a directory below a volume'
    '';
  };
}
