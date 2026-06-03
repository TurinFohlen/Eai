defmodule Eai.Tool.GetLocalTime do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "get_local_time",
      description: "Returns current UTC time in ISO-8601 format.",
      parameters: %{type: "object", properties: %{}, required: []}
    }}
  end

  @impl true
  def execute(_args, _pty_session_id, _chat_session_id) do
    Jason.encode!(%{utc_time: DateTime.utc_now() |> DateTime.to_iso8601()})
  end
end
