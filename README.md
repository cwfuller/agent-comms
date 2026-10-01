# agent-comms

Autonomous code-review loops between AI coding agents. One agent implements, the
others review the same pinned snapshot, and the loop repeats until they approve.

```
                 ┌─► other agents review ─┐
  any driver ────┤   the same snapshot    ├─► one composed verdict ─► fix ─► repeat until approved
  (claude, codex,└─► (a panel, by default)┘
   grok, gemini)
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
```

Needs git, Node >= 22.13 and an agent CLI (codex >= 0.159 for the default
GPT-6.1 Sol reviewer; `helpers/acp.sh doctor` checks it) — two or more for cross-model review
(`claude` and `codex` work out of the box); a lone agent is reviewed by its own
model. Gemini CLI >= 0.39 adds a fourth model family as a reviewer: enable it with
`agents = claude codex grok gemini` in `.comms/config` (or `comms.sh setup`). Clone-first
install, scopes and reviewer containment:
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
  from a versioned table: fast = GPT-6 Luna, balanced = GPT-6.1 Sol then GPT-6
  Sol, each falling back to GPT-5.6 when your codex is too old to serve it;
  strong = GPT-6 Astra, the frontier model. Low confidence keeps the default:
  GPT-6.1 Sol at xhigh, which needs codex >= 0.159 (an older codex is refused,
  not downgraded; `acp.sh doctor` says so). "Use max" runs GPT-6 Astra at ultra.

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

## Custom agents and model pins

Start an interactive coding session with `helpers/comms.sh launch <profile> [model-id]`.
OpenCode profiles support Build mode and the installed `/auto` and `/ask` skills.

### Gemini as a reviewer

`gemini` is a built-in agent beside `claude`, `codex` and `grok`, reviewing through the installed
Gemini CLI's ACP mode (`gemini --acp`) so it can gate Claude- or Codex-written work with a third
model family. It is opt-in: add it to the `agents =` line (`gemini-review` comes with it).

```text
<auto> --reviewers gemini         one Gemini reviewer
<auto> --reviewers codex,gemini   Codex plus Gemini
export COMMS_ACP_GEMINI_MODEL=gemini-3.5-flash COMMS_ACP_GEMINI_EFFORT=low   # pin a cheaper leg
helpers/acp.sh doctor             reports the Gemini CLI version and refuses one without --acp
```

Each review runs in an isolated `GEMINI_CLI_HOME` with the leg's model and thinking level bound
from [the policy map](docs/COMMANDS.md), and your existing login
keeps working (an API key in the environment, a keychain login, or the file-backed OAuth token,
which is copied in). A rate limit or a failed login is recorded as a failed turn with its reason
(`rate-limited`, `auth-failed`). Containment is Gemini's read-only `plan` mode (like Claude's, not a
kernel sandbox) and has not yet been measured against a live turn — see
[INSTALL](docs/INSTALL.md#reviewer-containment).

Use [operator-owned agent profiles](docs/AGENT_PROFILES.md) to name ACP agents, pin
models, and group reviewers by model family. OpenCode is an optional contained
review adapter; the guide includes a Venice/GLM example.

## License

MIT
