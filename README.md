# agent-comms

Autonomous communication between Claude Code and Codex, with optional [cmux](https://cmux.com) auto-delivery.

Drop a file, deliver it to the other agent's terminal pane, get a response back — no manual intervention.

## Install

```bash
# From any git project root:
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash
```

The installer opens a menu:

```
1) Global + project init (recommended)
2) Global only
3) Project init only
4) Local pinned install
5) Cancel
```

Global installs reusable Claude commands to `~/.claude/commands/` and Codex skills to `~/.codex/skills/`, so updates only need to be installed once. Project init creates `.comms/`, updates `.gitignore`, and adds the protocol note to `.codex/AGENTS.md`.

If an existing project already has local copies under `.claude/commands/` or `.agents/skills/`, those may shadow the global install. The installer warns when it sees likely agent-comms local copies.

For non-interactive installs, pass a scope explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=global
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=project
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=local
```

Or clone and run:

```bash
git clone https://github.com/cwfuller/agent-comms.git
cd your-project
../agent-comms/install.sh
```

If you're installing from your own fork via a downloaded script, point template downloads at that fork:

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/agent-comms/main/install.sh -o /tmp/agent-comms-install.sh
AGENT_COMMS_REPO_RAW="https://raw.githubusercontent.com/<you>/agent-comms/main" bash /tmp/agent-comms-install.sh --scope=both
```

## What it installs

**Claude Code commands:**
| Command | Description |
|---|---|
| `/send-to-codex` | One-shot send with auto-delivery |
| `/read-from-codex` | Read and act on Codex's response |
| `/ask-codex` | One-off question — get Codex's take, no review framing |
| `/auto-plan` | Autonomous plan + review cycle |
| `/auto-implement` | Autonomous implement + review cycle |
| `/auto-full` | Plan cycle then implement cycle |
| `/clean-comms` | Delete messages — default scopes to this workspace's own inbox + archive; `all`, `archive`, or a filename |
| `/fleet` | Orchestrate auto-loops across N cmux workspaces |

**Codex skills:**
| Skill | Description |
|---|---|
| `$read-from-claude` | Read and act on Claude's message |
| `$send-to-claude` | Send findings back with auto-delivery |

**Shared helpers** (installed to `~/.agent-comms/`, or `<repo>/.agent-comms/` for pinned local installs) — the single source of truth both agents call, so the two sides provably can't drift:
| Helper | Description |
|---|---|
| `comms.sh` | workspace/root resolution, message validation, pane-aware cmux delivery, idempotent own-inbox archive, atomic send (refuses to archive the inbound unless the outbound validated) |
| `fleet.sh` | the `/fleet` engine — status, dispatch (with per-target busy-check), dispatch-all (two-phase), harvest, clear |

## How it works

1. Agent writes a markdown message to `.comms/to-codex/` or `.comms/to-claude/`
2. When available, `cmux send` types the read command into the other agent's terminal pane
3. The other agent reads the message, acts on it, and responds

Messages are workspace-scoped when running under `cmux`, fall back to branch/repo-scoped filenames outside `cmux`, are worktree-safe (always resolve to the main repo root), and auto-archive after processing.

## One-off questions

```
/ask-codex should we use a Postgres LISTEN/NOTIFY queue or just poll the table?
```

Claude writes a `type: question` message with `## Question / ## Context / ## Current Thinking` and delivers it. Codex answers as a `type: response` with no verdict — single round, then archive. Use this for design judgment calls; use `/send-to-codex` when you want a real review.

## Autonomous loops

```
/auto-plan build a caching layer for the API
```

Claude creates a plan, sends it to Codex for review. Codex reviews, sends findings back. Claude refines, sends again. Loop continues until Codex approves or max rounds (10) is reached.

`/auto-implement` does the same for code. `/auto-full` chains both: plan until approved, then implement until approved.

## Fleet orchestration

When you have multiple cmux workspaces each running a Claude+Codex pair (`ws-1`, `ws-2`, …) plus a control workspace, `/fleet` dispatches briefs across them from one place:

```
/fleet status                                  # who's idle, who's working, what got approved
/fleet dispatch ws-2 docs/plans/caching.md     # clear ws-2 and fire /auto-implement
/fleet dispatch-all brief1.md brief2.md ...    # auto-assign briefs to free workspaces
/fleet harvest                                 # workspaces idle + approved, ready for next brief
/fleet clear ws-2                              # /new both panes
/fleet help                                    # full usage
```

Override the workspace name prefix with `FLEET_PREFIX=tide` and the concurrency cap with `FLEET_MAX=5`. The cap defaults to 3 to protect a shared on-disk working tree from cross-staged commits and `index.lock` collisions; bump or `--force` if each workspace has its own `git worktree add`.

**Review quality:**
- Round 1: full contextual review with provided focus areas
- Round 2+: holistic re-review with stable context, not fix verification
- Blocking/advisory distinction: only blocking issues trigger REQUEST_CHANGES
- Default to APPROVE — the bar is production correctness, not perfection

## Requirements

- [cmux](https://cmux.com) — optional terminal multiplexer for cross-pane auto-delivery
- Claude Code and Codex running in adjacent cmux panes when using auto-delivery
- Claude Code with **vim mode** enabled when using Codex→Claude auto-delivery — the delivery keystrokes assume modal input (`escape`, `i`, type, `enter`); without vim mode the injected command arrives garbled
- `python3` on PATH for `/fleet` (pane-title spinner classification)
- Git repository

## Protocol

Messages are markdown files with YAML frontmatter:

```markdown
---
type: review-request
from: claude
timestamp: 2026-03-27T01:40:47Z
branch: feat/my-feature
workspace: my-workspace
cwd: /path/to/working/directory
message_id: my-workspace_2026-03-27T01-40-47_auto-plan-12345   # filename sans .md
thread: caching-layer-12345  # names the loop; constant across all its messages
workflow: auto-plan          # triggers autonomous mode
phase: plan
round: 1
max-rounds: 10
---

## What was done
## Files changed
## Review focus
```

Autonomous replies preserve the workflow metadata (including `thread`), set `in-reply-to` to the `message_id` they answer, and add a `verdict: APPROVE | REQUEST_CHANGES`. Replies from Codex use `type: review-feedback` for reviews and `type: response` for `/ask-codex` answers (no verdict). A `type: error` message reports a malformed counterpart and requests a clean resend without consuming a round.

Loop ground truth lives in `.comms/state/<workspace>_<thread>.json` (written automatically by the helper's `send`): workflow/phase/round, who owes the next message, and the last delivery outcome (`delivered`/`manual`/`failed`). `comms.sh stalled` lists threads awaiting a reply too long — the recovery surface for dropped delivery nudges.

## File structure

```
.comms/                          # gitignored, local only
  to-codex/                      # Claude writes, Codex reads
  to-claude/                     # Codex writes, Claude reads
  archive/                       # processed messages
.claude/commands/                # Claude Code commands (thin wrappers over comms.sh)
  send-to-codex.md
  read-from-codex.md
  ask-codex.md
  auto-plan.md
  auto-implement.md
  auto-full.md
  clean-comms.md
  fleet.md
.agents/skills/                  # Codex skills (same comms.sh)
  read-from-claude/SKILL.md
  send-to-claude/SKILL.md
.agent-comms/                    # shared helpers (local pinned installs)
  comms.sh
  fleet.sh
.codex/AGENTS.md                 # protocol docs for Codex
```

Global installs place the same Claude command files under `~/.claude/commands/`, the same Codex skills under `~/.codex/skills/`, and the helpers under `~/.agent-comms/`. The repo also ships `tests/run.sh` — a hermetic harness (stubbed cmux, throwaway git fixtures) covering the helpers and installer; run it with `bash tests/run.sh`.
