defmodule Eai.Hook.Example do
  @moduledoc """
  Example hook: demonstrates pre-hook block and modify patterns.

  This file is a template for writing your own hooks. Copy it to
  `config/hooks/NN_yourname.exs`, change the module name and logic,
  then call `Eai.Hub.reload!()`.

  ## Patterns shown here

  1. **Block** — reject a call before it runs (e.g. dangerous command guard)
  2. **Modify** — transform args before execution (e.g. arg normalization)
  3. **Timeout advice** — hooks should keep `interest/3` fast and bound
     any slow work with `Task.await/2`

  ## Priority

  `use Eai.Hook, priority: 10` means this hook runs first among hooks with
  higher priority numbers. Lower integer = earlier in pipeline.
  """

  use Eai.Hook, priority: 10

  @impl true
  @doc """
  Opt in to all pre-events whose tool_name contains "write_to_session".

  `tool_name` is the full Elixir module string (e.g. "Elixir.Eai.Tool.WriteToSession").
  Use `String.contains?/2` with a short substring to avoid coupling on the full module path.
  """
  def interest(:pre, tool_name, _payload) do
    String.contains?(tool_name, "WriteToSession")
  end

  def interest(_event, _tool_name, _payload), do: false

  @impl true
  @doc """
  Block writes containing shell-nuke patterns.

  ## Args format

  EAI tools receive their arguments in two different shapes:

  1. Map-wrapped (most tools including write_to_session):
     `[%{"input" => "user content"}, pty_session_id, chat_session_id]`

  2. Bare string (legacy / simple tools):
     `["plain string", pty_session_id, chat_session_id]`

  This clause handles both so the guard works regardless of how the tool is called.
  """
  def verdict(:pre, _tool_name, %{args: [%{"input" => cmd} | _]}) when is_binary(cmd) do
    check_dangerous(cmd)
  end

  def verdict(:pre, _tool_name, %{args: [cmd | _]}) when is_binary(cmd) do
    check_dangerous(cmd)
  end

  def verdict(:pre, _tool_name, _payload), do: :ok

  @impl true
  def verdict(:post, _tool_name, _payload, _result), do: :ok

  # ── private ──────────────────────────────────────────────────────────

  @dangerous_patterns ["rm -rf /", ":(){ :|:&};:", "dd if=/dev/zero"]

  defp check_dangerous(cmd) do
    if Enum.any?(@dangerous_patterns, &String.contains?(cmd, &1)) do
      {:block, "ExampleHook: blocked dangerous shell pattern"}
    else
      :ok
    end
  end
end
