defmodule Eai.Tool.HubReload do
  @moduledoc """
  Re-reads all runtime-extensible config and re-registers derived state.

  Two things happen in sequence:

    1. `Eai.Hub.Reloader.reload!/0` — re-compiles every
       `config/hooks/*.exs` file, re-registers the hook pipeline.
    2. `Eai.MCP.reload!/0` — re-scans `config/mcp_servers/*.exs`,
       honours the `# @mcp-metadata.enabled` flag for each, starts
       newly-enabled servers, stops newly-disabled ones, refreshes
       the `mcp_io` bridge entry in the tool registry.

  Does NOT restart the VM. Use after:
    - editing a hook file under `config/hooks/`
    - editing an MCP server file under `config/mcp_servers/`
    - changing an `mcp_<name>_use` flag via `set_config`
    - adding/removing an MCP server file

  Returns a small JSON map of what changed, suitable for the model
  to report back to the user.
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

        Re-reads `config/hooks/*.exs` (re-registers the hook pipeline)
        and `config/mcp_servers/*.exs` (starts/stops MCP servers
        according to each file's `# @mcp-metadata.enabled` flag,
        refreshes the `mcp_io` bridge in the tool registry).

        Call this after editing a hook file, an MCP server file, or
        after toggling an `mcp_<name>_use` flag via `set_config`. It
        does not pick up code-level changes to modules under `lib/`
        — those need a full VM restart.

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
    mcp_diff = Eai.MCP.reload!()

    Jason.encode!(%{hooks: hooks_result, mcp: mcp_diff})
  end
end
