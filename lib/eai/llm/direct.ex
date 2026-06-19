defmodule Eai.LLM.Direct do
  @moduledoc """
  Direct LLM API orchestration using Converse-based internal message IR.

  All internal history is [Eai.Message.t()]. Before sending to an LLM provider,
  the appropriate adapter converts messages to provider-specific wire format.
  Responses are parsed back into Eai.Message.t(). LLM requests
  flow through `Pipeline.llm_pre_hooks/4` and `llm_post_hooks/5`
  for pre/post request interception.
  """

  require Logger
  @tools_dir Path.expand("config/tools", File.cwd!())

  alias Eai.Hub.Pipeline
  alias Eai.Message

  # ── Tool registry (lazy-loaded on first run) ─────────────────────────

  defp load_tools do
    {:ok, files} = File.ls(@tools_dir)

    modules =
      files
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        path = Path.join(@tools_dir, file)
        compile_or_load(path)
      end)

    schemas = Enum.map(modules, & &1.schema())
    dispatch = Map.new(modules, fn mod -> {mod.schema().function.name, mod} end)
    registry = %{schemas: schemas, dispatch: dispatch}

    :persistent_term.put(:eai_llm_tools, registry)
    registry
  end

  # Extract the `defmodule Foo.Bar.Baz do` head from the first line of a
  # tool file. Returns `{:ok, mod}` on success, `:error` if the line is
  # missing or doesn't match the expected shape. Anchored on the file's
  # first line because every `config/tools/*.exs` follows that convention;
  # the regex intentionally rejects comments and stray whitespace to keep
  # the contract tight.
  @tool_module_regex ~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do\s*$/

  defp tool_module_name(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, mod} <- parse_module_head(contents) do
      {:ok, mod}
    else
      _ -> :error
    end
  end

  defp parse_module_head(contents) do
    case String.split(contents, "\n", parts: 2) do
      [first_line, _rest] -> match_to_module(Regex.run(@tool_module_regex, first_line))
      _ -> :error
    end
  end

  defp match_to_module([_, mod_str]), do: {:ok, Module.concat([mod_str])}
  defp match_to_module(_), do: :error

  # Every tool file under `config/tools/` declares its module on the
  # very first line as `defmodule Eai.Tool.<Name> do`. Extracting the
  # module name from that line lets us short-circuit when the module
  # is already loaded — `Code.compile_file/1` would otherwise emit
  # "redefining module X" warnings every time `load_tools/0` runs
  # (e.g. after a recompile, in `iex` sessions, or whenever the
  # `:eai_llm_tools` persistent term has been cleared). We fall back
  # to the compilation result only when the module isn't loaded yet.
  # A tool file without a top-level `defmodule` is a programming
  # error, but we don't want to take the whole tool registry down —
  # compile it the old way and let any later warning surface; if the
  # file is unparseable, `[]` propagates.
  defp compile_or_load(path) do
    case tool_module_name(path) do
      {:ok, mod} ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :schema, 0),
          do: [mod],
          else: compile_to_list(path)

      :error ->
        compile_to_list(path)
    end
  end

  defp compile_to_list(path) do
    case Code.compile_file(path) do
      [{mod, _}] -> [mod]
      _ -> []
    end
  end

  defp tools do
    case :persistent_term.get(:eai_llm_tools, :not_found) do
      :not_found -> load_tools()
      registry -> registry
    end
  end

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Run LLM tool-calling loop with messages.

  Internal API called by `Chat.talk/1`. Handles model selection, adapter routing,
  tool execution, and result polling.

  ## Options (map)

    * `:model` (atom) — Model name: `:deepseek`, `:claude_opus`, etc.
                        Default: from config `:default_model`
    * `:prompt` (atom) — System prompt: `:momoka`, `:coder`, `:analyst`, etc.
                         Default: `:momoka`
    * `:chat_session_id` (string) — Session for multi-session isolation.
                                     Default: `"default"`
    * `:card_system_prompt` (string) — Extra system prompt (role layer, appended).
                                        Default: nil
    * `:card_tools` (list) — Allowlist of tool names. Default: all tools
    * `:card_pre_context` (list) — Pre-loaded messages (for prefix caching).
                                    Default: nil

  **Internal fields** (filled automatically by `Chat.talk`, do NOT set externally):
    * `:provider` — Adapter provider (`:anthropic`, `:openai_compat`, etc.)
    * `:api_key` — LLM API key (from env)
    * `:url` — LLM endpoint URL
    * `:receive_timeout` — HTTP timeout in ms
    * `:reasoning_effort` — Model-specific (e.g., "high" for DeepSeek)
    * `:model_str` — Actual model string for API

  ## Returns
      `{:ok, final_reply}` or `{:error, reason}`

  ## Example (internal, called by Chat.talk)
      iex> Eai.LLM.Direct.run(
        messages,
        "default",
        %{model: :deepseek, prompt: :coder, chat_session_id: "work"}
      )
      {:ok, "Here's the refactored code..."}
  """
  def run(messages, pty_session_id \\ "default", opts \\ %{}) do
    entry = resolve_model_entry(opts)
    chat_session_id = Map.get(opts, :chat_session_id, "default") |> to_string()
    provider = Map.get(opts, :provider, entry[:provider] || :openai_compat)
    adapter = adapter_for(provider)

    api_key = Map.get(opts, :api_key, Eai.Models.api_key(entry))
    model = Map.get(opts, :model_str, entry[:model])
    url = Map.get(opts, :url, entry[:url])
    timeout = Map.get(opts, :receive_timeout, entry[:receive_timeout] || 120_000)
    effort = Map.get(opts, :reasoning_effort, entry[:reasoning_effort])
    # Step 7: 10 sampler/超参数 fields. `Map.get(opts, :field, entry[:field])`
    # — explicit `talk/1` opt (carried via build_run_opts/15 → opts map) wins;
    # otherwise we fall back to the model config (`config/models/<name>.exs`).
    # Both nil → field is omitted from the HTTP body (provider default).
    # Step 9 adds an 11th field `:anthropic_beta` to the same pattern.
    temperature = Map.get(opts, :temperature, entry[:temperature])
    top_p = Map.get(opts, :top_p, entry[:top_p])
    top_k = Map.get(opts, :top_k, entry[:top_k])
    min_p = Map.get(opts, :min_p, entry[:min_p])
    max_tokens = Map.get(opts, :max_tokens, entry[:max_tokens])
    repetition_penalty = Map.get(opts, :repetition_penalty, entry[:repetition_penalty])
    frequency_penalty = Map.get(opts, :frequency_penalty, entry[:frequency_penalty])
    presence_penalty = Map.get(opts, :presence_penalty, entry[:presence_penalty])
    stop_sequences = Map.get(opts, :stop_sequences, entry[:stop_sequences])
    seed = Map.get(opts, :seed, entry[:seed])
    # Step 9: `anthropic_beta` is a per-model opt-in list. Same precedence
    # as the 10 sampler fields: explicit `talk/1` opt > model config
    # (`config/models/<name>.exs`) > nil/omit. nil/[] → no beta header.
    # Multi-beta supported (joined with ", " per Anthropic convention),
    # though the current scope adds no model that uses more than one.
    anthropic_beta = Map.get(opts, :anthropic_beta, entry[:anthropic_beta])
    # Step 10: `reasoning_budget_tokens` is the Anthropic thinking block's
    # `budget_tokens` value. Pass-through only: nil = Anthropic rejects.
    # No Eai-side fallback. Same precedence as the other Step 7+9 fields.
    reasoning_budget_tokens =
      Map.get(opts, :reasoning_budget_tokens, entry[:reasoning_budget_tokens])

    prompt = resolve_prompt(Map.get(opts, :system_prompt))

    {messages, prompt, schemas, opts} = prepare_run_context(messages, prompt, opts)

    # ── LLM pre-hooks ──────────────────────────────────────────────
    req_ctx = %{
      adapter: adapter,
      model: model,
      prompt: prompt,
      schemas: schemas,
      provider: provider,
      api_key: api_key,
      url: url,
      timeout: timeout,
      effort: effort,
      temperature: temperature,
      top_p: top_p,
      top_k: top_k,
      min_p: min_p,
      max_tokens: max_tokens,
      repetition_penalty: repetition_penalty,
      frequency_penalty: frequency_penalty,
      presence_penalty: presence_penalty,
      stop_sequences: stop_sequences,
      seed: seed,
      anthropic_beta: anthropic_beta,
      reasoning_budget_tokens: reasoning_budget_tokens
    }

    case Pipeline.llm_pre_hooks(messages, pty_session_id, chat_session_id, opts) do
      {:block, reason} ->
        Logger.warning("LLM request blocked by hook: #{reason}")
        {:error, "LLM request blocked by hook: #{reason}", messages}

      {:modify,
       %{
         messages: messages,
         pty_session_id: pty_session_id,
         chat_session_id: chat_session_id,
         opts: opts
       }} ->
        do_run(messages, pty_session_id, chat_session_id, opts, req_ctx)

      :ok ->
        do_run(messages, pty_session_id, chat_session_id, opts, req_ctx)
    end
  end

  # ── Run context preparation (extracted to reduce CC) ────────────────

  defp prepare_run_context(messages, prompt, opts) do
    # Card pre_context injection
    card_pre = Map.get(opts, :card_pre_context)

    messages =
      if is_list(card_pre) and card_pre != [] do
        card_pre ++ messages
      else
        messages
      end

    # Card system_prompt merge
    card_sys = Map.get(opts, :card_system_prompt)

    prompt =
      if card_sys && card_sys != "" do
        prompt <> "\n\n---\n## Role\n" <> card_sys
      else
        prompt
      end

    # Tool filtering
    card_tools = Map.get(opts, :card_tools)
    %{schemas: schemas} = tools()

    {schemas, opts} =
      if is_list(card_tools) do
        allowed = MapSet.new(card_tools)
        filtered = Enum.filter(schemas, fn s -> MapSet.member?(allowed, s.function.name) end)
        {filtered, Map.put(opts, :tools_allowlist, allowed)}
      else
        {schemas, opts}
      end

    {messages, prompt, schemas, opts}
  end

  # ── Execute LLM request (extracted for hook rebind) ────────────

  defp do_run(messages, pty_session_id, chat_session_id, opts, req_ctx) do
    %{
      adapter: adapter,
      model: model,
      prompt: prompt,
      schemas: schemas,
      provider: provider,
      api_key: api_key,
      url: url,
      timeout: timeout,
      effort: effort,
      temperature: temperature,
      top_p: top_p,
      top_k: top_k,
      min_p: min_p,
      max_tokens: max_tokens,
      repetition_penalty: repetition_penalty,
      frequency_penalty: frequency_penalty,
      presence_penalty: presence_penalty,
      stop_sequences: stop_sequences,
      seed: seed,
      anthropic_beta: anthropic_beta,
      reasoning_budget_tokens: reasoning_budget_tokens
    } = req_ctx

    region = Map.get(opts, :region)
    # Build adapter_opts dynamically: nil-omit pattern for all sampler/超参数
    # fields. Only add the key when the value is non-nil; adapters that don't
    # support a given field just don't read it.
    optional_opts = [
      reasoning_effort: effort,
      region: region,
      temperature: temperature,
      top_p: top_p,
      top_k: top_k,
      min_p: min_p,
      max_tokens: max_tokens,
      repetition_penalty: repetition_penalty,
      frequency_penalty: frequency_penalty,
      presence_penalty: presence_penalty,
      stop_sequences: stop_sequences,
      seed: seed,
      reasoning_budget_tokens: reasoning_budget_tokens
    ]

    adapter_opts = Enum.reject(optional_opts, fn {_k, v} -> is_nil(v) end)

    req = adapter.to_request_body(messages, model, prompt, schemas, adapter_opts)
    req_url = if is_nil(req.url), do: url, else: req.url
    # Step 9: build `extra_headers` from the per-model `anthropic_beta`
    # opt-in list. When the list is non-empty we emit a single
    # `anthropic-beta` header whose value is the list joined with ", "
    # (Anthropic's convention for multiple betas). When the list is nil
    # or [], we emit no extra header at all and the merge clause in
    # `build_headers/3` short-circuits, falling through to the
    # provider-specific `[]` default. The Step 8 merge clause in
    # `build_headers/3` is preserved unchanged — it now consumes
    # `extra_headers` (built here from `anthropic_beta`) instead of the
    # adapter's `req.headers`. Currently the Anthropic adapter returns
    # `[]` (Step 9 removed the hardcoded beta header), so the only
    # source of `extra_headers` is the per-model config / `talk/1` opt.
    extra_headers =
      if anthropic_beta && anthropic_beta != [] do
        [{"anthropic-beta", Enum.join(anthropic_beta, ", ")}]
      else
        []
      end

    headers = build_headers(provider, api_key, extra_headers)

    execute_request(
      req_url,
      req.json_body,
      headers,
      timeout,
      messages,
      pty_session_id,
      chat_session_id,
      opts
    )
  end

  defp execute_request(
         url,
         json_body,
         headers,
         timeout,
         messages,
         pty_session_id,
         chat_session_id,
         opts
       ) do
    entry = resolve_model_entry(opts)
    provider = Map.get(opts, :provider, entry[:provider] || :openai_compat)
    adapter = adapter_for(provider)

    if System.get_env("EAI_DEBUG_LLM_REQUEST") == "1" do
      require Logger
      Logger.debug("LLM request body", body: inspect(json_body, limit: :infinity, pretty: true))
    end

    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute([:eai, :llm, :request, :start], %{system_time: System.system_time()}, %{
      pty_session_id: pty_session_id
    })

    result = Req.post(url, json: json_body, headers: headers, receive_timeout: timeout)
    duration = System.monotonic_time(:millisecond) - start_time

    handle_http_result(result, duration, messages, pty_session_id, chat_session_id, adapter, opts)
  end

  defp handle_http_result(
         result,
         duration,
         messages,
         pty_session_id,
         chat_session_id,
         adapter,
         opts
       ) do
    raw_result =
      case result do
        {:ok, %{status: 200, body: resp_body}} ->
          :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{
            pty_session_id: pty_session_id,
            status: :ok
          })

          assistant_msg = adapter.from_response(resp_body)
          handle_response(assistant_msg, messages, pty_session_id, chat_session_id, opts)

        {:ok, %{status: status, body: body}} ->
          :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{
            pty_session_id: pty_session_id,
            status: :error
          })

          :telemetry.execute([:eai, :error, :llm], %{duration_ms: duration}, %{
            pty_session_id: pty_session_id,
            chat_session_id: chat_session_id,
            kind: :http,
            status: status,
            body: body
          })

          {:error, "HTTP #{status}: #{inspect(body)}", messages}

        {:error, reason} ->
          :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{
            pty_session_id: pty_session_id,
            status: :error
          })

          :telemetry.execute([:eai, :error, :llm], %{duration_ms: duration}, %{
            pty_session_id: pty_session_id,
            chat_session_id: chat_session_id,
            kind: :transport,
            reason: reason
          })

          {:error, reason, messages}
      end

    # ── LLM post-hooks ─────────────────────────────────────────────
    case Pipeline.llm_post_hooks(messages, pty_session_id, chat_session_id, opts, raw_result) do
      {:ok, final} -> final
      {:block, _reason} -> raw_result
    end
  end

  # ── Response routing ────────────────────────────────────────────────

  defp handle_response(assistant_msg, history, pty_session_id, chat_session_id, opts) do
    history = history ++ [assistant_msg]

    if Message.has_tool_uses?(assistant_msg) do
      handle_tool_calls(assistant_msg, history, pty_session_id, chat_session_id, opts)
    else
      text = Message.text(assistant_msg)
      {:ok, Eai.Utils.sanitize_value(text), history}
    end
  end

  # ── Tool execution loop ─────────────────────────────────────────────

  defp handle_tool_calls(assistant_msg, history, pty_session_id, chat_session_id, opts) do
    %{dispatch: dispatch} = tools()
    allowlist = Map.get(opts, :tools_allowlist)

    dispatch =
      if allowlist do
        Map.filter(dispatch, fn {name, _} -> MapSet.member?(allowlist, name) end)
      else
        dispatch
      end

    tool_uses = Message.tool_uses(assistant_msg)

    new_user_messages =
      tool_uses
      |> Enum.reduce([], fn tu, acc ->
        msg = execute_single_tool_call(tu, dispatch, pty_session_id, chat_session_id)
        [msg | acc]
      end)

    new_user_messages = Enum.reverse(new_user_messages)

    all_messages =
      (history ++ new_user_messages)
      |> dedup_stale_task_polls()
      |> dedup_stale_subagent_polls()

    run(all_messages, pty_session_id, opts)
  end

  defp execute_single_tool_call(tu, dispatch, pty_session_id, chat_session_id) do
    name = tu[:name]
    args = Eai.Utils.sanitize_value(tu[:input])
    tool_use_id = tu[:tool_use_id]

    :telemetry.execute([:eai, :tool, :pre], %{system_time: System.system_time()}, %{
      tool: name,
      pty_session_id: pty_session_id
    })

    content_json =
      try do
        case Map.fetch(dispatch, name) do
          {:ok, mod} ->
            case Eai.Hub.run(mod, :execute, [args, pty_session_id, chat_session_id]) do
              {:ok, result} ->
                :telemetry.execute(
                  [:eai, :tool, :post],
                  %{system_time: System.system_time()},
                  %{tool: name, pty_session_id: pty_session_id}
                )

                result

              {:block, reason} ->
                :telemetry.execute(
                  [:eai, :tool, :blocked],
                  %{system_time: System.system_time()},
                  %{tool: name, pty_session_id: pty_session_id, reason: reason}
                )

                Jason.encode!(%{error: "tool blocked by hook: #{reason}"})
            end

          :error ->
            Jason.encode!(%{error: "unknown tool: #{name}"})
        end
      rescue
        e ->
          :telemetry.execute([:eai, :error, :tool], %{system_time: System.system_time()}, %{
            tool: name,
            mod: dispatch[name],
            chat_session_id: chat_session_id,
            pty_session_id: pty_session_id,
            kind: :exception,
            error: %{type: e.__struct__, message: Exception.message(e)},
            stacktrace: __STACKTRACE__
          })

          Jason.encode!(%{error: Exception.message(e)})
      end

    case Jason.decode(content_json) do
      {:ok, %{"type" => "multimodal_inject", "blocks" => blocks}} ->
        inject_msg = Message.from_inject_blocks(blocks)
        inject_msg

      {:ok, _} ->
        result_content = [{:text, content_json}]
        tool_msg = Message.new_tool_result(tool_use_id, result_content)
        tool_msg

      {:error, _} ->
        result_content = [{:text, content_json}]
        tool_msg = Message.new_tool_result(tool_use_id, result_content)
        tool_msg
    end
  end

  # ── Poll dedup: get_task_result ───────────────────────────────────────
  # Prune stale assistant(tool_use)+user(tool_result) pairs where
  # status == "running". Only the latest running pair survives.
  # Fully independent of get_subagent_result dedup — no shared code path.

  defp dedup_stale_task_polls(all_messages) do
    {clean, _} =
      all_messages
      |> Enum.reverse()
      |> Enum.reduce({[], false}, &reduce_task_poll/2)

    clean
  end

  defp reduce_task_poll(msg, {acc, kept_running}) do
    case classify_task_poll(msg) do
      {:running_user, _tool_use_id} ->
        if kept_running, do: {acc, :skip_assistant}, else: {[msg | acc], true}

      :assistant_poll_tool ->
        if kept_running == :skip_assistant, do: {acc, false}, else: {[msg | acc], kept_running}

      _ ->
        {[msg | acc], kept_running}
    end
  end

  defp classify_task_poll(%{role: :user, content: [{:tool_result, kw}]}) do
    content_str =
      case kw[:content] do
        [{:text, t}] -> t
        _ -> ""
      end

    case Jason.decode(content_str) do
      {:ok, %{"status" => "running"}} -> {:running_user, kw[:tool_use_id]}
      _ -> :other
    end
  end

  defp classify_task_poll(%{role: :assistant, content: content}) do
    has_poll =
      Enum.any?(content, fn
        {:tool_use, kw} -> Keyword.get(kw, :name) == "get_task_result"
        _ -> false
      end)

    if has_poll, do: :assistant_poll_tool, else: :other
  end

  defp classify_task_poll(_), do: :other

  # ── Poll dedup: get_subagent_result ──────────────────────────────────
  # Same pattern as get_task_result, fully independent implementation.
  # A future change to classify_task_poll cannot accidentally affect
  # subagent polling, and vice versa. Explicit duplication over
  # implicit coupling.

  defp dedup_stale_subagent_polls(all_messages) do
    {clean, _} =
      all_messages
      |> Enum.reverse()
      |> Enum.reduce({[], false}, &reduce_subagent_poll/2)

    clean
  end

  defp reduce_subagent_poll(msg, {acc, kept_running}) do
    case classify_subagent_poll(msg) do
      {:running_user, _tool_use_id} ->
        if kept_running, do: {acc, :skip_assistant}, else: {[msg | acc], true}

      :assistant_poll_tool ->
        if kept_running == :skip_assistant, do: {acc, false}, else: {[msg | acc], kept_running}

      _ ->
        {[msg | acc], kept_running}
    end
  end

  defp classify_subagent_poll(%{role: :user, content: [{:tool_result, kw}]}) do
    content_str =
      case kw[:content] do
        [{:text, t}] -> t
        _ -> ""
      end

    case Jason.decode(content_str) do
      {:ok, %{"status" => "running"}} -> {:running_user, kw[:tool_use_id]}
      _ -> :other
    end
  end

  defp classify_subagent_poll(%{role: :assistant, content: content}) do
    has_poll =
      Enum.any?(content, fn
        {:tool_use, kw} -> Keyword.get(kw, :name) == "get_subagent_result"
        _ -> false
      end)

    if has_poll, do: :assistant_poll_tool, else: :other
  end

  defp classify_subagent_poll(_), do: :other

  # ── Model / prompt resolution ────────────────────────────────────────

  defp resolve_model_entry(%{model: name}) when is_atom(name), do: Eai.Models.get!(name)
  defp resolve_model_entry(_opts), do: Eai.Models.default()

  defp resolve_prompt(nil), do: Eai.Prompts.default()[:content]
  defp resolve_prompt(name) when is_atom(name), do: Eai.Prompts.get!(name)[:content]
  defp resolve_prompt(text) when is_binary(text), do: text

  # ── Adapter dispatch ─────────────────────────────────────────────────

  defp adapter_for(:anthropic), do: Eai.Adapter.Anthropic
  defp adapter_for(:openai_compat), do: Eai.Adapter.OpenAI
  defp adapter_for(:converse), do: Eai.Adapter.Converse
  defp adapter_for(_), do: Eai.Adapter.OpenAI

  # ── Header construction ──────────────────────────────────────────────

  # Step 8 (preserved in Step 9): when extra headers are passed
  # (currently sourced from the per-model `anthropic_beta` opt-in list
  # in `run/3`), merge them with the provider's auth headers instead of
  # replacing them. The `[]` fallthrough below is unchanged. The merge
  # semantic is identical regardless of where the extra headers come
  # from (adapter body or per-model opt-in), so the function shape has
  # not changed since Step 8 — only the call site in `do_run/5` now
  # builds `extra_headers` from the per-model `anthropic_beta` list
  # rather than reading the adapter's `req.headers` directly.
  defp build_headers(provider, api_key, extra_headers)
       when is_list(extra_headers) and extra_headers != [] do
    provider_headers = build_headers(provider, api_key, [])
    provider_headers ++ extra_headers
  end

  defp build_headers(:anthropic, api_key, []) do
    [
      {"x-api-key", api_key || ""},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  defp build_headers(_provider, api_key, []) do
    [authorization: "Bearer #{api_key || ""}"]
  end
end
