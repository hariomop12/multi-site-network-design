# Lab host / access-switch node.
#
# A plain Alpine box with the tooling the fault scenarios need: real iproute2
# (busybox `ip` cannot do 802.1Q bridge filtering), a DHCP client, tcpdump and a
# tiny HTTP server for the NAT test.
FROM alpine:3.20

RUN apk add --no-cache \
        iproute2 \
        iproute2-tc \
        iputils \
        traceroute \
        tcpdump \
        conntrack-tools \
        dnsmasq \
        bind-tools \
        curl \
        bash \
        python3 \
        jq

# Every node may ship a per-node /etc/lab/setup.sh that is executed on boot.
COPY entrypoint.sh       /usr/local/bin/lab-entrypoint.sh
COPY dhcp-lease.sh       /opt/dhcp-lease.sh
COPY dhcp-request.sh     /opt/dhcp-request.sh
COPY dhcp-supervise.sh   /opt/dhcp-supervise.sh
RUN chmod +x /usr/local/bin/lab-entrypoint.sh \
             /opt/dhcp-lease.sh /opt/dhcp-request.sh /opt/dhcp-supervise.sh

ENTRYPOINT ["/usr/local/bin/lab-entrypoint.sh"]
