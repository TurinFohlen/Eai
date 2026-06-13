# Changelog

All notable changes to this project are documented in this file.

## [0.1.13] — 2026-06-13

### Fixed

- **MCP transport format**: Changed from incorrect keyword list `[layer: ..., command: ...]` to
  correct 2-tuple `{:stdio, command: ...}` format required by Anubis 1.6.x.
  The old format would crash in `Anubis.Client.Supervisor.parse_transport_config/1`.

### Changed

- **MCP config restructured**: Moved from single file `config/mcp_servers.exs` to
  `config/mcp_servers/` directory with one `.exs` file per server. Enables:
  - Cleaner separation of concerns (each server in its own file)
  - Runtime hot-reload without VM restart
  - Easy enable/disable by commenting/uncommenting individual files

- **`Eai.MCP` rewritten**: State is now a struct `%{servers, ids}` instead of raw list.
  Added `stop_server/1` for graceful teardown via `Anubis.Client.Supervisor`.

### Added

- **HTTP API endpoint** (`Eai.API`): OpenAI-compatible REST API, powered by Bandit.
  External tools can use eai as a drop-in OpenAI replacement.
  - `POST /v1/chat/completions` — full OpenAI-format chat completions
  - `GET /v1/models` — list available LLM models
  - `GET /v1/tools` — list all MCP tools
  - `GET /v1/mcp/status` — MCP server health
  - `GET /health` — version + quick status
  - Config: `config :eai, :api, enabled: true, port: 4000`
  - Ideal for chatgpt-on-wechat, n8n, custom bots, or any tool that talks OpenAI API

- **`Eai.MCP.reload!/0`**: Hot-reload all MCP server configs at runtime.
  Re-reads `config/mcp_servers/*.exs`, stops removed servers, starts new ones,
  refreshes tool registry — no VM restart needed. Returns `{:ok, diff}` with
  added/removed/unchanged counts.

- **`Eai.MCP.status/0`**: One-shot status for all MCP servers. Returns a list of
  `%{id, status, tools, transport}` maps — see which servers are online, how many
  tools each exposes, and what transport they use. No more digging through logs.

- **Config validation layer**: Both `start_all` and `reload!` now validate transport
  format before passing to Anubis. Catches missing `:command` for stdio, missing `:url`
  for streamable_http, wrong tuple format, etc. Returns clear error messages instead
  of crashing on pattern match.

- **`config/mcp_servers/npx.exs`**: Filesystem MCP server via `@modelcontextprotocol/server-filesystem`.
  Zero-auth, npx auto-downloads. Good first-run sanity check for the MCP pipeline.

- **`config/mcp_servers/gdrive.exs`**: Google Drive MCP server via `@isaacphi/mcp-gdrive`.
  Requires one-time OAuth setup (steps in file comments).

## [0.1.12] — Previous release

- Initial public version.