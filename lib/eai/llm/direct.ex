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
    }},
    %{type: "function", function: %{
        name: "write_to_session",
        description: """
        Write raw bytes directly to a PTY session's stdin, bypassing the sentinel wrapper.
        Use ONLY when the session is waiting for interactive input (e.g. after seeing [Y/n], Password:, etc.).
        Do NOT use for normal script execution — use execute_script for that.
        """,
        parameters: %{type: "object",
          properties: %{
            input:    %{type: "string", description: "The exact string to write to the PTY (e.g. \"y\\n\", \"no\\n\", \"mypassword\\n\")."},
            agent_id: %{type: "string", description: "PTY session ID (default: 'default')."}
          },
          required: ["input"]
        }
    }},
    %{type: "function", function: %{
        name: "force_complete_task",
        description: """
        Force-collect whatever output a task has produced so far and mark it complete.
        Use when a task is stuck or taking too long and you want to retrieve partial output
        without sending Ctrl+C. The task_id must be the one returned by execute_script.
        After calling this, the session is unlocked and ready for the next execute_script.
        """,
        parameters: %{type: "object",
          properties: %{
            task_id:  %{type: "string", description: "The task_id to force-complete."},
            agent_id: %{type: "string", description: "PTY session ID (default: 'default')."}
          },
          required: ["task_id"]
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
        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{agent_id: agent_id, reason: "HTTP #{status}", body: inspect(body)})
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{agent_id: agent_id, status: :error})
        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{agent_id: agent_id, reason: inspect(reason)})
        {:error, reason}
    end
  end

  # ── 消息格式化（全部使用 string keys，确保 DeepSeek 不报错） ──
  defp format_message(%{role: "assistant"} = msg) do
    base = %{
      "role" => "assistant",
      "content" => msg["content"] || "",
      "reasoning_content" => msg["reasoning_content"] || ""
    }
    if msg["tool_calls"] do
      Map.put(base, "tool_calls", msg["tool_calls"])
    else
      base
    end
  end
  defp format_message(msg), do: msg

  defp handle_response(%{"tool_calls" => tool_calls} = assistant, history, agent_id) do
    tool_results = Enum.map(tool_calls, fn tc ->
      name = tc["function"]["name"]
      args = tc["function"]["arguments"] |> decode_args() |> Utils.sanitize_value()

      :telemetry.execute([:eai, :tool, :execute], %{system_time: System.system_time()}, %{tool: name, agent_id: agent_id})

      result =
        try do
          execute_tool(name, args, agent_id)
        rescue
          e ->
            :telemetry.execute([:eai, :tool, :error], %{system_time: System.system_time()}, %{tool: name, agent_id: agent_id, error: Exception.message(e)})
            Jason.encode!(%{error: Exception.message(e)})
        end
      %{role: "tool", tool_call_id: tc["id"], content: result}
    end)

    assistant_msg = %{
      "role" => "assistant",
      "content" => assistant["content"] || "",
      "tool_calls" => tool_calls
    }
    assistant_msg = case assistant["reasoning_content"] do
      rc when is_binary(rc) -> Map.put(assistant_msg, "reasoning_content", rc)
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

  defp execute_tool("get_task_result", args, agent_id) do
    case args["task_id"] do
      nil ->
        Jason.encode!(%{error: "missing task_id"})

      task_id ->
        # 优先检查强制中断标记
        if ResultCollector.check_and_clear_interrupt_flag(agent_id) do
          PTYPool.interrupt_task(agent_id)
          result = %{
            status: "complete",
            output: "Task forcefully interrupted by user. Please reply now."
          }
          result |> Utils.sanitize_value() |> Jason.encode!()
        else
          # 检查超时深度窗口
          case ResultCollector.check_timeout_window(agent_id) do
            msg when is_binary(msg) ->
              %{status: "complete", output: msg}
              |> Utils.sanitize_value()
              |> Jason.encode!()

            _ ->
              result = case ResultCollector.get(task_id) do
                %{status: "complete", output: output} -> %{status: "complete", output: output}
                %{status: status}                     -> %{status: status}
                nil                                   -> %{status: "not_found"}
              end
              result |> Utils.sanitize_value() |> Jason.encode!()
          end
        end
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

  defp execute_tool("force_complete_task", args, agent_id) do
    task_id = Map.get(args, "task_id", "")
    target  = Map.get(args, "agent_id", agent_id)

    case ResultCollector.force_complete(task_id) do
      {:ok, output} ->
        # session task_id 也要清掉，否则 PTYPool 以为还在跑
        PTYPool.clear_task(target, task_id)
        %{status: "complete", output: output}
        |> Utils.sanitize_value()
        |> Jason.encode!()
      _ ->
        Jason.encode!(%{error: "force_complete failed or task not found"})
    end
  end

  defp execute_tool("write_to_session", args, agent_id) do
    input    = Map.get(args, "input", "")
    target   = Map.get(args, "agent_id", agent_id)
    input    = String.replace(input, "\\n", "\n")
    PTYPool.write_raw(target, input)
    %{status: "ok", wrote: input}
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