defmodule Eai.PTY.Session do
  @moduledoc """
  Per-session GenServer owning a single PTY process.

  Each `PTY.Session` holds the state previously scattered as one map entry
  inside `Eai.Sandbox.PTYPool`. Moving to a dedicated process means:

  - Slow PTY init (`pty_init_sleep_ms`, `pty_ready_sleep_ms`) runs inside
    this process and no longer blocks other sessions.
  - PTY crash → `:pty_exited` arrives in this process only; orphaned tasks
    are cleaned up immediately via `ResultCollector.force_complete/1`.
  - `:transient` restart: on abnormal exit, the supervisor restarts the
    session with a fresh PTY. `init/1` force-completes any in-flight task
    left over from the previous incarnation.

  ## Lifecycle

      start_link(pty_session_id)
        └─ init/1
             ├─ mkdir work_dir, setup symlinks
             ├─ ExPTY.spawn (shell, on_data → self, on_exit → self)
             └─ flush init noise

      handle_call :exec / :force_reset / :write_raw / :interrupt_task / :clear_task / :info
      handle_info {:pty_data, data} / :pty_exited

      terminate/2  →  Hub.run_post_only(__MODULE__, :terminate, [reason, state])

  ## Naming / addressing

  Registered via `Eai.Naming.pty_session(pty_session_id)` on start.
  Look up by `Eai.PTY.Registry.lookup(pty_session_id)`.
  """

  use GenServer, restart: :transient
  require Logger
  alias Eai.ResultCollector

  defp sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)

  # ── Public API ────────────────────────────────────────────────────────

  @doc "Start a PTY.Session for `pty_session_id`."
  def start_link(pty_session_id) do
    GenServer.start_link(__MODULE__, pty_session_id,
      name: Eai.Naming.pty_session(pty_session_id)
    )
  end

  # ── Public dispatch (called via Hub.run → apply) ──────────────────────

  @doc "Execute command async. Called by `Eai.PTY` via `Hub.run`."
  def exec(pid, task_id, cmd), do: GenServer.call(pid, {:exec, task_id, cmd}, 15_000)

  @doc "Send raw input. Called by `Eai.PTY` via `Hub.run`."
  def write_raw(pid, input), do: GenServer.call(pid, {:write_raw, input})

  @doc "Force-reset session PTY. Called by `Eai.PTY` via `Hub.run`."
  def force_reset(pid), do: GenServer.call(pid, :force_reset, 30_000)

  @doc "Inject Ctrl+C interrupt. Called by `Eai.PTY` via `Hub.run`."
  def interrupt_task(pid), do: GenServer.call(pid, :interrupt_task)

  @doc "Clear completed task state. Called by `Eai.PTY` via `Hub.run`."
  def clear_task(pid, task_id), do: GenServer.call(pid, {:clear_task, task_id})

  # ── init ─────────────────────────────────────────────────────────────

  @impl true
  def init(pty_session_id) do
    Process.flag(:trap_exit, true)

    state = %{
      pty_session_id: pty_session_id,
      pty: nil,
      task_id: nil,
      task_started_at: nil
    }

    case spawn_pty(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  # ── Calls ────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:exec, task_id, cmd}, _from, %{task_id: current} = state)
      when is_binary(current) do
    Logger.warning("PTY.Session busy",
      pty_session_id: state.pty_session_id,
      current_task: current
    )

    {:reply, {:error, :busy}, state}
  end

  def handle_call({:exec, task_id, cmd}, _from, state) do
    ResultCollector.init_task(task_id)
    now = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:eai, :task, :start],
      %{system_time: System.system_time()},
      %{pty_session_id: state.pty_session_id, task_id: task_id}
    )

    left = ResultCollector.sentinel_left()
    right = ResultCollector.sentinel_right()
    b64_left = Base.encode64(left <> "\n")
    b64_right = Base.encode64("\n" <> right)
    line = "{ echo #{b64_left}|base64 -d; #{cmd}; echo #{b64_right}|base64 -d; }\n"

    Logger.debug("PTY.Session exec",
      pty_session_id: state.pty_session_id,
      task_id: task_id
    )

    ExPTY.write(state.pty, line)

    {:reply, {:ok, task_id},
     %{state | task_id: task_id, task_started_at: now}}
  end

  def handle_call(:force_reset, _from, state) do
    if is_binary(state.task_id) do
      ResultCollector.force_complete(state.task_id)
    end

    Logger.warning("PTY.Session force_reset",
      pty_session_id: state.pty_session_id,
      pty: inspect(state.pty)
    )

    :telemetry.execute(
      [:eai, :session, :reset],
      %{system_time: System.system_time()},
      %{pty_session_id: state.pty_session_id}
    )

    if is_pid(state.pty) and Process.alive?(state.pty) do
      Process.exit(state.pty, :kill)
    end

    # PTY is dead; respawn immediately so the session stays available.
    case spawn_pty(%{state | pty: nil, task_id: nil, task_started_at: nil}) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:write_raw, input}, _from, state) do
    ExPTY.write(state.pty, input)
    {:reply, :ok, state}
  end

  def handle_call(:interrupt_task, _from, %{task_id: task_id, pty: pty} = state)
      when is_binary(task_id) do
    if is_pid(pty) and Process.alive?(pty) do
      ExPTY.write(pty, <<3>>)

      right = ResultCollector.sentinel_right()
      msg = "Task forcefully interrupted by user. Please reply now."
      b64 = Base.encode64(msg <> right)
      ExPTY.write(pty, "echo #{b64} | base64 -d\n")

      Logger.info("PTY.Session interrupt_task: Ctrl+C + right sentinel",
        pty_session_id: state.pty_session_id,
        task_id: task_id
      )
    end

    {:reply, :ok, state}
  end

  def handle_call(:interrupt_task, _from, state) do
    {:reply, {:error, :no_active_task}, state}
  end

  def handle_call({:clear_task, _task_id}, _from, state) do
    {:reply, :ok, %{state | task_id: nil, task_started_at: nil}}
  end

  def handle_call(:info, _from, state) do
    info = %{
      pty: inspect(state.pty),
      alive: is_pid(state.pty) and Process.alive?(state.pty),
      current_task: state.task_id,
      running_ms:
        if(state.task_started_at,
          do: System.monotonic_time(:millisecond) - state.task_started_at
        )
    }

    {:reply, info, state}
  end

  # ── PTY data & exit ───────────────────────────────────────────────────

  @impl true
  def handle_info({:pty_data, data}, %{task_id: task_id} = state) when is_binary(task_id) do
    :telemetry.execute(
      [:eai, :task, :chunk],
      %{bytes: byte_size(data)},
      %{pty_session_id: state.pty_session_id, task_id: task_id}
    )

    state =
      case ResultCollector.collect(task_id, data) do
        {:complete, output} ->
          duration = System.monotonic_time(:millisecond) - (state.task_started_at || 0)

          Logger.info("PTY.Session task complete",
            pty_session_id: state.pty_session_id,
            task_id: task_id,
            duration_ms: duration,
            output_bytes: byte_size(output)
          )

          :telemetry.execute(
            [:eai, :task, :complete],
            %{duration_ms: duration, output_size: byte_size(output)},
            %{pty_session_id: state.pty_session_id, task_id: task_id}
          )

          %{state | task_id: nil, task_started_at: nil}

        other ->
          Logger.debug("PTY.Session collect",
            pty_session_id: state.pty_session_id,
            task_id: task_id,
            state: inspect(other)
          )

          state
      end

    {:noreply, state}
  end

  def handle_info({:pty_data, _data}, state), do: {:noreply, state}

  def handle_info(:pty_exited, state) do
    Logger.warning("PTY.Session: underlying PTY exited",
      pty_session_id: state.pty_session_id,
      task_id: state.task_id
    )

    # Clean up any in-flight task so result_collector doesn't hang collecting.
    if is_binary(state.task_id) do
      ResultCollector.force_complete(state.task_id)
    end

    # Exit abnormally so :transient supervisor restarts the session.
    {:stop, :pty_exited, %{state | pty: nil, task_id: nil, task_started_at: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("PTY.Session unhandled msg",
      pty_session_id: state.pty_session_id,
      msg: inspect(msg)
    )

    {:noreply, state}
  end

  # ── Terminate ─────────────────────────────────────────────────────────

  @impl true
  def terminate(reason, state) do
    Eai.Hub.run_post_only(__MODULE__, :terminate, [reason, state])
  end

  # ── Internal ─────────────────────────────────────────────────────────

  defp spawn_pty(state) do
    pty_session_id = state.pty_session_id
    self_pid = self()

    work_root = sandbox_cfg(:work_dir_root)
    work_dir = "#{work_root}/#{pty_session_id}"
    File.mkdir_p!(work_dir)

    priv_src = sandbox_cfg(:priv_src)
    priv_link = Path.join(work_dir, "priv")
    maybe_link_priv(pty_session_id, priv_src, priv_link)

    sandbox = Application.fetch_env!(:eai, :sandbox)

    Enum.each(Keyword.get(sandbox, :mounts, []), fn mount_src ->
      expanded = Path.expand(mount_src)
      mount_link = Path.join(work_dir, Path.basename(expanded))
      maybe_link_mount(pty_session_id, expanded, mount_link)
    end)

    shell = System.find_executable("bash") || "/bin/sh"
    cols = sandbox_cfg(:pty_cols)
    rows = sandbox_cfg(:pty_rows)

    case ExPTY.spawn(shell, [],
           name: "xterm-256color",
           cols: cols,
           rows: rows,
           cwd: work_dir,
           on_data: fn _pty, _pid, data ->
             send(self_pid, {:pty_data, data})
           end,
           on_exit: fn _pty, _pid, _code, _sig ->
             send(self_pid, :pty_exited)
           end
         ) do
      {:ok, pty} ->
        Process.sleep(sandbox_cfg(:pty_init_sleep_ms))
        flush_init_noise(pty_session_id)

        :telemetry.execute(
          [:eai, :session, :spawn],
          %{system_time: System.system_time()},
          %{pty_session_id: pty_session_id, pty: inspect(pty)}
        )

        Logger.info("PTY.Session spawned", pty_session_id: pty_session_id, pty: inspect(pty))
        Process.sleep(sandbox_cfg(:pty_ready_sleep_ms))

        {:ok, %{state | pty: pty}}

      {:error, reason} ->
        Logger.error("PTY.Session spawn failed",
          pty_session_id: pty_session_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp flush_init_noise(pty_session_id) do
    receive do
      {:pty_data, _data} -> flush_init_noise(pty_session_id)
    after
      50 -> :ok
    end
  end

  defp maybe_link_priv(pty_session_id, nil, _priv_link) do
    Logger.warning("PTY.Session priv src nil, skip symlink", pty_session_id: pty_session_id)
  end

  defp maybe_link_priv(pty_session_id, priv_src, priv_link) do
    cond do
      File.exists?(priv_link) ->
        :ok

      File.exists?(priv_src) ->
        case File.ln_s(priv_src, priv_link) do
          :ok ->
            Logger.info("PTY.Session priv symlink created",
              pty_session_id: pty_session_id,
              src: priv_src,
              link: priv_link
            )

          {:error, reason} ->
            Logger.warning("PTY.Session priv symlink failed",
              pty_session_id: pty_session_id,
              reason: reason
            )
        end

      true ->
        Logger.warning("PTY.Session priv src not found, skip",
          pty_session_id: pty_session_id,
          priv_src: priv_src
        )
    end
  end

  defp maybe_link_mount(pty_session_id, mount_src, mount_link) do
    cond do
      File.exists?(mount_link) ->
        :ok

      File.exists?(mount_src) ->
        case File.ln_s(mount_src, mount_link) do
          :ok ->
            Logger.info("PTY.Session mount symlink created",
              pty_session_id: pty_session_id,
              src: mount_src,
              link: mount_link
            )

          {:error, reason} ->
            Logger.warning("PTY.Session mount symlink failed",
              pty_session_id: pty_session_id,
              reason: reason
            )
        end

      true ->
        Logger.info("PTY.Session mount src not found, skip",
          pty_session_id: pty_session_id,
          src: mount_src
        )
    end
  end
end
