defmodule Eai.Tool.ReadMediaFile do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "read_media_file",
        description: """
        Read an image or video file and return its metadata plus a base64-encoded preview
        (image as-is, video as a frame). Optionally pass analyze_prompt to have a
        vision-capable model (GPT-4o, Claude, LLaVA, etc.) describe or analyse the visual
        content — the model is chosen independently of the current conversation model, so
        you can route vision tasks to the best available multimodal endpoint.

        When inject is true, the file is NOT analyzed by a separate vision model.
        Instead, the media is returned as Converse-format content blocks that can be
        injected directly into the current conversation stream, allowing the main model
        to "see" the image.

        Returns JSON with keys: ok, type, mime, file_size, metadata, base64, compression,
        and (if analyze_prompt was set) vision_analysis + vision_model.
        When inject=true: returns type="multimodal_inject" with blocks array.
        """,
        parameters: %{
          type: "object",
          properties: %{
            file_path: %{
              type: "string",
              description: "Absolute path to the media file (must be inside workspace)."
            },
            media_type: %{
              type: "string",
              enum: ["image", "video", "auto"],
              description: "Force type detection. Defaults to auto."
            },
            video_frame_time: %{
              type: "number",
              description: "For video: extract frame at this second. Default 0."
            },
            max_dimension: %{
              type: "integer",
              description:
                "Resize longest edge to this px before encoding. Default 1024. Set 0 for original."
            },
            analyze_prompt: %{
              type: "string",
              description:
                "If set, send the extracted image to a vision model with this prompt and return the analysis."
            },
            inject: %{
              type: "boolean",
              description:
                "If true, return Converse content blocks for injection into conversation (no separate vision call)."
            },
            vision_model: %{
              type: "string",
              description:
                "Vision model to use when analyze_prompt is set. E.g. 'gpt-4o', 'claude-opus-4-6', 'llava'. Defaults to config :vision_model or 'gpt-4o'."
            },
            vision_api_key: %{
              type: "string",
              description: "Override API key for the vision model call."
            },
            vision_url: %{
              type: "string",
              description:
                "Override base API URL for the vision model (OpenAI-compatible or Anthropic)."
            }
          },
          required: ["file_path"]
        }
      }
    }
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    file_path = args["file_path"]
    work_root = Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(:work_dir_root)

    if not String.starts_with?(Path.expand(file_path), Path.expand(work_root)) do
      Jason.encode!(%{ok: false, reason: "file path outside workspace"})
    else
      max_dim = to_string(args["max_dimension"] || 1024)
      frame_time = to_string(args["video_frame_time"] || 0)
      media_type = args["media_type"] || "auto"
      script = Path.join(:code.priv_dir(:eai), "scripts/media_reader.py")

      case System.cmd(
             "python3",
             [
               script,
               file_path,
               "--max-dim",
               max_dim,
               "--frame-time",
               frame_time,
               "--type",
               media_type
             ], stderr_to_stdout: false, timeout: 30_000) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"ok" => true} = media} ->
              cond do
                # ── Inject mode: return Converse blocks for conversation injection ──
                truthy?(args["inject"]) ->
                  format = extract_format(media["mime"])
                  base64_data = media["base64"]

                  blocks = [
                    %{"text" => args["analyze_prompt"] || "请分析这个媒体文件"},
                    %{
                      "image" => %{
                        "format" => format,
                        "source" => %{"bytes" => base64_data}
                      }
                    }
                  ]

                  Jason.encode!(%{
                    type: "multimodal_inject",
                    blocks: blocks
                  })

                # ── Analyze mode: call separate vision model ──
                not is_nil(args["analyze_prompt"]) ->
                  vision_result =
                    call_vision_model(
                      media["base64"],
                      media["mime"],
                      args["analyze_prompt"],
                      vision_model: args["vision_model"],
                      vision_api_key: args["vision_api_key"],
                      vision_url: args["vision_url"]
                    )

                  case vision_result do
                    {:ok, analysis, model_used} ->
                      media
                      |> Map.put("vision_analysis", analysis)
                      |> Map.put("vision_model", model_used)
                      |> Jason.encode!()

                    {:error, reason} ->
                      media
                      |> Map.put("vision_analysis", nil)
                      |> Map.put("vision_error", reason)
                      |> Jason.encode!()
                  end

                # ── Plain mode: just return media metadata ──
                true ->
                  Jason.encode!(media)
              end

            {:ok, err_map} ->
              Jason.encode!(err_map)

            {:error, _} ->
              Jason.encode!(%{ok: false, reason: "invalid output from media_reader", raw: output})
          end

        {error, code} ->
          Jason.encode!(%{
            ok: false,
            reason: "media_reader exited #{code}: #{String.trim(error)}"
          })
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp truthy?(val) when val in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp extract_format(mime) do
    case String.split(mime, "/") do
      [_, fmt] -> fmt
      _ -> "png"
    end
  end

  # ── Vision model routing (exclusive to read_media_file) ──────────

  defp call_vision_model(base64_data, mime, prompt, opts) do
    entry =
      cond do
        is_atom(opts[:vision_model]) and not is_nil(opts[:vision_model]) ->
          Eai.Models.get!(opts[:vision_model])

        is_binary(opts[:vision_model]) ->
          base = Eai.Models.default_vision() || raise "no vision model configured in models.exs"
          Keyword.put(base, :model, opts[:vision_model])

        true ->
          Eai.Models.default_vision() ||
            raise "no vision model configured in models.exs; add vision: true to a model entry"
      end

    model = entry[:model]
    api_key = opts[:vision_api_key] || Eai.Models.api_key(entry)
    url = opts[:vision_url] || entry[:url]
    provider = entry[:provider] || :openai_compat

    result =
      case provider do
        :anthropic -> vision_call_anthropic(url, api_key, model, base64_data, mime, prompt)
        :openai_compat -> vision_call_openai(url, api_key, model, base64_data, mime, prompt)
      end

    case result do
      {:ok, text} -> {:ok, text, model}
      err -> err
    end
  end

  defp vision_call_openai(url, api_key, model, base64_data, mime, prompt) do
    body = %{
      model: model,
      max_tokens: 1024,
      messages: [
        %{
          role: "user",
          content: [
            %{type: "image_url", image_url: %{url: "data:#{mime};base64,#{base64_data}"}},
            %{type: "text", text: prompt}
          ]
        }
      ]
    }

    case Req.post(url,
           json: body,
           headers: [authorization: "Bearer #{api_key}", content_type: "application/json"],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => c}} | _]}}} ->
        {:ok, c}

      {:ok, %{status: s, body: b}} ->
        {:error, "vision HTTP #{s}: #{inspect(b)}"}

      {:error, r} ->
        {:error, inspect(r)}
    end
  end

  defp vision_call_anthropic(url, api_key, model, base64_data, mime, prompt) do
    body = %{
      model: model,
      max_tokens: 1024,
      messages: [
        %{
          role: "user",
          content: [
            %{type: "image", source: %{type: "base64", media_type: mime, data: base64_data}},
            %{type: "text", text: prompt}
          ]
        }
      ]
    }

    case Req.post(url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => t} | _]}}} -> {:ok, t}
      {:ok, %{status: s, body: b}} -> {:error, "vision HTTP #{s}: #{inspect(b)}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end
end
