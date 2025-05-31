#!/bin/sh

set -e

# Check required environment variables
if [ -z "$VPN_PASSWORD" ] || [ -z "$VPN_SERVER" ]; then
  echo "VPN_PASSWORD and VPN_SERVER are required"
  exit 1
fi

# Default test URL if not provided
TEST_URL=${TEST_URL:-"https://www.baidu.com"}

echo "Connecting to VPN: $VPN_SERVER"
openconnect \
    --protocol=anyconnect \
    -c /app/certificate.p12 \
    --key-password="$VPN_PASSWORD" \
    --background \
    "$VPN_SERVER"

echo "Starting socks5 proxy on port 11080"
microsocks -p 11080 &

# Monitoring script
monitor() {
    while true; do
        # Test connection through the proxy
        curl -x socks5://localhost:11080 -m 10 "$TEST_URL" > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "$(date): Connection test to $TEST_URL failed"
            # Try to reconnect VPN
            echo "Attempting to reconnect VPN..."
            pkill openconnect
            sleep 5
            openconnect \
                --protocol=anyconnect \
                -c /app/certificate.p12 \
                --key-password="$VPN_PASSWORD" \
                --background \
                "$VPN_SERVER"
        else
            echo "$(date): Connection test to $TEST_URL successful"
        fi
        sleep 300
    done
}

# Start monitoring in background
monitor &

# Keep the container running
wait