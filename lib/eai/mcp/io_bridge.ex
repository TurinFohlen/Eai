defmodule Eai.MCP.IOBridge do
  @moduledoc """
  The single `mcp_io` tool exposed to the LLM.

  Why a single tool, not one-per-MCP-tool? Three reasons:

    1. **Provider name validation.** OpenAI / DeepSeek reject tool
       names that don't match `^[a-zA-Z0-9_-]+$`. Native MCP tool
       names like `filesystem:read_file` contain a colon, so registering
       them directly triggers an HTTP 400 from the provider. A single
       `mcp_io` tool sidesteps this by being the only name the model
       ever sees.

    2. **No schema prediction.** Each MCP server defines its own tool
       `inputSchema`. Building a union of N×M schemas is fragile and
       bloats every request body. With base64-encoded arguments the
       bridge imposes no shape — the model can pass anything the
       server accepts.

    3. **Provider-agnostic arguments.** Wrapping the arguments in
       base64 means the bridge's JSON schema only constrains the
       *envelope* (server, tool, b64_args), never the *payload*.
       This is what lets one tool wrap every MCP server uniformly.

  Encoding is **asymmetric** by design:

    - The model's *input* is base64-encoded (`b64_args`) so the bridge
      imposes no schema on the JSON object the server receives.
    - The model's *output* is a JSON envelope with two fields:
        * `text` — text extracted from MCP `content[].text` blocks,
          joined with newlines. Always present, always plain string.
        * `structured` — the raw `structuredContent` from the MCP
          response, passed through untouched as a JSON object. Only
          present when the server actually supplied it; absent
          otherwise (no noise).

  This split keeps the primary response human-readable (the text view)
  while still exposing the structured view for servers that use it
  for genuine machine consumption (Calendar events, query rows, etc.).
  We don't reuse `Eai.MCP.Adapter.do_execute/5` because that function
  discards `structuredContent` and re-stringifies the result; the
  IOBridge calls Anubis directly so the full envelope survives.

  Errors from the call are surfaced as `{"error": "..."}` text in the
  `text` field with a `kind` discriminator, so the model gets a single
  string back either way and never has to branch on result shape.

  Server validity is checked at execute time (atom exists in
  :eai_mcp_catalog, server process alive) so `Eai.MCP.reload!()` —
  which can add or remove servers — is reflected immediately.
  """

  @behaviour Eai.Tool

  alias Anubis.MCP.Response
  alias Eai.MCP.Adapter
  alias Eai.ResultCollector
  alias Eai.Tool.Helpers

  @catalog_key :eai_mcp_catalog

  @impl true
  def schema, do: Adapter.build_io_bridge_schema()

  @impl true
  def execute(args, pty_session_id, chat_session_id) do
    with {:ok, server} <- fetch_server(args),
         {:ok, tool} <- fetch_tool(args),
         {:ok, decoded_args} <- fetch_decoded_args(args),
         :ok <- ensure_server_ready(server),
         :ok <- ensure_tool_exists(server, tool) do
      call_mcp(server, tool, decoded_args, pty_session_id, chat_session_id)
    else
      {:error, kind, info} -> error_json(kind, info)
    end
  end

  # The actual Anubis call. We can't go through `Adapter.do_execute/5`
  # because that helper flattens content blocks into a single text
  # string and re-`Jason.encode!`s the whole thing, which discards
  # `structuredContent` and turns the response into a JSON-quoted blob.
  # The IOBridge needs to preserve the full envelope so structured
  # views (Calendar events, query rows, etc.) survive.
  #
  # We do still reuse the cooldown / telemetry / timeout-window
  # plumbing from `do_execute` so observability stays consistent.
  defp call_mcp(server, tool, decoded_args, pty_session_id, _chat_session_id) do
    :telemetry.execute(
      [:eai, :adapter, :mcp, :do_execute, :start],
      %{system_time: System.system_time()},
      %{server_id: server, tool_name: tool, pty_session_id: pty_session_id}
    )

    cooldown = Helpers.poll_cooldown_ms()
    if is_integer(cooldown) and cooldown > 0, do: Process.sleep(cooldown)

    sanitized = Eai.Utils.sanitize_value(decoded_args)

    result =
      case Anubis.Client.call_tool(server, tool, sanitized) do
        {:ok, response} ->
          unwrapped = Response.unwrap(response) |> Eai.Utils.sanitize_value()
          text = extract_text(unwrapped)
          structured = Map.get(unwrapped, "structuredContent")

          envelope = %{"server" => server, "tool" => tool, "text" => text}

          envelope =
            if structured, do: Map.put(envelope, "structured", structured), else: envelope

          :telemetry.execute(
            [:eai, :adapter, :mcp, :do_execute, :stop],
            %{system_time: System.system_time(), byte_size: byte_size(Jason.encode!(envelope))},
            %{server_id: server, tool_name: tool, pty_session_id: pty_session_id}
          )

          # Embed the envelope in a string so the existing timeout-window
          # append logic (which concatenates to a string) still works.
          encoded = Jason.encode!(envelope)
          maybe_append_nudge(encoded, pty_session_id)

        {:error, error} ->
          :telemetry.execute(
            [:eai, :adapter, :mcp, :do_execute, :error],
            %{system_time: System.system_time()},
            %{server_id: server, tool_name: tool, error: inspect(error)}
          )

          %{
            error: "MCP tool '#{tool}' on #{server} failed: #{inspect(error)}",
            kind: :anubis_error
          }
          |> Jason.encode!()
      end

    result
  end

  defp extract_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "resource", "resource" => r} -> "[resource: #{inspect(r)}]"
      other -> inspect(other)
    end)
  end

  defp extract_text(other), do: inspect(other)

  defp maybe_append_nudge(result_string, pty_session_id) do
    if pty_session_id do
      case ResultCollector.check_timeout_window(pty_session_id) do
        nil -> result_string
        nudge -> result_string <> "\n\n" <> nudge
      end
    else
      result_string
    end
  end

  # ── arg parsing ──────────────────────────────────────────────────────

  defp fetch_server(args) do
    case Map.get(args, "server") do
      s when is_binary(s) and s != "" -> resolve_known_server(s)
      other when is_binary(other) -> {:error, :missing_server, other}
      nil -> {:error, :missing_server, nil}
    end
  end

  # The string from the model has to be a registered MCP server — that means
  # (a) it must resolve to an existing atom (not arbitrary gibberish like
  # "ghost"), and (b) the atom must appear in the live catalog that
  # Eai.MCP keeps in :persistent_term. We intentionally reject bare atoms
  # like :filesystem that exist in the BEAM but aren't connected as MCP
  # servers, so the model can't accidentally address some other process.
  #
  # `String.to_existing_atom/1` raises `ArgumentError` for unknown strings;
  # we catch it and report the same "unknown server" error as we do for a
  # known atom that simply isn't connected. No helper wrapper needed —
  # the `try/rescue` makes both branches explicit so dialyzer doesn't
  # complain about a redundant `is_atom/1` guard.
  defp resolve_known_server(str) do
    catalog = :persistent_term.get(@catalog_key, %{})
    available = catalog |> Map.keys() |> Enum.sort()
    unknown = {:error, :unknown_server, %{name: str, available: available}}

    try do
      atom = String.to_existing_atom(str)

      if Map.has_key?(catalog, atom) do
        {:ok, atom}
      else
        unknown
      end
    rescue
      ArgumentError -> unknown
    end
  end

  defp fetch_tool(args) do
    case Map.get(args, "tool") do
      t when is_binary(t) and t != "" -> {:ok, t}
      nil -> {:error, :missing_tool, nil}
      other when is_binary(other) -> {:error, :missing_tool, other}
    end
  end

  # Decode the base64 JSON envelope into a plain map. The decoded value
  # is forwarded verbatim as the MCP `arguments` object, so we do not
  # impose any further schema — the server validates it.
  defp fetch_decoded_args(args) do
    case Map.get(args, "b64_args") do
      b when is_binary(b) and b != "" -> decode_b64_args(b)
      nil -> {:error, :missing_b64_args, nil}
      other when is_binary(other) -> {:error, :missing_b64_args, other}
    end
  end

  defp decode_b64_args(b) do
    with {:ok, raw} <- Base.decode64(b),
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      :error -> {:error, :bad_base64, b}
      {:error, %Jason.DecodeError{} = err} -> {:error, :bad_json, err}
      false -> {:error, :bad_args_shape, "(non-object)"}
    end
  end

  # ── live-state checks against the catalog ───────────────────────────

  defp ensure_server_ready(server) do
    case Process.whereis(server) do
      nil -> {:error, :server_offline, server}
      pid when is_pid(pid) -> :ok
    end
  end

  # The MCP `tools/call` protocol carries tool names exactly as the
  # server exposed them during `tools/list`. We only confirm the
  # server exposes *some* tool by that name; the server itself
  # validates arguments and reports schema errors. This is intentional:
  # the bridge has no way to know each server's per-tool inputSchema
  # without keeping a much heavier catalog, and the model already
  # needs the schema to formulate correct calls in the first place.
  defp ensure_tool_exists(server, tool_name) do
    catalog = :persistent_term.get(@catalog_key, %{})
    server_tools = Map.get(catalog, server, %{})

    if Map.has_key?(server_tools, tool_name) do
      :ok
    else
      available = server_tools |> Map.keys() |> Enum.sort()
      {:error, :unknown_tool, %{server: server, tool: tool_name, available: available}}
    end
  end

  # ── error formatting ─────────────────────────────────────────────────

  # Two error categories, two small maps. Splitting the case statement keeps
  # cyclomatic complexity under credo @moduledoc limits and makes it easy to
  # add new error kinds to one side without touching the other.
  defp error_json(kind, info) do
    body =
      case kind do
        k
        when k in [
               :missing_server,
               :missing_tool,
               :missing_b64_args,
               :bad_base64,
               :bad_json,
               :bad_args_shape
             ] ->
          envelope_error(k, info)

        _ ->
          runtime_error(kind, info)
      end

    Jason.encode!(body)
  end

  # Errors the model can fix by changing what it sends next.
  defp envelope_error(:missing_server, _),
    do: %{
      error: "mcp_io requires a 'server' argument (string)",
      hint: "Pass the atom name of a connected MCP server."
    }

  defp envelope_error(:missing_tool, _),
    do: %{
      error: "mcp_io requires a 'tool' argument (string)",
      hint: "Pass the exact tool name the server exposes."
    }

  defp envelope_error(:missing_b64_args, _),
    do: %{
      error: "mcp_io requires a 'b64_args' argument (non-empty string)",
      hint: "Pass base64(JSON_object). Use base64 of '{}' for no-arg tools."
    }

  defp envelope_error(:bad_base64, b),
    do: %{
      error: "'b64_args' is not valid base64",
      input_preview: String.slice(b, 0, 80)
    }

  defp envelope_error(:bad_json, err),
    do: %{error: "decoded base64 is not valid JSON", detail: Exception.message(err)}

  defp envelope_error(:bad_args_shape, other),
    do: %{
      error: "'b64_args' must decode to a JSON object, got: #{inspect(other)}",
      hint: "The MCP arguments payload must be a JSON object ({}), not an array/scalar."
    }

  # Errors the model can react to (unknown server/tool/offline) plus the
  # catch-all that should never fire but is here so a future kind is
  # still reported as JSON instead of crashing the bridge.
  defp runtime_error(:unknown_server, %{name: name, available: avail}),
    do: %{
      error: "unknown MCP server: #{inspect(name)}",
      available_servers: Enum.map(avail, &"`#{&1}`")
    }

  defp runtime_error(:server_offline, server),
    do: %{
      error: "MCP server `#{server}` is not running",
      hint: "Check Eai.MCP.status() and call Eai.MCP.reload!() if needed."
    }

  defp runtime_error(:unknown_tool, %{server: s, tool: t, available: avail}),
    do: %{
      error: "MCP tool `#{t}` is not provided by server `#{s}`",
      available_tools: avail
    }

  defp runtime_error(kind, info),
    do: %{error: "mcp_io failed", kind: kind, info: inspect(info)}
end
