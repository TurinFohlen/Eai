defmodule Eai.Tool.ExportChatSessionContext do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "export_chat_session_context",
        description:
          "Export a single chat session's conversation history to a gzip file. " <>
            "For the whole-system snapshot, use export_global_context. " <>
            "Returns the file path.",
        parameters: %{
          type: "object",
          properties: %{
            file_path: %{
              type: "string",
              description: "Absolute path for the .gz file to save to."
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

    case Eai.Naming.chat().export_history(file_path, chat_session_id) do
      {:ok, path} -> Jason.encode!(%{ok: true, file: path})
      {:error, reason} -> Jason.encode!(%{ok: false, error: reason})
    end
  end
end
