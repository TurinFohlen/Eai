# Changelog

All notable changes to Eai.

---

## [Unreleased]

### Added

- **tmux TUI** (`priv/scripts/eai-tui.sh` + `eai-input.sh`) — three-pane terminal UI wrapping IEx via PTY. Left: IEx info screen (telemetry / tool output / LLM replies). Right-bottom: input bar (ENTER to send). Ctrl+↑↓←→ focus switching. Zero internal code changes.
- **Poll dedup for `get_subagent_result`** — `dedup_stale_subagent_polls/1` in `direct.ex`, fully independent of `dedup_stale_task_polls/1`. Only the latest `status: "running"` poll pair survives in conversation history.
- **Chara Card V2 system** — `config/chara_cards/*.json`, `Eai.Card` module. Two-layer prompt composition (system + role). Supports tool filtering, pre_context injection, SillyTavern compatibility.
- **`call_subagent` SBC mode** — `sbc: true` blocks until subagent completes, same pattern as `execute_script` SBC. Internal polling via `sbc_wait` reads cache; shared `dispatch_subagent/5` for both SBC and async.
- **SBC mode for `execute_script`** — internal polling loop returns result directly, saves 2 LLM roundtrips.

### Fixed

- **Async error silent swallow** — `Chat.handle_info` now prints `❌` / `💥` on error/crash paths instead of nothing.

### Changed

- **Poll dedup split into independent clusters** — `dedup_stale_task_polls` + `classify_task_poll` vs `dedup_stale_subagent_polls` + `classify_subagent_poll`. Explicit duplication over implicit coupling via parameterised function. (Supersedes `fdb18d0`.)
- **`call_subagent` SBC realigned** — now uses async dispatch + internal polling instead of direct `Eai.Chat.talk` synchronous call. Same pattern as `execute_script`.
- **`blocking` → `sbc` rename** in `call_subagent` for naming consistency.

### Reverted

- `mix eai` CLI (`1449c7f`) — premature `IO.gets`-based implementation. Replaced by tmux TUI approach.

---

## [0.1.11] — 2026-06-04

### Changed

- **ResultCollector → Eai.Task** — task polling extracted to tool layer
- **SBC mode** for `execute_script` — internal poll loop
- **Poll dedup** — only latest `get_task_result` "running" pair kept in history
- **Cost model** moved from system prompt into tool descriptions
- **System prompt** shrunk 14KB → 8KB

---

## [0.1.0] — 2026-05-26

### Added

- Initial Hex package release
- Triple-notation (`<< subject, predicate, object >>`) with `dispatch.py` path calculus
- `agent-browser` toolkit with ARM64 workaround
- Mathematica/Wolfram integration via `math` CLI (`wolframscript` incompatible with PTY)
- PTY session resilience — `list_pty_sessions` / `reset_session`
- Git-based memory via `TRANSITION.md` / `PROJECT_TRANSITION.md`
