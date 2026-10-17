#!/bin/bash
# Boot hook for FRR nodes.
#
# 1. wait until containerlab has finished wiring the veth interfaces (it signals
#    that by touching the marker file from an `exec` hook)
# 2. run the per-node /etc/lab/setup.sh: 802.1Q sub-interfaces, kernel settings,
#    nftables NAT, dnsmasq
# 3. hand over to the stock FRR start-up wrapper
set -u

MARKER="${LAB_READY_MARKER:-/tmp/.lab-interfaces-ready}"
TIMEOUT="${LAB_WAIT_TIMEOUT:-90}"

waited=0
while [ ! -e "$MARKER" ] && [ "$waited" -lt "$TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
done

if [ ! -e "$MARKER" ]; then
    echo "[lab-entrypoint] interfaces marker never appeared, continuing anyway" >&2
fi

# containerlab's management network installs a default route on eth0 which would
# otherwise shadow the routing table this lab builds. The lab never needs it.
ip route del default dev eth0 2>/dev/null || true

if [ -f /etc/lab/setup.sh ]; then
    echo "[lab-entrypoint] running /etc/lab/setup.sh"
    sh /etc/lab/setup.sh || echo "[lab-entrypoint] setup.sh exited with $?" >&2
fi

exec /usr/lib/frr/docker-start
