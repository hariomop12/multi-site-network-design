#!/bin/sh
# Branch access switch (used by b1-sw1 and b2-sw1).
#
# A branch only needs a single user VLAN, so the trunk carries VLAN 10 only and
# there is no redundant path - STP stays off.
#
#   eth1  trunk -> <site>-core   VLAN 10 (tagged)
#   eth2  <site>-users           VLAN 10
set -eu

BR=br0

ip link add "$BR" type bridge
ip link set "$BR" type bridge vlan_filtering 1 stp_state 0
ip link set "$BR" up

# trunk towards the site router
ip link set eth1 master "$BR"
ip link set eth1 up
bridge vlan del dev eth1 vid 1 2>/dev/null || true
bridge vlan add dev eth1 vid 10

# access port for the user workstation
ip link set eth2 master "$BR"
ip link set eth2 up
bridge vlan del dev eth2 vid 1 2>/dev/null || true
bridge vlan add dev eth2 vid 10 pvid untagged

echo "$(hostname): branch bridge ready"
