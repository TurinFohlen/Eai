defmodule Eai.Prompts do
  @moduledoc """
  Prompt registry. Loads from `config/prompts/*.exs` at runtime.

  Each file registers a single prompt entry under a `:prompt_<name>` key.
  Pattern mirrors `config/tools/`.
  """

  @prompts_dir Path.expand("config/prompts", File.cwd!())

  @type prompt_entry :: keyword()

  # ── Core queries ───────────────────────────────────────────────────

  @doc """
  Get all registered prompts from config.

  Loads from `:persistent_term` cache (set by `reload/0`).

  ## Returns
      List of prompt entries with keys: `:name`, `:content`, `:description`, etc.
  """
  @spec all() :: [prompt_entry()]
  def all do
    case :persistent_term.get(:eai_prompts, :not_found) do
      :not_found -> load_prompts()
      entries -> entries
    end
  end

  @doc """
  Force reload prompt registry from config/prompts.exs.

  Returns all reloaded prompt entries.
  """
  @spec reload() :: [prompt_entry()]
  def reload, do: load_prompts()

  @doc """
  Get default prompt (`:momoka` — helpful generalist).

  Used when no explicit `:prompt` is provided to `Chat.talk/1`.
  """
  @spec default() :: prompt_entry()
  def default, do: get!(:momoka)

  @doc """
  Look up prompt by `:name` atom.

  Returns `nil` if not found. `nil` input returns default prompt.

  ## Options
    * `name` (atom) — Prompt name: `:momoka`, `:coder`, `:analyst`, etc.

  ## Example
      iex> Eai.Prompts.get(:coder)
      %{name: :coder, content: "You are a code expert...", ...}
  """
  @spec get(atom() | nil) :: prompt_entry() | nil
  def get(nil), do: default()
  def get(name) when is_atom(name),
    do: Enum.find(all(), fn e -> e[:name] == name end)

  @doc """
  Look up prompt by `:name` atom. Raises if not found.

  ## Options
    * `name` (atom) — Prompt name.

  ## Raises
      ArgumentError if prompt not found.
  """
  @spec get!(atom()) :: prompt_entry()
  def get!(name) do
    case get(name) do
      nil ->
        raise ArgumentError,
          "unknown prompt #{inspect(name)}; available: #{inspect(names())}"
      entry -> entry
    end
  end

  @doc """
  Get list of all registered prompt names (atoms).

  ## Example
      iex> Eai.Prompts.names()
      [:momoka, :coder, :analyst]
  """
  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1[:name])

  @doc """
  Extract system prompt text from prompt entry.

  ## Options
    * `name` (atom) — Prompt name.

  ## Returns
      String content of the prompt.
  """
  @spec content(atom()) :: String.t()
  def content(name), do: get(name)[:content]

  @doc """
  Print formatted table of available prompts and their descriptions.

  ## Example
      iex> Eai.Prompts.list()
      
      Available prompts:
      
        :momoka              Helpful generalist, concise
        :coder               Code analysis and refactoring
        :analyst             Research-focused, structured reasoning
  """
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
    with {:ok, files} <- File.ls(@prompts_dir) do
      files
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.each(&compile_prompt_file/1)
    end

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

  defp compile_prompt_file(file) do
    path = Path.join(@prompts_dir, file)

    path
    |> Config.Reader.read!()
    |> Enum.each(fn {app, kvs} -> put_prompt_app_env(app, kvs) end)
  end

  defp put_prompt_app_env(app, kvs) do
    Enum.each(kvs, fn {key, val} -> Application.put_env(app, key, val) end)
  end
end
