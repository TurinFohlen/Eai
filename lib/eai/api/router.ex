defmodule Eai.API.Router do
  @moduledoc false
  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  # ── Health ──────────────────────────────────────────────────────────

  get "/health" do
    send_json(conn, 200, %{
      status: "ok",
      version: "0.1.13",
      models: Eai.Models.names()
    })
  end

  # ── GET /v1/models ─────────────────────────────────────────────────

  get "/v1/models" do
    models =
      Enum.map(Eai.Models.all(), fn m ->
        %{
          id: to_string(m[:name]),
          object: "model",
          created: System.system_time(:second),
          owned_by: "eai"
        }
      end)

    send_json(conn, 200, %{object: "list", data: models})
  end

  # ── POST /v1/chat/completions ──────────────────────────────────────

  post "/v1/chat/completions" do
    body = conn.body_params

    with {:ok, model} <- extract_model(body),
         {:ok, messages} <- extract_messages(body) do
      # Extract the last user message as content
      user_content =
        messages
        |> Enum.filter(&(&1["role"] == "user"))
        |> List.last()
        |> case do
          %{"content" => c} when is_binary(c) -> c
          _ -> nil
        end

      if is_nil(user_content) do
        send_json(conn, 400, %{
          error: %{message: "No user message found", type: "invalid_request_error"}
        })
      else
        # Extract optional params
        opts = [content: user_content, model: model, mod: :function]
        opts = maybe_add_prompt(opts, body)

        timeout = Map.get(body, "timeout", 120_000)
        opts = Keyword.put(opts, :timeout, timeout)

        case Eai.Chat.talk(opts) do
          {:ok, reply} ->
            response = %{
              id: "chatcmpl-#{System.unique_integer([:positive])}",
              object: "chat.completion",
              created: System.system_time(:second),
              model: to_string(model),
              choices: [
                %{
                  index: 0,
                  message: %{role: "assistant", content: reply},
                  finish_reason: "stop"
                }
              ],
              usage: %{
                prompt_tokens: estimate_tokens(user_content),
                completion_tokens: estimate_tokens(reply),
                total_tokens: estimate_tokens(user_content) + estimate_tokens(reply)
              }
            }

            send_json(conn, 200, response)

          {:error, :busy} ->
            send_json(conn, 429, %{
              error: %{message: "Session busy, try again later", type: "server_error"}
            })

          {:error, reason} ->
            send_json(conn, 500, %{error: %{message: inspect(reason), type: "server_error"}})
        end
      end
    else
      {:error, field, msg} ->
        send_json(conn, 400, %{
          error: %{message: "#{field}: #{msg}", type: "invalid_request_error"}
        })
    end
  end

  # ── GET /v1/tools ──────────────────────────────────────────────────

  get "/v1/tools" do
    tools =
      case :persistent_term.get(:eai_llm_tools, :not_found) do
        :not_found ->
          []

        %{schemas: schemas} ->
          Enum.map(schemas, fn s ->
            %{
              name: s["name"] || s[:name],
              description: s["description"] || s[:description] || "",
              parameters: s["inputSchema"] || s[:input_schema] || %{}
            }
          end)
      end

    send_json(conn, 200, %{object: "list", data: tools, total: length(tools)})
  end

  # ── Fallback ────────────────────────────────────────────────────────

  match _ do
    send_json(conn, 404, %{error: %{message: "Not found", type: "invalid_request_error"}})
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp extract_model(%{"model" => model}) when is_binary(model) do
    # Accept both atom-style ("deepseek") and string-style ("deepseek-chat")
    atom_model =
      try do
        String.to_existing_atom(model)
      rescue
        ArgumentError -> model
      end

    available = Eai.Models.names()

    if atom_model in available do
      {:ok, atom_model}
    else
      # Try string match
      match = Enum.find(available, &(to_string(&1) == model))

      if match,
        do: {:ok, match},
        else: {:error, "model", "unknown model '#{model}'. Available: #{inspect(available)}"}
    end
  end

  defp extract_model(_), do: {:error, "model", "required field 'model' must be a string"}

  defp extract_messages(%{"messages" => [_ | _] = messages}) do
    {:ok, messages}
  end

  defp extract_messages(%{"messages" => _}), do: {:error, "messages", "must be a non-empty array"}
  defp extract_messages(_), do: {:error, "messages", "required field 'messages' must be an array"}

  defp maybe_add_prompt(opts, %{"prompt" => p}) when is_binary(p) do
    atom_p =
      try do
        String.to_existing_atom(p)
      rescue
        ArgumentError -> p
      end

    available = Eai.Prompts.names()
    if atom_p in available, do: Keyword.put(opts, :prompt, atom_p), else: opts
  end

  defp maybe_add_prompt(opts, _), do: opts

  # Very rough token estimate (4 chars ≈ 1 token for English, ~2 chars for CJK)
  defp estimate_tokens(text) when is_binary(text), do: max(1, div(String.length(text), 3))
  defp estimate_tokens(_), do: 0
end
