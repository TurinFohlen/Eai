defmodule Eai.Hook do
  @moduledoc """
  Behaviour + macro for user-level hook modules.

  ## Usage

      defmodule MyHook do
        use Eai.Hook, priority: 10

        @impl true
        def interest(:pre, "write_to_session", _payload), do: true
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
      end

  ## Callbacks

  - `interest/3` — return `true` to opt-in to a (event, tool) pair. Keep fast: no I/O.
  - `verdict/3` — pre-hook: `:ok | {:block, reason} | {:modify, new_args}`
  - `verdict/4` — post-hook: `:ok | {:block, reason} | {:modify, new_result}`

  ## Registered automatically

  `@before_compile` injects `register/0` which puts this module into
  `:persistent_term` under `:eai_hooks`. Called by `Eai.Hub.Pipeline.register/1`.
  """

  # ── Behaviour callbacks ──────────────────────────────────────────────

  @doc "Return true if this hook wants to handle (event, tool_name, payload)."
  @callback interest(event :: :pre | :post, tool_name :: String.t(), payload :: map()) ::
              boolean()

  @doc "Pre-hook verdict: may allow, block, or modify args."
  @callback verdict(event :: :pre, tool_name :: String.t(), payload :: map()) ::
              :ok | {:block, String.t()} | {:modify, [any()]}

  @doc "Post-hook verdict: may allow, block, or modify the result."
  @callback verdict(event :: :post, tool_name :: String.t(), payload :: map(), result :: any()) ::
              :ok | {:block, String.t()} | {:modify, any()}

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

      defoverridable interest: 3, verdict: 3, verdict: 4
    end
  end

  # ── @before_compile — injects register/0 ────────────────────────────

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
