#!/bin/sh
# Boot hook for the simulated ISP edge.
set -eu

sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.all.rp_filter=0
sysctl -qw net.ipv4.conf.default.rp_filter=0

for i in 1 2; do
    ip link set "eth$i" up 2>/dev/null || true
done

echo "isp: forwarding enabled"
