# Build stage
FROM debian:bullseye-slim as builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget gzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download and install gost
RUN wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz && \
    gzip -d gost-linux-amd64-2.11.5.gz && \
    mv gost-linux-amd64-2.11.5 /usr/local/bin/gost && \
    chmod +x /usr/local/bin/gost

# Runtime stage
FROM debian:bullseye-slim

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    openconnect ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Copy gost binary from builder
COPY --from=builder /usr/local/bin/gost /usr/local/bin/

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