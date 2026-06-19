defmodule Eai.Naming do
  @moduledoc """
  Maps logical names to registered process names, supporting multi-instance deployments.

  ## Graph
  <<{Eai.Naming, required_by, Eai.PTY.Registry}.
  <<{Eai.Naming, required_by, Eai.PTY.Supervisor}.
  <<{Eai.Naming, required_by, Eai.PTY.Session}.
  <<{Eai.Naming, required_by, Eai.PTY}.
  <<{Eai.Naming, required_by, Eai.Chat}.
  <<{Eai.Naming, required_by, Eai.Application}.
  """

  @doc "读取当前实例 ID，默认 \"default\"。"
  def instance_id do
    Application.get_env(:eai, :instance_id, "default")
  end

  @doc "Chat GenServer 的注册名。"
  def chat, do: via(Eai.Chat)

  @doc "PubSub 的注册名。"
  def pubsub, do: via(Eai.PubSub)

  @doc "Cache 的模块/注册名。"
  def cache, do: via(Eai.Cache.Cache)

  @doc "Task.Supervisor 的注册名，通用异步任务池。"
  def task_supervisor, do: via(Eai.TaskSupervisor)

  @doc "PTY OTP Registry 的注册名。"
  def pty_registry, do: via(Eai.PTY.Registry)

  @doc "PTY DynamicSupervisor 的注册名。"
  def pty_supervisor, do: via(Eai.PTY.Supervisor)

  @doc "通过 Registry 寻址单个 PTY.Session 的 via tuple。"
  def pty_session(pty_session_id) do
    {:via, Registry, {pty_registry(), pty_session_id}}
  end

  # 默认实例直接返回原始名，其余拼接 CamelCase 后缀——
  # 这样 instance_id == "default" 时行为与硬编码时完全一致，零破坏。
  defp via(base) do
    case instance_id() do
      "default" -> base
      id -> Module.concat(base, String.to_atom(Macro.camelize(id)))
    end
  end
end
