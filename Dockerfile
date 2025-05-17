FROM debian:bullseye-slim AS builder

# 安装构建依赖并清理缓存
RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential ca-certificates autoconf automake libevent-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth=1 https://github.com/cernekee/ocproxy.git /build/ocproxy \
    && cd /build/ocproxy \
    && ./autogen.sh \
    && ./configure \
    && make \
    && strip ocproxy

FROM debian:bullseye-slim

# 安装运行时依赖并清理缓存
RUN apt-get update && apt-get install -y --no-install-recommends \
    openconnect ca-certificates libevent-2.1-7 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app \
    && chmod 755 /app

# 复制编译好的二进制文件
COPY --from=builder /build/ocproxy/ocproxy /usr/local/bin/ocproxy
RUN chmod 755 /usr/local/bin/ocproxy

WORKDIR /app

# 暴露 SOCKS 代理端口
EXPOSE 11080

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:11080 || exit 1

# 使用非 root 用户运行
RUN useradd -m -s /bin/bash vpnuser
USER vpnuser

# 使用 JSON 格式的 ENTRYPOINT
ENTRYPOINT ["sh", "-c", "\
  if [ -z \"$KEY_PASSWORD\" ] || [ -z \"$VPN_SERVER\" ]; then \
    echo \"Environment variables must be set: KEY_PASSWORD and VPN_SERVER\" >&2; exit 1; \
  fi && \
  echo \"Connecting VPN $VPN_SERVER ...\" && \
  openconnect \
    --script-tun \
    --script \"/usr/local/bin/ocproxy -D 11080\" \
    --protocol=anyconnect \
    -c /app/certificate.p12 \
    --key-password=\"$KEY_PASSWORD\" \
    \"$VPN_SERVER\""]