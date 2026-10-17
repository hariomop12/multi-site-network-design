#!/usr/bin/env bash
# FAULT 4 - layer-2 loop / broadcast storm.
#
# hq-sw1 and hq-sw2 are joined by two parallel links. With STP running, one of
# the two hq-sw2 uplinks sits in the blocking state and the loop is broken.
#
# Disabling STP makes both links forward, so a single broadcast frame is flooded
# back and forth forever: a broadcast storm. This is the fault that takes a
# whole VLAN down in production.
#
# Runbook: docs/runbooks/04-stp-loop.md
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Injecting fault: STP disabled on the HQ switches"
for sw in hq-sw1 hq-sw2; do
    exec_in "$sw" ip link set br0 type bridge stp_state 0
    say "$sw: stp_state 0 (both parallel links now forwarding)"
done

# A port that was blocking does not start forwarding the instant STP is turned
# off, so wait for it. Without this the broadcast frame can be sent while the
# redundant link is still blocked, and no storm forms.
ports_blocked() {
    local sw
    for sw in hq-sw1 hq-sw2; do
        if exec_in "$sw" bridge link show | grep -q "state blocking"; then
            return 0
        fi
    done
    return 1
}

for _ in $(seq 1 30); do
    ports_blocked || break
    sleep 1
done

if ports_blocked; then
    echo "error: a bridge port is still blocking after STP was disabled" >&2
    exit 1
fi

say "both parallel links forwarding: the loop is open"
say "expect: broadcast frames on the looped VLAN multiply without limit"
