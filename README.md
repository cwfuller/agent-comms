# agent-comms

Autonomous code-review loops between AI coding agents. One agent implements, the
others review the same pinned snapshot, and the loop repeats until they approve.

```
                 ┌─► other agents review ─┐
  any driver ────┤   the same snapshot    ├─► one composed verdict ─► fix ─► repeat until approved
  (claude, codex,└─► (a panel, by default)┘
   grok)
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
```

Needs git, Node >= 22.13 and an agent CLI — two or more for cross-model review
(`claude` and `codex` work out of the box); a lone agent is reviewed by its own
model. Clone-first install, scopes and reviewer containment:
[docs/INSTALL.md](docs/INSTALL.md).

Then run `~/.agent-comms/comms.sh setup` (re-runnable): it detects your agents and
saves [settings](docs/INSTALL.md#settings-commssh-setup), so nothing depends on shell exports.

## Use

| Driver | Run |
| --- | --- |
| Claude | `/auto add rate limiting to the API` |
| Grok | `/user:auto add rate limiting to the API` |
| Codex | `$auto add rate limiting to the API` |

```text
<auto> <task>               implement → panel review → fix, until approved (10 rounds max)
<auto> --reviewers codex    one reviewer instead of the whole panel
<auto> --reviewers claude,codex
                            name yourself to add your own model: from Claude this
                            is Claude plus Codex (your built-in claude-review
                            twin reviews; no config). One reviewer per model.
<auto> --plan <task>        approach review first, for high-stakes work
<auto> --max <task>         deepest Codex review: strongest model, highest effort
<ask> codex <question>      one-off consult, no loop
```

Every flag and the helper CLI: [docs/COMMANDS.md](docs/COMMANDS.md).

## Why you can trust the verdict

- **Pinned artifact.** Every reviewer reads the same snapshot, not your live tree.
- **Corroboration gates.** A blocker two reviewers raise blocks, as do the gating
  (first) reviewer's; any other lone blocker is flagged for you to cross-check,
  so one noisy reviewer cannot stall the loop.
- **Nothing silently dropped.** Malformed messages are refused, an unanswered
  reviewer blocks the gate, and leftover advisories feed later rounds.
- **Proven review depth.** Each Codex review is checked against the model and
  effort Codex itself logged; a review at the wrong depth is never published.

How: [docs/PROTOCOL.md](docs/PROTOCOL.md), [docs/INTERNALS.md](docs/INTERNALS.md).

## Model routing (optional)

A classifier (Jev, via TypeSafe) sizes the work so easy things run cheap:

- **The loop:** decides whether a task needs an approach review first.
- **Reviewers:** picks each Codex reviewer's model tier and effort per thread
  from a versioned table (fast / balanced = GPT-6 Luna / Sol when your installed
  codex is new enough, else GPT-5.6 Luna / Terra; strong = GPT-6 Astra). Low
  confidence keeps the default depth.

Off by default. `comms.sh setup` turns it on (TypeSafe key, then per-project
permission before any review text is sent); `--no-route` turns it off for one loop. Details:
[`route` / `review-route`](docs/COMMANDS.md),
[reviewer routing](docs/INTERNALS.md#reviewer-modeleffort-routing),
`acp.sh doctor`, `acp.sh capabilities`.

## Docs

| | |
| --- | --- |
| [INSTALL](docs/INSTALL.md) | install, requirements, containment, upgrading |
| [COMMANDS](docs/COMMANDS.md) | driver commands and the helper CLI |
| [PROTOCOL](docs/PROTOCOL.md) | message format, transports, state |
| [loopspec](docs/loopspec/SPEC.md) | the portable review-loop contract |
| [INTERNALS](docs/INTERNALS.md) | architecture and the reasoning behind it |
| [ROADMAP](docs/ROADMAP.md) | decisions, field reports, what's next |
| [AGENTS.md](AGENTS.md) | contributing to agent-comms itself |

## License

MIT
