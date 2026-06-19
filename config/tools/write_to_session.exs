defmodule Eai.Tool.WriteToSession do
  @behaviour Eai.Tool

  @right_sentinel Application.compile_env(:eai, [:sandbox, :sentinel_right])

  @description """
  Write raw bytes directly to a PTY session's stdin, bypassing the sentinel wrapper.
  Use for interactive input (e.g. answering [Y/n] prompts, navigating pagers/editors).
  Do NOT use for normal script execution — use execute_script for that.

  Supported escape sequences (write them literally in the input string):

    \\\\n      newline
    \\\\r      carriage return
    \\\\t      tab
    \\\\e      ESC (ANSI escape prefix, e.g. \\\\e[A for up arrow)
    \\\\x1b    ESC (hex form, same as \\\\e)

  Arrow keys (send after ESC):
    \\\\e[A    up
    \\\\e[B    down
    \\\\e[C    right
    \\\\e[D    left

  Extended keys:
    \\\\e[1~   Home
    \\\\e[4~   End
    \\\\e[5~   PgUp
    \\\\e[6~   PgDn
    \\\\e[2~   Insert
    \\\\e[3~   Delete

  Control characters:
    \\\\x03    Ctrl+C (interrupt running task)
    \\\\x04    Ctrl+D (EOF)
    \\\\x1a    Ctrl+Z (suspend)
    \\\\x07    Ctrl+G (bell)
    \\\\x08    Ctrl+H (backspace)
    \\\\x7f    DEL (delete)

  Common key combos:
    q          quit less/more/man
    Space      page down in pager
    :q!\\n      quit vim
    i          enter insert mode (vim)
    Esc        exit insert mode (vim)

  **Example:** interrupt a stuck task:
    input: "\\\\x03\\\\necho #{@right_sentinel}\\\\n"

  **Example:** navigate less pager down 2 lines then quit:
    input: "\\\\e[B\\\\e[Bq"

  **Example:** quit vim:
    input: "\\\\x1b:q!\\\\n"
  """

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "write_to_session",
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            input: %{
              type: "string",
              description:
                "String to write. Supports escape sequences: \\\\n \\\\r \\\\t \\\\e \\\\x1b \\\\x03(Ctrl+C) \\\\x04(Ctrl+D) \\\\x1a(Ctrl+Z). Arrow keys: \\\\e[A(B,C,D). Extended: \\\\e[1~(Home) \\\\e[4~(End) \\\\e[5~(PgUp) \\\\e[6~(PgDn)."
            },
            pty_session_id: %{type: "string", description: "PTY session ID (default: 'default')."}
          },
          required: ["input"]
        }
      }
    }
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    input = Map.get(args, "input", "")
    target = Map.get(args, "pty_session_id", pty_session_id)
    raw = unescape(input)

    if Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(:debug_pty_output) do
      IO.puts(
        "\n=== WRITE_TO_SESSION [#{target}] ===\ninput: #{inspect(input)}\nraw:   #{inspect(raw)}\n=== END WRITE ==="
      )
    end

    Eai.PTY.write_raw(target, raw)

    %{status: "ok", wrote: inspect(raw)}
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp unescape(input) do
    input
    # ANSI / extended keys (process before single chars to avoid partial matches)
    # Home
    |> String.replace("\\e[1~", "\e[1~")
    # Insert
    |> String.replace("\\e[2~", "\e[2~")
    # Delete
    |> String.replace("\\e[3~", "\e[3~")
    # End
    |> String.replace("\\e[4~", "\e[4~")
    # PgUp
    |> String.replace("\\e[5~", "\e[5~")
    # PgDn
    |> String.replace("\\e[6~", "\e[6~")
    # Up
    |> String.replace("\\e[A", "\e[A")
    # Down
    |> String.replace("\\e[B", "\e[B")
    # Right
    |> String.replace("\\e[C", "\e[C")
    # Left
    |> String.replace("\\e[D", "\e[D")
    # Home (alt form)
    |> String.replace("\\e[H", "\e[H")
    # End (alt form)
    |> String.replace("\\e[F", "\e[F")
    # ESC variants
    |> String.replace("\\x1b", "\x1b")
    |> String.replace("\\e", "\e")
    # Control characters
    |> String.replace("\\x03", <<3>>)
    |> String.replace("\\x04", <<4>>)
    |> String.replace("\\x07", <<7>>)
    |> String.replace("\\x08", <<8>>)
    |> String.replace("\\x1a", <<26>>)
    |> String.replace("\\x7f", <<127>>)
    # Common whitespace (process last to avoid interfering with above)
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
  end
end
