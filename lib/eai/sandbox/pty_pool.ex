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

  def exec_sync(agent_id, cmd, timeout_ms \\ nil) do
    timeout_ms = timeout_ms || sandbox_cfg(:exec_sync_timeout)
    task_id = "task_#{System.unique_integer([:positive, :monotonic])}"
    case exec_async(agent_id, cmd, task_id) do
      {:ok, ^task_id} -> wait_for_result(task_id, timeout_ms, agent_id)
      error -> error
    end
  end

  def force_reset(agent_id) do
    GenServer.call(__MODULE__, {:force_reset, agent_id})
  end

  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  def kill(agent_id) do
    GenServer.cast(__MODULE__, {:kill, agent_id})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  def init(_), do: {:ok, %{}}

  def handle_call({:exec, agent_id, task_id, cmd}, _from, sessions) do
    session = Map.get(sessions, agent_id, %{pty: nil, task_id: nil, task_started_at: nil})

    if session.task_id != nil do
      Logger.warning("PTYPool busy: agent=#{agent_id} current=#{session.task_id}")
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

      Logger.debug("PTYPool exec: agent=#{agent_id} task=#{task_id}")
      ExPTY.write(pty, line)

      {:reply, {:ok, task_id}, sessions}
    end
  end

  def handle_call({:force_reset, agent_id}, _from, sessions) do
    sessions = case Map.get(sessions, agent_id) do
      nil ->
        Logger.info("PTYPool.force_reset: #{agent_id} not in pool")
        sessions
      %{pty: pty} ->
        Logger.warning("PTYPool.force_reset: killing #{agent_id} pty=#{inspect(pty)}")
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

  def handle_cast({:kill, agent_id}, sessions) do
    case Map.get(sessions, agent_id) do
      %{pty: pty} when is_pid(pty) -> ExPTY.write(pty, "exit\n")
      _ -> :ok
    end
    {:noreply, sessions}
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
            Logger.info("PTYPool task complete: agent=#{agent_id} task=#{task_id} #{duration}ms output=#{byte_size(output)}b")
            :telemetry.execute(
              [:eai, :task, :complete],
              %{duration_ms: duration, output_size: byte_size(output)},
              %{agent_id: agent_id, task_id: task_id}
            )
            sessions
            |> put_in([agent_id, :task_id], nil)
            |> put_in([agent_id, :task_started_at], nil)

          other ->
            Logger.debug("PTYPool collect: agent=#{agent_id} task=#{task_id} state=#{inspect(other)}")
            sessions
        end

        {:noreply, sessions}

      _ ->
        {:noreply, sessions}
    end
  end

  def handle_info(msg, sessions) do
    Logger.debug("PTYPool unhandled msg: #{inspect(msg)}")
    {:noreply, sessions}
  end

  # ── 内部流转控制 ──────────────────────────────────────────────────────────

  defp wait_for_result(task_id, timeout_ms, agent_id) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(task_id, deadline, agent_id)
  end

  defp do_wait(task_id, deadline, agent_id) do
    if System.monotonic_time(:millisecond) >= deadline do
      :telemetry.execute(
        [:eai, :task, :timeout],
        %{system_time: System.system_time()},
        %{agent_id: agent_id, task_id: task_id}
      )
      Logger.warning("PTYPool timeout: agent=#{agent_id} task=#{task_id}, force-completing")
      case ResultCollector.force_complete(task_id) do
        {:ok, output} -> {:ok, output}
        _ -> {:error, :timeout}
      end
    else
      case ResultCollector.get(task_id) do
        %{status: "complete", output: output} -> {:ok, output}
        _ ->
          Process.sleep(50)
          do_wait(task_id, deadline, agent_id)
      end
    end
  end

  defp get_or_create(agent_id, sessions) do
    case Map.get(sessions, agent_id) do
      nil ->
        pool_pid  = self()
        work_root = sandbox_cfg(:work_dir_root)
        work_dir  = "#{work_root}/#{agent_id}"
        File.mkdir_p!(work_dir)

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

        # 冲洗 Bash 启动时的初始化噪声（提示符、转义序列等）
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
        Logger.info("PTYPool: spawned #{agent_id} pid=#{inspect(pty)}")

        Process.sleep(sandbox_cfg(:pty_ready_sleep_ms))
        session = %{pty: pty, task_id: nil, task_started_at: nil}
        {pty, Map.put(sessions, agent_id, session)}

      %{pty: pty} ->
        {pty, sessions}
    end
  end
end
