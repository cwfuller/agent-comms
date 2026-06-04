# agent-comms

Autonomous code-review loops between **Claude Code** and **Codex**, running side by side in your terminal.

One agent writes a markdown message into a local `.comms/` directory, nudges the other agent's pane (via [cmux](https://cmux.com)), and gets a structured reply back. Chain that and you get plan → review → implement → review cycles that run until the reviewer approves — no copy-paste, no babysitting.

```
┌─────────────┐  .comms/to-codex/   ┌─────────────┐
│ Claude Code │ ──────────────────▶ │    Codex    │
│ (implement) │ ◀────────────────── │  (review)   │
└─────────────┘  .comms/to-claude/  └─────────────┘
        loop until verdict: APPROVE (max N rounds)
```

## Quick start

```bash
# from your project's root:
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
```

Open a cmux workspace with Claude Code and Codex in adjacent panes, then ask Claude:

```
/auto-implement add rate limiting to the API
```

Claude implements, sends the diff to Codex for review, fixes the blocking findings, and re-submits — looping until Codex replies `APPROVE` (default cap: 10 rounds). You watch, or you don't.

Works without cmux too: messages are still written and validated, you just trigger each side manually.

## Commands

| Claude Code | What it does |
|---|---|
| `/auto-implement <task>` | implement → review → fix, until approved |
| `/auto-plan <task>` | plan → review → refine, until approved |
| `/auto-full <task>` | plan loop, then implement loop |
| `/ask-codex <question>` | one-off question — judgment call, no review framing |
| `/send-to-codex` | one-shot review request for work you just did |
| `/read-from-codex` | read + act on Codex's reply |
| `/fleet <subcommand>` | orchestrate loops across many cmux workspaces |
| `/clean-comms [mode]` | guarded message cleanup (dry-run first) |

| Codex | What it does |
|---|---|
| `$read-from-claude` | read + act on Claude's message |
| `$send-to-claude` | send findings back, auto-deliver |

Full reference with flags, modes, and the underlying helper CLI: **[docs/COMMANDS.md](docs/COMMANDS.md)**

## What makes the loops reliable

- **Validated messages** — frontmatter-checked before any delivery; malformed messages are refused, never half-processed
- **Threaded** — `thread`/`message_id`/`in-reply-to` fields let concurrent loops share one workspace without consuming each other's replies
- **Stateful** — `.comms/state/` records each loop's round, who owes the next message, and the last delivery outcome; survives compaction and session restarts
- **Honest delivery** — a dropped pane nudge reports `FAILED` and is recoverable (`comms.sh stalled`), instead of silently looking like "the reviewer is slow"
- **Review quality built in** — pass-oriented verdicts (blocking vs advisory), holistic re-review each round instead of fix-checklist tunnel vision, and approved-but-unactioned advisories carried over to `docs/advisories.md`

The full message format, loop semantics, and state model: **[docs/PROTOCOL.md](docs/PROTOCOL.md)**

## Requirements

- Claude Code and Codex CLIs
- A git repository
- Optional, for auto-delivery: [cmux](https://cmux.com), the two agents in adjacent panes, Claude Code in vim mode, and `python3` (for `/fleet`)

## Docs

| | |
|---|---|
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | message format, threading, state files, error lane — the spec both agents follow |
| [docs/COMMANDS.md](docs/COMMANDS.md) | every command, skill, and helper subcommand in detail |
| [docs/INSTALL.md](docs/INSTALL.md) | install scopes, fork installs, local pinning, upgrading |
| [docs/INTERNALS.md](docs/INTERNALS.md) | architecture, the template/helper split, editing rules, test harness |
| [docs/ROADMAP.md](docs/ROADMAP.md) | audit history, friction log, what's next |

## License

MIT
