# Runbook 02 — Routing loop between two routers

| | |
| --- | --- |
| **Scenario** | 2 of 4 |
| **Severity** | Low until someone uses the prefix — then High for that traffic |
| **Blast radius** | Only the looped prefix (`198.18.0.0/24`); normal traffic is untouched |
| **Expected outcome** | The loop is localised, removed, and normal traffic proven unaffected |
| **Automated test** | `tests/test_faults.py::test_routing_loop_is_localised_and_removed` |

## 1. What breaks

A decommissioned test prefix gets a static route on each branch router, and the
two routes point at each other:

```text
hq-core  -> 198.18.0.0/24 via 10.0.0.2 (b1-core)
b1-core  -> 198.18.0.0/24 via 10.0.2.2 (b2-core)
b2-core  -> 198.18.0.0/24 via 10.0.2.1 (b1-core)   <-- closes the loop
```

A packet for the prefix enters at HQ, is handed to Branch-1, then to Branch-2,
then back to Branch-1, and so on until the TTL hits zero.

`198.18.0.0/24` is from the RFC 2544 benchmarking range, so it is safe to use as
a "customer prefix that should not exist" — nothing else in the lab depends on it.

## 2. Reproduce

```bash
make fault NAME=routing_loop
# or:  bash faults/inject/routing_loop.sh
```

```bash
docker exec clab-corpnet-b1-core vtysh -c "show ip route 198.18.0.0/24"
docker exec clab-corpnet-b2-core vtysh -c "show ip route 198.18.0.0/24"
```

## 3. Detection — what an engineer looks at

`traceroute` is the tool that makes the loop visible. The same two hops repeat
until the probe gives up:

```bash
docker exec clab-corpnet-hq-srv1 traceroute -n -w1 -q1 -m8 198.18.0.1
```

```text
traceroute to 198.18.0.1 (198.18.0.1), 8 hops max, 60 byte packets
 1  10.10.20.1  0.082 ms      <- hq-core, VLAN 20 gateway
 2  10.0.0.2    0.069 ms      <- b1-core
 3  10.0.1.2    0.053 ms      <- b2-core
 4  10.0.0.2    0.048 ms      <- b1-core again
 5  10.0.1.2    0.050 ms
 6  10.0.0.2    0.058 ms
 7  10.0.1.2    0.060 ms
 8  10.0.0.2    0.063 ms
```

The signal is a **repeated hop address** before the destination is reached. A
healthy path never repeats a router.

### Why this fault is hidden

Everything else about the network looks fine — that is the point of the
scenario:

* OSPF adjacencies are all `FULL`.
* `show ip route` shows routes for every real prefix.
* End hosts ping each other normally, because the looped prefix is not
  transit for anything.

This is exactly the class of bug that survives a change window and is found
weeks later by one user. It has to be caught with a **synthetic reachability
probe** for prefixes that should be *unreachable*, not by watching normal
traffic. In this lab that check is `route_via(...) is None` in the baseline.

## 4. Root cause

Two static routes that each point at the other router, plus the HQ route that
feeds the loop. Static routes have no loop detection of their own: hop count is
never incremented, so nothing in the routers notices.

## 5. Remediation

```bash
make fix NAME=routing_loop
# or:  bash faults/fix/routing_loop.sh
```

Removes all three static routes. The prefix becomes unreachable again, which is
the correct state for a prefix that does not exist.

Removing only one of the two branch routes also breaks the loop — but leaving a
half-configured static route behind is how the next incident starts, so the fix
removes all of them.

## 6. Verification

```bash
# Both branch routers must no longer have the prefix at all
docker exec clab-corpnet-b1-core vtysh -c "show ip route 198.18.0.0/24"
docker exec clab-corpnet-b2-core vtysh -c "show ip route 198.18.0.0/24"

# Normal traffic was never affected, prove it still is not
docker exec clab-corpnet-hq-srv1 ping -c3 2.2.2.2
docker exec clab-corpnet-hq-srv1 ping -c3 10.30.10.1
```

## 7. What this proves

* Reading a **traceroute** as evidence: repeated hops, TTL expiry, and the
  difference between "unreachable" and "looping".
* The judgement to say a fault is **localised** and does not justify touching
  anything else — a real RCA skill, and one that avoids making an outage worse.
* Testing that prefixes which must *not* be reachable stay unreachable.

## 8. Evidence

Full captured output: `artifacts/fault-02-routing-loop.txt`
