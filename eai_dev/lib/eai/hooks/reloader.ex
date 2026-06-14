defmodule Eai.Hub.Reloader do
  @moduledoc """
  Hot-reloads hook modules from `config/hooks/*.exs`.

  ## Reload flow

  1. Scan `config/hooks/` for `*.exs` files (sorted by filename = priority prefix).
  2. `Code.compile_file/1` each file — this defines the hook module in the BEAM.
  3. Collect `{module, priority}` pairs via `module.__hook_entry__/0`.
  4. Pass sorted entries to `Eai.Hub.Pipeline.register/1` → stored in `:persistent_term`.

  ## Why `Code.compile_file` instead of `Code.eval_file`?

  `compile_file` creates proper BEAM modules (registered in code server),
  while `eval_file` only evaluates expressions in the current binding context.
  Hot-reloading requires proper module registration so that subsequent calls
  to the hook module dispatch via the BEAM's standard module lookup.

  ## Why `Code.compile_string` for Hub regeneration (see hub.ex)?

  The Hub module itself is regenerated (not the hook files). We use
  `compile_string` so we can build source dynamically from the registry,
  embedding the hook list directly. The hook files themselves use
  `compile_file` — they are static source files.

  ## Safety

  - Files that fail to compile are skipped with a Logger warning; the
    rest of the reload still proceeds.
  - Old hook registrations are fully replaced on each reload (no
    accumulation across reloads). `:persistent_term.put` is atomic.
  """

  require Logger

  @hooks_dir "config/hooks"

  @doc """
  Reload all hooks from `config/hooks/*.exs`.

  Returns `:ok` on success, `{:error, reason}` if the hooks directory
  cannot be read. Individual file compile failures are logged but do not
  cause an error return.
  """
  @spec reload!() :: :ok | {:error, term()}
  def reload! do
    hooks_dir = hooks_dir_path()

    with {:ok, files} <- File.ls(hooks_dir) do
      entries =
        files
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.sort()
        |> Enum.flat_map(&compile_hook_file(hooks_dir, &1))

      Eai.Hub.Pipeline.register(entries)

      Logger.info("Eai.Hub.Reloader: loaded #{length(entries)} hook(s)",
        hooks: Enum.map(entries, fn {mod, prio} -> "#{inspect(mod)}@#{prio}" end)
      )

      :ok
    else
      {:error, reason} ->
        Logger.warning("Eai.Hub.Reloader: cannot read hooks dir",
          dir: hooks_dir,
          reason: inspect(reason)
        )
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp compile_hook_file(hooks_dir, filename) do
    path = Path.join(hooks_dir, filename)

    try do
      # compile_file returns [{module, binary}] — we only need the module atom.
      compiled = Code.compile_file(path)

      compiled
      |> Enum.flat_map(fn {mod, _binary} ->
        # Only accept modules that implement Eai.Hook (have __hook_entry__/0).
        if function_exported?(mod, :__hook_entry__, 0) do
          [mod.__hook_entry__()]
        else
          []
        end
      end)
    rescue
      e ->
        Logger.warning("Eai.Hub.Reloader: failed to compile hook file",
          file: filename,
          error: Exception.message(e)
        )
        []
    catch
      kind, reason ->
        Logger.warning("Eai.Hub.Reloader: failed to compile hook file",
          file: filename,
          error: inspect({kind, reason})
        )
        []
    end
  end

  defp hooks_dir_path do
    # Resolve relative to Mix project root, falling back to cwd.
    # This ensures correct path whether called from iex -S mix or releases.
    case :application.get_key(:eai, :vsn) do
      {:ok, _} ->
        # Running as compiled app — use app dir
        app_dir = Application.app_dir(:eai)
        # In dev, app_dir is _build/dev/lib/eai — go up to project root
        priv = Path.join(app_dir, "priv")
        if File.dir?(priv) do
          # Fall back to cwd-based path for dev
          cwd_path = Path.expand(@hooks_dir, File.cwd!())
          if File.dir?(cwd_path), do: cwd_path, else: @hooks_dir
        else
          @hooks_dir
        end
      _ ->
        Path.expand(@hooks_dir, File.cwd!())
    end
  end
end
