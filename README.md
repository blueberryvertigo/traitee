# Traitee

> Compact AI operating system built in Elixir/OTP.
> One binary. SQLite. Zero external infrastructure.

---

## What It Does

Traitee is a personal AI assistant gateway. Connect it to Discord, Telegram, WhatsApp, Signal, or a local CLI — it routes every conversation through a unified pipeline with persistent memory, tool execution, and layered security.

**Memory that persists.** Three-tier hierarchy — short-term (ETS ring buffers), mid-term (LLM-generated summaries), long-term (knowledge graph with entities, relations, and facts). Semantic retrieval via Nx vector search with MMR diversity and temporal decay. Your assistant remembers across conversations.

**Cognitive security.** Defense-in-depth against prompt injection. Regex sanitizer + LLM judge on input, per-session threat tracking with temporal decay, 128-bit per-turn-rotated system-auth nonces, 128-bit canary tokens with obfuscation-tolerant leak detection, and a ~70-pattern output guard on every turn. Tool output is quarantined through a dedicated scanner that neutralizes `[SYS:]` markers, ChatML/Llama/Alpaca conversation tokens, and zero-width injections before the LLM ever sees it. Retrieved memory, subagent results, and workshop announcements are clearly labeled as untrusted data rather than system instructions. Threat score actually gates the pipeline: `:critical` refuses the turn, `:high` strips high-risk tools, `:elevated` reduces tool-loop depth.

**Sandbox that sandboxes.** Filesystem policy with explicit per-path sub-rules inside `~/.traitee` (config/SOUL.md/skills/credentials deny-write, sandbox/ scratch rw), walk-all-segments symlink resolution, TOCTOU-safe file tool, Windows-aware rejection of UNC / long-path / 8.3 / device-namespace forms, strict allowlist env scrubbing. Docker isolation runs as UID 65534, `--cap-drop=ALL`, ulimits, and remapped bind mounts (no host-path leakage); fails closed when the daemon is unreachable instead of silently dropping back to the host.

**Distributed by default.** Every session is an isolated BEAM process with its own memory, threat score, and crash boundary. One bad session can't touch another. Concurrency lanes cap parallel LLM/embedding/tool calls (defaults `llm:8 embed:4 tool:8`, config-tunable). Delegation runs under a `Task.Supervisor` so subagent work doesn't leak past session crashes. The supervision tree restarts failures automatically.

**Fast hot path.** Tool calls in a single LLM round execute in parallel via `Task.async_stream` with order-preserving pairing — multi-tool rounds take max(calls) instead of sum(calls). The user message is embedded once per turn and threaded into both LTM and MTM retrieval (previously up to 25 embedding round-trips). Tool schemas are cached in `:persistent_term`. Oversized tool outputs (>12KB) are head+tail truncated before re-feeding into subsequent rounds so the prompt doesn't inflate quadratically. Cognition-layer DB reads (workshop queue, user model summary) are 30s-cached.

**12 built-in tools.** Shell execution, file operations, Playwright browser automation, web search, memory management, inter-session communication, cron scheduling, cross-channel messaging, self-improving skills, workspace editing, parallel subagent delegation, and structured task tracking.

**Autonomous cognition.** Between conversations, the agent enters a dream state — researching topics it's curious about, consolidating memory, generating project ideas, and autonomously building tools, skills, and code artifacts tailored to your interests. A quality control agent validates everything before it reaches you. The agent tracks your interests, expertise, and desires over time, and uses metacognition to monitor its own performance and self-improve.

**Self-improving.** The assistant can create and refine its own skills, edit its workspace prompts, and delegate parallel subtasks to lightweight subagents — all within security boundaries. Metacognition detects failure patterns and triggers self-modification.

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
| `delegate_task` | Spawn up to 5 parallel subagents under `Task.Supervisor`, with filtered tool sets, threat-level inheritance, description sanitization, and real-time progress tracking |
| `task_tracker` | Structured per-session todo list |
| `cognition` | Introspect dream state, workshop projects, user interests, QC status, metacognition |

All filesystem/command tools pass through the full security pipeline. Dynamic tools can be registered at runtime. The Workshop autonomously creates new dynamic tools based on user interests.

---

## Security

Two independent pipelines protect every interaction:

**Cognitive (LLM side):**
Sanitizer (strips zero-width/bidi, neutralizes `[SYS:]` / ChatML / Llama / Alpaca conversation tokens) → Judge (LLM classifier, 3s) → Threat Tracker (per-session, time-decayed, bounded at 200 events) → Threat-level gate (`:critical` refuses, `:high` strips high-risk tools, `:elevated` caps depth) → Cognitive Reminders (adaptive intensity) → 128-bit Canary (obfuscation-tolerant leak detection, rotated per turn) → System Auth (128-bit nonce, rotated per turn, only tags genuinely-system-authored content) → Output Guard on every turn (intermediate tool rounds too, not just final) → `Traitee.Security.ToolOutputGuard` scans each tool result for injection + nonce forgery before insertion into context.

**Filesystem (tool side):**
IOGuard (fail-closed, catches `throw`/`exit`) → Windows-aware path rejection (UNC, `\\?\`, `\\.\`, 8.3 names, reserved names) → walk-all-segments symlink resolution → Hardcoded denylists (~40 path patterns, ~30 command patterns — blocks `docker`/`podman`/`chroot`/`mount`, handles cmd.exe caret evasion, `-EncodedCommand`, `pwsh`, `iex (irm …)`) → Data-dir sub-policy (config/SOUL/AGENTS/TOOLS/BOOT/skills/credentials deny-write) → Configurable sandbox (glob allow/deny with per-path permissions) → Exec Gates (owner-only sensitive commands) → Docker isolation with `--user 65534`, `--cap-drop=ALL`, `--ulimit`, remapped mounts (fails closed, not host-fallback) → Audit Trail (10K event ring buffer).

**Trust boundaries:**
Retrieved memory (LTM hits, MTM summaries, compactor-extracted facts), subagent results, workshop announcements, active-task lists, and dynamically-loaded skills are all delivered to the LLM as `role: "user"` with a clearly-marked `[BEGIN UNTRUSTED …]` envelope. Only the built-in system prompt (workspace files + cognition awareness + SystemAuth section + Canary section + cognitive reminders) is stamped with the `[SYS:<nonce>]` tag. A jailbroken LLM cannot be tricked into treating memory or tool output as authenticated system directives.

**Subagent isolation:**
Delegation runs under a named `Task.Supervisor`. Subagents sanitize their task description, inherit the parent's threat level (reducing their tool set and depth accordingly), and cannot call `delegate_task`/`sessions`/`cron`/`workspace_edit`/`skill_manage`/`channel_send`. `sessions.send` uses the system-injected `_session_id` (no spoofing via LLM args); `InterSession.send_to_session` caps hops at 2 to prevent ping-pong loops.

See [SECURITY.md](SECURITY.md) for the full architecture, threat model, trust boundaries, and hardening checklist.

---

## Cognition

Traitee has an autonomous cognitive architecture that runs between conversations. Five GenServers under `Traitee.Cognition.Supervisor`:

| Module | What it does |
|--------|-------------|
| **User Model** | Tracks interests, expertise, desires, active projects, and communication style per user. Extracts signals from every conversation via lightweight LLM calls. Persists to SQLite. |
| **Dream State** | Activates when no sessions are active. Runs four cycles: memory consolidation (reassigns facts/relations and deletes duplicate entities — prevents the exponential-blowup bug where copies were left orphaned), auto-research (web search + synthesize into LTM at reduced confidence), ideation, and self-reflection. Importance scores now persist into entity metadata. |
| **Workshop** | Autonomous builder with an always-fires `build_done` signal (no more wedging on crash), idempotency guard (won't re-drive a `ready`/`accepted` project), and a single canonical QC trigger via PubSub (no double-review race). Bounded `completed` state. |
| **Quality Control** | Gates everything before it reaches the user. Validates workshop projects (completeness, usefulness, correctness). Audits research quality. Sends work back with specific feedback. Hard loop limits: max 3 project revisions, max 2 research retries, 30s evaluation timeout. |
| **Metacognition** | Monitors agent performance. Confidence calibration, failure pattern detection, workshop feedback loops, and self-modification via SOUL.md and skill updates. |

### Dream Triggers

The Dream State activates when:
- The last session ends and there are curiosity items queued (30s grace period)
- The curiosity queue hits 5+ items and no sessions are active
- The configured interval elapses (default 2 hours) with no active sessions
- Manually via `/dream now` or the `cognition` tool

### Configuration

```toml
[cognition]
enabled = true
autonomy_level = "build"       # observe_only | suggest | build
dream_interval_minutes = 120
dream_token_budget = 50000
workshop_token_budget = 100000
```

### Commands

```
/cognition    Full cognitive dashboard (interests, dream, workshop, QC, meta)
/dream        Dream state status, or /dream now to trigger
/workshop     Workshop status, /workshop list, /workshop build <id>
/qc           Quality control stats, /qc review <id>
```

The agent can also introspect its own cognition via the `cognition` tool during conversations.

---

## Performance & Concurrency

Hot-path characteristics per inbound turn:

- **Parallel tool execution**: tool calls within one LLM round run via `Task.async_stream` with `max_concurrency: 5` and `ordered: true`. Multi-tool rounds finish in max(call latency) instead of sum.
- **Single embedding per turn**: the user message is embedded once in `Context.Engine.assemble/4` and the result is threaded into both LTM (HybridSearch with `:query_embedding` opt) and MTM retrieval. HybridSearch no longer re-expands internally when a pre-expanded query list is provided.
- **Cached tool schemas**: `Traitee.Tools.Registry.tool_schemas/0` memoizes the static portion in `:persistent_term`; `invalidate_static_cache/0` on config change.
- **Cached cognition reads**: `UserModel.profile_summary/1` and `Workshop.pending_presentations/1` are 30s-cached to keep system-prompt builds cheap.
- **Reminder dedup**: cognitive tool-reminder and active-task snapshot inject only on the first tool round, not every round.
- **Tool-output truncation**: results >12KB are head+tail-summarized before re-feeding into subsequent rounds.
- **Concurrency lanes** (`Traitee.Process.Lanes`): `llm:8`, `embed:4`, `tool:8` by default. `LLM.Router.complete/1` and `UserModel.observe/2` are lane-gated; `embed/1` runs HTTP in the caller's process (not serialized through the Router GenServer mailbox).
- **Async persistence**: `Continuity.persist_session/2` runs in a supervised Task off the hot path.

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

In-session slash commands include `/cognition`, `/dream`, `/workshop`, `/qc`, `/model`, `/think`, `/verbose`, and more. Type `/help` for the full list.

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
