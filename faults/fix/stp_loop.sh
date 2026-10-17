#!/usr/bin/env bash
# FIX for fault 4 - turn STP back on so one of the parallel links is blocked.
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Remediating: re-enabling STP on the HQ switches"
for sw in hq-sw1 hq-sw2; do
    exec_in "$sw" ip link set br0 type bridge stp_state 1
    say "$sw: stp_state 1"
done
say "allow a few seconds for the topology to converge and the storm to stop"
