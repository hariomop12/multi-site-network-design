"""Helpers for talking to a deployed containerlab lab from pytest.

Everything goes through ``docker exec``, so the tests need nothing more than the
Docker CLI on the machine that owns the lab. The container name for a node is
``clab-<lab-name>-<node-name>``, which is containerlab's default naming scheme.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

LAB_NAME = os.environ.get("LAB_NAME", "corpnet")
PREFIX = f"clab-{LAB_NAME}"
REPO_ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = REPO_ROOT / "artifacts"

# Internal prefixes, used to make assertions readable.
HQ_LAN = "10.10.0.0/16"
BRANCHES = ("10.20.0.0/16", "10.30.0.0/16")


class LabError(RuntimeError):
    """Raised when a container command fails in a way a test should notice."""


@dataclass
class Result:
    ok: bool
    out: str
    code: int

    def __bool__(self) -> bool:  # pragma: no cover - sugar
        return self.ok


def node_container(node: str) -> str:
    return f"{PREFIX}-{node}"


def docker_exec(node: str, command: str, *, timeout: int = 30, check: bool = False) -> Result:
    """Run a shell command inside a lab node."""
    full = ["docker", "exec", node_container(node), "sh", "-c", command]
    proc = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
    out = (proc.stdout or "") + (proc.stderr or "")
    result = Result(ok=proc.returncode == 0, out=out.strip(), code=proc.returncode)
    if check and not result.ok:
        raise LabError(f"{node}: `{command}` failed ({result.code}):\n{result.out}")
    return result


def vtysh(node: str, command: str, *, timeout: int = 30) -> str:
    """Run a FRR command and return its raw output."""
    result = docker_exec(node, f"vtysh -c {shlex.quote(command)}", timeout=timeout)
    return result.out


def ping_loss(src: str, dst: str, *, count: int = 4, timeout: int = 25) -> float:
    """Return packet loss percentage (0-100) for a ping."""
    result = docker_exec(src, f"ping -c {count} -W 2 {shlex.quote(dst)}", timeout=timeout)
    for token in result.out.split():
        if token.endswith("%"):
            try:
                return float(token.rstrip("%"))
            except ValueError:
                continue
    # No reply at all -> full loss.
    return 100.0


def can_ping(src: str, dst: str, *, count: int = 3, timeout: int = 20) -> bool:
    """True when ``src`` gets at least one echo reply from ``dst``."""
    return ping_loss(src, dst, count=count, timeout=timeout) < 100.0


def set_link(node: str, iface: str, up: bool) -> Result:
    return docker_exec(node, f"ip link set {shlex.quote(iface)} {'up' if up else 'down'}")


def ospf_neighbor_count(node: str) -> int:
    """Number of OSPF neighbours in the FULL state."""
    out = vtysh(node, "show ip ospf neighbor json")
    try:
        import json

        data = json.loads(out or "{}")
    except ValueError:
        # Fall back to text parsing if JSON is unavailable.
        return sum(1 for line in out.splitlines() if "Full" in line)
    total = 0
    for _iface, neighbours in data.get("neighbors", {}).items():
        total += sum(1 for n in neighbours if n.get("nbrState", "").startswith("Full"))
    return total


def route_via(node: str, prefix: str) -> str | None:
    """Return the next-hop IP for ``prefix`` in ``node``'s RIB, if present."""
    import json
    import re

    out = vtysh(node, f"show ip route {prefix} json")
    try:
        data = json.loads(out or "{}")
    except ValueError:
        return None
    for _pfx, entries in data.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            for nexthop in entry.get("nexthops", []):
                ip = nexthop.get("ip")
                if ip:
                    return ip
    # Fall back to text form ("via 10.0.2.2").
    match = re.search(r"via (\d+\.\d+\.\d+\.\d+)", out)
    return match.group(1) if match else None


def dhcp_lease(host: str, iface: str = "eth1", *, tries: int = 5, wait: int = 25) -> str | None:
    """Force a fresh DHCP request on ``host`` and return the leased IP or None.

    ``hq-phone*`` / ``hq-users*`` images ship ``/opt/dhcp-request.sh`` which does
    a single one-shot request and records the result in ``/tmp/dhcp_lease``.
    """
    docker_exec(host, "rm -f /tmp/dhcp_lease")
    docker_exec(host, f"ip addr flush dev {iface}; ip link set {iface} down; ip link set {iface} up")
    result = docker_exec(host, f"sh /opt/dhcp-request.sh {iface} {tries}", timeout=wait + 15)
    if not result.ok:
        return None
    out = docker_exec(host, "cat /tmp/dhcp_lease 2>/dev/null").out.strip()
    return out or None


def bridge_port_state(switch: str, iface: str) -> str:
    """Return the STP-ish state of a bridge port: 'forwarding' or 'blocking'."""
    out = docker_exec(switch, f"ip -d link show {shlex.quote(iface)}").out
    lowered = out.lower()
    if "state blocking" in lowered or "disabled" in lowered:
        return "blocking"
    if "state forwarding" in lowered:
        return "forwarding"
    # Linux bridges expose the logical state through `bridge link show`.
    links = docker_exec(switch, "bridge -j link show").out
    if iface in links:
        if '"state":"disabled"' in links.replace(" ", "") or '"state":"blocking"' in links.replace(" ", ""):
            return "blocking"
        if '"state":"forwarding"' in links.replace(" ", ""):
            return "forwarding"
    return "unknown"


def _iface_packets(node: str, iface: str) -> int | None:
    """Total packets in and out of an interface, straight from the kernel."""
    out = docker_exec(
        node,
        f"cat /sys/class/net/{shlex.quote(iface)}/statistics/rx_packets "
        f"/sys/class/net/{shlex.quote(iface)}/statistics/tx_packets",
    ).out
    try:
        rx, tx = (int(value) for value in out.split())
    except ValueError:
        return None
    return rx + tx


def traffic_rate(node: str, iface: str, *, seconds: int = 3) -> float:
    """Packets per second seen on an interface.

    Interface counters are used rather than a packet capture: during a
    broadcast storm a capture has to log every frame before it can report how
    many there were, which at storm rates is slower than the storm itself.
    """
    before = _iface_packets(node, iface)
    if before is None:
        return 0.0
    time.sleep(seconds)
    after = _iface_packets(node, iface)
    if after is None:
        return 0.0
    return max(0, after - before) / seconds


def write_artifact(name: str, content: str) -> Path:
    """Persist a piece of evidence (RCA output) under artifacts/."""
    ARTIFACTS.mkdir(exist_ok=True)
    path = ARTIFACTS / name
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    path.write_text(f"# generated {stamp}\n\n{content}\n")
    return path


def run_script(relative_path: str, *, timeout: int = 120) -> str:
    """Run one of the fault injectors / fixes and return its output."""
    script = REPO_ROOT / relative_path
    proc = subprocess.run(
        ["bash", str(script)],
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=REPO_ROOT,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        raise LabError(f"{relative_path} failed ({proc.returncode}):\n{output}")
    return output.strip()


def count_bridge_states(switch: str) -> dict[str, int]:
    """Count bridge ports per STP state: {'forwarding': n, 'blocking': m, ...}."""
    out = docker_exec(switch, "bridge link show").out
    states: dict[str, int] = {}
    for token in out.split():
        if token in {"forwarding", "blocking", "disabled", "learning", "listening"}:
            states[token] = states.get(token, 0) + 1
    return states


def send_broadcasts(host: str, iface: str, *, count: int = 3) -> None:
    """Put broadcast frames on the wire to feed a layer-2 loop.

    `arping` always works on a client that has no address of its own, which
    makes it a better storm trigger than a broadcast ping.
    """
    if "arping" in docker_exec(host, "command -v arping").out:
        docker_exec(host, f"arping -c {count} -w 2 -I {iface} 10.10.10.250")
    else:
        docker_exec(host, f"ping -b -c {count} -W 1 -I {iface} 10.10.10.255")


def wait_until(predicate, *, timeout: int = 60, interval: float = 2.0) -> bool:
    """Poll ``predicate`` until it is truthy or the timeout expires."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False
