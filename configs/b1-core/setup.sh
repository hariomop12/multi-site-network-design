#!/bin/sh
# Boot hook for b1-core: sub-interface for the branch LAN + DHCP relay.
set -eu

sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.all.rp_filter=0
sysctl -qw net.ipv4.conf.default.rp_filter=0

for i in 1 2 3; do
    ip link set "eth$i" up 2>/dev/null || true
done

if ! ip link show eth3.10 >/dev/null 2>&1; then
    ip link add link eth3 name eth3.10 type vlan id 10
fi
ip link set eth3.10 up

mkdir -p /var/lib/lab
dnsmasq --conf-file=/etc/lab/dnsmasq.conf

echo "b1-core: sub-interface up, DHCP relay started"
