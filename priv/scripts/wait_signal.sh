#!/bin/bash
# wait_signal.sh - 阻塞监听信号，等待前置任务完成
# 用法: ./wait_signal.sh "信号名称"

SIGNAL=$1
if [ -z "$SIGNAL" ]; then
    echo "Usage: $0 <signal_name>"
    exit 1
fi

SOCKET_DIR="/tmp/eai_signals"
mkdir -p "$SOCKET_DIR"
chmod 777 "$SOCKET_DIR" 2>/dev/null || true

# 状态检查：如果信号已经发出过了，直接放行（增加鲁棒性）
if [ -f "$SOCKET_DIR/done_$SIGNAL" ]; then
    exit 0
fi

# 创建属于当前进程的唯一监听 Socket
# 使用 PID 保证并发安全
LISTEN_SOCK="$SOCKET_DIR/wait_$$.sock"

# 确保退出时清理 Socket
trap "rm -f $LISTEN_SOCK" EXIT

# 循环监听，直到收到匹配的信号
while true; do
    # socat 启动监听，接收到一次连接后会自动退出
    # 我们读取连接传来的内容
    MSG=$(socat -u UNIX-LISTEN:"$LISTEN_SOCK",unlink-early - 2>/dev/null)
    
    # 检查是否是我们要的信号
    if [ "$MSG" == "$SIGNAL" ]; then
        break
    fi
    
    # 如果收到了错误的信号，继续监听
done

exit 0
