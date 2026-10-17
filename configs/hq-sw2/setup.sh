#!/bin/sh
# hq-sw2 - second HQ access switch.
#
# Connected to hq-sw1 with TWO parallel links, which creates a layer-2 loop.
# STP elects hq-sw1 as root (lower priority) and puts one of the two links in
# the blocking state. Disabling STP here is the broadcast-storm fault scenario.
#
#   eth1  hq-sw1 (link A)   VLAN 10,20,30,99
#   eth2  hq-sw1 (link B)   VLAN 10,20,30,99
#   eth3  hq-users2         VLAN 10
set -eu

BR=br0
TRUNK_VIDS="10 20 30 99"

ip link add "$BR" type bridge
ip link set "$BR" type bridge vlan_filtering 1 \
    stp_state 1 forward_delay 400 hello_time 200 max_age 600
ip link set "$BR" up

add_access() {
    ip link set "$1" master "$BR"
    ip link set "$1" up
    bridge vlan del dev "$1" vid 1 2>/dev/null || true
    bridge vlan add dev "$1" vid "$2" pvid untagged
}

add_trunk() {
    ip link set "$1" master "$BR"
    ip link set "$1" up
    bridge vlan del dev "$1" vid 1 2>/dev/null || true
    for v in $TRUNK_VIDS; do
        bridge vlan add dev "$1" vid "$v"
    done
}

add_trunk  eth1
add_trunk  eth2
add_access eth3 10

echo "hq-sw2: bridge ready (STP non-root, one uplink must block)"
