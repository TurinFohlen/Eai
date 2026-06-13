defmodule Eai.MCP do
  @moduledoc """
  MCP (Model Context Protocol) client manager.

  On boot:
  1. Reads `config :eai, :mcp_servers` (from config/mcp_servers/*.exs)
  2. Starts an `Anubis.Client` process for each server
  3. Calls `list_tools()` to discover available tools
  4. Builds runtime `Eai.Tool` modules and merges into the LLM tool registry

  Hot-reload:
      Eai.MCP.reload!()

  Status:
      Eai.MCP.status()
  """

  use GenServer
  require Logger

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
      {:ok, %{initial_state() | servers: started, ids: ids}, {:continue, :discover}}
    end
  end

  @impl true
  def handle_continue(:discover, state) do
    {schemas, dispatch, tool_counts} = discover_all(MapSet.to_list(state.ids))
    merge(schemas, dispatch)
    Logger.info("MCP: ready — #{MapSet.size(state.ids)} server(s)")
    {:noreply, %{state | tool_counts: tool_counts}}
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

    # Stop removed
    Enum.each(removed, fn id ->
      Logger.info("MCP: stopping removed server #{id}")
      stop_server(id)
    end)

    # Validate + start added
    new_entries =
      new_servers
      |> Enum.filter(fn {id, _opts} -> MapSet.member?(added, id) end)
      |> Enum.reduce([], fn {id, opts}, acc -> try_start({id, opts}, acc, "skipping") end)

    # Keep existing that are still present
    kept = Enum.filter(state.servers, fn {id, _} -> MapSet.member?(new_ids, id) end)
    all_servers = kept ++ new_entries

    # Refresh tools
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
    config_dir = Path.join(:code.priv_dir(:eai) |> Path.dirname(), @mcp_config_dir)

    if File.dir?(config_dir) do
      config_dir
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.each(fn file ->
        Logger.debug("MCP: re-reading #{Path.basename(file)}")
        Code.eval_file(file)
      end)

      Application.get_env(:eai, :mcp_servers, [])
    else
      Logger.warning("MCP: config dir not found: #{config_dir}")
      []
    end
  end

  defp stop_server(id) do
    sup_name = Module.concat(id, "Supervisor")

    case Process.whereis(sup_name) do
      nil ->
        :ok

      pid ->
        # Try DynamicSupervisor first, fall back to Supervisor.stop
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
    # Check if the Anubis.Client process is alive
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
      {:ok, transport} ->
        validate_transport(transport)

      :error ->
        {:error, "missing :transport key in server config"}
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
    Enum.reduce(server_ids, {[], %{}, %{}}, &discover_server_tools/2)
  end

  defp discover_server_tools(id, {schemas, dispatch, counts}) do
    case Anubis.Client.list_tools(id) do
      {:ok, response} ->
        tools = response[:tools] || []
        Logger.info("MCP: #{id} → #{length(tools)} tool(s)")

        {new_schemas, new_dispatch} = build_tool_entries(tools, id)
        {schemas ++ new_schemas, Map.merge(dispatch, new_dispatch), Map.put(counts, id, length(tools))}

      {:error, reason} ->
        Logger.error("MCP: #{id} list_tools failed — #{inspect(reason)}")
        {schemas, dispatch, Map.put(counts, id, 0)}
    end
  end

  defp build_tool_entries(tools, id) do
    Enum.reduce(tools, {[], %{}}, fn tool, {s_acc, d_acc} ->
      name = tool["name"]
      desc = tool["description"] || ""
      input_schema = tool["inputSchema"] || %{}

      {mod, schema} = Eai.MCP.Adapter.build_tool_module(id, name, input_schema, desc)
      tool_name = "#{id}:#{name}"
      {[schema | s_acc], Map.put(d_acc, tool_name, mod)}
    end)
  end

  defp merge(mcp_schemas, mcp_dispatch) do
    existing =
      case :persistent_term.get(:eai_llm_tools, :not_found) do
        :not_found -> %{schemas: [], dispatch: %{}}
        reg -> reg
      end

    merged = %{
      schemas: existing.schemas ++ mcp_schemas,
      dispatch: Map.merge(existing.dispatch, mcp_dispatch)
    }

    :persistent_term.put(:eai_llm_tools, merged)
  end
end
