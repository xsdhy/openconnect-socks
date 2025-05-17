FROM debian:bullseye-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential ca-certificates autoconf automake libevent-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth=1 https://github.com/cernekee/ocproxy.git && \
    cd ocproxy && \
    ./autogen.sh && \
    ./configure && \
    make


FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openconnect ca-certificates libevent-2.1-7 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/ocproxy/src/ocproxy /usr/local/bin/

WORKDIR /app

EXPOSE 11080

ENTRYPOINT sh -c '\
  if [ -z "$KEY_PASSWORD" ] || [ -z "$VPN_SERVER" ]; then \
    echo "Environment variables must be set: KEY_PASSWORD and VPN_SERVER" >&2; exit 1; \
  fi && \
  echo "Connecting VPN $VPN_SERVER ..." && \
  openconnect \
    --script-tun \
    --script "/usr/local/bin/ocproxy -D 11080" \
    --protocol=anyconnect \
    -c /app/certificate.p12 \
    --key-password="$KEY_PASSWORD" \
    "$VPN_SERVER"'