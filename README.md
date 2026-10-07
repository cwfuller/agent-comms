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
model. The Antigravity CLI (`agy` >= 1.3.1) adds a fourth model family as a reviewer: enable it with
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

`gemini` is a built-in agent beside `claude`, `codex` and `grok`, reviewing and answering consults through
Google's Antigravity CLI (`agy`, >= 1.3.1), which replaced the retired Gemini CLI, so it can gate Claude- or
Codex-written work with a third model family. agy has no ACP mode, so agent-comms runs it directly, one
non-interactive turn at a time. It is opt-in: add it to the `agents =` line (`gemini-review` comes with it).

```text
<auto> --reviewers gemini         one Gemini reviewer
<auto> --reviewers codex,gemini   Codex plus Gemini
export COMMS_ACP_GEMINI_MODEL=gemini-3.8-flash COMMS_ACP_GEMINI_EFFORT=low   # pin a cheaper leg
helpers/acp.sh doctor             reports the agy version and refuses one older than 1.3.1
```

The leg's model and effort come from [the policy map](docs/COMMANDS.md) (gemini-3.8-flash at `high` by
default) and are passed as agy's `<model>-<effort>` id; agy's own `init` event names that id back, and a review
whose turn ran anything else is withheld. agy runs in your real home, because its login cannot be staged into an
isolated one, so it uses the account you are already signed in with. A rate limit or quota refusal is recorded as a
failed turn with reason `rate-limited` (and quota state `refused`); a model your account is not entitled to
(`SUBSCRIPTION_REQUIRED`, seen for gemini-3.8-flash on some accounts) is `model-unavailable`, and a failed login
is `auth-failed`. When 3.8 Flash is not served to you, pin `COMMS_ACP_GEMINI_MODEL=gemini-3.1-pro` and
`COMMS_ACP_GEMINI_EFFORT=high`. Containment is agy's read-only `plan` mode plus the mount's tree-identity check
(not a kernel sandbox) — see [INSTALL](docs/INSTALL.md#reviewer-containment).

Use [operator-owned agent profiles](docs/AGENT_PROFILES.md) to name ACP agents, pin
models, and group reviewers by model family. OpenCode is an optional contained
review adapter; the guide includes a Venice/GLM example.

### Exact per-leg binding (for a caller that picks the model)

A caller that has already decided each reviewer's exact **model**, **native effort** and
**expected access profile** (account, billing class, credential reference) can have
`panel dispatch --bindings FILE` run exactly that — or refuse the whole dispatch, with a code per
leg, before any snapshot, event or leg file is written. agent-comms never reclassifies a tier or
chooses a route in this mode. Each agent has one immutable access profile in
`~/.agent-comms/access.json`; a bound leg's environment is credential-scrubbed and gets only its
own route's credential. See [AGENT_PROFILES](docs/AGENT_PROFILES.md#access-profiles-accessjson)
and [COMMANDS](docs/COMMANDS.md): `review-route capability`, `review-route plan --bindings`,
`agents --access`. Existing invocations are unchanged.

## License

MIT
