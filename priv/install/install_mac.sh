#!/usr/bin/env bash
# install_mac.sh — eai 一键安装脚本（macOS，Homebrew 环境）
# 与 install_unix.sh 基本相同，但额外处理 macOS 特有路径和 Homebrew
set -euo pipefail

BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; RESET="\033[0m"

info()  { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
error() { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}$*${RESET}"; }

# ─── 1. 依赖检查 + Homebrew 提示 ─────────────────────────────────────────────
step "1/5  检查依赖"

if ! command -v brew &>/dev/null; then
  warn "未检测到 Homebrew。"
  warn "推荐先安装：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi

for cmd in elixir mix python3; do
  if command -v "$cmd" &>/dev/null; then
    info "$cmd 已安装 ($(command -v "$cmd"))"
  else
    if command -v brew &>/dev/null; then
      case "$cmd" in
        elixir|mix) warn "尝试 Homebrew 安装 elixir…"; brew install elixir ;;
        python3)    warn "尝试 Homebrew 安装 python…"; brew install python ;;
      esac
    else
      error "未找到 $cmd，且未安装 Homebrew，请手动安装后重试。"
    fi
  fi
done

# ─── 2. 环境变量检查 ──────────────────────────────────────────────────────────
step "2/5  检查环境变量"

SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == *"bash"* ]] && SHELL_RC="$HOME/.bash_profile"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  warn "OPENAI_API_KEY 未设置。"
  read -rp "      请输入 API Key（直接回车跳过）: " INPUT_KEY
  if [[ -n "$INPUT_KEY" ]]; then
    export OPENAI_API_KEY="$INPUT_KEY"
    if ! grep -q "OPENAI_API_KEY" "$SHELL_RC" 2>/dev/null; then
      echo "export OPENAI_API_KEY=\"$INPUT_KEY\"" >> "$SHELL_RC"
      info "已追加到 $SHELL_RC（source $SHELL_RC 后生效）"
    fi
  else
    warn "跳过。启动前请手动执行：export OPENAI_API_KEY=sk-..."
  fi
else
  info "OPENAI_API_KEY 已设置"
fi

# ─── 3. Python 依赖 ───────────────────────────────────────────────────────────
step "3/5  安装 Python 依赖"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIV_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$PRIV_DIR/scripts"

PIP_ARGS="--quiet --break-system-packages 2>/dev/null || pip3 install --quiet"

if [[ -f "$SCRIPTS_DIR/requirements.txt" ]]; then
  python3 -m pip install --quiet --break-system-packages -r "$SCRIPTS_DIR/requirements.txt" 2>/dev/null \
    || python3 -m pip install --quiet -r "$SCRIPTS_DIR/requirements.txt"
  info "Python 依赖安装完成"
else
  python3 -m pip install --quiet --break-system-packages numpy scipy 2>/dev/null \
    || python3 -m pip install --quiet numpy scipy
  info "numpy + scipy 已安装"
fi

# ─── 4. Mix 依赖 & 编译 ────────────────────────────────────────────────────────
step "4/5  获取 Mix 依赖并编译"

cd "$(dirname "$PRIV_DIR")"
mix deps.get --quiet
info "deps.get 完成"
mix compile --quiet
info "编译完成"

# ─── 5. 工作目录 ─────────────────────────────────────────────────────────────
step "5/5  准备运行时目录"

WORK_DIR="${EAI_WORK_DIR:-$HOME/eai_agents}"
mkdir -p "$WORK_DIR" && info "工作目录：$WORK_DIR"

echo ""
echo -e "${GREEN}${BOLD}安装完成！${RESET}"
echo ""
echo "启动方式："
echo "  iex -S mix               # 交互式 shell"
echo "  mix run --no-halt        # 后台运行"
echo ""
echo "可选环境变量覆盖："
echo "  EAI_LLM_URL      LLM 接口地址"
echo "  EAI_LLM_MODEL    模型名称"
echo "  EAI_LLM_TIMEOUT  请求超时（毫秒）"
echo "  EAI_WORK_DIR     PTY 工作目录根路径（默认 ~/eai_agents）"
