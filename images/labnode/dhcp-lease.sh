#!/bin/sh
# udhcpc event script.
#
# busybox calls this with $1 = deconfig|bound|renew|nak|leasefail and exports the
# lease details as environment variables. We record the address so the pytest
# suite can assert on it, which is the container equivalent of
# `show ip dhcp binding` on a Cisco device.
set -u

case "$1" in
    deconfig)
        ip addr flush dev "$interface"
        rm -f /tmp/dhcp_lease
        ;;
    bound|renew)
        rm -f /tmp/dhcp_lease
        ip addr add "$ip/${mask:-24}" dev "$interface" 2>/dev/null || true
        if [ -n "${router:-}" ]; then
            ip route del default 2>/dev/null || true
            ip route add default via "$router" dev "$interface" 2>/dev/null || true
        fi
        echo "$ip" > /tmp/dhcp_lease
        echo "lease=$ip/$( [ -n "${mask:-}" ] && echo "$mask" || echo 24 ) router=${router:-none} server=${serverid:-none}" >> /tmp/dhcp_history
        ;;
    nak|leasefail)
        rm -f /tmp/dhcp_lease
        ;;
esac
