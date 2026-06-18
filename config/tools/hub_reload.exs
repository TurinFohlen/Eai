defmodule Eai.Tool.HubReload do
  @moduledoc """
  Re-reads all runtime-extensible config and re-registers hooks, models, and cards.

  Re-compiles every `config/hooks/*.exs` file and re-registers the hook pipeline.
  Re-reads `config/models/*.exs` and updates the model registry.
  Re-reads `config/chara_cards/*.json` and updates the card registry.

  Does NOT restart the VM. Use after editing a hook, model, or card file.
  Does not pick up code-level changes to modules under `lib/` — those need
  a full VM restart.

  Returns a JSON map describing what was reloaded.
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

        Re-reads `config/hooks/*.exs` (re-registers the hook pipeline),
        `config/models/*.exs` (updates model registry), and
        `config/chara_cards/*.json` (updates card registry).

        Call this after editing a hook, model, or character card file.
        It does not pick up code-level changes to modules under `lib/` — those need a
        full VM restart.

        Returns a JSON map describing what was reloaded.
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
    models = Eai.Models.reload()
    cards = Eai.Card.reload()

    Jason.encode!(%{
      hooks: hooks_result,
      models: %{count: length(models), names: Enum.map(models, & &1[:name])},
      cards: %{count: length(cards), names: Enum.map(cards, & &1[:name])}
    })
  end
end
