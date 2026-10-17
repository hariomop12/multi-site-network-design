#!/bin/sh
# pub-srv - the public web server on the provider's hosting segment.
#
# Used as the NAT destination: internal hosts curl it and the provider only
# ever sees the single translated address 203.0.113.2.
set -eu

ADDR=198.51.100.10/24
GW=198.51.100.1

ip link set eth1 up
ip addr show dev eth1 | grep -q "${ADDR%/*}" || ip addr add "$ADDR" dev eth1
ip route replace default via "$GW"

mkdir -p /www
cat > /www/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>multi-site-network-design</title></head>
<body>
  <h1>Public web server</h1>
  <p>Served from 198.51.100.10 by the simulated provider.</p>
  <p>If you can read this, NAT overload on hq-core is working.</p>
</body>
</html>
HTML

# Alpine's busybox is built without the httpd applet, so the web server comes
# from python3 - which the labnode image already carries.
pkill -f "http.server" 2>/dev/null || true
nohup python3 -m http.server 80 --directory /www >/var/log/httpd.log 2>&1 &

echo "pub-srv: $ADDR, httpd listening on :80"
