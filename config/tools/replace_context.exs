defmodule Eai.Tool.ReplaceContext do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "replace_context",
        description: """
        Replace the current conversation history with the content of a
        previously exported .gz file. Supports converse/openai/anthropic formats.
        Used to restore context from backup or to inject pre-loaded history.
        """

        The format parameter tells the system how to interpret the stored messages:
        - \"converse\" (default): Messages are in Eai's native Converse-based IR format.
        - \"openai\": Messages are in OpenAI Chat Completions format (with \"role\": \"tool\", \"tool_calls\").
        - \"anthropic\": Messages are in Anthropic Messages API format.
        """,
        parameters: %{
          type: "object",
          properties: %{
            file_path: %{type: "string", description: "Absolute path to the .gz file to load."},
            format: %{
              type: "string",
              enum: ["converse", "openai", "anthropic"],
              description: "Format of messages in the file. Defaults to \"converse\"."
            }
          },
          required: ["file_path"]
        }
      }
    }
  end

  @impl true
  def execute(args, _pty_session_id, chat_session_id) do
    file_path = args["file_path"]
    format = args["format"] || "converse"

    case Eai.Naming.chat().replace_history(file_path, chat_session_id, format) do
      {:ok, count} -> Jason.encode!(%{ok: true, messages_loaded: count})
      {:error, reason} -> Jason.encode!(%{ok: false, error: reason})
    end
  end
end
