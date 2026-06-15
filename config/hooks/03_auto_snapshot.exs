defmodule Eai.Hook.AutoSnapshot do
  @moduledoc """
  Auto-snapshot + rollback hook for LLM request resilience.

  Before every LLM HTTP request, saves a snapshot of the conversation history
  in an ETS table keyed by `chat_session_id`. If the LLM returns an error
  (HTTP 400/429/5xx etc.), the hook rolls back to the snapshot, preventing
  corrupted message sequences from permanently poisoning the session.

  ## How it works

  1. `llm_pre` — snapshot current messages into `:eai_snapshots` ETS table
  2. `llm_post` — if result is `{:error, _, _}`, restore snapshot into history
  3. Result bubbles up to `Eai.Chat` GenServer with clean history

  The snapshot is two-tier:
  - `snapshot_N` — "last known good" (before current request)
  - `snapshot_N-1` — "grandfather" (fallback if the current one is corrupt)

  This handles the pathological case where the model emits consecutive
  assistant tool_use messages with the same tool_call_id (which causes
  HTTP 400 on the *next* request). The lagged snapshot ensures we always
  have a clean anchor.

  ## Telemetry

  - `[:eai, :hook, :auto_snapshot, :saved]` — snapshot saved
  - `[:eai, :hook, :auto_snapshot, :rolled_back]` — rollback executed
  - `[:eai, :hook, :auto_snapshot, :cleared]` — snapshot cleared on success
  """

  use Eai.Hook, priority: 5

  @table_name :eai_snapshots

  # ── Interest: only LLM requests ──────────────────────────────────────

  @impl true
  def interest(:llm_pre, "LLM_REQUEST", _payload), do: true
  def interest(:llm_post, "LLM_REQUEST", _payload), do: true
  def interest(_event, _tool, _payload), do: false

  # ── Pre-hook: snapshot ───────────────────────────────────────────────

  @impl true
  def verdict(:llm_pre, _tool, %{messages: messages, chat_session_id: csid}) do
    ensure_table!()

    # Deep-copy messages to avoid shared references
    snapshot = :erlang.term_to_binary(messages)

    # Rotate: current snapshot → grandfather, new → current
    current_key = :"snapshot_#{csid}"
    grandpa_key = :"snapshot_#{csid}_prev"

    case :ets.lookup(@table_name, current_key) do
      [{^current_key, old_snapshot}] ->
        :ets.insert(@table_name, {grandpa_key, old_snapshot})
      [] ->
        :ok
    end

    :ets.insert(@table_name, {current_key, snapshot})

    :telemetry.execute(
      [:eai, :hook, :auto_snapshot, :saved],
      %{system_time: System.system_time()},
      %{chat_session_id: csid, msg_count: length(messages)}
    )

    :ok
  end

  # ── Post-hook: detect error, rollback ────────────────────────────────

  @impl true
  def verdict(:llm_post, _tool,
              %{chat_session_id: csid},
              {:error, reason, _}) do
    ensure_table!()

    # Try current snapshot first, fall back to grandfather
    current_key = :"snapshot_#{csid}"
    grandpa_key = :"snapshot_#{csid}_prev"

    restore_msgs =
      case :ets.lookup(@table_name, current_key) do
        [{^current_key, snapshot}] ->
          :erlang.binary_to_term(snapshot)

        [] ->
          case :ets.lookup(@table_name, grandpa_key) do
            [{^grandpa_key, grandpa}] ->
              :erlang.binary_to_term(grandpa)

            [] ->
              nil
          end
      end

    if restore_msgs do
      cleanup_keys(csid)

      :telemetry.execute(
        [:eai, :hook, :auto_snapshot, :rolled_back],
        %{system_time: System.system_time()},
        %{chat_session_id: csid, reason: reason, restored_count: length(restore_msgs)}
      )

      # Replace the partial history with the snapshot.
      # The result triple is {:error, reason, partial_history}.
      {:modify, {:error, reason, restore_msgs}}
    else
      :ok
    end
  end

  @impl true
  def verdict(:llm_post, _tool, %{chat_session_id: csid}, _success_result) do
    # Request succeeded — clear snapshots for this session
    cleanup_keys(csid)

    :telemetry.execute(
      [:eai, :hook, :auto_snapshot, :cleared],
      %{system_time: System.system_time()},
      %{chat_session_id: csid}
    )

    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp ensure_table! do
    unless Process.whereis(@table_name) do
      :ets.new(@table_name, [:named_table, :public, :set])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_keys(csid) do
    current_key = :"snapshot_#{csid}"
    grandpa_key = :"snapshot_#{csid}_prev"
    :ets.delete(@table_name, current_key)
    :ets.delete(@table_name, grandpa_key)
    :ok
  rescue
    _ -> :ok
  end
end
