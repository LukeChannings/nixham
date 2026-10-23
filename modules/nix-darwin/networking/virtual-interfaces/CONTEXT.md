# virtual-interfaces

Per-service network interfaces for a macOS host, each with its own MAC address and DHCP lease on a tagged VLAN.

## Language

**leg**:
One declared interface: an even-numbered `fethN`, holding the leg's MAC address and lease, peered with `feth(N+1)`, which joins the leg's bridge.
_Avoid_: virtual interface, vif

**uplink**:
`vlan<vlanId>` on the leg's parent NIC, bridged with every leg of that tag in `bridge<vlanId>`. One per tag.

**re-arm**:
Setting a leg's MAC address and restarting its DHCP client, which drops its lease. Only for a leg that is new since boot, changed, down, or unleased; a leg that merely fell out of its bridge is re-attached instead.
