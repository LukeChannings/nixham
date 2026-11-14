# virtual-interfaces

Per-service network interfaces for a macOS host, each with its own MAC address and DHCP lease on a tagged VLAN.

## Language

**leg**:
One declared interface: an even-numbered `fethN`, holding the leg's MAC address and lease, peered with `feth(N+1)`, which joins the leg's bridge.
_Avoid_: virtual interface, vif

**uplink**:
`vlan<vlanId>` on the leg's parent NIC, bridged with every leg of that tag in `bridge<vlanId>`. One per tag.

**register**:
Listing a bridge, and its members in the order the script adds them, in SystemConfiguration's preferences. configd destroys every bridge the preferences do not list, so an unregistered uplink lasts only until something publishes a new network interface — which every VM start does, through vmnet. Registering also makes macOS add a network service for the bridge, minutes after it takes the bridge over, which the poller disables: enabled, it runs a second DHCP client on the legs' network under the bridge's own MAC.

**re-arm**:
Setting a leg's MAC address and restarting its DHCP client, which drops its lease. Only for a leg that is new since boot, changed, down, or unleased; a leg that merely fell out of its bridge is re-attached instead. The clients run as `ipconfig setService` services, which configd keeps when interfaces come and go; it frees `ipconfig set`'s on every VM start and stop.
