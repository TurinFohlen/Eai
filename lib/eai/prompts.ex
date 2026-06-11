defmodule Eai.Prompts do
  @moduledoc """
  Prompt registry. Loads from `config/prompts/*.exs` at runtime.

  Each file registers a single prompt entry under a `:prompt_<name>` key.
  Pattern mirrors `config/tools/`.
  """

  @prompts_dir Path.expand("config/prompts", File.cwd!())

  @type prompt_entry :: keyword()

  # ── Core queries ───────────────────────────────────────────────────

  @doc "All prompt entries, sorted by name."
  @spec all() :: [prompt_entry()]
  def all do
    case :persistent_term.get(:eai_prompts, :not_found) do
      :not_found -> load_prompts()
      entries -> entries
    end
  end

  @doc "Reload prompts from disk."
  @spec reload() :: [prompt_entry()]
  def reload, do: load_prompts()

  @doc "Default prompt (:momoka)."
  @spec default() :: prompt_entry()
  def default, do: get!(:momoka)

  @doc "Get by name atom, nil if missing."
  @spec get(atom() | nil) :: prompt_entry() | nil
  def get(nil), do: default()
  def get(name) when is_atom(name),
    do: Enum.find(all(), fn e -> e[:name] == name end)

  @doc "Get by name atom, raise if missing."
  @spec get!(atom()) :: prompt_entry()
  def get!(name) do
    case get(name) do
      nil ->
        raise ArgumentError,
          "unknown prompt #{inspect(name)}; available: #{inspect(names())}"
      entry -> entry
    end
  end

  @doc "All name atoms."
  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1[:name])

  @doc "Extract content string."
  @spec content(atom()) :: String.t()
  def content(name), do: get(name)[:content]

  @doc "Print name → description table."
  @spec list() :: :ok
  def list do
    IO.puts("\nAvailable prompts:\n")
    Enum.each(all(), fn e ->
      n = e[:name] |> inspect() |> String.pad_trailing(16)
      d = e[:description] || "(no description)"
      IO.puts("  #{n}  #{d}")
    end)
    IO.puts("")
  end

  # ── Internal ───────────────────────────────────────────────────────

  defp load_prompts do
    # Compile all .exs files in prompts directory
    with {:ok, files} <- File.ls(@prompts_dir) do
      files
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.each(fn file ->
        path = Path.join(@prompts_dir, file)

        path
        |> Config.Reader.read!()
        |> Enum.each(fn {app, kvs} ->
          Enum.each(kvs, fn {key, val} -> Application.put_env(app, key, val) end)
        end)
      end)
    end

    # Scan all :prompt_<name> keys from app env
    entries =
      Application.get_all_env(:eai)
      |> Enum.filter(fn
        {key, _} -> is_atom(key) and String.starts_with?(Atom.to_string(key), "prompt_")
        _ -> false
      end)
      |> Enum.map(fn {_, entry} -> entry end)
      |> Enum.sort_by(& &1[:name])

    :persistent_term.put(:eai_prompts, entries)
    entries
  end
end
