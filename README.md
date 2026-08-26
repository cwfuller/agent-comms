# agent-comms

Autonomous code-review loops between AI coding agents. One agent implements, one or more
review, and the loop runs until they approve — no copy-paste, no babysitting.

It exists because asking one agent to write code, then asking another to critique it, then
feeding the critique back produces markedly better results than either alone. This is that
loop, automated.

```
                 ┌─────────► codex ──┐
  claude ────────┤  same artifact    ├────► one composed verdict ──► fix ──► repeat
 (implement)     └─────────► grok  ──┘        until approved
```

## Quick start

```bash
# from your project's root:
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
```

Then, in Claude Code:

```
/auto add rate limiting to the API
```

That's it. Claude implements, sends the diff to a reviewer, fixes the blocking findings,
and re-submits — until the reviewer approves or it runs out of rounds (default 4).

Nothing else is required: no terminal panes, no second window open. Review turns run over
ACP in a warm background session.

## Everyday use

```bash
/auto <task>                      # implement → review → fix, until approved
/auto --reviewers codex,grok      # a panel: both review the same pinned artifact
/auto --plan <task>               # add a capped approach review first (high-stakes work)
/auto --rounds 6 <task>           # more rounds than the default 4

/ask codex <question>             # one-off consult, no loop, no verdict
/ask                              # "thoughts?" on the current discussion
```

**When to reach for `--plan`:** only when a wrong *approach* would be expensive to discover
after implementing — novel architecture, high blast radius, safety-critical. Most work
should let the implementation speak for itself.

**When to reach for a panel:** when you want coverage more than speed. Two reviewers on one
artifact reliably find different things. A finding both raise gates the loop; a finding only
one raises is flagged for you to cross-check rather than obeyed automatically.

Full reference: **[docs/COMMANDS.md](docs/COMMANDS.md)**

## What makes the loops trustworthy

- **Every reviewer reads the same thing.** The tree is snapshotted when the request is sent
  and mounted for the reviewer, so a review is about a pinned artifact — not whatever you
  happened to be typing while it ran.
- **Messages are validated before delivery.** Malformed messages are refused, never
  half-processed. A failed delivery says so and is recoverable; it never looks like "the
  reviewer is just slow".
- **One noisy reviewer cannot hold the loop hostage.** A lone unsupported blocking finding
  is cross-checked, not automatically obeyed.
- **Nothing is silently dropped.** Composition keeps every finding, attributed to the
  reviewer who made it. An unanswered panel leg blocks the gate rather than counting as
  approval.
- **Advisories survive.** Un-actioned advisory findings are carried into
  `docs/advisories.md` when a loop ends, so lessons compound instead of evaporating.

Message format, loop semantics, and the state model: **[docs/PROTOCOL.md](docs/PROTOCOL.md)**

## Requirements

- A git repository
- At least two agent CLIs — `claude`, `codex`, and `grok` are supported
- Node ≥ 22.13 for the ACP transport (or set `ACPX_BIN` to an installed `acpx`)
- Optional: [cmux](https://cmux.com), if you want loops to run in watchable panes
  (`--via cmux`)

## Docs

| | |
|---|---|
| [docs/COMMANDS.md](docs/COMMANDS.md) | every command, skill, and helper subcommand |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | message format, transports, state, archive discipline |
| [docs/loopspec/SPEC.md](docs/loopspec/SPEC.md) | the portable review-loop contract: verdicts, rounds, schemas, fixtures |
| [docs/INSTALL.md](docs/INSTALL.md) | install scopes, local pinning, upgrading |
| [docs/INTERNALS.md](docs/INTERNALS.md) | architecture, the template/helper split, test harness |
| [docs/ROADMAP.md](docs/ROADMAP.md) | decisions, field reports, what's next |

## License

MIT
