# Build stage
FROM debian:bullseye-slim as builder

# Install build dependencies and CA certificates
RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build microsocks
RUN git config --global http.sslVerify false && \
    git clone https://github.com/rofl0r/microsocks && \
    cd microsocks && \
    make && \
    cd ..

# Runtime stage
FROM debian:bullseye-slim

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    openconnect ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Copy built microsocks binary from builder
COPY --from=builder /microsocks/microsocks /usr/local/bin/

# Create app directory
RUN mkdir -p /app && chmod 755 /app

WORKDIR /app

EXPOSE 11080

# Copy entrypoint script
COPY --chmod=755 entrypoint.sh /app/entrypoint.sh

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -x socks5://localhost:11080 -m 5 https://www.baidu.com > /dev/null 2>&1 || exit 1

CMD ["/app/entrypoint.sh"]