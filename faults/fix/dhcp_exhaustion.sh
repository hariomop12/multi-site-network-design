#!/usr/bin/env bash
# FIX for fault 3 - restore the full voice scope and clear the exhausted state.
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Remediating: restoring the voice scope to 10.10.30.100 - 10.10.30.120"
restart_dnsmasq hq-core /etc/lab/dnsmasq.conf

# Hand the phones back to their supervisors, which retry every few seconds
# until the starved one is served.
dhcp_hold off

say "21 addresses available again; the starved phone should pick one up"
