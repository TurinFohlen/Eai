defmodule Eai.Sandbox do
  @moduledoc "Behaviour for PTY-like command execution sandbox"

  @callback exec_async(agent_id :: String.t(), command :: String.t(), task_id :: String.t() | nil) ::
              {:ok, task_id :: String.t()} | {:error, term}
  @callback exec_sync(agent_id :: String.t(), command :: String.t(), timeout_ms :: non_neg_integer()) ::
              {:ok, output :: String.t()} | {:error, term}
  @callback kill(agent_id :: String.t()) :: :ok
end
