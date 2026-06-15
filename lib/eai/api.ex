defmodule Eai.API do
  @moduledoc """
  HTTP API for Eai — OpenAI-compatible Chat Completions endpoint.

  Exposes eai's LLM engine over HTTP so external tools (chatgpt-on-wechat,
  custom bots, n8n, etc.) can use it as a drop-in OpenAI replacement.

  ## Endpoints

  | Method | Path                      | Description                        |
  |--------|---------------------------|------------------------------------|
  | GET    | /health                   | Health check + version             |
  | GET    | /v1/models                | List available LLM models          |
  | POST   | /v1/chat/completions      | Chat completions (OpenAI format)   |
  | GET    | /v1/tools                 | List MCP tools                     |
  | GET    | /v1/mcp/status            | MCP server status                  |

  ## Configuration

      config :eai, :api,
        port: 4000,          # integer or :auto / "auto"
        host: "0.0.0.0"

  ## Usage

      # Start manually (auto-started with Application)
      Eai.API.start()

      # curl example
      curl -X POST http://localhost:4000/v1/chat/completions \\
        -H "Content-Type: application/json" \\
        -d '{"model":"deepseek","messages":[{"role":"user","content":"hello"}]}'
  """

  def start do
    port = Application.get_env(:eai, :api, []) |> Keyword.get(:port, 4000)
    port = Eai.Application.resolve_port(port)
    host = Application.get_env(:eai, :api, []) |> Keyword.get(:host, "0.0.0.0")

    IO.puts("🌐 Eai API listening on http://#{host}:#{port}")
    IO.puts("   POST /v1/chat/completions  — OpenAI-compatible chat")
    IO.puts("   GET  /v1/models            — list models")
    IO.puts("   GET  /v1/tools             — list MCP tools")
    IO.puts("   GET  /v1/mcp/status        — MCP server status")
    IO.puts("   GET  /health               — health check")

    Bandit.start_link(
      scheme: :http,
      plug: Eai.API.Router,
      port: port,
      ip: parse_host(host)
    )
  end

  defp parse_host(host) when is_binary(host) do
    host |> String.to_charlist() |> :inet.parse_address() |> elem(1)
  end

  defp parse_host(host), do: host
end
