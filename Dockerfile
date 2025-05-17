FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openconnect ca-certificates libevent-dev git build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/rofl0r/microsocks && \
    cd microsocks && \
    make && \
    cp microsocks /usr/local/bin/ && \
    cd .. && rm -rf microsocks

RUN mkdir -p /app && chmod 755 /app

WORKDIR /app

EXPOSE 11080

COPY --chmod=755 entrypoint.sh /app/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 CMD nc -z localhost 11080 || exit 1

CMD ["/app/entrypoint.sh"]