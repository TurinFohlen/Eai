# Eai — Bootstrap Guide

> Version 0.1.12 • Extreme minimal AI assistant with persistent PTY and recursive sub-agents

---

## 1. What Is Eai?

Eai is an **Elixir application** that gives an AI model a real, persistent Linux shell. It wraps multiple LLM providers behind a unified adapter layer, manages multi‑session conversation history, and exposes 14 tools the model can call autonomously. The result: an AI engineer that can write bash scripts, poll results, spawn cheap sub‑agents, read images, and maintain long‑lived graph‑based memory.

**One‑liner architecture:**

```
Eai.Chat → Eai.LLM.Direct (adapter → API) → tool loop → Eai.Sandbox.PTYPool + Eai.Task
```

---

## 2. Project Structure (High‑Level Map)

```
eai/
├── mix.exs                     # Project definition, deps, Hex package metadata
├── config/
│   ├── config.exs              # Sandbox, polling, sentinel, telemetry defaults
│   ├── models.exs              # LLM model registry (deepseek, gpt4o, claude_opus, …)
│   ├── prompts.exs             # System prompt registry (momoka, coder, analyst)
│   ├── cache.exs               # Cache backend (Nebulex local adapter)
│   ├── tools/                  # 14 self-contained tool files (.exs) — plugin architecture
│   ├── prompts/                # Individual prompt files per persona
│   ├── chara_cards/            # Character Card V2 JSON files (SillyTavern‑compatible)
│   ├── dev.exs / prod.exs / runtime.exs / test.exs
│   └── models/                 # Per‑model config overrides (optional)
│
├── lib/eai/
│   ├── application.ex          # OTP Application — starts supervisor tree
│   ├── chat.ex                 # Main GenServer: session mgmt, async task dispatch
│   ├── llm/direct.ex           # Core LLM loop: adapter routing, tool exec, poll dedup
│   ├── message.ex              # Internal message IR (Converse‑based content blocks)
│   ├── adapter.ex              # Adapter behaviour (to_request_body / from_response / from_messages)
│   ├── adapter/openai.ex       # IR ↔ OpenAI Chat Completions
│   ├── adapter/anthropic.ex    # IR ↔ Anthropic Messages API
│   ├── adapter/converse.ex     # IR ↔ AWS Bedrock Converse
│   ├── sandbox.ex              # Sandbox behaviour
│   ├── sandbox/pty_pool.ex     # PTY GenServer pool — spawns/kills/resets bash shells
│   ├── sandbox/result_collector.ex
│   ├── task.ex                 # Task result buffer (sentinel‑based), interrupt/timeout flags
│   ├── tool.ex                 # Tool behaviour (schema/0 + execute/4)
│   ├── tool/helpers.ex         # Shared tool utilities (vision, sandbox cfg, unescape)
│   ├── record.ex               # Background persistence → gzip logs
│   ├── models.ex               # Model registry query API
│   ├── prompts.ex              # Prompt registry query API
│   ├── card.ex                 # Character Card V2 loader
│   ├── naming.ex               # Process naming (multi‑instance via instance_id)
│   ├── git.ex                  # Bare shared repo init & path helper
│   ├── help.ex                 # Eai.help() — full public API cheat sheet
│   ├── telemetry_handler.ex    # :telemetry event → structured log
│   └── utils.ex                # Recursive UTF‑8 sanitization (all data exits)
│
├── priv/scripts/
│   ├── dispatch.py             # RDF‑triple graph engine (path/query/matrix/deps)
│   ├── read_record.exs         # Read gzip chat records
│   ├── media_reader.py         # Image/video extraction (frames, base64)
│   ├── eai-tui.sh              # tmux TUI — 3‑pane terminal wrapper
│   ├── eai-input.sh            # TUI input pane helper
│   └── requirements.txt        # Python deps (scipy, numpy, Pillow, etc.)
│
├── TRANSITION.md               # Core axiom grid — global, long‑lived RDF triples
├── PROJECT_TRANSITION.md       # Local expansion — branch‑specific triples
└── CHANGELOG.md                # Version history
```

---

## 3. Core Concepts & Design Decisions

### 3.1 Internal Message IR (Converse‑based)

All conversation history is stored as `[Eai.Message.t()]` — a list of maps with `:role` and `:content` (list of tuples):

```elixir
%{role: :user, content: [{:text, "hello"}]}
%{role: :assistant, content: [
  {:thinking, "Let me think..."},
  {:tool_use, [tool_use_id: "abc", name: "execute_script", input: %{"script" => "ls"}]}
]}
%{role: :user, content: [{:tool_result, [tool_use_id: "abc", content: [{:text, "..."}]]}]}
```

**Why:** Provider‑agnostic. Adapters (`OpenAI`, `Anthropic`, `Converse`) convert to/from wire format. Multimodal injection (`:image` blocks) flows through the same pipeline.

### 3.2 Adapter Architecture

```
IR [Eai.Message.t()]
    │
    ▼
┌─────────────────────────────────────────────┐
│ Eai.Adapter (behaviour)                      │
│   ├── Anthropic  → IR ↔ Anthropic Messages   │
│   ├── OpenAI     → IR ↔ Chat Completions     │
│   └── Converse   → IR ↔ Bedrock Converse     │
└─────────────────────────────────────────────┘
    │
    ▼
Provider HTTP API
```

`Eai.LLM.Direct` uses `adapter_for(provider)` to pick the right adapter at runtime. Models register their provider in `config/models.exs`.

### 3.3 Tool Plugin Architecture

Each tool is a self‑contained `.exs` file in `config/tools/`:

```
config/tools/
├── execute_script.exs        # Bash execution (ACC / SBC modes)
├── get_task_result.exs       # Poll async task output
├── call_subagent.exs         # Spawn cheap sub‑agent (session reuse, prefix caching)
├── get_subagent_result.exs   # Poll sub‑agent result
├── write_to_session.exs      # Raw PTY input (Ctrl‑C, interactive prompts)
├── list_pty_sessions.exs     # List all PTY sessions + current tasks
├── reset_session.exs         # Force‑kill stuck PTY
├── force_complete_task.exs   # Extract partial output from hung tasks
├── read_media_file.exs       # Image/video → base64, optional vision analysis
├── export_context.exs        # Save conversation history → gzip
├── replace_context.exs       # Restore conversation history from gzip
├── list_chat_sessions.exs    # List chat sessions (message count, status)
├── close_chat_session.exs    # Close and free a chat session
├── get_local_time.exs        # UTC timestamp
└── set_config.exs            # Tune poll_cooldown_ms, PTY timing
```

Every tool implements `Eai.Tool` behaviour (`schema/0` + `execute/4`). Tools are lazy‑loaded on first `Direct.run/3` call and cached in `:persistent_term`. The tool dispatch map is built automatically — no registration needed.

### 3.4 Execution Modes: ACC vs SBC

| Mode | Full Name | Returns | Use Case |
|------|-----------|---------|----------|
| **ACC** | Asynchronous Concurrent Call | `task_id` immediately | Long tasks, parallel dispatch |
| **SBC** | Synchronous Blocking Call | Result directly | Fast tasks (<30s), saves 2 roundtrips |

Both `execute_script` and `call_subagent` support SBC via `sbc: true` flag. SBC internally polls `poll_cooldown_ms` (same as manual polling).

### 3.5 PTY Lifecycle & Sentinel Protocol

1. **Spawn:** `Eai.Sandbox.PTYPool` creates a bash PTY per `pty_session_id` in `work_dir_root/<session>/`
2. **Execute:** Tool writes a temp script, runs `bash <script>`, captures output between sentinels
3. **Collect:** `Eai.Task.collect/2` buffers PTY output, strips ANSI escape codes, extracts between `___EAI_START___` / `___EAI_END___`
4. **Reset:** `reset_session` kills the PTY process, which auto‑spawns on next command
5. **Interrupt:** Ctrl‑C injected via `write_to_session("\x03")`

### 3.6 Poll Dedup (Cost Optimization)

LLM conversation history grows rapidly during tool‑calling loops. `Eai.LLM.Direct` strips stale "running" polls — only the **latest** `get_task_result` / `get_subagent_result` pair (assistant tool_use + user tool_result with `status: "running"`) survives. Older "running" pairs are pruned before the next LLM call.

### 3.7 Two‑Layer Grid Memory

| File | Scope | Purpose |
|------|-------|---------|
| `TRANSITION.md` | **Main branch**, global | Core axioms: framework modules, CLI tools, user profile, universal predicates |
| `PROJECT_TRANSITION.md` | **Feature branch**, local | Temporary middleware, feature flags, branch‑specific states |

Triples use free‑form syntax: `<<{subject, predicate, object}.` — one per line.

Query via:
```bash
python priv/scripts/dispatch.py TRANSITION.md path A B     # shortest logical path
python priv/scripts/dispatch.py TRANSITION.md query A B 5   # next valid hops
python priv/scripts/dispatch.py TRANSITION.md deps X        # what X depends on
python priv/scripts/dispatch.py TRANSITION.md matrix        # visualise graph
```

### 3.8 Sub‑Agent Economics

`call_subagent` creates a **fresh agent context** with only system prompt + task message. This is ~50× cheaper per round‑trip than running the same task in the main context. Supports session reuse (`chat_session`) and prefix caching (`pre_context`) for repeated operations.

---

## 4. Data Flow: A Complete Request

```
User: Eai.Chat.talk(content: "Refactor app.ex", mod: :function, model: :claude_opus)
  │
  ▼
Eai.Chat (GenServer)
  │  Wraps user text in Eai.Message (role: :user)
  │  Spawns Task.async → Eai.LLM.Direct.run(messages, pty_session_id, opts)
  │
  ▼
Eai.LLM.Direct
  │  1. Resolves model entry (Eai.Models), prompt text (Eai.Prompts)
  │  2. Loads tool schemas from config/tools/ (lazy, cached in :persistent_term)
  │  3. Builds request via adapter.to_request_body(messages, model, prompt, tools)
  │  4. POSTs to provider URL (Req.post)
  │  5. Parses response via adapter.from_response(resp_body) → Eai.Message
  │
  ├── No tool_use → return {:ok, reply_text, history}
  │
  └── Has tool_use → Tool Loop:
        │
        ├── Dispatch each tool via Eai.Tool behaviour (execute/4)
        ├── Tool may call PTYPool.exec_async → PTY runs bash → Task.collect/2
        ├── Build tool_result user messages
        ├── Prune stale polls (dedup_stale_task_polls / dedup_stale_subagent_polls)
        └── Recurse: Direct.run(updated_messages, ...) → back to LLM
```

---

## 5. Key Modules Cheat Sheet

| Module | Type | Purpose |
|--------|------|---------|
| `Eai.Chat` | GenServer | Multi‑session chat history, async task dispatch |
| `Eai.LLM.Direct` | Module | Tool‑calling loop, adapter dispatch, poll dedup |
| `Eai.Sandbox.PTYPool` | GenServer | PTY lifecycle (spawn, exec, reset, interrupt) |
| `Eai.Task` | Module | Sentinel‑based output collection, interrupt/timeout flags |
| `Eai.Message` | Module | Converse‑based IR constructors & accessors |
| `Eai.Adapter.OpenAI` | Module | IR ↔ OpenAI Chat Completions |
| `Eai.Adapter.Anthropic` | Module | IR ↔ Anthropic Messages API |
| `Eai.Adapter.Converse` | Module | IR ↔ Bedrock Converse |
| `Eai.Models` | Module | Model registry queries |
| `Eai.Prompts` | Module | Prompt registry queries |
| `Eai.Card` | Module | Character Card V2 loader |
| `Eai.Record` | GenServer | Background gzip persistence |
| `Eai.Tool` | Behaviour | Tool contract (schema + execute) |
| `Eai.Tool.Helpers` | Module | Shared utilities for tool implementations |
| `Eai.Utils` | Module | Recursive UTF‑8 sanitization |
| `Eai.Git` | Module | Shared bare repo init & path |
| `Eai.Naming` | Module | Process naming (multi‑instance support) |
| `Eai.TelemetryHandler` | Module | `:telemetry` → structured log |

---

## 6. Configuration Quick Reference

### config/config.exs (core settings)

```elixir
config :eai, :default_model, :deepseek            # default LLM
config :eai, :poll_cooldown_ms, 2_000              # min polling interval
config :eai, :sandbox,
  work_dir_root: "/home/eai_agents",               # PTY working dirs
  sentinel_left:  "___EAI_START___",               # output extraction markers
  sentinel_right: "___EAI_END___",
  pty_cols: 200, pty_rows: 50,
  pty_init_sleep_ms: 200, pty_ready_sleep_ms: 300,
  debug_pty_output: false                          # set EAI_DEBUG_PTY=1 to override
```

### config/models.exs (model entries)

Each model is a keyword list with `:name`, `:model`, `:url`, `:provider` (`:openai_compat` or `:anthropic`), `:api_key_env`, and optional `:vision`, `:reasoning_effort`, `:receive_timeout`.

### config/prompts.exs (system prompts)

Three built‑in prompts: `:momoka` (default engineer persona), `:coder` (minimal, no fluff), `:analyst` (structured reasoning). Extensible via `config/prompts/*.exs`.

---

## 7. Environment Variables

| Variable | Purpose |
|----------|---------|
| `OPENAI_API_KEY` | OpenAI / OpenAI‑compatible providers |
| `DEEPSEEK_API_KEY` | DeepSeek API key |
| `ANTHROPIC_API_KEY` | Anthropic (Claude) API key |
| `EAI_DEBUG_PTY` | Set to `1` to see raw PTY output |
| `EAI_DEBUG_LLM_REQUEST` | Set to `1` to print full LLM request body |
| `EAI_WORK_DIR` | Override sandbox root directory |

---

## 8. Dependencies

| Dep | Purpose |
|-----|---------|
| `req` + `finch` | HTTP client |
| `jason` | JSON encode/decode |
| `expty` | PTY spawning & I/O |
| `nebulex` + `shards` | In‑memory cache (task results, flags) |
| `phoenix_pubsub` | Internal pub/sub (chat updates → Record) |
| `python3` + scipy, numpy | `dispatch.py` — path graph engine |
| `Pillow` (Python) | `media_reader.py` — image/video extraction |

---

## 9. Quick Start

```bash
cd ~/eai
mix deps.get && mix compile
pip3 install -r priv/scripts/requirements.txt

# Set at least one API key
export OPENAI_API_KEY=sk-...
# export DEEPSEEK_API_KEY=sk-...
# export ANTHROPIC_API_KEY=sk-ant-...

# Launch
iex -S mix
```

```elixir
# Interactive chat
Eai.Chat.talk()

# One‑shot
Eai.Chat.talk(content: "List files", mod: :function)

# Switch model / persona
Eai.Chat.talk(content: "Refactor this", model: :claude_opus, prompt: :coder)

# Help
Eai.help()
```

---

## 10. Development Conventions

- **Conventional commits** (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `revert:`)
- **Feature branches** off `main`; merge when stable
- **Triples** written directly to `TRANSITION.md` (global) or `PROJECT_TRANSITION.md` (branch)
- **Tool files** in `config/tools/` — no registration needed; just drop a `.exs` that implements `Eai.Tool`
- **No database** — all state is in‑memory (Cache GenServer) or on‑disk (gzip records, git repo)

---

## 11. Common Pitfalls & Gotchas

| Issue | Resolution |
|-------|------------|
| PTY hangs / unresponsive | `list_pty_sessions()` → `reset_session("id")` |
| LLM request times out | Increase `:receive_timeout` in model config, or use `timeout:` option |
| Non‑UTF‑8 bytes in output | `Eai.Utils.sanitize_value/1` wraps them as `BASE64_DATA:<b64>` |
| Task too slow / too many polls | Raise `poll_cooldown_ms` via `set_config`, use heartbeat subscription pattern |
| Sub‑agent too expensive | Use `pre_context` for prefix caching, reuse `chat_session` across calls |
| SBC hangs | Task may take >30s — switch to ACC (`sbc: false`), poll manually |

---

*Generated from codebase analysis. Last updated: version 0.1.12.*
