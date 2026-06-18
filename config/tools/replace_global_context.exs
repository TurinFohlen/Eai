defmodule Eai.Tool.ReplaceGlobalContext do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "replace_global_context",
        description:
          "RESTORE Eai runtime state from a gzip file written by " <>
            "export_global_context. **Blocking until in-flight tasks complete.** " <>
            "Restore is split by ownership: (1) chat session histories — " <>
            "Eai.System's own domain — are FULLY REPLACED per session " <>
            "(wipe + write the messages from the snapshot). (2) Cache " <>
            "entries are split further: only keys present in the snapshot " <>
            "are written/overwritten; every other key in the cache — user " <>
            "config, environment-derived state, third-party tool caches — " <>
            "is preserved untouched. (3) Keys with prefixes `chat_session:` " <>
            "or `chat_history:` are NEVER included in the snapshot, so " <>
            "any per-session cache layer is never touched by restore. " <>
            "Net effect: the snapshot domain is restored verbatim, the " <>
            "non-snapshot domain is merged additively. Only call when you " <>
            "intend to replace chat history; treat the cache write as a " <>
            "selective merge.",
        parameters: %{
          type: "object",
          properties: %{
            file_path: %{
              type: "string",
              description: "Absolute path to the .gz file to load."
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

    case Eai.System.restore_from_gzip(file_path) do
      {:ok, info} -> Jason.encode!(%{ok: true, info: info})
      {:error, reason} -> Jason.encode!(%{ok: false, error: reason})
    end
  end
end
