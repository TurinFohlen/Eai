import Config

# API Key 校验已下放到模型层（Eai.Models.api_key/1），
# 仅在实际发起请求时按模型的 api_key_env 字段按需读取，
# 这样可以同时支持多个供应商（DeepSeek、OpenAI、Anthropic、Ollama 等），
# 且未使用的供应商无需提前配置密钥。

# ── Sandbox 环境变量覆盖（可选）────────────────────────────────────
if work_dir = System.get_env("EAI_WORK_DIR") do
  config :eai, :sandbox, work_dir_root: work_dir
end

if debug_pty = System.get_env("EAI_DEBUG_PTY") do
  config :eai, :sandbox, debug_pty_output: debug_pty in ["1", "true", "yes"]
end

if priv = System.get_env("EAI_PRIV_SRC") do
  config :eai, :sandbox, priv_src: priv
else
  config :eai, :sandbox, priv_src: Path.expand("priv", File.cwd!())
end

# ── Mounts ────────────────────────────────────────────────────
# 每个 agent 创建时自动符号链接到其工作目录
default_mounts = Application.get_env(:eai, :sandbox, [])[:default_mounts] || []

mounts =
  if extra = System.get_env("EAI_MOUNTS") do
    default_mounts ++ String.split(extra, ":")
  else
    default_mounts
  end

config :eai, :sandbox, mounts: mounts

# ── MCP Servers: 合并加载 config/mcp_servers/*.exs ──────────────────────────
# 每个文件返回裸列表 [{:server_id, [...opts]}]，flat_map 合并后写入 app env。
# 与 Eai.MCP.reread_configs/0 逻辑一致，boot 和热重载路径统一。
mcp_config_dir = Path.expand("config/mcp_servers", File.cwd!())

if File.dir?(mcp_config_dir) do
  merged =
    mcp_config_dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn file ->
      {result, _} = Code.eval_file(file)
      result
    end)

  config :eai, :mcp_servers, merged
end

# ── API Port: auto → random free port ───────────────────────────────────────
# When config :eai, :api, port: is :auto or "auto", pick a random port in
# 1024–49151, verify it's free, and put the resolved integer back into the
# application env. lib/ code only ever sees an integer.

# Define helper module inline — runtime.exs is evaluated at app start,
# so this module lives in the BEAM for the lifetime of the node.
defmodule Eai.RuntimeHelper do
  @moduledoc false

  def pick_free_port(0), do: raise("could not find a free port after 10 attempts")

  def pick_free_port(retries) do
    port = 1024 + :rand.uniform(49151 - 1024)

    case :gen_tcp.listen(0, [{:port, port}, :inet, {:ip, {127, 0, 0, 1}}]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        port

      {:error, :eaddrinuse} ->
        pick_free_port(retries - 1)

      {:error, reason} ->
        raise "unexpected error probing port #{port}: #{inspect(reason)}"
    end
  end
end

api_config = Application.get_all_env(:eai)[:api] || []
api_port = api_config[:port]

if api_port in [:auto, "auto"] do
  port = Eai.RuntimeHelper.pick_free_port(10)
  new_api = Keyword.put(api_config, :port, port)
  Application.put_env(:eai, :api, new_api)
end
