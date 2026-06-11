#!/usr/bin/env bash
# ============================================================
# eai-tui.sh — TUI wrapper for Eai with tmux
#
# Layout:
#   ┌──────────────────────┬────────────┐
#   │   IEx 信息屏 (70%)    │ 右上角 (留白) │
#   │  • model 回复         │            │
#   │  • telemetry 刷屏     ├────────────┤
#   │  • 工具调用输出        │  输入栏     │
#   │                      │ [ENTER] 发送 │
#   └──────────────────────┴────────────┘
#
# Controls:
#   Ctrl+↑↓←→  — 切换焦点窗口
#   输入栏 ENTER — 发送消息到 IEx
#
# Prerequisite: tmux installed
# ============================================================

set -euo pipefail
\n# ── Prerequisites ────────────────────────────────────────

if ! command -v tmux &>/dev/null; then

  echo "ERROR: tmux is required. Install: apt install tmux"

  exit 1

fi

SESSION="eai-tui"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLS=$(tput cols 2>/dev/null || echo 120)
ROWS=$(tput lines 2>/dev/null || echo 40)

# ── Cleanup: kill old session, remove our bindings ───────────
cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  # Remove C-Arrow bindings we set (silently ignore if not set)
  tmux unbind-key -n C-Up    2>/dev/null || true
  tmux unbind-key -n C-Down  2>/dev/null || true
  tmux unbind-key -n C-Left  2>/dev/null || true
  tmux unbind-key -n C-Right 2>/dev/null || true
}
trap cleanup EXIT
cleanup

# ── Key bindings (server-global — cleaned up on EXIT) ────────
tmux bind-key -n C-Up    select-pane -U
tmux bind-key -n C-Down  select-pane -D
tmux bind-key -n C-Left  select-pane -L
tmux bind-key -n C-Right select-pane -R

# ── Create session ──────────────────────────────────────────
tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR" -x "$COLS" -y "$ROWS"
tmux set-option -t "$SESSION" status-style "bg=black,fg=green"
tmux set-option -t "$SESSION" status-left " EAI TUI — IEx "
tmux set-option -t "$SESSION" status-right " Ctrl+Arrows: swap | ENTER: send | Ctrl+B D: detach "

# ── Pane layout ─────────────────────────────────────────────
# Left: IEx (70% width)
tmux send-keys -t "$SESSION:0.0" 'iex -S mix' Enter
sleep 0.5

# Right split: 30%
tmux split-window -h -p 30 -t "$SESSION:0.0"
# Right-top: blank for now
tmux send-keys -t "$SESSION:0.1" 'echo "   (right panel — reserved)"' Enter

# Right-bottom: input bar (20% of right column)
tmux split-window -v -p 20 -t "$SESSION:0.1"

# ── Launch input handler ────────────────────────────────────
IEX_PANE="$SESSION:0.0"
INPUT_PANE="$SESSION:0.2"

sleep 2  # let IEx finish compiling
tmux send-keys -t "$INPUT_PANE" 'clear; echo "── EAI Input ──"' Enter
sleep 0.2
tmux send-keys -t "$INPUT_PANE" "bash '$SCRIPT_DIR/eai-input.sh' '$IEX_PANE'" Enter

# ── Focus IEx pane ──────────────────────────────────────────
tmux select-pane -t "$IEX_PANE"

# ── Attach ──────────────────────────────────────────────────
tmux attach-session -t "$SESSION"
