# Runbook 01 — WAN link failure (HQ ↔ Branch-1)

| | |
| --- | --- |
| **Scenario** | 1 of 4 |
| **Severity** | High — a whole branch loses its primary path |
| **Blast radius** | Branch-1 users; Branch-2 is unaffected |
| **Expected outcome** | OSPF reconverges through Branch-2, no packet loss after convergence |
| **Automated test** | `tests/test_faults.py::test_wan_link_failure_reconverges_via_the_other_branch` |

## 1. What breaks

The HQ ↔ Branch-1 WAN link (`hq-core:eth3` ↔ `b1-core:eth1`, `10.0.0.0/30`) goes
down. In production this is a fibre cut, a dead CPE, or an ISP maintenance
window.

The design survives it because the WAN is a **triangle**:

```
   hq-core ──10.0.0.0/30── b1-core     <-- this one fails
      │                       │
      └──10.0.1.0/30── b2-core ──10.0.2.0/30──┘
```

With the direct link gone, Branch-1 traffic has a second path:
`hq-core → b2-core → b1-core`.

## 2. Reproduce

```bash
make fault NAME=wan_link_failure
# or:  bash faults/inject/wan_link_failure.sh
```

Both ends of the link are shut, which is what a real fibre cut looks like from
each router's point of view. (Shutting only one end still triggers OSPF failover,
but the far end keeps its interface up and would not raise its own alarm.)

## 3. Detection — what an engineer looks at

```bash
# 1. Adjacency count drops from 2 to 1 on hq-core
docker exec clab-corpnet-hq-core vtysh -c "show ip ospf neighbor"
docker exec clab-corpnet-hq-core vtysh -c "show ip ospf neighbor json" | jq '.neighbors | keys'

# 2. The interface is down, and FRR logged the adjacency change
docker exec clab-corpnet-hq-core ip -br link show eth3
docker exec clab-corpnet-hq-core vtysh -c "show logging" | grep -i "adjacency"

# 3. The branch prefix is still in the RIB, but the next hop changed
docker exec clab-corpnet-hq-core vtysh -c "show ip route 10.20.10.0/24"
```

Captured immediately after reconvergence — note the next hop is now `10.0.1.2`
(`b2-core`), not `10.0.0.2`:

```text
Routing entry for 10.20.10.0/24
  Known via "ospf", distance 110, metric 120, best
  Last update 00:00:01 ago
  * 10.0.1.2, via eth4, weight 1
```

Branch-1 now sees Branch-2 as its only neighbour:

```text
Neighbor ID     Pri State           Up Time         Dead Time Address         Interface
3.3.3.3           1 Full/-          5m42s              9.844s 10.0.2.2        eth2:10.0.2.1
```

### Symptoms to look for in a real network

| Symptom | Where |
| --- | --- |
| OSPF neighbour leaves `FULL` | `show ip ospf neighbor` |
| `%OSPF-5-ADJCHG ... to DOWN` | router log |
| Prefix still present, different next hop | `show ip route` |
| Branch unreachable, HQ core reachable | ping tests |

The important distinction from a *routing* failure: the prefix **never
disappears**, it only moves. That is what tells you reconvergence worked.

## 4. Root cause

A physical/transport failure on one WAN link. There is no misconfiguration to
fix — the exercise is proving that the redundancy design behaves correctly and
that convergence is fast enough.

## 5. Remediation

```bash
make fix NAME=wan_link_failure
# or:  bash faults/fix/wan_link_failure.sh
```

Brings `hq-core:eth3` and `b1-core:eth1` back up. OSPF re-forms the adjacency
within the configured timers (`hello 3s`, `dead 10s`) and the prefix moves back
to the preferred path.

## 6. Verification

```bash
# Adjacency is FULL again (2 on hq-core)
docker exec clab-corpnet-hq-core vtysh -c "show ip ospf neighbor"

# The primary path is reinstalled, next hop 10.0.0.2
docker exec clab-corpnet-hq-core vtysh -c "show ip route 10.20.10.0/24"

# End to end
docker exec clab-corpnet-hq-srv1 ping -c3 10.20.10.1
docker exec clab-corpnet-hq-srv1 ping -c3 2.2.2.2
```

## 7. Why the timers are what they are

| Timer | Value | Reason |
| --- | --- | --- |
| `hello-interval` | 3s | Faster detection than the 10s default; cheap on a lab-scale link |
| `dead-interval` | 10s (≈4× hello) | Detect a dead link in ~10s instead of 40s |
| `ip ospf cost` (WAN) | 10 | Keeps the direct link preferred over the 2-hop detour |
| `ip ospf cost` (LAN) | 100 | LANs never become transit paths |

`ip ospf network point-to-point` is set on the WAN links. A `/30` is a
point-to-point link by nature; without this, OSPF treats it as broadcast and
wastes a DR/BDR election on a link with exactly two routers.

## 8. What this proves

* Multi-area OSPF with a partial-mesh WAN, not a single hub-and-spoke link.
* Failover verification with timers and costs, not just "it pings again".
* The ability to read a RIB and tell *why* a path changed, from the next hop and
  the OSPF metric.

## 9. Evidence

Full captured output: `artifacts/fault-01-wan-link-failure.txt`
