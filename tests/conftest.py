"""Shared pytest fixtures.

The suite talks to an already-deployed lab. Deploy it with ``make deploy`` (or
let CI do it) before running pytest; the session fixture fails fast with a clear
message if the containers are missing.
"""

from __future__ import annotations

import subprocess

import pytest

from lab import LAB_NAME, PREFIX, docker_exec


def _running_containers() -> set[str]:
    proc = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"],
        capture_output=True,
        text=True,
    )
    return set(proc.stdout.split())


@pytest.fixture(scope="session", autouse=True)
def lab_up() -> None:
    names = _running_containers()
    if not any(n.startswith(PREFIX) for n in names):
        pytest.exit(
            f"no containers matching '{PREFIX}-*' are running.\n"
            f"Deploy the lab first:  make deploy   (lab name: {LAB_NAME})",
            returncode=1,
        )


@pytest.fixture(scope="session")
def lab() -> dict:
    """A tiny handle object with the addresses tests care about."""
    return {
        "hq_user": "hq-users",
        "hq_user2": "hq-users2",
        "hq_srv": "hq-srv1",
        "hq_nms": "hq-nms",
        "phones": ["hq-phone1", "hq-phone2", "hq-phone3", "hq-phone4"],
        "b1_user": "b1-users",
        "b2_user": "b2-users",
        "pub_srv": "pub-srv",
        "hq_core": "hq-core",
        "b1_core": "b1-core",
        "b2_core": "b2-core",
        "hq_sw1": "hq-sw1",
        "hq_sw2": "hq-sw2",
    }


@pytest.fixture(scope="session")
def routers(lab) -> dict:
    """Router name -> its loopback address."""
    return {
        lab["hq_core"]: "1.1.1.1",
        lab["b1_core"]: "2.2.2.2",
        lab["b2_core"]: "3.3.3.3",
    }


def pytest_report_header(config) -> str:
    return f"containerlab prefix: {PREFIX}-*  (LAB_NAME={LAB_NAME})"
