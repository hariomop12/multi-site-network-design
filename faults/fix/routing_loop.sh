#!/usr/bin/env bash
# FIX for fault 2 - remove the three static routes that create the loop.
set -euo pipefail
cd "$(dirname "$0")/../.."
source faults/lib.sh

require_lab

echo "Remediating: removing the static routes for 198.18.0.0/24"
vtysh_in hq-core -c "no ip route 198.18.0.0/24 10.0.0.2"
vtysh_in b1-core -c "no ip route 198.18.0.0/24 10.0.2.2"
vtysh_in b2-core -c "no ip route 198.18.0.0/24 10.0.2.1"
say "prefix is now unreachable again, which is correct - it does not exist"
