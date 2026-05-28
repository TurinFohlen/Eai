# Eai

**Extreme minimal AI assistant** with persistent PTY and recursive sub-agents.

## Features

- **Persistent PTY** — long-running bash sessions with async task polling
- **Recursive sub-agents** — spawn child agents for parallel work
- **Graph-based memory** — RDF triple store via `priv/scripts/dispatch.py`
- **Sandboxed execution** — isolated PTY pools per agent


## Scripts

| Script | Purpose |
|--------|---------|
| `priv/scripts/dispatch.py` | Triple store engine — `matrix`, `path`, `query`, `deps` |
| `priv/scripts/__init__.py` | Python API bindings |

## License

Apache-2.0
