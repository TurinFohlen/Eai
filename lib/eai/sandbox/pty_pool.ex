defmodule Eai.Sandbox.PTYPool do
  @behaviour Eai.Sandbox

  use GenServer
  require Logger
  alias Eai.ResultCollector

  # ── 公开 API ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def exec_async(agent_id, cmd, task_id \\ nil) do
    task_id = task_id || "task_#{System.unique_integer([:positive, :monotonic])}"
    GenServer.call(__MODULE__, {:exec, agent_id, task_id, cmd})
  end

  def exec_sync(agent_id, cmd, timeout_ms \\ 30_000) do
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
      # 【核心改动】：卸下 stty 结界，任由 PTY 产生双倍镜像
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
      {:error, :timeout}
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
        pool_pid = self()
        work_dir = "/home/eai_agents/#{agent_id}"
        File.mkdir_p!(work_dir)
        shell = System.find_executable("bash") || "/bin/sh"

        {:ok, pty} = ExPTY.spawn(shell, [],
          name: "xterm-256color",
          cols: 200, rows: 50,
          cwd: work_dir,
          on_data: fn _pty, _pid, data ->
            send(pool_pid, {:pty_data, agent_id, data})
          end,
          on_exit: fn _pty, _pid, _code, _sig ->
            GenServer.cast(pool_pid, {:remove, agent_id})
          end
        )
	# 💡 [开光修补]：给新生的 Bash 会话一点呼吸和安顿的时间
	  Process.sleep(200)
	  
	  # 💡 冲洗邮箱，把 Bash 刚启动时吐出的 "root@localhost..." 提示符和 \e[?2004h 噪声吃掉
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

        Process.sleep(300)
        session = %{pty: pty, task_id: nil, task_started_at: nil}
        {pty, Map.put(sessions, agent_id, session)}

      %{pty: pty} ->
        {pty, sessions}
    end
  end
end
