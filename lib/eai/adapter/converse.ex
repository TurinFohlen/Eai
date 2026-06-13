defmodule Eai.Adapter.Converse do
  @moduledoc "AWS Bedrock Converse API wire format adapter."

  @behaviour Eai.Adapter
  alias Eai.Message

  @impl true
  def to_request_body(messages, model, system_prompt, tools, opts) do
    region = Keyword.get(opts, :region, System.get_env("AWS_REGION", "us-east-1"))
    :telemetry.execute(
      [:eai, :adapter, :converse, :to_request_body],
      %{msgs: length(messages), tools: length(tools)},
      %{model: model, region: region}
    )

    converse_messages = Enum.map(messages, &Message.to_converse_map/1)

    # Convert tools from OpenAI schema format to Bedrock toolSpec format
    bedrock_tools =
      Enum.map(tools, fn
        %{function: %{name: name, description: desc, parameters: params}} ->
          %{
            "toolSpec" => %{
              "name" => name,
              "description" => desc,
              "inputSchema" => %{"json" => params}
            }
          }

        %{"toolSpec" => _} = t ->
          t

        t ->
          t
      end)

    body = %{
      "modelId" => model,
      "system" => [%{"text" => system_prompt}],
      "messages" => converse_messages
    }

    body =
      if bedrock_tools != [] do
        Map.put(body, "toolConfig", %{"tools" => bedrock_tools})
      else
        body
      end

    url = "https://bedrock-runtime.#{region}.amazonaws.com/model/#{model}/converse"

    # Headers: actual auth would use SigV4 — placeholder for now
    headers = [{"content-type", "application/json"}]

    %{url: url, headers: headers, json_body: body}
  end

  @impl true
  def from_response(%{"output" => %{"message" => %{"role" => "assistant", "content" => content}}}) do
    :telemetry.execute(
      [:eai, :adapter, :converse, :from_response],
      %{blocks: length(content)},
      %{shape: :output_message}
    )
    blocks = Enum.map(content, &block_from_converse/1)
    %{role: :assistant, content: blocks}
  end

  def from_response(%{"content" => content}) do
    :telemetry.execute(
      [:eai, :adapter, :converse, :from_response],
      %{blocks: length(content)},
      %{shape: :content_array}
    )
    blocks = Enum.map(content, &block_from_converse/1)
    %{role: :assistant, content: blocks}
  end

  @impl true
  def from_messages(raw_messages) when is_list(raw_messages) do
    :telemetry.execute(
      [:eai, :adapter, :converse, :from_messages],
      %{count: length(raw_messages)},
      %{}
    )
    Enum.map(raw_messages, &Message.from_converse_map/1)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp block_from_converse(%{"text" => t}), do: {:text, t}
  defp block_from_converse(%{"thinking" => t}), do: {:thinking, t}
  defp block_from_converse(%{"redactedThinking" => t}), do: {:thinking, t}

  defp block_from_converse(%{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}}) do
    {:tool_use, [tool_use_id: id, name: name, input: input]}
  end

  defp block_from_converse(other) do
    {:text, inspect(other)}
  end
end
