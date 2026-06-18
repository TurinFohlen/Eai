defmodule Eai.Hook.FixEmptyThinking do
  @moduledoc """
  Fixes assistant messages that have thinking content but no actionable text output
  and no tool calls.

  When an LLM provider returns a response with reasoning/thinking blocks but no text
  content and no tool calls, the resulting Eai.Message is invalid for subsequent requests
  — OpenAI rejects with "Invalid assistant message: content or tool_calls must be set".

  This hook detects such messages in the `llm_post` phase and fills the text content
  with the raw thinking text. This:

    - Prevents the HTTP 400 error on the next request
    - Preserves context continuity (the model sees its own reasoning as text)
    - Avoids base64 noise that pollutes the conversation context
  """

  use Eai.Hook, priority: 25

  @impl true
  def interest(:llm_post, "LLM_REQUEST", _payload), do: true
  def interest(_event, _tool, _payload), do: false

  @impl true
  def verdict(:llm_post, _tool, _payload, {:ok, text, history}) when text == "" do
    case maybe_fix_history(history) do
      {:fixed, new_history, new_text} ->
        {:modify, {:ok, new_text, new_history}}

      :no_fix ->
        :ok
    end
  end

  def verdict(:llm_post, _tool, _payload, _result), do: :ok

  defp maybe_fix_history(history) do
    case List.last(history) do
      %{role: :assistant, content: content} = msg ->
        thinking_blocks = Enum.filter(content, &match?({:thinking, _}, &1))
        text_blocks = Enum.filter(content, &match?({:text, _}, &1))
        has_tool_use = Enum.any?(content, &match?({:tool_use, _}, &1))

        has_thinking = thinking_blocks != []
        has_useful_text = Enum.any?(text_blocks, fn {:text, t} -> t != "" end)

        if has_thinking and not has_useful_text and not has_tool_use do
          thinking_text =
            thinking_blocks
            |> Enum.map_join("\n", fn {:thinking, t} -> t end)

          if thinking_text == "" do
            :no_fix
          else
            text_block = {:text, thinking_text}
            new_content = [text_block | content]
            new_msg = %{msg | content: new_content}

            {front, [_]} = Enum.split(history, -1)
            new_history = front ++ [new_msg]

            {:fixed, new_history, thinking_text}
          end
        else
          :no_fix
        end

      _ ->
        :no_fix
    end
  end
end
