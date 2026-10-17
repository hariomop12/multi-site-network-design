#!/bin/sh
# hq-sw1 - HQ access switch.
#
# A Linux bridge with 802.1Q filtering, which behaves like a managed access
# switch: access ports are untagged in one VLAN, the uplink is a trunk. STP is
# enabled because the two parallel links towards hq-sw2 form a real layer-2
# loop.
#
#   eth1  trunk -> hq-core          VLAN 10,20,30,99 (tagged)
#   eth2  hq-users                  VLAN 10
#   eth3  hq-srv1                   VLAN 20
#   eth4  hq-nms                    VLAN 99
#   eth5  hq-phone1                 VLAN 30
#   eth6  hq-phone2                 VLAN 30
#   eth7  hq-phone3                 VLAN 30
#   eth8  hq-phone4                 VLAN 30
#   eth9  hq-sw2  (link A)          VLAN 10,20,30,99
#   eth10 hq-sw2  (link B)          VLAN 10,20,30,99
set -eu

BR=br0
TRUNK_VIDS="10 20 30 99"

ip link add "$BR" type bridge
# vlan_filtering must be set before the first port joins the bridge.
ip link set "$BR" type bridge vlan_filtering 1 \
    stp_state 1 priority 4096 forward_delay 400 hello_time 200 max_age 600
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
add_access eth2 10
add_access eth3 20
add_access eth4 99
add_access eth5 30
add_access eth6 30
add_access eth7 30
add_access eth8 30
add_trunk  eth9
add_trunk  eth10

echo "hq-sw1: bridge ready, STP root (priority 4096)"
