# Runbook 03 — DHCP scope exhaustion

| | |
| --- | --- |
| **Scenario** | 3 of 4 |
| **Severity** | Medium — users come online but get no address |
| **Blast radius** | One VLAN at one site (HQ VLAN 30, voice) |
| **Expected outcome** | The scope is expanded, the starved client recovers without a reboot |
| **Automated test** | `tests/test_faults.py::test_dhcp_scope_exhaustion_and_scope_expansion` |

## 1. What breaks

The HQ voice scope is `10.10.30.100–10.10.30.120` (21 addresses) for 4 phones.
The fault shrinks it to **3 addresses** (`.100–.102`) and clears the lease
database — the exact effect of a site outgrowing its scope, or of a scope
copy-pasted from a smaller floor.

Four phones, three addresses: the first three register, the fourth never gets an
address.

```
before: dhcp-range=set:hq-voice,10.10.30.100,10.10.30.120
after:  dhcp-range=set:hq-voice,10.10.30.100,10.10.30.102
```

## 2. Reproduce

```bash
make fault NAME=dhcp_exhaustion
# or:  bash faults/inject/dhcp_exhaustion.sh
```

The injector also **parks** the phones' DHCP supervisors. Each lab host runs a
small supervisor that keeps retrying until it has a lease, which would otherwise
race the test and make the result depend on timing. Parking them means the only
DHCP traffic on the wire is the request the test deliberately generates.

## 3. Detection — what an engineer looks at

The server side first: how much of the scope is in use?

```bash
# The lease database - the container equivalent of `show ip dhcp binding`
docker exec clab-corpnet-hq-core cat /var/lib/lab/dnsmasq.leases

# The server's own view of the shortage
docker exec clab-corpnet-hq-core grep "no address available" /var/log/lab-dnsmasq.log
```

```text
DHCPDISCOVER(eth2.30) aa:c1:ab:25:40:13 no address available
available DHCP range: 10.10.30.100 -- 10.10.30.102
```

Then the client side — force one request per phone and record what it gets:

```bash
docker exec clab-corpnet-hq-phone4 sh /opt/dhcp-request.sh eth1 5; echo "rc=$?"
docker exec clab-corpnet-hq-phone4 cat /tmp/dhcp_lease      # empty -> no lease
```

Captured leases while the scope holds 3 addresses:

```text
hq-phone1 = 10.10.30.102
hq-phone2 = 10.10.30.100
hq-phone3 = 10.10.30.101
hq-phone4 = (no lease)          <-- the starved client
```

### Symptoms to look for in a real network

| Symptom | Where |
| --- | --- |
| Pool usage 100%, "no free leases" | Cisco: `show ip dhcp pool`, `show ip dhcp server statistics` |
| Same MAC retrying DISCOVER | server DHCP debug / `log-dhcp` output |
| Client has a link-local address only | client `ipconfig` / `ip addr` |
| Some devices fine, others not | **always a capacity problem, not connectivity** |

The last row is the diagnostic that separates this from a link fault: if
*some* devices in the VLAN are working, the path is fine and the resource is not.

## 4. Root cause

The scope is smaller than the number of devices that need an address from it.
Nothing is broken; the pool was simply sized wrong (or a device count grew).

The reason it is worth a runbook: it is one of the few faults where the network
can be perfectly healthy and users are still offline.

## 5. Remediation

```bash
make fix NAME=dhcp_exhaustion
# or:  bash faults/fix/dhcp_exhaustion.sh
```

Restores the range to `.100–.120`, restarts dnsmasq on a clean lease database,
and un-parks the phones. The starved phone's supervisor retries every 3 seconds
and picks up an address on its own — **no client-side action is needed**, which
is what you want in a live environment.

```text
leases after the scope was expanded:
  hq-phone1 = 10.10.30.114
  hq-phone2 = 10.10.30.118
  hq-phone3 = 10.10.30.117
  hq-phone4 = 10.10.30.116
```

## 6. Verification

```bash
# Everyone has a lease now
docker exec clab-corpnet-hq-core cat /var/lib/lab/dnsmasq.leases

# And the previously starved phone agrees
docker exec clab-corpnet-hq-phone4 ip -br addr show eth1
```

## 7. Design notes

* **Site-local DHCP.** `hq-core` serves its own VLANs, so this failure is
  contained to HQ VLAN 30 and a WAN outage cannot cause it.
* **Why the supervisor exists.** Real DHCP clients retry periodically anyway.
  Modelling that (a bounded request every few seconds) is what lets the fix be
  verified as "the client recovers by itself".
* **`no-ping`.** dnsmasq normally spends ~3 seconds probing a candidate address
  before offering it. That is a useful guard when static devices share a subnet,
  but it made pool exhaustion take ~10s per client and produced timing-dependent
  results. Nothing static lives inside these pools, so the check is disabled and
  the scenario is deterministic (~50s instead of relying on a race).

## 8. What this proves

* Distinguishing a **capacity** fault from a **connectivity** fault.
* Reading a DHCP server's lease table and log as primary evidence.
* Sizing a scope, and verifying recovery end-to-end rather than restarting the
  client and hoping.

## 9. Evidence

Full captured output: `artifacts/fault-03-dhcp-exhaustion.txt`
