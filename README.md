# agent-comms

Autonomous communication between Claude Code and Codex, with optional [cmux](https://cmux.com) auto-delivery.

Drop a file, deliver it to the other agent's terminal pane, get a response back — no manual intervention.

## Install

```bash
# From any git project root:
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash
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
AGENT_COMMS_REPO_RAW="https://raw.githubusercontent.com/<you>/agent-comms/main" bash /tmp/agent-comms-install.sh
```

## What it installs

**Claude Code commands:**
| Command | Description |
|---|---|
| `/send-to-codex` | One-shot send with auto-delivery |
| `/read-from-codex` | Read and act on Codex's response |
| `/auto-plan` | Autonomous plan + review cycle |
| `/auto-implement` | Autonomous implement + review cycle |
| `/auto-full` | Plan cycle then implement cycle |
| `/clean-comms` | Delete messages |

**Codex skills:**
| Skill | Description |
|---|---|
| `$read-from-claude` | Read and act on Claude's message |
| `$send-to-claude` | Send findings back with auto-delivery |

## How it works

1. Agent writes a markdown message to `.comms/to-codex/` or `.comms/to-claude/`
2. When available, `cmux send` types the read command into the other agent's terminal pane
3. The other agent reads the message, acts on it, and responds

Messages are workspace-scoped when running under `cmux`, fall back to branch/repo-scoped filenames outside `cmux`, are worktree-safe (always resolve to the main repo root), and auto-archive after processing.

## Autonomous loops

```
/auto-plan build a caching layer for the API
```

Claude creates a plan, sends it to Codex for review. Codex reviews, sends findings back. Claude refines, sends again. Loop continues until Codex approves or max rounds (10) is reached.

`/auto-implement` does the same for code. `/auto-full` chains both: plan until approved, then implement until approved.

**Review quality:**
- Round 1: full contextual review with provided focus areas
- Round 2+: holistic re-review with stable context, not fix verification
- Blocking/advisory distinction: only blocking issues trigger REQUEST_CHANGES
- Default to APPROVE — the bar is production correctness, not perfection

## Requirements

- [cmux](https://cmux.com) — optional terminal multiplexer for cross-pane auto-delivery
- Claude Code and Codex running in adjacent cmux panes when using auto-delivery
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
workflow: auto-plan          # triggers autonomous mode
phase: plan
round: 1
max-rounds: 10
---

## What was done
## Files changed
## Review focus
```

Autonomous replies preserve the workflow metadata and add a `verdict: APPROVE | REQUEST_CHANGES`.

## File structure

```
.comms/                          # gitignored, local only
  to-codex/                      # Claude writes, Codex reads
  to-claude/                     # Codex writes, Claude reads
  archive/                       # processed messages
.claude/commands/                # Claude Code skills
  send-to-codex.md
  read-from-codex.md
  auto-plan.md
  auto-implement.md
  auto-full.md
  clean-comms.md
.agents/skills/                  # Codex skills
  read-from-claude/SKILL.md
  send-to-claude/SKILL.md
.codex/AGENTS.md                 # protocol docs for Codex
```
