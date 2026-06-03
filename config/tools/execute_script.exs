defmodule Eai.Tool.ExecuteScript do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "execute_script",
      description: """
      Execute a bash script inside a persistent PTY session.
      Returns a task_id immediately (async). Use get_task_result to poll for output.
      """,
      parameters: %{type: "object",
        properties: %{
          script:         %{type: "string", description: "Bash script content to execute."},
          pty_session_id: %{type: "string", description: "PTY session ID (default: 'default')."}
        },
        required: ["script"]
      }
    }}
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    sid     = Map.get(args, "pty_session_id", pty_session_id)
    script  = Map.get(args, "script", "")
    task_id = "task_#{System.unique_integer([:positive, :monotonic])}"
    prefix  = Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(:script_tmp_prefix)
    path    = "#{prefix}#{task_id}.sh"

    with :ok <- File.write(path, script),
         :ok <- debug_script(path, script),
         {:ok, ^task_id} <- Eai.Naming.pool().exec_async(sid, "bash #{path}; rm -f #{path}", task_id) do
      %{task_id: task_id, status: "queued"}
      |> Eai.Utils.sanitize_value()
      |> Jason.encode!()
    else
      err ->
        %{error: inspect(err)}
        |> Eai.Utils.sanitize_value()
        |> Jason.encode!()
    end
  end

  defp debug_script(path, script) do
    if Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(:debug_pty_output) do
      IO.puts("\n=== SCRIPT START [#{path}] ===\n#{script}\n=== SCRIPT END ===")
    end
    :ok
  end
end
