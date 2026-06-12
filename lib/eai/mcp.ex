defmodule Eai.MCP do
  @moduledoc """
  MCP (Model Context Protocol) client manager.

  On boot:
  1. Reads `config :eai, :mcp_servers` (from config/mcp_servers.exs)
  2. Starts an `Anubis.Client` process for each server
  3. Calls `list_tools()` to discover available tools
  4. Builds runtime `Eai.Tool` modules and merges into the LLM tool registry
  """

  use GenServer
  require Logger

  # ── OTP ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    servers = Application.get_env(:eai, :mcp_servers, [])
    Logger.info("MCP: booting with #{length(servers)} server(s)")

    if servers == [] do
      {:ok, :idle}
    else
      start_all(servers)
      {:ok, servers, {:continue, :discover}}
    end
  end

  @impl true
  def handle_continue(:discover, servers) do
    server_ids = Enum.map(servers, &elem(&1, 0))
    {schemas, dispatch} = discover_all(server_ids)
    merge(schemas, dispatch)
    Logger.info("MCP: ready — #{length(schemas)} tool(s) from #{length(server_ids)} server(s)")
    {:noreply, servers}
  end

  # ── public API ───────────────────────────────────────────────────────

  @doc "Re-scan all MCP servers and refresh the tool registry."
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @impl true
  def handle_call(:refresh, _from, servers) do
    server_ids = Enum.map(servers, &elem(&1, 0))
    {schemas, dispatch} = discover_all(server_ids)
    merge(schemas, dispatch)
    {:reply, {:ok, length(schemas)}, servers}
  end

  # ── internal ─────────────────────────────────────────────────────────

  defp start_all(servers) do
    Enum.each(servers, fn {id, opts} ->
      client_info = Keyword.get(opts, :client_info, %{name: "Eai"})
      transport = Keyword.fetch!(opts, :transport)

      case Anubis.Client.start_link(
             name: id,
             transport: transport,
             client_info: client_info
           ) do
        {:ok, _pid} -> Logger.info("MCP: #{id} started")
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> Logger.error("MCP: #{id} failed — #{inspect(reason)}")
      end
    end)
  end

  defp discover_all(server_ids) do
    {schemas_acc, dispatch_acc} =
      Enum.reduce(server_ids, {[], %{}}, fn id, {schemas, dispatch} ->
        case Anubis.Client.list_tools(id) do
          {:ok, response} ->
            tools = response[:tools] || []
            Logger.info("MCP: #{id} → #{length(tools)} tool(s)")

            Enum.reduce(tools, {schemas, dispatch}, fn tool, {s_acc, d_acc} ->
              name = tool["name"]
              desc = tool["description"] || ""
              input_schema = tool["inputSchema"] || %{}

              {mod, schema} =
                Eai.MCP.Adapter.build_tool_module(id, name, input_schema, desc)

              tool_name = "#{id}:#{name}"
              {[schema | s_acc], Map.put(d_acc, tool_name, mod)}
            end)

          {:error, reason} ->
            Logger.error("MCP: #{id} list_tools failed — #{inspect(reason)}")
            {schemas, dispatch}
        end
      end)

    {Enum.reverse(schemas_acc), dispatch_acc}
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
