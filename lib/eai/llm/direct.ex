defmodule Eai.LLM.Direct do
  @moduledoc "直接调用 LLM API，支持 OpenAI 兼容和 Anthropic，含 telemetry 埋点"
  @right_sentinel Application.compile_env(:eai, [:sandbox, :sentinel_right])

  alias Eai.ResultCollector
  alias Eai.Utils

  # ── 配置读取（运行时，重启即生效，无需重新编译）────────────────────────────
  defp sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)
  defp system_prompt,    do: Eai.Prompts.default()[:content]
  defp poll_cooldown_ms do
  Application.get_env(:eai, :poll_cooldown_ms)
  end
  # ── 工具定义 ───────────────────────────────────────────────────────────────
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
            script:         %{type: "string", description: "Bash script content to execute."},
            pty_session_id: %{type: "string", description: "PTY session ID (default: 'default')."}
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
        Always call list_pty_sessions first to identify the correct pty_session_id.
        After reset, the next execute_script will automatically create a fresh session.
        """,
        parameters: %{type: "object",
          properties: %{pty_session_id: %{type: "string", description: "PTY session ID to reset."}},
          required: ["pty_session_id"]
        }
    }},
    %{type: "function", function: %{
        name: "list_pty_sessions",
        description: "List all active PTY sessions with their status and current task.",
        parameters: %{type: "object", properties: %{}, required: []}
    }},
    %{type: "function", function: %{
        name: "force_complete_task",
        description: """
        Force-collect the current output of a running task and mark it as complete.
        Use when a task appears stuck but has produced output you want to retrieve.
        Always call list_pty_sessions first to confirm the task_id.
        """,
        parameters: %{type: "object",
          properties: %{
            task_id:        %{type: "string", description: "The task_id to force-complete."},
            pty_session_id: %{type: "string", description: "PTY session ID (default: current session)."}
          },
          required: ["task_id"]
        }
    }},
    %{type: "function", function: %{
        name: "call_subagent",
        description: """
        Dispatch a sub-task to an independent AI agent. Returns a subagent_task_id immediately (async).
        Use get_subagent_result to poll for the answer. Do not use recursively.
        """,
        parameters: %{type: "object",
          properties: %{
            message:        %{type: "string", description: "The task or question for the sub-agent."},
            pty_session_id: %{type: "string", description: "Optional PTY session ID for the sub-agent. Defaults to a unique ID."}
          },
          required: ["message"]
        }
    }},
    %{type: "function", function: %{
        name: "get_subagent_result",
        description: """
        Retrieve the result of a previously dispatched sub-agent task by subagent_task_id.
        Poll until status == \"complete\". Wait at least 5 s after call_subagent before first poll.
        """,
        parameters: %{type: "object",
          properties: %{subagent_task_id: %{type: "string", description: "subagent_task_id returned by call_subagent."}},
          required: ["subagent_task_id"]
        }
    }},
    %{type: "function", function: %{
        name: "write_to_session",
        description: """
        Write raw bytes directly to a PTY session's stdin, bypassing the sentinel wrapper.
        Use for interactive input (e.g. answering [Y/n] prompts) or for sending control characters.
        Do NOT use for normal script execution — use execute_script for that.

        Supported escape sequences (write them literally in the input string):
          \\n   newline
          \\r   carriage return
          \\t   tab
          \\x03 Ctrl+C (interrupt running task)
          \\x04 Ctrl+D (EOF)
          \\x1a Ctrl+Z

        **Example:** to interrupt a running task, send Ctrl+C then echo the right sentinel:
          input: "\\x03\\necho #{@right_sentinel}\\n"
        """,
        parameters: %{type: "object",
          properties: %{
            input:          %{type: "string", description: "String to write, using escape sequences for control chars (e.g. \"y\\n\", \"\\x03\\n\")."},
            pty_session_id: %{type: "string", description: "PTY session ID (default: 'default')."}
          },
          required: ["input"]
        }
    }},
    %{type: "function", function: %{
        name: "read_media_file",
        description: """
        Read an image or video file and return its metadata plus a base64-encoded preview
        (image as-is, video as a frame). Optionally pass analyze_prompt to have a
        vision-capable model (GPT-4o, Claude, LLaVA, etc.) describe or analyse the visual
        content — the model is chosen independently of the current conversation model, so
        you can route vision tasks to the best available multimodal endpoint.

        Returns JSON with keys: ok, type, mime, file_size, metadata, base64, compression,
        and (if analyze_prompt was set) vision_analysis + vision_model.
        """,
        parameters: %{type: "object",
          properties: %{
            file_path:        %{type: "string",  description: "Absolute path to the media file (must be inside workspace)."},
            media_type:       %{type: "string",  enum: ["image", "video", "auto"], description: "Force type detection. Defaults to auto."},
            video_frame_time: %{type: "number",  description: "For video: extract frame at this second. Default 0."},
            max_dimension:    %{type: "integer", description: "Resize longest edge to this px before encoding. Default 1024. Set 0 for original."},
            analyze_prompt:   %{type: "string",  description: "If set, send the extracted image to a vision model with this prompt and return the analysis."},
            vision_model:     %{type: "string",  description: "Vision model to use when analyze_prompt is set. E.g. 'gpt-4o', 'claude-opus-4-6', 'llava'. Defaults to config :vision_model or 'gpt-4o'."},
            vision_api_key:   %{type: "string",  description: "Override API key for the vision model call."},
            vision_url:       %{type: "string",  description: "Override base API URL for the vision model (OpenAI-compatible or Anthropic)."}
          },
          required: ["file_path"]
        }
    }},
    # ── 上下文管理工具 ───────────────────────────────────────────────
    %{type: "function", function: %{
        name: "export_context",
        description: "Export the current conversation history to a gzip file (same format as Record). Returns the file path.",
        parameters: %{type: "object",
          properties: %{
            file_path: %{type: "string", description: "Absolute path for the .gz file to save to."}
          },
          required: ["file_path"]
        }
    }},
    %{type: "function", function: %{
        name: "replace_context",
        description: "Replace the current conversation history with the content of a previously exported .gz file.",
        parameters: %{type: "object",
          properties: %{
            file_path: %{type: "string", description: "Absolute path to the .gz file to load."}
          },
          required: ["file_path"]
        }
    }},
    %{type: "function", function: %{
        name: "list_chat_sessions",
        description: "List all active chat sessions with their message count and status (idle/busy).",
        parameters: %{type: "object", properties: %{}, required: []}
    }}
  ]

  # ── 转换 OpenAI tools 为 Anthropic tools 格式 ────────────────────────────
  defp to_anthropic_tools(tools) do
    Enum.map(tools, fn tool ->
      func = tool.function
      %{
        name: func.name,
        description: func.description,
        input_schema: func.parameters
      }
    end)
  end

  def run(messages, pty_session_id \\ "default", opts \\ %{}) do
    entry           = resolve_model_entry(opts)
    chat_session_id = Map.get(opts, :chat_session_id, "default") |> to_string()

    api_key  = Map.get(opts, :api_key,         Eai.Models.api_key(entry))
    model    = Map.get(opts, :model_str,        entry[:model])
    url      = Map.get(opts, :url,              entry[:url])
    timeout  = Map.get(opts, :receive_timeout,  entry[:receive_timeout]  || 120_000)
    effort   = Map.get(opts, :reasoning_effort, entry[:reasoning_effort])
    provider = Map.get(opts, :provider,         entry[:provider] || :openai_compat)
    prompt   = resolve_prompt(Map.get(opts, :system_prompt))

    formatted =
      messages
      |> Enum.map(&format_message/1)
      |> Utils.sanitize_messages()

    body = build_request_body(model, prompt, formatted, effort, provider)

    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:eai, :llm, :request, :start], %{system_time: System.system_time()}, %{pty_session_id: pty_session_id})

    result = Req.post(url,
      json: body,
      headers: build_headers(provider, api_key),
      receive_timeout: timeout
    )

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: 200, body: resp_body}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{pty_session_id: pty_session_id, status: :ok})
        msg = extract_message(resp_body, provider)
        handle_response(msg, messages, pty_session_id, chat_session_id, opts)

      {:ok, %{status: status, body: body}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{pty_session_id: pty_session_id, status: :error})
        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{pty_session_id: pty_session_id, reason: "HTTP #{status}", body: inspect(body)})
        {:error, "HTTP #{status}: #{inspect(body)}", messages}

      {:error, reason} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{pty_session_id: pty_session_id, status: :error})
        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{pty_session_id: pty_session_id, reason: inspect(reason)})
        {:error, reason, messages}
    end
  end

  defp resolve_model_entry(%{model: name}) when is_atom(name), do: Eai.Models.get!(name)
  defp resolve_model_entry(_opts),                             do: Eai.Models.default()

  defp resolve_prompt(nil),                    do: system_prompt()
  defp resolve_prompt(name) when is_atom(name), do: Eai.Prompts.get!(name)[:content]
  defp resolve_prompt(text) when is_binary(text), do: text

  # ── 根据 provider 构造请求体 ─────────────────────────────────────────────
  defp build_request_body(model, prompt, formatted, effort, :anthropic) do
    body = %{
      model:      model,
      max_tokens: 8192,
      system:     prompt,
      messages:   formatted,
      tools:      to_anthropic_tools(@tools)
    }
    if effort, do: Map.put(body, :thinking, %{type: "enabled", budget_tokens: 5000}), else: body
  end
  defp build_request_body(model, prompt, formatted, effort, _openai_compat) do
    body = %{
      model:       model,
      messages:    [%{role: "system", content: prompt} | formatted],
      tools:       @tools,
      tool_choice: "auto",
      stream:      false
    }
    body
    |> then(fn b -> if effort, do: Map.merge(b, %{thinking: %{type: "enabled"}, reasoning_effort: effort}), else: b end)
  end

  # ── 根据 provider 构造鉴权头 ─────────────────────────────────────────────
  defp build_headers(:anthropic, api_key) do
    [{"x-api-key", api_key || ""}, {"anthropic-version", "2023-06-01"}, {"content-type", "application/json"}]
  end
  defp build_headers(_openai_compat, api_key) do
    [authorization: "Bearer #{api_key || ""}"]
  end

  # ── 从不同 provider 的响应中提取 message map ────────────────────────────

  defp extract_message(%{"stop_reason" => "tool_use", "content" => blocks}, :anthropic) do
    tool_uses = Enum.filter(blocks, &(&1["type"] == "tool_use"))
    %{
      "content" => nil,
      "tool_calls" => Enum.map(tool_uses, fn tu ->
        %{
          "id" => tu["id"],
          "type" => "function",
          "function" => %{
            "name" => tu["name"],
            "arguments" => Jason.encode!(tu["input"])
          }
        }
      end)
    }
  end

  defp extract_message(%{"choices" => [%{"message" => msg} | _]}, _provider),     do: msg
  defp extract_message(%{"content" => [%{"type" => "text", "text" => t} | _]}, _), do: %{"content" => t}
  defp extract_message(%{"content" => content}, _) when is_binary(content),        do: %{"content" => content}
  defp extract_message(body, _), do: raise("unexpected response shape: #{inspect(body)}")

  # ── 消息格式化（全部使用 string keys，确保 DeepSeek 不报错） ────────────
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

  # ── 处理响应 ────────────────────────────────────────────────────────────

  defp handle_response(%{"tool_calls" => tool_calls} = assistant, history, pty_session_id, chat_session_id, opts) do
    results =
      Enum.map(tool_calls, fn tc ->
        name = tc["function"]["name"]
        args = tc["function"]["arguments"] |> decode_args() |> Utils.sanitize_value()

        :telemetry.execute([:eai, :tool, :execute], %{system_time: System.system_time()},
          %{tool: name, pty_session_id: pty_session_id})

        content =
          try do
            execute_tool(name, args, pty_session_id, chat_session_id)
          rescue
            e ->
              :telemetry.execute([:eai, :tool, :error], %{system_time: System.system_time()},
                %{tool: name, pty_session_id: pty_session_id, error: Exception.message(e)})
              Jason.encode!(%{error: Exception.message(e)})
          end

        %{role: "tool", tool_call_id: tc["id"], content: content}
      end)

    assistant_msg =
      %{"role" => "assistant", "content" => assistant["content"] || "",
        "tool_calls" => tool_calls}
      |> then(fn m ->
        case assistant["reasoning_content"] do
          rc when is_binary(rc) -> Map.put(m, "reasoning_content", rc)
          _                     -> m
        end
      end)

    run(history ++ [assistant_msg] ++ results, pty_session_id, opts)
  end

  defp handle_response(%{"content" => content}, history, _pty_session_id, _chat_session_id, _opts) do
    final_msg = %{"role" => "assistant", "content" => Utils.sanitize_value(content)}
    {:ok, Utils.sanitize_value(content), history ++ [final_msg]}
  end

  # ── 调试辅助 ──────────────────────────────────────────────────────────────
  defp maybe_debug_script(path, script) do
    if sandbox_cfg(:debug_pty_output) do
      IO.puts("\n=== SCRIPT [#{path}] ===\n#{script}\n=== END SCRIPT ===")
    end
    :ok
  end

  # ── 工具执行 ──────────────────────────────────────────────────────────────

  defp execute_tool("get_local_time", _args, _pty_session_id, _chat_session_id) do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp execute_tool("execute_script", args, pty_session_id, _chat_session_id) do
    sid     = Map.get(args, "pty_session_id", pty_session_id)
    script  = Map.get(args, "script", "")
    task_id = "task_#{System.unique_integer([:positive, :monotonic])}"
    prefix  = sandbox_cfg(:script_tmp_prefix)
    path    = "#{prefix}#{task_id}.sh"

    with :ok <- File.write(path, script),
         :ok <- maybe_debug_script(path, script),
         {:ok, ^task_id} <- Eai.Naming.pool().exec_async(sid, "bash #{path}; rm -f #{path}", task_id) do
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

  defp execute_tool("get_task_result", args, pty_session_id, _chat_session_id) do
    Process.sleep(poll_cooldown_ms())  
    case args["task_id"] do
      nil ->
        Jason.encode!(%{error: "missing task_id"})

      task_id ->
        if ResultCollector.check_and_clear_interrupt_flag(pty_session_id) do
          Eai.Naming.pool().interrupt_task(pty_session_id)
          result = %{
            status: "complete",
            output: "Task forcefully interrupted by user. Please reply now."
          }
          result |> Utils.sanitize_value() |> Jason.encode!()
        else
          case ResultCollector.check_timeout_window(pty_session_id) do
            msg when is_binary(msg) ->
              %{status: "complete", output: msg}
              |> Utils.sanitize_value()
              |> Jason.encode!()

            _ ->
              result = case ResultCollector.get(task_id) do
                %{status: "complete", output: output} ->
                  %{status: "complete", output: output}
                %{started_at: started_at} when not is_nil(started_at) ->
                  elapsed = System.monotonic_time(:millisecond) - started_at
                  %{status: "running", time: elapsed}
                %{} ->
                  %{status: "running", time: 0}
                nil ->
                  %{status: "not_found"}
              end
              result |> Utils.sanitize_value() |> Jason.encode!()
          end
        end
    end
  end

  defp execute_tool("reset_session", args, pty_session_id, _chat_session_id) do
    target = Map.get(args, "pty_session_id", pty_session_id)
    Eai.Naming.pool().force_reset(target)
    %{status: "ok", message: "Session #{target} killed. Next execute_script creates fresh session."}
    |> Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp execute_tool("list_pty_sessions", _args, _pty_session_id, _chat_session_id) do
    Eai.Naming.pool().list_sessions()
    |> Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp execute_tool("force_complete_task", args, pty_session_id, _chat_session_id) do
    task_id = Map.get(args, "task_id", "")
    target  = Map.get(args, "pty_session_id", pty_session_id)

    case ResultCollector.force_complete(task_id) do
      {:ok, output} ->
        Eai.Naming.pool().clear_task(target, task_id)
        %{status: "complete", output: output}
        |> Utils.sanitize_value()
        |> Jason.encode!()
      _ ->
        Jason.encode!(%{error: "force_complete failed or task not found"})
    end
  end

  defp execute_tool("call_subagent", args, _pty_session_id, _chat_session_id) do
    message          = Map.get(args, "message", "")
    pty_session_id   = Map.get(args, "pty_session_id", "subagent_#{System.unique_integer([:positive])}")
    subagent_task_id = "satask_#{System.unique_integer([:positive, :monotonic])}"

    Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", %{
      status: "running",
      started_at: System.monotonic_time(:millisecond)
    })

    Task.start(fn ->
      result_entry =
        try do
          case Eai.Naming.chat().send(message, pty_session_id: pty_session_id, chat_session_id: "default") do
            {:ok, response}  -> %{status: "complete", answer: response, pty_session_id: pty_session_id}
            {:error, reason} -> %{status: "error", reason: inspect(reason), pty_session_id: pty_session_id}
          end
        rescue
          e -> %{status: "error", reason: Exception.message(e), pty_session_id: pty_session_id}
        end

      Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", result_entry)
    end)

    %{subagent_task_id: subagent_task_id, status: "queued", pty_session_id: pty_session_id}
    |> Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp execute_tool("get_subagent_result", args, _pty_session_id, _chat_session_id) do
    Process.sleep(poll_cooldown_ms())
    case args["subagent_task_id"] do
      nil ->
        Jason.encode!(%{error: "missing subagent_task_id"})

      subagent_task_id ->
        case Eai.Naming.cache().get("subagent_result:#{subagent_task_id}") do
          nil ->
            Jason.encode!(%{error: "task_not_found"})

          %{status: status, started_at: started_at}
              when status not in ["complete", "error"] ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Jason.encode!(%{status: "running", time: elapsed})

          result ->
            result |> Utils.sanitize_value() |> Jason.encode!()
        end
    end
  end

  defp execute_tool("write_to_session", args, pty_session_id, _chat_session_id) do
    input  = Map.get(args, "input", "")
    target = Map.get(args, "pty_session_id", pty_session_id)
    raw    = unescape(input)
    if sandbox_cfg(:debug_pty_output) do
      IO.puts("\n=== WRITE_TO_SESSION [#{target}] ===\ninput: #{inspect(input)}\nraw:   #{inspect(raw)}\n=== END WRITE ===")
    end
    Eai.Naming.pool().write_raw(target, raw)
    %{status: "ok", wrote: inspect(raw)}
    |> Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp execute_tool("read_media_file", args, _pty_session_id, _chat_session_id) do
    file_path  = args["file_path"]
    work_root  = sandbox_cfg(:work_dir_root)

    if not String.starts_with?(Path.expand(file_path), Path.expand(work_root)) do
      Jason.encode!(%{ok: false, reason: "file path outside workspace"})
    else
      max_dim    = to_string(args["max_dimension"] || 1024)
      frame_time = to_string(args["video_frame_time"] || 0)
      media_type = args["media_type"] || "auto"
      script     = Path.join(:code.priv_dir(:eai), "scripts/media_reader.py")

      case System.cmd("python3", [script, file_path,
             "--max-dim",    max_dim,
             "--frame-time", frame_time,
             "--type",       media_type],
             stderr_to_stdout: false, timeout: 30_000) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"ok" => true} = media} ->
              case args["analyze_prompt"] do
                nil ->
                  Jason.encode!(media)

                prompt ->
                  vision_result = call_vision_model(
                    media["base64"], media["mime"], prompt,
                    vision_model:   args["vision_model"],
                    vision_api_key: args["vision_api_key"],
                    vision_url:     args["vision_url"]
                  )
                  case vision_result do
                    {:ok, analysis, model_used} ->
                      media
                      |> Map.put("vision_analysis", analysis)
                      |> Map.put("vision_model", model_used)
                      |> Jason.encode!()
                    {:error, reason} ->
                      media
                      |> Map.put("vision_analysis", nil)
                      |> Map.put("vision_error", reason)
                      |> Jason.encode!()
                  end
              end

            {:ok, err_map} ->
              Jason.encode!(err_map)

            {:error, _} ->
              Jason.encode!(%{ok: false, reason: "invalid output from media_reader", raw: output})
          end

        {error, code} ->
          Jason.encode!(%{ok: false, reason: "media_reader exited #{code}: #{String.trim(error)}"})
      end
    end
  end

  # ── 上下文管理工具实现 ──────────────────────────────────────────────────
  defp execute_tool("export_context", args, _pty_session_id, chat_session_id) do
    file_path = args["file_path"]
    case Eai.Naming.chat().export_history(file_path, chat_session_id) do
      {:ok, path} -> Jason.encode!(%{ok: true, file: path})
      {:error, reason} -> Jason.encode!(%{ok: false, error: reason})
    end
  end

  defp execute_tool("replace_context", args, _pty_session_id, chat_session_id) do
    file_path = args["file_path"]
    case Eai.Naming.chat().replace_history(file_path, chat_session_id) do
      {:ok, count} -> Jason.encode!(%{ok: true, messages_loaded: count})
      {:error, reason} -> Jason.encode!(%{ok: false, error: reason})
    end
  end

  defp execute_tool("list_chat_sessions", _args, _pty_session_id, _chat_session_id) do
    Eai.Naming.chat().list_chat_sessions()
    |> Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp execute_tool(name, _args, _pty_session_id, _chat_session_id) do
    Jason.encode!(%{error: "unknown tool: #{name}"})
  end

  # ── Vision 模型路由 ───────────────────────────────────────────────────────
  defp call_vision_model(base64_data, mime, prompt, opts) do
    entry =
      cond do
        is_atom(opts[:vision_model]) and not is_nil(opts[:vision_model]) ->
          Eai.Models.get!(opts[:vision_model])

        is_binary(opts[:vision_model]) ->
          base = Eai.Models.default_vision() || raise "no vision model configured in models.exs"
          Keyword.put(base, :model, opts[:vision_model])

        true ->
          Eai.Models.default_vision() || raise "no vision model configured in models.exs; add vision: true to a model entry"
      end

    model    = entry[:model]
    api_key  = opts[:vision_api_key] || Eai.Models.api_key(entry)
    url      = opts[:vision_url]     || entry[:url]
    provider = entry[:provider]      || :openai_compat

    result = case provider do
      :anthropic     -> vision_call_anthropic(url, api_key, model, base64_data, mime, prompt)
      :openai_compat -> vision_call_openai(url, api_key, model, base64_data, mime, prompt)
    end

    case result do
      {:ok, text} -> {:ok, text, model}
      err         -> err
    end
  end

  defp vision_call_openai(url, api_key, model, base64_data, mime, prompt) do
    body = %{
      model: model,
      max_tokens: 1024,
      messages: [%{
        role: "user",
        content: [
          %{type: "image_url",
            image_url: %{url: "data:#{mime};base64,#{base64_data}"}},
          %{type: "text", text: prompt}
        ]
      }]
    }
    case Req.post(url,
           json: body,
           headers: [authorization: "Bearer #{api_key}", content_type: "application/json"],
           receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => c}} | _]}}} ->
        {:ok, c}
      {:ok, %{status: s, body: b}} ->
        {:error, "vision HTTP #{s}: #{inspect(b)}"}
      {:error, r} ->
        {:error, inspect(r)}
    end
  end

  defp vision_call_anthropic(url, api_key, model, base64_data, mime, prompt) do
    body = %{
      model: model,
      max_tokens: 1024,
      messages: [%{
        role: "user",
        content: [
          %{type: "image",
            source: %{type: "base64", media_type: mime, data: base64_data}},
          %{type: "text", text: prompt}
        ]
      }]
    }
    case Req.post(url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => t} | _]}}} ->
        {:ok, t}
      {:ok, %{status: s, body: b}} ->
        {:error, "vision HTTP #{s}: #{inspect(b)}"}
      {:error, r} ->
        {:error, inspect(r)}
    end
  end

  defp decode_args(nil), do: %{}
  defp decode_args(""),  do: %{}
  defp decode_args(s),   do: Jason.decode!(s)

  # 将模型输出的转义序列字面量还原为实际字节
  defp unescape(input) do
    input
    |> String.replace("\\n",   "\n")
    |> String.replace("\\r",   "\r")
    |> String.replace("\\t",   "\t")
    |> String.replace("\\x03", <<3>>)   # Ctrl+C
    |> String.replace("\\x04", <<4>>)   # Ctrl+D (EOF)
    |> String.replace("\\x1a", <<26>>)  # Ctrl+Z
  end
end