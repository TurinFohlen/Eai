defmodule Eai.Adapter.Converse do
  @behaviour Eai.Adapter
  require Logger
  alias Eai.Message

  @impl true
  def to_request_body(messages, model, system_prompt, tools, opts) do
    region = Keyword.get(opts, :region, System.get_env("AWS_REGION", "us-east-1"))

    converse_messages = Enum.map(messages, &Message.to_converse_map/1)

    # Convert tools from OpenAI schema format to Bedrock toolSpec format
    bedrock_tools = Enum.map(tools, fn
      %{function: %{name: name, description: desc, parameters: params}} ->
        %{"toolSpec" => %{
          "name" => name,
          "description" => desc,
          "inputSchema" => %{"json" => params}
        }}
      %{"toolSpec" => _} = t -> t
      t -> t
    end)

    body = %{
      "modelId" => model,
      "system" => [%{"text" => system_prompt}],
      "messages" => converse_messages
    }

    body = if bedrock_tools != [] do
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
    blocks = Enum.map(content, &block_from_converse/1)
    %{role: :assistant, content: blocks}
  end

  def from_response(%{"content" => content}) do
    # Direct content array (some Converse API variants)
    blocks = Enum.map(content, &block_from_converse/1)
    %{role: :assistant, content: blocks}
  end

  @impl true
  def from_messages(raw_messages) when is_list(raw_messages) do
    Enum.map(raw_messages, &Message.from_converse_map/1)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp block_from_converse(%{"text" => t}), do: {:text, t}

  defp block_from_converse(%{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}}) do
    {:tool_use, [tool_use_id: id, name: name, input: input]}
  end

  defp block_from_converse(other) do
    {:text, inspect(other)}
  end
end
