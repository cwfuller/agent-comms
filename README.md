# agent-comms

Autonomous code-review loops between AI coding agents. One agent implements, the
others review the same pinned artifact, and the loop runs until they approve.
No babysitting.

It exists because asking one agent to write code, then asking another to critique
it, then feeding the critique back produces markedly better results than either
alone. This is that loop, automated.

```
                 ┌─────────► other registered agents ──┐
  any driver ────┤  same artifact                      ├────► one composed verdict ──► fix ──► repeat
  (claude,       └─────────► on the panel              ┘        until approved
   codex, grok)
```

## Quick start

From your project's root:

```bash
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh \
  | bash -s -- --scope=both
```

Piping a script into a shell means running code you have not read. Prefer cloning
and inspecting first — the result is identical:

```bash
git clone https://github.com/cwfuller/agent-comms ~/src/agent-comms
less ~/src/agent-comms/install.sh
cd /path/to/your/project && bash ~/src/agent-comms/install.sh --scope=both
```

`--scope=both` writes driver commands/skills for Claude, Grok, and Codex, the
shared helpers, a Codex protocol note, and this project's `.comms/` mailboxes
(plus `.gitignore` entries). Nothing else.

Then drive from whichever agent you are in. Same task, different invocation:

| Driver | Run |
| --- | --- |
| Claude | `/auto add rate limiting to the API` |
| Grok | `/user:auto add rate limiting to the API` |
| Codex | `$auto add rate limiting to the API` |

Grok notes: bare `/auto` is Grok's own permission-mode built-in, so the global
install is `/user:auto`. A project pin is `/local:auto`. Codex notes: if you
have both a local pin (`.agents/skills/auto`) and a global install
(`~/.codex/skills/auto`), both can appear in the `$` selector — pick the one
you mean, or disable the other with `/skills`.

That's it. The driving agent implements, snapshots the tree, and every other
registered agent reviews **that same pinned artifact**. Shared blockers gate the
next round; unique ones are flagged for you. It repeats until they approve or it
hits the round cap (default 10 per phase).

Nothing else is required: no terminal panes, no second window. Review turns run
over ACP in the background.

## Everyday use

Invocation differs by driver (see the table above). The flags are the same:

```text
<auto> <task>                 # implement → review → fix, until approved
                              #   reviewed by a PANEL of every other agent by default
                              #   a query classifier may enable an approach review
<auto> --reviewers codex      # narrow it to one reviewer
<auto> --plan <task>          # force an approach review first (high-stakes work)
<auto> --no-plan <task>       # skip approach review even if the classifier would request one
<auto> --rounds 3 <task>      # a tighter cap than the default 10

<ask> codex <question>        # one-off consult, no loop, no verdict
<ask>                         # "thoughts?" on the current discussion
```

`<auto>` / `<ask>` mean `/auto` and `/ask` in Claude, `/user:auto` and
`/user:ask` in Grok (or `/local:…` for a pin), and `$auto` / `$ask` in Codex.

**When to reach for `--plan`:** only when a wrong *approach* would be expensive
to discover after implementing — novel architecture, high blast radius,
safety-critical. Most work should let the implementation speak for itself.
Without an explicit `--plan` / `--no-plan`, `comms.sh route` (TypeSafe Jev, when
`TYPESAFE_API_KEY` is set) may request the approach-review phase; it fails open
to "no plan" without a key. It never chooses a reviewer or a model.

**A panel is the default.** Every registered agent except the driver reviews the
same pinned artifact. They find different things. A blocking finding two of them
raise (same `path:line`) gates the loop; a finding only one raises is flagged
for you to cross-check rather than obeyed automatically, so one noisy reviewer
cannot cost you a round. Narrow with `--reviewers` when you want speed over
coverage.

Full command reference: **[docs/COMMANDS.md](docs/COMMANDS.md)**

## What makes the loops trustworthy

- **Every reviewer reads the same thing.** The tree is snapshotted when the
  request is sent and mounted for the reviewer, so a review is about a pinned
  artifact, not whatever you happened to be typing while it ran.
- **Messages are validated before delivery.** Malformed messages are refused,
  never half-processed. A failed delivery says so and is recoverable; it never
  looks like "the reviewer is just slow".
- **One noisy reviewer cannot hold the loop hostage.** A lone unsupported
  blocking finding is cross-checked, not automatically obeyed.
- **Nothing is silently dropped.** Composition keeps every finding, attributed
  to the reviewer who made it. An unanswered panel leg blocks the gate rather
  than counting as approval.
- **Advisories survive.** On an approval, un-actioned advisory findings are
  appended to `docs/advisories.md`, and `comms.sh lessons` reads that file back
  into later rounds, so lessons compound instead of evaporating.
- **ACP is the default transport.** Reviewers run in the background; you do not
  babysit a pane. The old `--via cmux` pane transport was deleted — asking for it
  is refused rather than silently downgraded. Later rounds on the same thread
  reuse a stable mount path so ACP can stay warm. A running turn is watchable in
  its run dir (`.comms/logs/<message>.<ts>.<pid>/runner.log`).

## Requirements

- A git repository
- At least two agent CLIs. **`claude` and `codex` work out of the box.** `grok`
  is registered by default, but read the containment note below before relying
  on it as a *reviewer*.
- Node ≥ 22.13 for the ACP transport. Setting `ACPX_BIN` to an already-installed
  `acpx` skips the `npx` download; the Node floor still applies.
- No pane multiplexer. Loops run over ACP.

**A reviewer runs against a mounted copy of your tree, so it has to be
contained.** `claude` and `codex` have verified isolation backends and are
constrained automatically, though not identically: `codex` runs under its own
kernel sandbox, while `claude`'s backend is measured write-contained but still
reaches the network. Read that as "was unable to modify the machine in our write
probes" rather than a kernel boundary — behavioural defence, and it does not
stop the reviewer phoning home.

**`grok` has no verified backend on any platform**, so a mounted grok *review*
turn is refused rather than run unconstrained, and a default panel that includes
it will not complete. Grok as a *driver* is fine. Two ways forward for review:

- narrow the roster: `<auto> --reviewers codex`, or drop `grok` from `agents` in
  `.comms/config`
- or accept an uncontained reviewer deliberately:
  `export COMMS_RUNPHASE_ALLOW_UNCONTAINED=1`

Understand the second before using it. An uncontained turn can write outside its
mount and reach the network with your git credentials. That is a fair trade for
reviewing your own code on your own machine, and a poor one for anything you did
not write.

## Docs

Start here if you are installing or driving a loop. The rest is for deeper
detail or for agents working *on* this repository.

| For you | |
| --- | --- |
| [docs/INSTALL.md](docs/INSTALL.md) | install scopes, local pinning, upgrading |
| [docs/COMMANDS.md](docs/COMMANDS.md) | driver commands (Claude, Grok, Codex) and the helper CLI |

| Deeper / for agents | |
| --- | --- |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | message format, transports, state, archive discipline |
| [docs/loopspec/SPEC.md](docs/loopspec/SPEC.md) | portable review-loop contract: verdicts, rounds, schemas, fixtures |
| [docs/INTERNALS.md](docs/INTERNALS.md) | architecture, the template/helper split, test harness |
| [docs/ROADMAP.md](docs/ROADMAP.md) | decisions, field reports, what's next |
| [AGENTS.md](AGENTS.md) | contributing to agent-comms itself (`CLAUDE.md` symlinks here) |

## License

MIT
