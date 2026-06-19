defmodule Eai.PTY.Registry do
  @moduledoc """
  OTP Registry for PTY sessions.

  Maps `pty_session_id` (string) → `PTY.Session` PID via
  `{:via, Registry, {Eai.Naming.pty_registry(), pty_session_id}}`.

  Started as a child of `Eai.Supervisor`. All Registry lookups go through
  `Eai.Naming.pty_session/1` — do not call Registry directly from outside
  the PTY subsystem.
  """

  @doc "Child spec for `Eai.Supervisor`."
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: Eai.Naming.pty_registry()
    )
  end

  @doc "Return the PID of the session, or `nil` if not registered."
  @spec lookup(String.t()) :: pid() | nil
  def lookup(pty_session_id) do
    case Registry.lookup(Eai.Naming.pty_registry(), pty_session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Return all currently registered `{pty_session_id, pid}` pairs."
  @spec all() :: [{String.t(), pid()}]
  def all do
    Registry.select(Eai.Naming.pty_registry(), [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
