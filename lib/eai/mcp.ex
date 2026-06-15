defmodule Eai.MCP do
  @moduledoc """
  MCP (Model Context Protocol) client manager.

  On boot:
  1. Reads `config :eai, :mcp_servers` (from config/mcp_servers/*.exs)
  2. Starts an `Anubis.Client` process for each server
  3. Waits for Anubis handshake to complete (polling server_capabilities)
  4. Calls `list_tools()` to discover available tools
  5. Builds runtime `Eai.Tool` modules and merges into the LLM tool registry

  Hot-reload:
      Eai.MCP.reload!()

  Status:
      Eai.MCP.status()
  """

  use GenServer
  require Logger
  alias Eai.MCP.Adapter

  @mcp_config_dir "config/mcp_servers"
  @valid_transports [:stdio, :streamable_http, :sse, :websocket]

  # ── OTP ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    servers = Application.get_env(:eai, :mcp_servers, [])
    Logger.info("MCP: booting with #{length(servers)} server(s)")

    if servers == [] do
      {:ok, initial_state()}
    else
      started = start_all(servers)
      ids = MapSet.new(Enum.map(started, &elem(&1, 0)))
      Process.send_after(self(), :do_discover, 500)
      {:ok, %{initial_state() | servers: started, ids: ids}}
    end
  end

  # ── public API ───────────────────────────────────────────────────────

  @doc "Re-scan all running MCP servers and refresh the tool registry."
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc """
  Hot-reload: re-read config/mcp_servers/*.exs, stop removed servers,
  start new ones, and refresh tools. No VM restart needed.

  Returns `{:ok, diff}` where diff is a map with :added, :removed, :unchanged counts.
  """
  def reload! do
    GenServer.call(__MODULE__, :reload, 30_000)
  end

  @doc """
  Show status of all MCP servers.

  Returns a list of maps:
      [%{id: :filesystem, status: :online, tools: 5, transport: :stdio}, ...]
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── callbacks ────────────────────────────────────────────────────────

  @impl true
  def handle_info(:do_discover, state) do
    {schemas, dispatch, tool_counts} = discover_all(MapSet.to_list(state.ids))
    merge(schemas, dispatch)
    Logger.info("MCP: ready — #{MapSet.size(state.ids)} server(s)")
    {:noreply, %{state | tool_counts: tool_counts}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {_schemas, _dispatch, tool_counts} = discover_all(MapSet.to_list(state.ids))
    {:reply, {:ok, MapSet.size(state.ids)}, %{state | tool_counts: tool_counts}}
  end

  def handle_call(:status, _from, state) do
    entries =
      Enum.map(state.servers, fn {id, opts} ->
        transport = Keyword.get(opts, :transport)
        alive? = server_alive?(id)
        tools = Map.get(state.tool_counts, id, 0)

        %{
          id: id,
          status: if(alive?, do: :online, else: :offline),
          tools: tools,
          transport: transport_type(transport)
        }
      end)

    {:reply, entries, state}
  end

  def handle_call(:reload, _from, state) do
    new_servers = reread_configs()
    new_ids = MapSet.new(Enum.map(new_servers, &elem(&1, 0)))
    old_ids = state.ids

    removed = MapSet.difference(old_ids, new_ids)
    added = MapSet.difference(new_ids, old_ids)

    Enum.each(removed, fn id ->
      Logger.info("MCP: stopping removed server #{id}")
      stop_server(id)
    end)

    new_entries =
      new_servers
      |> Enum.filter(fn {id, _opts} -> MapSet.member?(added, id) end)
      |> Enum.reduce([], fn {id, opts}, acc -> try_start({id, opts}, acc, "skipping") end)

    kept = Enum.filter(state.servers, fn {id, _} -> MapSet.member?(new_ids, id) end)
    all_servers = kept ++ new_entries

    {schemas, dispatch, tool_counts} = discover_all(MapSet.to_list(new_ids))
    merge(schemas, dispatch)

    diff = %{
      added: MapSet.size(added),
      removed: MapSet.size(removed),
      unchanged: MapSet.size(MapSet.intersection(old_ids, new_ids)),
      total: MapSet.size(new_ids)
    }

    Logger.info("MCP: reloaded — +#{diff.added} -#{diff.removed} =#{diff.unchanged} (#{diff.total} total)")
    {:reply, {:ok, diff}, %{state | servers: all_servers, ids: new_ids, tool_counts: tool_counts}}
  end

  # ── internal ─────────────────────────────────────────────────────────

  defp initial_state, do: %{servers: [], ids: MapSet.new(), tool_counts: %{}}

  defp reread_configs do
    config_dir = Path.expand(@mcp_config_dir, File.cwd!())

    if File.dir?(config_dir) do
      config_dir
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        Logger.debug("MCP: re-reading #{Path.basename(file)}")
        {result, _} = Code.eval_file(file)
        result
      end)
    else
      Logger.warning("MCP: config dir not found: #{config_dir}")
      []
    end
  end

  defp stop_server(id) do
    sup_name = Module.concat(id, "Supervisor")

    case Process.whereis(sup_name) do
      nil -> :ok
      pid ->
        try do
          DynamicSupervisor.terminate_child(Eai.MCP.DynamicSupervisor, pid)
        rescue
          _ -> Supervisor.stop(sup_name, :normal, 5_000)
        end
        Logger.info("MCP: #{id} stopped")
    end
  rescue
    _ -> :ok
  end

  defp server_alive?(id) do
    case Process.whereis(id) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp transport_type({type, _opts}) when type in @valid_transports, do: type
  defp transport_type(_), do: :unknown

  # ── config validation ────────────────────────────────────────────────

  defp validate_server_config({id, opts}) when is_atom(id) and is_list(opts) do
    case Keyword.fetch(opts, :transport) do
      {:ok, transport} -> validate_transport(transport)
      :error -> {:error, "missing :transport key in server config"}
    end
  end

  defp validate_server_config({id, _}) do
    {:error, "server id must be an atom, got: #{inspect(id)}"}
  end

  defp validate_transport({type, opts}) when type in @valid_transports and is_list(opts) do
    required_key =
      case type do
        :stdio -> :command
        :streamable_http -> :url
        :sse -> :base_url
        :websocket -> :url
      end

    if Keyword.has_key?(opts, required_key) do
      :ok
    else
      {:error, "#{type} transport requires :#{required_key} option"}
    end
  end

  defp validate_transport(other) do
    {:error,
     "invalid transport format: #{inspect(other)}\n" <>
       "Expected 2-tuple: {:stdio, command: ...} | {:streamable_http, url: ...} | {:sse, base_url: ...} | {:websocket, url: ...}"}
  end

  # ── start / discover ─────────────────────────────────────────────────

  defp start_all(servers) do
    servers
    |> Enum.reduce([], fn {id, opts}, acc -> try_start({id, opts}, acc, "skipped") end)
    |> Enum.reverse()
  end

  defp try_start({id, opts} = server, acc, error_prefix) do
    case validate_server_config(server) do
      :ok ->
        case start_server(id, opts) do
          {:ok, _} -> [{id, opts} | acc]
          _ -> acc
        end

      {:error, reason} ->
        Logger.error("MCP: #{id} #{error_prefix} — #{reason}")
        acc
    end
  end

  defp start_server(id, opts) do
    client_info = Keyword.get(opts, :client_info, %{"name" => "Eai", "version" => "0.1.13"})
    transport = Keyword.fetch!(opts, :transport)

    case Anubis.Client.start_link(
           name: id,
           transport: transport,
           client_info: client_info
         ) do
      {:ok, pid} ->
        Logger.info("MCP: #{id} started")
        {:ok, pid}

      {:error, {:already_started, _}} ->
        Logger.debug("MCP: #{id} already running")
        {:ok, :already_started}

      {:error, reason} ->
        Logger.error("MCP: #{id} failed — #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp discover_all(server_ids) do
    # 等 Anubis 完成内部握手（最多 10 秒，每 200ms 检查一次）
    wait_for_handshake(server_ids, 150)

    tools_by_server =
      Enum.reduce(server_ids, %{}, fn id, acc ->
        case Anubis.Client.list_tools(id) do
          {:ok, %{result: %{"tools" => tools}}} ->
            Logger.info("MCP: #{id} → #{length(tools)} tool(s)")
            Map.put(acc, id, tools)

          {:error, reason} ->
            Logger.error("MCP: #{id} list_tools failed — #{inspect(reason)}")
            Map.put(acc, id, [])
        end
      end)

    counts = Map.new(tools_by_server, fn {id, tools} -> {id, length(tools)} end)
    {schemas, dispatch} = build_io_bridge_entry(tools_by_server)
    {schemas, dispatch, counts}
  end

  defp wait_for_handshake(_server_ids, 0), do: :ok

  defp wait_for_handshake(server_ids, retries) do
    all_ready? = Enum.all?(server_ids, fn id ->
      case Anubis.Client.get_server_capabilities(id) do
        %{} = caps when caps != %{} -> true
        _ -> false
      end
    end)

    if all_ready? do
      :ok
    else
      Process.sleep(200)
      wait_for_handshake(server_ids, retries - 1)
    end
  end

  # Build the single `mcp_io` bridge entry plus a per-server catalog stored
  # in :persistent_term under :eai_mcp_catalog. The catalog is what
  # Eai.MCP.IOBridge consults at execute-time to validate the model's
  # (server, tool) pair before calling Anubis.
  defp build_io_bridge_entry(tools_by_server) do
    catalog = build_catalog_map(tools_by_server)
    schema = Adapter.build_io_bridge_schema()

    :persistent_term.put(:eai_mcp_catalog, catalog)
    {[schema], %{"mcp_io" => Eai.MCP.IOBridge}}
  end

  defp build_catalog_map(tools_by_server) do
    Map.new(tools_by_server, fn {server, tools} ->
      tool_map =
        Map.new(tools, fn tool ->
          name = tool["name"]
          desc = tool["description"] || ""
          schema = tool["inputSchema"] || %{}

          {name,
           %{
             description: desc,
             input_schema: schema
           }}
        end)

      {server, tool_map}
    end)
  end

  # Replace (not append) the mcp_io entry in the tool registry. Without
  # this guard, repeated Eai.MCP.reload!/0 calls would stack up multiple
  # mcp_io entries — and a stale description would mislead the model.
  defp merge(mcp_schemas, mcp_dispatch) do
    existing =
      case :persistent_term.get(:eai_llm_tools, :not_found) do
        :not_found -> %{schemas: [], dispatch: %{}}
        reg -> reg
      end

    cleaned_schemas = Enum.reject(existing.schemas, &mcp_io_schema?/1)
    cleaned_dispatch = Map.drop(existing.dispatch, Map.keys(mcp_dispatch))

    merged = %{
      schemas: cleaned_schemas ++ mcp_schemas,
      dispatch: Map.merge(cleaned_dispatch, mcp_dispatch)
    }

    :persistent_term.put(:eai_llm_tools, merged)
  end

  defp mcp_io_schema?(%{function: %{name: "mcp_io"}}), do: true
  defp mcp_io_schema?(_), do: false
end
