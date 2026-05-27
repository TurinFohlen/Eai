#!/usr/bin/env bash
# install_unix.sh — eai 一键安装脚本（Linux / macOS）
set -euo pipefail

BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; RESET="\033[0m"

info()  { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
error() { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}$*${RESET}"; }

# ─── 1. 依赖检查 ─────────────────────────────────────────────────────────────
step "1/5  检查依赖"

check_cmd() {
  if command -v "$1" &>/dev/null; then
    info "$1 已安装 ($(command -v "$1"))"
  else
    error "未找到 $1，请先安装后重试。"
  fi
}

check_cmd elixir
check_cmd mix
check_cmd python3

ELIXIR_VER=$(elixir --version | grep "Elixir" | awk '{print $2}')
info "Elixir $ELIXIR_VER"

# ─── 2. 环境变量检查 ──────────────────────────────────────────────────────────
step "2/5  检查环境变量"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  warn "OPENAI_API_KEY 未设置。"
  read -rp "      请输入 API Key（直接回车跳过，稍后手动设置）: " INPUT_KEY
  if [[ -n "$INPUT_KEY" ]]; then
    export OPENAI_API_KEY="$INPUT_KEY"
    # 写入 ~/.profile（如已存在则跳过）
    if ! grep -q "OPENAI_API_KEY" ~/.profile 2>/dev/null; then
      echo "export OPENAI_API_KEY=\"$INPUT_KEY\"" >> ~/.profile
      info "已追加到 ~/.profile（重新登录或 source ~/.profile 后生效）"
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

if [[ -f "$SCRIPTS_DIR/requirements.txt" ]]; then
  python3 -m pip install --quiet -r "$SCRIPTS_DIR/requirements.txt"
  info "Python 依赖安装完成"
else
  python3 -m pip install --quiet numpy scipy 2>/dev/null && info "numpy + scipy 已安装" || warn "pip 安装失败，请手动安装 numpy scipy"
fi

# ─── 4. Mix 依赖 & 编译 ────────────────────────────────────────────────────────
step "4/5  获取 Mix 依赖并编译"

cd "$(dirname "$PRIV_DIR")"   # 项目根目录
mix deps.get --quiet
info "deps.get 完成"
mix compile --quiet
info "编译完成"

# ─── 5. 工作目录 ─────────────────────────────────────────────────────────────
step "5/5  准备运行时目录"

WORK_DIR="${EAI_WORK_DIR:-/home/eai_agents}"
if [[ ! -d "$WORK_DIR" ]]; then
  mkdir -p "$WORK_DIR" && info "创建工作目录 $WORK_DIR" || warn "无法创建 $WORK_DIR，请手动创建或设置 EAI_WORK_DIR"
else
  info "工作目录已存在：$WORK_DIR"
fi

echo ""
echo -e "${GREEN}${BOLD}安装完成！${RESET}"
echo ""
echo "启动方式："
echo "  iex -S mix               # 交互式 shell"
echo "  mix run --no-halt        # 后台运行"
echo ""
echo "可选环境变量覆盖默认配置："
echo "  EAI_LLM_URL      LLM 接口地址（默认 DeepSeek）"
echo "  EAI_LLM_MODEL    模型名称"
echo "  EAI_LLM_TIMEOUT  请求超时（毫秒）"
echo "  EAI_WORK_DIR     PTY 工作目录根路径"
