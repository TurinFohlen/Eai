defmodule Eai.Tool.ListCharaCards do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "list_chara_cards",
        description:
          "List all available character cards with name, description, model, and tools. " <>
            "Optionally filter by a search term matching name or description.",
        parameters: %{
          type: "object",
          properties: %{
            filter: %{
              type: "string",
              description:
                "Optional case-insensitive search term to filter cards by name or description."
            }
          },
          required: []
        }
      }
    }
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    filter = args["filter"] || ""

    cards =
      Eai.Card.all()
      |> Enum.map(fn c ->
        %{
          name: c[:name],
          description: c[:description],
          model: c[:model],
          tools: c[:tools] || []
        }
      end)
      |> then(fn all ->
        if filter == "" do
          all
        else
          term = String.downcase(filter)

          Enum.filter(all, fn c ->
            String.contains?(String.downcase(to_string(c[:name])), term) or
              String.contains?(String.downcase(c[:description] || ""), term)
          end)
        end
      end)
      |> Enum.sort_by(&to_string(&1[:name]))

    Jason.encode!(%{count: length(cards), cards: cards})
  end
end
