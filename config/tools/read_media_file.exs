defmodule Eai.Tool.ReadMediaFile do
  @behaviour Eai.Tool
  alias Eai.Tool.Helpers

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "read_media_file",
      description: """
      Read an image or video file and return its metadata plus a base64-encoded preview
      (image as-is, video as a frame). Optionally pass analyze_prompt to have a
      vision-capable model (GPT-4o, Claude, LLaVA, etc.) describe or analyse the visual
      content — the model is chosen independently of the current conversation model, so
      you can route vision tasks to the best available multimodal endpoint.

      Returns JSON with keys: ok, type, mime, file_size, metadata, base64, compression,
      and (if analyze_prompt was set) vision_analysis + vision_model.
      """,
      parameters: %{type: "object",
        properties: %{
          file_path:        %{type: "string",  description: "Absolute path to the media file (must be inside workspace)."},
          media_type:       %{type: "string",  enum: ["image", "video", "auto"], description: "Force type detection. Defaults to auto."},
          video_frame_time: %{type: "number",  description: "For video: extract frame at this second. Default 0."},
          max_dimension:    %{type: "integer", description: "Resize longest edge to this px before encoding. Default 1024. Set 0 for original."},
          analyze_prompt:   %{type: "string",  description: "If set, send the extracted image to a vision model with this prompt and return the analysis."},
          vision_model:     %{type: "string",  description: "Vision model to use when analyze_prompt is set. E.g. 'gpt-4o', 'claude-opus-4-6', 'llava'. Defaults to config :vision_model or 'gpt-4o'."},
          vision_api_key:   %{type: "string",  description: "Override API key for the vision model call."},
          vision_url:       %{type: "string",  description: "Override base API URL for the vision model (OpenAI-compatible or Anthropic)."}
        },
        required: ["file_path"]
      }
    }}
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    file_path  = args["file_path"]
    work_root  = Helpers.sandbox_cfg(:work_dir_root)

    if not String.starts_with?(Path.expand(file_path), Path.expand(work_root)) do
      Jason.encode!(%{ok: false, reason: "file path outside workspace"})
    else
      max_dim    = to_string(args["max_dimension"] || 1024)
      frame_time = to_string(args["video_frame_time"] || 0)
      media_type = args["media_type"] || "auto"
      script     = Path.join(:code.priv_dir(:eai), "scripts/media_reader.py")

      case System.cmd("python3", [script, file_path,
             "--max-dim",    max_dim,
             "--frame-time", frame_time,
             "--type",       media_type],
             stderr_to_stdout: false, timeout: 30_000) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"ok" => true} = media} ->
              case args["analyze_prompt"] do
                nil ->
                  Jason.encode!(media)
                prompt ->
                  vision_result = Helpers.call_vision_model(
                    media["base64"], media["mime"], prompt,
                    vision_model:   args["vision_model"],
                    vision_api_key: args["vision_api_key"],
                    vision_url:     args["vision_url"]
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
              end
            {:ok, err_map} -> Jason.encode!(err_map)
            {:error, _} -> Jason.encode!(%{ok: false, reason: "invalid output from media_reader", raw: output})
          end
        {error, code} ->
          Jason.encode!(%{ok: false, reason: "media_reader exited #{code}: #{String.trim(error)}"})
      end
    end
  end
end
