#!/usr/bin/env bash
# Human-readable health check for the deployed lab.
#
# This is the manual companion to the pytest suite: run it after `make deploy`
# to see, at a glance, whether routing, VLANs, DHCP, NAT and STP are healthy.
#
# Usage: scripts/baseline.sh
set -uo pipefail

LAB="${LAB_NAME:-corpnet}"
PREFIX="clab-${LAB}"

ROUTERS=(hq-core b1-core b2-core)
DHCP_HOSTS=(hq-users hq-users2 b1-users b2-users hq-phone1 hq-phone2 hq-phone3 hq-phone4)

pass=0
fail=0

c() { docker exec "${PREFIX}-$1" sh -c "$2" 2>&1; }

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
head() { printf '\n\033[1m%s\033[0m\n' "$1"; }

check() { # <description> <expected-substring> <actual-output>
    if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1 (got: ${3:0:120})"; fi
}

head "Routing - OSPF adjacencies (expect 2 FULL per router)"
for r in "${ROUTERS[@]}"; do
    n=$(c "$r" "vtysh -c 'show ip ospf neighbor'" | grep -c "Full")
    if [[ "$n" == "2" ]]; then ok "$r: 2 neighbours FULL"; else bad "$r: $n neighbours FULL (expected 2)"; fi
done

head "Routing - prefix reachability from hq-srv1"
for target in 1.1.1.1 2.2.2.2 3.3.3.3 10.20.10.1 10.30.10.1; do
    out=$(c hq-srv1 "ping -c2 -W2 -q $target")
    check "hq-srv1 -> $target" "0% packet loss" "$out"
done

head "Switching - inter-VLAN routing at HQ"
check "hq-nms (VLAN 99) -> hq-srv1 (VLAN 20)" "0% packet loss" "$(c hq-nms 'ping -c2 -W2 -q 10.10.20.10')"
check "hq-srv1 (VLAN 20) -> hq-nms (VLAN 99)" "0% packet loss" "$(c hq-srv1 'ping -c2 -W2 -q 10.10.99.50')"

head "Switching - STP on the parallel HQ links"
sw2_blocking=$(c hq-sw2 "bridge link show" | grep -c "state blocking")
sw1_forwarding=$(c hq-sw1 "bridge link show" | grep -c "state forwarding")
if [[ "$sw2_blocking" -ge 1 ]]; then ok "hq-sw2: $sw2_blocking port(s) blocking (loop broken)"; else bad "hq-sw2: no blocking port, the loop is open"; fi
if [[ "$sw1_forwarding" -ge 1 ]]; then ok "hq-sw1: $sw1_forwarding port(s) forwarding"; else bad "hq-sw1: nothing forwarding"; fi

head "Addressing - DHCP leases"
for h in "${DHCP_HOSTS[@]}"; do
    lease=$(c "$h" "cat /tmp/dhcp_lease 2>/dev/null")
    if [[ -n "$lease" ]]; then ok "$h: $lease"; else bad "$h: no lease"; fi
done

head "Services - per-site DHCP servers"
for r in hq-core b1-core b2-core; do
    check "$r runs a DHCP server" "dnsmasq --conf-file" "$(c "$r" 'ps -o args= | grep dnsmasq | head -1')"
done
for r in hq-core b1-core b2-core; do
    check "$r holds a lease database" "1" "$(c "$r" 'test -s /var/lib/lab/dnsmasq.leases && echo 1 || echo 0')"
done

head "Services - NAT overload on hq-core"
for host in hq-srv1 b1-users b2-users; do
    code=$(c "$host" "curl -s -m 8 -o /dev/null -w '%{http_code}' http://198.51.100.10/")
    check "$host -> http://198.51.100.10" "200" "$code"
done
translated=$(c hq-core "conntrack -L 2>/dev/null" | grep -c "203.0.113.2")
if [[ "$translated" -ge 1 ]]; then ok "hq-core: $translated translated flow(s) visible in conntrack"; else bad "hq-core: no translated flows"; fi

printf '\n\033[1mSummary\033[0m  %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
