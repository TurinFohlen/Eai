<<feat/converse-ir adopts AWS Bedrock Converse API format as internal message IR.
<<Old format_message extract_message build_request_body functions deleted from Eai.LLM.Direct.
<<Provider switching now handled by adapter dispatch: adapter_for(:anthropic/:openai_compat/:converse).
<<multimodal_inject type detected in tool loop → constructs :user message with :image blocks.
<<Tool results always wrapped in separate :user message per Anthropic/Converse spec.
<<reasoning_content from OpenAI models preserved in :text block within assistant message.
<<export_context serializes Eai.Message tuples directly via :erlang.term_to_binary.
<<replace_context converts imported messages via adapter from_messages based on format param.
<<Empty assistant messages prevented — always at least [{:text, ""}] to avoid API errors.
