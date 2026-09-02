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
| `global` | 5 Claude commands, 3 helper scripts, 2 loopspec fragments | `~/.claude/commands/`, `~/.agent-comms/` |
| `project` | per-repo state only | `.comms/{to-codex,to-claude,archive}/`, `.gitignore` entries, `.codex/AGENTS.md` protocol note |
| `both` | global + project | the recommended pair |
| `local` | pinned copies of everything into the repo | `.claude/commands/`, `.agents/loopspec-fragments/`, `.agent-comms/` + project state |

All scopes are idempotent — re-run freely.

## Codex permissions

**No socket allowance is required.** Delivery runs over ACP, which needs no network and no
Unix socket. The `workspace-cmux` permission profile this section used to prescribe — along
with the `comms.sh codex-permissions` and `comms.sh doctor` commands that printed and verified
it — was removed in step 4 with the cmux transport itself.

Reviewer turns are contained by Codex's own kernel sandbox (`sandbox_mode = "read-only"` plus
an isolated `CODEX_HOME`), which `runphase.sh` sets up per turn. Nothing needs configuring in
`~/.codex/config.toml` for agent-comms to deliver.

If a sandboxed session still cannot write its reply, the message file persists and Claude is
**not** notified — do not assume passive polling of `.comms/`. Use one manual pickup rather
than re-running the same helper from the unchanged sandbox.

### Global vs local pinning

Global installs are shared: update once (`install.sh --scope=global` from a checkout, or
re-run the curl line) and every project picks the new version up immediately.

A **local pinned** install copies everything into the repo instead. Pinned copies
**shadow the global install and never auto-update** — the installer prints exactly this
warning. Resolution order everywhere is *local pin first, then global* (commands via the
CLI's own project-command precedence; helpers via the templates' resolver:
`<repo>/.agent-comms/comms.sh` then `~/.agent-comms/comms.sh`). To un-pin, delete the
repo's `.claude/commands/`, `.agents/loopspec-fragments/`, and `.agent-comms/` copies.

Stale pins are the classic failure mode: a repo pinned months ago silently runs old
behavior while every other repo runs current. `install.sh --scope=global` warns when it
detects local copies that would shadow it.

### What project init does

- creates `.comms/` (`to-codex/`, `to-claude/`, `archive/`)
- gitignores `.comms/`, `.codex/AGENTS.md`, `.agent-comms/` (whole-line matched,
  trailing-newline-safe, idempotent)
- writes the protocol note into `.codex/AGENTS.md` so Codex knows review turns are parent-brokered
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
| `CODEX_SKILLS_DIR` | `~/.codex/skills` | where retired Codex skills are removed from (nothing is installed there) |

## From a clone

```bash
git clone https://github.com/cwfuller/agent-comms.git
cd your-project
../agent-comms/install.sh --scope=both
```

## Upgrading

Re-run the installer with the same scope. Global scope refreshes commands, fragments, and
helpers in place; running sessions pick the new versions up on their next command
invocation (slash commands are read from disk each time). In-flight review loops survive
upgrades — protocol-v2 fields are soft-validated precisely so an older message mid-loop
isn't rejected.
