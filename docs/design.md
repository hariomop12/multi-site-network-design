# Network Design

> Three-site corporate network: HQ + Branch-1 + Branch-2, simulated with
> **containerlab** and real **FRRouting** daemons. Every router, switch and host
> is a container, so the whole topology is reproducible from a single YAML file.

## 1. Design goals

| Goal | How the lab addresses it |
| --- | --- |
| Branch connectivity over a shared WAN | OSPF area 0 over point-to-point WAN links |
| Address-plan scalability | One `/16` per site, one `/24` per VLAN |
| Fast convergence on WAN failure | Partial-mesh WAN (HQ-B1, HQ-B2, B1-B2) + OSPF |
| Segmentation | 802.1Q VLANs on access switches, router-on-a-stick at each site |
| IP assignment | A `dnsmasq` server at each site, one pool per VLAN |
| Internet egress | NAT overload (PAT) on the HQ edge router |
| Layer-2 loop protection | Linux bridge STP on the HQ access layer |
| Operability | Automated fault injection + `pytest` assertions instead of manual screenshots |

## 2. Topology

```
   INTERNET
     pub-srv 198.51.100.10 ──── isp ────┬── 198.51.100.0/24   (web service)
                                       └── 203.0.113.0/29     hq-core:eth1  [NAT outside]

   HQ SITE  10.10.0.0/16  (OSPF area 1, stub)
     hq-core:eth2 ──(trunk 10/20/30/99)── hq-sw1 ──┬── hq-users       VLAN 10  DHCP
                                                    ├── hq-srv1       VLAN 20  static
                                                    ├── hq-nms        VLAN 99  static
                                                    └── hq-phone1..4  VLAN 30  DHCP
                        hq-sw1 ══(2 parallel links = the layer-2 loop)══ hq-sw2
                                                                     └── hq-users2  VLAN 10

   WAN TRIANGLE  (OSPF area 0: WAN links + loopbacks)
     hq-core:eth3 ── 10.0.0.0/30 ── b1-core:eth1
     hq-core:eth4 ── 10.0.1.0/30 ── b2-core:eth1
     b1-core:eth2 ── 10.0.2.0/30 ── b2-core:eth2

   BRANCH-1  10.20.0.0/16 (area 2, stub)      BRANCH-2  10.30.0.0/16 (area 3, stub)
     b1-core:eth3 ── b1-sw1 ── b1-users         b2-core:eth3 ── b2-sw1 ── b2-users
                               (VLAN 10, DHCP)                     (VLAN 10, DHCP)
```

## 3. Routing design

### OSPF areas

| Area | Contents | Type |
| --- | --- | --- |
| `0.0.0.0` | WAN links (10.0.0.0/22) + router loopbacks | Backbone |
| `1` | HQ VLANs (10.10.0.0/16) | Stub |
| `2` | Branch-1 VLANs (10.20.0.0/16) | Stub |
| `3` | Branch-2 VLANs (10.30.0.0/16) | Stub |

* `hq-core` is the **ABR** for area 1 and the **ASBR** towards the ISP.
* `b1-core` / `b2-core` are ABRs for area 2 and 3 respectively.
* Stub areas keep Type-5 LSAs out of the branches; the branches only need a
  default route, which `hq-core` injects with `default-information originate`.
* Loopbacks are advertised so each device has a stable, always-up router-ID and
  a management address that survives link flaps.

### Why a partial-mesh WAN

HQ-B1, HQ-B2 and B1-B2 links form a triangle. If the HQ-B1 link fails, Branch-1
traffic reconverges through Branch-2. This is what makes the *link-failure*
fault scenario meaningful instead of a dead-end.

## 4. Layer 2 design

* Each access switch is a Linux bridge with `vlan_filtering 1`, emulating an
  802.1Q switch: access ports are untagged in one VLAN, the uplink is a trunk.
* The site router performs **router-on-a-stick** inter-VLAN routing using
  `eth.X` sub-interfaces, one per VLAN.
* `hq-sw1` and `hq-sw2` are joined by **two parallel links**, which forms a real
  layer-2 loop. STP blocks one of them; disabling STP produces a broadcast
  storm. That is the STP fault scenario.

## 5. Services design

### DHCP

Each site router runs its own `dnsmasq`, serving the VLANs it is the default
gateway for:

| Server | Scopes | Why here |
| --- | --- | --- |
| `hq-core` | VLAN 10 `.100–.150`, VLAN 30 `.100–.120` | Default gateway of both HQ scopes |
| `b1-core` | B1 VLAN 10 `.100–.150` | Local to Branch-1 |
| `b2-core` | B2 VLAN 10 `.100–.150` | Local to Branch-2 |

* Because the server is directly attached to every scope it serves, **no DHCP
  relay is needed** — there is no `ip helper-address` equivalent anywhere in the
  design.
* This is the design real branch networks use: a WAN outage must not stop local
  address assignment. It also means the *DHCP-exhaustion* scenario stays local to
  one site.
* VLAN 20 (servers) and VLAN 99 (management) are statically addressed and have
  no pool.
* `no-ping` is set: dnsmasq normally spends ~3s probing a candidate address
  before offering it, and nothing static lives inside these pools.

### NAT

`hq-core` masquerades everything leaving towards the ISP with **nftables**:

```
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat
        oifname "eth1" ip saddr != 10.0.0.0/22 masquerade
    }
}
```

* The upstream FRR build ships **without NAT support** (no `libnftnl`), so FRR's
  own `ip nat inside source ... overload` syntax is unavailable. nftables gives
  the same result with a real, inspectable conntrack table (see
  `conntrack -L` on `hq-core`).
* `ip saddr != 10.0.0.0/22` keeps inter-site transit untranslated, so HQ↔Branch
  routing is never hidden behind the NAT address.

## 6. Fault scenarios

| # | Scenario | Inject | Expected detection | Remediation |
| --- | --- | --- | --- | --- |
| 1 | WAN link failure | `eth3` down on `hq-core` **and** `eth1` down on `b1-core` | OSPF neighbour down, `10.20.10.0/24` re-installed via `b2-core` | Restore both ends, verify reconvergence |
| 2 | Routing loop | Static route pair between `b1-core`/`b2-core` for a test prefix | `traceroute` repeats two hops, TTL exceeded | Remove the static routes |
| 3 | DHCP exhaustion | Shrink the VLAN-30 pool below the number of phones | Only 3 of 4 phones get a lease, dnsmasq logs `no address available` | Expand the pool, re-lease |
| 4 | STP loop / broadcast storm | Disable STP on the bridged loop | Interface packet counters explode on the looped port | Re-enable STP, confirm one port blocking |

Each scenario has a runbook in `docs/runbooks/` and an automated test in
`tests/`.

## 7. Technology mapping (resume ↔ reality)

| Resume keyword | Implementation here |
| --- | --- |
| Cisco Packet Tracer / GNS3 | containerlab (YAML topologies, real Linux netns) |
| OSPF | FRR `ospfd`, multi-area, stub areas, ABR/ASBR |
| VLANs / inter-VLAN routing | Linux bridge `vlan_filtering` + FRR sub-interfaces |
| NAT | nftables masquerade on the edge router (FRR has no NAT) |
| DHCP | A `dnsmasq` server per site, pool per VLAN, no relay |
| STP | Linux bridge STP with a physical loop |
| Fault simulation & RCA | Shell fault injectors + `pytest` assertion suites |
