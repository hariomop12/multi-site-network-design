#!/bin/sh
# One-shot DHCP request.
#
# Stops the boot-time supervisor, flushes the interface, performs a bounded
# request and then hands the interface back to the supervisor. Returns non-zero
# when no lease was obtained, which is exactly what the DHCP-exhaustion test
# needs to observe.
#
# usage: dhcp-request.sh <iface> [client-tries]
set -u

IFACE="${1:-eth1}"
TRIES="${2:-5}"

pkill udhcpc 2>/dev/null || true
sleep 1

ip addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" down 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true
sleep 1
rm -f /tmp/dhcp_lease

udhcpc -f -n -q -t "$TRIES" -T 2 -i "$IFACE" -s /opt/dhcp-lease.sh > /tmp/dhcp_udhcpc.log 2>&1
rc=$?

# Give the interface back to the long-running supervisor, unless a fault
# scenario has parked it with /tmp/dhcp-hold.
if [ -f /opt/dhcp-supervise.sh ] && [ ! -e "${DHCP_HOLD_FILE:-/tmp/dhcp-hold}" ]; then
    nohup /opt/dhcp-supervise.sh "$IFACE" > /dev/null 2>&1 &
fi

exit $rc
