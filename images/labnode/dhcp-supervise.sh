#!/bin/sh
# Keep an address on the interface for the lifetime of the lab.
#
# Started by /etc/lab/setup.sh on DHCP hosts. A bounded request is repeated:
# quickly while there is no lease (so a client recovers as soon as the pool has
# room) and slowly once a lease exists.
#
# Tests stop this process with /opt/dhcp-request.sh when they need a measurable
# single request. The DHCP fault scenarios additionally create /tmp/dhcp-hold,
# which parks the supervisor so that the only DHCP traffic on the wire is the
# one the test deliberately generates - otherwise the retry loop races the test
# and the outcome is not reproducible.
set -u

IFACE="${1:-eth1}"
HOLD_FILE="${DHCP_HOLD_FILE:-/tmp/dhcp-hold}"
START_DELAY="${DHCP_START_DELAY:-8}"
RENEW_INTERVAL="${DHCP_RENEW_INTERVAL:-30}"
RETRY_INTERVAL="${DHCP_RETRY_INTERVAL:-3}"

sleep "$START_DELAY"

while :; do
    # Parked by a fault scenario: hold the interface in whatever state the
    # scenario left it in and re-check every couple of seconds.
    if [ -e "$HOLD_FILE" ]; then
        sleep 2
        continue
    fi

    ip link set "$IFACE" up 2>/dev/null || true

    if udhcpc -f -n -q -t 4 -T 2 -i "$IFACE" -s /opt/dhcp-lease.sh >/dev/null 2>&1; then
        sleep "$RENEW_INTERVAL"
    else
        sleep "$RETRY_INTERVAL"
    fi
done
