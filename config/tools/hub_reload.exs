defmodule Eai.Tool.HubReload do
  @moduledoc """
  Re-reads all runtime-extensible config and re-registers hooks.

  Re-compiles every `config/hooks/*.exs` file and re-registers the hook pipeline.

  Does NOT restart the VM. Use after editing a hook file under `config/hooks/`.
  Does not pick up code-level changes to modules under `lib/` — those need
  a full VM restart.

  Returns a small JSON map describing what changed.
  """

  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "hub_reload",
        description: """
        Reload all runtime-extensible config without restarting the VM.

        Re-reads `config/hooks/*.exs` (re-registers the hook pipeline).

        Call this after editing a hook file. It does not pick up
        code-level changes to modules under `lib/` — those need a
        full VM restart.

        Returns a small JSON map describing what changed.
        """,
        parameters: %{
          type: "object",
          properties: %{},
          required: []
        }
      }
    }
  end

  @impl true
  def execute(_args, _pty_session_id, _chat_session_id) do
    hooks_result = Eai.Hub.Reloader.reload!()

    Jason.encode!(%{hooks: hooks_result})
  end
end
