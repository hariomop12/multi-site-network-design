# IP Address Plan

Single source of truth for every address in the lab. Configs and tests must
match this document.

## 1. Site summary

| Site | Aggregate | OSPF area | Router ID | Inter-VLAN device |
| --- | --- | --- | --- | --- |
| HQ | 10.10.0.0/16 | 1 (stub) | 1.1.1.1 | `hq-core` |
| Branch-1 | 10.20.0.0/16 | 2 (stub) | 2.2.2.2 | `b1-core` |
| Branch-2 | 10.30.0.0/16 | 3 (stub) | 3.3.3.3 | `b2-core` |
| WAN transit | 10.0.0.0/22 | 0 | — | — |
| Internet edge | 203.0.113.0/29 | — | — | — |

## 2. VLANs

### HQ (gateway = `10.10.<vlan>.1` on `hq-core`)

| VLAN | Name | Subnet | Gateway | Notes |
| --- | --- | --- | --- | --- |
| 10 | USERS | 10.10.10.0/24 | 10.10.10.1 | DHCP pool `.100–.150` |
| 20 | SERVERS | 10.10.20.0/24 | 10.10.20.1 | Static addressing |
| 30 | VOICE | 10.10.30.0/24 | 10.10.30.1 | DHCP pool `.100–.120`; 4 phones |
| 99 | MGMT | 10.10.99.0/24 | 10.10.99.1 | Static addressing |

### Branch-1 (gateway on `b1-core`)

| VLAN | Name | Subnet | Gateway |
| --- | --- | --- | --- |
| 10 | USERS | 10.20.10.0/24 | 10.20.10.1 |

### Branch-2 (gateway on `b2-core`)

| VLAN | Name | Subnet | Gateway |
| --- | --- | --- | --- |
| 10 | USERS | 10.30.10.0/24 | 10.30.10.1 |

## 3. WAN links (OSPF area 0)

| Link | Subnet | Endpoints |
| --- | --- | --- |
| hq-core \| isp | 203.0.113.0/29 | isp `.1`, hq-core `.2` |
| isp \| pub-srv | 198.51.100.0/24 | isp `.1`, pub-srv `.10` |
| hq-core \| b1-core | 10.0.0.0/30 | hq-core `.1`, b1-core `.2` |
| hq-core \| b2-core | 10.0.1.0/30 | hq-core `.1`, b2-core `.2` |
| b1-core \| b2-core | 10.0.2.0/30 | b1-core `.1`, b2-core `.2` |

## 4. Loopbacks (router-IDs)

| Device | Loopback |
| --- | --- |
| hq-core | 1.1.1.1/32 |
| b1-core | 2.2.2.2/32 |
| b2-core | 3.3.3.3/32 |

## 5. End hosts

| Host | Site VLAN | Address | Method | Container IP |
| --- | --- | --- | --- | --- |
| hq-users | HQ VLAN 10 | 10.10.10.100+ | DHCP | dynamic |
| hq-users2 | HQ VLAN 10 | 10.10.10.100+ | DHCP | dynamic |
| hq-srv1 | HQ VLAN 20 | 10.10.20.10/24 | static | — |
| hq-nms | HQ VLAN 99 | 10.10.99.50/24 | static | — |
| hq-phone1..4 | HQ VLAN 30 | 10.10.30.100+ | DHCP | dynamic |
| b1-users | B1 VLAN 10 | 10.20.10.100+ | DHCP | dynamic |
| b2-users | B2 VLAN 10 | 10.30.10.100+ | DHCP | dynamic |
| pub-srv | — | 198.51.100.10/24 | static | — |

> **Fault scenario, not a config error:** the VLAN-30 pool holds 21 addresses
> (`.100–.120`) for 4 phones in the baseline. The *DHCP-exhaustion* scenario
> deliberately shrinks it to 3 addresses (`.100–.102`) so the fourth phone is
> starved. Nothing in the baseline configuration is undersized.

## 6. Services

| Service | Where | Address |
| --- | --- | --- |
| DHCP server — HQ VLAN 10 + VLAN 30 | `hq-core` | 10.10.10.1 / 10.10.30.1 |
| DHCP server — B1 VLAN 10 | `b1-core` | 10.20.10.1 |
| DHCP server — B2 VLAN 10 | `b2-core` | 10.30.10.1 |
| NAT outside address | `hq-core` eth1 | 203.0.113.2 |
| Default route | `hq-core` | static → 203.0.113.1 |
| Public web server | `pub-srv` | http://198.51.100.10 |

> DHCP is site-local: each server is directly attached to the scopes it serves,
> so there is no relay / `ip helper-address` configuration anywhere.

## 7. Interface map

Containerlab assigns `eth1..N` in the order links are listed in
`topology.clab.yml`.

| Node | eth1 | eth2 | eth3 | eth4 | eth5 |
| --- | --- | --- | --- | --- | --- |
| isp | → hq-core (203.0.113.1/29) | → pub-srv (198.51.100.1/24) | | | |
| pub-srv | → isp (198.51.100.10/24) | | | | |
| hq-core | → isp (203.0.113.2/29) | → hq-sw1 trunk | → b1-core (10.0.0.1/30) | → b2-core (10.0.1.1/30) | — |
| hq-sw1 | → hq-core trunk | → hq-users (access 10) | → hq-srv1 (access 20) | → hq-nms (access 99) | → hq-phone1 (access 30) |
| hq-sw1 | eth6 → hq-phone2 | eth7 → hq-phone3 | eth8 → hq-phone4 | eth9 → hq-sw2 (link A) | eth10 → hq-sw2 (link B) |
| hq-sw2 | → hq-sw1 (link A) | → hq-sw1 (link B) | → hq-users2 (access 10) | | |
| b1-core | → hq-core (10.0.0.2/30) | → b2-core (10.0.2.1/30) | → b1-sw1 trunk | | |
| b1-sw1 | → b1-core trunk | → b1-users (access 10) | | | |
| b2-core | → hq-core (10.0.1.2/30) | → b2-sw1 trunk | → b1-core (10.0.2.2/30) | | |
| b2-sw1 | → b2-core trunk | → b2-users (access 10) | | | |

**Trunk VLANs:** `hq-core↔hq-sw1` carries 10, 20, 30, 99.
`hq-sw1↔hq-sw2` carries 10, 20, 30, 99 as well (it must be a symmetric trunk).
Branch trunks carry VLAN 10 only.
