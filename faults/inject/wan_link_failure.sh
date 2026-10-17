#!/usr/bin/env bash
# FAULT 1 - WAN link failure: the HQ <-> Branch-1 link goes down.
#
# Both ends are shut, which is what you see when a fibre or a CPE fails. The
# expected behaviour is that OSPF drops the adjacency and Branch-1 traffic
# reconverges through Branch-2 (the HQ-B2 and B1-B2 links are still up).
#
# Runbook: docs/runbooks/01-wan-link-failure.md
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Injecting fault: HQ <-> Branch-1 WAN link failure"
exec_in hq-core ip link set eth3 down
exec_in b1-core ip link set eth1 down
say "hq-core:eth3 down"
say "b1-core:eth1 down"
say "expect: OSPF neighbour drops, Branch-1 reachable via Branch-2"
