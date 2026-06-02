defmodule Eai.Tool.Helpers do
  @moduledoc "Shared utilities for tool implementations."

  def sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)
  def poll_cooldown_ms, do: Application.get_env(:eai, :poll_cooldown_ms)

  def unescape(input) do
    input
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
    |> String.replace("\\x03", <<3>>)
    |> String.replace("\\x04", <<4>>)
    |> String.replace("\\x1a", <<26>>)
  end

  def maybe_debug_script(path, script) do
    if sandbox_cfg(:debug_pty_output) do
      IO.puts("\n=== SCRIPT START [#{path}] ===\n#{script}\n=== SCRIPT END ===")
    end
    :ok
  end

  # ── Vision model routing ─────────────────────────────────────────────

  def call_vision_model(base64_data, mime, prompt, opts) do
    entry =
      cond do
        is_atom(opts[:vision_model]) and not is_nil(opts[:vision_model]) ->
          Eai.Models.get!(opts[:vision_model])
        is_binary(opts[:vision_model]) ->
          base = Eai.Models.default_vision() || raise "no vision model configured in models.exs"
          Keyword.put(base, :model, opts[:vision_model])
        true ->
          Eai.Models.default_vision() || raise "no vision model configured in models.exs; add vision: true to a model entry"
      end

    model    = entry[:model]
    api_key  = opts[:vision_api_key] || Eai.Models.api_key(entry)
    url      = opts[:vision_url]     || entry[:url]
    provider = entry[:provider]      || :openai_compat

    result = case provider do
      :anthropic     -> vision_call_anthropic(url, api_key, model, base64_data, mime, prompt)
      :openai_compat -> vision_call_openai(url, api_key, model, base64_data, mime, prompt)
    end

    case result do
      {:ok, text} -> {:ok, text, model}
      err         -> err
    end
  end

  defp vision_call_openai(url, api_key, model, base64_data, mime, prompt) do
    body = %{
      model: model,
      max_tokens: 1024,
      messages: [%{
        role: "user",
        content: [
          %{type: "image_url", image_url: %{url: "data:#{mime};base64,#{base64_data}"}},
          %{type: "text", text: prompt}
        ]
      }]
    }
    case Req.post(url,
           json: body,
           headers: [authorization: "Bearer #{api_key}", content_type: "application/json"],
           receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => c}} | _]}}} -> {:ok, c}
      {:ok, %{status: s, body: b}} -> {:error, "vision HTTP #{s}: #{inspect(b)}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end

  defp vision_call_anthropic(url, api_key, model, base64_data, mime, prompt) do
    body = %{
      model: model,
      max_tokens: 1024,
      messages: [%{
        role: "user",
        content: [
          %{type: "image", source: %{type: "base64", media_type: mime, data: base64_data}},
          %{type: "text", text: prompt}
        ]
      }]
    }
    case Req.post(url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => t} | _]}}} -> {:ok, t}
      {:ok, %{status: s, body: b}} -> {:error, "vision HTTP #{s}: #{inspect(b)}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end
end
