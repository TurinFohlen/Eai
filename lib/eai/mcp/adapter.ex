defmodule Eai.MCP.Adapter do
  @moduledoc """
  Generic `Eai.Tool` dispatch for MCP tools.

  Two flavors of dispatch are supported:

    1. **Per-tool runtime modules** (`build_tool_module/4`) — one schema
       per MCP tool. Useful when tool count is small and stable, but
       triggers the OpenAI `^[a-zA-Z0-9_-]+$` name pattern failure
       (MCP names like `filesystem:read_file` contain a colon), so it
       is no longer wired into the default registry.

    2. **Single base64 pipe tool** (`build_io_bridge_schema/0`) — one
       schema named `mcp_io`. The LLM passes the MCP server name, tool
       name, and a base64-encoded JSON `arguments` blob; the bridge
       forwards the call to Anubis and base64-encodes the resulting
       content back. This is the default exposed to the model — it
       never has to know the underlying tool name grammar.

  `do_execute/5` is shared by both paths and handles the actual
  Anubis call, telemetry, cooldown, and timeout-window check.
  """

  alias Anubis.MCP.Response
  alias Eai.ResultCollector
  alias Eai.Tool.Helpers

  @doc """
  Schema for the single `mcp_io` bridge tool.

  This is the only MCP tool the model ever sees. The `server` and
  `tool` arguments are passed through verbatim (Anubis accepts any
  string the connected server exposes). The `b64_args` argument is
  a **base64-encoded JSON object** — encoding the arguments this way
  sidesteps provider-side JSON schema strictness and lets the model
  pass arbitrarily-shaped arguments without our bridge having to
  predict or validate the per-tool shape.

  The result returned by the bridge has the shape:

      %{
        "server" => server_string,
        "tool" => tool_string,
        "b64_result" => base64(JSON-encoded MCP content blocks)
      }

  The model decodes `b64_result` to read the response. On failure
  the bridge returns a structured `{"error": "..."}` map instead.
  """
  def build_io_bridge_schema do
    %{
      type: "function",
      function: %{
        name: "mcp_io",
        description: """
        Transparent pipe to a connected MCP (Model Context Protocol) server.
        Only the **arguments** are base64-encoded; the **result** is a
        small JSON envelope with both the text view and (when available)
        the structured view of the MCP response.

        ## What to pass

          - `server`  — atom name of a connected MCP server
                        (e.g. `"filesystem"`, `"gdrive"`). Use
                        `Eai.MCP.status()` (out-of-band) to see the list.
          - `tool`    — exact tool name the server exposes, as a string.
                        Pass it verbatim — the server is the source of truth.
          - `b64_args` — base64 of a JSON object. This becomes the
                         `arguments` field of the MCP `tools/call` request.
                         Encode `{"path":"/tmp"}` to get the b64 string.
                         Pass base64 of `{}` for tools that take no args.

        ## What you get back

        A JSON object (returned as a string) with these keys:

          - `server`     — echoed back.
          - `tool`       — echoed back.
          - `text`       — text content extracted from the MCP response
                           `content[].text` blocks, joined with `\n`.
                           Always present, always a plain string. This
                           is the human-readable view of the response
                           (e.g. `[FILE] a.txt\n[FILE] b.txt` for
                           `filesystem.list_directory`).
          - `structured` — the raw `structuredContent` from the MCP
                           response, passed through untouched as a
                           JSON object. **Only present when the server
                           actually supplied it.** Absent otherwise.
                           Use this for machine-consumable data
                           (Calendar events, query rows, etc.) where
                           the text view is a summary and the
                           structured view carries the real fields.

        On error (unknown server, MCP error envelope, invalid
        arguments, etc.) you get instead:

            {"error": "...", "kind": "<error kind>"}

        as the result. The bridge does NOT retry.

        ## Why both views?

        MCP allows servers to expose the same data two ways: a
        human-readable `content` array (text/images/resources) and a
        machine-readable `structuredContent` (arbitrary JSON). Most
        servers use the same string in both, but some (Calendar, Notion,
        SQL) genuinely differ — the text view is a summary, the
        structured view carries typed fields. Keeping both means the
        bridge works for both kinds of server without losing data.

        ## Discovery

        This tool intentionally exposes no tool catalog — the set of
        available `(server, tool)` pairs is whatever the connected
        servers declare, and can change at runtime via
        `Eai.MCP.reload!()`. Inspect `Eai.MCP.status()` or ask the user
        to list connected servers before calling.
        """,
        parameters: %{
          type: "object",
          properties: %{
            server: %{
              type: "string",
              description: """
              MCP server id (the atom name as configured in
              `config/mcp_servers/<name>.exs`). Must be the name of a
              server that is currently online — see `Eai.MCP.status()`.
              """
            },
            tool: %{
              type: "string",
              description: """
              Tool name to invoke on the chosen server. Pass it exactly
              as the server exposes it; this bridge does not normalize
              or validate the name. The server is the source of truth.
              """
            },
            b64_args: %{
              type: "string",
              description: """
              Base64 encoding of a JSON object that will be passed
              verbatim as the `arguments` field of the MCP `tools/call`
              request. To call a tool with `{"path":"/tmp"}`, encode
              the JSON to base64 and pass the result here. Pass
              base64 of `{}` for tools that take no arguments.
              """
            }
          },
          required: ["server", "tool", "b64_args"]
        }
      }
    }
  end

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
          unquote(__MODULE__).do_execute(
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
  def do_execute(server_id, tool_name, args, pty_session_id, _chat_session_id) do
    :telemetry.execute(
      [:eai, :adapter, :mcp, :do_execute, :start],
      %{system_time: System.system_time()},
      %{server_id: server_id, tool_name: tool_name, pty_session_id: pty_session_id}
    )

    # Share the same poll_cooldown_ms that get_task_result uses, so MCP tool
    # calls can't fire faster than the LLM-side poller. Pinned here (not in
    # ExPTY on_data) because the terminal stream itself is fine — only the
    # MCP-driven pull loop was racing.
    cooldown = Helpers.poll_cooldown_ms()
    if is_integer(cooldown) and cooldown > 0, do: Process.sleep(cooldown)

    sanitized = Eai.Utils.sanitize_value(args)

    result =
      case Anubis.Client.call_tool(server_id, tool_name, sanitized) do
        {:ok, response} ->
          response
          |> Response.unwrap()
          |> extract_text()
          |> Eai.Utils.sanitize_value()
          |> Jason.encode!()

        {:error, error} ->
          :telemetry.execute(
            [:eai, :adapter, :mcp, :do_execute, :error],
            %{system_time: System.system_time()},
            %{server_id: server_id, tool_name: tool_name, error: inspect(error)}
          )

          %{error: "MCP tool '#{tool_name}' on #{server_id} failed: #{inspect(error)}"}
          |> Jason.encode!()
      end

    :telemetry.execute(
      [:eai, :adapter, :mcp, :do_execute, :stop],
      %{system_time: System.system_time(), byte_size: byte_size(result)},
      %{server_id: server_id, tool_name: tool_name, pty_session_id: pty_session_id}
    )

    # Mirror the timeout-window check used by get_task_result. If the user
    # triggered Eai.ResultCollector.trigger_timeout_window(pty_session_id), each MCP
    # call here will consume one layer of the depth and append a reminder
    # so the LLM-side loop can wrap up.
    timeout_nudge = if pty_session_id, do: ResultCollector.check_timeout_window(pty_session_id)
    (timeout_nudge && result <> "\n\n" <> timeout_nudge) || result
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp extract_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "resource", "resource" => r} -> "[resource: #{inspect(r)}]"
      other -> inspect(other)
    end)
  end

  defp extract_text(other), do: inspect(other)
end
