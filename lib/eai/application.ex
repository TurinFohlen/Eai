defmodule Eai.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    attach_telemetry()

    children =
      if Application.get_env(:eai, :start_application, true) do
        IO.puts("╔══════════════════════════════════════════════════╗")
        IO.puts("║  🤖 EAI  v0.1 — AI Agent Framework              ║")
        IO.puts("║  Type Eai.help() for full documentation.        ║")
        IO.puts("║  Type Eai.Chat.talk() to chat.                  ║")
        IO.puts("╚══════════════════════════════════════════════════╝\n")

        api_children =
          if Application.get_env(:eai, :api, [])[:enabled] != false do
            [api_child_spec()]
          else
            []
          end

        [
          {Phoenix.PubSub, name: Eai.Naming.pubsub()},
          Eai.Cache.Cache,
          Eai.Sandbox.PTYPool,
          {Eai.Chat, []}
        ] ++ api_children
      else
        []
      end

    opts = [strategy: :one_for_one, name: Eai.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Load hooks asynchronously after supervisor is up (decision #4 + #9).
    # 500ms delay ensures all children (Cache, PTYPool, etc.) are ready before
    # Reloader tries to compile hook files that may reference them.
    # Task.start (not Task.async) — fire-and-forget, no supervision needed.
    if Application.get_env(:eai, :start_application, true) do
      Task.start(&load_hooks/0)
    end

    result
  end

  defp load_hooks do
    :timer.sleep(500)
    Eai.Hub.reload!()
    count = length(:persistent_term.get(:eai_hooks, []))

    if count > 0 do
      IO.puts("🪝  #{count} hook(s) loaded from config/hooks/")
    end
  end

  defp api_child_spec do
    api_config = Application.get_env(:eai, :api, [])
    port = Keyword.get(api_config, :port, 4000)
    host = Keyword.get(api_config, :host, "0.0.0.0")

    IO.puts("🌐 Eai API listening on http://#{host}:#{port}")
    IO.puts("   POST /v1/chat/completions  — OpenAI-compatible chat")
    IO.puts("   GET  /v1/models            — list models")
    IO.puts("   GET  /health               — health check")

    bandit_opts = [scheme: :http, plug: Eai.API.Router, port: port]

    bandit_opts =
      case parse_host(host) do
        {:ok, ip} -> Keyword.put(bandit_opts, :ip, ip)
        :error -> bandit_opts
        other -> Keyword.put(bandit_opts, :ip, other)
      end

    %{
      id: Eai.API,
      start: {Bandit, :start_link, [bandit_opts]},
      type: :supervisor
    }
  end

  defp parse_host(host) when is_binary(host) do
    host |> String.to_charlist() |> :inet.parse_address()
  end

  defp parse_host(_host), do: :error

  defp attach_telemetry do
    events = Enum.map(Application.get_env(:eai, :telemetry_events, []), fn {e, _} -> e end)

    :telemetry.attach_many(
      "eai-unified-handler",
      events,
      &Eai.TelemetryHandler.handle_event/4,
      nil
    )
  end
end
