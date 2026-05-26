# Eai

**Extreme minimal AI assistant** with persistent PTY and recursive sub-agents.

## Installation

```elixir
def deps do
  [
    {:eai, "~> 0.1.2"}
  ]
end
```

## Features

- **Persistent PTY** — long-running bash sessions with async task polling
- **Recursive sub-agents** — spawn child agents for parallel work
- **Graph-based memory** — RDF triple store via `priv/scripts/dispatch.py`
- **Sandboxed execution** — isolated PTY pools per agent

## Quick Start

```elixir
alias Eai.Sandbox

{:ok, agent} = Sandbox.spawn("my_agent")
Sandbox.exec(agent, "ls -la")
```

## Scripts

| Script | Purpose |
|--------|---------|
| `priv/scripts/dispatch.py` | Triple store engine — `matrix`, `path`, `query`, `deps` |
| `priv/scripts/__init__.py` | Python API bindings |

## License

Apache-2.0
