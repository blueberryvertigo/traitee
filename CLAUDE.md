# CLAUDE.md — Traitee

> Compact AI operating system built in Elixir/OTP. Personal AI assistant gateway
> with hierarchical memory, cognitive security, and multi-channel support.

## Quick Reference

```bash
mix setup              # Install deps + create DB + migrate
mix test               # Run unit tests (auto-migrates)
mix lint               # Format check + Credo strict
mix quality.ci         # Format + Credo + Dialyzer
mix format             # Auto-format code
mix credo --strict     # Static analysis
mix dialyzer           # Type checking (slow first run — builds PLTs)
```

## Tech Stack

- **Elixir ~> 1.17** on **OTP 27** (BEAM VM)
- **Phoenix ~> 1.7** with **Bandit** HTTP server (port 4000)
- **SQLite** via `ecto_sqlite3` — single file at `~/.traitee/traitee.db`
- **Nx** for vector similarity (cosine distance in ETS)
- **Nostrum** (Discord), **ExGram** (Telegram) for channel integrations
- **Req** for HTTP (LLM API calls)
- **Mox** + **ExUnit** for testing, **ExCoveralls** for coverage

## Project Layout

```
lib/
  traitee/
    application.ex         OTP supervision tree (~18 children)
    config.ex              Multi-source TOML config loader
    router.ex              Inbound message routing
    session.ex             Session facade
    session/               GenServer per user, lifecycle, inter-session
    memory/                3-tier: STM (ETS) → MTM (summaries) → LTM (knowledge graph)
    context/               Token-aware prompt assembly with budget allocation
    llm/                   Provider abstraction: OpenAI, Anthropic, xAI, Ollama
    security/              8-layer cognitive pipeline + 4-layer filesystem pipeline
                           (sanitizer, judge, threat tracker, io_guard, sandbox,
                            filesystem, exec_gate, docker, audit, output_guard)
    tools/                 8 built-in tools (bash, file, browser, web_search, etc.)
    channels/              Discord, Telegram, WhatsApp, Signal, streaming
    hooks/                 9 hook points with chainable handlers
    skills/                Loader + registry (60s filesystem rescan)
    routing/               Multi-agent router with 5-tier priority
    cron/                  Scheduler with cron expression parser
    process/               Cross-platform executor + concurrency lanes
    auto_reply/            Debouncer + command registry + pipeline
    browser/               Playwright bridge (Node.js JSON-RPC subprocess)
    daemon/                OS service management (Windows/Linux/macOS)
    secrets/               Credential store + manager
    media/                 Pipeline + text extractor
  traitee_web/
    controllers/           health, webhook, openai_proxy (OpenAI-compatible API)
    channels/              Phoenix WebSocket (chat_channel, user_socket)
  mix/tasks/               10 CLI tasks: chat, serve, send, doctor, memory, cron, daemon, onboard, pairing, security
config/                    config.exs, dev.exs, test.exs, prod.exs, runtime.exs
priv/repo/migrations/      SQLite migrations (sessions, messages, summaries, entities, relations, facts, cron_jobs)
priv/browser/              Node.js Playwright bridge (bridge.js)
test/                      ~40 test files mirroring lib/ structure
```

## Architecture

### Supervision Tree

Single `one_for_one` supervisor starts all services. ETS tables are initialized
**before** the supervision tree to guarantee lock-free reads from boot:

```
Traitee.Application
├── Repo (SQLite/Ecto)
├── PubSub (Phoenix — config changes, webchat)
├── Hooks.Engine (GenServer — 9 hook points)
├── Config.HotReload (GenServer — 5s file poll)
├── LLM.Router (GenServer — failover + usage tracking)
├── Memory.Compactor (GenServer — async STM→MTM→LTM)
├── Memory.BatchEmbedder (GenServer — batches of 20)
├── Skills.Registry (GenServer — 60s rescan)
├── Security.Audit (GenServer — filesystem audit trail, ETS ring buffer)
├── Security.Pairing (GenServer — DM approval codes)
├── AutoReply.Debouncer (GenServer — 500ms window)
├── Cron.Scheduler (GenServer — 15s tick)
├── Registry (session lookup, :unique)
├── DynamicSupervisor (sessions — one GenServer per user)
├── Channels.Supervisor (Discord, Telegram, WhatsApp, Signal)
├── DynamicSupervisor (tools)
├── Browser.Supervisor (Node.js Playwright, lazy)
├── Process.Lanes (concurrency limiter: tool=3, embed=2, llm=1)
└── TraiteeWeb.Endpoint (Phoenix/Bandit on :4000)
```

### Message Flow

1. **Channel** normalizes inbound → `%{text, sender_id, channel_type, ...}`
2. **Router** checks allowlist/pairing, commands, resolves agent route
3. **Session.Server.send_message/4** runs the pipeline:
   - Sanitizer → Judge → ThreatTracker → STM.push → Context.Engine.assemble → LLM.Router.complete → Tool loop (max 5) → OutputGuard → STM.push → respond
4. Response delivered back through the originating channel

### Key Design Patterns

- **Actor model**: Every session is an isolated GenServer with own ETS heap and crash boundary
- **ETS for hot paths**: Rate limits, threat scores, canary tokens, vector index, STM ring buffers — all ETS for lock-free concurrent reads; SQLite for durability
- **Behaviour-driven polymorphism**: `Traitee.Tools.Tool`, `Traitee.LLM.Provider`, `Traitee.Process.ExecutorBehaviour`
- **Token budget management**: `Context.Budget` with tiered allocation; unused LTM/MTM capacity cascades to STM
- **Pipeline composition**: Security and auto-reply are composable multi-stage pipelines
- **Hot reload**: Config polled every 5s, changes broadcast via PubSub — no restart needed

## Coding Conventions

### Style

- **Max line length**: 120 characters
- **Formatter**: `mix format` with imports from `:ecto`, `:ecto_sql`, `:phoenix`
- **Credo strict mode** — enforced in CI
- **Max cyclomatic complexity**: 15
- **Max nesting**: 3 levels
- **Max function arity**: 6
- **Alias ordering**: alphabetical (enforced by Credo)
- **No `@spec` requirement** — `Credo.Check.Readability.Specs` is explicitly disabled

### Naming

- Modules: `Traitee.<Domain>.<Concept>` (e.g. `Traitee.Memory.STM`, `Traitee.Security.Sanitizer`)
- Test files mirror source: `lib/traitee/memory/stm.ex` → `test/traitee/memory/stm_test.exs`
- Behaviours named with `Behaviour` suffix (e.g. `RouterBehaviour`, `ExecutorBehaviour`)

### Patterns to Follow

- Use `GenServer` for stateful services; `DynamicSupervisor` for dynamic children
- Use ETS for high-read, low-write hot data; SQLite for durable state
- Use `Task.start` for fire-and-forget async work (compaction, message persistence, hook firing)
- Define `@callback` behaviours and use Mox in tests
- Config access via `Traitee.Config.get/1` — never call `Application.get_env` directly
- Secrets in TOML use `env:VAR_NAME` syntax for indirection

## Testing

### Running Tests

```bash
mix test                                       # All unit tests
mix test test/traitee/memory/stm_test.exs      # Single file
mix test --exclude slow --exclude integration   # Fast subset (Windows CI uses this)
mix test --partitions 2                         # Sharded (CI uses this)
```

### Test Infrastructure

- **ExUnit** with **Ecto.Adapters.SQL.Sandbox** in `:manual` mode
- **Mox mocks**: `Traitee.LLM.RouterMock`, `Traitee.Process.ExecutorMock`
- **Fixtures**: `test/support/fixtures.ex` — factory functions for common structs
- **Helpers**: `test/support/test_helpers.ex` — unique session IDs, temp dirs, fake embeddings, ETS setup
- **Tags excluded by default**: `:integration`, `:live`, `:slow`
- Tests use `async: true` for pure-logic modules (Sanitizer, Budget) and `async: false` for ETS/DB-dependent ones
- **Coverage**: ExCoveralls, 60% minimum threshold

### Writing Tests

- Mirror `lib/` structure in `test/`
- Use unique session IDs per test to avoid ETS conflicts
- Use `STM.push_direct/3` (bypasses Compactor/Repo) for unit tests that only need STM
- Use `setup` blocks for resource creation/cleanup
- Tag slow or integration tests: `@tag :slow`, `@tag :integration`

## CI/CD

### CI Pipeline (`.github/workflows/ci.yml`)

Runs on push to `main` and PRs. Concurrency groups cancel in-progress PR runs.

| Job | What it does |
|---|---|
| `detect-scope` | Skips heavy jobs on docs-only changes; skips draft PRs |
| `lint` | `mix format --check-formatted` + `mix credo --strict` |
| `test` | Sharded (2 partitions), `--warnings-as-errors` on compile, coverage upload |
| `dialyzer` | Type checking with cached PLTs |
| `docker` | Build smoke test (`docker build` + `eval "IO.puts(:ok)"`) |
| `test-windows` | Windows compatibility (push to main only, excludes slow/integration) |
| `ci-pass` | Gate — all of the above must pass or be skipped |

### Release (`.github/workflows/release.yml`)

- Triggered by `v*` tags
- Builds multi-arch Docker image (`linux/amd64` + `linux/arm64`)
- Pushes to GHCR with version tag + `latest`

### Pre-merge Checklist

Before opening a PR, ensure locally:

```bash
mix format
mix credo --strict
mix test
mix compile --warnings-as-errors
```

## Database

SQLite with Ecto. DB lives at `~/.traitee/traitee.db` (dev) or `~/.traitee/traitee_test.db` (test).

### Tables

| Table | Purpose |
|---|---|
| `sessions` | Session metadata (channel, status, message count, last activity) |
| `messages` | All messages (role, content, token count, metadata) |
| `summaries` | MTM — LLM-generated conversation summaries with embeddings |
| `entities` | LTM — Named entities with type, description, embeddings |
| `relations` | LTM — Entity-to-entity relationships with type and strength |
| `facts` | LTM — Entity-attached facts with confidence and embeddings |
| `cron_jobs` | Scheduled tasks |

### Migrations

Located in `priv/repo/migrations/`. Create new ones with:

```bash
mix ecto.gen.migration <name>
```

## Configuration

Multi-source with precedence: **env vars > TOML file > defaults**.

- TOML config: pointed to by `TRAITEE_CONFIG` env var (see `config/traitee.example.toml`)
- Runtime config: `config/runtime.exs` reads env vars for secrets and API keys
- Accessed in code via `Traitee.Config.get/1` — backed by `:persistent_term` for fast reads
- Hot-reloaded every 5 seconds; changes broadcast via PubSub

### Key Env Vars

`SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`XAI_API_KEY`, `DISCORD_BOT_TOKEN`, `TELEGRAM_BOT_TOKEN`, `WHATSAPP_TOKEN`,
`SIGNAL_CLI_PATH`, `TRAITEE_CONFIG`

## Docker

```bash
docker build -t traitee .                    # Build
docker compose up -d                         # Run with compose
docker run --rm traitee bin/traitee eval "IO.puts(:ok)"   # Smoke test
```

Multi-stage: `elixir:1.17-otp-27-slim` (build) → `debian:bookworm-slim` (runtime).
Runs as non-root `traitee` user. Health check on `/api/health`.

## Adding New Features

### New Tool

1. Create `lib/traitee/tools/my_tool.ex` implementing `@behaviour Traitee.Tools.Tool`
2. Implement `name/0`, `description/0`, `parameters_schema/0` (JSON Schema), `execute/1`
3. Register in `Traitee.Tools.Registry`
4. Add test in `test/traitee/tools/my_tool_test.exs`

### New LLM Provider

1. Create `lib/traitee/llm/my_provider.ex` implementing `@behaviour Traitee.LLM.Provider`
2. Implement `configured?/0`, `complete/1`, `stream/2`, `embed/1`, `model_info/1`
3. Add to `Traitee.LLM.Router` provider list

### New Channel

1. Create `lib/traitee/channels/my_channel.ex`
2. Normalize inbound messages to `%{text, sender_id, channel_type, ...}`
3. Add to `Traitee.Channels.Supervisor` conditional start list
4. Add config entries in TOML and `runtime.exs`

### New Hook

1. Register handlers via `Traitee.Hooks.Engine.register/3`
2. Available hook points: `before_message`, `after_message`, `before_tool`, `after_tool`,
   `on_error`, `session_start`, `session_end`, `compaction`, `config_change`
