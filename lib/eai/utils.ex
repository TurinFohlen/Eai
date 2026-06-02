# lib/eai/utils.ex
defmodule Eai.Utils do
  @moduledoc """
  通用清洗、转换等无业务耦合的工具函数。

  在任何需要序列化数据的出口（JSON 导出、日志记录、网络请求）之前，
  均可 `alias Eai.Utils` 后调用 `sanitize_value/1` 进行防御性清洗，
  确保所有嵌套结构中的二进制字段都是合法 UTF-8。
  """

  @doc """
  递归清洗任意嵌套结构，保证所有二进制字段都是合法 UTF-8 字符串。
  无效字节会被替换为 \"BASE64_DATA:\" <> base64 编码。

  支持的类型：
  - `binary`  — 检查 UTF-8 合法性，非法则 base64 编码
  - `list`    — 递归处理每个元素
  - `map`     — 递归处理键和值（含 struct 的 __struct__ 键会被保留）
  - `tuple`   — 递归处理每个元素，返回同阶 tuple
  - 其他       — 原样返回（integer / float / atom / boolean / nil）

  ## 示例

      iex> Eai.Utils.sanitize_value("hello")
      \"hello\"

      iex> Eai.Utils.sanitize_value(<<0xFF, 0xFE>>)
      \"BASE64_DATA://w==\"

      iex> Eai.Utils.sanitize_value(%{\"key\" => <<0xFF>>})
      %{\"key\" => \"BASE64_DATA:/w==\"}

      iex> Eai.Utils.sanitize_value([1, \"ok\", <<0xFE>>])
      [1, \"ok\", \"BASE64_DATA:/g==\"]

  """
  @spec sanitize_value(term()) :: term()
  def sanitize_value(v) when is_binary(v) do
    if String.valid?(v) do
      v
    else
      "BASE64_DATA:" <> Base.encode64(v)
    end
  end

  def sanitize_value(list) when is_list(list) do
    Enum.map(list, &sanitize_value/1)
  end

  def sanitize_value(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_value(k), sanitize_value(v)} end)
  end

  # Handle content block tuples from Eai.Message IR:
  # {:text, string}
  # {:image, [format: fmt, source: {:bytes, data}]}
  # {:tool_use, [tool_use_id: id, name: name, input: map]}
  # {:tool_result, [tool_use_id: id, content: [blocks]]}
  def sanitize_value({tag, payload}) when is_atom(tag) and tag in [:text, :image, :tool_use, :tool_result] do
    {tag, sanitize_value(payload)}
  end

  def sanitize_value({tag, a, b}) when is_atom(tag) do
    {tag, sanitize_value(a), sanitize_value(b)}
  end

  def sanitize_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&sanitize_value/1)
    |> List.to_tuple()
  end

  def sanitize_value(v), do: v

  @doc """
  对整个消息列表（LLM history）做批量清洗，适合在入口/出口统一调用。

  支持 Eai.Message IR 格式（%{role: atom, content: [tuples]}）和旧版 map 格式。

  ## 示例

      messages
      |> Eai.Utils.sanitize_messages()
      |> Jason.encode!()

  """
  @spec sanitize_messages([map()]) :: [map()]
  def sanitize_messages(messages) when is_list(messages) do
    Enum.map(messages, &sanitize_value/1)
  end
end
