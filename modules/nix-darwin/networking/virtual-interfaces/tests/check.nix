{
  lib,
  makeTest,
  darwin,
  dash,
}:
let
  inherit (darwin) esc json text;
  s = darwin.eval [
    {
      networking.virtualInterfaces = {
        feth50 = {
          parent = "en0";
          vlanId = 40;
          macAddress = "02:4C:4C:4D:00:01";
        };
        feth52 = {
          parent = "en0";
          vlanId = 40;
          macAddress = "02:47:52:47:00:01";
          ipv6 = false;
        };
        feth60 = {
          parent = "en1";
          vlanId = 41;
          macAddress = "02:00:00:00:00:60";
          dhcp = false;
        };
      };
    }
  ];
  daemon = (s.daemon "virtual-interfaces").serviceConfig;
  script = text "virtual-interfaces" s.config.system.build.virtualInterfaces.text;
  activation = name: text name s.config.system.activationScripts.${name}.text;
  failed = legs: (darwin.eval [ { networking.virtualInterfaces = legs; } ]).failedAssertions;
  leg = vlanId: macAddress: {
    parent = "en0";
    inherit vlanId macAddress;
  };

  # Each runs under both of the shells /bin/sh may be.
  scenarios = {
    "a cold boot plumbs every leg" = ''
      vi || fail "$(cat "$BATS_TEST_TMPDIR/stderr")"
      assert_equal "$(cat "$FAKE_NET/vlan40/vlan")" "40 en0"
      assert_equal "$(cat "$FAKE_NET/vlan41/vlan")" "41 en1"
      member bridge40 vlan40 && member bridge40 feth51 && member bridge40 feth53
      member bridge41 vlan41 && member bridge41 feth61
      run ! member bridge40 feth50
      assert_equal "$(cat "$FAKE_NET/feth50/peer")" feth51
      assert_equal "$(cat "$FAKE_NET/feth50/ether")" 02:4c:4c:4d:00:01
      [ -e "$FAKE_NET/feth50/lease" ] && [ -e "$FAKE_NET/feth52/lease" ]
      [ -e "$FAKE_NET/feth50/v6" ] && [ ! -e "$FAKE_NET/feth52/v6" ] && [ -e "$FAKE_NET/feth60/v6" ]
      [ -e "$FAKE_NET/feth60/up" ] && [ ! -e "$FAKE_NET/feth60/lease" ]
      run ! grep -q "ipconfig set feth60 DHCP" "$FAKE_LOG"
    '';
    "a healthy tick changes and logs nothing" = ''
      vi
      : >"$FAKE_LOG"
      vi
      [ ! -s "$FAKE_LOG" ] && [ ! -s "$BATS_TEST_TMPDIR/stderr" ]
    '';
    "a leg vmnet detached is repaired, and only it re-armed" = ''
      vi
      ifconfig bridge40 deletem feth51
      ifconfig bridge40 deletem feth53
      ifconfig feth50 down
      rm "$FAKE_NET/feth50/lease"
      : >"$FAKE_LOG"
      vi || fail "$(cat "$BATS_TEST_TMPDIR/stderr")"
      member bridge40 feth51 && member bridge40 feth53
      [ -e "$FAKE_NET/feth50/up" ] && [ -e "$FAKE_NET/feth50/lease" ]
      grep -q "ipconfig set feth50 DHCP" "$FAKE_LOG"
      grep -q "ipconfig set feth50 AUTOMATIC-V6" "$FAKE_LOG"
      run ! grep -q "ipconfig set feth52" "$FAKE_LOG"
      run ! grep -q create "$FAKE_LOG"
    '';
    "a lost IPv6 service is re-armed alone" = ''
      vi
      rm "$FAKE_NET/feth50/v6"
      : >"$FAKE_LOG"
      vi
      assert_equal "$(grep '^ipconfig' "$FAKE_LOG")" "ipconfig set feth50 AUTOMATIC-V6"
      run ! grep -Eq "lladdr|create|addm|deletem|vlan " "$FAKE_LOG"
    '';
    "ipv6 = false disarms a leftover IPv6 service" = ''
      vi
      touch "$FAKE_NET/feth52/v6"
      rm "$BATS_TEST_TMPDIR/state/feth52"
      vi
      [ ! -e "$FAKE_NET/feth52/v6" ]
      : >"$FAKE_LOG"
      vi
      [ ! -s "$FAKE_LOG" ]
    '';
    "a foreign vlan holding the tag blocks only its uplink" = ''
      ifconfig vlan0 create
      ifconfig vlan0 vlan 40 vlandev en0
      run ! vi
      grep -q "vlan0 already carries tag 40 on en0" "$BATS_TEST_TMPDIR/stderr"
      [ ! -e "$FAKE_NET/feth50/peer" ]
      member bridge41 feth61
    '';
    "DHCP is retried, then left to the poller" = ''
      FAKE_DHCP_FAIL=1 run ! vi
      assert_equal "$(grep -c "ipconfig set feth50 DHCP" "$FAKE_LOG")" 4
      grep -q "no DHCPv4 lease on feth50 after 60s" "$BATS_TEST_TMPDIR/stderr"
      vi
      [ -e "$FAKE_NET/feth50/lease" ]
    '';
    "a slow lease is waited for, not re-armed away" = ''
      FAKE_DHCP_DELAY=3 vi || fail "$(cat "$BATS_TEST_TMPDIR/stderr")"
      [ -e "$FAKE_NET/feth50/lease" ] && [ -e "$FAKE_NET/feth52/lease" ]
      assert_equal "$(grep -c "ipconfig set feth50 DHCP" "$FAKE_LOG")" 1
    '';
  };
  shells = {
    bash = "bash --posix";
    dash = "dash";
  };
in
makeTest {
  name = "virtual-interfaces";
  inputs = [ dash ];
  helpers = [
    ''
      vi() {
        $sh "$BATS_TEST_TMPDIR/virtual-interfaces" 2>"$BATS_TEST_TMPDIR/stderr"
      }

      member() {
        grep -qx "$2" "$FAKE_NET/$1/members"
      }
    ''
  ];
  setup = ''
    stub ${./stubs}
    sed -e "s|^PATH=.*|PATH=$PATH|" -e "s|^state_dir=.*|state_dir=$BATS_TEST_TMPDIR/state|" \
      ${script} >"$BATS_TEST_TMPDIR/virtual-interfaces"
    export FAKE_NET="$BATS_TEST_TMPDIR/net" FAKE_LOG="$BATS_TEST_TMPDIR/log"
    mkdir -p "$FAKE_NET/en0" "$FAKE_NET/en1"
    touch "$FAKE_NET/en0/up" "$FAKE_NET/en1/up" "$FAKE_LOG"
  '';
  tests = {
    "the fixture passes every assertion" = ''
      assert_equal ${json s.failedAssertions} '[]'
    '';
    "the daemon runs the root-volume script at load and every 30s, and reloads with it" = ''
      assert_equal ${
        json [
          daemon.Program
          daemon.RunAtLoad
          daemon.StartInterval
          daemon.ProgramArguments
        ]
      } '["/usr/local/libexec/nix-darwin/virtual-interfaces",true,30,null]'
      assert_equal ${esc daemon.EnvironmentVariables.NIX_DARWIN_VIRTUAL_INTERFACES_SCRIPT} ${esc s.config.system.build.virtualInterfaces}
      run cat ${activation "preActivation"}
      assert_output --regexp 'install -m 0755 /nix/store/[^ ]*-virtual-interfaces /usr/local/libexec/nix-darwin/virtual-interfaces'
      run cat ${activation "postActivation"}
      assert_output --partial 'launchctl kickstart -k system/org.nixos.virtual-interfaces'
    '';
    "the script runs before /nix mounts" = ''
      run cat ${script}
      assert_line --index 0 '#!/bin/sh'
      refute_output --partial /nix/store
      assert_line --partial 'feth50 feth51 40 en0 02:4c:4c:4d:00:01 1 1'
      assert_line --partial 'feth52 feth53 40 en0 02:47:52:47:00:01 1 0'
      assert_line --partial 'feth60 feth61 41 en1 02:00:00:00:00:60 0 1'
      dash -n ${script}
    '';
    "without legs, there is no daemon" = ''
      assert_equal ${json ((darwin.eval [ ]).config.launchd.daemons ? virtual-interfaces)} false
    '';
    "bad legs are rejected" = ''
      run echo ${
        json (failed {
          en5 = leg 40 "02:00:00:00:00:01";
          feth51 = leg 40 "02:00:00:00:00:02";
          feth52 = leg 40 "03:00:00:00:00:03";
          feth54 = leg 40 "02:00:00:00:00:01";
          feth56 = leg 41 "02:00:00:00:00:04";
          feth58 = leg 41 "02:00:00:00:00:05" // {
            parent = "en1";
          };
        })
      }
      assert_output --partial 'must be `fethN` (got en5)'
      assert_output --partial 'feth51 must use an even unit number'
      assert_output --partial 'feth52 (03:00:00:00:00:03) must have a unicast macAddress'
      assert_output --partial 'every leg needs a distinct macAddress'
      assert_output --partial 'vlanId 41 is declared on parents en0, en1'
    '';
  }
  // lib.concatMapAttrs (
    shell: sh:
    lib.mapAttrs' (name: body: lib.nameValuePair "${name} (${shell})" "sh=${esc sh}\n${body}") scenarios
  ) shells;
}
