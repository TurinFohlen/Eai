<<feat/converse-ir adopts AWS Bedrock Converse API format as internal message IR.
<<Old format_message extract_message build_request_body functions deleted from Eai.LLM.Direct.
<<Provider switching now handled by adapter dispatch: adapter_for(:anthropic/:openai_compat/:converse).
<<multimodal_inject type detected in tool loop → constructs :user message with :image blocks.
<<Tool results always wrapped in separate :user message per Anthropic/Converse spec.
<<reasoning_content from OpenAI models preserved in :text block within assistant message.
<<export_context serializes Eai.Message tuples directly via :erlang.term_to_binary.
<<replace_context converts imported messages via adapter from_messages based on format param.
<<Empty assistant messages prevented — always at least [{:text, ""}] to avoid API errors.
<<Anthropic tool_result content collapsed to string when single text block per stricter API validation.
<<:thinking content block type added to IR for Anthropic thinking/redacted_thinking round-trip.
<<Anthropic adapter splits text/image blocks from tool_result blocks into separate user messages.
<<OpenAI adapter converts :thinking blocks to prefixed [thinking] text for compatibility.
<<Converse adapter handles thinking blocks as :thinking tuples.

<<Eai.LLM.Direct extract tools to config/tools/ plugin architecture.
<<Eai.Tool behaviour schema/0 + execute/4.
<<config/tools/ directory 13 self-contained tool files.
<<Eai.LLM.Direct 714-lines slimmed to 224-lines.
<<Eai.Tool.Helpers vision_model sandbox_cfg unescape maybe_debug_script shared utilities.
<<config/tools/ lazy-loaded persistent_term first run/3 call.

<<Eai.Message Converse-based IR unifies internal message format with tuple content blocks.
<<Eai.Adapter behaviour to_request_body from_response from_messages provider abstraction.
<<Eai.Adapter.OpenAI converts IR ↔ OpenAI Chat Completions wire format.
<<Eai.Adapter.Anthropic converts IR ↔ Anthropic Messages API wire format.
<<Eai.Adapter.Converse converts IR ↔ AWS Bedrock Converse API wire format.
<<Eai.LLM.Direct refactored to use Eai.Message IR + adapter dispatch based on provider.
<<Eai.Chat message history now stored as [Eai.Message.t()] Converse IR tuples.
<<Eai.Chat.replace_history supports format parameter converse/openai/anthropic.
<<Eai.Tool.ReadMediaFile inject parameter returns multimodal_inject blocks for conversation injection.
<<Eai.Tool.ReplaceContext format parameter for cross-provider history import.
<<Eai.Utils.sanitize_value handles content-block tuples :text :image :tool_use :tool_result.