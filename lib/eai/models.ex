defmodule Eai.Models do
  @moduledoc """
  模型注册表查询接口。

  模型定义拆分至 `config/models/*.exs`，每个文件以 `:model_<name>` 为 key 注册一项。
  新增本地/自托管模型只需新建一个 `.exs` 文件，无需修改任何中心文件。

  默认模型通过 `config :eai, :default_model, :atom` 指定（见 config/config.exs）。

  ## 快速查表

      iex> Eai.Models.all()           # 全部模型条目
      iex> Eai.Models.default()       # 默认模型（:default_model 配置项）
      iex> Eai.Models.get(:gpt4o)     # 按 :name atom 查找
      iex> Eai.Models.names()         # 所有 name atom 列表
      iex> Eai.Models.vision_models() # 标注了 vision: true 的条目
      iex> Eai.Models.reload()        # 重新扫描 config/models/ 目录

  ## 本地模型示例

      # config/models/my_qwen.exs
      import Config
      config :eai, :model_qwen,
        name: :qwen,
        model: "qwen2.5:14b",
        url: "http://localhost:11434/v1/chat/completions",
        provider: :openai_compat,
        api_key_env: nil,
        receive_timeout: 180_000
  """

  @models_dir Path.expand("config/models", File.cwd!())

  @type model_entry :: keyword()

  # ── 基础查询 ────────────────────────────────────────────────────────────────

  @doc "返回注册表中所有模型条目（按文件名字母序）。"
  @spec all() :: [model_entry()]
  def all do
    case :persistent_term.get(:eai_models, :not_found) do
      :not_found -> load_models()
      entries -> entries
    end
  end

  @doc "强制重新扫描 config/models/ 目录。"
  @spec reload() :: [model_entry()]
  def reload, do: load_models()

  @doc "返回默认模型（由 config :eai, :default_model 指定）。"
  @spec default() :: model_entry()
  def default do
    name = Application.get_env(:eai, :default_model)
    get!(name)
  end

  @doc "按 :name atom 查找模型，找不到返回 nil。"
  @spec get(atom() | nil) :: model_entry() | nil
  def get(nil), do: default()

  def get(name) when is_atom(name) do
    Enum.find(all(), fn entry -> entry[:name] == name end)
  end

  @doc "按 :name atom 查找模型，找不到抛出 ArgumentError。"
  @spec get!(atom()) :: model_entry()
  def get!(name) do
    case get(name) do
      nil -> raise ArgumentError, "unknown model #{inspect(name)}; available: #{inspect(names())}"
      entry -> entry
    end
  end

  @doc "返回所有 :name atom 列表。"
  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1[:name])

  @doc "返回所有标注了 vision: true 的模型条目。"
  @spec vision_models() :: [model_entry()]
  def vision_models, do: Enum.filter(all(), &(&1[:vision] == true))

  @doc "返回第一个支持视觉的模型，找不到返回 nil。"
  @spec default_vision() :: model_entry() | nil
  def default_vision, do: hd(vision_models() ++ [nil])

  # ── 字段便捷访问 ─────────────────────────────────────────────────────────────

  @doc "从条目中提取 API Key（读对应环境变量；nil 表示无需 key）。"
  @spec api_key(model_entry()) :: String.t() | nil
  def api_key(entry) do
    case entry[:api_key_env] do
      nil ->
        nil

      env ->
        System.get_env(env) ||
          raise "environment variable #{env} is not set (required by model #{entry[:name]})"
    end
  end

  @doc "从条目中提取字段，组装成 Direct.run/3 的 opts map。"
  @spec to_run_opts(model_entry()) :: map()
  def to_run_opts(entry) do
    base = %{
      model: entry[:model],
      url: entry[:url],
      provider: entry[:provider]
    }

    base
    |> maybe_put(:api_key, api_key(entry))
    |> maybe_put(:receive_timeout, entry[:receive_timeout])
    |> maybe_put(:reasoning_effort, entry[:reasoning_effort])
  end

  # ── 内部加载 ─────────────────────────────────────────────────────────────────

  defp load_models do
    with {:ok, files} <- File.ls(@models_dir) do
      files
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.each(fn file ->
        path = Path.join(@models_dir, file)

        path
        |> Config.Reader.read!()
        |> Enum.each(fn {app, kvs} ->
          Enum.each(kvs, fn {key, val} -> Application.put_env(app, key, val) end)
        end)
      end)
    end

    entries =
      Application.get_all_env(:eai)
      |> Enum.filter(fn
        {key, _} -> is_atom(key) and String.starts_with?(Atom.to_string(key), "model_")
        _ -> false
      end)
      |> Enum.map(fn {_, entry} -> entry end)
      |> Enum.sort_by(& &1[:name])

    :persistent_term.put(:eai_models, entries)
    entries
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
