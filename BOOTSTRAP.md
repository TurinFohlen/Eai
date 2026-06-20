# Eai - Bootstrap Guide

> Version 0.2.0 • Extreme minimal AI assistant with persistent PTY and recursive sub-agents. MCP servers are accessed via external CLI tools (mcporter, agent-browser), not baked into the framework.

---

## 1. What Is Eai?

Eai is an **Elixir application** that gives an AI model a real, persistent Linux shell. It wraps multiple LLM providers behind a unified adapter layer, manages multi-session conversation history, and exposes 18 tools the model can call autonomously. The result: an AI engineer that can write bash scripts, poll results, spawn cheap sub-agents, read images, and maintain long-lived graph-based memory.

**One-liner architecture:**

```
Eai.Chat → Eai.LLM.Direct (adapter → API) → tool loop → Eai.PTY → Eai.PTY.Session (per-session GenServer) + Eai.ResultCollector
```

---

## 2. Project Structure (High-Level Map)

```
eai/
├── mix.exs                     # Project definition, deps, Hex package metadata
├── config/
│   ├── config.exs              # Sandbox, polling, sentinel, telemetry defaults
│   ├── models.exs              # LLM model registry (deepseek, gpt4o, claude_opus, …)
│   ├── prompts.exs             # System prompt registry (momoka, coder, analyst)
│   ├── tools/                  # 18 self-contained tool files (.exs) - plugin architecture
│   ├── prompts/                # Individual prompt files per persona
│   ├── hooks/                  # Hook .exs files (numeric prefix = load order)
│   ├── chara_cards/            # Character Card V2 JSON files (SillyTavern-compatible)
│   ├── dev.exs / prod.exs / runtime.exs / test.exs
│   └── models/                 # Per-model config overrides (optional)
│
├── lib/eai/
│   ├── application.ex          # OTP Application - starts supervisor tree
│   ├── chat.ex                 # Main GenServer: session mgmt, async task dispatch
│   ├── llm/direct.ex           # Core LLM loop: adapter routing, tool exec, poll dedup
│   ├── message.ex              # Internal message IR (Converse-based content blocks)
│   ├── adapter.ex              # Adapter behaviour (to_request_body / from_response / from_messages)
│   ├── adapter/openai.ex       # IR ↔ OpenAI Chat Completions
│   ├── adapter/anthropic.ex    # IR ↔ Anthropic Messages API
│   ├── adapter/converse.ex     # IR ↔ AWS Bedrock Converse (SigV4 signed)
│   ├── sandbox.ex              # Sandbox behaviour (legacy — replaced by Eai.PTY)
│   ├── pty.ex                  # PTY Public API — routes all calls through Hub.run/3
│   ├── pty/registry.ex          # OTP Registry: pty_session_id → PTY.Session PID
│   ├── pty/session.ex           # Per-session GenServer owning one PTY
│   ├── pty/supervisor.ex        # DynamicSupervisor — spawns :transient children
│   ├── sandbox/result_collector.ex  # Sentinel-based output buffering
│   ├── hooks/hook.ex           # Eai.Hook behaviour + __using__ macro
│   ├── hooks/hub.ex            # Eai.Hub.run/3 central dispatch + reload!/0
│   ├── hooks/pipeline.ex       # pre/post/llm_pre/llm_post hook pipelines
│   ├── hooks/loader.ex         # Read-only hook introspection
│   ├── hooks/reloader.ex       # Hot-reload hooks from config/hooks/*.exs
│   ├── tool.ex                 # Tool behaviour (schema/0 + execute/4)
│   ├── tool/helpers.ex         # Shared tool utilities (vision, sandbox cfg, unescape)
│   ├── record.ex               # Background persistence → gzip logs
│   ├── models.ex               # Model registry query API
│   ├── prompts.ex              # Prompt registry query API
│   ├── card.ex                 # Character Card V2 loader
│   ├── naming.ex               # Process naming (multi-instance via instance_id)
│   ├── git.ex                  # Bare shared repo init & path helper
│   ├── help.ex                 # Eai.help() - full public API cheat sheet
│   ├── telemetry_handler.ex    # :telemetry event → structured log
│   └── utils.ex                # Recursive UTF-8 sanitization (all data exits)
│
├── priv/scripts/
│   ├── dispatch.py             # RDF-triple graph engine (path/query/matrix/deps)
│   ├── read_record.exs         # Read gzip chat records
│   ├── media_reader.py         # Image/video extraction (frames, base64)
│   ├── eai-tui.sh              # tmux TUI - 3-pane terminal wrapper
│   ├── eai-input.sh            # TUI input pane helper
│   └── requirements.txt        # Python deps (scipy, numpy, Pillow, etc.)
│
├── TRANSITION.md               # Core axiom grid - global, long-lived RDF triples
├── PROJECT_TRANSITION.md       # Local expansion - branch-specific triples
└── CHANGELOG.md                # Version history
```

---

## 3. Core Concepts & Design Decisions

### 3.1 Internal Message IR (Converse-based)

All conversation history is stored as `[Eai.Message.t()]` - a list of maps with `:role` and `:content` (list of tuples):

```elixir
%{role: :user, content: [{:text, "hello"}]}
%{role: :assistant, content: [
  {:thinking, "Let me think..."},
  {:tool_use, [tool_use_id: "abc", name: "execute_script", input: %{"script" => "ls"}]}
]}
%{role: :user, content: [{:tool_result, [tool_use_id: "abc", content: [{:text, "..."}]}]}
```

**Why:** Provider-agnostic. Adapters (`OpenAI`, `Anthropic`, `Converse`) convert to/from wire format. Multimodal injection (`:image` blocks) flows through the same pipeline.

### 3.2 Adapter Architecture

```
IR [Eai.Message.t()]
    │
    ▼
┌──────────────────────────────────────┐
│ Eai.Adapter (behaviour)              │
│   ├── Anthropic  → IR ↔ Anthropic Messages   │
│   ├── OpenAI     → IR ↔ Chat Completions     │
│   └── Converse   → IR ↔ Bedrock Converse (SigV4) │
└──────────────────────────────────────┘
    │
    ▼
Provider HTTP API
```

`Eai.LLM.Direct` uses `adapter_for(provider)` to pick the right adapter at runtime. Models register their provider in `config/models.exs`.

### 3.3 Tool Plugin Architecture

Each tool is a self-contained `.exs` file in `config/tools/`:

```
config/tools/
├── execute_script.exs        # Bash execution (ACC / SBC modes)
├── get_task_result.exs       # Poll async task output
├── call_subagent.exs         # Spawn cheap sub-agent (session reuse, prefix caching)
├── get_subagent_result.exs   # Poll sub-agent result
├── write_to_session.exs      # Raw PTY input (Ctrl-C, interactive prompts)
├── list_pty_sessions.exs     # List all PTY sessions + current tasks
├── reset_session.exs         # Force-kill stuck PTY
├── force_complete_task.exs   # Extract partial output from hung tasks
├── read_media_file.exs       # Image/video → base64, optional vision analysis
├── export_chat_session_context.exs  # Save conversation history → gzip
├── replace_chat_session_context.exs # Restore conversation history from gzip
├── export_global_context.exs  # Save entire runtime state → gzip
├── replace_global_context.exs # Restore entire runtime state from gzip
├── list_chat_sessions.exs    # List chat sessions (message count, status)
├── get_local_time.exs        # UTC timestamp
├── set_config.exs            # Modify app env / persistent_term at runtime
├── hub_reload.exs            # Hot-reload hooks
└── list_chara_cards.exs      # List available character cards
```

Every tool implements `Eai.Tool` behaviour (`schema/0` + `execute/4`). Tools are lazy-loaded on first `Direct.run/3` call and cached in `:persistent_term`. The tool dispatch map is built automatically - no registration needed.

### 3.4 Execution Modes: ACC vs SBC

| Mode | Full Name | Returns | Use Case |
|------|-----------|---------|----------|
| **ACC** | Asynchronous Concurrent Call | `task_id` immediately | Long tasks, parallel dispatch |
| **SBC** | Synchronous Blocking Call | Result directly | Fast tasks (<30s), saves 2 roundtrips |

Both `execute_script` and `call_subagent` support SBC via `sbc: true` flag. SBC internally polls `poll_cooldown_ms` (same as manual polling).

### 3.5 PTY Lifecycle & Sentinel Protocol

The PTY subsystem was refactored (v0.2.0) from a monolithic GenServer pool into four specialized modules:

| Module | Role |
|--------|------|
| `Eai.PTY` | Public API — all calls route through `Eai.Hub.run/3` for hook interception |
| `Eai.PTY.Registry` | OTP Registry — maps `pty_session_id` → `PTY.Session` PID |
| `Eai.PTY.Session` | Per-session GenServer — owns one PTY, handles exec/interrupt/reset/clear |
| `Eai.PTY.Supervisor` | DynamicSupervisor — spawns `:transient` children, restarts on abnormal exit |

**Lifecycle (write path):**

1. **Lookup/Create:** `Eai.PTY.exec_async/3` → `get_or_create/1` → Registry lookup → miss → `Supervisor.start_session/1` → `Session.start_link/1`
2. **Session init:** `PTY.Session.init/1` → `mkdir work_dir`, symlink `priv/` + mounts, `ExPTY.spawn(bash)`, flush init noise, telemetry
3. **Execute:** `Hub.run(Session, :exec, [pid, task_id, cmd])` → wraps cmd in base64-encoded sentinels → `ExPTY.write(pty, line)`
4. **Collect:** PTY output → `send(self(), {:pty_data, data})` → `ResultCollector.collect/2` — buffers between `___EAI_START___` / `___EAI_END___`, strips ANSI
5. **Interrupt:** `write_to_session` → `Hub.run(Session, :write_raw, [pid, input])` — injects `\x03` (Ctrl+C) + right sentinel echo
6. **Reset:** `reset_session` → `Hub.run(Session, :force_reset, [pid])` → kills PTY process → calls `spawn_pty/1` to respawn immediately
7. **Crash recovery:** PTY process exits → `send(self(), :pty_exited)` → `force_complete` in-flight task → `{:stop, :pty_exited, state}` → `:transient` restart by Supervisor

### 3.6 Sub-Agent Economics

`call_subagent` creates a **fresh agent context** with only system prompt + task message. This is ~50× cheaper per round-trip than running the same task in the main context. Supports session reuse (`chat_session`) and prefix caching (`pre_context`) for repeated operations.

### 3.7 Hook Framework

Every tool call and LLM HTTP request flows through a central dispatch (`Eai.Hub.run/3`):
`config/hooks/*.exs` → Code.compile_file → Pipeline.register/1 → :persistent_term → Pipeline.pre_hooks / post_hooks

| Event | Scope | When |
|-------|-------|------|
| `:pre` / `:post` | Tool | Before/after tool execution |
| `:llm_pre` / `:llm_post` | LLM | Before/after each HTTP request |

**Built-in hooks:**

| File | Priority | Purpose |
|------|----------|---------|
| `01_example.exs` | 10 | Blocks dangerous shell patterns |
| `02_session_log.exs` | 20 | Fires telemetry for every tool/LLM event |
| `03_auto_snapshot.exs` | 5 | Two-tier ETS snapshot + automatic rollback on LLM errors |
| `04_fix_empty_thinking.exs` | 25 | Fills empty assistant text with thinking content when LLM returns reasoning but no output |

**Management:**

```bash
Eai.Hub.reload!()              # Hot-reload all hooks
Eai.Hub.Loader.print_hooks()   # List current hooks with priorities
:persistent_term.erase(:eai_hooks); Eai.Hub.reload!()  # Force full reload
```

### 3.8 HTTP API (OpenAI-compatible)

Eai exposes an OpenAI-compatible REST API on port 4000 (configurable). This enables any OpenAI-compatible client to talk to Eai's LLM backends.

Quick start:

```bash
# List models
curl http://localhost:4000/v1/models

# Chat completion
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek","messages":[{"role":"user","content":"hello"}]}'

# List tools
curl http://localhost:4000/v1/tools

# Health check
curl http://localhost:4000/health
```

Configuration:

```elixir
config :eai, :api,
  enabled: true,    # set false to disable
  port: 4000,
  host: "0.0.0.0"
```

**Connecting chatgpt-on-wechat:** set `openai_api_base` to `http://<eai-host>:4000/v1` in CoW's config. Done - WeChat/飞书/钉钉 all go through this one endpoint.

### 3.9 External Tooling (Unix Philosophy)

Rather than baking external integrations into the Elixir framework (which bloats system prompts and breaks prefix caching), Eai uses **external CLI tools** called via `execute_script`. The model interacts with them like any other bash command — no schema pollution, no context overhead.

#### McPorter — MCP client CLI

[McPorter](https://github.com/openclaw/mcporter) (⭐4,652) is the de-facto MCP CLI. Install globally:

```bash
npm install -g mcporter
```

The model uses it like this:

```bash
# Discover tools on an MCP server
mcporter list filesystem

# Call a tool
mcporter call filesystem.read_file path:/tmp/hello.txt

# Ad-hoc: connect to any MCP endpoint without config
mcporter call --stdio "npx -y @modelcontextprotocol/server-filesystem /tmp" --name fs

# Bridge mode: expose daemon-managed servers as one MCP endpoint
mcporter serve --stdio
```

McPorter auto-discovers MCP configs from Cursor/Claude/Codex/VS Code, handles OAuth, and supports stdio/HTTP/SSE transports. **Zero framework integration needed.**

#### Agent Browser — headless browser CLI

[Agent Browser](https://agentbrowser.dev) provides compact page snapshots with `@eN` refs (~200-400 tokens instead of raw HTML):

```bash
agent-browser open https://example.com
agent-browser snapshot -i     # interactive elements only
agent-browser click @e3
agent-browser get text @e1
```

#### Design Principle

The pattern is the same for any external integration: **CLI → stdout/JSON → model reads → model acts.** No tools registered in Eai, nothing in the system prompt. Pure Unix — one tool, one job, pipes and JSON.

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
  │  4a. [LLM pre-hooks] Pipeline.llm_pre_hooks — hook modules intercept/modify request
  │  4b. POSTs to provider URL (Req.post)
  │  4c. [LLM post-hooks] Pipeline.llm_post_hooks — hook modules observe/modify response
  │  5. Parses response via adapter.from_response(resp_body) → Eai.Message
  │
  ├── No tool_use → return {:ok, reply_text, history}
  │
  └── Has tool_use → Tool Loop:
        │
        ├── [Tool pre-hooks] Eai.Hub.run → Pipeline.pre_hooks — block/modify args
        ├── Dispatch each tool via Eai.Tool behaviour (execute/4)
        ├── [Tool post-hooks] Pipeline.post_hooks — block/modify results
        ├── Tool may call Eai.PTY.exec_async → Hub.run → PTY.Session.exec → PTY runs bash → ResultCollector.collect/2
        ├── Build tool_result user messages
        ├── Prune stale polls (dedup_stale_task_polls / dedup_stale_subagent_polls)
        └── Recurse: Direct.run(updated_messages, ...) → back to LLM
```

---

## 5. Key Modules Cheat Sheet

| Module | Type | Purpose |
|--------|------|---------|
| `Eai.API` | Module | HTTP API entry point (Bandit) |
| `Eai.API.Router` | Plug.Router | OpenAI-compatible REST endpoints |
| `Eai.Chat` | GenServer | Multi‑session chat history, async task dispatch |
| `Eai.LLM.Direct` | Module | Tool-calling loop, adapter dispatch, poll dedup |
| `Eai.Hook` | Behaviour | Hook contract (interest + verdict callbacks) |
| `Eai.Hub` | Module | Central dispatch bus for tool + LLM call interception |
| `Eai.Hub.Pipeline` | Module | Pre/post hook execution with priority ordering |
| `Eai.Hub.Loader` | Module | Read-only hook introspection (list_files, print_hooks) |
| `Eai.Hub.Reloader` | Module | Hot-reload hooks from config/hooks/*.exs |
| `Eai.PTY` | Module | Public PTY API — all calls route through Hub.run/3 for hook interception |
| `Eai.PTY.Registry` | Registry | pty_session_id → Session PID lookup via Naming.pty_session/1 |
| `Eai.PTY.Session` | GenServer | Per-session PTY owner (exec, interrupt, reset, clear) |
| `Eai.PTY.Supervisor` | DynamicSupervisor | Spawns/restarts PTY.Session with :transient strategy |
| `Eai.ResultCollector` | Module | Sentinel-based output collection, interrupt/timeout flags |
| `Eai.Message` | Module | Converse-based IR constructors & accessors |
| `Eai.Adapter.OpenAI` | Module | IR ↔ OpenAI Chat Completions |
| `Eai.Adapter.Anthropic` | Module | IR ↔ Anthropic Messages API |
| `Eai.Adapter.Converse` | Module | IR ↔ Bedrock Converse (SigV4) |
| `Eai.Models` | Module | Model registry queries |
| `Eai.Prompts` | Module | Prompt registry queries |
| `Eai.Card` | Module | Character Card V2 loader |
| `Eai.Record` | GenServer | Background gzip persistence |
| `Eai.Tool` | Behaviour | Tool contract (schema + execute) |
| `Eai.Tool.Helpers` | Module | Shared utilities for tool implementations |
| `Eai.Utils` | Module | Recursive UTF-8 sanitization |
| `Eai.Git` | Module | Shared bare repo init & path |
| `Eai.Naming` | Module | Process naming (multi-instance support) |
| `Eai.TelemetryHandler` | Module | `:telemetry` → structured log |

---

## 6. Configuration Quick Reference

### config/config.exs (core settings)

```elixir
config :eai, :default_model, :deepseek            # default LLM
config :eai, :api,
  enabled: true,
  port: 4002,             # or :auto for random port in 1024–49151
  host: "0.0.0.0"

config :eai, :poll_cooldown_ms, 2_000              # min polling interval
config :eai, :sandbox,
  work_dir_root: "/home/eai_agents",               # PTY working dirs
  sentinel_left:  "___EAI_START___",               # output extraction markers
  sentinel_right: "___EAI_END___",
  priv_src: "priv"                                  # priv/ mount source
```

### Environment Variables

```
DEEPSEEK_API_KEY    — DeepSeek API key
OPENAI_API_KEY      — OpenAI API key
ANTHROPIC_API_KEY   — Anthropic API key
EAI_WORK_DIR        — Override PTY work dir root
EAI_DEBUG_PTY       — Set to "1" for raw PTY output
EAI_DEBUG_LLM_REQUEST — Set to "1" to dump LLM request body
```

---

## 7. Telemetry Events

All `:telemetry.execute/3` calls land on a single handler: `Eai.TelemetryHandler.handle_event/4`.

| Event | Where | When |
|-------|-------|------|
| `[:eai, :session, :spawn]` | `Eai.PTY.Session.spawn_pty/1` | New PTY session spawned |
| `[:eai, :session, :reset]` | `Eai.PTY.Session` | Force-reset on session |
| `[:eai, :task, :start]` | `Eai.LLM.Direct` | Task submitted |
| `[:eai, :task, :chunk]` | `Eai.PTY.Session` | PTY chunk received |
| `[:eai, :task, :complete]` | `Eai.PTY.Session` | Task complete |
| `[:eai, :task, :timeout]` | `Eai.Task` | Task timed out |
| `[:eai, :llm, :request, :start \| :stop]` | `Eai.LLM.Direct` | LLM roundtrip timing (`:stop` carries `status: :ok \| :error`, no failure detail) |
| `[:eai, :tool, :pre \| :post \| :blocked]` | `Eai.LLM.Direct` | Tool call lifecycle (Direct side); `:blocked` = hook veto, not a failure |
| `[:eai, :tool, :hub_pre \| :hub_post \| :hub_blocked]` | `Eai.Hub` | Hook dispatch lifecycle (Hub side) |
| `[:eai, :error, :llm]` | `Eai.LLM.Direct` | LLM request failed. `kind: :http` → `status` (int), `body` (raw term); `kind: :transport` → `reason` (raw term, e.g. `Req`/`Mint` error). Always includes `chat_session_id`, `pty_session_id`, `duration_ms`. Fields are raw terms, never pre-stringified — match directly, no regex needed. |
| `[:eai, :error, :tool]` | `Eai.LLM.Direct` | Tool execution raised an exception (caught in `execute_single_tool_call/4`). `kind: :exception`, `mod` (the dispatched tool module, resolved dynamically from the same `config/tools/*.exs` registry used for dispatch — works for any user-added tool, nothing hardcoded per tool), `error: %{type:, message:}`, `stacktrace:`. Does **not** fire on hook `:block` (see `:tool, :blocked` above) — only on raised exceptions. |
| `[:eai, :hook, :auto_snapshot, :saved \| :rolled_back \| :cleared]` | `Eai.Hook.AutoSnapshot` | Snapshot lifecycle |
| `[:eai, :adapter, :anthropic, :*]` | `Eai.Adapter.Anthropic` | `to_request_body` / `from_response` / `from_messages` |
| `[:eai, :adapter, :converse, :*]` | `Eai.Adapter.Converse` | (same three) |
| `[:eai, :adapter, :openai, :*]` | `Eai.Adapter.OpenAI` | (same three) |

**Error namespace:** all failure-detail events (as opposed to pure timing/lifecycle events) live under `[:eai, :error, *]`. A hook/telemetry author who only cares about failures can `:telemetry.attach_many/4` against this one prefix instead of tracking failure-shaped payloads scattered across `:llm, :request, :stop` and `:tool, :post`. Session-lifecycle events (`Eai.Chat`) are intentionally **not** routed through `Eai.Hub` — they have no executable body to intercept (no pre/post/block semantics make sense for "a session was created"), so they remain plain `:telemetry.execute` calls local to `chat.ex`. `Eai.Hub` is the dispatch point only for events with an actual hookable verdict (tool calls, LLM requests); pure-observation events do not need to round-trip through it.


---

## 8. Common Pitfalls & Gotchas

| Issue | Resolution |
|-------|------------|
| PTY hangs / unresponsive | `list_pty_sessions()` → `reset_session("id")` |
| LLM request times out | Increase `:receive_timeout` in model config, or use `timeout:` option |
| Non-UTF-8 bytes in output | `Eai.Utils.sanitize_value/1` wraps them as `BASE64_DATA:<b64>` |
| Task too slow / too many polls | Raise `poll_cooldown_ms` via `set_config`, use heartbeat subscription pattern |
| Sub-agent too expensive | Use `pre_context` for prefix caching, reuse `chat_session` across calls |
| SBC hangs | Task may take >30s - switch to ACC (`sbc: false`), poll manually |
| LLM returns thinking but no output | Hook `04_fix_empty_thinking.exs` auto-fills text from thinking content |
| OpenAI 400 "content or tool_calls must be set" | Caused by empty assistant message; `04_fix_empty_thinking` prevents this |
| Node/npm OpenSSL errors | `export LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu` for system libcrypto |

---

## 9. Quick Start

```bash
# Clone & setup
git clone https://github.com/TurinFohlen/eai.git
cd eai
mix deps.get

# Set at least one API key
export DEEPSEEK_API_KEY=sk-...

# Launch
iex -S mix
```

```elixir
# Interactive chat
Eai.Chat.talk()

# One-shot
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
- **Tool files** in `config/tools/` - no registration needed; just drop a `.exs` that implements `Eai.Tool`
- **No database** - all state is in-memory (Cache GenServer) or on-disk (gzip records, git repo)
- **External integrations via CLI** — no framework code for MCP/browsers/etc. Use `execute_script` + CLI tools
