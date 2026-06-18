#!/usr/bin/env bash
# ============================================================
# eai-input.sh — input bar handler for EAI TUI
#
# Single-line input. ENTER = send. Empty = ignore.
# Usage: bash eai-input.sh <tmux_target_pane>
# ============================================================

TARGET="$1"
if [ -z "$TARGET" ]; then
  echo "Usage: eai-input.sh <tmux_pane_id>"
  exit 1
fi

while true; do
  printf '> '
  read -r input
  [ -z "$input" ] && continue

  escaped=$(printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g')
  tmux send-keys -t "$TARGET" "Eai.Chat.talk(content: \"$escaped\", mod: :f)" Enter
  echo "→ sent"
done