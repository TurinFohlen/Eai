# install_win.ps1 — eai 一键安装脚本（Windows PowerShell / pwsh）
# 使用方式：pwsh -ExecutionPolicy Bypass -File .\priv\install\install_win.ps1

$ErrorActionPreference = "Stop"

function Info  { param($m) Write-Host "[✓] $m" -ForegroundColor Green }
function Warn  { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Fatal { param($m) Write-Host "[✗] $m" -ForegroundColor Red; exit 1 }
function Step  { param($m) Write-Host "`n$m" -ForegroundColor Cyan }

# ─── 1. 依赖检查 ──────────────────────────────────────────────────────────────
Step "1/5  检查依赖"

foreach ($cmd in @("elixir", "mix", "python")) {
  if (Get-Command $cmd -ErrorAction SilentlyContinue) {
    Info "$cmd 已安装"
  } else {
    Fatal "未找到 $cmd，请先安装后重试。"
  }
}

# ─── 2. 环境变量检查 ──────────────────────────────────────────────────────────
Step "2/5  检查环境变量"

if (-not $env:OPENAI_API_KEY) {
  Warn "OPENAI_API_KEY 未设置。"
  $key = Read-Host "请输入 API Key（直接回车跳过）"
  if ($key) {
    $env:OPENAI_API_KEY = $key
    # 写入用户级环境变量（持久化）
    [System.Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $key, "User")
    Info "已写入用户环境变量（重新打开终端后生效）"
  } else {
    Warn "跳过。启动前请手动设置：`$env:OPENAI_API_KEY = 'sk-...'"
  }
} else {
  Info "OPENAI_API_KEY 已设置"
}

# ─── 3. Python 依赖 ───────────────────────────────────────────────────────────
Step "3/5  安装 Python 依赖"

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$privDir    = Split-Path -Parent $scriptDir
$scriptsDir = Join-Path $privDir "scripts"
$req        = Join-Path $scriptsDir "requirements.txt"

if (Test-Path $req) {
  python -m pip install --quiet -r $req
  Info "Python 依赖安装完成"
} else {
  python -m pip install --quiet numpy scipy
  Info "numpy + scipy 已安装"
}

# ─── 4. Mix 依赖 & 编译 ────────────────────────────────────────────────────────
Step "4/5  获取 Mix 依赖并编译"

$projectRoot = Split-Path -Parent $privDir
Set-Location $projectRoot

mix deps.get --quiet
Info "deps.get 完成"
mix compile --quiet
Info "编译完成"

# ─── 5. 工作目录 ─────────────────────────────────────────────────────────────
Step "5/5  准备运行时目录"

$workDir = if ($env:EAI_WORK_DIR) { $env:EAI_WORK_DIR } else { "$env:USERPROFILE\eai_agents" }
if (-not (Test-Path $workDir)) {
  New-Item -ItemType Directory -Path $workDir | Out-Null
  Info "创建工作目录 $workDir"
} else {
  Info "工作目录已存在：$workDir"
}

Write-Host ""
Write-Host "安装完成！" -ForegroundColor Green
Write-Host ""
Write-Host "启动方式："
Write-Host "  iex -S mix               # 交互式 shell"
Write-Host "  mix run --no-halt        # 后台运行"
Write-Host ""
Write-Host "可选环境变量覆盖（PowerShell）："
Write-Host '  $env:EAI_LLM_URL     = "https://..."'
Write-Host '  $env:EAI_LLM_MODEL   = "deepseek-v4-pro"'
Write-Host '  $env:EAI_LLM_TIMEOUT = "120000"'
Write-Host '  $env:EAI_WORK_DIR    = "C:\eai_agents"'