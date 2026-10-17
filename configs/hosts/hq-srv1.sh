#!/bin/sh
# hq-srv1 - static server in HQ VLAN 20 (the "server farm").
set -eu

ADDR=10.10.20.10/24
GW=10.10.20.1

ip link set eth1 up
ip addr show dev eth1 | grep -q "${ADDR%/*}" || ip addr add "$ADDR" dev eth1
ip route replace default via "$GW"

echo "hq-srv1: $ADDR via $GW"
