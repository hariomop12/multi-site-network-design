# Lab router node: FRRouting plus the small set of tools the fault scenarios,
# the DHCP service and the edge NAT need.
#
# Based on the official FRR image so that `vtysh`, the daemons and the start-up
# wrapper behave exactly as they do upstream.
#
# Note: the official FRR build ships without NAT support (no libnftnl), which is
# why NAT overload is implemented with nftables on the edge router instead. See
# docs/runbooks/ for the reasoning.
FROM quay.io/frrouting/frr:10.7.1

RUN apk add --no-cache \
        iproute2 \
        iproute2-tc \
        iputils \
        traceroute \
        tcpdump \
        conntrack-tools \
        nftables \
        dnsmasq \
        bind-tools \
        curl \
        bash \
        jq

# Per-node boot hook: creates VLAN sub-interfaces, applies nftables NAT and
# starts local services before FRR loads its configuration.
COPY entrypoint.sh /usr/local/bin/lab-entrypoint.sh
RUN chmod +x /usr/local/bin/lab-entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/lab-entrypoint.sh"]
