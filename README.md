# OpenConnect SOCKS5 代理

[![Docker Image](https://img.shields.io/badge/Docker-xsdhy%2Fopenconnect--socks-blue?logo=docker)](https://hub.docker.com/r/xsdhy/openconnect-socks)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

一个健壮的 Docker 容器，将 OpenConnect VPN 连接通过 SOCKS5 代理暴露，提供稳定的 VPN 网关服务。

## ✨ 功能特性

- 🔒 **安全稳定** - 基于 OpenConnect 的 AnyConnect 协议连接
- 🔄 **自动重连** - 智能检测连接状态，自动重连断开的 VPN
- 🩺 **健康检查** - 通过 SOCKS5 代理定期检查网络连通性
- ⚡ **指数退避** - 连接失败时采用指数退避策略，避免频繁重试
- 🛠️ **自愈机制** - 多层故障检测与自动修复
- 📊 **详细日志** - 完整的操作日志，便于监控和调试
- 🐳 **容器友好** - 优雅的信号处理，支持容器编排
- 🌐 **DNS 支持** - SOCKS5h 模式确保 DNS 查询也通过 VPN

## 🏗️ 架构原理

```
┌─────────────────┐    ┌──────────────┐    ┌─────────────────┐
│   应用客户端     │───▶│  SOCKS5代理   │───▶│   VPN隧道       │
│ (curl/browser)  │    │ (microsocks) │    │ (openconnect)  │
└─────────────────┘    └──────────────┘    └─────────────────┘
                              │                      │
                              ▼                      ▼
                       ┌──────────────┐    ┌─────────────────┐
                       │   健康检查    │    │   目标服务器     │
                       │   监控循环    │    │                │
                       └──────────────┘    └─────────────────┘
```

## 🚀 快速开始

### 基本用法

```yaml
version: "3.8"
services:
  vpn-proxy:
    image: xsdhy/openconnect-socks:latest
    container_name: vpn-proxy
    privileged: true
    ports:
      - "11080:11080"
    volumes:
      - ./certificate.p12:/app/certificate.p12
    environment:
      VPN_PASSWORD: "your_certificate_password"
      VPN_SERVER: "vpn.example.com"
    restart: unless-stopped
```

### 高级配置

```yaml
version: "3.8"
services:
  vpn-proxy:
    image: xsdhy/openconnect-socks:latest
    container_name: vpn-proxy
    privileged: true
    ports:
      - "11080:11080"
    volumes:
      - ./certificate.p12:/app/certificate.p12
      - /etc/localtime:/etc/localtime:ro
    environment:
      # 必需参数
      VPN_PASSWORD: "your_certificate_password"
      VPN_SERVER: "vpn.example.com"
      
      # 可选参数
      TEST_URL: "https://www.google.com"      # 健康检查目标
      PROXY_PORT: "11080"                     # SOCKS5 端口
      CHECK_INTERVAL: "300"                   # 检查间隔（秒）
      RETRY_INTERVAL: "5"                     # 重试间隔（秒）
      MAX_RETRIES: "5"                        # 最大重试次数
      MAX_FAILS_BEFORE_RESTART: "3"          # 重启阈值
      MAX_SELFHEAL_RETRIES: "3"              # 自愈重试次数
      SELFHEAL_BACKOFF: "30"                 # 自愈退避时间
      CERT_FILE: "/app/certificate.p12"      # 证书文件路径
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "--proxy", "socks5h://localhost:11080", "https://www.baidu.com"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 30s
```

## 📋 环境变量

### 必需参数

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `VPN_PASSWORD` | VPN 证书密码 | `mypassword123` |
| `VPN_SERVER` | VPN 服务器地址 | `vpn.company.com` |

### 可选参数

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `TEST_URL` | `https://www.baidu.com` | 健康检查目标 URL |
| `CERT_FILE` | `/app/certificate.p12` | 客户端证书文件路径 |
| `PROXY_PORT` | `11080` | SOCKS5 代理监听端口 |
| `CHECK_INTERVAL` | `300` | 健康检查间隔（秒） |
| `RETRY_INTERVAL` | `5` | VPN 重连初始间隔（秒） |
| `MAX_RETRIES` | `5` | VPN 连接最大重试次数 |
| `MAX_FAILS_BEFORE_RESTART` | `3` | 触发全栈重启的失败次数 |
| `MAX_SELFHEAL_RETRIES` | `3` | 自愈机制最大重试次数 |
| `SELFHEAL_BACKOFF` | `30` | 自愈失败后退避时间（秒） |

## 🛠️ 重试与自愈机制详解

### 核心参数说明

#### `RETRY_INTERVAL` - VPN 重连初始间隔
- **作用**: 控制 VPN 连接失败后的初始重试间隔
- **机制**: 采用指数退避算法，每次失败后间隔会翻倍
- **计算公式**: `实际间隔 = RETRY_INTERVAL × 2^(失败次数-1)`
- **示例**: 设置为 5 秒时，重试间隔为 5s → 10s → 20s → 40s → 80s
- **建议值**: 3-10 秒，避免对 VPN 服务器造成压力

#### `MAX_RETRIES` - VPN 连接最大重试次数
- **作用**: 限制单轮 VPN 连接的最大尝试次数
- **触发**: 超过此次数后，会触发更高级别的故障处理
- **与其他参数关系**: 配合 `RETRY_INTERVAL` 形成完整的重试策略
- **建议值**: 3-8 次，平衡恢复速度和资源消耗

#### `MAX_FAILS_BEFORE_RESTART` - 全栈重启阈值
- **作用**: 连续健康检查失败达到此次数时，触发完整的服务重启
- **重启范围**: 同时重启 OpenConnect VPN 和 SOCKS5 代理
- **使用场景**: 处理深层次的网络故障或进程卡死
- **建议值**: 2-5 次，确保及时发现严重故障

#### `MAX_SELFHEAL_RETRIES` - 自愈重试上限
- **作用**: 限制自愈机制的最大尝试次数
- **自愈流程**: 检测到问题 → 尝试修复 → 验证修复效果 → 记录结果
- **失败处理**: 超过此次数后进入更长的退避期
- **建议值**: 2-5 次，避免无效的频繁重试

#### `SELFHEAL_BACKOFF` - 自愈退避时间
- **作用**: 自愈机制完全失败后的等待时间
- **目的**: 给系统时间稳定，避免陷入无限重试循环
- **期间行为**: 暂停所有主动修复操作，仅进行被动监控
- **建议值**: 30-300 秒，根据网络环境调整

### 工作流程示例

```
VPN连接失败
     ↓
使用指数退避重试 (MAX_RETRIES次)
     ↓
健康检查持续失败 (MAX_FAILS_BEFORE_RESTART次)
     ↓
触发全栈重启
     ↓
重启后仍有问题，启动自愈机制 (MAX_SELFHEAL_RETRIES次)
     ↓
自愈失败，进入退避期 (SELFHEAL_BACKOFF时间)
     ↓
退避期结束，重新开始循环
```


## 🔐 安全注意事项

1. **证书保护** - 确保 `.p12` 证书文件权限正确 (600)
2. **密码安全** - 使用 Docker secrets 或环境变量文件存储密码
3. **网络隔离** - 仅暴露必要的端口