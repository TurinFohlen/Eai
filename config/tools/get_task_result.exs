defmodule Eai.Tool.GetTaskResult do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "get_task_result",
        description: """
        Retrieve the output of a previously submitted script by task_id.
        Poll until status == 'complete'. Wait at least 5 s after execute_script before first poll.
        """,
        parameters: %{
          type: "object",
          properties: %{
            task_id: %{type: "string", description: "task_id returned by execute_script."}
          },
          required: ["task_id"]
        }
      }
    }
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    Process.sleep(Application.get_env(:eai, :poll_cooldown_ms))

    case args["task_id"] do
      nil ->
        Jason.encode!(%{error: "missing task_id"})

      task_id ->
        if Eai.ResultCollector.check_and_clear_interrupt_flag(pty_session_id) do
          Eai.Naming.pool().interrupt_task(pty_session_id)

          %{status: "complete", output: "Task forcefully interrupted by user. Please reply now."}
          |> Eai.Utils.sanitize_value()
          |> Jason.encode!()
        else
          case Eai.ResultCollector.check_timeout_window(pty_session_id) do
            msg when is_binary(msg) ->
              %{status: "complete", output: msg} |> Eai.Utils.sanitize_value() |> Jason.encode!()

            _ ->
              result =
                case Eai.ResultCollector.get(task_id) do
                  %{status: "complete", output: output} ->
                    %{status: "complete", output: output}

                  %{started_at: started_at} when not is_nil(started_at) ->
                    %{status: "running", time: System.monotonic_time(:millisecond) - started_at}

                  %{} ->
                    %{status: "running", time: 0}

                  nil ->
                    %{status: "not_found"}
                end

              result |> Eai.Utils.sanitize_value() |> Jason.encode!()
          end
        end
    end
  end
end
