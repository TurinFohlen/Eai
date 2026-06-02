defmodule Eai.Adapter.OpenAI do
  @behaviour Eai.Adapter
  require Logger
  alias Eai.Message

  @impl true
  def to_request_body(messages, model, system_prompt, tools, _opts) do
    openai_messages =
      [%{role: "system", content: system_prompt} |
       Enum.flat_map(messages, &message_to_openai/1)]

    body = %{
      model: model,
      messages: openai_messages,
      tools: tools,
      tool_choice: "auto",
      stream: false
    }

    # Note: URL/headers are populated by the caller using model config
    %{url: nil, headers: [], json_body: body}
  end

  @impl true
  def from_response(%{"choices" => [%{"message" => msg} | _]}) do
    %{"role" => "assistant", "content" => content, "tool_calls" => tool_calls} = msg
    blocks = []

    # Reasoning content (for deepseek/openai reasoning models)
    reasoning = msg["reasoning_content"] || ""

    blocks =
      if reasoning != "" do
        blocks ++ [{:text, reasoning}]
      else
        blocks
      end

    # Text content
    blocks =
      if is_binary(content) and content != "" and not is_nil(content) do
        blocks ++ [{:text, content}]
      else
        blocks
      end

    # Tool calls
    blocks =
      if is_list(tool_calls) and tool_calls != [] do
        blocks ++ Enum.map(tool_calls, fn tc ->
          args = case tc["function"]["arguments"] do
            s when is_binary(s) -> Jason.decode!(s)
            m when is_map(m) -> m
            _ -> %{}
          end
          {:tool_use, [
            tool_use_id: tc["id"],
            name: tc["function"]["name"],
            input: args
          ]}
        end)
      else
        blocks
      end

    # Ensure we never return empty content — must have at least one text block
    blocks =
      if blocks == [] do
        [{:text, ""}]
      else
        blocks
      end

    %{role: :assistant, content: blocks}
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

  defp message_to_openai(%{role: :user, content: blocks}) do
    {user_blocks, tool_results} = split_blocks(blocks)

    msgs = []

    # User message with text/image blocks
    msgs = if user_blocks != [] do
      msgs ++ [%{"role" => "user", "content" => blocks_to_openai_content(user_blocks)}]
    else
      # Must have a user message even if empty (OpenAI requires alternating)
      msgs ++ [%{"role" => "user", "content" => ""}]
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
      |> Enum.map(fn {:text, t} -> t; {:thinking, t} -> "[thinking] #{t}" end)
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
      Map.put(msg, "tool_calls", tool_calls)
    else
      msg
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
    if Enum.all?(blocks, &(match?({:text, _}, &1) or match?({:thinking, _}, &1))) do
      # Pure text: serialize as string
      blocks
      |> Enum.map(fn {:text, t} -> t; {:thinking, t} -> "[thinking] #{t}" end)
      |> Enum.join("\n")
    else
      # Mixed content: content array
      Enum.map(blocks, fn
        {:thinking, t} ->
          %{"type" => "text", "text" => "[thinking] #{t}"}
        {:text, t} ->
          %{"type" => "text", "text" => t}
        {:image, kw} ->
          format = kw[:format]
          mime = "image/#{format}"
          {:bytes, data} = kw[:source]
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:#{mime};base64,#{data}"}
          }
      end)
    end
  end

  defp tool_result_to_text([{:text, t} | _]), do: t
  defp tool_result_to_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map(fn {:text, t} -> t end)
    |> Enum.join("\n")
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
