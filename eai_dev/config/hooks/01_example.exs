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
  @doc "Opt in to all pre-events on write_to_session; ignore everything else."
  def interest(:pre, tool_name, _payload) do
    # Keep interest/3 fast — no I/O, no blocking calls.
    # The pipeline calls this for every hook × every tool call.
    String.contains?(tool_name, "write_to_session")
  end

  def interest(_event, _tool, _payload), do: false

  @impl true
  @doc """
  Block writes containing shell-nuke patterns; pass everything else.

  In a real guard you might also use Task.await/2 with a timeout for
  any external validation (e.g. an allowlist service):

      task = Task.async(fn -> check_allowlist(args) end)
      case Task.await(task, 500) do
        :allowed -> :ok
        :denied  -> {:block, "not in allowlist"}
      end
  """
  def verdict(:pre, _tool_name, %{args: [cmd | _]}) when is_binary(cmd) do
    dangerous_patterns = ["rm -rf /", ":(){ :|:&};:", "dd if=/dev/zero"]

    if Enum.any?(dangerous_patterns, &String.contains?(cmd, &1)) do
      {:block, "ExampleHook: blocked dangerous shell pattern in write_to_session"}
    else
      :ok
    end
  end

  def verdict(:pre, _tool_name, _payload), do: :ok

  @impl true
  def verdict(:post, _tool_name, _payload, _result), do: :ok
end
