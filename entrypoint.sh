#!/bin/sh

set -e

if [ -z "$VPN_PASSWORD" ] || [ -z "$VPN_SERVER" ]; then
  echo "VPN_PASSWORD and VPN_SERVER are required"
  exit 1
fi

echo "Connecting to VPN: $VPN_SERVER"
openconnect \
    --protocol=anyconnect \
    -c /app/certificate.p12 \
    --key-password="$VPN_PASSWORD" \
    --background \
    "$VPN_SERVER"

while true; do sleep 1; done
echo "Starting socks5 proxy on port 11080"
microsocks -p 11080