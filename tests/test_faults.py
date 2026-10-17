"""Fault scenarios: inject, detect, remediate, verify.

Each test is written the way an incident is actually worked: prove the fault,
capture the evidence an engineer would look at, apply the fix, prove recovery.
The raw evidence is written to ``artifacts/`` so it can be pasted into a ticket.

These tests need a healthy lab to start from - run ``test_baseline.py`` first
(``make test`` does both, in order).
"""

from __future__ import annotations

import pytest

from lab import (
    can_ping,
    count_bridge_states,
    dhcp_lease,
    docker_exec,
    ospf_neighbor_count,
    route_via,
    run_script,
    send_broadcasts,
    traffic_rate,
    vtysh,
    wait_until,
    write_artifact,
)

pytestmark = pytest.mark.faults


# ---------------------------------------------------------------- fault 1 ---
def test_wan_link_failure_reconverges_via_the_other_branch(lab):
    """HQ <-> Branch-1 link down, Branch-1 traffic must reroute through Branch-2."""
    hq_core, b1_core = lab["hq_core"], lab["b1_core"]

    assert wait_until(lambda: route_via(hq_core, "10.20.10.0/24") == "10.0.0.2", timeout=30), (
        "lab is not in its baseline state"
    )

    evidence = [run_script("faults/inject/wan_link_failure.sh")]
    try:
        # Detection: the adjacency on that link disappears.
        assert wait_until(lambda: ospf_neighbor_count(hq_core) <= 1, timeout=40), (
            "OSPF never noticed the link failure"
        )
        # Reconvergence: Branch-1's LAN is now reached through Branch-2.
        assert wait_until(lambda: route_via(hq_core, "10.20.10.0/24") == "10.0.1.2", timeout=90), (
            "Branch-1 prefix did not reroute through Branch-2"
        )
        evidence.append("hq-core RIB after reconvergence:\n" + vtysh(hq_core, "show ip route 10.20.10.0/24"))
        evidence.append("b1-core neighbours:\n" + vtysh(b1_core, "show ip ospf neighbor"))
        assert can_ping(lab["hq_srv"], "10.20.10.1"), "Branch-1 LAN unreachable after reroute"
        assert can_ping(lab["hq_srv"], "2.2.2.2"), "Branch-1 loopback unreachable after reroute"
    finally:
        evidence.append(run_script("faults/fix/wan_link_failure.sh"))

    write_artifact("fault-01-wan-link-failure.txt", "\n\n".join(evidence))

    assert wait_until(lambda: ospf_neighbor_count(hq_core) == 2, timeout=90), (
        "adjacency did not come back after the link was restored"
    )
    # The adjacency can reach FULL a moment before SPF reinstalls the preferred
    # path, so wait for the RIB rather than assuming it has already moved.
    assert wait_until(lambda: route_via(hq_core, "10.20.10.0/24") == "10.0.0.2", timeout=90), (
        f"primary path was not reinstalled, still via {route_via(hq_core, '10.20.10.0/24')}"
    )


# ---------------------------------------------------------------- fault 2 ---
def test_routing_loop_is_localised_and_removed(lab):
    """Two static routes pointing at each other must be found and cleared."""
    hq_srv, b1_core, b2_core = lab["hq_srv"], lab["b1_core"], lab["b2_core"]

    assert route_via(b1_core, "198.18.0.0/24") is None, "lab is not in its baseline state"

    evidence = [run_script("faults/inject/routing_loop.sh")]
    try:
        assert route_via(b1_core, "198.18.0.0/24") == "10.0.2.2"
        assert route_via(b2_core, "198.18.0.0/24") == "10.0.2.1"

        trace = docker_exec(hq_srv, "traceroute -n -w1 -q1 -m8 198.18.0.1", timeout=60).out
        evidence.append("traceroute to the looped prefix:\n" + trace)

        # traceroute right-aligns the hop number, so strip before testing it.
        hops = [line.strip() for line in trace.splitlines() if line.strip()[:1].isdigit()]
        addresses = [line.split()[1] for line in hops if len(line.split()) > 1]
        assert len(addresses) >= 4, f"expected the path to bounce, got:\n{trace}"
        assert len(set(addresses)) < len(addresses), (
            f"the path never repeated, so there is no loop:\n{trace}"
        )
        assert "198.18.0.1" not in addresses, f"the looped prefix was actually reachable:\n{trace}"

        # A loop on an unused prefix does not disturb real traffic - worth proving.
        assert can_ping(hq_srv, "2.2.2.2"), "the loop leaked into normal traffic"
        assert can_ping(hq_srv, "10.30.10.1"), "the loop leaked into normal traffic"
    finally:
        evidence.append(run_script("faults/fix/routing_loop.sh"))

    write_artifact("fault-02-routing-loop.txt", "\n\n".join(evidence))

    assert route_via(b1_core, "198.18.0.0/24") is None, "the static route on b1-core survived"
    assert route_via(b2_core, "198.18.0.0/24") is None, "the static route on b2-core survived"
    assert can_ping(hq_srv, "10.20.10.1")


# ---------------------------------------------------------------- fault 3 ---
def test_dhcp_scope_exhaustion_and_scope_expansion(lab):
    """A scope smaller than the number of devices starves one of them."""
    phones = lab["phones"]

    evidence = [run_script("faults/inject/dhcp_exhaustion.sh")]
    try:
        leases = {phone: dhcp_lease(phone) for phone in phones}
        evidence.append(
            "leases while the scope holds 3 addresses:\n"
            + "\n".join(f"  {phone} = {ip or '(no lease)'}" for phone, ip in leases.items())
        )
        served = [phone for phone, ip in leases.items() if ip]
        assert len(served) == 3, (
            f"expected exactly 3 phones to be served by a 3-address scope, got {len(served)}: {leases}"
        )
    finally:
        evidence.append(run_script("faults/fix/dhcp_exhaustion.sh"))

    recovered = {phone: dhcp_lease(phone) for phone in phones}
    evidence.append(
        "leases after the scope was expanded:\n"
        + "\n".join(f"  {phone} = {ip or '(no lease)'}" for phone, ip in recovered.items())
    )
    write_artifact("fault-03-dhcp-exhaustion.txt", "\n\n".join(evidence))

    missing = [phone for phone, ip in recovered.items() if not ip]
    assert not missing, f"these phones still have no lease after the fix: {missing}"


# ---------------------------------------------------------------- fault 4 ---
def test_stp_loop_causes_a_broadcast_storm(lab):
    """Removing STP from a bridged loop turns one frame into a storm."""
    sw1, sw2 = lab["hq_sw1"], lab["hq_sw2"]

    assert wait_until(lambda: count_bridge_states(sw2).get("blocking", 0) >= 1, timeout=60), (
        "STP is not blocking in the baseline"
    )

    quiet = traffic_rate(sw1, "eth9", seconds=3)
    threshold = max(50.0, quiet * 10)
    evidence = [f"baseline: {quiet:.0f} pps on {sw1}:eth9, hq-sw2 states {count_bridge_states(sw2)}"]

    try:
        evidence.append(run_script("faults/inject/stp_loop.sh"))
        send_broadcasts(lab["hq_user2"], "eth1", count=3)
        storm = traffic_rate(sw1, "eth9", seconds=3)
        evidence.append(f"faulted: {storm:.0f} pps on {sw1}:eth9 (threshold {threshold:.0f})")
        assert storm > threshold, f"no broadcast storm detected: {storm:.0f} pps vs {quiet:.0f} pps"
    finally:
        evidence.append(run_script("faults/fix/stp_loop.sh"))

    assert wait_until(lambda: count_bridge_states(sw2).get("blocking", 0) >= 1, timeout=90), (
        "STP never re-blocked the redundant link"
    )
    settled = traffic_rate(sw1, "eth9", seconds=3)
    evidence.append(f"recovered: {settled:.0f} pps on {sw1}:eth9")
    write_artifact("fault-04-stp-loop.txt", "\n\n".join(evidence))

    assert settled < threshold, f"the storm did not stop after STP was re-enabled: {settled:.0f} pps"
