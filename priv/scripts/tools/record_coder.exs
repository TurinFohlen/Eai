#!/usr/bin/env elixir
# SPDX-FileDescription: IR JSON ↔ Converse .gz bidirectional codec — decode transcripts, encode contexts

# record_coder.exs — IR JSON ↔ Converse .gz 双向编解码器
#
# Decode:  .gz → pretty transcript / JSON
# Encode:  IR JSON → Converse 规范 .gz（直接喂 Card pre_context 或 replace_context）
#
# 用法:
#   elixir priv/scripts/record_coder.exs decode <file>              # pretty print transcript
#   elixir priv/scripts/record_coder.exs decode <file> --limit N    # 最近 N 条
#   elixir priv/scripts/record_coder.exs decode <file> --json       # JSON 输出
#   elixir priv/scripts/record_coder.exs encode <input.json> <out.gz>

Mix.install([:jason])

defmodule RecordCoder do
  @moduledoc """
  Converse IR JSON 与 Erlang term gzip 的双向桥接器。

  管线:
    IR JSON (messages 列表)
      ↓ encode
    Converse 规范 .gz
      ↓ 作为 pre_context 喂给 subagent / Card
    子 agent 用 Converse adapter 直接消费

  反向:
    Converse 规范 .gz
      ↓ decode
    pretty transcript 或 IR JSON
  """

  # ═══════════════════════════════════════════════════════════════════
  # CLI entry
  # ═══════════════════════════════════════════════════════════════════

  def main(args) do
    {opts, cmd_args, _} =
      OptionParser.parse(args, strict: [limit: :integer, json: :boolean])

    case cmd_args do
      ["encode", input_json, out_gz] ->
        encode(input_json, out_gz)

      ["decode", file | _] ->
        decode(file, opts)

      [file | _] ->
        # 默认行为: decode
        decode(file, opts)

      _ ->
        print_usage()
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Decode: .gz → transcript / JSON
  # ═══════════════════════════════════════════════════════════════════

  defp decode(file, opts) do
    unless File.exists?(file) do
      IO.puts(:stderr, "File not found: #{file}")
      System.halt(1)
    end

    data = File.read!(file)

    decompressed =
      try do
        :zlib.gunzip(data)
      rescue
        _ -> raise "Not a valid gzip file: #{file}"
      end

    messages =
      try do
        :erlang.binary_to_term(decompressed)
      rescue
        _ -> raise "Not a valid Erlang term in: #{file}"
      end

    # Validate it walks like a message list
    unless is_list(messages) do
      raise "Expected a message list, got: #{inspect(messages)}"
    end

    messages =
      if limit = opts[:limit] do
        Enum.take(messages, -limit)
      else
        messages
      end

    if opts[:json] do
      messages
      |> Enum.map(&message_to_json/1)
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_transcript(messages)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Encode: IR JSON → Converse .gz
  # ═══════════════════════════════════════════════════════════════════

  defp encode(input_json, out_gz) do
    unless File.exists?(input_json) do
      IO.puts(:stderr, "Input file not found: #{input_json}")
      System.halt(1)
    end

    raw =
      case Jason.decode!(File.read!(input_json)) do
        list when is_list(list) -> list
        %{"messages" => list} when is_list(list) -> list
        other -> raise "Expected a JSON array of messages, got: #{inspect(other)}"
      end

    messages = Enum.map(raw, &json_to_message/1)

    out_dir = Path.dirname(out_gz)
    if out_dir != "." and out_dir != "" do
      File.mkdir_p!(out_dir)
    end

    binary = :erlang.term_to_binary(messages)
    compressed = :zlib.gzip(binary)
    File.write!(out_gz, compressed)

    IO.puts("Encoded #{length(messages)} messages → #{out_gz}")
    IO.puts("  #{byte_size(compressed)} bytes (gzip)")
    IO.puts("  Feed to: Card pre_context / replace_context / call_subagent pre_context")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Message → JSON (Converse format)
  # ═══════════════════════════════════════════════════════════════════

  defp message_to_json(msg) when is_map(msg) do
    role_str =
      case Map.get(msg, :role) || Map.get(msg, "role") do
        r when is_atom(r) -> Atom.to_string(r)
        r when is_binary(r) -> r
        _ -> "unknown"
      end

    content = Map.get(msg, :content) || Map.get(msg, "content") || []
    content_json = Enum.map(content, &block_to_json/1)

    %{"role" => role_str, "content" => content_json}
  end

  defp message_to_json(other), do: %{"role" => "unknown", "content" => [%{"text" => inspect(other)}]}

  # ── content block → JSON ──────────────────────────────────────────

  defp block_to_json({:text, t}), do: %{"text" => to_string(t)}
  defp block_to_json({:thinking, t}), do: %{"thinking" => to_string(t)}

  defp block_to_json({:image, kw}) when is_list(kw) do
    format = Keyword.get(kw, :format, "png")
    source = Keyword.get(kw, :source, {:bytes, ""})
    bytes = elem(source, 1)
    %{"image" => %{"format" => format, "source" => %{"bytes" => bytes}}}
  end

  defp block_to_json({:tool_use, kw}) when is_list(kw) do
    %{
      "toolUse" => %{
        "toolUseId" => Keyword.get(kw, :tool_use_id) || "",
        "name" => Keyword.get(kw, :name) || "",
        "input" => Keyword.get(kw, :input, %{})
      }
    }
  end

  defp block_to_json({:tool_result, kw}) when is_list(kw) do
    inner = Keyword.get(kw, :content, [])
    %{
      "toolResult" => %{
        "toolUseId" => Keyword.get(kw, :tool_use_id) || "",
        "content" => Enum.map(inner, &block_to_json/1)
      }
    }
  end

  # Fallback: unknown tuple → inspect
  defp block_to_json({tag, payload}) when is_atom(tag) do
    %{"text" => "[#{tag}: #{inspect(payload)}]"}
  end

  defp block_to_json(other) when is_binary(other), do: %{"text" => other}
  defp block_to_json(other), do: %{"text" => inspect(other)}

  # ═══════════════════════════════════════════════════════════════════
  # JSON → Message (Converse → internal IR)
  # ═══════════════════════════════════════════════════════════════════

  defp json_to_message(%{"role" => role_str, "content" => content}) when is_list(content) do
    role =
      try do
        String.to_existing_atom(role_str)
      rescue
        ArgumentError -> String.to_atom(role_str)
      end

    blocks = Enum.map(content, &json_to_block/1)
    %{role: role, content: blocks}
  end

  defp json_to_message(%{"role" => role_str} = msg) do
    # No content key — try text directly
    text = Map.get(msg, "text") || Map.get(msg, "content")
    role =
      try do
        String.to_existing_atom(role_str)
      rescue
        ArgumentError -> String.to_atom(role_str)
      end
    %{role: role, content: [{:text, to_string(text)}]}
  end

  defp json_to_message(other) do
    %{role: :user, content: [{:text, inspect(other)}]}
  end

  # ── JSON block → content tuple ────────────────────────────────────

  defp json_to_block(%{"text" => t}), do: {:text, t}
  defp json_to_block(%{"thinking" => t}), do: {:thinking, t}

  defp json_to_block(%{"image" => %{"format" => fmt, "source" => %{"bytes" => data}}}) do
    {:image, [format: fmt, source: {:bytes, data}]}
  end

  defp json_to_block(%{"toolUse" => tu}) do
    {:tool_use,
     [
       tool_use_id: Map.get(tu, "toolUseId") || "",
       name: Map.get(tu, "name") || "",
       input: Map.get(tu, "input", %{})
     ]}
  end

  # Bedrock Converse bare camelCase variant
  defp json_to_block(%{"toolUseId" => id, "name" => name} = tu) do
    {:tool_use,
     [
       tool_use_id: id,
       name: name,
       input: Map.get(tu, "input", %{})
     ]}
  end

  defp json_to_block(%{"toolResult" => tr}) do
    inner = Map.get(tr, "content", [])
    {:tool_result,
     [
       tool_use_id: Map.get(tr, "toolUseId") || "",
       content: Enum.map(inner, &json_to_block/1)
     ]}
  end

  defp json_to_block(other) when is_map(other) do
    {:text, "[unknown block: #{inspect(other)}]"}
  end

  defp json_to_block(other), do: {:text, inspect(other)}

  # ═══════════════════════════════════════════════════════════════════
  # Pretty-print transcript
  # ═══════════════════════════════════════════════════════════════════

  defp print_transcript(messages) do
    total = length(messages)
    IO.puts(String.duplicate("─", 60))

    messages
    |> Enum.with_index(1)
    |> Enum.each(fn {msg, idx} ->
      role = get_role(msg)
      content = get_content(msg)

      # Header
      role_icon = role_icon(role)
      IO.puts("\n#{role_icon} Message #{idx}/#{total}  #{role_label(role)}")

      # Print each content block
      Enum.each(content, fn block ->
        case block do
          {:text, t} ->
            IO.puts(String.trim(t))

          {:thinking, t} ->
            IO.puts("💭 #{String.trim(t)}")

          {:tool_use, kw} ->
            IO.puts("")
            IO.puts("  🔧 TOOL: #{Keyword.get(kw, :name, "?")}")
            IO.puts("     id: #{Keyword.get(kw, :tool_use_id, "?")}")
            input = Keyword.get(kw, :input, %{})
            if map_size(input) > 0 do
              IO.puts("     input: #{Jason.encode!(input)}")
            end

          {:tool_result, kw} ->
            IO.puts("  📦 RESULT for #{Keyword.get(kw, :tool_use_id, "?")}:")
            inner = Keyword.get(kw, :content, [])
            Enum.each(inner, fn
              {:text, t} -> IO.puts("     #{String.trim(t)}")
              other -> IO.puts("     #{inspect(other)}")
            end)

          {:image, _kw} ->
            IO.puts("  🖼️  [image]")

          other ->
            IO.puts(inspect(other))
        end
      end)

      IO.puts("")
      IO.puts(String.duplicate("─", 60))
    end)
  end

  defp get_role(%{role: r}) when is_atom(r), do: r
  defp get_role(%{"role" => r}) when is_binary(r), do: String.to_atom(r)
  defp get_role(_), do: :unknown

  defp get_content(%{content: c}) when is_list(c), do: c
  defp get_content(%{"content" => c}) when is_list(c), do: c
  defp get_content(_), do: []

  defp role_icon(:user), do: "👤"
  defp role_icon(:assistant), do: "🤖"
  defp role_icon(_), do: "❓"

  defp role_label(:user), do: "USER"
  defp role_label(:assistant), do: "ASSISTANT"
  defp role_label(other), do: String.upcase(to_string(other))

  # ═══════════════════════════════════════════════════════════════════
  # Help
  # ═══════════════════════════════════════════════════════════════════

  defp print_usage do
    IO.puts("""
    record_coder.exs — IR JSON ↔ Converse .gz 双向编解码器

    用法:
      elixir priv/scripts/record_coder.exs decode <file>              # pretty print transcript
      elixir priv/scripts/record_coder.exs decode <file> --limit N    # 最近 N 条
      elixir priv/scripts/record_coder.exs decode <file> --json       # Converse JSON 输出
      elixir priv/scripts/record_coder.exs encode <input.json> <out.gz>

    管线:
      IR JSON (messages 列表)
        ↓ encode
      Converse 规范 .gz
        ↓ 作为 pre_context 喂给 subagent / Card
      子 agent 用 Converse adapter 直接消费
    """)
  end
end

RecordCoder.main(System.argv())
