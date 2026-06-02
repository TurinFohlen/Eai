defmodule Eai.Message do
  @moduledoc """
  Internal message representation (IR) based on AWS Bedrock Converse API format.

  Uses Elixir tuples for content blocks, providing a unified format that all
  provider adapters can convert to/from. This solves the cross-provider
  compatibility problem and enables multimodal content injection.
  """

  # ── Types ──────────────────────────────────────────────────────────────

  @type role :: :user | :assistant

  @type content_block ::
          {:text, String.t()}
          | {:image, [format: String.t(), source: {:bytes, String.t()}]}
          | {:tool_use, [tool_use_id: String.t(), name: String.t(), input: map()]}
          | {:tool_result, [tool_use_id: String.t(), content: [content_block()]]}

  @type t :: %{role: role(), content: [content_block()]}

  # ── Constructors ───────────────────────────────────────────────────────

  @doc """
  Create a new message.

  When content is a binary, it's wrapped as `[{:text, content}]`.
  When content is a list, it's used directly (must be valid content blocks).
  """
  @spec new(role(), String.t() | [content_block()]) :: t()
  def new(role, content) when is_binary(content) do
    %{role: role, content: [{:text, content}]}
  end

  def new(role, content) when is_list(content) do
    %{role: role, content: content}
  end

  @doc """
  Create a :user message with tool_result block(s), ensuring Anthropic
  compatibility (tool results must be in their own :user message).
  """
  @spec new_tool_result(String.t(), [content_block()]) :: t()
  def new_tool_result(tool_use_id, result_content) do
    %{
      role: :user,
      content: [{:tool_result, [tool_use_id: tool_use_id, content: result_content]}]
    }
  end

  @doc """
  Create a :user message from multimodal_inject blocks returned by read_media_file.
  Input is a list of JSON-decoded maps (the "blocks" array).
  """
  @spec from_inject_blocks([map()]) :: t()
  def from_inject_blocks(blocks) when is_list(blocks) do
    content = Enum.map(blocks, &block_from_json_map/1)
    %{role: :user, content: content}
  end

  # ── JSON <-> Tuple conversion ──────────────────────────────────────────

  @doc """
  Convert internal message to a JSON-friendly map (atom keys → string keys).
  Useful for Bedrock Converse direct pass-through.
  """
  @spec to_converse_map(t()) :: map()
  def to_converse_map(%{role: role, content: content}) do
    %{
      "role" => Atom.to_string(role),
      "content" => Enum.map(content, &block_to_map/1)
    }
  end

  @doc """
  Convert a Converse-format JSON map back to internal message.
  """
  @spec from_converse_map(map()) :: t()
  def from_converse_map(%{"role" => role_str, "content" => content}) do
    role = String.to_existing_atom(role_str)
    %{role: role, content: Enum.map(content, &block_from_map/1)}
  end

  @doc """
  Extract text content from a message as a single string.
  Joins multiple :text blocks with double newline.
  """
  @spec text(t()) :: String.t()
  def text(%{content: blocks}) do
    blocks
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map(fn {:text, t} -> t end)
    |> Enum.join("\n\n")
  end

  @doc """
  Check if message contains any :tool_use blocks.
  """
  @spec has_tool_uses?(t()) :: boolean()
  def has_tool_uses?(%{content: blocks}) do
    Enum.any?(blocks, &match?({:tool_use, _}, &1))
  end

  @doc """
  Extract :tool_use blocks from a message.
  """
  @spec tool_uses(t()) :: [keyword()]
  def tool_uses(%{content: blocks}) do
    Enum.filter(blocks, &match?({:tool_use, _}, &1))
    |> Enum.map(fn {:tool_use, tu} -> tu end)
  end

  @doc """
  Check if the message is effectively empty (no content blocks or only empty text).
  """
  @spec empty?(t()) :: boolean()
  def empty?(%{content: []}), do: true
  def empty?(%{content: [{:text, ""}]}), do: true
  def empty?(_), do: false

  # ── Private: block ↔ map ──────────────────────────────────────────────

  defp block_to_map({:text, t}) do
    %{"text" => t}
  end

  defp block_to_map({:image, kw}) do
    %{
      "image" => %{
        "format" => kw[:format],
        "source" => %{"bytes" => elem(kw[:source], 1)}
      }
    }
  end

  defp block_to_map({:tool_use, kw}) do
    %{
      "toolUse" => %{
        "toolUseId" => kw[:tool_use_id],
        "name" => kw[:name],
        "input" => kw[:input]
      }
    }
  end

  defp block_to_map({:tool_result, kw}) do
    %{
      "toolResult" => %{
        "toolUseId" => kw[:tool_use_id],
        "content" => Enum.map(kw[:content], &block_to_map/1)
      }
    }
  end

  defp block_from_map(%{"text" => t}) do
    {:text, t}
  end

  defp block_from_map(%{"image" => %{"format" => fmt, "source" => %{"bytes" => data}}}) do
    {:image, [format: fmt, source: {:bytes, data}]}
  end

  defp block_from_map(%{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}}) do
    {:tool_use, [tool_use_id: id, name: name, input: input]}
  end

  # Bedrock Converse bare camelCase variant (no "toolUse" wrapper)
  defp block_from_map(%{"toolUseId" => id, "name" => name, "input" => input} = _tool_use_map) do
    {:tool_use, [tool_use_id: id, name: name, input: input]}
  end

  defp block_from_map(%{"toolResult" => %{"toolUseId" => id, "content" => content}}) do
    {:tool_result, [tool_use_id: id, content: Enum.map(content, &block_from_map/1)]}
  end

  # For reading inject blocks from read_media_file JSON
  defp block_from_json_map(%{"text" => t}) do
    {:text, t}
  end

  defp block_from_json_map(%{"image" => %{"format" => fmt, "source" => %{"bytes" => data}}}) do
    {:image, [format: fmt, source: {:bytes, data}]}
  end

  defp block_from_json_map(other) do
    {:text, "unexpected block: #{inspect(other)}"}
  end


end
