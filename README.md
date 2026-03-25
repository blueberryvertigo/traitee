# Traitee

> Compact AI operating system built in Elixir/OTP.
> One binary. SQLite. Zero external infrastructure.

---

## What It Does

Traitee is a personal AI assistant gateway. Connect it to Discord, Telegram, WhatsApp, Signal, or a local CLI — it routes every conversation through a unified pipeline with persistent memory, tool execution, and layered security.

**Memory that persists.** Three-tier hierarchy — short-term (ETS ring buffers), mid-term (LLM-generated summaries), long-term (knowledge graph with entities, relations, and facts). Semantic retrieval via Nx vector search with MMR diversity and temporal decay. Your assistant remembers across conversations.

**Cognitive security.** 16-module defense-in-depth system. Regex sanitizer + LLM judge on input, per-session threat tracking with temporal decay, adaptive identity reinforcement, system message authentication nonces, canary tokens for leak detection, and a ~70-pattern output guard. Filesystem protection with hardcoded denylists, configurable sandbox, exec gates, optional Docker isolation, and full audit trail. The assistant protects itself from prompt injection — and protects your host from the assistant.

**Distributed by default.** Every session is an isolated BEAM process with its own memory, threat score, and crash boundary. One bad session can't touch another. Concurrency lanes limit parallel tool/LLM/embedding calls. The supervision tree restarts failures automatically.

**12 built-in tools.** Shell execution, file operations, Playwright browser automation, web search, memory management, inter-session communication, cron scheduling, cross-channel messaging, self-improving skills, workspace editing, parallel subagent delegation, and structured task tracking.

**Self-improving.** The assistant can create and refine its own skills, edit its workspace prompts, and delegate parallel subtasks to lightweight subagents — all within security boundaries.

**OpenAI-compatible API.** Drop `http://localhost:4000/v1/` into any tool that speaks OpenAI's API (Cursor, VS Code extensions, scripts) and get hierarchical memory for free.

---

## Quick Start

### Install

```bash
# macOS
brew install elixir

# Windows (PowerShell as admin)
winget install ErlangSolutions.Erlang.OTP
winget install ElixirLang.Elixir

# Linux (Ubuntu/Debian)
sudo apt install erlang elixir
```

Requires **Elixir >= 1.17** / **OTP >= 27**.

### Setup

```bash
git clone https://github.com/blueberryvertigo/traitee.git
cd traitee
mix setup
```

### Configure an LLM

Set at least one API key:

```bash
# Pick one (or more)
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
export XAI_API_KEY=xai-...

# Or use a local model — no key needed
ollama pull llama3
```

### Run

```bash
mix traitee.onboard    # Interactive setup wizard (recommended first run)
mix traitee.chat       # Start chatting in the terminal
mix traitee.serve      # Full gateway: all channels + API + WebSocket
```

---

## Channels

| Channel | Transport | Notes |
|---------|-----------|-------|
| Discord | Nostrum (native gateway) | Guilds + DMs, streaming edits, message splitting |
| Telegram | Bot API long-polling | Groups + DMs, streaming edits, exponential backoff |
| WhatsApp | Cloud API v21.0 + webhooks | DMs, typing indicators |
| Signal | signal-cli subprocess | DMs, auto-restart on crash |
| WebChat | Phoenix WebSocket | Real-time streaming via PubSub |
| CLI | Mix task REPL | Streaming, all slash commands |

Channels start conditionally based on config. Typing indicators run on linked processes.

---

## LLM Providers

| Provider | Models | Features |
|----------|--------|----------|
| OpenAI | GPT-4o, GPT-4o-mini, GPT-4.1, o3-mini | Streaming, tools, embeddings |
| Anthropic | Claude Opus 4.6, Sonnet 4, Opus 4, Haiku 3.5 | Streaming, tools, adaptive thinking |
| xAI | Grok-4-1-fast, Grok-4-0709 | Streaming, tools, 2M context window |
| Ollama | Any local model | Streaming, embeddings, zero cost |

Automatic failover between primary and fallback providers. Usage tracking per session.

---

## Tools

| Tool | What it does |
|------|-------------|
| `bash` | Cross-platform shell (30s timeout, sandboxed, optional Docker) |
| `file` | Read/write/append/list (50K read cap, per-path permissions) |
| `browser` | Playwright automation — 14 actions including navigate, click, screenshot, evaluate JS |
| `web_search` | SearXNG-backed queries |
| `memory` | Store and recall facts in the knowledge graph |
| `sessions` | List, inspect, and message between conversations |
| `cron` | Schedule one-shot, interval, or cron-expression jobs |
| `channel_send` | Send messages to any configured channel |
| `skill_manage` | Create/patch/delete skills (agent's procedural memory) |
| `workspace_edit` | Read/patch workspace prompts (SOUL.md, AGENTS.md, TOOLS.md) |
| `delegate_task` | Spawn up to 5 parallel subagents with filtered tool sets |
| `task_tracker` | Structured per-session todo list |

All filesystem/command tools pass through the full security pipeline. Dynamic tools can be registered at runtime.

---

## Security

Two independent pipelines protect every interaction:

**Cognitive (LLM side):** Sanitizer (regex) → Judge (LLM classifier, 3s) → Threat Tracker (per-session, time-decayed) → Cognitive Reminders (adaptive intensity) → Canary Tokens (leak detection) → System Auth (message authentication nonces) → Output Guard (~70 patterns, 14 categories).

**Filesystem (tool side):** I/O Guards (fail-closed) → Hardcoded Denylists (~32 path + ~20 command patterns, always on) → Configurable Sandbox (allow/deny with glob patterns) → Exec Gates (approval for risky commands) → Optional Docker isolation → Audit Trail (10K event ring buffer).

See [SECURITY.md](SECURITY.md) for the full architecture, threat model, trust boundaries, and hardening checklist.

---

## Configuration

Create `~/.traitee/config.toml` (or use `mix traitee.onboard`):

```toml
[agent]
model = "anthropic/claude-sonnet-4"
fallback_model = "openai/gpt-4o"

[security]
enabled = true

[security.filesystem]
sandbox_mode = true
default_policy = "deny"

[[security.filesystem.allow]]
pattern = "/home/me/projects/**"
permissions = ["read", "write"]

[channels.discord]
enabled = true
token = "env:DISCORD_BOT_TOKEN"
```

Config hot-reloads every 5 seconds — no restart needed. Secrets use `env:VAR_NAME` indirection.

---

## CLI Commands

```
mix traitee.onboard     Interactive setup wizard
mix traitee.chat        Terminal REPL (--session ID)
mix traitee.serve       Start the full gateway (--port N)
mix traitee.send "msg"  One-shot message (--channel, --to)
mix traitee.doctor      System diagnostics
mix traitee.memory      Memory stats, search, entities, reindex
mix traitee.security    Filesystem security audit (--audit, --gaps, --test)
mix traitee.cron        Scheduled job management
mix traitee.daemon      OS service install/start/stop/status
mix traitee.pairing     Sender approval management
```

---

## Docker

```bash
docker build -t traitee .
docker compose up -d
```

Multi-stage build (`elixir:1.17-otp-27-slim` → `debian:bookworm-slim`). Runs as non-root. Health check on `/api/health`.

---

## Development

```bash
mix test                 # Run tests (auto-migrates)
mix lint                 # Format + Credo strict
mix quality.ci           # Format + Credo + Dialyzer
mix traitee.doctor       # Verify everything works
```

---

## License

MIT
