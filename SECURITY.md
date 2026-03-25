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

Traitee implements two independent security pipelines: an **8-layer cognitive pipeline** (with supplementary SystemAuth and Canary subsystems) that processes every LLM interaction, and a **4-layer filesystem pipeline** that enforces boundaries on every tool execution. Both are always active. 16 security modules total.

### Cognitive Security Pipeline

Protects the LLM's reasoning process from manipulation, on both sides of the LLM call.

#### Inbound

| Layer | Module | Purpose |
|-------|--------|---------|
| 1. Sanitizer | `Security.Sanitizer` | Regex-based input classification across 8 threat categories (~28 patterns, 4 severity tiers); replaces matched patterns with `[filtered]` |
| 2. Judge | `Security.Judge` | LLM-as-a-judge detection for attacks that bypass regex (multilingual injection, encoding evasion, social engineering). Fails open on timeout (3s) |
| 3. Threat Tracker | `Security.ThreatTracker` | Per-session ETS-backed threat accumulator with time-decayed scoring (10-minute half-life). Escalates threat level across `normal → elevated → high → critical` |
| 4. Cognitive | `Security.Cognitive` | Persistent identity reinforcement — injects reminders scaled to threat level (3 strategies: positional, reactive, pre-tool). Pre-tool reminders treat all tool outputs as untrusted |

#### Context Assembly (woven into prompt construction)

| Component | Module | Purpose |
|-----------|--------|---------|
| Canary Tokens | `Security.Canary` | Per-session cryptographic canary tokens (`CANARY-<12hex>`) embedded in the system prompt. If the LLM reproduces the token, system prompt leakage is confirmed. Output Guard checks for this on every response |
| System Auth | `Security.SystemAuth` | Per-session 8-char hex nonces (`[SYS:<nonce>]`) that tag every genuine system message. The LLM is instructed to only trust messages bearing this prefix — defends against user-injected fake system messages. Complements Canary: canary detects prompt *leakage*, SystemAuth verifies message *authenticity* |

#### Outbound

| Layer | Module | Purpose |
|-------|--------|---------|
| 5. Output Guard | `Security.OutputGuard` | Post-LLM response validator with ~70 patterns across 14 categories: identity drift, prompt leakage, restriction denial, instruction compliance, mode switching, exploit acknowledgment, persona adoption, reluctant compliance, authority compliance, encoded output, hypothetical bypass, continuation attacks, manipulation awareness, and **secret leakage** (PEM keys, SSH keys, API keys, database URLs with credentials). Critical violations (canary leakage, secrets) are blocked; others are redacted. All violations feed back into ThreatTracker |

#### Access Control

| Layer | Module | Purpose |
|-------|--------|---------|
| 6. Allowlist | `Security.Allowlist` | Per-channel glob-pattern sender allowlists with configurable DM policy (`open` / `pairing` / `closed`) |
| 7. Pairing | `Security.Pairing` | DM approval flow with cryptographic codes (6-char, 10-minute expiry), persistent approved-sender storage (`approved_senders.json`), composite keys (`channel:sender_id`) for cross-channel uniqueness |
| 8. Rate Limiter | `Security.RateLimiter` | ETS-backed token-bucket rate limiting (default: 30 requests/minute, configurable per key prefix) |

### Filesystem Security Pipeline

Protects the host filesystem and prevents secret exfiltration through tool execution. Every tool call passes through this pipeline in order. Layers 1 and 2 are always active and cannot be disabled.

| Layer | Module | Purpose |
|-------|--------|---------|
| 1. I/O Guards | `Security.IOGuard` | **Always active, independent of sandbox.** Scans tool arguments for ~25 sensitive path patterns (`.ssh`, `.aws`, `.env`, `.pem`, `master.key`, `/etc/shadow`, etc.) and 13 dangerous command patterns (`curl\|sh`, fork bombs, reverse shells, `rm -rf /`, etc.). Scans tool output for 15 secret types and redacts them (PEM keys, SSH keys, API keys for OpenAI/xAI/GitHub/GitLab/AWS/Google, JWTs, passwords, database URLs). Wraps entire tool execution in `try/rescue` — if any security module crashes, the operation is **denied** (fail-closed) rather than crashing the session |
| 2. Hardcoded Denylists | `Security.Filesystem` | **Always active.** ~32 path glob patterns (`.ssh/*`, `.aws/*`, `id_rsa*`, `*.pem`, `master.key`, `/etc/shadow`, `C:/Windows/System32/**`, `/proc/**`, etc.) and ~20 command regex patterns (`curl\|sh`, `nc -e`, `chmod +s`, `certutil`, `powershell -enc`, `reg add HKLM`, etc.) that are blocked unconditionally. Environment variable scrubbing strips `KEY`, `SECRET`, `TOKEN`, `PASSWORD`, `CREDENTIAL`, `AUTH` from child process environments. Symlink resolution prevents bypass via symbolic links |
| 3. Sandbox | `Security.Sandbox` | **Configurable.** Centralized enforcement facade composing Filesystem, ExecGate, and Docker. Per-path access control with `allow` / `deny` rules, glob patterns, and per-rule permissions (`read`, `write`, `exec`). Default policy: `deny`, `read_only`, or `allow`. Working directory jail. `~/.traitee` is always accessible |
| 4. Exec Gates | `Security.ExecGate` | **Configurable.** Approval gates for risky commands with 10 default rules (`rm`, `chmod`, `curl`, `wget`, `docker`, `sudo`, `npm publish`, `pip install`, `git push`, `powershell`). Actions: `approve`, `warn`, `deny`. System directory write protection (`/usr`, `/bin`, `/etc`, `C:\Windows`, `C:\Program Files`, etc.) |

**Optional: Docker isolation** (`Security.Docker`) — OS-level container isolation with ephemeral containers, `--read-only` filesystem, `--network none`, memory/CPU/PID limits, dynamic bind mounts from allow rules, and host fallback on Docker unavailability.

**Audit trail** (`Security.Audit`) — Structured ETS ring buffer (10K events) recording all security-relevant filesystem operations: path access, command checks, exec gate decisions, Docker executions, I/O guard denials, crash events, and tool denials. Queryable by type, tool, session, and time range. Accessible via `mix traitee.security`.

## Tool Security

Traitee includes 12 built-in tools. Each can be individually enabled or disabled via config. All tools that touch the filesystem or execute commands pass through the full filesystem security pipeline (IOGuard → Hardcoded Denylists → Sandbox → Exec Gates).

| Tool | Capabilities | Risk Level |
|------|-------------|------------|
| `bash` | Execute shell commands (cmd.exe on Windows, /bin/sh on Unix) | **High** — 30s timeout, 100KB output cap. Enforced through Sandbox: commands are checked against hardcoded denylists, exec gates, and configurable policies. Optional Docker container isolation |
| `file` | Read, write, append, list, check existence | **High** — 50KB read cap. All paths checked against IOGuard patterns, hardcoded denylists, and configurable per-path allow/deny policies with read/write permissions |
| `browser` | Full Playwright automation: navigate, click, type, screenshot, evaluate JS, multi-tab | **High** — arbitrary JS execution in Chromium; headless by default; 14 actions including snapshot (ARIA tree), get_text (15K cap) |
| `web_search` | SearXNG-based web queries | Low — read-only, 10s timeout |
| `memory` | Store/recall entities and facts in LTM | Low — scoped to the instance's knowledge graph |
| `sessions` | List sessions, view history, send inter-session messages | Medium — can access other sessions' context |
| `cron` | Manage scheduled jobs | Medium — jobs can trigger session messages |
| `channel_send` | Send messages to any configured channel | Medium — cross-channel message delivery |
| `skill_manage` | Self-improvement: create, patch, edit, delete, list skills | Medium — modifies the assistant's procedural memory; template skills protected from deletion |
| `workspace_edit` | Self-improvement: read, patch, append SOUL.md/AGENTS.md/TOOLS.md | Medium — modifies workspace prompts (8K cap, `.bak` backups); changes take effect next session |
| `delegate_task` | Spawn up to 5 parallel subagents with per-task tool subsets | Medium — subagents get IOGuard protection but not the full cognitive security pipeline (parent already validated input); max 25 tool iterations per subagent |
| `task_tracker` | Per-session structured todo list (add/update/list/clear) | Low — ETS-backed, scoped to current session; auto-prunes completed tasks after 10 minutes |

**Dynamic tools** can be registered at runtime (bash templates, scripts). They are stored in `~/.traitee/dynamic_tools.json` and cannot override built-in tool names. Dynamic tools are also subject to the full filesystem security pipeline — bash templates pass through Sandbox command checks, and script executors pass through path checks.

**Concurrency limits** are enforced via `Process.Lanes`: tool=3, embed=2, llm=1 concurrent operations.

### Tool Execution Security Chain

Every tool call in the session server passes through this chain:

1. **IOGuard input check** — scans tool arguments for sensitive paths and dangerous commands (independent pattern set from Filesystem)
2. **Sandbox enforcement** — hardcoded denylists, configurable allow/deny policies, exec gates
3. **Tool execution** — wrapped in `try/rescue` via `IOGuard.safe_execute/2` (fail-closed: crashes become denials, not session termination)
4. **IOGuard output check** — scans tool results for leaked secrets (PEM keys, API keys, passwords, etc.) and redacts them with `[REDACTED:<type>]` markers
5. **Audit logging** — all security events recorded to the audit trail
6. **SystemAuth tagging** — any cognitive reminders or task reminders injected between tool rounds are tagged with `[SYS:<nonce>]`

If any step fails or crashes, the tool call returns a safe error message and the session continues normally. The session tool loop supports up to 50 iterations per message.

### Tool Hardening Recommendations

- Disable `bash` and `file` tools in config if your use case doesn't require them.
- Enable **sandbox mode** (`security.filesystem.sandbox_mode = true`) with `default_policy = "deny"` and explicit allow rules for trusted directories.
- Enable **Docker isolation** (`security.filesystem.docker.enabled = true`) for OS-level containment of bash commands.
- Enable **exec gates** (`security.filesystem.exec_gate.enabled = true`) to get approval checks on risky commands like `rm`, `curl`, `docker`, and `sudo`.
- Enable **audit trail** (`security.filesystem.audit.enabled = true`) and review with `mix traitee.security --audit`.
- Review dynamic tools before deployment — they execute with the same OS privileges as the Traitee process, but are still subject to all filesystem security layers.
- The `browser` tool's `evaluate` action runs arbitrary JavaScript. Disable the browser tool if not needed.
- Consider running Traitee as a non-root/low-privilege OS user to limit tool blast radius.
- Run `mix traitee.security --gaps` to identify weaknesses in your filesystem security posture.

## Session Isolation

- Every conversation is an isolated **GenServer** with its own ETS heap, STM buffer, and crash boundary.
- One session crash does not affect other sessions (OTP supervision with `restart: :transient`).
- Both security pipelines (cognitive and filesystem) run independently per session.
- Threat scores are per-session and time-decayed — one user's threat level does not affect another's.
- Per-session security state includes: canary token (ETS), SystemAuth nonce (ETS), threat events (ETS), and task list (ETS).
- Tool execution is fail-closed: if any security module crashes during a tool call, the tool returns a safe error and the session continues. Security failures never propagate to session termination.
- Activity logging (`ActivityLog`) records all tool calls, LLM calls, and subagent events per session in a non-blocking ETS log (max 500 entries/session) for observability without impacting performance.

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
- **IOGuard fail-closed behavior** — The I/O guard layer intentionally fails closed (denies the operation on any crash). Reports that the fail-closed behavior is "too restrictive" are not vulnerabilities.
- **Sandbox configuration choices** — Reports that the sandbox default policy is set to `allow` by the operator. The operator chose this configuration.
- **Hardcoded denylist bypasses via allowed paths** — If the operator explicitly allows a path that overlaps with the hardcoded denylist, the hardcoded denylist takes precedence. Reports that the operator "cannot override" the hardcoded denylist are by design.
- **Session data visibility** — The `sessions` tool allows viewing other sessions' history on the same instance. This is expected in the single-operator model.
- **Local filesystem access** — Reports that require pre-existing write access to `~/.traitee/` or the workspace directory.
- **Docker unavailability fallback** — When Docker is enabled but unavailable, commands fall back to host execution with all other security layers still active. This is documented behavior.
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
- IOGuard pattern false positives (e.g., file path that matches `.pem` but is not a private key) — these are intentional over-matches in a defense-in-depth system
- Reports that the hardcoded denylist blocks legitimate operator paths — the operator should use the sandbox allow rules with appropriate permissions
- Audit trail event volume or retention — the 10K ring buffer is a configurable design choice
- Reports that Docker isolation can be bypassed by disabling it in config — Docker is an optional layer, not a mandatory boundary

## Responsible Disclosure

Traitee is a personal project. There is no bug bounty program. Please still disclose responsibly so we can fix issues quickly. The best way to help is by sending PRs.

## Deployment Checklist

For a hardened Traitee deployment:

**OS & Network**

- [ ] Run as a non-root, dedicated OS user
- [ ] Keep Traitee bound to localhost or a trusted network
- [ ] Use a reverse proxy with authentication if remote access is needed
- [ ] Enable full-disk encryption for data-at-rest protection
- [ ] Keep Elixir, OTP, and all dependencies up to date

**Secrets & Credentials**

- [ ] Set `~/.traitee/` permissions to owner-only (`700` on Unix)
- [ ] Use environment variables for all secrets (never hardcode in TOML)
- [ ] Run `mix traitee.doctor` to audit credential configuration

**Access Control**

- [ ] Review and restrict channel allowlists
- [ ] Set DM policy to `pairing` or `closed` for all channels
- [ ] Disable unused tools (especially `bash`, `file`, `browser`)

**Filesystem Security**

- [ ] Enable sandbox mode: `security.filesystem.sandbox_mode = true`
- [ ] Set default policy to deny: `security.filesystem.default_policy = "deny"`
- [ ] Configure explicit allow rules only for directories the assistant needs
- [ ] Enable exec gates: `security.filesystem.exec_gate.enabled = true`
- [ ] Enable audit trail: `security.filesystem.audit.enabled = true`
- [ ] Enable Docker isolation if available: `security.filesystem.docker.enabled = true`
- [ ] Run `mix traitee.security` to audit filesystem security posture
- [ ] Run `mix traitee.security --gaps` to identify configuration weaknesses
- [ ] Review audit trail periodically: `mix traitee.security --audit`
