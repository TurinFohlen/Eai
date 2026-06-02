defmodule Eai.Models do
  @moduledoc """
  模型注册表查询接口。

  所有模型定义集中在 `config/models.exs`，运行时通过本模块访问，
  代码中不再出现任何硬编码的模型字符串。

  ## 快速查表

      iex> Eai.Models.all()           # 全部模型条目
      iex> Eai.Models.default()       # 列表第一个（系统默认）
      iex> Eai.Models.get(:gpt4o)     # 按 :name atom 查找
      iex> Eai.Models.names()         # 所有 name atom 列表
      iex> Eai.Models.vision_models() # 标注了 vision: true 的条目
  """

  @type model_entry :: keyword()

  # ── 基础查询 ────────────────────────────────────────────────────────────────

  @doc "返回注册表中所有模型条目（顺序与 models.exs 定义一致）。"
  @spec all() :: [model_entry()]
  def all, do: Application.fetch_env!(:eai, :models)

  @doc "返回默认模型（注册表第一个条目）。"
  @spec default() :: model_entry()
  def default, do: hd(all())

  @doc "按 :name atom 查找模型，找不到返回 nil。"
  @spec get(atom() | nil) :: model_entry() | nil
  def get(nil),  do: default()
  def get(name) when is_atom(name) do
    Enum.find(all(), fn entry -> entry[:name] == name end)
  end

  @doc "按 :name atom 查找模型，找不到抛出 ArgumentError。"
  @spec get!(atom()) :: model_entry()
  def get!(name) do
    case get(name) do
      nil   -> raise ArgumentError, "unknown model #{inspect(name)}; available: #{inspect(names())}"
      entry -> entry
    end
  end

  @doc "返回所有 :name atom 列表。"
  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1[:name])

  @doc "返回所有标注了 vision: true 的模型条目。"
  @spec vision_models() :: [model_entry()]
  def vision_models, do: Enum.filter(all(), & &1[:vision] == true)

  @doc "返回第一个支持视觉的模型，找不到返回 nil。"
  @spec default_vision() :: model_entry() | nil
  def default_vision, do: hd(vision_models() ++ [nil])

  # ── 字段便捷访问 ─────────────────────────────────────────────────────────────

  @doc "从条目中提取 API Key（读对应环境变量；nil 表示无需 key）。"
  @spec api_key(model_entry()) :: String.t() | nil
  def api_key(entry) do
    case entry[:api_key_env] do
      nil -> nil
      env -> System.get_env(env) || raise "environment variable #{env} is not set (required by model #{entry[:name]})"
    end
  end

  @doc "从条目中提取模型字符串、URL、provider 等字段，组装成 Direct.run/3 的 opts map。"
  @spec to_run_opts(model_entry()) :: map()
  def to_run_opts(entry) do
    base = %{
      model:    entry[:model],
      url:      entry[:url],
      provider: entry[:provider]
    }

    base
    |> maybe_put(:api_key,          api_key(entry))
    |> maybe_put(:receive_timeout,  entry[:receive_timeout])
    |> maybe_put(:reasoning_effort, entry[:reasoning_effort])
  end

  defp maybe_put(map, _key, nil),   do: map
  defp maybe_put(map, key, value),  do: Map.put(map, key, value)
end
