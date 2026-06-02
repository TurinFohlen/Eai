defmodule Eai.Tool.WriteToSession do
  @behaviour Eai.Tool
  alias Eai.Tool.Helpers

  @right_sentinel Application.compile_env(:eai, [:sandbox, :sentinel_right])

  @description """
  Write raw bytes directly to a PTY session's stdin, bypassing the sentinel wrapper.
  Use for interactive input (e.g. answering [Y/n] prompts) or for sending control characters.
  Do NOT use for normal script execution — use execute_script for that.

  Supported escape sequences (write them literally in the input string):
    \\\\n   newline
    \\\\r   carriage return
    \\\\t   tab
    \\\\x03 Ctrl+C (interrupt running task)
    \\\\x04 Ctrl+D (EOF)
    \\\\x1a Ctrl+Z

  **Example:** to interrupt a running task, send Ctrl+C then echo the right sentinel:
    input: "\\\\x03\\\\necho #{@right_sentinel}\\\\n"
  """

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "write_to_session",
      description: @description,
      parameters: %{type: "object",
        properties: %{
          input:          %{type: "string", description: "String to write, using escape sequences for control chars (e.g. \"y\\\\n\", \"\\\\x03\\\\n\")."},
          pty_session_id: %{type: "string", description: "PTY session ID (default: 'default')."}
        },
        required: ["input"]
      }
    }}
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    input  = Map.get(args, "input", "")
    target = Map.get(args, "pty_session_id", pty_session_id)
    raw    = unescape(input)
    if Helpers.sandbox_cfg(:debug_pty_output) do
      IO.puts("\n=== WRITE_TO_SESSION [#{target}] ===\ninput: #{inspect(input)}\nraw:   #{inspect(raw)}\n=== END WRITE ===")
    end
    Eai.Naming.pool().write_raw(target, raw)
    %{status: "ok", wrote: inspect(raw)}
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp unescape(input) do
    input
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
    |> String.replace("\\x03", <<3>>)
    |> String.replace("\\x04", <<4>>)
    |> String.replace("\\x1a", <<26>>)
  end
end
