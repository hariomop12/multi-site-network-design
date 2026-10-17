# Runbook 04 — STP loop / broadcast storm

| | |
| --- | --- |
| **Scenario** | 4 of 4 |
| **Severity** | Critical — it takes down a whole VLAN, and then the switches |
| **Blast radius** | Every device in the looped VLAN, then switch CPU |
| **Expected outcome** | One redundant link is returned to blocking and the storm stops |
| **Automated test** | `tests/test_faults.py::test_stp_loop_causes_a_broadcast_storm` |

## 1. What breaks

`hq-sw1` and `hq-sw2` are joined by **two parallel links** (`eth9`/`eth10` ↔
`eth1`/`eth2`). That is a genuine layer-2 loop:

```text
   hq-sw1 ══════ link A ══════╗
      ║                       hq-sw2 ── hq-users2
      ╚═════ link B ══════╝
```

Spanning Tree keeps one of the two links in the **blocking** state, so only one
path is active. With STP disabled, both links forward: a single broadcast frame
is flooded from one switch to the other, back again, and around forever.

`hq-sw1` is the root bridge (priority 4096), so `hq-sw2` blocks the redundant port.

## 2. Reproduce

```bash
make fault NAME=stp_loop
# or:  bash faults/inject/stp_loop.sh
```

The injector disables STP on both switches **and waits until every bridge port is
forwarding** before declaring the fault in place. A port that was blocking does
not start forwarding the instant STP is switched off, so without that wait a
broadcast sent immediately afterwards would find the loop still broken and no
storm would form.

```bash
# Confirm the loop is open
docker exec clab-corpnet-hq-sw1 bridge link show | grep -c "state forwarding"
docker exec clab-corpnet-hq-sw2 bridge link show | grep -c "state forwarding"
```

## 3. Detection — what an engineer looks at

**Traffic volume on the looped port.** Interface counters are sampled over a
window instead of running a packet capture: during a storm, `tcpdump` has to log
every frame before it can report how many there were, which at storm rates is
slower than the storm itself.

```bash
docker exec clab-corpnet-hq-sw1 cat /sys/class/net/eth9/statistics/rx_packets
```

Measured before, during and after:

```text
baseline:    3 pps on hq-sw1:eth9
faulted: 262299 pps on hq-sw1:eth9     <-- ~87,000x
recovered:   2 pps on hq-sw1:eth9
```

**STP state.** Which port is carrying traffic, and is anything blocked?

```bash
docker exec clab-corpnet-hq-sw2 bridge link show
```

```text
before:  eth1 ... state forwarding
         eth2 ... state blocking      <-- loop broken by STP
after:   eth1 ... state forwarding
         eth2 ... state forwarding    <-- loop open, storm
```

### Symptoms to look for in a real network

| Symptom | Where |
| --- | --- |
| Interface counters climbing in one direction forever | `show interfaces`, `/sys/class/net/*/statistics` |
| MAC address flapping between ports | Cisco: `show mac address-table`, syslog `%SW_MATM-4-MACFLAP_NOTIF` |
| Switch CPU pinned, management slow or unreachable | `show processes cpu` |
| Whole VLAN dead but other VLANs fine | user reports |

The gap between "counters are rising" and "CPU is pegged" is the window you have
to act. Step 1 in production is to break the loop physically; then work out why
STP was not protecting it.

## 4. Root cause

Spanning Tree was disabled (`stp_state 0`) on the bridged loop. With STP off,
nothing suppresses the duplicate path, and frames have no TTL — unlike an IP
loop, which at least dies at TTL 0. A layer-2 loop never ends on its own.

Production causes are usually mundane: an access port cabled to another access
port, a misconfigured switch with STP disabled, or a trunk that lost its VLANs.

## 5. Remediation

```bash
make fix NAME=stp_loop
# or:  bash faults/fix/stp_loop.sh
```

Re-enables STP on both switches. `hq-sw2` returns one uplink to blocking and the
storm stops within a few seconds.

## 6. Verification

```bash
# Exactly one port blocking again
docker exec clab-corpnet-hq-sw2 bridge link show

# Counters have gone quiet
docker exec clab-corpnet-hq-sw1 cat /sys/class/net/eth9/statistics/rx_packets

# The VLAN works
docker exec clab-corpnet-hq-users2 ip -br addr show eth1
docker exec clab-corpnet-hq-users2 ping -c3 10.10.10.1
```

## 7. Design notes

| Item | Value | Reason |
| --- | --- | --- |
| `hq-sw1` bridge priority | 4096 | Deterministic root bridge, so the blocked port is predictable |
| `hq-sw2` bridge priority | default 32768 | Non-root, blocks the redundant uplink |
| `forward_delay` | 4s | Faster transitions than the 15s default in a small lab |
| Loop | two real links | A real loop, not a simulated one |

Both switches run `vlan_filtering 1`, so the loops exist **per VLAN**. `hq-sw1`
and `hq-sw2` are configured as symmetric trunks for VLANs 10/20/30/99 — an
asymmetric trunk would leak one VLAN into another.

## 8. What this proves

* Layer-2 loop protection and why STP exists.
* Quantifying a fault instead of describing it: baseline, faulted and recovered
  packet rates on the affected port.
* Knowing the failure mode that has no natural stopping point (no TTL), which is
  why a broadcast storm escalates faster than any routing problem.

## 9. Evidence

Full captured output: `artifacts/fault-04-stp-loop.txt`
