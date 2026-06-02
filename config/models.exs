import Config

# ── 模型注册表 ─────────────────────────────────────────────────────────────
#
# 每个条目是一个带 :name atom 键的关键字列表。
# 列表顺序即优先级：第一个为系统默认模型。
#
# 必填字段
#   :name     - atom，在 iex 中用作 Eai.Chat.talk(model: :name) 的参数
#   :model    - 实际传给 API 的模型字符串
#   :url      - 聊天补全接口地址
#   :provider - :openai_compat | :anthropic（决定鉴权头格式与消息体结构）
#
# 可选字段
#   :api_key_env   - 读取 API Key 的环境变量名（默认 "OPENAI_API_KEY"）
#   :vision        - true 表示此模型支持图像输入（用于 read_media_file）
#   :reasoning_effort - "low" | "medium" | "high"（仅部分模型支持）
#   :receive_timeout  - 毫秒，覆盖全局超时

config :eai, :models, [
  # ── 主力对话模型（默认）─────────────────────────────────────────
  [
    name:             :deepseek,
    model:            "deepseek-v4-pro",
    url:              "https://api.deepseek.com/chat/completions",
    provider:         :openai_compat,
    api_key_env:      "DEEPSEEK_API_KEY",
    reasoning_effort: "high",
    receive_timeout:  120_000
  ],

  # ── OpenAI ──────────────────────────────────────────────────────
  [
    name:            :gpt4o,
    model:           "gpt-4o",
    url:             "https://api.openai.com/v1/chat/completions",
    provider:        :openai_compat,
    api_key_env:     "OPENAI_API_KEY",
    vision:          true,
    receive_timeout: 60_000
  ],
  [
    name:            :gpt4o_mini,
    model:           "gpt-4o-mini",
    url:             "https://api.openai.com/v1/chat/completions",
    provider:        :openai_compat,
    api_key_env:     "OPENAI_API_KEY",
    vision:          true,
    receive_timeout: 30_000
  ],

  # ── Anthropic ───────────────────────────────────────────────────
  [
    name:            :claude_opus,
    model:           "claude-opus-4-6",
    url:             "https://api.anthropic.com/v1/messages",
    provider:        :anthropic,
    api_key_env:     "ANTHROPIC_API_KEY",
    vision:          true,
    receive_timeout: 120_000
  ],
  [
    name:            :claude_sonnet,
    model:           "claude-sonnet-4-6",
    url:             "https://api.anthropic.com/v1/messages",
    provider:        :anthropic,
    api_key_env:     "ANTHROPIC_API_KEY",
    vision:          true,
    receive_timeout: 60_000
  ],

  # ── 本地 / 自托管（Ollama） ─────────────────────────────────────
  [
    name:            :llava,
    model:           "llava",
    url:             "http://localhost:11434/v1/chat/completions",
    provider:        :openai_compat,
    api_key_env:     nil,           # Ollama 无需 key
    vision:          true,
    receive_timeout: 120_000
  ],
  [
    name:            :llama3,
    model:           "llama3",
    url:             "http://localhost:11434/v1/chat/completions",
    provider:        :openai_compat,
    api_key_env:     nil,
    receive_timeout: 120_000
  ],
]
