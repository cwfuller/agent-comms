# Installing

## Quick install

```bash
# from your project's root:
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
```

Run interactively (no `--scope`) and the installer shows a menu:

```
1) Global + project init (recommended)
2) Global only
3) Project init only
4) Local pinned install
5) Cancel
```

## Scopes

| scope | installs | where |
|---|---|---|
| `global` | 8 Claude commands, 2 Codex skills, 3 helper scripts | `~/.claude/commands/`, `~/.codex/skills/`, `~/.agent-comms/` |
| `project` | per-repo state only | `.comms/{to-codex,to-claude,archive}/`, `.gitignore` entries, `.codex/AGENTS.md` protocol note |
| `both` | global + project | the recommended pair |
| `local` | pinned copies of everything into the repo | `.claude/commands/`, `.agents/skills/`, `.agent-comms/` + project state |

All scopes are idempotent — re-run freely.

## Codex socket permissions

Codex → Claude auto-delivery uses cmux's local Unix socket **when cmux delivery is selected** — since 2026-08-25 loops default to the headless runner, which needs no socket, and cmux is opt-in via `--via cmux` / `COMMS_DELIVERY=cmux`. This section applies only to the cmux path. A default
`sandbox_mode = "workspace-write"` session cannot connect to that socket, and wrappers
or retries launched by the same session remain inside the same boundary. Message files
still persist, but Claude is not notified and does not passively poll `.comms/`.

Configure the least-privilege permission profile once in `~/.codex/config.toml`:

```toml
# Remove any sandbox_mode line and [sandbox_workspace_write] table first.
default_permissions = "workspace-cmux"

[permissions.workspace-cmux]
description = "Workspace editing plus agent-comms cmux delivery"
extends = ":workspace"

[permissions.workspace-cmux.network]
enabled = true

[permissions.workspace-cmux.network.unix_sockets]
"/Users/YOU/.local/state/cmux/cmux.sock" = "allow"
```

The installed helper prints a copy with the current user's resolved path:

```bash
~/.agent-comms/comms.sh codex-permissions
```

Restart Codex after changing the global config. No launch parameter is required:
`default_permissions` applies the profile to every new session. Do not launch Codex
with `--sandbox`, because that selects the legacy sandbox model and overrides the
profile. Verify a session with:

```bash
~/.agent-comms/comms.sh doctor
```

`cmux socket: reachable` is the required result. A `blocked` result means the message
queue remains reliable but active peer notification is unavailable in that session.
Permission profiles are supported by Codex 0.138.0 and later and are currently beta.

### Global vs local pinning

Global installs are shared: update once (`install.sh --scope=global` from a checkout, or
re-run the curl line) and every project picks the new version up immediately.

A **local pinned** install copies everything into the repo instead. Pinned copies
**shadow the global install and never auto-update** — the installer prints exactly this
warning. Resolution order everywhere is *local pin first, then global* (commands via the
CLI's own project-command precedence; helpers via the templates' resolver:
`<repo>/.agent-comms/comms.sh` then `~/.agent-comms/comms.sh`). To un-pin, delete the
repo's `.claude/commands/`, `.agents/skills/`, and `.agent-comms/` copies.

Stale pins are the classic failure mode: a repo pinned months ago silently runs old
behavior while every other repo runs current. `install.sh --scope=global` warns when it
detects local copies that would shadow it.

### What project init does

- creates `.comms/` (`to-codex/`, `to-claude/`, `archive/`)
- gitignores `.comms/`, `.codex/AGENTS.md`, `.agent-comms/` (whole-line matched,
  trailing-newline-safe, idempotent)
- writes the protocol note into `.codex/AGENTS.md` so Codex knows the skills exist
  (appends a section if the file already exists)

## Installing from a fork

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/agent-comms/main/install.sh -o /tmp/agent-comms-install.sh
AGENT_COMMS_REPO_RAW="https://raw.githubusercontent.com/<you>/agent-comms/main" \
  bash /tmp/agent-comms-install.sh --scope=both
```

`AGENT_COMMS_REPO_RAW` points template/helper downloads at any raw-file base URL
(including `file:///path/to/checkout` for fully-local testing).

## Environment overrides

| variable | default | purpose |
|---|---|---|
| `AGENT_COMMS_REPO_RAW` | this repo's `main` | raw base URL for remote installs |
| `AGENT_COMMS_HOME` | `~/.agent-comms` | where global helpers land |
| `CLAUDE_COMMANDS_DIR` | `~/.claude/commands` | where global commands land |
| `CODEX_SKILLS_DIR` | `~/.codex/skills` | where global Codex skills land |

## From a clone

```bash
git clone https://github.com/cwfuller/agent-comms.git
cd your-project
../agent-comms/install.sh --scope=both
```

## Upgrading

Re-run the installer with the same scope. Global scope refreshes commands, skills, and
helpers in place; running sessions pick the new versions up on their next command
invocation (slash commands are read from disk each time). In-flight review loops survive
upgrades — protocol-v2 fields are soft-validated precisely so an older message mid-loop
isn't rejected.
