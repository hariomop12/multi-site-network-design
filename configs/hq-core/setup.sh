#!/bin/sh
# Boot hook for hq-core.
#
# Runs before FRR loads its configuration, so anything zebra needs to find
# already exists (this is where the 802.1Q sub-interfaces come from).
set -eu

# ---------------------------------------------------------------- kernel ----
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.all.rp_filter=0
sysctl -qw net.ipv4.conf.default.rp_filter=0

for i in 1 2 3 4; do
    ip link set "eth$i" up 2>/dev/null || true
done

# ------------------------------------------ router-on-a-stick sub-interfaces -
# The single trunk to hq-sw1 carries four VLANs; each one gets a sub-interface
# that hq-core later uses as its default gateway.
for vlan in 10 20 30 99; do
    if ! ip link show "eth2.$vlan" >/dev/null 2>&1; then
        ip link add link eth2 name "eth2.$vlan" type vlan id "$vlan"
    fi
    ip link set "eth2.$vlan" up
done

# ------------------------------------------------------------------ NAT ----
# The official FRR build has no NAT support, so NAT overload is done with
# nftables: everything leaving towards the ISP is masqueraded behind eth1.
nft flush ruleset
nft -f /etc/lab/nat.nft

# ------------------------------------------------------ DHCP server -------
# hq-core is the default gateway of every HQ VLAN, so it can serve the user and
# voice scopes without a relay.
mkdir -p /var/lib/lab
dnsmasq --conf-file=/etc/lab/dnsmasq.conf

echo "hq-core: sub-interfaces up, NAT loaded, DHCP server started"
