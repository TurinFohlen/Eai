import Config

config :eai, :model_xingchen_glm_5_1,
  name: :xingchen_glm_5_1,
  model: "glm-5.1",
  # 星辰AI中转 — 可选 CDN:
  #   https://ai.centos.hk (Cloudflare)
  #   https://api.centos.hk (EO)
  #   https://frapi.centos.hk (三网优化)
  url: "https://ai.centos.hk/v1/chat/completions",
  provider: :openai_compat,
  api_key_env: "XINGCHEN_API_KEY",
  # 摇号池排队，留足 10 分钟
  receive_timeout: 600_000
