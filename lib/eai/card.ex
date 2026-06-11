defmodule Eai.Card do
  @moduledoc """
  Character Card V2 loader and registry.

  Cards live in `config/chara_cards/` as JSON files. Each card bundles:
  - system_prompt (role-level identity)
  - model, tools, pre_context (via extensions.eai)
  - Character Card V2 spec fields for SillyTavern compatibility

  ## Usage

      iex> Eai.Card.names()           # list available card atoms
      iex> Eai.Card.list()            # print name → description table
      iex> Eai.Card.get(:coder)       # fetch one card
      iex> Eai.Chat.talk(chara_card: :frontend_dev, content: "...")
  """

  @cards_dir Path.expand("config/chara_cards", File.cwd!())

  # ── Public API ──────────────────────────────────────────────────────

  @doc "Returns all loaded card entries as keyword lists."
  @spec all() :: [keyword()]
  def all do
    case :persistent_term.get(:eai_chara_cards, :not_found) do
      :not_found -> load_cards()
      cards -> cards
    end
  end

  @doc "Reload cards from disk (useful after editing a card file)."
  @spec reload() :: [keyword()]
  def reload, do: load_cards()

  @doc "Return card name atoms."
  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1[:name])

  @doc "Get card by name atom. Returns nil if not found."
  @spec get(atom()) :: keyword() | nil
  def get(name) when is_atom(name) do
    Enum.find(all(), fn c -> c[:name] == name end)
  end

  @doc "Get card by name atom, raise if missing."
  @spec get!(atom()) :: keyword()
  def get!(name) do
    case get(name) do
      nil -> raise ArgumentError, "unknown card #{inspect(name)}; available: #{inspect(names())}"
      card -> card
    end
  end

  @doc "Print name → description table."
  @spec list() :: :ok
  def list do
    IO.puts("\nAvailable chara cards:\n")
    Enum.each(all(), fn c ->
      name = c[:name] |> inspect() |> String.pad_trailing(20)
      desc = c[:description] || "(no description)"
      IO.puts("  #{name}  #{desc}")
    end)
    IO.puts("")
  end

  @doc """
  Build run_opts from a card for Direct.run / Chat.talk.

  Returns a keyword list with :model, :system_prompt (overrides),
  and :card_pre_context (raw messages list to inject).
  """
  @spec to_opts(keyword()) :: keyword()
  def to_opts(card) do
    opts = []
    opts = if card[:model], do: [{:model, card[:model]} | opts], else: opts
    opts = if card[:system_prompt], do: [{:card_system_prompt, card[:system_prompt]} | opts], else: opts
    opts = if card[:tools], do: [{:card_tools, card[:tools]} | opts], else: opts
    opts = if card[:pre_context], do: [{:card_pre_context, card[:pre_context]} | opts], else: opts
    opts
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp load_cards do
    cards =
      case File.ls(@cards_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.sort()
          |> Enum.flat_map(fn file ->
            path = Path.join(@cards_dir, file)
            case File.read(path) do
              {:ok, body} -> parse_card(body, file)
              {:error, _} -> []
            end
          end)

        {:error, _} ->
          []
      end

    :persistent_term.put(:eai_chara_cards, cards)
    cards
  end

  defp parse_card(body, source_file) do
    case Jason.decode(body) do
      {:ok, json} ->
        card = extract_card(json, source_file)
        if card, do: [card], else: []

      {:error, reason} ->
        require Logger
        Logger.error("Eai.Card: bad JSON in #{source_file}: #{inspect(reason)}")
        []
    end
  end

  defp extract_card(json, _source_file) do
    data = json["data"] || %{}
    ext = data["extensions"] || %{}
    eai_ext = ext["eai"] || %{}

    name_str = data["name"] || ""
    system_prompt = data["system_prompt"] || ""
    description = data["description"] || ""

    model_raw = eai_ext["model"]
    model = if model_raw, do: String.to_atom(model_raw)

    tools = eai_ext["tools"]
    prompt_ref_raw = eai_ext["prompt"]
    prompt_ref = if prompt_ref_raw, do: String.to_atom(prompt_ref_raw)

    pre_context_b64 = eai_ext["pre_context"]

    # Decode pre_context if present
    pre_context =
      if pre_context_b64 && pre_context_b64 != "" do
        try do
          pre_context_b64
          |> Base.decode64!()
          |> :zlib.gunzip()
          |> :erlang.binary_to_term()
        rescue
          _ -> nil
        end
      end

    card_name =
      if name_str != "",
        do: String.to_atom(name_str),
        else: nil

    if card_name do
      [
        name: card_name,
        description: description,
        system_prompt: system_prompt,
        model: model,
        prompt: prompt_ref,
        tools: tools,
        pre_context: pre_context
      ]
    end
  end
end
