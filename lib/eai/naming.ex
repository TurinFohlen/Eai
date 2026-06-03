defmodule Eai.Naming do
  @moduledoc false

  @doc "读取当前实例 ID，默认 \"default\"。"
  def instance_id do
    Application.get_env(:eai, :instance_id, "default")
  end

  @doc "Chat GenServer 的注册名。"
  def chat, do: via(Eai.Chat)

  @doc "PTYPool GenServer 的注册名。"
  def pool, do: via(Eai.Sandbox.PTYPool)

  @doc "PubSub 的注册名。"
  def pubsub, do: via(Eai.PubSub)

  @doc "Cache 的模块/注册名。"
  def cache, do: via(Eai.Cache.Cache)

  # 默认实例直接返回原始名，其余拼接 CamelCase 后缀——
  # 这样 instance_id == "default" 时行为与硬编码时完全一致，零破坏。
  defp via(base) do
    case instance_id() do
      "default" -> base
      id -> Module.concat(base, String.to_atom(Macro.camelize(id)))
    end
  end
end
