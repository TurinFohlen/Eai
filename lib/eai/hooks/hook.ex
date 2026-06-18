defmodule Eai.Hook do
  @moduledoc """
  Behaviour + macro for user-level hook modules.

  ## Events

  There are four event types, two for tool calls and two for LLM HTTP requests:

  | Event       | Scope  | When                          |
  |-------------|--------|-------------------------------|
  | `:pre`      | Tool   | Before tool execution         |
  | `:post`     | Tool   | After tool execution          |
  | `:llm_pre`  | LLM    | Before each LLM HTTP request  |
  | `:llm_post` | LLM    | After each LLM HTTP response  |

  All events share the same `interest/3` + `verdict/3` / `verdict/4` callbacks.
  The `tool_name` for LLM events is always `"LLM_REQUEST"`.

  ## Usage

      defmodule MyHook do
        use Eai.Hook, priority: 10

        # ── Tool hooks ──────────────────────────────────────────

        @impl true
        def interest(:pre, tool_name, _payload),
          do: String.contains?(tool_name, "WriteToSession")
        def interest(_event, _tool, _payload), do: false

        @impl true
        def verdict(:pre, _tool, payload) do
          if payload.args |> hd() |> String.contains?("rm -rf") do
            {:block, "blocked dangerous command"}
          else
            :ok
          end
        end

        @impl true
        def verdict(:post, _tool, _payload, result), do: :ok

        # ── LLM hooks ───────────────────────────────────────────

        @impl true
        def interest(:llm_pre, "LLM_REQUEST", _payload), do: true
        def interest(:llm_post, "LLM_REQUEST", _payload), do: true

        @impl true
        def verdict(:llm_pre, _tool, _payload), do: :ok

        @impl true
        def verdict(:llm_post, _tool, _payload, result) do
          case result do
            {:error, _reason, _msgs} ->
              # handle error, e.g. log or rollback
              :ok
            _ -> :ok
          end
        end
      end

  ## LLM payload shape

  `llm_pre` and `llm_post` receive:

      %{
        messages: [Eai.Message.t()],
        pty_session_id: String.t(),
        chat_session_id: String.t(),
        opts: map()
      }

  `llm_post` additionally receives `result` as the 4th argument:

      {:ok, reply_text, full_history} | {:error, reason, partial_history}

  The post-hook can return `{:modify, modified_result}` to replace the
  return value that bubbles up to the Chat GenServer.

  ## Callbacks

  - `interest/3` — return `true` to opt-in. Keep fast: no I/O.
  - `verdict/3` — pre-hook (`:pre`, `:llm_pre`): `:ok | {:block, reason} | {:modify, new_value}`
  - `verdict/4` — post-hook (`:post`, `:llm_post`): `:ok | {:block, reason} | {:modify, new_value}`

  ## Registered automatically

  `@before_compile` injects `register/0` which puts this module into
  `:persistent_term` under `:eai_hooks`. Called by `Eai.Hub.Pipeline.register/1`.
  """

  # ── Behaviour callbacks ──────────────────────────────────────────────

  @doc "Return true if this hook wants to handle (event, tool_name, payload)."
  @callback interest(
              event :: :pre | :post | :llm_pre | :llm_post,
              tool_name :: String.t(),
              payload :: map()
            ) :: boolean()

  @doc """
  Pre-hook verdict: may allow, block, or modify the incoming value.

  For `:pre` (tool): payload has `%{mod:, fun:, args:}`.
    `:modify` expects `[new_args]`.
  For `:llm_pre` (LLM): payload has `%{messages:, pty_session_id:, chat_session_id:, opts:}`.
    `:modify` expects a map with the same keys (messages etc. can be changed).
  """
  @callback verdict(
              event :: :pre | :llm_pre,
              tool_name :: String.t(),
              payload :: map()
            ) :: :ok | {:block, String.t()} | {:modify, any()}

  @doc """
  Post-hook verdict: may allow, block, or modify the result.

  For `:post` (tool): result is the tool's raw output.
    `:modify` returns a replacement result.
  For `:llm_post` (LLM): result is `{:ok, reply, history}` or `{:error, reason, history}`.
    `:modify` returns a replacement triple.
  """
  @callback verdict(
              event :: :post | :llm_post,
              tool_name :: String.t(),
              payload :: map(),
              result :: any()
            ) :: :ok | {:block, String.t()} | {:modify, any()}

  # ── __using__ macro ──────────────────────────────────────────────────

  @doc """
  Injects `@priority`, `@behaviour Eai.Hook`, and `@before_compile Eai.Hook`
  into the calling module.

  Priority is a positive integer. Lower = runs first in the pre-pipeline,
  higher priority = runs last. Users own the numbering space entirely.
  """
  defmacro __using__(opts) do
    priority = Keyword.fetch!(opts, :priority)

    quote do
      @behaviour Eai.Hook
      @priority unquote(priority)
      @before_compile Eai.Hook

      # Default no-op implementations so users only override what they need.
      # Overridable so the compiler doesn't warn on unused defaults.
      @impl true
      def interest(_event, _tool, _payload), do: false

      @impl true
      def verdict(:pre, _tool, _payload), do: :ok

      @impl true
      def verdict(:post, _tool, _payload, _result), do: :ok

      @impl true
      def verdict(:llm_pre, _tool, _payload), do: :ok

      @impl true
      def verdict(:llm_post, _tool, _payload, _result), do: :ok

      defoverridable interest: 3,
                     verdict: 3,
                     verdict: 4
    end
  end

  # ── @before_compile — injects register/0 ─────────────────────────────

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Returns `{module, priority}` tuple for this hook.
      Called by `Eai.Hub.Pipeline.register/1` during `reload!`.
      """
      def __hook_entry__, do: {__MODULE__, @priority}
    end
  end
end
