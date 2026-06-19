defmodule Eai.PTY.Supervisor do
  @moduledoc """
  DynamicSupervisor that owns all `Eai.PTY.Session` processes.

  Each PTY session is a `:transient` child — restarted on abnormal exit,
  not on `:normal` / `:shutdown`. Session creation is driven by
  `Eai.PTY.get_or_create/1`; sessions never start themselves.

  ## Graph
  <<{Eai.Naming, required_by, Eai.PTY.Supervisor}.
  <<{Eai.PTY.Registry, required_by, Eai.PTY.Supervisor}.
  <<{Eai.PTY.Supervisor, required_by, Eai.PTY}.
  <<{Eai.PTY.Supervisor, required_by, Eai.Application}.
  <<{Eai.PTY.Session, spawned_by, Eai.PTY.Supervisor}.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Eai.Naming.pty_supervisor())
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a new `PTY.Session` for `pty_session_id` under this supervisor."
  @spec start_session(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_session(pty_session_id) do
    child_spec = %{
      id: {Eai.PTY.Session, pty_session_id},
      start: {Eai.PTY.Session, :start_link, [pty_session_id]},
      restart: :transient
    }

    DynamicSupervisor.start_child(Eai.Naming.pty_supervisor(), child_spec)
  end

  @doc "Terminate the session for `pty_session_id`, if running."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(pty_session_id) do
    case Eai.PTY.Registry.lookup(pty_session_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(Eai.Naming.pty_supervisor(), pid)
    end
  end
end
