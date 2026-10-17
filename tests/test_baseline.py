"""Baseline health checks: the network as it should look when nothing is broken.

These are the assertions a NOC would run after a change window. If a baseline
test fails, the lab itself is misconfigured - not a fault scenario.
"""

from __future__ import annotations

import pytest

from lab import (
    can_ping,
    dhcp_lease,
    docker_exec,
    ospf_neighbor_count,
    ping_loss,
    route_via,
    vtysh,
    write_artifact,
)

pytestmark = pytest.mark.baseline

# ---------------------------------------------------------------- OSPF layer


def test_ospf_adjacencies_are_full(lab):
    """Every WAN link must form an OSPF adjacency (6 links -> 2 per router)."""
    expected = {lab["hq_core"]: 2, lab["b1_core"]: 2, lab["b2_core"]: 2}
    actual = {node: ospf_neighbor_count(node) for node in expected}
    details = {
        node: vtysh(node, "show ip ospf neighbor")
        for node in expected
    }
    write_artifact("baseline-ospf-neighbors.txt", "\n\n".join(f"### {k}\n{v}" for k, v in details.items()))
    assert actual == expected, f"OSPF adjacency problem: {actual} != {expected}\n{details}"


def test_loopbacks_are_reachable_from_hq(lab):
    """All router loopbacks (router-IDs) must be reachable across the WAN."""
    assert can_ping(lab["hq_srv"], "1.1.1.1"), "cannot reach HQ loopback"
    assert can_ping(lab["hq_srv"], "2.2.2.2"), "cannot reach Branch-1 loopback"
    assert can_ping(lab["hq_srv"], "3.3.3.3"), "cannot reach Branch-2 loopback"


# ------------------------------------------------------------ routing tables


def test_branches_learn_a_default_route_from_ospf(lab):
    """Stub areas must receive the default route injected by hq-core."""
    for node in (lab["b1_core"], lab["b2_core"]):
        table = vtysh(node, "show ip route 0.0.0.0/0")
        assert "0.0.0.0/0" in table and "ospf" in table.lower(), (
            f"{node} has no OSPF default route:\n{table}"
        )


def test_hq_installs_a_static_default_towards_the_isp(lab):
    table = vtysh(lab["hq_core"], "show ip route 0.0.0.0/0")
    assert "203.0.113.1" in table, f"hq-core default route not towards ISP:\n{table}"


def test_hq_core_sees_branch_lans_as_ospf_routes(lab):
    for prefix, area_expectation in (("10.20.10.0/24", "branch-1"), ("10.30.10.0/24", "branch-2")):
        route = vtysh(lab["hq_core"], f"show ip route {prefix}")
        assert prefix in route and "ospf" in route.lower(), (
            f"hq-core missing {area_expectation} LAN {prefix}:\n{route}"
        )


# ------------------------------------------------------- VLAN / L3 switching


def test_inter_vlan_routing_at_hq(lab):
    """Management VLAN must reach the server VLAN through hq-core."""
    assert can_ping(lab["hq_nms"], "10.10.20.10"), "mgmt -> server VLAN blocked"
    assert can_ping(lab["hq_srv"], "10.10.99.50"), "server -> mgmt VLAN blocked"


def test_cross_site_reachability(lab):
    """HQ server VLAN must reach both branch user gateways, with no loss."""
    for target in ("10.20.10.1", "10.30.10.1"):
        loss = ping_loss(lab["hq_srv"], target, count=5)
        assert loss == 0.0, f"HQ -> {target} loss {loss}%"


# ------------------------------------------------------------- DHCP service


def test_dhcp_serves_hq_and_branch_users(lab):
    """Every user host gets a lease from its own site's router."""
    leases = {}
    for host, expected in (
        (lab["hq_user"], "10.10.10."),
        (lab["hq_user2"], "10.10.10."),
        (lab["b1_user"], "10.20.10."),
        (lab["b2_user"], "10.30.10."),
    ):
        leases[host] = dhcp_lease(host)
        assert leases[host] and leases[host].startswith(expected), (
            f"{host} did not get a lease in {expected}0/24: {leases[host]!r}"
        )
    write_artifact("baseline-dhcp-leases.txt", "\n".join(f"{k} = {v}" for k, v in leases.items()))


def test_each_site_runs_its_own_dhcp_server(lab):
    """DHCP is site-local: every site router serves its own users."""
    for node in (lab["hq_core"], lab["b1_core"], lab["b2_core"]):
        args = docker_exec(node, "ps -o args= | grep '[d]nsmasq' | head -1").out
        in_use = docker_exec(node, "test -s /var/lib/lab/dnsmasq.leases && echo yes").out
        assert "--conf-file" in args, f"{node} is not running a DHCP server:\n{args}"
        assert in_use == "yes", f"{node} has an empty lease database"


# ------------------------------------------------------------------ NAT


def test_nat_gives_hq_and_branch_hosts_internet_access(lab):
    """All internal hosts egress through the single NAT address on hq-core."""
    for host, desc in ((lab["hq_srv"], "HQ"), (lab["b1_user"], "Branch-1"), (lab["b2_user"], "Branch-2")):
        out = docker_exec(host, "curl -s -m 8 -o /dev/null -w '%{http_code}' http://198.51.100.10/", timeout=20)
        assert out.out.strip().endswith("200"), f"{desc} host cannot reach the internet: {out.out!r}"


def test_nat_translations_exist_on_the_edge(lab):
    """NAT overload is nftables masquerade, so the evidence is the conntrack table."""
    # Generate one flow from an internal host so the test stands on its own.
    docker_exec(lab["hq_srv"], "curl -s -m 8 -o /dev/null http://198.51.100.10/", timeout=20)
    out = docker_exec(lab["hq_core"], "conntrack -L 2>/dev/null").out
    write_artifact("baseline-nat-translations.txt", out)
    assert "203.0.113.2" in out, f"no NAT overload entries on hq-core:\n{out}"


# ------------------------------------------------------------------- STP


def test_stp_blocks_one_of_the_parallel_links(lab):
    """The two hq-sw1 <-> hq-sw2 links form a loop; STP must break it."""
    for switch, iface in ((lab["hq_sw1"], "eth9"), (lab["hq_sw1"], "eth10")):
        state = docker_exec(switch, f"cat /sys/class/net/{iface}/operstate").out
        assert state == "up", f"{switch}:{iface} is not up ({state})"

    states = "\n".join(
        f"### {sw}\n{docker_exec(sw, 'bridge link show').out}"
        for sw in (lab["hq_sw1"], lab["hq_sw2"])
    )
    write_artifact("baseline-stp-ports.txt", states)

    blocking = states.count("state blocking")
    forwarding = states.count("state forwarding")
    assert forwarding >= 1, "no forwarding bridge ports, the switches are broken"
    assert blocking >= 1, "STP is not blocking a redundant port, the loop is open"
