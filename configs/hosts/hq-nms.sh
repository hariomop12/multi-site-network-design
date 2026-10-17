#!/bin/sh
# hq-nms - static management workstation in HQ VLAN 99.
#
# Lives on the same VLAN as the DHCP server address, so it is the natural place
# to run reachability checks from.
set -eu

ADDR=10.10.99.50/24
GW=10.10.99.1

ip link set eth1 up
ip addr show dev eth1 | grep -q "${ADDR%/*}" || ip addr add "$ADDR" dev eth1
ip route replace default via "$GW"

echo "hq-nms: $ADDR via $GW"
