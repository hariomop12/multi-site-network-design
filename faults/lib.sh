#!/usr/bin/env bash
# Shared helpers for the fault injectors and their fixes.
#
# Every script works on the lab prefix (clab-<LAB_NAME>-<node>) so the same
# scripts keep working if the lab is deployed under a different name.

LAB_NAME="${LAB_NAME:-corpnet}"
PREFIX="clab-${LAB_NAME}"

# exec_in <node> <command...>
exec_in() {
    local node="$1"
    shift
    docker exec "${PREFIX}-${node}" "$@"
}

# vtysh_in <node> <config-command>
vtysh_in() {
    local node="$1"
    shift
    docker exec "${PREFIX}-${node}" vtysh -c "conf t" "$@" -c end
}

require_lab() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${PREFIX}-"; then
        echo "error: no running containers matching '${PREFIX}-*'. Deploy the lab first." >&2
        exit 1
    fi
}

# The HQ voice hosts used by the DHCP scenarios. Their supervisors can be
# parked so that a test's request is the only DHCP traffic on the wire.
PHONES="${PHONES:-hq-phone1 hq-phone2 hq-phone3 hq-phone4}"

# restart_dnsmasq <node> <conf-file>
# Restart the site DHCP server on a clean lease database.
#
# The wait is the important part: dnsmasq keeps UDP/67 bound for a moment after
# it is signalled, so a plain "pkill; sleep 1; dnsmasq" intermittently fails
# with "failed to bind DHCP server socket: Address in use".
restart_dnsmasq() {
    local node="$1" conf="$2"
    exec_in "$node" sh -c '
        conf="$1"
        pkill dnsmasq 2>/dev/null || true
        for _ in $(seq 1 30); do
            pgrep dnsmasq >/dev/null 2>&1 || break
            sleep 1
        done
        rm -f /var/lib/lab/dnsmasq.leases
        for _ in $(seq 1 10); do
            if dnsmasq --conf-file="$conf"; then
                exit 0
            fi
            sleep 1
        done
        echo "error: dnsmasq did not start with ${conf}" >&2
        exit 1
    ' sh "$conf"
}

# dhcp_hold <state: on|off> [node...]
# on : park the DHCP supervisor and drop any address the host is holding
# off: let the supervisor run again
dhcp_hold() {
    local state="$1"
    shift
    local nodes=("$@")
    if [ "${#nodes[@]}" -eq 0 ]; then
        read -r -a nodes <<<"$PHONES"
    fi

    local node
    if [ "$state" = on ]; then
        # Park the supervisors first, then wait out any request that is already
        # in flight (udhcpc retries for up to ~8s), then drop the addresses.
        # Without the wait a phone can pick an address up again after we cleared
        # it, and the outcome of the scenario depends on timing.
        for node in "${nodes[@]}"; do
            exec_in "$node" touch /tmp/dhcp-hold >/dev/null
        done
        sleep 12
        for node in "${nodes[@]}"; do
            exec_in "$node" sh -c '
                pkill udhcpc 2>/dev/null || true
                sleep 1
                ip addr flush dev eth1 2>/dev/null || true
                ip route flush dev eth1 2>/dev/null || true
                rm -f /tmp/dhcp_lease
            ' >/dev/null
        done
    else
        # The supervisor process is parked, not dead, so clearing the flag is
        # usually enough - start one only if it really is gone.
        for node in "${nodes[@]}"; do
            exec_in "$node" sh -c '
                rm -f /tmp/dhcp-hold
                if ! pgrep -f "[d]hcp-supervise.sh" >/dev/null 2>&1; then
                    nohup /opt/dhcp-supervise.sh eth1 > /dev/null 2>&1 &
                fi
            ' >/dev/null
        done
    fi
}

say() { printf '  %s\n' "$1"; }
