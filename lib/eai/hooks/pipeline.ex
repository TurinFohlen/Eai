defmodule Eai.Hub.Pipeline do
  @moduledoc """
  Runs pre/post hook pipelines and manages the `:eai_hooks` persistent_term registry.

  ## Pipeline semantics

  - Pre-hooks run in ascending priority order (lowest number first).
  - Post-hooks run in ascending priority order; each hook sees the result
    already modified by all prior post-hooks (pipeline/reduce semantics).
  - A `:block` verdict from any hook short-circuits the pipeline immediately
    (`Enum.reduce_while` — block is a veto, not just a vote).
  - Hook errors → fail open: telemetry fires `[:eai, :hook, :error]`,
    original call continues as if the hook returned `:ok`.

  ## Why `Enum.reduce_while` for post-hooks?

  Post-hooks accumulate a result value through the chain. `reduce_while` lets
  a block verdict break early without processing remaining hooks, which matters
  for security-gating hooks that want to suppress a result entirely.
  """

  require Logger

  @hooks_key :eai_hooks

  # ── Registry ─────────────────────────────────────────────────────────

  @doc """
  Store the sorted hook list into `:persistent_term`.

  Called by `Eai.Hub.Reloader.reload!/0` after compiling the hooks.
  Hooks are stored as `[{module, priority}]` sorted ascending by priority.
  """
  @spec register([{module(), non_neg_integer()}]) :: :ok
  def register(hook_entries) do
    sorted = Enum.sort_by(hook_entries, fn {_mod, prio} -> prio end)
    :persistent_term.put(@hooks_key, sorted)
    :ok
  end

  @doc "Return the currently registered hooks, or [] if none loaded yet."
  @spec hooks() :: [{module(), non_neg_integer()}]
  def hooks, do: :persistent_term.get(@hooks_key, [])

  # ── Pre-hooks ─────────────────────────────────────────────────────────

  @doc """
  Run all pre-hooks for (mod, fun, args).

  Returns:
  - `:ok` — all hooks passed, proceed with original args
  - `{:block, reason}` — a hook vetoed the call; caller should abort
  - `{:modify, new_args}` — hooks modified args; caller should use new_args

  Why not pass args through as accumulator here?
  Pre-hooks can modify args, but we pass the *latest* args into each
  subsequent hook so they see the already-modified version. We still
  short-circuit on block (reduce_while).
  """
  @spec pre_hooks(module(), atom(), [any()]) ::
          :ok | {:block, String.t()} | {:modify, [any()]}
  def pre_hooks(mod, fun, args) do
    tool_name = "#{mod}.#{fun}"
    payload = %{mod: mod, fun: fun, args: args}

    hooks()
    |> Enum.reduce_while({:ok, args}, &reduce_pre_hook(&1, &2, tool_name, payload))
    |> case do
      {:ok, _} -> :ok
      {:modify, new_args} -> {:modify, new_args}
      {:block, reason} -> {:block, reason}
    end
  end

  # ── Post-hooks ────────────────────────────────────────────────────────

  @doc """
  Run all post-hooks for (mod, fun, args, result).

  Returns:
  - `{:ok, final_result}` — pipeline completed; result may have been modified
  - `{:block, reason}` — a hook vetoed the result

  Why pipeline (each hook sees previous hook's modified result)?
  This matches the spec (decision #8): post-hooks are composable transforms,
  e.g. hook A sanitizes, hook B rate-limits based on sanitized output.
  `reduce_while` gives us short-circuit on block.
  """
  @spec post_hooks(module(), atom(), [any()], any()) ::
          {:ok, any()} | {:block, String.t()}
  def post_hooks(mod, fun, args, result) do
    tool_name = "#{mod}.#{fun}"
    payload = %{mod: mod, fun: fun, args: args}

    hooks()
    |> Enum.reduce_while({:ok, result}, &reduce_post_hook(&1, &2, tool_name, payload))
  end

  # ── Reduce helpers (extracted to reduce nesting depth) ─────────────

  defp reduce_pre_hook({hook_mod, _prio}, {status, current_args}, tool_name, payload) do
    current_payload = %{payload | args: current_args}

    if safe_interest(hook_mod, :pre, tool_name, current_payload) do
      case safe_verdict(hook_mod, :pre, tool_name, current_payload) do
        :ok -> {:cont, {:ok, current_args}}
        {:modify, new_args} -> {:cont, {:modify, new_args}}
        {:block, reason} -> {:halt, {:block, reason}}
      end
    else
      {:cont, {status, current_args}}
    end
  end

  defp reduce_post_hook({hook_mod, _prio}, {:ok, current_result}, tool_name, payload) do
    current_payload = %{payload | args: payload.args}

    if safe_interest(hook_mod, :post, tool_name, current_payload) do
      case safe_verdict_post(hook_mod, :post, tool_name, current_payload, current_result) do
        :ok -> {:cont, {:ok, current_result}}
        {:modify, new_result} -> {:cont, {:ok, new_result}}
        {:block, reason} -> {:halt, {:block, reason}}
      end
    else
      {:cont, {:ok, current_result}}
    end
  end

  # ── Safe wrappers (fail open + telemetry) ────────────────────────────

  # Why wrap in try/rescue?
  # A buggy hook must never crash the tool call. We fire telemetry so the
  # error is observable (metrics, log handler) without being fatal.
  defp safe_interest(hook_mod, event, tool_name, payload) do
    hook_mod.interest(event, tool_name, payload)
  rescue
    e ->
      emit_hook_error(hook_mod, :interest, e)
      false
  catch
    kind, reason ->
      emit_hook_error(hook_mod, :interest, {kind, reason})
      false
  end

  defp safe_verdict(hook_mod, event, tool_name, payload) do
    hook_mod.verdict(event, tool_name, payload)
  rescue
    e ->
      emit_hook_error(hook_mod, :verdict_pre, e)
      :ok
  catch
    kind, reason ->
      emit_hook_error(hook_mod, :verdict_pre, {kind, reason})
      :ok
  end

  defp safe_verdict_post(hook_mod, event, tool_name, payload, result) do
    hook_mod.verdict(event, tool_name, payload, result)
  rescue
    e ->
      emit_hook_error(hook_mod, :verdict_post, e)
      :ok
  catch
    kind, reason ->
      emit_hook_error(hook_mod, :verdict_post, {kind, reason})
      :ok
  end

  defp emit_hook_error(hook_mod, callback, error) do
    :telemetry.execute(
      [:eai, :hook, :error],
      %{system_time: System.system_time()},
      %{hook: hook_mod, callback: callback, error: inspect(error)}
    )
    Logger.warning("Hook error (fail open)",
      hook: inspect(hook_mod),
      callback: callback,
      error: inspect(error)
    )
  end
end
