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

  @doc """
  Get all registered character cards from config/chara_cards/.

  Cards are loaded from `:persistent_term` cache (set by `reload/0`).

  ## Returns
      List of card keyword lists with keys: `:name`, `:description`, `:model`, `:system_prompt`, `:tools`, `:pre_context`
  """
  @spec all() :: [keyword()]
  def all do
    case :persistent_term.get(:eai_chara_cards, :not_found) do
      :not_found -> load_cards()
      cards -> cards
    end
  end

  @doc """
  Force reload character card registry from disk.

  Useful after editing a `.json` file in `config/chara_cards/`.

  ## Returns
      List of all reloaded card entries.
  """
  @spec reload() :: [keyword()]
  def reload, do: load_cards()

  @doc """
  Get list of all registered card names (atoms).

  ## Example
      iex> Eai.Card.names()
      [:backend_engineer, :frontend_dev, :research_analyst]
  """
  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1[:name])

  @doc """
  Look up card by `:name` atom.

  Returns `nil` if not found.

  ## Options
    * `name` (atom) — Card name.

  ## Example
      iex> Eai.Card.get(:backend_engineer)
      [name: :backend_engineer, description: "...", model: :claude_opus, system_prompt: "...", ...]
  """
  @spec get(atom()) :: keyword() | nil
  def get(name) when is_atom(name) do
    Enum.find(all(), fn c -> c[:name] == name end)
  end

  @doc """
  Look up card by `:name` atom. Raises if not found.

  ## Options
    * `name` (atom) — Card name.

  ## Raises
      ArgumentError if card not found.
  """
  @spec get!(atom()) :: keyword()
  def get!(name) do
    case get(name) do
      nil -> raise ArgumentError, "unknown card #{inspect(name)}; available: #{inspect(names())}"
      card -> card
    end
  end

  @doc """
  Print formatted table of available character cards and descriptions.

  ## Example
      iex> Eai.Card.list()
      
      Available chara cards:
      
        :backend_engineer      Scalability-focused, error handling specialist
        :frontend_dev          UI/UX focused, accessibility aware
        :research_analyst      Structured reasoning, hypothesis-driven
  """
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
  Convert card to options for `Chat.talk/1` or `LLM.Direct.run/3`.

  Returns keyword list extracting card fields:
  - `:model` — if card specifies a model override
  - `:card_system_prompt` — role-level system prompt
  - `:card_tools` — allowlist of tool names
  - `:card_pre_context` — pre-loaded context messages (for prefix caching)

  ## Options
    * `card` — Card keyword list from `Card.get/1` or `Card.all/0`.

  ## Example
      iex> card = Eai.Card.get!(:backend_engineer)
      iex> Eai.Card.to_opts(card)
      [model: :claude_opus, card_system_prompt: "You are a backend...", card_tools: ["execute_script", "call_subagent"]]
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
          |> Enum.flat_map(&load_card_file/1)

        {:error, _} ->
          []
      end

    :persistent_term.put(:eai_chara_cards, cards)
    cards
  end

  defp load_card_file(file) do
    path = Path.join(@cards_dir, file)

    case File.read(path) do
      {:ok, body} -> parse_card(body, file)
      {:error, _} -> []
    end
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
    {name_str, system_prompt, description} = extract_card_fields(json)
    {model, tools, prompt_ref, pre_context} = extract_eai_fields(json)

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

  defp extract_card_fields(json) do
    data = json["data"] || %{}
    name_str = data["name"] || ""
    system_prompt = data["system_prompt"] || ""
    description = data["description"] || ""
    {name_str, system_prompt, description}
  end

  defp extract_eai_fields(json) do
    data = json["data"] || %{}
    ext = data["extensions"] || %{}
    eai_ext = ext["eai"] || %{}

    model_raw = eai_ext["model"]
    model = if model_raw, do: String.to_atom(model_raw)

    tools = eai_ext["tools"]
    prompt_ref_raw = eai_ext["prompt"]
    prompt_ref = if prompt_ref_raw, do: String.to_atom(prompt_ref_raw)

    pre_context = decode_pre_context(eai_ext["pre_context"])

    {model, tools, prompt_ref, pre_context}
  end

  defp decode_pre_context(nil), do: nil
  defp decode_pre_context(""), do: nil

  defp decode_pre_context(pre_context_b64) do
    pre_context_b64
    |> Base.decode64!()
    |> :zlib.gunzip()
    |> :erlang.binary_to_term()
  rescue
    _ -> nil
  end
end
