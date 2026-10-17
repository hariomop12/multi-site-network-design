#!/usr/bin/env bash
# FAULT 2 - routing loop between two routers.
#
# A decommissioned test prefix (198.18.0.0/24, from the RFC 2544 benchmarking
# range) gets a static route on each branch router, and the two routes point at
# each other. This is the classic "two static routes facing each other" loop:
# packets bounce between b1-core and b2-core until the TTL expires.
#
# Note how normal traffic is untouched - a loop on an unused prefix is invisible
# until somebody tries to reach it. That is what makes it a good interview
# scenario.
#
# Runbook: docs/runbooks/02-routing-loop.md
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Injecting fault: static routing loop for 198.18.0.0/24"
# HQ needs a route for the prefix so traffic can enter the loop at all.
vtysh_in hq-core -c "ip route 198.18.0.0/24 10.0.0.2"
# The loop: b1-core points at b2-core and b2-core points straight back.
vtysh_in b1-core -c "ip route 198.18.0.0/24 10.0.2.2"
vtysh_in b2-core -c "ip route 198.18.0.0/24 10.0.2.1"
say "hq-core -> 10.0.0.2 (b1-core)"
say "b1-core -> 10.0.2.2 (b2-core)"
say "b2-core -> 10.0.2.1 (b1-core)   <-- closes the loop"
say "expect: traceroute to 198.18.0.1 repeats the same two hops until TTL expires"
