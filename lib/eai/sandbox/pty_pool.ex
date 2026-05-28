defmodule Eai.Sandbox.PTYPool do
  @behaviour Eai.Sandbox

  use GenServer
  require Logger
  alias Eai.ResultCollector

  # ── 配置读取 ───────────────────────────────────────────────────────────────
  defp sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)

  # ── 公开 API ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def exec_async(agent_id, cmd, task_id \\ nil) do
    task_id = task_id || "task_#{System.unique_integer([:positive, :monotonic])}"
    GenServer.call(__MODULE__, {:exec, agent_id, task_id, cmd})
  end

  def force_reset(agent_id) do
    GenServer.call(__MODULE__, {:force_reset, agent_id})
  end

  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  def write_raw(agent_id, input) do
    GenServer.call(__MODULE__, {:write_raw, agent_id, input})
  end

  def interrupt_task(agent_id) do
    GenServer.call(__MODULE__, {:interrupt_task, agent_id})
  end

  def clear_task(agent_id, task_id) do
    GenServer.call(__MODULE__, {:clear_task, agent_id, task_id})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  def init(_), do: {:ok, %{}}

  def handle_call({:exec, agent_id, task_id, cmd}, _from, sessions) do
    session = Map.get(sessions, agent_id, %{pty: nil, task_id: nil, task_started_at: nil})

    if session.task_id != nil do
      Logger.warning("PTYPool busy", agent_id: agent_id, current_task: session.task_id)
      {:reply, {:error, :busy}, sessions}
    else
      {pty, sessions} = get_or_create(agent_id, sessions)
      ResultCollector.init_task(task_id)

      now = System.monotonic_time(:millisecond)
      sessions = sessions
        |> put_in([agent_id, :task_id], task_id)
        |> put_in([agent_id, :task_started_at], now)

      :telemetry.execute(
        [:eai, :task, :start],
        %{system_time: System.system_time()},
        %{agent_id: agent_id, task_id: task_id}
      )

      line = "echo #{ResultCollector.sentinel_left()}; #{cmd}; echo #{ResultCollector.sentinel_right()}\n"

      Logger.debug("PTYPool exec", agent_id: agent_id, task_id: task_id)
      ExPTY.write(pty, line)


      {:reply, {:ok, task_id}, sessions}
    end
  end

  def handle_call({:force_reset, agent_id}, _from, sessions) do
    sessions = case Map.get(sessions, agent_id) do
      nil ->
        Logger.info("PTYPool.force_reset: not in pool", agent_id: agent_id)
        sessions
      %{pty: pty} ->
        Logger.warning("PTYPool.force_reset: killing", agent_id: agent_id, pty: inspect(pty))
        :telemetry.execute(
          [:eai, :session, :reset],
          %{system_time: System.system_time()},
          %{agent_id: agent_id}
        )
        if is_pid(pty) and Process.alive?(pty), do: Process.exit(pty, :kill)
        Map.delete(sessions, agent_id)
    end
    {:reply, :ok, sessions}
  end

  def handle_call(:list_sessions, _from, sessions) do
    info = Map.new(sessions, fn {agent_id, s} ->
      {agent_id, %{
        pty:          inspect(s.pty),
        alive:        is_pid(s.pty) and Process.alive?(s.pty),
        current_task: s.task_id,
        running_ms:   if(s.task_started_at, do: System.monotonic_time(:millisecond) - s.task_started_at)
      }}
    end)
    {:reply, info, sessions}
  end

  def handle_call({:clear_task, agent_id, task_id}, _from, sessions) do
    # 仅当 session 当前 task 确实是 task_id 时才清空，避免误清后来的任务
    sessions = case Map.get(sessions, agent_id) do
      %{task_id: ^task_id} ->
        sessions
        |> put_in([agent_id, :task_id], nil)
        |> put_in([agent_id, :task_started_at], nil)
      _ ->
        sessions
    end
    {:reply, :ok, sessions}
  end

  def handle_call({:write_raw, agent_id, input}, _from, sessions) do
    case Map.get(sessions, agent_id) do
      %{pty: pty} when is_pid(pty) ->
        ExPTY.write(pty, input)
        {:reply, :ok, sessions}
      nil ->
        {:reply, {:error, :no_session}, sessions}
    end
  end

  def handle_call({:interrupt_task, agent_id}, _from, sessions) do
    case Map.get(sessions, agent_id) do
      %{task_id: task_id, pty: pty} when is_binary(task_id) ->
        if is_pid(pty) and Process.alive?(pty) do
          # 1. 发送 Ctrl+C
          ExPTY.write(pty, <<3>>)
  
          # 2. 只 echo 消息 + 右哨兵（左哨兵已经在 PTY 流中）
          right = ResultCollector.sentinel_right()
          msg   = "Task forcefully interrupted by user. Please reply now."
          b64   = Base.encode64(msg <> right)
          cmd   = "echo #{b64} | base64 -d\n"
  
          ExPTY.write(pty, cmd)
  
          Logger.info("PTYPool interrupt_task: Ctrl+C + right sentinel echo sent",
            agent_id: agent_id, task_id: task_id)
        end
  
        {:reply, :ok, sessions}
  
      _ ->
        {:reply, {:error, :no_active_task}, sessions}
    end
  end

  def handle_cast({:remove, agent_id}, sessions) do
    {:noreply, Map.delete(sessions, agent_id)}
  end

  def handle_info({:pty_data, agent_id, data}, sessions) do
    case Map.get(sessions, agent_id) do
      %{task_id: task_id, task_started_at: started_at} when is_binary(task_id) ->
        :telemetry.execute(
          [:eai, :task, :chunk],
          %{bytes: byte_size(data)},
          %{agent_id: agent_id, task_id: task_id}
        )

        sessions = case ResultCollector.collect(task_id, data) do
          {:complete, output} ->
            duration = System.monotonic_time(:millisecond) - (started_at || 0)
            Logger.info("PTYPool task complete", agent_id: agent_id, task_id: task_id, duration_ms: duration, output_bytes: byte_size(output))
            :telemetry.execute(
              [:eai, :task, :complete],
              %{duration_ms: duration, output_size: byte_size(output)},
              %{agent_id: agent_id, task_id: task_id}
            )
            sessions
            |> put_in([agent_id, :task_id], nil)
            |> put_in([agent_id, :task_started_at], nil)

          other ->
            Logger.debug("PTYPool collect", agent_id: agent_id, task_id: task_id, state: inspect(other))
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

  defp get_or_create(agent_id, sessions) do
    case Map.get(sessions, agent_id) do
      nil ->
        pool_pid  = self()
        work_root = sandbox_cfg(:work_dir_root)
        work_dir  = "#{work_root}/#{agent_id}"
        File.mkdir_p!(work_dir)

        priv_src = sandbox_cfg(:priv_src)
        priv_link = Path.join(work_dir, "priv")
        cond do
          priv_src && File.exists?(priv_src) && !File.exists?(priv_link) ->
            case File.ln_s(priv_src, priv_link) do
              :ok ->
                Logger.info("PTYPool priv symlink created", agent_id: agent_id, src: priv_src, link: priv_link)
              {:error, reason} ->
                Logger.warning("PTYPool priv symlink failed", agent_id: agent_id, reason: reason)
            end
          File.exists?(priv_link) ->
            :ok
          true ->
            Logger.warning("PTYPool priv src not found, skip symlink", agent_id: agent_id, priv_src: priv_src)
        end

        shell = System.find_executable("bash") || "/bin/sh"
        cols  = sandbox_cfg(:pty_cols)
        rows  = sandbox_cfg(:pty_rows)

        {:ok, pty} = ExPTY.spawn(shell, [],
          name: "xterm-256color",
          cols: cols, rows: rows,
          cwd: work_dir,
          on_data: fn _pty, _pid, data ->
            send(pool_pid, {:pty_data, agent_id, data})
          end,
          on_exit: fn _pty, _pid, _code, _sig ->
            GenServer.cast(pool_pid, {:remove, agent_id})
          end
        )

        Process.sleep(sandbox_cfg(:pty_init_sleep_ms))

        flush_init_noise = fn fun ->
          receive do
            {:pty_data, ^agent_id, _data} -> fun.(fun)
          after 50 -> :ok
          end
        end
        flush_init_noise.(flush_init_noise)

        :telemetry.execute(
          [:eai, :session, :spawn],
          %{system_time: System.system_time()},
          %{agent_id: agent_id, pty: inspect(pty)}
        )
        Logger.info("PTYPool spawned", agent_id: agent_id, pty: inspect(pty))

        Process.sleep(sandbox_cfg(:pty_ready_sleep_ms))
        session = %{pty: pty, task_id: nil, task_started_at: nil}
        {pty, Map.put(sessions, agent_id, session)}

      %{pty: pty} ->
        {pty, sessions}
    end
  end
end