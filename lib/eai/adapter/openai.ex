defmodule Eai.Adapter.OpenAI do
  @moduledoc "OpenAI-compatible wire format adapter (also used for DeepSeek and similar providers)."

  @behaviour Eai.Adapter
  require Logger
  alias Eai.Message
@impl true
def to_request_body(messages, model, system_prompt, tools, opts) do
  effort = Keyword.get(opts, :reasoning_effort)

  openai_messages =
    [%{"role" => "system", "content" => system_prompt} |
     Enum.flat_map(messages, &message_to_openai/1)]

  body = %{
    model: model,
    messages: openai_messages,
    tools: tools,
    tool_choice: "auto",
    stream: false
  }

  body = if effort do
    Map.put(body, :reasoning_effort, effort)
  else
    body
  end

  %{url: nil, headers: [], json_body: body}
end
@impl true
def from_response(%{"choices" => [%{"message" => msg} | _]}) do
  content = msg["content"]
  reasoning = msg["reasoning_content"]
  tool_calls = msg["tool_calls"]

  blocks = []

  # 1. 思考内容 → :thinking 块（原样保留，便于 Anthropic 往返）
  blocks =
    if is_binary(reasoning) and reasoning != "" do
      [{:thinking, reasoning} | blocks]
    else
      blocks
    end

  # 2. 文本内容 → :text 块（可能为 nil）
  blocks =
    if is_binary(content) and content != "" do
      [{:text, content} | blocks]
    else
      blocks
    end

  # 3. 工具调用 → :tool_use 块
  blocks =
    if is_list(tool_calls) and tool_calls != [] do
      Enum.map(tool_calls, &tool_call_to_block/1) ++ blocks
    else
      blocks
    end

  # 4. 确保至少有一个 :text 块（防止空 content 导致下游出错）
  blocks = if blocks == [], do: [{:text, ""}], else: blocks

  %{role: :assistant, content: Enum.reverse(blocks)}
end

  @impl true
  def from_messages(raw_messages) when is_list(raw_messages) do
    Enum.flat_map(raw_messages, fn
      %{"role" => "system"} -> []  # skip system messages
      %{"role" => "user", "content" => content} ->
        [message_from_openai_user(content)]

      %{"role" => "assistant"} = msg ->
        [from_response(%{"choices" => [%{"message" => msg}]})]

      %{"role" => "tool", "tool_call_id" => tool_call_id, "content" => content} ->
        result_content = [{:text, content}]
        [Message.new_tool_result(tool_call_id, result_content)]

      _ -> []
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp tool_call_to_block(tc) do
    args = decode_tool_args(tc["function"]["arguments"])
    {:tool_use, [tool_use_id: tc["id"], name: tc["function"]["name"], input: args]}
  end

  defp decode_tool_args(s) when is_binary(s), do: Jason.decode!(s)
  defp decode_tool_args(m) when is_map(m),    do: m
  defp decode_tool_args(_),                   do: %{}

  defp message_to_openai(%{role: :user, content: blocks}) do
    {user_blocks, tool_results} = split_blocks(blocks)

    msgs = []

    # Only add a user message when there is actual user content.
    # Pure tool-result messages must NOT have a preceding empty user turn —
    # OpenAI requires assistant(tool_calls) → tool(results) with nothing in between.
    msgs = if user_blocks != [] do
      msgs ++ [%{"role" => "user", "content" => blocks_to_openai_content(user_blocks)}]
    else
      msgs
    end

    # Tool results as separate role: "tool" messages
    msgs = msgs ++ Enum.map(tool_results, fn {:tool_result, kw} ->
      %{
        "role" => "tool",
        "tool_call_id" => kw[:tool_use_id],
        "content" => tool_result_to_text(kw[:content])
      }
    end)

    msgs
  end

  defp message_to_openai(%{role: :assistant, content: blocks}) do
    {text_blocks, tool_use_blocks} = split_assistant_blocks(blocks)

    text_content =
      text_blocks
      |> Enum.flat_map(fn
        {:text, t}     -> [t]
        {:thinking, _} -> []
      end)
      |> Enum.join("\n")

    msg = %{
      "role" => "assistant",
      "content" => (if text_content == "", do: nil, else: text_content)
    }

    if tool_use_blocks != [] do
      tool_calls = Enum.map(tool_use_blocks, fn {:tool_use, kw} ->
        %{
          "id" => kw[:tool_use_id],
          "type" => "function",
          "function" => %{
            "name" => kw[:name],
            "arguments" => Jason.encode!(kw[:input])
          }
        }
      end)
      [Map.put(msg, "tool_calls", tool_calls)]
    else
      [msg]
    end
  end

  # Split user blocks into text/image vs tool_result
  defp split_blocks(blocks) do
    user_blocks = Enum.reject(blocks, &match?({:tool_result, _}, &1))
    tool_results = Enum.filter(blocks, &match?({:tool_result, _}, &1))
    {user_blocks, tool_results}
  end

  # Split assistant blocks into text vs tool_use
  defp split_assistant_blocks(blocks) do
    text_blocks = Enum.filter(blocks, &(match?({:text, _}, &1) or match?({:thinking, _}, &1)))
    tool_use_blocks = Enum.filter(blocks, &match?({:tool_use, _}, &1))
    {text_blocks, tool_use_blocks}
  end

  defp blocks_to_openai_content(blocks) do
    visible = Enum.reject(blocks, &match?({:thinking, _}, &1))

    if Enum.all?(visible, &match?({:text, _}, &1)) do
      visible
      |> Enum.map_join("\n", fn {:text, t} -> t end)
    else
      Enum.flat_map(visible, fn
        {:text, t} ->
          [%{"type" => "text", "text" => t}]
        {:image, kw} ->
          format = kw[:format]
          {:bytes, data} = kw[:source]
          [%{
            "type" => "image_url",
            "image_url" => %{"url" => "data:image/#{format};base64,#{data}"}
          }]
      end)
    end
  end

  defp tool_result_to_text([{:text, t} | _]), do: t
  defp tool_result_to_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("\n", fn {:text, t} -> t end)
  end

  defp message_from_openai_user(content) when is_binary(content) do
    Message.new(:user, content)
  end

  defp message_from_openai_user(content) when is_list(content) do
    blocks = Enum.map(content, fn
      %{"type" => "text", "text" => t} ->
        {:text, t}
      %{"type" => "image_url", "image_url" => %{"url" => url}} ->
        # Parse data:image/png;base64,...
        [mime_part, data] = String.split(url, ",", parts: 2)
        fmt = mime_part
              |> String.replace_prefix("data:image/", "")
              |> String.replace_suffix(";base64", "")
        {:image, [format: fmt, source: {:bytes, data}]}
    end)
    %{role: :user, content: blocks}
  end
end
