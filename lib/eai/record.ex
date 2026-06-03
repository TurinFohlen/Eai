defmodule Eai.Record do
  @moduledoc "GenServer for background persistence of conversation history to compressed logs."

  use GenServer
  alias Eai.Utils

  # ── 客户端 API ──────────────────────────────────────────────────

  @doc """
  启动 Record 进程，订阅指定 chat_session 的更新并持久化到文件。

  - base_dir: 存储目录
  - session_id: chat session 名（原子或字符串，nil 则默认 "default"）

  文件路径为 base_dir/file_<session_id>.gzip。
  """
  def start_link(base_dir, session_id \\ nil) do
    session_str = to_string(session_id || "default")
    GenServer.start_link(__MODULE__, {base_dir, session_str}, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__, :normal)
  end

  # ── 服务端回调 ─────────────────────────────────────────────────
  def init({base_dir, session_id}) do
    Phoenix.PubSub.subscribe(Eai.Naming.pubsub(), "chat_updates:#{session_id}")
    file_path = Path.join(base_dir, "file_#{session_id}.gzip")
    {:ok, %{file_path: file_path}}
  end

  def handle_info({:new_message, messages}, state) do
    sanitized  = Utils.sanitize_messages(messages)
    binary     = :erlang.term_to_binary(sanitized)
    compressed = :zlib.gzip(binary)

    File.mkdir_p!(Path.dirname(state.file_path))
    File.write!(state.file_path, compressed)

    {:noreply, state}
  end

  def handle_info({:error, _reason}, state) do
    {:noreply, state}
  end

  def terminate(_reason, _state) do
    :ok
  end
end
