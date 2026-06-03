defmodule Eai.Tool.CallSubagent do
  @behaviour Eai.Tool

  def schema do
    %{type: "function", function: %{
      name: "call_subagent",
      description: "Dispatch a sub-task to an independent AI agent...",
      parameters: %{type: "object",
        properties: %{
          message:        %{type: "string", description: "The task or question for the sub-agent."},
          pty_session_id: %{type: "string", description: "Optional PTY session ID."},
          model:          %{type: "string", description: "Optional model name (e.g., 'gpt4o', 'claude_sonnet', 'deepseek')."},
          prompt:         %{type: "string", description: "Optional prompt name (e.g., 'coder', 'analyst')."}
        },
        required: ["message"]
      }
    }}
  end

  def execute(args, _pty_session_id, _chat_session_id) do
    message   = Map.get(args, "message", "")
    model_opt = Map.get(args, "model")
    prompt_opt = Map.get(args, "prompt")
    pty_session_id = Map.get(args, "pty_session_id", "subagent_#{System.unique_integer([:positive])}")
    subagent_task_id = "satask_#{System.unique_integer([:positive, :monotonic])}"

    Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", %{
      status: "running",
      started_at: System.monotonic_time(:millisecond)
    })

    Task.start(fn ->
      opts = [
        pty_session_id: pty_session_id,
        chat_session_id: "subagent_#{subagent_task_id}"
      ]
      opts = if model_opt, do: Keyword.put(opts, :model, String.to_atom(model_opt)), else: opts
      opts = if prompt_opt, do: Keyword.put(opts, :prompt, String.to_atom(prompt_opt)), else: opts
      
      result_entry =
        try do
          case Eai.Chat.send(message, opts) do
            {:ok, response} -> %{status: "complete", answer: response, pty_session_id: pty_session_id}
            {:error, reason} -> %{status: "error", reason: inspect(reason), pty_session_id: pty_session_id}
          end
        rescue
          e -> %{status: "error", reason: Exception.message(e), pty_session_id: pty_session_id}
        end
      Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", result_entry)
    end)

    %{subagent_task_id: subagent_task_id, status: "queued", pty_session_id: pty_session_id}
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end
end