defmodule Eai.Sandbox.PTYPool do
  @moduledoc "GenServer pool managing per-session PTY processes and task dispatching."

  @behaviour Eai.Sandbox

  use GenServer
  require Logger
  alias Eai.Task

  # ── 配置读取 ───────────────────────────────────────────────────────────────
  defp sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)

  # ── 公开 API ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Eai.Naming.pool())

  @doc """
  Execute command asynchronously in a PTY session.

  Submits command to PTY, returns task_id immediately. Results collected via `Task.get/1`.

  ## Options
    * `pty_session_id` (string) — PTY session for isolation. Default: `"default"`
    * `cmd` (string) — Shell command or script (may contain sentinels).
    * `task_id` (string, optional) — Custom task ID. Auto-generated if omitted.

  ## Returns
      `{:ok, task_id}` or `{:error, reason}`

  ## Example
      iex> Eai.Sandbox.PTYPool.exec_async("default", "ls -la")
      {:ok, "task_1234567890"}
  """
  def exec_async(pty_session_id, cmd, task_id \\ nil) do
    task_id = task_id || "task_#{System.unique_integer([:positive, :monotonic])}"
    GenServer.call(Eai.Naming.pool(), {:exec, pty_session_id, task_id, cmd}, 15_000)
  end

  @doc """
  Force reset a PTY session (kill processes, clear state).

  Use after hang or corruption. PTY recreated on next command.

  ## Options
    * `pty_session_id` (string) — Session to reset.

  ## Returns
      `:ok` or `{:error, reason}`
  """
  def force_reset(pty_session_id) do
    GenServer.call(Eai.Naming.pool(), {:force_reset, pty_session_id})
  end

  @doc """
  List all active PTY sessions.

  ## Returns
      List of session IDs: `["default", "task_1", ...]`
  """
  def list_sessions do
    GenServer.call(Eai.Naming.pool(), :list_sessions)
  end

  @doc """
  Send raw input to PTY (for interactive prompts, Ctrl+C, etc.).

  ## Options
    * `pty_session_id` (string) — Target session.
    * `input` (string) — Raw input to send. Supports escape sequences:
      - `\\n` = newline, `\\r` = carriage return, `\\t` = tab
      - `\\x03` = Ctrl+C, `\\x04` = Ctrl+D, `\\x1a` = Ctrl+Z

  ## Example
      iex> Eai.Sandbox.PTYPool.write_raw("default", "\\x03")  # Send Ctrl+C
      :ok
  """
  def write_raw(pty_session_id, input) do
    GenServer.call(Eai.Naming.pool(), {:write_raw, pty_session_id, input})
  end

  @doc """
  Set interrupt flag for a PTY session (injects Ctrl+C on next poll).

  Internal use (called by `Chat.interrupt!`).

  ## Options
    * `pty_session_id` (string) — Session to interrupt.

  ## Returns
      `:ok` or `{:error, reason}`
  """
  def interrupt_task(pty_session_id) do
    GenServer.call(Eai.Naming.pool(), {:interrupt_task, pty_session_id})
  end

  @doc """
  Clear a completed task from PTY session state.

  Internal use (cache cleanup).

  ## Options
    * `pty_session_id` (string) — Session.
    * `task_id` (string) — Task to clear.

  ## Returns
      `:ok` or `{:error, reason}`
  """
  def clear_task(pty_session_id, task_id) do
    GenServer.call(Eai.Naming.pool(), {:clear_task, pty_session_id, task_id})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  def init(_), do: {:ok, %{}}

  def handle_call({:exec, pty_session_id, task_id, cmd}, _from, sessions) do
    session = Map.get(sessions, pty_session_id, %{pty: nil, task_id: nil, task_started_at: nil})

    if session.task_id != nil do
      Logger.warning("PTYPool busy",
        pty_session_id: pty_session_id,
        current_task: session.task_id
      )

      {:reply, {:error, :busy}, sessions}
    else
      {pty, sessions} = get_or_create(pty_session_id, sessions)
      Task.init_task(task_id)

      now = System.monotonic_time(:millisecond)

      sessions =
        sessions
        |> put_in([pty_session_id, :task_id], task_id)
        |> put_in([pty_session_id, :task_started_at], now)

      :telemetry.execute(
        [:eai, :task, :start],
        %{system_time: System.system_time()},
        %{pty_session_id: pty_session_id, task_id: task_id}
      )

      left = Task.sentinel_left()
      right = Task.sentinel_right()

      b64_left = Base.encode64(left <> "\n")
      b64_right = Base.encode64("\n" <> right)

      line =
        "{ echo #{b64_left}|base64 -d; #{cmd}; echo #{b64_right}|base64 -d; }\n"

      Logger.debug("PTYPool exec", pty_session_id: pty_session_id, task_id: task_id)
      ExPTY.write(pty, line)

      {:reply, {:ok, task_id}, sessions}
    end
  end

  def handle_call({:force_reset, pty_session_id}, _from, sessions) do
    # 1. 强制完成该 agent 当前正在进行的任务（如果有），避免缓存泄漏
    old_task_id = get_in(sessions, [pty_session_id, :task_id])

    if is_binary(old_task_id) do
      Task.force_complete(old_task_id)
    end

    # 2. 杀死 PTY 进程并从池中彻底移除 session
    sessions =
      case Map.get(sessions, pty_session_id) do
        nil ->
          Logger.info("PTYPool.force_reset: not in pool", pty_session_id: pty_session_id)
          sessions

        %{pty: pty} ->
          Logger.warning("PTYPool.force_reset: killing",
            pty_session_id: pty_session_id,
            pty: inspect(pty)
          )

          :telemetry.execute(
            [:eai, :session, :reset],
            %{system_time: System.system_time()},
            %{pty_session_id: pty_session_id}
          )

          if is_pid(pty) and Process.alive?(pty), do: Process.exit(pty, :kill)
          Map.delete(sessions, pty_session_id)
      end

    {:reply, :ok, sessions}
  end

  def handle_call(:list_sessions, _from, sessions) do
    info =
      Map.new(sessions, fn {pty_session_id, s} ->
        {pty_session_id,
         %{
           pty: inspect(s.pty),
           alive: is_pid(s.pty) and Process.alive?(s.pty),
           current_task: s.task_id,
           running_ms:
             if(s.task_started_at, do: System.monotonic_time(:millisecond) - s.task_started_at)
         }}
      end)

    {:reply, info, sessions}
  end

  def handle_call({:clear_task, pty_session_id, _task_id}, _from, sessions) do
    # 无条件清理指定 agent 的 task 状态，不再匹配具体的 task_id
    sessions =
      case Map.get(sessions, pty_session_id) do
        nil ->
          sessions

        _ ->
          sessions
          |> put_in([pty_session_id, :task_id], nil)
          |> put_in([pty_session_id, :task_started_at], nil)
      end

    {:reply, :ok, sessions}
  end

  def handle_call({:write_raw, pty_session_id, input}, _from, sessions) do
    case Map.get(sessions, pty_session_id) do
      %{pty: pty} when is_pid(pty) ->
        ExPTY.write(pty, input)
        {:reply, :ok, sessions}

      nil ->
        {:reply, {:error, :no_session}, sessions}
    end
  end

  def handle_call({:interrupt_task, pty_session_id}, _from, sessions) do
    case Map.get(sessions, pty_session_id) do
      %{task_id: task_id, pty: pty} when is_binary(task_id) ->
        if is_pid(pty) and Process.alive?(pty) do
          # 1. 发送 Ctrl+C
          ExPTY.write(pty, <<3>>)

          # 2. 只 echo 消息 + 右哨兵（左哨兵已经在 PTY 流中）
          right = Task.sentinel_right()
          msg = "Task forcefully interrupted by user. Please reply now."
          b64 = Base.encode64(msg <> right)
          cmd = "echo #{b64} | base64 -d\n"

          ExPTY.write(pty, cmd)

          Logger.info("PTYPool interrupt_task: Ctrl+C + right sentinel echo sent",
            pty_session_id: pty_session_id,
            task_id: task_id
          )
        end

        {:reply, :ok, sessions}

      _ ->
        {:reply, {:error, :no_active_task}, sessions}
    end
  end

  def handle_cast({:remove, pty_session_id}, sessions) do
    {:noreply, Map.delete(sessions, pty_session_id)}
  end

  def handle_info({:pty_data, pty_session_id, data}, sessions) do
    case Map.get(sessions, pty_session_id) do
      %{task_id: task_id, task_started_at: started_at} when is_binary(task_id) ->
        :telemetry.execute(
          [:eai, :task, :chunk],
          %{bytes: byte_size(data)},
          %{pty_session_id: pty_session_id, task_id: task_id}
        )

        sessions =
          case Task.collect(task_id, data) do
            {:complete, output} ->
              duration = System.monotonic_time(:millisecond) - (started_at || 0)

              Logger.info("PTYPool task complete",
                pty_session_id: pty_session_id,
                task_id: task_id,
                duration_ms: duration,
                output_bytes: byte_size(output)
              )

              :telemetry.execute(
                [:eai, :task, :complete],
                %{duration_ms: duration, output_size: byte_size(output)},
                %{pty_session_id: pty_session_id, task_id: task_id}
              )

              sessions
              |> put_in([pty_session_id, :task_id], nil)
              |> put_in([pty_session_id, :task_started_at], nil)

            other ->
              Logger.debug("PTYPool collect",
                pty_session_id: pty_session_id,
                task_id: task_id,
                state: inspect(other)
              )

              sessions
          end

        {:noreply, sessions}

      _ ->
        {:noreply, sessions}
    end
  end

  def handle_info(msg, sessions) do
    Logger.debug("PTYPool unhandled msg", msg: inspect(msg))
    {:noreply, sessions}
  end

  # ── 内部函数 ──────────────────────────────────────────────────────────────

  defp get_or_create(pty_session_id, sessions) do
    case Map.get(sessions, pty_session_id) do
      nil ->
        pool_pid = self()
        work_root = sandbox_cfg(:work_dir_root)
        work_dir = "#{work_root}/#{pty_session_id}"
        File.mkdir_p!(work_dir)

        priv_src = sandbox_cfg(:priv_src)
        priv_link = Path.join(work_dir, "priv")
        maybe_link_priv(pty_session_id, priv_src, priv_link)

        shell = System.find_executable("bash") || "/bin/sh"
        cols = sandbox_cfg(:pty_cols)
        rows = sandbox_cfg(:pty_rows)

        {:ok, pty} =
          ExPTY.spawn(shell, [],
            name: "xterm-256color",
            cols: cols,
            rows: rows,
            cwd: work_dir,
            on_data: fn _pty, _pid, data ->
              send(pool_pid, {:pty_data, pty_session_id, data})
            end,
            on_exit: fn _pty, _pid, _code, _sig ->
              GenServer.cast(pool_pid, {:remove, pty_session_id})
            end
          )

        Process.sleep(sandbox_cfg(:pty_init_sleep_ms))

        flush_init_noise = fn fun ->
          receive do
            {:pty_data, ^pty_session_id, _data} -> fun.(fun)
          after
            50 -> :ok
          end
        end

        flush_init_noise.(flush_init_noise)

        :telemetry.execute(
          [:eai, :session, :spawn],
          %{system_time: System.system_time()},
          %{pty_session_id: pty_session_id, pty: inspect(pty)}
        )

        Logger.info("PTYPool spawned", pty_session_id: pty_session_id, pty: inspect(pty))

        Process.sleep(sandbox_cfg(:pty_ready_sleep_ms))
        session = %{pty: pty, task_id: nil, task_started_at: nil}
        {pty, Map.put(sessions, pty_session_id, session)}

      %{pty: pty} ->
        {pty, sessions}
    end
  end

  defp maybe_link_priv(_id, priv_src, _priv_link) when is_nil(priv_src) do
    Logger.warning("PTYPool priv src not found, skip symlink")
  end

  defp maybe_link_priv(_id, _priv_src, priv_link) when not is_nil(priv_link) do
    if File.exists?(priv_link), do: :ok
  end

  defp maybe_link_priv(pty_session_id, priv_src, priv_link) do
    cond do
      File.exists?(priv_link) ->
        :ok

      File.exists?(priv_src) ->
        case File.ln_s(priv_src, priv_link) do
          :ok ->
            Logger.info("PTYPool priv symlink created",
              pty_session_id: pty_session_id,
              src: priv_src,
              link: priv_link
            )

          {:error, reason} ->
            Logger.warning("PTYPool priv symlink failed",
              pty_session_id: pty_session_id,
              reason: reason
            )
        end

      true ->
        Logger.warning("PTYPool priv src not found, skip symlink",
          pty_session_id: pty_session_id,
          priv_src: priv_src
        )
    end
  end
end
