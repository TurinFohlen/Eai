defmodule Eai.Hub.Loader do
  @moduledoc """
  Lists and inspects hook files from `config/hooks/`.

  This module is a **read-only introspection helper** — it does not compile
  or register hooks. Use `Eai.Hub.reload!/0` for that.

  ## Why separate from Reloader?

  Reloader owns the compile + register side-effect path.
  Loader owns the discovery + inspection path (pure read, no BEAM mutations).
  Keeping them separate lets us query what *would* be loaded without triggering
  a full reload — useful for tooling, debugging, and tests.

  ## Usage

      iex> Eai.Hub.Loader.list_files()
      ["01_example.exs", "02_session_log.exs"]

      iex> Eai.Hub.Loader.current_hooks()
      [{MyHook, 10}, {SessionLogHook, 20}]
  """

  alias Eai.Hub.Pipeline

  @hooks_dir "config/hooks"

  @doc """
  List hook `.exs` filenames in load order (sorted by filename).

  Returns `{:ok, [filename]}` or `{:error, reason}` if the dir is missing.
  """
  @spec list_files() :: {:ok, [String.t()]} | {:error, term()}
  def list_files do
    dir = Path.expand(@hooks_dir, File.cwd!())

    case File.ls(dir) do
      {:ok, files} ->
        sorted =
          files
          |> Enum.filter(&String.ends_with?(&1, ".exs"))
          |> Enum.sort()
        {:ok, sorted}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Return the currently registered hooks from `:persistent_term`.

  This is what's *actually running* — may differ from disk files if
  `reload!/0` hasn't been called since a file was added/removed.
  """
  @spec current_hooks() :: [{module(), non_neg_integer()}]
  def current_hooks, do: Pipeline.hooks()

  @doc """
  Pretty-print the current hook registry to stdout.

  Useful in IEx for quick inspection:

      iex> Eai.Hub.Loader.print_hooks()
      Registered hooks (2):
        priority=10  Elixir.ExampleHook
        priority=20  Elixir.SessionLogHook
  """
  @spec print_hooks() :: :ok
  def print_hooks do
    hooks = current_hooks()
    IO.puts("Registered hooks (#{length(hooks)}):")

    if hooks == [] do
      IO.puts("  (none — run Eai.Hub.reload!() to load)")
    else
      Enum.each(hooks, fn {mod, prio} ->
        IO.puts("  priority=#{prio}  #{inspect(mod)}")
      end)
    end

    :ok
  end
end
