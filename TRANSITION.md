
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
