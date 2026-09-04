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

Piping a script into a shell means running code you have not read. If you would rather look
first — and you should — clone it and run it from disk. The result is identical:

```bash
git clone https://github.com/cwfuller/agent-comms ~/src/agent-comms
less ~/src/agent-comms/install.sh     # with --scope=both it writes ~/.claude/commands,
                                      # ~/.agent-comms, ~/.codex/AGENTS.md, and in the project
                                      # .comms/ plus .gitignore entries. Nothing else.
cd /path/to/your/project && bash ~/src/agent-comms/install.sh --scope=both
```

Then, in Claude Code:

```
/auto add rate limiting to the API
```

That's it. Claude implements, snapshots the tree, and every other registered agent
reviews **that same pinned artifact**. Shared blockers gate the next round; unique
ones are flagged for you. It repeats until they approve or it hits the round cap
(default 10 per phase).

Nothing else is required: no terminal panes, no second window open. Review turns run
over ACP in the background.

## Everyday use

```bash
/auto <task>                      # implement → review → fix, until approved
                                  #   reviewed by a PANEL of every other agent by default
/auto --reviewers codex           # narrow it to one reviewer
/auto --plan <task>               # add an approach review first (high-stakes work)
/auto --rounds 3 <task>           # a tighter cap than the default 10

/ask codex <question>             # one-off consult, no loop, no verdict
/ask                              # "thoughts?" on the current discussion
```

**When to reach for `--plan`:** only when a wrong *approach* would be expensive to discover
after implementing — novel architecture, high blast radius, safety-critical. Most work
should let the implementation speak for itself.

**A panel is the default.** This tool is for work that wants that bar — every
registered agent except the driver reviews the same pinned artifact. They find
different things. A blocking finding two of them raise (same `path:line`) gates
the loop; a finding only one raises is flagged for you to cross-check rather than
obeyed automatically, so one noisy reviewer cannot cost you a round. Narrow with
`--reviewers` when you want speed over coverage.

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
- **Advisories survive.** On an approval, un-actioned advisory findings are appended to
  `docs/advisories.md` — a closing step in the loop's own instructions rather than something a
  helper enforces — and `comms.sh lessons` reads that file back into later rounds, so lessons
  compound instead of evaporating.
- **ACP is the default transport.** Reviewers run in the background; you do not babysit a
  pane. The `--via cmux` pane transport was deleted — asking for it is refused outright rather
  than silently downgraded to something you did not choose. Later rounds on the same thread
  reuse a stable mount path, so ACP can stay warm instead of starting a new session each time.
  A running turn is watchable in its run dir (`.comms/logs/<message>.<ts>.<pid>/runner.log`).

Message format, loop semantics, and the state model: **[docs/PROTOCOL.md](docs/PROTOCOL.md)**

## Requirements

- A git repository
- At least two agent CLIs. **`claude` and `codex` work out of the box.** `grok` is registered
  by default, but read the containment note below before relying on it.
- Node ≥ 22.13 for the ACP transport. Setting `ACPX_BIN` to an already-installed `acpx` skips
  the `npx` download, but the Node floor still applies.
- No pane multiplexer is required: loops run over ACP.

**A reviewer runs against a mounted copy of your tree, so it has to be contained.** `claude`
and `codex` have verified isolation backends and are constrained automatically — though not
identically: `codex` runs under its own kernel sandbox, while `claude`'s backend is measured
write-contained but still reaches the network, so treat it as "cannot modify your machine"
rather than "cannot phone home". **`grok` has no verified backend on any platform** — so a mounted grok review turn is refused rather than run
unconstrained, and a default panel including it will not complete. Two ways forward:

- narrow the roster: `/auto --reviewers codex`, or drop `grok` from `agents` in `.comms/config`
- or accept an uncontained reviewer deliberately: `export COMMS_RUNPHASE_ALLOW_UNCONTAINED=1`

Understand the second before using it. An uncontained turn can write outside its mount and
reach the network with your git credentials. That is a fair trade for reviewing your own code
on your own machine, and a poor one for anything you did not write.

## Docs

| | |
|---|---|
| [docs/COMMANDS.md](docs/COMMANDS.md) | the Claude Code commands and the helper CLI (not exhaustive — `panel`, `compose`, `round-note` and `friction` live only in `comms.sh help`) |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | message format, transports, state, archive discipline |
| [docs/loopspec/SPEC.md](docs/loopspec/SPEC.md) | the portable review-loop contract: verdicts, rounds, schemas, fixtures |
| [docs/INSTALL.md](docs/INSTALL.md) | install scopes, local pinning, upgrading |
| [docs/INTERNALS.md](docs/INTERNALS.md) | architecture, the template/helper split, test harness |
| [docs/ROADMAP.md](docs/ROADMAP.md) | decisions, field reports, what's next |
| [AGENTS.md](AGENTS.md) | contributing to agent-comms itself — for AI agents working on this repo (`CLAUDE.md` symlinks here) |

## License

MIT
