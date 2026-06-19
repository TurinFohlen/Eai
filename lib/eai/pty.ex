defmodule Eai.PTY do
  @moduledoc """
  Public API for PTY session management.

  All calls route through `Eai.Hub.run/3` before reaching the underlying
  `PTY.Session` GenServer, enabling pre/post hooks on every PTY operation.

  Sessions are created lazily on first `exec_async/3` call.
  Use `Eai.PTY.Supervisor.stop_session/1` to explicitly terminate a session.

  ## Replaces

  `Eai.Sandbox.PTYPool` (deleted). Call sites update:

      PTYPool.exec_async(id, cmd)      →  Eai.PTY.exec_async(id, cmd)
      PTYPool.force_reset(id)          →  Eai.PTY.force_reset(id)
      PTYPool.write_raw(id, input)     →  Eai.PTY.write_raw(id, input)
      PTYPool.interrupt_task(id)       →  Eai.PTY.interrupt_task(id)
      PTYPool.clear_task(id, task_id)  →  Eai.PTY.clear_task(id, task_id)
      PTYPool.list_sessions()          →  Eai.PTY.list_sessions()
  """

  @doc """
  Execute a command asynchronously in a PTY session.

  Creates the session if it does not exist yet. Returns `{:ok, task_id}`
  immediately; poll results via `Eai.ResultCollector.get/1`.
  """
  @spec exec_async(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()} | {:block, String.t()}
  def exec_async(pty_session_id, cmd, task_id \\ nil) do
    task_id = task_id || "task_#{System.unique_integer([:positive, :monotonic])}"

    with {:ok, pid} <- get_or_create(pty_session_id) do
      Eai.Hub.run(Eai.PTY.Session, :exec, [pid, task_id, cmd])
    end
  end

  @doc "Send raw input (Ctrl+C, passwords, etc.) to a PTY session."
  @spec write_raw(String.t(), String.t()) :: :ok | {:error, term()} | {:block, String.t()}
  def write_raw(pty_session_id, input) do
    with {:ok, pid} <- require_session(pty_session_id) do
      Eai.Hub.run(Eai.PTY.Session, :write_raw, [pid, input])
    end
  end

  @doc "Force-reset a PTY session — kills the PTY and respawns it."
  @spec force_reset(String.t()) :: :ok | {:error, term()} | {:block, String.t()}
  def force_reset(pty_session_id) do
    with {:ok, pid} <- require_session(pty_session_id) do
      Eai.Hub.run(Eai.PTY.Session, :force_reset, [pid])
    end
  end

  @doc "Inject Ctrl+C + right sentinel into the active task."
  @spec interrupt_task(String.t()) :: :ok | {:error, term()} | {:block, String.t()}
  def interrupt_task(pty_session_id) do
    with {:ok, pid} <- require_session(pty_session_id) do
      Eai.Hub.run(Eai.PTY.Session, :interrupt_task, [pid])
    end
  end

  @doc "Clear completed task state from a session."
  @spec clear_task(String.t(), String.t()) :: :ok | {:error, term()} | {:block, String.t()}
  def clear_task(pty_session_id, task_id) do
    with {:ok, pid} <- require_session(pty_session_id) do
      Eai.Hub.run(Eai.PTY.Session, :clear_task, [pid, task_id])
    end
  end

  @doc "Return info map for all active PTY sessions."
  @spec list_sessions() :: %{String.t() => map()}
  def list_sessions do
    Eai.PTY.Registry.all()
    |> Map.new(fn {session_id, pid} ->
      info =
        try do
          GenServer.call(pid, :info, 5_000)
        catch
          :exit, _ -> %{pty: "dead", alive: false, current_task: nil, running_ms: nil}
        end

      {session_id, info}
    end)
  end

  # ── Internal ─────────────────────────────────────────────────────────

  # Get existing session PID or start a new one.
  defp get_or_create(pty_session_id) do
    case Eai.PTY.Registry.lookup(pty_session_id) do
      nil ->
        case Eai.PTY.Supervisor.start_session(pty_session_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  # Require an existing session (no auto-create).
  defp require_session(pty_session_id) do
    case Eai.PTY.Registry.lookup(pty_session_id) do
      nil -> {:error, :no_session}
      pid -> {:ok, pid}
    end
  end
end
