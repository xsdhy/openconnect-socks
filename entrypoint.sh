#!/usr/bin/env bash

# vpn_proxy.sh — 健壮的永远在线 VPN + SOCKS5 桥接服务
# ====================================================
# 功能特性：
# * 指数退避的 VPN 连接（使用 AnyConnect 协议）
# * 带故障计数器的自愈 microsocks 代理
# * 通过 SOCKS5h 进行健康检查以验证 DNS + HTTP 路径
# * 优雅关闭和正确的退出码供编排器使用

# 严格模式：遇到错误立即退出，管道中任何命令失败都会导致失败，使用未定义变量会报错
set -Eeuo pipefail

# 预先声明所有变量以避免 set -u 模式下 trap 处理函数中的未定义变量问题
# 注意：不要覆盖环境变量，仅声明进程相关变量
SOCKS_PID=""                    # SOCKS 代理进程 ID
VPN_PID=""                      # VPN 进程 ID  
OPENCONNECT_PID_FILE="/tmp/openconnect.pid"  # OpenConnect PID 文件路径

# 配置变量将在后面根据环境变量设置，这里仅声明避免 set -u 错误
: ${TEST_URL:=}                 # 健康检查用的测试 URL（从环境变量获取）
: ${CERT_FILE:=}                # VPN 证书文件路径
: ${PROXY_PORT:=}               # SOCKS 代理端口
: ${CHECK_INTERVAL:=}           # 健康检查间隔（秒）
: ${RETRY_INTERVAL:=}           # VPN 重试间隔（秒）
: ${MAX_RETRIES:=}              # VPN 最大重试次数
: ${MAX_FAILS_BEFORE_RESTART:=} # 触发重启前的最大失败次数
: ${MAX_SELFHEAL_RETRIES:=}     # 自愈最大重试次数
: ${SELFHEAL_BACKOFF:=}         # 自愈失败后的退避时间（秒）

#################################
#           日志工具             #
#################################
# 统一的日志输出函数，格式：[时间戳] 消息内容
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

#################################
#           清理处理             #
#################################
# 清理函数：负责优雅关闭所有子进程
# 注意：仅在脚本退出时调用，不要在自愈逻辑中使用
cleanup() {
  log "触发清理 — 正在关闭子进程"
  
  # 优先使用内存中的 VPN_PID，回退到 PID 文件
  local vpn_killed=false
  if [[ -n "${VPN_PID}" && "${VPN_PID}" =~ ^[0-9]+$ ]]; then
    if kill "${VPN_PID}" 2>/dev/null; then
      vpn_killed=true
      log "已向 VPN 进程 ${VPN_PID} 发送 SIGTERM"
    fi
  elif [[ -r "${OPENCONNECT_PID_FILE}" ]]; then
    local pid_content=""
    # 安全地读取 PID 文件，避免空文件或并发删除导致的错误
    if pid_content=$(<"${OPENCONNECT_PID_FILE}" 2>/dev/null); then
      if [[ -n "${pid_content}" && "${pid_content}" =~ ^[0-9]+$ ]]; then
        if kill "${pid_content}" 2>/dev/null; then
          vpn_killed=true
          log "已向 VPN 进程 ${pid_content} 发送 SIGTERM（从文件读取）"
        fi
      fi
    fi
  fi
  
  # 关闭 SOCKS 进程
  local socks_killed=false
  if [[ -n "${SOCKS_PID}" && "${SOCKS_PID}" =~ ^[0-9]+$ ]]; then
    if kill "${SOCKS_PID}" 2>/dev/null; then
      socks_killed=true
      log "已向 SOCKS 进程 ${SOCKS_PID} 发送 SIGTERM"
    fi
  fi
  
  # 等待进程优雅退出（最多 5 秒）
  if $vpn_killed || $socks_killed; then
    log "等待进程退出，最多 5 秒..."
    local wait_count=0
    while (( wait_count < 5 )); do
      local still_running=false
      
      # 检查 VPN 进程是否仍在运行
      if $vpn_killed && [[ -n "${VPN_PID}" && "${VPN_PID}" =~ ^[0-9]+$ ]]; then
        if kill -0 "${VPN_PID}" 2>/dev/null; then
          still_running=true
        fi
      fi
      
      # 检查 SOCKS 进程是否仍在运行
      if $socks_killed && [[ -n "${SOCKS_PID}" && "${SOCKS_PID}" =~ ^[0-9]+$ ]]; then
        if kill -0 "${SOCKS_PID}" 2>/dev/null; then
          still_running=true
        fi
      fi
      
      # 如果所有进程都已退出，跳出等待循环
      if ! $still_running; then
        log "所有进程已优雅退出"
        break
      fi
      
      sleep 1
      (( wait_count++ ))
    done
    
    # 如果进程仍在运行，强制杀死
    if $vpn_killed && [[ -n "${VPN_PID}" && "${VPN_PID}" =~ ^[0-9]+$ ]]; then
      if kill -0 "${VPN_PID}" 2>/dev/null; then
        log "强制杀死 VPN 进程 ${VPN_PID}"
        kill -9 "${VPN_PID}" 2>/dev/null || true
      fi
    fi
    
    if $socks_killed && [[ -n "${SOCKS_PID}" && "${SOCKS_PID}" =~ ^[0-9]+$ ]]; then
      if kill -0 "${SOCKS_PID}" 2>/dev/null; then
        log "强制杀死 SOCKS 进程 ${SOCKS_PID}"
        kill -9 "${SOCKS_PID}" 2>/dev/null || true
      fi
    fi
  fi
}

# 保留原始信号编号以便外部系统正确识别退出原因
trap 'code=$?; cleanup; exit $code' EXIT  # 正常退出或异常退出
trap 'cleanup; exit 2' INT                # Ctrl+C 中断 (SIGINT = 2)
trap 'cleanup; exit 15' TERM              # 终止信号 (SIGTERM = 15)

#################################
#           配置参数             #
#################################
# 必需的环境变量检查
: "${VPN_PASSWORD:?必须设置环境变量 VPN_PASSWORD}"
: "${VPN_SERVER:?必须设置环境变量 VPN_SERVER}"

# 可选配置参数（带默认值）
TEST_URL=${TEST_URL:-https://www.baidu.com}            # 健康检查目标 URL
CERT_FILE=${CERT_FILE:-/app/certificate.p12}          # VPN 客户端证书
PROXY_PORT=${PROXY_PORT:-11080}                       # SOCKS5 代理端口
CHECK_INTERVAL=${CHECK_INTERVAL:-300}                 # 健康检查间隔（5分钟）
RETRY_INTERVAL=${RETRY_INTERVAL:-5}                   # VPN 重试初始间隔
MAX_RETRIES=${MAX_RETRIES:-5}                         # VPN 连接最大重试次数
MAX_FAILS_BEFORE_RESTART=${MAX_FAILS_BEFORE_RESTART:-3}  # 触发全栈重启的失败阈值
MAX_SELFHEAL_RETRIES=${MAX_SELFHEAL_RETRIES:-3}       # 自愈最大尝试次数
SELFHEAL_BACKOFF=${SELFHEAL_BACKOFF:-30}              # 自愈失败后退避时间

# 检查证书文件是否存在
[[ -f "$CERT_FILE" ]] || { log "证书文件 $CERT_FILE 未找到"; exit 1; }

#################################
#           VPN 控制             #
#################################
# 启动 VPN 连接，带指数退避重试机制
start_vpn() {
  local attempt=1 sleep_time=$RETRY_INTERVAL
  
  while (( attempt <= MAX_RETRIES )); do
    log "[VPN] ($attempt/$MAX_RETRIES) 正在连接到 $VPN_SERVER"
    
    # 使用 OpenConnect 建立 AnyConnect VPN 连接
    if openconnect --protocol=anyconnect \
                   -c "$CERT_FILE" \
                   --key-password="$VPN_PASSWORD" \
                   --background \
                   --pid-file "$OPENCONNECT_PID_FILE" \
                   "$VPN_SERVER"; then
      # 连接成功，从 PID 文件读取进程 ID
      VPN_PID=$(<"$OPENCONNECT_PID_FILE")
      log "[VPN] 连接成功 (pid=$VPN_PID)"
      return 0
    fi
    
    # 连接失败，指数退避
    log "[VPN] openconnect 失败 — 退避 $sleep_time 秒"
    sleep "$sleep_time"
    sleep_time=$(( sleep_time * 2 ))  # 下次等待时间翻倍
    (( attempt++ ))
  done
  
  log "[VPN] 重试 $MAX_RETRIES 次后仍然失败"
  return 1
}

#################################
#         SOCKS5 控制           #
#################################
# 启动 SOCKS5 代理服务，带严格的验证机制
start_socks() {
  log "[SOCKS] 在端口 $PROXY_PORT 启动 microsocks"
  
  # 总是先清空 PID 以避免使用过期值
  SOCKS_PID=""
  
  # 检查端口是否被占用（可选 - 优雅降级）
  if command -v netstat >/dev/null 2>&1; then
    if netstat -ln 2>/dev/null | grep -q ":${PROXY_PORT} "; then
      log "[SOCKS] 端口 $PROXY_PORT 似乎正在使用中，仍然尝试继续"
    fi
  elif command -v ss >/dev/null 2>&1; then
    if ss -ln 2>/dev/null | grep -q ":${PROXY_PORT} "; then
      log "[SOCKS] 端口 $PROXY_PORT 似乎正在使用中 (ss)，仍然尝试继续"
    fi
  fi
  
  # 启动 microsocks 进程
  microsocks -p "$PROXY_PORT" &
  local new_pid=$!
  
  # 等待进程启动并验证其仍在运行
  sleep 2
  if ! kill -0 "$new_pid" 2>/dev/null; then
    log "[SOCKS] microsocks 启动失败（进程已死亡）"
    # SOCKS_PID 保持为空 - 无需清理
    return 1
  fi
  
  # 附加验证：尝试快速连接测试（可选）
  local test_success=true  # 如果工具不可用则假设成功
  if command -v timeout >/dev/null 2>&1 && command -v nc >/dev/null 2>&1; then
    # 使用 timeout 和 nc 进行端口连通性测试
    test_success=false
    local test_attempts=3
    for (( i=1; i<=test_attempts; i++ )); do
      if timeout 3 bash -c "echo | nc -w1 127.0.0.1 $PROXY_PORT" >/dev/null 2>&1; then
        test_success=true
        break
      fi
      sleep 1
    done
  elif command -v bash >/dev/null 2>&1; then
    # 备选方案：不使用外部工具的简单套接字测试
    test_success=false
    for (( i=1; i<=3; i++ )); do
      if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PROXY_PORT && exec 3<&-" 2>/dev/null; then
        test_success=true
        break
      fi
      sleep 1
    done
  fi
  
  if ! $test_success; then
    log "[SOCKS] microsocks 已启动但端口 $PROXY_PORT 不接受连接"
    kill "$new_pid" 2>/dev/null || true
    # 短暂等待进程退出
    sleep 1
    # SOCKS_PID 保持为空
    return 1
  fi
  
  # 只有在所有验证通过后才设置 SOCKS_PID
  SOCKS_PID=$new_pid
  log "[SOCKS] 启动并验证成功 (pid=$SOCKS_PID)"
  return 0
}

#################################
#           健康检查             #
#################################
# 通过 SOCKS5 代理进行健康检查
# 使用 socks5h 确保 DNS 解析也通过代理进行
healthcheck() {
  curl --silent --show-error --fail \
       --proxy "socks5h://localhost:$PROXY_PORT" \
       --max-time 10 "$TEST_URL" -o /dev/null
}

#################################
#           自愈机制             #
#################################
# 重启整个服务栈（VPN + SOCKS），用于自愈场景
restart_stack() {
  log "[自愈] 重启 VPN 和代理"
  
  # 杀死 VPN 进程并等待资源清理
  if [[ -n "${VPN_PID}" && "${VPN_PID}" =~ ^[0-9]+$ ]]; then
    log "[自愈] 停止 VPN 进程 $VPN_PID"
    kill "${VPN_PID}" 2>/dev/null || true
    
    # 等待 VPN 释放资源（如 TUN 设备）
    local wait_count=0
    while (( wait_count < 10 )) && kill -0 "${VPN_PID}" 2>/dev/null; do
      sleep 1
      (( wait_count++ ))
    done
    
    # 如果进程仍未退出，强制杀死
    if kill -0 "${VPN_PID}" 2>/dev/null; then
      log "[自愈] 强制杀死 VPN 进程 $VPN_PID"
      kill -9 "${VPN_PID}" 2>/dev/null || true
      sleep 2  # 额外等待 TUN 设备清理
    fi
  elif [[ -r "$OPENCONNECT_PID_FILE" ]]; then
    # 备选方案：从 PID 文件读取
    local pid_content=""
    if pid_content=$(<"$OPENCONNECT_PID_FILE" 2>/dev/null); then
      if [[ -n "${pid_content}" && "${pid_content}" =~ ^[0-9]+$ ]]; then
        log "[自愈] 停止 VPN 进程 $pid_content（从文件读取）"
        kill "${pid_content}" 2>/dev/null || true
        local wait_count=0
        while (( wait_count < 10 )) && kill -0 "${pid_content}" 2>/dev/null; do
          sleep 1
          (( wait_count++ ))
        done
        if kill -0 "${pid_content}" 2>/dev/null; then
          kill -9 "${pid_content}" 2>/dev/null || true
          sleep 2
        fi
      fi
    fi
  fi
  
  # 清理 VPN 相关状态
  VPN_PID=""
  rm -f "$OPENCONNECT_PID_FILE"
  
  # 杀死 SOCKS 进程
  if [[ -n "${SOCKS_PID}" && "${SOCKS_PID}" =~ ^[0-9]+$ ]]; then
    log "[自愈] 停止 SOCKS 进程 $SOCKS_PID"
    kill "${SOCKS_PID}" 2>/dev/null || true
    # 短暂等待端口释放
    sleep 1
  fi
  SOCKS_PID=""

  # 重启 VPN
  if ! start_vpn; then
    log "[自愈] VPN 重启失败"
    return 1
  fi
  
  # 重启 SOCKS - 如果失败，我们有 VPN 但没有代理
  if ! start_socks; then
    log "[自愈] SOCKS 重启失败，但 VPN 已连接"
    # SOCKS_PID 在 start_socks 失败时已经为空
    # 保持 VPN 运行，下一个监控周期将重试 SOCKS
    return 1
  fi
  
  log "[自愈] VPN 和 SOCKS 都重启成功"
  return 0
}

#################################
#           监控循环             #
#################################
# 主监控循环：检查进程状态和健康状况，执行自愈操作
monitor() {
  local fail_count=0 selfheal_failures=0 socks_restart_failures=0
  
  while true; do
    # 检查 microsocks 是否存活（安全的 PID 检查）
    local socks_alive=false
    if [[ -n "${SOCKS_PID}" && "${SOCKS_PID}" =~ ^[0-9]+$ ]] && kill -0 "${SOCKS_PID}" 2>/dev/null; then
      socks_alive=true
    fi
    
    # 如果 SOCKS 进程不存活，尝试重启
    if ! $socks_alive; then
      log "[监控] microsocks 未运行，正在重启"
      if start_socks; then
        log "[监控] microsocks 重启成功"
        socks_restart_failures=0  # 成功时重置计数器
      else
        (( socks_restart_failures++ ))
        log "[监控] microsocks 重启失败 ($socks_restart_failures/5)"
        
        # 如果 SOCKS 持续重启失败，触发全栈重启
        if (( socks_restart_failures >= 5 )); then
          log "[监控] SOCKS 重启失败次数过多，触发全栈重启"
          socks_restart_failures=0
          fail_count=$MAX_FAILS_BEFORE_RESTART  # 强制全栈重启
        fi
      fi
    fi

    # 执行健康检查
    log "[监控] 正在执行健康检查 - $TEST_URL"
    if healthcheck; then
      # 健康检查通过
      if [[ $fail_count -ne 0 ]]; then
        log "[监控] 健康检查已恢复（之前失败 $fail_count 次）"
      else
        log "[监控] 健康检查正常"
      fi
      fail_count=0
    else
      # 健康检查失败
      (( fail_count++ ))
      log "[监控] 健康检查失败 ($fail_count/$MAX_FAILS_BEFORE_RESTART)"
      
      # 达到失败阈值时触发自愈
      if (( fail_count >= MAX_FAILS_BEFORE_RESTART )); then
        fail_count=0
        if restart_stack; then
          log "[监控] 自愈重启完成"
          selfheal_failures=0       # 成功时重置自愈失败计数
          socks_restart_failures=0  # 同时重置 SOCKS 计数器
        else
          (( selfheal_failures++ ))
          log "[监控] 自愈重启失败 ($selfheal_failures/$MAX_SELFHEAL_RETRIES)"
          
          # 达到最大自愈重试次数时退出，让外部编排器介入
          if (( selfheal_failures >= MAX_SELFHEAL_RETRIES )); then
            log "[监控] 超过最大自愈重试次数，退出以供编排器介入"
            exit 1
          fi
          
          # 自愈失败后退避一段时间再继续
          log "[监控] 退避 ${SELFHEAL_BACKOFF} 秒后继续"
          sleep "$SELFHEAL_BACKOFF"
        fi
      fi
    fi
    
    # 等待下一个检查周期
    sleep "$CHECK_INTERVAL"
  done
}

#################################
#             主程序             #
#################################
# 主函数：初始化服务并启动监控
main() {
  log "启动 VPN 代理服务"
  
  # 尝试启动 VPN
  if ! start_vpn; then
    log "初始 VPN 连接失败，退出"
    exit 1
  fi
  
  # 尝试启动 SOCKS - 如果失败，继续监控以重试
  if start_socks; then
    log "服务启动成功，开始监控"
  else
    log "初始 SOCKS 启动失败，将在监控循环中重试"
    # 继续到监控阶段 - 它会处理 SOCKS 重启
  fi
  
  monitor  # 正常情况下永不返回
}

# 启动主程序，传递所有命令行参数
main "$@"
