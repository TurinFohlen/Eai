# Eai

**Extreme minimal AI assistant** — a pragmatic engineer's companion with a real Linux terminal, recursive sub‑agents, and a graph‑based memory engine. MCP servers and browsers are integrated via recommended CLI tools (mcporter, agent-browser) — no framework bloat.

## Quick Start

```bash
# Install deps
mix deps.get && mix compile
pip3 install -r priv/scripts/requirements.txt

# Recommended external CLI tools
npm install -g mcporter agent-browser && agent-browser install

# Set API key
export OPENAI_API_KEY=sk-...
# (also ANTHROPIC_API_KEY if using Claude)

# Launch
iex -S mix
```

Basic Usage

```elixir
# Interactive multi‑line chat (send with /s, cancel with /c)
Eai.Chat.talk()

# One‑shot question
Eai.Chat.talk(content: "List files", mod: :f)

# Switch model or persona
Eai.Chat.talk(model: :claude_sonnet, prompt: :coder, content: "Refactor this")
Eai.Chat.talk(chat_session: "work", content: "Setup CI")   # isolated session
```

Models & Prompts

Defined in config/models.exs and config/prompts.exs. List what's available:

```elixir
Eai.Models.names()   # => [:deepseek, :gpt4o, :claude_sonnet, …]
Eai.Prompts.list()   # => :momoka, :coder, :analyst
```

Tools

All tools live in config/tools/ and are called autonomously by the agent.

| Tool | Purpose |
|------|---------|
| execute_script | Run bash asynchronously → returns task_id |
| get_task_result | Poll async output |
| call_subagent | Dispatch a sub‑task to an independent agent |
| write_to_session | Send raw input to a PTY (e.g. Ctrl‑C) |
| read_media_file | Extract images/frames; optional vision analysis |
| export_context / replace_context | Save/load conversation history (gzip) |

## External CLI Tools (Recommended)

Eai does NOT bake MCP or browser support into the framework. Instead, the model uses ordinary CLI programs via `execute_script` — pure Unix philosophy. No tool schemas in the system prompt, no context overhead, no prefix-cache breakage.

### McPorter — MCP client

[McPorter](https://github.com/openclaw/mcporter) (⭐4,652) is the de-facto CLI for Model Context Protocol servers.

```bash
npm install -g mcporter

# List configured servers (auto-discovers Cursor/Claude/Codex/VS Code configs)
mcporter list

# List tools on a server (TypeScript-style signatures)
mcporter list filesystem

# Call a tool
mcporter call filesystem.read_file path:/tmp/hello.txt

# Ad-hoc: connect to any MCP endpoint without config
mcporter call --stdio "npx -y @modelcontextprotocol/server-filesystem /tmp" --name fs

# Bridge: expose daemon-managed servers as one MCP endpoint
mcporter serve --stdio
```

Supports stdio, HTTP, SSE transports. Built-in OAuth, daemon keep-alive, record/replay.

### Agent Browser — headless browser

[Agent Browser](https://agentbrowser.dev) provides compact accessibility-tree snapshots with `@eN` refs — ~200-400 tokens instead of raw HTML.

```bash
npm install -g agent-browser && agent-browser install

# Navigate and snapshot
agent-browser open https://example.com
agent-browser snapshot -i          # interactive elements only

# Interact via @refs
agent-browser click @e1
agent-browser fill @e2 "text"

# Extract data
agent-browser get text @e1
agent-browser screenshot page.png
```

## Graph‑based Memory

Agents write RDF‑style triples `<<{subject, predicate, object}.` into files (e.g. TRANSITION.md).
Query them with:

```bash
python priv/scripts/dispatch.py <file_or_dir> path A B
python priv/scripts/dispatch.py <file_or_dir> query A B 5
```

## Configuration

Key settings in config/config.exs:

```elixir
config :eai, :sandbox, work_dir_root: "/home/eai_agents"
config :eai, :poll_cooldown_ms, 5_000   # min polling interval
```

Set EAI_DEBUG_PTY=1 to see raw PTY output.

## Adding a Custom Model

Edit config/models.exs:

```elixir
[
  name: :my_llama,
  model: "llama3",
  url: "http://localhost:11434/v1/chat/completions",
  provider: :openai_compat,
  api_key_env: nil    # no key needed
]
```

## Architecture

```
Eai.Chat → Eai.LLM.Direct (adapter → API) → tool loop → Eai.Sandbox.PTYPool + Eai.Task
                                                                  │
                                          ┌───────────────────────┘
                                          ▼
                                     bash PTY
                                          │
                              ┌───────────┼───────────┐
                              ▼           ▼           ▼
                          mcporter   agent-browser   git, curl, ...
                          (MCP)      (browser)       (anything)
```

External tools are NOT framework code. They are ordinary CLI programs the model invokes naturally through its terminal. Zero coupling, maximum flexibility.

## License

Apache-2.0
