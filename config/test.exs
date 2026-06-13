import Config

config :eai, :llm,
  url: "https://api.deepseek.com/chat/completions",
  model: "deepseek-v4-pro",
  receive_timeout: 10_000

config :eai, :sandbox,
  work_dir_root: System.tmp_dir!(),
  script_tmp_prefix: System.tmp_dir!() <> "/eai_test_",
  exec_sync_timeout: 5_000,
  sentinel_left: "___EAI_START___",
  sentinel_right: "___EAI_END___"