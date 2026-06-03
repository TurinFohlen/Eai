defmodule Eai.Prompts do
  @moduledoc """
  Prompt 注册表查询接口。

  所有 prompt 定义集中在 `config/prompts.exs`，运行时通过本模块访问。

  ## 快速查表

      iex> Eai.Prompts.all()          # 全部条目
      iex> Eai.Prompts.default()      # 列表第一个（系统默认）
      iex> Eai.Prompts.get(:coder)    # 按 :name atom 查找
      iex> Eai.Prompts.names()        # 所有 name atom 列表
      iex> Eai.Prompts.list()         # 打印 name + description 对照表

  ## 在 iex 中使用

      iex> Eai.Chat.talk(prompt: :coder)
      iex> Eai.Chat.talk(prompt: :analyst, content: "分析这段代码")
      iex> Eai.Chat.talk(model: :gpt4o, prompt: :coder)
  """

  @type prompt_entry :: keyword()

  # ── 基础查询 ────────────────────────────────────────────────────────────────

  @doc "返回注册表中所有 prompt 条目（顺序与 prompts.exs 定义一致）。"
  @spec all() :: [prompt_entry()]
  def all, do: Application.fetch_env!(:eai, :prompts)

  @doc "返回默认 prompt（注册表第一个条目）。"
  @spec default() :: prompt_entry()
  def default, do: hd(all())

  @doc "按 :name atom 查找 prompt，nil 返回默认，找不到返回 nil。"
  @spec get(atom() | nil) :: prompt_entry() | nil
  def get(nil), do: default()

  def get(name) when is_atom(name) do
    Enum.find(all(), fn entry -> entry[:name] == name end)
  end

  @doc "按 :name atom 查找 prompt，找不到抛出 ArgumentError。"
  @spec get!(atom()) :: prompt_entry()
  def get!(name) do
    case get(name) do
      nil ->
        raise ArgumentError, "unknown prompt #{inspect(name)}; available: #{inspect(names())}"

      entry ->
        entry
    end
  end

  @doc "返回所有 :name atom 列表。"
  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1[:name])

  @doc "提取 prompt 文本内容（content 字段）。"
  @spec content(atom() | nil) :: String.t()
  def content(name), do: get(name)[:content]

  @doc "打印 name → description 对照表，方便在 iex 中查看可用 prompts。"
  @spec list() :: :ok
  def list do
    IO.puts("\nAvailable prompts:\n")

    Enum.each(all(), fn entry ->
      name = entry[:name] |> inspect() |> String.pad_trailing(16)
      desc = entry[:description] || "(no description)"
      IO.puts("  #{name}  #{desc}")
    end)

    IO.puts("")
  end
end
