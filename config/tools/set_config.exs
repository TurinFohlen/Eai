defmodule Eai.Tool.SetConfig do
  @moduledoc "运行时动态修改 eai 配置参数，立即对所有进程生效。"

  @behaviour Eai.Tool

  # 允许修改的参数白名单及其说明
  @allowed %{
    "poll_cooldown_ms" =>
      "轮询冷却时间（ms）。影响 get_task_result / get_subagent_result 的 sleep 间隔。默认 2000。",
    "pty_init_sleep_ms" => "PTY 启动后等待 shell 就绪的时间（ms）。任务卡住时可适当增大。默认 200。",
    "pty_ready_sleep_ms" => "PTY 发送命令后等待首字节输出的时间（ms）。默认 300。"
  }

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "set_config",
        description: """
        Dynamically update a runtime configuration parameter. Changes take effect
        immediately for all processes — no restart needed.

        **When to use each key:**

        - `poll_cooldown_ms` — Controls how long `get_task_result` and `get_subagent_result`
          sleep between polls. High values add artificial delay to every tool-result round-trip.
          Lower to speed up execute_script → get_task_result cycles (recommended floor: 500 ms).
          Raise when the LLM is polling too aggressively and burning API credits.

        - `pty_init_sleep_ms` — Wait after spawning a PTY shell before sending commands.
          If the shell needs more time to source .bashrc or load env vars, increase this.
          Default 200 ms, rarely needs adjustment.

        - `pty_ready_sleep_ms` — Wait after sending a command for the first byte of output.
          Increase if commands produce no output (shell still loading); decrease if terminal
          feels laggy (default 300 ms).

        Call with no arguments (or key = "list") to see current values.
        """,
        parameters: %{
          type: "object",
          properties: %{
            key: %{
              type: "string",
              description:
                "Parameter name. One of: #{Map.keys(@allowed) |> Enum.join(", ")}. Omit to list current values."
            },
            value: %{
              type: "integer",
              description: "New value (milliseconds, integer)."
            }
          },
          required: []
        }
      }
    }
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    key = Map.get(args, "key")

    cond do
      is_nil(key) or key == "list" ->
        current_values()
        |> Jason.encode!()

      not Map.has_key?(@allowed, key) ->
        %{
          error: "unknown key: #{key}",
          allowed: Map.keys(@allowed)
        }
        |> Jason.encode!()

      not is_integer(Map.get(args, "value")) ->
        %{error: "value must be an integer (ms)"}
        |> Jason.encode!()

      true ->
        value = Map.get(args, "value")
        apply_config(key, value)

        %{ok: true, key: key, value: value}
        |> Jason.encode!()
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  defp current_values do
    sandbox = Application.get_env(:eai, :sandbox, [])

    %{
      poll_cooldown_ms: Application.get_env(:eai, :poll_cooldown_ms),
      pty_init_sleep_ms: Keyword.get(sandbox, :pty_init_sleep_ms),
      pty_ready_sleep_ms: Keyword.get(sandbox, :pty_ready_sleep_ms)
    }
  end

  defp apply_config("poll_cooldown_ms", value) do
    Application.put_env(:eai, :poll_cooldown_ms, value)
  end

  defp apply_config(key, value) when key in ["pty_init_sleep_ms", "pty_ready_sleep_ms"] do
    atom_key = String.to_existing_atom(key)
    sandbox = Application.get_env(:eai, :sandbox, [])
    Application.put_env(:eai, :sandbox, Keyword.put(sandbox, atom_key, value))
  end
end
