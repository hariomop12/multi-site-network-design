#!/usr/bin/env bash
# FIX for fault 1 - restore the HQ <-> Branch-1 WAN link.
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Remediating: restoring the HQ <-> Branch-1 WAN link"
exec_in hq-core ip link set eth3 up
exec_in b1-core ip link set eth1 up
say "both ends up; OSPF should re-form within the hello/dead timers (3s/10s)"
say "expect: hq-core installs the Branch-1 route via 10.0.0.2 again"
