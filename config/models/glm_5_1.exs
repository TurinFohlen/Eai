import Config

config :eai, :model_glm_5_1,
  name: :glm_5_1,
  model: "glm-5.1",
  url: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
  provider: :openai_compat,
  api_key_env: "ZHIPU_API_KEY",
  receive_timeout: 300_000
