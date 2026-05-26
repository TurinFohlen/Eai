defmodule Eai.Record do
  use GenServer

  alias Eai.Utils    # ← 诉求一：日志写入前清洗

  # 客户端 API
  def start_link(file_path) do
    GenServer.start_link(__MODULE__, file_path, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__, :normal)
  end

  # 服务端回调
def init(file_path) do
  file_path |> Path.dirname() |> File.mkdir_p!()
  {:ok, file} = File.open(file_path, [:append, :binary])

  z = :zlib.open()
  # 关键是 windowBits = 15 + 16，生成 gzip 格式
  :zlib.deflateInit(z, :default, :deflated, 15 + 16, 8, :default)

  Phoenix.PubSub.subscribe(Eai.PubSub, "chat_updates")

  {:ok, %{file: file, z: z}}
end
  # 收到广播消息
  def handle_info({:new_message, messages}, state) do
    # 诉求一：日志写入出口 — 先清洗消息列表，确保 term_to_binary 不含非法字节
    sanitized = Utils.sanitize_messages(messages)

    binary     = :erlang.term_to_binary(sanitized)
    compressed = :zlib.deflate(state.z, binary, :sync)
    IO.binwrite(state.file, compressed)

    {:noreply, state}
  end

  def handle_info({:error, _reason}, state) do
    # 错误事件不写入文件，静默忽略即可
    {:noreply, state}
  end

  # 终止时清理资源
  def terminate(_reason, state) do
    final = :zlib.deflate(state.z, <<>>, :finish)
    IO.binwrite(state.file, final)
    :zlib.deflateEnd(state.z)
    File.close(state.file)
    :ok
  end
end
