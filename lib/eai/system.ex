defmodule Eai.System do
  @moduledoc """
  Step 4 — whole-runtime snapshot and restore.

  Owns the "lock + serialize" logic for the global export/import tools
  (`Eai.Tool.ExportGlobalContext`, `Eai.Tool.ReplaceGlobalContext`). The
  per-session variants (`export_chat_session_context`,
  `replace_chat_session_context`) are still served directly by
  `Eai.Chat.export_history/2` and `Eai.Chat.replace_history/3`.

  This module does NOT add a force parameter, does NOT install any
  auto-snapshot trigger, and does NOT add cron / periodic jobs. The
  caller (an LLM tool call or a human) is the only thing that can
  invoke it.
  """

  @default_timeout_ms 30_000
  @poll_interval_ms 50
  @gzip_version 1

  @type await_result :: :ok | {:error, :timeout}
  @type snapshot_info :: %{
          file: String.t(),
          chat_session_count: non_neg_integer(),
          cache_entry_count: non_neg_integer()
        }
  @type restore_info :: %{
          chat_sessions_restored: non_neg_integer(),
          cache_entries_restored: non_neg_integer()
        }

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Block until every chat session and PTY session is idle, then return
  `:ok`. If the deadline expires first, return `{:error, :timeout}`.

  Polls every #{@poll_interval_ms}ms. After both sides report all-idle
  once, sleeps one more #{@poll_interval_ms}ms to absorb any in-flight
  `Task.Supervisor` spawn that hasn't appeared in the listing yet, then
  returns `:ok`.

  ## Options
    * `timeout` — Max wait in ms. Default: `#{@default_timeout_ms}`.
  """
  @spec await_idle(timeout()) :: await_result()
  def await_idle(timeout \\ @default_timeout_ms) do
    deadline = monotonic_ms() + timeout

    if wait_for_idle_tick(deadline) do
      # One extra tick absorbs a Task that just finished on a previous
      # poll, leaving a brief window where the listing shows idle but
      # the bookkeeping (cache write, monitor DOWN) hasn't caught up.
      Process.sleep(@poll_interval_ms)

      if still_idle?() do
        :ok
      else
        wait_for_idle_tick(deadline)
      end
    else
      {:error, :timeout}
    end
  end

  @doc """
  Snapshot the entire Eai runtime state to a gzip file.

  Awaits system-idle first. Then, for every chat session, calls
  `Eai.Chat.snapshot_messages_bytes/1` to get the gzip blob of its
  messages in the exact same format as the per-session
  `export_chat_session_context` tool. Iterates the Nebulex cache
  (skipping `chat_session:*` and `chat_history:*` keys as a defensive
  measure — those names are reserved for future per-session cache
  storage) and captures every other entry. Writes the top-level
  `%{version, exported_at, chat_sessions, cache_entries}` map as a
  gzipped `:erlang.term_to_binary/1` to `file_path`.

  ## Options
    * `file_path` — Destination `.gz` path.

  ## Returns
    * `{:ok, %{file, chat_session_count, cache_entry_count}}` on success
    * `{:error, :timeout}` if `await_idle/1` times out
    * `{:error, term}` for any other failure
  """
  @spec snapshot_to_gzip(Path.t()) :: {:ok, snapshot_info()} | {:error, term()}
  def snapshot_to_gzip(file_path) do
    with :ok <- await_idle() do
      do_snapshot_to_gzip(file_path)
    end
  end

  @doc """
  Restore the entire Eai runtime state from a gzip file written by
  `snapshot_to_gzip/1`.

  Awaits system-idle first. Reads the file, gunzips, binary_to_terms.
  Validates the `version` field (must equal `#{@gzip_version}`; an
  unknown version is an error rather than a silent compat fall-back).
  For every chat_session in the snapshot, writes its gzip blob to a
  temp file, calls `Eai.Chat.replace_history/3` with `format: "converse"`,
  then deletes the temp file. For every cache_entry, calls
  `Eai.Naming.cache().put/2`. Cache restore is a MERGE — keys that
  exist in the runtime but not in the snapshot are NOT deleted.

  ## Options
    * `file_path` — Source `.gz` path.

  ## Returns
    * `{:ok, %{chat_sessions_restored, cache_entries_restored}}` on success
    * `{:error, :timeout}` if `await_idle/1` times out
    * `{:error, term}` for any other failure
  """
  @spec restore_from_gzip(Path.t()) :: {:ok, restore_info()} | {:error, term()}
  def restore_from_gzip(file_path) do
    with :ok <- await_idle() do
      do_restore_from_gzip(file_path)
    end
  end

  # ── Helper: implicit try pattern (Credo R) ────────────────────────────────

  defp rescue_to_error_tuple(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Snapshot implementation ────────────────────────────────────────────────

  defp do_snapshot_to_gzip(file_path) do
    rescue_to_error_tuple(fn ->
      chat_sessions = collect_chat_session_blobs()
      cache_entries = collect_cache_entries()

      payload = %{
        version: @gzip_version,
        exported_at: System.system_time(:microsecond),
        chat_sessions: chat_sessions,
        cache_entries: cache_entries
      }

      binary = :erlang.term_to_binary(payload)
      compressed = :zlib.gzip(binary)

      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, compressed)

      {:ok,
       %{
         file: file_path,
         chat_session_count: map_size(chat_sessions),
         cache_entry_count: map_size(cache_entries)
       }}
    end)
  end

  defp collect_chat_session_blobs do
    Eai.Naming.chat().list_chat_sessions()
    |> Map.keys()
    |> Map.new(fn chat_session_id ->
      blob = Eai.Naming.chat().snapshot_messages_bytes(chat_session_id)
      {chat_session_id, blob}
    end)
  end

  # Walks the Nebulex cache. We deliberately use the
  # adapter's `stream/0` (Nebulex 2.6.x API — returns an `Enum.t`
  # stream of `{key, value}` pairs per partition) and fold into
  # a plain map. Keys whose name starts with `chat_session:` or
  # `chat_history:` are filtered out — those are reserved for any
  # future per-session cache layer and shouldn't be carried by a
  # whole-system snapshot.
  defp collect_cache_entries do
    cache = Eai.Naming.cache()
    raw = cache.stream() |> Enum.to_list()
    pairs = normalize_cache_entries(raw)

    pairs
    |> Enum.filter(fn {key, _value} -> include_in_snapshot?(key) end)
    |> Map.new()
  rescue
    # Older Nebulex Local builds or stub adapters may not implement
    # `stream/0` — treat as "no cache entries" rather than crashing
    # the whole snapshot.
    UndefinedFunctionError -> %{}
  end

  # Different Nebulex adapter versions yield `stream/0` in different
  # shapes:
  #   * Local 2.0–2.5: `[%{key => value}, ...]` (one map per partition)
  #   * Local 2.6+:     `[{key, value}, ...]` (flat list of tuples)
  #   * Hashing/Redis:  `[{key, value}, ...]`
  # Normalize all three to a flat `[{key, value}, ...]` list.
  defp normalize_cache_entries(list) when is_list(list) do
    Enum.flat_map(list, &one_cache_entry/1)
  end

  defp one_cache_entry({key, value}), do: [{key, value}]
  defp one_cache_entry(%{} = map), do: Map.to_list(map)
  defp one_cache_entry(_other), do: []

  defp include_in_snapshot?(key) when is_binary(key) do
    not String.starts_with?(key, "chat_session:") and
      not String.starts_with?(key, "chat_history:")
  end

  defp include_in_snapshot?(_other), do: false

  # ── Restore implementation ─────────────────────────────────────────────────

  defp do_restore_from_gzip(file_path) do
    rescue_to_error_tuple(fn ->
      payload =
        file_path
        |> File.read!()
        |> :zlib.gunzip()
        |> :erlang.binary_to_term()

      %{chat_sessions: chat_sessions, cache_entries: cache_entries} = validate_snapshot!(payload)

      cs_count = restore_chat_sessions(chat_sessions)
      cache_count = restore_cache_entries(cache_entries)

      {:ok,
       %{
         chat_sessions_restored: cs_count,
         cache_entries_restored: cache_count
       }}
    end)
  end

  defp validate_snapshot!(%{version: @gzip_version} = payload), do: payload

  defp validate_snapshot!(%{version: other}),
    do: raise("unsupported gzip snapshot version: #{inspect(other)}")

  defp validate_snapshot!(other),
    do: raise("not a valid Eai gzip snapshot: #{inspect(other)}")

  defp restore_chat_sessions(chat_sessions) do
    # PRE-CREATE phase: materialize every session in state.sessions BEFORE
    # any messages are written. Without this, sessions appear one-by-one
    # as replace_history/3 is called, and a concurrent observer could see
    # an inconsistent state where some sessions have messages and others
    # don't yet exist.
    Enum.each(chat_sessions, fn {chat_session_id, _blob} ->
      Eai.Chat.ensure_session_exists(chat_session_id)
    end)

    # WRITE phase: replace messages for each session.
    Enum.reduce(chat_sessions, 0, fn {chat_session_id, blob}, acc ->
      tmp_path = tmp_blob_path(chat_session_id)
      File.write!(tmp_path, blob)

      try do
        case Eai.Naming.chat().replace_history(tmp_path, chat_session_id, "converse") do
          {:ok, _count} ->
            acc + 1

          {:error, reason} ->
            raise "replace_history failed for #{chat_session_id}: #{inspect(reason)}"
        end
      after
        File.rm(tmp_path)
      end
    end)
  end

  defp restore_cache_entries(cache_entries) do
    cache = Eai.Naming.cache()

    Enum.each(cache_entries, fn {key, value} ->
      cache.put(key, value)
    end)

    map_size(cache_entries)
  end

  defp tmp_blob_path(chat_session_id) do
    suffix = chat_session_id |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    Path.join(
      System.tmp_dir!(),
      "eai_system_restore_#{suffix}_#{System.unique_integer([:positive])}.gz"
    )
  end

  # ── await_idle implementation ──────────────────────────────────────────────

  defp wait_for_idle_tick(deadline) do
    if still_idle?() do
      true
    else
      if monotonic_ms() >= deadline do
        false
      else
        Process.sleep(@poll_interval_ms)
        wait_for_idle_tick(deadline)
      end
    end
  end

  defp still_idle? do
    chat_idle?() and pty_idle?()
  end

  defp chat_idle? do
    Eai.Naming.chat().list_chat_sessions()
    |> Enum.all?(fn {_id, %{status: status}} -> status == "idle" end)
  end

  # A PTY session is "idle" iff it has no `current_task`. We only need
  # the boolean answer, not the full info map.
  defp pty_idle? do
    Eai.PTY.list_sessions()
    |> Enum.all?(fn {_id, info} -> is_nil(Map.get(info, :current_task)) end)
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end
