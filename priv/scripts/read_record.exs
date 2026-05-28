#!/usr/bin/env elixir

# read_record.exs — 读取 Eai.Record 写入的 gzip 压缩日志文件
#
# 用法:
#   elixir priv/scripts/read_record.exs <record_file> [--limit N] [--json]
#
#   不指定 --limit 则返回所有记录
#   --json 输出 JSON 格式（供 Python / jq 等工具消费）

defmodule ReadRecord do
  @moduledoc """
  读取 Eai.Record 写入的 gzip 压缩日志。

  ## 示例

      # 读取所有记录（可读格式）
      elixir priv/scripts/read_record.exs chat_records/session_001.log.gz

      # 读取最近 10 条（JSON 格式）
      elixir priv/scripts/read_record.exs chat_records/session_001.log.gz --limit 10 --json

      # 读取最近 5 条（可读格式）
      elixir priv/scripts/read_record.exs chat_records/session_001.log.gz --limit 5
  """

  def main(args) do
    {opts, files, _} = OptionParser.parse(args, strict: [limit: :integer, json: :boolean])

    file = List.first(files) || raise "Usage: elixir priv/scripts/read_record.exs <file> [--limit N] [--json]"

    if !File.exists?(file) do
      raise "File not found: #{file}"
    end

    data = File.read!(file)
    decompressed = :zlib.gunzip(data)
    records = :erlang.binary_to_term(decompressed)

    records =
      if limit = opts[:limit] do
        # 取最后 N 条（最近的在前）
        Enum.take(records, -limit)
      else
        records
      end

    if opts[:json] do
      records
      |> Enum.map(&sanitize_for_json/1)
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      IO.puts("=== Found #{length(records)} record(s) ===\n")
      records
      |> Enum.with_index(1)
      |> Enum.each(fn {record, idx} ->
        IO.puts("--- Record ##{idx} ---")
        IO.inspect(record)
        IO.puts("")
      end)
    end
  end

  # ── 辅助函数 ───────────────────────────────────────────────────────

  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(list) when is_list(list), do: Enum.map(list, &sanitize_for_json/1)
  defp sanitize_for_json(bin) when is_binary(bin), do: bin
  defp sanitize_for_json(other), do: inspect(other)
end

ReadRecord.main(System.argv())