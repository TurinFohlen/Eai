defmodule Eai.Tool.ExportGlobalContext do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "export_global_context",
        description:
          "Snapshot the entire Eai runtime state to a gzip file. " <>
            "Includes all chat session conversation histories and all runtime " <>
            "cache entries (subagent results, subagent queues, PTY task results, " <>
            "control flags). USE WITH CARE: this blocks until all in-flight " <>
            "tasks complete, and the resulting file is meant to be reloaded via " <>
            "replace_global_context.",
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
  def execute(args, _pty_session_id, _chat_session_id) do
    file_path = args["file_path"]

    case Eai.System.snapshot_to_gzip(file_path) do
      {:ok, info} -> Jason.encode!(%{ok: true, info: info})
      {:error, reason} -> Jason.encode!(%{ok: false, error: reason})
    end
  end
end
