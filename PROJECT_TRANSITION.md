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

<<feat/pty-supervision replaces PTYPool monolithic GenServer with DynamicSupervisor + per-session GenServer architecture.
<<Eai.Sandbox.PTYPool deleted entirely; public API surface migrated to Eai.PTY module (thin Hub-routing facade).
<<Eai.PTY.Supervisor added as DynamicSupervisor under Eai.Supervisor; owns all PTY.Session child processes.
<<Eai.PTY.Registry added as OTP Registry under Eai.Supervisor; maps pty_session_id → PTY.Session pid via {:via, Registry, {Eai.PTY.Registry, id}}.
<<Eai.PTY.Session added as per-session GenServer holding %{pty: pid, task_id: nil, task_started_at: nil} previously scattered in PTYPool map.
<<PTY.Session restart strategy is :transient — restarts on abnormal exit, not on :normal/:shutdown; init/1 calls ResultCollector.force_complete on orphaned task_id from prior crash.
<<PTY.Session on_data callback sends {:pty_data, data} to self() rather than routing through pool_pid; eliminates cross-process routing for PTY output.
<<PTY.Session on_exit callback sends :pty_exited to self(); handle_info(:pty_exited) calls ResultCollector.force_complete(task_id) then lets process exit — no orphaned collecting entries.
<<PTY.Session terminate/2 calls Hub.run_post_only(__MODULE__, :terminate, [reason, state]) to route lifecycle exit events through hook pipeline.
<<Slow PTY init (pty_init_sleep_ms + pty_ready_sleep_ms Process.sleep) now runs inside PTY.Session init/1 — no longer blocks other sessions.
<<All external PTY operations (exec_async, write_raw, force_reset, list_sessions, clear_task) route through Hub.run → Registry lookup → PTY.Session GenServer.call.
<<Hub.run_post_only/3 added to Eai.Hub — runs post-hook pipeline only, no pre-hook, no execute; result passed to hooks is {:terminated, reason}.
<<Hub.run_post_only block semantic is "abort remaining hook chain", NOT "prevent OTP shutdown"; terminate/2 return value is ignored by OTP regardless.
<<Hub.run_post_only documented: hooks must not GenServer.call the dying PTY.Session (deadlock); use Cache/PubSub/ETS instead.
<<Eai.Hook behaviour post_hooks/4 signature unchanged; hooks distinguish terminal events by pattern-matching {:terminated, reason} in result position.
<<Hook authoring pattern: def post_hooks(_m, _f, _a, {:terminated, reason}), do: cleanup(reason); def post_hooks(m, f, a, result), do: normal(m, f, a, result).
<<interrupt flag key remains pty_session_id-based in ResultCollector; Chat.interrupt!/1 must pass pty_session_id not chat_session_id to set_interrupt_flag — decoupling was already present, now explicit.
<<Task.async + Process.unlink pattern in Eai.Chat replaced with Task.Supervisor.async_nolink(Eai.Naming.task_supervisor(), fn -> ... end) — intent explicit, tasks visible in supervisor tree.
<<Eai.Application supervision order: PubSub → Cache → Registry → PTY.Supervisor → Task.Supervisor → Chat → (API).
<<tools execute_script.exs call site updated from PTYPool.exec_async to Eai.PTY.exec_async (Hub-routed); no other tool-layer changes required.