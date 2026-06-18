defmodule Eai.Hub do
  @moduledoc """
  Central dispatch bus for all tool calls in eai.

  Every tool invocation flows through `Eai.Hub.run/3` instead of a bare
  `apply(mod, fun, args)`. This single choke-point enables:

  - **Pre-hooks**: intercept, block, or modify arguments before execution
  - **Post-hooks**: observe, block, or transform results after execution
  - **Telemetry**: uniform `:eai, :tool, :hub_pre` / `:eai, :tool, :hub_post` events

  ## Why this design (decision #1 + #2)?

  Centralising dispatch here means the 14 tool modules are untouched.
  Hooks run in the **same process** as the caller (no PubSub, no GenServer
  round-trip) so they can synchronously veto a call before it executes.

  ## Initial code is complete (decision #9)

  This module ships fully wired to `Eai.Hub.Pipeline` from the start.
  `Pipeline.pre_hooks/3` and `Pipeline.post_hooks/4` are no-ops when
  `:eai_hooks` is empty (the 500ms window before Application.start fires
  `reload!`). No "bare apply" fallback path is needed.

  ## reload!

  Delegates to `Eai.Hub.Reloader.reload!/0`. Exposed here for ergonomics:

      Eai.Hub.reload!()
      :persistent_term.erase(:eai_hooks); Eai.Hub.reload!()
  """

  alias Eai.Hub.Pipeline
  alias Eai.Hub.Reloader

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Dispatch a tool call through the pre→execute→post hook pipeline.

  ## Flow

  1. `Pipeline.pre_hooks/3` — runs all interested pre-hooks in priority order.
     - `:ok` → proceed with original args
     - `{:modify, new_args}` → proceed with modified args
     - `{:block, reason}` → abort; return `{:block, reason}` to caller
  2. `apply(mod, fun, effective_args)` — execute the actual tool.
  3. `Pipeline.post_hooks/4` — runs all interested post-hooks in priority order.
     - `{:ok, result}` → return result
     - `{:block, reason}` → suppress result; return `{:block, reason}`

  ## Telemetry events

  - `[:eai, :tool, :hub_pre]` — fired before pre-hooks, carries `{mod, fun, args}`
  - `[:eai, :tool, :hub_post]` — fired after post-hooks, carries `{mod, fun, result, duration_ms}`
  - `[:eai, :tool, :hub_blocked]` — fired when any hook blocks (pre or post)
  """
  @spec run(module(), atom(), [any()]) :: {:ok, any()} | {:block, String.t()}
  def run(mod, fun, args) do
    tool_name = "#{mod}.#{fun}"

    :telemetry.execute(
      [:eai, :tool, :hub_pre],
      %{system_time: System.system_time()},
      %{tool: tool_name, mod: mod, fun: fun, args: args}
    )

    start_ms = System.monotonic_time(:millisecond)

    case Pipeline.pre_hooks(mod, fun, args) do
      {:block, reason} ->
        :telemetry.execute(
          [:eai, :tool, :hub_blocked],
          %{system_time: System.system_time()},
          %{tool: tool_name, phase: :pre, reason: reason}
        )

        {:block, reason}

      pre_result ->
        effective_args =
          case pre_result do
            {:modify, new_args} -> new_args
            :ok -> args
          end

        # Execute the actual tool function.
        # Errors propagate naturally — Hub is not a try/rescue wrapper.
        # Tool-level error handling stays in Eai.LLM.Direct.
        raw_result = apply(mod, fun, effective_args)

        case Pipeline.post_hooks(mod, fun, effective_args, raw_result) do
          {:block, reason} ->
            :telemetry.execute(
              [:eai, :tool, :hub_blocked],
              %{system_time: System.system_time()},
              %{tool: tool_name, phase: :post, reason: reason}
            )

            {:block, reason}

          {:ok, final_result} ->
            duration_ms = System.monotonic_time(:millisecond) - start_ms

            :telemetry.execute(
              [:eai, :tool, :hub_post],
              %{duration_ms: duration_ms},
              %{tool: tool_name, mod: mod, fun: fun, result: final_result}
            )

            {:ok, final_result}
        end
    end
  end

  @doc """
  Reload all runtime-extensible config without restarting the VM.

  Reloads three registries in one call:
  - Hooks: re-compiles `config/hooks/*.exs` → `:persistent_term.put(:eai_hooks, ...)`
  - Models: re-reads `config/models/*.exs`  → `:persistent_term.put(:eai_models, ...)`
  - Cards:  re-reads `config/chara_cards/*.json` → `:persistent_term.put(:eai_chara_cards, ...)`

  All three take effect immediately — the next LLM call picks up new models/cards,
  the next tool invocation picks up new hooks.

  ## IEx usage

      iex> Eai.Hub.reload!()
      :ok

      # Force full re-scan
      iex> :persistent_term.erase(:eai_hooks); Eai.Hub.reload!()
      :ok

  ## Mix usage

      mix run -e "Eai.Hub.reload!()"
  """
  @spec reload!() :: :ok | {:error, term()}
  def reload! do
    hooks_result = Reloader.reload!()
    _models = Eai.Models.reload()
    _cards = Eai.Card.reload()

    hooks_result
  end
end
