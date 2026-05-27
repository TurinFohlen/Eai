defmodule Eai.LLM.Direct do
  @moduledoc "直接调用 DeepSeek API，含 telemetry 埋点"

  alias Eai.ResultCollector
  alias Eai.Sandbox.PTYPool
  alias Eai.Utils

  # ── 配置读取（运行时，重启即生效，无需重新编译）────────────────────────────
  defp llm_cfg(key),     do: Application.fetch_env!(:eai, :llm)           |> Keyword.fetch!(key)
  defp sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox)        |> Keyword.fetch!(key)
  defp system_prompt,    do: Application.fetch_env!(:eai, :system_prompt)

  @tools [
    %{type: "function", function: %{
        name: "get_local_time",
        description: "Returns current UTC time in ISO-8601 format.",
        parameters: %{type: "object", properties: %{}, required: []}
    }},
    %{type: "function", function: %{
        name: "execute_script",
        description: """
        Execute a bash script inside a persistent PTY session.
        Returns a task_id immediately (async). Use get_task_result to poll for output.
        """,
        parameters: %{type: "object",
          properties: %{
            script:   %{type: "string", description: "Bash script content to execute."},
            agent_id: %{type: "string", description: "PTY session ID (default: 'default')."}
          },
          required: ["script"]
        }
    }},
    %{type: "function", function: %{
        name: "get_task_result",
        description: """
        Retrieve the output of a previously submitted script by task_id.
        Poll until status == 'complete'. Wait at least 5 s after execute_script before first poll.
        """,
        parameters: %{type: "object",
          properties: %{task_id: %{type: "string", description: "task_id returned by execute_script."}},
          required: ["task_id"]
        }
    }},
    %{type: "function", function: %{
        name: "reset_session",
        description: """
        Force-kill a stuck or unresponsive PTY session.
        Always call list_sessions first to identify the correct agent_id.
        After reset, the next execute_script will automatically create a fresh session.
        """,
        parameters: %{type: "object",
          properties: %{agent_id: %{type: "string", description: "Session ID to reset."}},
          required: ["agent_id"]
        }
    }},
    %{type: "function", function: %{
        name: "list_sessions",
        description: "List all active PTY sessions with their status and current task.",
        parameters: %{type: "object", properties: %{}, required: []}
    }},
    %{type: "function", function: %{
        name: "call_subagent",
        description: "Ask another independent AI agent to solve a sub-task. Returns its final answer. Do not use recursively.",
        parameters: %{type: "object",
          properties: %{
            message: %{type: "string", description: "The task or question for the sub-agent."},
            agent_id: %{type: "string", description: "Optional session ID for the sub-agent. Defaults to 'subagent'."}
          },
          required: ["message"]
        }
    }}
  ]

  def run(messages, agent_id \\ "default") do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    formatted =
      messages
      |> Enum.map(&format_message/1)
      |> Utils.sanitize_messages()

    body = %{
      model:            llm_cfg(:model),
      messages:         [%{role: "system", content: system_prompt()} | formatted],
      tools:            @tools,
      tool_choice:      "auto",
      thinking:         %{type: "enabled"},
      reasoning_effort: llm_cfg(:reasoning_effort),
      stream:           false
    }

    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:eai, :llm, :request, :start], %{system_time: System.system_time()}, %{agent_id: agent_id})

    result = Req.post(llm_cfg(:url),
      json: body,
      headers: [authorization: "Bearer #{api_key}"],
      receive_timeout: llm_cfg(:receive_timeout)
    )

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]}}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{agent_id: agent_id, status: :ok})
        handle_response(msg, messages, agent_id)

      {:ok, %{status: status, body: body}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{agent_id: agent_id, status: :error})
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{agent_id: agent_id, status: :error})
        {:error, reason}
    end
  end

  # assistant 消息：reasoning_content 原样回传（空也要传，有语义）
  defp format_message(%{role: "assistant"} = msg) do
    base = Map.take(msg, [:role, :content, :tool_calls, :reasoning_content])
    Enum.reject(base, fn {_, v} -> is_nil(v) end) |> Map.new()
  end
  defp format_message(msg), do: msg

  defp handle_response(%{"tool_calls" => tool_calls} = assistant, history, agent_id) do
    tool_results = Enum.map(tool_calls, fn tc ->
      name = tc["function"]["name"]
      args = tc["function"]["arguments"] |> decode_args() |> Utils.sanitize_value()

      :telemetry.execute([:eai, :tool, :execute], %{system_time: System.system_time()}, %{tool: name, agent_id: agent_id})

      result = execute_tool(name, args, agent_id)
      %{role: "tool", tool_call_id: tc["id"], content: result}
    end)

    assistant_msg = %{role: "assistant", content: assistant["content"] || "", tool_calls: tool_calls}
    assistant_msg = case assistant["reasoning_content"] do
      rc when is_binary(rc) -> Map.put(assistant_msg, :reasoning_content, rc)
      _                     -> assistant_msg
    end

    run(history ++ [assistant_msg] ++ tool_results, agent_id)
  end

  defp handle_response(%{"content" => content}, _history, _agent_id) do
    {:ok, Utils.sanitize_value(content)}
  end

  # ── 工具执行 ──────────────────────────────────────────────────────────────

  defp execute_tool("get_local_time", _args, _agent_id) do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp execute_tool("execute_script", args, agent_id) do
    sid     = Map.get(args, "agent_id", agent_id)
    script  = Map.get(args, "script", "")
    task_id = "task_#{System.unique_integer([:positive, :monotonic])}"
    prefix  = sandbox_cfg(:script_tmp_prefix)
    path    = "#{prefix}#{task_id}.sh"

    with :ok <- File.write(path, script),
         {:ok, ^task_id} <- PTYPool.exec_async(sid, "bash #{path}; rm -f #{path}", task_id) do
      %{task_id: task_id, status: "queued"}
      |> Utils.sanitize_value()
      |> Jason.encode!()
    else
      err ->
        %{error: inspect(err)}
        |> Utils.sanitize_value()
        |> Jason.encode!()
    end
  end

  defp execute_tool("get_task_result", args, _agent_id) do
    case args["task_id"] do
      nil ->
        Jason.encode!(%{error: "missing task_id"})

      task_id ->
        result = case ResultCollector.get(task_id) do
          %{status: "complete", output: output} -> %{status: "complete", output: output}
          %{status: status}                     -> %{status: status}
          nil                                   -> %{status: "not_found"}
        end
        result |> Utils.sanitize_value() |> Jason.encode!()
    end
  end

  defp execute_tool("reset_session", args, agent_id) do
    target = Map.get(args, "agent_id", agent_id)
    PTYPool.force_reset(target)
    %{status: "ok", message: "Session #{target} killed. Next execute_script creates fresh session."}
    |> Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp execute_tool("list_sessions", _args, _agent_id) do
    PTYPool.list_sessions()
    |> Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp execute_tool("call_subagent", args, _parent_agent_id) do
    message  = Map.get(args, "message", "")
    agent_id = Map.get(args, "agent_id", "subagent_#{System.unique_integer([:positive])}")

    case Eai.Chat.send(message, agent_id) do
      {:ok, response} ->
        %{status: "success", answer: response, sub_agent_id: agent_id}
        |> Utils.sanitize_value() |> Jason.encode!()
      {:error, reason} ->
        %{status: "error", reason: inspect(reason)}
        |> Utils.sanitize_value() |> Jason.encode!()
    end
  end

  defp execute_tool(name, _args, _agent_id) do
    Jason.encode!(%{error: "unknown tool: #{name}"})
  end

  defp decode_args(nil), do: %{}
  defp decode_args(""),  do: %{}
  defp decode_args(s),   do: Jason.decode!(s)
end
