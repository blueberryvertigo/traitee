# Security Policy

If you believe you've found a security issue in Traitee, please report it privately.

## Reporting a Vulnerability

Use [GitHub Security Advisories](https://github.com/blueberryvertigo/traitee/security/advisories/new) to report vulnerabilities directly.

### Required in Reports

1. **Title** — concise summary of the issue
2. **Severity assessment** — your estimate of impact (Low / Medium / High / Critical)
3. **Affected component** — module path and function (e.g. `Traitee.Security.Sanitizer.classify/1`)
4. **Technical reproduction** — step-by-step instructions against a current revision
5. **Demonstrated impact** — concrete proof of what an attacker gains
6. **Environment** — Elixir/OTP version, OS, channel type, relevant config
7. **Remediation advice** — suggested fix if you have one

Reports without reproduction steps and demonstrated impact will be deprioritized. Given the volume of AI-generated scanner findings, we must ensure we're receiving vetted reports from researchers who understand the issues.

### Report Acceptance Gate

For fastest triage, include all of the following:

- Exact vulnerable path (module, function, and line range) on a current revision
- Tested version (Traitee version and/or commit SHA)
- Reproducible PoC against latest `main` or latest released version
- Demonstrated impact tied to Traitee's documented trust boundaries
- Explicit statement that the report does not rely on multi-user scenarios on a single Traitee instance
- Scope check explaining why the report is **not** covered by the Out of Scope section below

Reports that miss these requirements may be closed as `invalid` or `no-action`.

### Duplicate Report Handling

- Search existing advisories before filing.
- Include likely duplicate GHSA IDs in your report when applicable.
- Maintainers may close lower-quality or later duplicates in favor of the earliest high-quality canonical report.

## Operator Trust Model

Traitee is a **personal AI assistant** — a single-operator, single-host system, not a shared multi-tenant platform.

- The person who deploys and configures Traitee is the **trusted operator** for that instance.
- Anyone who can modify `~/.traitee/` (config, credentials, approved senders, database) is effectively a trusted operator.
- Authenticated channel senders approved via the pairing system are trusted within the permissions granted to that channel.
- A single Traitee instance shared by mutually untrusted people is **not a supported configuration**. Use separate instances per trust boundary.
- Session identifiers are routing controls for conversation isolation, not per-user authorization boundaries.

### Channel Trust

- The **owner** (identified by `security.owner_id` and per-channel IDs in config) has full access to all commands and tools.
- Non-owner senders must be approved via the **pairing system** (6-character code, 10-minute expiry, owner approval required) or be on the channel allowlist.
- DM policy is configurable per channel: `open`, `pairing` (default), or `closed`.
- If multiple people can message the same tool-enabled agent (e.g. a shared Discord server), they can all interact with the agent within its granted permissions. For mixed-trust environments, use the allowlist and pairing system to restrict access.

## Security Architecture

Traitee implements an 8-layer security pipeline that processes every message:

### Inbound Pipeline

| Layer | Module | Purpose |
|-------|--------|---------|
| 1. Sanitizer | `Security.Sanitizer` | Regex-based input classification across 8 threat categories; replaces matched patterns with `[filtered]` |
| 2. Judge | `Security.Judge` | LLM-as-a-judge detection for attacks that bypass regex (multilingual injection, encoding evasion, social engineering). Fails open on timeout |
| 3. Threat Tracker | `Security.ThreatTracker` | Per-session ETS-backed threat accumulator with time-decayed scoring. Escalates threat level across `normal → elevated → high → critical` |
| 4. Cognitive | `Security.Cognitive` | Persistent identity reinforcement — injects reminders scaled to threat level. Pre-tool reminders treat all tool outputs as untrusted |

### Outbound Pipeline

| Layer | Module | Purpose |
|-------|--------|---------|
| 5. Output Guard | `Security.OutputGuard` | Post-LLM response validator detecting identity drift, prompt leakage, restriction denial, encoded output, and 50+ violation patterns. Critical violations are blocked; others are redacted |
| 6. Canary | `Security.Canary` | Per-session cryptographic canary tokens embedded in system prompts. Leakage triggers critical-level blocking |

### Access Control

| Layer | Module | Purpose |
|-------|--------|---------|
| 7. Allowlist | `Security.Allowlist` | Per-channel glob-pattern sender allowlists with configurable DM policy |
| 8. Pairing | `Security.Pairing` | DM approval flow with cryptographic codes, 10-minute expiry, persistent approved-sender storage |

Additionally, `Security.RateLimiter` provides ETS-backed token-bucket rate limiting (default: 30 requests/minute).

## Tool Security

Traitee includes 8 built-in tools. Each can be individually enabled or disabled via config.

| Tool | Capabilities | Risk Level |
|------|-------------|------------|
| `bash` | Execute shell commands (cmd.exe on Windows, /bin/sh on Unix) | **High** — 30s timeout, 10KB output cap, but no sandbox by default |
| `file` | Read, write, append, list, check existence | **High** — operates on expanded paths without sandboxing; 50KB read cap |
| `browser` | Full Playwright automation: navigate, click, type, screenshot, evaluate JS | **High** — arbitrary JS execution in Chromium; headless by default |
| `web_search` | SearXNG-based web queries | Low — read-only, 10s timeout |
| `memory` | Store/recall entities and facts in LTM | Low — scoped to the instance's knowledge graph |
| `sessions` | List sessions, view history, send inter-session messages | Medium — can access other sessions' context |
| `cron` | Manage scheduled jobs | Medium — jobs can trigger session messages |
| `channel_send` | Send messages to any configured channel | Medium — cross-channel message delivery |

**Dynamic tools** can be registered at runtime (bash templates, scripts). They are stored in `~/.traitee/dynamic_tools.json` and cannot override built-in tool names.

**Concurrency limits** are enforced via `Process.Lanes`: tool=3, embed=2, llm=1 concurrent operations.

### Tool Hardening Recommendations

- Disable `bash` and `file` tools in config if your use case doesn't require them.
- Review dynamic tools before deployment — they execute with the same OS privileges as the Traitee process.
- The `browser` tool's `evaluate` action runs arbitrary JavaScript. Disable the browser tool if not needed.
- Consider running Traitee as a non-root/low-privilege OS user to limit tool blast radius.

## Session Isolation

- Every conversation is an isolated **GenServer** with its own ETS heap, STM buffer, and crash boundary.
- One session crash does not affect other sessions (OTP supervision with `restart: :transient`).
- The full security pipeline (sanitizer → judge → threat tracker → cognitive → output guard) runs independently per session.
- Threat scores are per-session and time-decayed — one user's threat level does not affect another's.

## Secrets and Credentials

- **Environment variables** are the recommended way to provide API keys and tokens (e.g. `OPENAI_API_KEY`, `DISCORD_BOT_TOKEN`).
- **TOML config** supports `env:VAR_NAME` indirection — secrets are resolved at runtime, not stored in config files.
- **Credential store** (`~/.traitee/credentials/`) stores provider credentials as plaintext JSON files on disk. Protect this directory with appropriate filesystem permissions.
- The **Secrets Manager** provides `redact/1` to scrub known secrets from output text before it reaches users.
- `SECRET_KEY_BASE` is required for Phoenix session signing and must be kept confidential.

### Credential Hardening Recommendations

- Set `~/.traitee/` directory permissions to owner-only (`700` on Unix).
- Use environment variables or `env:` indirection rather than hardcoding secrets in TOML.
- Run `mix traitee.doctor` to audit credential configuration.
- Never commit `.env` files, `credentials/` directories, or TOML files containing secrets.

## Database

Traitee uses **SQLite** with a single database file at `~/.traitee/traitee.db`.

- All conversation history (messages, summaries, entities, facts) is stored locally.
- The database file should be protected with appropriate filesystem permissions.
- There is no encryption at rest by default. For sensitive deployments, use full-disk encryption on the host.

## Network Exposure

Traitee runs a **Phoenix/Bandit HTTP server** on port 4000.

- The web endpoint serves health checks (`/api/health`), webhooks (WhatsApp), and an OpenAI-compatible proxy API.
- **Do not expose Traitee directly to the public internet.** It is designed for local or trusted-network use.
- If remote access is needed, use an SSH tunnel, VPN, or reverse proxy with authentication.
- The WebSocket endpoint (`/socket/websocket`) is intended for local web UI connections.

## Docker

The official Docker image follows security best practices:

- **Multi-stage build** — build dependencies are not included in the runtime image.
- **Non-root user** — runs as the `traitee` user, not root.
- **Health check** — built-in health endpoint at `/api/health`.

For additional hardening:

```bash
docker run --read-only --cap-drop=ALL \
  -v traitee-data:/root/.traitee \
  traitee:latest
```

## Out of Scope

The following are **not** considered vulnerabilities:

- **Public internet exposure** — Traitee is not designed for public-facing deployment. Issues arising from exposing it to the internet are user misconfiguration.
- **Prompt injection without boundary bypass** — Prompt injection that does not cross an auth, tool policy, or security pipeline boundary. The security pipeline is designed to mitigate prompt injection but does not claim to be impervious; pure prompt manipulation without tool execution or data exfiltration is out of scope.
- **Multi-user trust on a single instance** — Reports that assume per-user authorization on a shared Traitee instance. This is not a supported configuration.
- **Trusted operator actions** — Reports where the operator (someone with access to `~/.traitee/` or config) performs actions within their trust level.
- **Tool execution by design** — Reports that only show a tool (bash, file, browser) doing what it is designed to do when enabled by the operator. These are intentional capabilities.
- **Dynamic tool behavior** — Reports that only show a dynamic tool executing with host privileges after a trusted operator registers it.
- **LLM hallucination or quality** — Issues with LLM response accuracy or behavior that don't involve security boundary violations.
- **Judge fail-open behavior** — The LLM judge layer intentionally fails open (returns `:safe` on timeout/error) to avoid blocking the pipeline. This is a design trade-off, not a vulnerability.
- **Session data visibility** — The `sessions` tool allows viewing other sessions' history on the same instance. This is expected in the single-operator model.
- **Local filesystem access** — Reports that require pre-existing write access to `~/.traitee/` or the workspace directory.
- **Scanner-only claims** — Automated scanner findings without a working reproduction against a current revision.

## Common False-Positive Patterns

These are frequently reported but typically closed with no code change:

- Prompt injection chains that don't bypass the security pipeline or achieve tool execution
- Reports treating operator-enabled tools (bash, file, browser) as vulnerabilities without demonstrating an auth/policy bypass
- Reports assuming the pairing system provides multi-tenant authorization (it provides DM access control, not user-level permissions)
- Reports that treat `evaluate` in the browser tool as a vulnerability without demonstrating unauthorized access (it is an intentional operator-enabled capability)
- Reports that depend on modifying `~/.traitee/` state (config, credentials, approved senders) without showing an untrusted path to that write
- Canary token detection gaps that don't result in actual data exfiltration
- Rate limiter bypass through legitimate usage patterns
- Missing HSTS on default local deployments

## Responsible Disclosure

Traitee is a personal project. There is no bug bounty program. Please still disclose responsibly so we can fix issues quickly. The best way to help is by sending PRs.

## Deployment Checklist

For a hardened Traitee deployment:

- [ ] Run as a non-root, dedicated OS user
- [ ] Set `~/.traitee/` permissions to owner-only
- [ ] Use environment variables for all secrets (never hardcode in TOML)
- [ ] Disable unused tools (especially `bash`, `file`, `browser`)
- [ ] Keep Traitee bound to localhost or a trusted network
- [ ] Use a reverse proxy with authentication if remote access is needed
- [ ] Enable full-disk encryption for data-at-rest protection
- [ ] Review and restrict channel allowlists
- [ ] Set DM policy to `pairing` or `closed` for all channels
- [ ] Run `mix traitee.doctor` to audit configuration
- [ ] Keep Elixir, OTP, and all dependencies up to date
