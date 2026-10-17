#!/bin/sh
# DHCP client host (hq-users, hq-users2, hq-phone1..4, b1-users, b2-users).
#
# Hands eth1 over to the lease supervisor, which keeps requesting until a lease
# is available and then renews it. Tests stop this process with
# /opt/dhcp-request.sh when they need a measurable one-shot request.
set -eu

ip link set eth1 up
pkill udhcpc 2>/dev/null || true
nohup /opt/dhcp-supervise.sh eth1 >/dev/null 2>&1 &

echo "$(hostname): DHCP client started"
