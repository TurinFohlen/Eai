defmodule Eai.Sandbox do
  @moduledoc "Behaviour for PTY-like command execution sandbox"

  @callback exec_async(pty_session_id :: String.t(), command :: String.t(), task_id :: String.t() | nil) ::
              {:ok, task_id :: String.t()} | {:error, term}
end