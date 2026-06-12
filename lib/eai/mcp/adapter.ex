defmodule Eai.MCP.Adapter do
  @moduledoc """
  Generic `Eai.Tool` dispatch for MCP tools.

  Each MCP tool gets a lightweight runtime module (via `Module.create/3`)
  that delegates to `do_execute/5` with the server_id and tool_name baked in.
  """

  require Logger

  @doc """
  Build a runtime module for one MCP tool.

  Returns `{module, schema_map}` suitable for injection into the tool registry.
  """
  def build_tool_module(server_id, tool_name, input_schema, description) do
    alias_part = server_id |> to_string() |> Macro.camelize()
    tool_part = tool_name |> to_string() |> Macro.camelize()
    mod_name = Module.concat([Eai, MCP, Tools, alias_part, tool_part])

    # Parameter names from the MCP inputSchema
    param_props = Map.get(input_schema, "properties", %{})
    required = Map.get(input_schema, "required", [])

    schema = %{
      type: "function",
      function: %{
        name: "#{server_id}:#{tool_name}",
        description: "[MCP/#{server_id}] #{description}",
        parameters: %{
          type: "object",
          properties: param_props,
          required: required
        }
      }
    }

    # Build the module via Module.create
    ast =
      quote do
        @behaviour Eai.Tool

        @impl true
        def schema, do: unquote(Macro.escape(schema))

        @impl true
        def execute(args, pty_session_id, chat_session_id) do
          Eai.MCP.Adapter.do_execute(
            unquote(server_id),
            unquote(tool_name),
            args,
            pty_session_id,
            chat_session_id
          )
        end
      end

    Module.create(mod_name, ast, Macro.Env.location(__ENV__))

    {mod_name, schema}
  end

  @doc false
  def do_execute(server_id, tool_name, args, _pty_session_id, _chat_session_id) do
    sanitized = Eai.Utils.sanitize_value(args)

    case Anubis.Client.call_tool(server_id, tool_name, sanitized) do
      {:ok, response} ->
        extract_text(response)
        |> Eai.Utils.sanitize_value()
        |> Jason.encode!()

      {:error, error} ->
        %{error: "MCP tool '#{tool_name}' on #{server_id} failed: #{inspect(error)}"}
        |> Jason.encode!()
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "resource", "resource" => r} -> "[resource: #{inspect(r)}]"
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp extract_text(other), do: inspect(other)
end
