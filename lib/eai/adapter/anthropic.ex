defmodule Eai.Adapter.Anthropic do
  @moduledoc "Anthropic Messages API wire format adapter."

  @behaviour Eai.Adapter

  @impl true
  def to_request_body(messages, model, system_prompt, tools, opts) do
    effort = Keyword.get(opts, :reasoning_effort)
    :telemetry.execute(
      [:eai, :adapter, :anthropic, :to_request_body],
      %{msgs: length(messages), tools: length(tools)},
      %{model: model, effort: effort}
    )

    # System prompt as content-block list with cache breakpoint
    system = [%{type: "text", text: system_prompt, cache_control: %{type: "ephemeral"}}]

    # Convert tools to Anthropic format
    anthropic_tools = to_anthropic_tools(tools)

    # Pin cache_control on last tool
    anthropic_tools =
      case List.pop_at(anthropic_tools, -1) do
        {last, rest} when not is_nil(last) ->
          rest ++ [Map.put(last, :cache_control, %{type: "ephemeral"})]

        _ ->
          anthropic_tools
      end

    anthropic_messages = messages |> Enum.flat_map(&message_to_anthropic/1)
    anthropic_messages = mark_message_cache_breakpoints(anthropic_messages)

    body = %{
      model: model,
      max_tokens: 8192,
      system: system,
      messages: anthropic_messages,
      tools: anthropic_tools
    }

    body =
      if effort do
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: 5000})
      else
        body
      end

    %{url: nil, headers: [], json_body: body}
  end

  @impl true
  def from_response(%{"content" => blocks}) do
    :telemetry.execute(
      [:eai, :adapter, :anthropic, :from_response],
      %{blocks: length(blocks)},
      %{}
    )
    ir_blocks = Enum.map(blocks, &anthropic_block_to_ir/1)

    ir_blocks =
      if ir_blocks == [] do
        [{:text, ""}]
      else
        ir_blocks
      end

    %{role: :assistant, content: ir_blocks}
  end

  @impl true
  def from_messages(raw_messages) when is_list(raw_messages) do
    :telemetry.execute(
      [:eai, :adapter, :anthropic, :from_messages],
      %{count: length(raw_messages)},
      %{}
    )
    Enum.flat_map(raw_messages, fn
      %{"role" => "user", "content" => content} ->
        blocks = content |> List.wrap() |> Enum.map(&anthropic_content_to_ir_block/1)
        [%{role: :user, content: blocks}]

      %{"role" => "assistant", "content" => content} ->
        blocks = content |> List.wrap() |> Enum.map(&anthropic_block_to_ir/1)
        [%{role: :assistant, content: blocks}]

      _ ->
        []
    end)
  end

  # ── Private: IR → Anthropic ──────────────────────────────────────────

  defp message_to_anthropic(%{role: :user, content: blocks}) do
    {text_image_blocks, tool_results} = split_user_blocks(blocks)

    msgs = []

    # Text + image blocks as a user message
    msgs =
      if text_image_blocks != [] do
        anthropic_content = Enum.map(text_image_blocks, &ir_block_to_anthropic_content/1)
        msgs ++ [%{role: "user", content: anthropic_content}]
      else
        msgs
      end

    # Tool results MUST be separate user messages (Anthropic requirement)
    msgs =
      msgs ++
        Enum.map(tool_results, fn {:tool_result, kw} ->
          result_content = Enum.map(kw[:content], &ir_block_to_anthropic_content/1)

          # Anthropic requires tool_result content to be a string (not array) when pure text
          result_payload =
            if match?([%{type: "text", text: _}], result_content) do
              hd(result_content).text
            else
              result_content
            end

          %{
            role: "user",
            content: [
              %{
                type: "tool_result",
                tool_use_id: kw[:tool_use_id],
                content: result_payload
              }
            ]
          }
        end)

    # If no messages produced (empty user), add placeholder (shouldn't happen normally)
    if msgs == [] do
      [%{role: "user", content: [%{type: "text", text: ""}]}]
    else
      msgs
    end
  end

  defp message_to_anthropic(%{role: :assistant, content: blocks}) do
    anthropic_content = Enum.map(blocks, &ir_block_to_anthropic_content/1)

    if anthropic_content == [] do
      [%{role: "assistant", content: [%{type: "text", text: ""}]}]
    else
      [%{role: "assistant", content: anthropic_content}]
    end
  end

  # Pin Anthropic prompt cache breakpoints on the last N assistant messages.
  #
  # Anthropic's cache is prefix-matched: a breakpoint at position P caches
  # everything before P. The closer to the end, the more we save on the next
  # turn (the entire prefix becomes a cache hit).
  #
  # Anthropic allows max 4 cache_control markers per request:
  #   - system prompt:  1 (already pinned above)
  #   - last tool:      1 (already pinned above)
  #   - messages:       2 (we pin the last 2 assistant messages here)
  #
  # Each IR assistant expands to exactly one Anthropic assistant message, so
  # "last 2 assistant messages" is stable across the flat_map expansion done
  # in to_request_body/5.
  @max_message_cache_breakpoints 2

  defp mark_message_cache_breakpoints(msgs) do
    assistant_indices =
      msgs
      |> Enum.with_index()
      |> Enum.filter(fn {%{role: role}, _idx} -> role == "assistant" end)
      |> Enum.map(fn {_msg, idx} -> idx end)
      |> Enum.take(-@max_message_cache_breakpoints)
      |> MapSet.new()

    if MapSet.size(assistant_indices) == 0 do
      msgs
    else
      msgs
      |> Enum.with_index()
      |> Enum.map(&maybe_put_cache_on_message(&1, assistant_indices))
    end
  end

  defp maybe_put_cache_on_message({msg, idx}, assistant_indices) do
    if MapSet.member?(assistant_indices, idx),
      do: put_cache_on_last_block(msg),
      else: msg
  end

  # Put a cache_control marker on the last content block of a message.
  # Falls through unchanged if the content isn't a non-empty list (e.g. legacy
  # string content or empty content).
  defp put_cache_on_last_block(%{content: content} = msg) when is_list(content) and content != [] do
    case List.pop_at(content, -1) do
      {nil, _} ->
        msg

      {last_block, rest} ->
        marked = Map.put(last_block, :cache_control, %{type: "ephemeral"})
        %{msg | content: rest ++ [marked]}
    end
  end

  defp put_cache_on_last_block(msg), do: msg

  # Split user blocks: text/image vs tool_result
  defp split_user_blocks(blocks) do
    {
      Enum.reject(blocks, &match?({:tool_result, _}, &1)),
      Enum.filter(blocks, &match?({:tool_result, _}, &1))
    }
  end

  # IR content block → Anthropic content map
  defp ir_block_to_anthropic_content({:text, t}) do
    %{type: "text", text: t}
  end

  defp ir_block_to_anthropic_content({:image, kw}) do
    {:bytes, data} = kw[:source]

    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: "image/#{kw[:format]}",
        data: data
      }
    }
  end

  defp ir_block_to_anthropic_content({:thinking, t}) do
    %{type: "thinking", thinking: t}
  end

  defp ir_block_to_anthropic_content({:tool_use, kw}) do
    %{
      type: "tool_use",
      id: kw[:tool_use_id],
      name: kw[:name],
      input: kw[:input]
    }
  end

  # Tool results are nested inside the tool_result wrapper, not top-level content
  defp ir_block_to_anthropic_content({:tool_result, _kw}) do
    %{type: "text", text: ""}
  end

  # ── Private: Anthropic → IR ──────────────────────────────────────────

  defp anthropic_block_to_ir(%{"type" => "text", "text" => t}) do
    {:text, t}
  end

  # Thinking blocks — preserve even empty ones (Anthropic requires round-trip)
  defp anthropic_block_to_ir(%{"type" => "thinking", "thinking" => t}) do
    {:thinking, t}
  end

  defp anthropic_block_to_ir(%{"type" => "redacted_thinking", "data" => t}) do
    {:thinking, t}
  end

  # Handle string content from Anthropic (legacy: assistant content as string)
  defp anthropic_block_to_ir(%{"text" => t}) do
    {:text, t}
  end

  defp anthropic_block_to_ir(%{
         "type" => "image",
         "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
       }) do
    format = String.replace_prefix(mime, "image/", "")
    {:image, [format: format, source: {:bytes, data}]}
  end

  defp anthropic_block_to_ir(%{
         "type" => "tool_use",
         "id" => id,
         "name" => name,
         "input" => input
       }) do
    {:tool_use, [tool_use_id: id, name: name, input: input]}
  end

  defp anthropic_block_to_ir(%{
         "type" => "tool_result",
         "tool_use_id" => id,
         "content" => content
       }) do
    result_blocks = content |> List.wrap() |> Enum.map(&anthropic_block_to_ir/1)
    {:tool_result, [tool_use_id: id, content: result_blocks]}
  end

  defp anthropic_block_to_ir(other) do
    {:text, inspect(other)}
  end

  # For from_messages: raw user content → IR block
  defp anthropic_content_to_ir_block(%{"type" => "text", "text" => t}), do: {:text, t}
  defp anthropic_content_to_ir_block(%{"type" => "thinking", "thinking" => t}), do: {:thinking, t}

  defp anthropic_content_to_ir_block(%{"type" => "redacted_thinking", "data" => t}),
    do: {:thinking, t}

  defp anthropic_content_to_ir_block(%{
         "type" => "image",
         "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
       }) do
    format = String.replace_prefix(mime, "image/", "")
    {:image, [format: format, source: {:bytes, data}]}
  end

  defp anthropic_content_to_ir_block(%{
         "type" => "tool_result",
         "tool_use_id" => id,
         "content" => content
       }) do
    result_blocks = content |> List.wrap() |> Enum.map(&anthropic_content_to_ir_block/1)
    {:tool_result, [tool_use_id: id, content: result_blocks]}
  end

  defp anthropic_content_to_ir_block(%{
         "type" => "tool_use",
         "id" => id,
         "name" => name,
         "input" => input
       }) do
    {:tool_use, [tool_use_id: id, name: name, input: input]}
  end

  defp anthropic_content_to_ir_block(other) do
    {:text, inspect(other)}
  end

  # ── Tool schema conversion ──────────────────────────────────────────

  defp to_anthropic_tools(tools) do
    Enum.map(tools, fn
      %{function: %{name: name, description: desc, parameters: params}} ->
        %{name: name, description: desc, input_schema: params}

      %{name: name, description: desc, input_schema: params} ->
        %{name: name, description: desc, input_schema: params}
    end)
  end
end
