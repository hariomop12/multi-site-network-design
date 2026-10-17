#!/bin/sh
# Boot hook for every lab node.
#
# containerlab wires the veth interfaces *after* the container is created and
# signals completion by running the `exec` hook `touch /tmp/.lab-interfaces-ready`.
# Without that wait a node can try to configure an interface before it exists.
#
# Once the interfaces are there the per-node /etc/lab/setup.sh runs; that is
# where 802.1Q sub-interfaces, bridges and services are created.
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

exec sleep infinity
