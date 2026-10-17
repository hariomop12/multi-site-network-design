#!/usr/bin/env bash
# FAULT 3 - DHCP scope exhaustion.
#
# The voice scope on hq-core is 10.10.30.100 - 10.10.30.120, which is plenty for
# the four lab phones. The fault shrinks it to three addresses and clears the
# lease database, exactly the effect of a site outgrowing its scope (or of a
# copy-pasted scope from a smaller floor).
#
# Result: three phones get an address, the fourth never does.
#
# Runbook: docs/runbooks/03-dhcp-exhaustion.md
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Injecting fault: voice DHCP scope shrunk below the number of phones"

# Park the phones first so that the pool fills up in a predictable order: the
# supervisor retry loop would otherwise race the test's own requests.
dhcp_hold on

exec_in hq-core sh -c '
    sed "s/10.10.30.100,10.10.30.120/10.10.30.100,10.10.30.102/" \
        /etc/lab/dnsmasq.conf > /tmp/dnsmasq.fault.conf
'
restart_dnsmasq hq-core /tmp/dnsmasq.fault.conf

say "scope reduced to 10.10.30.100 - 10.10.30.102 (3 leases) for: $PHONES"
say "phones parked: the third request fills the scope, the fourth is starved"
