defmodule Eai.LLM.Direct do
  @moduledoc """
  Direct LLM API orchestration — assembles requests, routes tool calls,
  and delegates execution to tool modules discovered in config/tools/.
  """
  @tools_dir Path.expand("config/tools", File.cwd!())


  # ── Tool registry (lazy-loaded on first run) ─────────────────────────

  defp load_tools do
    {:ok, files} = File.ls(@tools_dir)

    modules =
      files
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        path = Path.join(@tools_dir, file)
        case Code.compile_file(path) do
          [{mod, _}] -> [mod]
          _ -> []
        end
      end)

    schemas    = Enum.map(modules, & &1.schema())
    dispatch   = Map.new(modules, fn mod -> {mod.schema().function.name, mod} end)
    registry   = %{schemas: schemas, dispatch: dispatch}

    :persistent_term.put(:eai_llm_tools, registry)
    registry
  end

  defp tools do
    case :persistent_term.get(:eai_llm_tools, :not_found) do
      :not_found -> load_tools()
      registry   -> registry
    end
  end

  # ── Public API ───────────────────────────────────────────────────────

  def run(messages, pty_session_id \\ "default", opts \\ %{}) do
    entry           = resolve_model_entry(opts)
    chat_session_id = Map.get(opts, :chat_session_id, "default") |> to_string()

    api_key  = Map.get(opts, :api_key,         Eai.Models.api_key(entry))
    model    = Map.get(opts, :model_str,       entry[:model])
    url      = Map.get(opts, :url,             entry[:url])
    timeout  = Map.get(opts, :receive_timeout, entry[:receive_timeout] || 120_000)
    effort   = Map.get(opts, :reasoning_effort, entry[:reasoning_effort])
    provider = Map.get(opts, :provider,        entry[:provider] || :openai_compat)
    prompt   = resolve_prompt(Map.get(opts, :system_prompt))

    formatted =
      messages
      |> Enum.map(&format_message/1)
      |> Eai.Utils.sanitize_messages()

    %{schemas: schemas} = tools()
    body = build_request_body(model, prompt, formatted, effort, provider, schemas)

    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:eai, :llm, :request, :start], %{system_time: System.system_time()}, %{pty_session_id: pty_session_id})

    result = Req.post(url,
      json: body,
      headers: build_headers(provider, api_key),
      receive_timeout: timeout
    )

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: 200, body: resp_body}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{pty_session_id: pty_session_id, status: :ok})
        msg = extract_message(resp_body, provider)
        handle_response(msg, messages, pty_session_id, chat_session_id, opts)

      {:ok, %{status: status, body: body}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{pty_session_id: pty_session_id, status: :error})
        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{pty_session_id: pty_session_id, reason: "HTTP #{status}", body: inspect(body)})
        {:error, "HTTP #{status}: #{inspect(body)}", messages}

      {:error, reason} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{pty_session_id: pty_session_id, status: :error})
        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{pty_session_id: pty_session_id, reason: inspect(reason)})
        {:error, reason, messages}
    end
  end

  # ── Model / prompt resolution ────────────────────────────────────────

  defp resolve_model_entry(%{model: name}) when is_atom(name), do: Eai.Models.get!(name)
  defp resolve_model_entry(_opts),                             do: Eai.Models.default()

  defp resolve_prompt(nil),                    do: Eai.Prompts.default()[:content]
  defp resolve_prompt(name) when is_atom(name), do: Eai.Prompts.get!(name)[:content]
  defp resolve_prompt(text) when is_binary(text), do: text

  # ── Provider-specific request building ───────────────────────────────

  defp build_request_body(model, prompt, formatted, effort, :anthropic, schemas) do
    # system as content-block list with cache breakpoint — cached at write (+25%),
    # subsequent reads hit cache (-90% cost).  ephemeral TTL = 5 min.
    system = [%{type: "text", text: prompt, cache_control: %{type: "ephemeral"}}]

    anthropic_tools = to_anthropic_tools(schemas)

    # Pin cache_control on the last tool so system + all tools sit inside the
    # cached prefix.  No tools → system prompt alone is still cached.
    tools =
      case List.pop_at(anthropic_tools, -1) do
        {last, rest} when not is_nil(last) ->
          rest ++ [Map.put(last, :cache_control, %{type: "ephemeral"})]
        _ ->
          anthropic_tools
      end

    body = %{
      model:      model,
      max_tokens: 8192,
      system:     system,
      messages:   formatted,
      tools:      tools
    }
    if effort, do: Map.put(body, :thinking, %{type: "enabled", budget_tokens: 5000}), else: body
  end

  defp build_request_body(model, prompt, formatted, effort, _openai_compat, schemas) do
    body = %{
      model:       model,
      messages:    [%{role: "system", content: prompt} | formatted],
      tools:       schemas,
      tool_choice: "auto",
      stream:      false
    }
    body
    |> then(fn b -> if effort, do: Map.merge(b, %{thinking: %{type: "enabled"}, reasoning_effort: effort}), else: b end)
  end

  defp to_anthropic_tools(tools) do
    Enum.map(tools, fn %{function: %{name: name, description: desc, parameters: params}} ->
      %{name: name, description: desc, input_schema: params}
    end)
  end

  defp build_headers(:anthropic, api_key) do
    [{"x-api-key", api_key || ""}, {"anthropic-version", "2023-06-01"}, {"content-type", "application/json"}]
  end
  defp build_headers(_openai_compat, api_key) do
    [authorization: "Bearer #{api_key || ""}"]
  end

  # ── Response extraction ──────────────────────────────────────────────

  defp extract_message(%{"stop_reason" => "tool_use", "content" => blocks}, :anthropic) do
    tool_uses = Enum.filter(blocks, &(&1["type"] == "tool_use"))
    %{
      "content" => nil,
      "tool_calls" => Enum.map(tool_uses, fn tu ->
        %{
          "id" => tu["id"],
          "type" => "function",
          "function" => %{"name" => tu["name"], "arguments" => Jason.encode!(tu["input"])}
        }
      end)
    }
  end

  defp extract_message(%{"choices" => [%{"message" => msg} | _]}, _provider),     do: msg
  defp extract_message(%{"content" => [%{"type" => "text", "text" => t} | _]}, _), do: %{"content" => t}
  defp extract_message(%{"content" => content}, _) when is_binary(content),        do: %{"content" => content}
  defp extract_message(body, _), do: raise("unexpected response shape: #{inspect(body)}")

  # ── Message formatting ────────────────────────────────────────────────

  defp format_message(%{role: "assistant"} = msg) do
    base = %{
      "role" => "assistant",
      "content" => msg["content"] || "",
      "reasoning_content" => msg["reasoning_content"] || ""
    }
    if msg["tool_calls"], do: Map.put(base, "tool_calls", msg["tool_calls"]), else: base
  end
  defp format_message(msg), do: msg

  # ── Response routing ─────────────────────────────────────────────────

  defp handle_response(%{"tool_calls" => tool_calls} = assistant, history, pty_session_id, chat_session_id, opts) do
    %{dispatch: dispatch} = tools()

    results =
      Enum.map(tool_calls, fn tc ->
        name = tc["function"]["name"]
        args = decode_args(tc["function"]["arguments"]) |> Eai.Utils.sanitize_value()

        :telemetry.execute([:eai, :tool, :execute], %{system_time: System.system_time()},
          %{tool: name, pty_session_id: pty_session_id})

        content =
          try do
            case Map.fetch(dispatch, name) do
              {:ok, mod} -> mod.execute(args, pty_session_id, chat_session_id)
              :error     -> Jason.encode!(%{error: "unknown tool: #{name}"})
            end
          rescue
            e ->
              :telemetry.execute([:eai, :tool, :error], %{system_time: System.system_time()},
                %{tool: name, pty_session_id: pty_session_id, error: Exception.message(e)})
              Jason.encode!(%{error: Exception.message(e)})
          end

        %{role: "tool", tool_call_id: tc["id"], content: content}
      end)

    assistant_msg =
      %{"role" => "assistant", "content" => assistant["content"] || "", "tool_calls" => tool_calls}
      |> then(fn m ->
        case assistant["reasoning_content"] do
          rc when is_binary(rc) -> Map.put(m, "reasoning_content", rc)
          _                     -> m
        end
      end)

    run(history ++ [assistant_msg] ++ results, pty_session_id, opts)
  end

  defp handle_response(%{"content" => content}, history, _pty_session_id, _chat_session_id, _opts) do
    final_msg = %{"role" => "assistant", "content" => Eai.Utils.sanitize_value(content)}
    {:ok, Eai.Utils.sanitize_value(content), history ++ [final_msg]}
  end

  # ── Utilities ────────────────────────────────────────────────────────

  defp decode_args(nil), do: %{}
  defp decode_args(""),  do: %{}
  defp decode_args(s),   do: Jason.decode!(s)
end
