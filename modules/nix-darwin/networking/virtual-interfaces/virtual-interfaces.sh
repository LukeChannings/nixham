# Runs from the root volume, before /nix mounts (see launchd's ADR-0001).
# Expects $state_dir, $uplinks ("<tag> <parent>" lines), $legs
# ("<feth> <peer> <tag> <parent> <mac> <dhcp> <ipv6>" lines) and $stable_v6.

log() {
  echo "virtual-interfaces: $*" >&2
}

has_if() {
  ifconfig "$1" >/dev/null 2>&1
}

is_up() {
  ifconfig "$1" 2>/dev/null | sed -n 1p | grep -Eq '[<,]UP[,>]'
}

# is_member <bridge> <ifname>
is_member() {
  ifconfig "$1" 2>/dev/null | grep -Eq "member: $2( |\$)"
}

is_leased() {
  [ -n "$(ipconfig getifaddr "$1" 2>/dev/null)" ]
}

# AUTOMATIC-V6 always configures a link-local address; a DHCPv6 one only
# appears when the RA is managed.
has_v6() {
  ifconfig "$1" 2>/dev/null | grep -q "inet6 fe80:"
}

# Temporary addresses regenerate on every re-arm, stranding established
# connections sourced from them; stable (RFC 7217) addresses re-form
# identically.
v6_source_ok() {
  [ "$stable_v6" = 0 ] || [ "$(sysctl -n net.inet6.ip6.prefer_tempaddr)" = 0 ]
}

# vlan_ok <vlan-if> <tag> <parent>
vlan_ok() {
  ifconfig "$1" 2>/dev/null | grep -q "vlan: $2 parent interface: $3\$"
}

# spec <parent> <tag> <mac> <dhcp> <ipv6>: what, changed, re-arms a leg.
spec() {
  echo "mac=$3 parent=$1 vlan=$2 dhcp=$4 ipv6=$5"
}

# stamp_ok <feth> <spec>: armed with <spec> since boot.
stamp_ok() {
  [ "$(cat "$state_dir/$1" 2>/dev/null)" = "$2" ]
}

# uplink_ok <tag> <parent>
uplink_ok() {
  vlan_ok "vlan$1" "$1" "$2" &&
    is_up "vlan$1" &&
    is_up "bridge$1" &&
    is_member "bridge$1" "vlan$1"
}

# leg_ok <feth> <peer> <tag> <dhcp> <ipv6> <spec>
leg_ok() {
  stamp_ok "$1" "$6" &&
    ifconfig "$1" 2>/dev/null | grep -q "peer: $2\$" &&
    is_up "$1" &&
    is_up "$2" &&
    is_member "bridge$3" "$2" &&
    { [ "$4" != 1 ] || is_leased "$1"; } &&
    { [ "$5" != 1 ] || has_v6 "$1"; }
}

healthy() {
  while read -r h_tag h_parent <&3; do
    uplink_ok "$h_tag" "$h_parent" || return 1
  done 3<<EOT
$uplinks
EOT
  while read -r h_host h_peer h_tag h_parent h_mac h_dhcp h_ipv6 <&3; do
    leg_ok "$h_host" "$h_peer" "$h_tag" "$h_dhcp" "$h_ipv6" \
      "$(spec "$h_parent" "$h_tag" "$h_mac" "$h_dhcp" "$h_ipv6")" || return 1
  done 3<<EOT
$legs
EOT
}

# ensure_uplink <tag> <parent>: vlan<tag> on <parent>, in bridge<tag>.
ensure_uplink() {
  u_tag=$1
  u_parent=$2
  u_vlan=vlan$1
  u_bridge=bridge$1

  u_waited=0
  while ! has_if "$u_parent"; do
    if [ "$u_waited" -ge 120 ]; then
      log "parent interface $u_parent still missing after ${u_waited}s"
      return 1
    fi
    sleep 2
    u_waited=$((u_waited + 2))
  done

  # vmnet allocates bridge100 and up for its shared networks.
  if ifconfig "$u_bridge" 2>/dev/null | grep -q "member: vmenet"; then
    log "$u_bridge is owned by vmnet; choose a vlanId that does not collide with it"
    return 1
  fi

  if ! vlan_ok "$u_vlan" "$u_tag" "$u_parent"; then
    # macOS allows one vlan interface per (parent, tag).
    for u_other in $(ifconfig -l); do
      case $u_other in
      vlan*) ;;
      *) continue ;;
      esac
      [ "$u_other" = "$u_vlan" ] && continue
      if vlan_ok "$u_other" "$u_tag" "$u_parent"; then
        log "$u_other already carries tag $u_tag on $u_parent; destroy it (ifconfig $u_other destroy) so $u_vlan can own the uplink"
        return 1
      fi
    done

    has_if "$u_vlan" || ifconfig "$u_vlan" create || return 1
    u_old=$(ifconfig "$u_vlan" 2>/dev/null | sed -n 's/^.*vlan: .* parent interface: //p')
    case $u_old in
    "" | "<none>") ;;
    *) ifconfig "$u_vlan" -vlandev "$u_old" ;;
    esac
    log "configuring $u_vlan: tag $u_tag on $u_parent"
    ifconfig "$u_vlan" vlan "$u_tag" vlandev "$u_parent" || return 1
  fi
  ifconfig "$u_vlan" up || return 1

  if ! has_if "$u_bridge"; then
    log "creating $u_bridge"
    ifconfig "$u_bridge" create || return 1
  fi
  is_member "$u_bridge" "$u_vlan" || ifconfig "$u_bridge" addm "$u_vlan" || return 1
  ifconfig "$u_bridge" up
}

# ensure_leg <feth> <peer> <tag> <mac> <dhcp> <ipv6> <spec>
ensure_leg() {
  l_host=$1
  l_peer=$2
  l_bridge=bridge$3
  l_mac=$4
  l_dhcp=$5
  l_ipv6=$6
  l_spec=$7

  if ! has_if "$l_host" || ! has_if "$l_peer"; then
    log "$l_host/$l_peer missing; skipping leg"
    return 1
  fi

  # A leg that only fell out of the bridge keeps its lease: re-attach it.
  l_rearm=0
  stamp_ok "$l_host" "$l_spec" || l_rearm=1
  is_up "$l_host" || l_rearm=1
  if [ "$l_dhcp" = 1 ] && ! is_leased "$l_host"; then
    l_rearm=1
  fi

  if [ "$l_rearm" = 1 ]; then
    log "arming $l_host ($l_mac) via $l_peer on $l_bridge"
    ifconfig "$l_host" lladdr "$l_mac" || return 1
    # A changed vlanId leaves the peer in its old bridge, and an interface
    # can only be in one.
    for l_other in $(ifconfig -l); do
      case $l_other in
      bridge*) ;;
      *) continue ;;
      esac
      [ "$l_other" = "$l_bridge" ] && continue
      if is_member "$l_other" "$l_peer"; then
        ifconfig "$l_other" deletem "$l_peer"
      fi
    done
  fi

  if ! ifconfig "$l_host" 2>/dev/null | grep -q "peer: $l_peer\$"; then
    ifconfig "$l_host" peer "$l_peer" || return 1
  fi
  ifconfig "$l_peer" up || return 1
  if ! is_member "$l_bridge" "$l_peer"; then
    log "attaching $l_peer to $l_bridge"
    ifconfig "$l_bridge" addm "$l_peer" || return 1
  fi

  if [ "$l_rearm" = 0 ]; then
    ifconfig "$l_host" up
    # A network change can tear down an ipconfig service on its own.
    if [ "$l_ipv6" = 1 ] && ! has_v6 "$l_host"; then
      log "re-arming IPv6 on $l_host"
      ipconfig set "$l_host" AUTOMATIC-V6 || return 1
    fi
    return 0
  fi

  l_status=0
  if [ "$l_dhcp" = 1 ]; then
    # configd takes ~3s from BOUND to publish a lease, and every
    # `ipconfig set` restarts its client: arm once and poll, re-arming only
    # once the client gives up (and downs the interface), or every 20s.
    ifconfig "$l_host" up
    ipconfig set "$l_host" DHCP
    l_tries=0
    while ! is_leased "$l_host"; do
      if [ "$l_tries" -ge 30 ]; then
        log "no DHCPv4 lease on $l_host after $((l_tries * 2))s; the poller will retry"
        l_status=1
        break
      fi
      sleep 2
      l_tries=$((l_tries + 1))
      if ! is_up "$l_host" || [ $((l_tries % 10)) = 0 ]; then
        ifconfig "$l_host" up
        ipconfig set "$l_host" DHCP
      fi
    done
  else
    ifconfig "$l_host" up
  fi

  if [ "$l_ipv6" = 1 ]; then
    ipconfig set "$l_host" AUTOMATIC-V6 || l_status=1
  else
    ipconfig set "$l_host" NONE-V6 || l_status=1
  fi

  echo "$l_spec" >"$state_dir/$l_host"
  return "$l_status"
}

if ! v6_source_ok; then
  log "preferring stable IPv6 source addresses"
  sysctl -w net.inet6.ip6.prefer_tempaddr=0 >/dev/null
fi

healthy && exit 0

log "plumbing incomplete; repairing"
mkdir -p "$state_dir"
status=0
broken=

while read -r tag parent <&3; do
  if ! ensure_uplink "$tag" "$parent"; then
    log "uplink vlan$tag/bridge$tag on $parent failed"
    broken="$broken $tag "
    status=1
  fi
done 3<<EOT
$uplinks
EOT

# Creating a feth after others are peered or bridged can fail.
while read -r host peer _ <&3; do
  for f in "$host" "$peer"; do
    has_if "$f" ||
      ifconfig "$f" create ||
      log "failed to create $f (feth creation after others are peered can fail; a reboot clears it)"
  done
done 3<<EOT
$legs
EOT

while read -r host peer tag parent mac dhcp ipv6 <&3; do
  case $broken in
  *" $tag "*) continue ;;
  esac
  ensure_leg "$host" "$peer" "$tag" "$mac" "$dhcp" "$ipv6" \
    "$(spec "$parent" "$tag" "$mac" "$dhcp" "$ipv6")" || status=1
done 3<<EOT
$legs
EOT

exit "$status"
