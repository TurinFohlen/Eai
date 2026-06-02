defmodule Eai.Tool.ReplaceContext do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "replace_context",
      description: "Replace the current conversation history with the content of a previously exported .gz file.",
      parameters: %{type: "object",
        properties: %{file_path: %{type: "string", description: "Absolute path to the .gz file to load."}},
        required: ["file_path"]
      }
    }}
  end

  @impl true
  def execute(args, _pty_session_id, chat_session_id) do
    file_path = args["file_path"]
    case Eai.Naming.chat().replace_history(file_path, chat_session_id) do
      {:ok, count} -> Jason.encode!(%{ok: true, messages_loaded: count})
      {:error, reason} -> Jason.encode!(%{ok: false, error: reason})
    end
  end
end
