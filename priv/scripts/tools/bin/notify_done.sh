#!/bin/bash
# SPDX-FileDescription: Broadcast task-completion signal to all waiting listeners via Unix sockets
# notify_done.sh - 发送任务完成信号广播
# 用法: ./notify_done.sh "信号名称"

SIGNAL=$1
if [ -z "$SIGNAL" ]; then
    echo "Usage: $0 <signal_name>"
    exit 1
fi

SOCKET_DIR="/tmp/eai_signals"
mkdir -p "$SOCKET_DIR"
chmod 777 "$SOCKET_DIR" 2>/dev/null || true

# 1. 记录持久化状态，防止后来者错过信号
touch "$SOCKET_DIR/done_$SIGNAL"

# 2. 广播给所有正在等待的门卫 (wait_*.sock)
if [ -d "$SOCKET_DIR" ]; then
    for sock in "$SOCKET_DIR"/wait_*.sock; do
        if [ -S "$sock" ]; then
            # 向每个监听者发送信号
            # 设置 1 秒超时防止死锁
            echo -n "$SIGNAL" | socat -t 1 - UNIX-CONNECT:"$sock" 2>/dev/null || true
        fi
    done
fi

exit 0
