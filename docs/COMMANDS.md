# Command & helper reference

Every Claude Code command, Codex skill, and helper subcommand. Commands are thin
prompt-wrappers; the shell logic lives in the installed helpers (see
[INTERNALS.md](INTERNALS.md) for why).

## Claude Code commands

### `/auto-implement [N] <task>`

Implement → send to Codex → fix blocking findings → repeat until `APPROVE` or `N`
rounds (default 10). The task text can describe work or reference an existing plan file.
Round messages keep stable context (latest findings bundle + `git diff --stat` +
validation results), never per-finding fix narration.

### `/auto-plan [N] <task>`

Same loop for a plan: draft → review → refine until approved. Each round re-sends the
full updated plan so the reviewer re-reads fresh.

### `/auto-full [N] <task>`

`/auto-plan` then `/auto-implement`, chained: when the plan phase gets `APPROVE`,
implementation starts automatically at `round: 1` (same `thread`, `phase: implement`).
`N` caps each phase separately.

### `/ask-codex <question> [--with-diff] [--with-files a,b]`

One-off judgment call — no review framing, no loop, no verdict. Body carries
`## Question` (verbatim), optional `## Context` / `## Current Thinking` (your draft take
so Codex refines rather than starts blank), and `## Grounding` when `--with-diff`
(attaches `git diff <default-branch> --stat`) or `--with-files` is set. Codex answers
with `type: response`: `## Summary` + `## Codex Take`. Follow-ups are a new `/ask-codex`.

### `/send-to-codex [instructions]`

One-shot review request for work you just did: gathers diff stat, recent commits, and
plan context; writes a `review-request`; validates + delivers. Extra argument text
becomes review-focus instructions.

### `/read-from-codex [filter]`

List and act on pending messages. Manual flow (no `workflow` field): summarize, archive,
ask how to proceed. Autonomous flow: enforce verdict/round semantics (see
[PROTOCOL.md](PROTOCOL.md#loop-semantics)), reply, atomically archive. An empty inbox
reports the latest archived message — a late delivery nudge for an already-processed
reply is common and harmless. Filter argument: "only the latest", "all messages", a
filename, or a thread.

### `/clean-comms [workspace|all|archive|<filename>]`

Guarded cleanup via `comms.sh clean` — always dry-runs first, deletes only after you
confirm (`--yes`). Default `workspace` mode touches **your inbox + archive only**; `all`
is the only mode that deletes the other agent's unread mail.

### `/fleet <subcommand>`

Orchestrate execution workspaces (`ws-1`, `ws-2`, …) from a control workspace. Each
execution workspace = Claude pane (1) + Codex pane (2).

| subcommand | effect |
|---|---|
| `status` | per-workspace table: pane states (braille-spinner detection), latest archive round/verdict, pending counts, `owes=<agent> <N>m` from thread state |
| `dispatch <ws> <brief> [--plan-first] [--force]` | `/new` both panes, fire `/auto-implement <brief>` (`--plan-first` → `/auto-full`); refuses a busy target unless `--force` |
| `dispatch-all <brief...> [--plan-first] [--force] [--yes]` | map briefs onto free workspaces (idle + approved-or-never-dispatched + no unread mail); dry-run without `--yes`; re-validates each target at fire time |
| `harvest` | list workspaces idle + approved — ready for the next brief |
| `clear <ws>` | `/new` both panes |

Env: `FLEET_PREFIX` (default `ws`), `FLEET_MAX` concurrency cap (default 3 — protects a
shared working tree; bump it if each workspace has its own `git worktree add`).

## Codex skills

### `$read-from-claude`

Mirror of `/read-from-codex` for Codex's inbox. In autonomous mode it reviews
immediately (no user prompt): round 1 = full contextual review; round 2+ = holistic
re-review with a blank checklist; every round runs the implement checklist
(auth/state-transitions/entry-points/async/tests); final round adds a broad quality
sweep. Verdict bar: default `APPROVE`; `REQUEST_CHANGES` only for ship-stopping issues.

### `$send-to-claude`

Write findings (`### Blocking` / `### Advisory` / `### Process`), copy the loop's
workflow fields + `thread`, set `in-reply-to`, then atomically validate + deliver +
archive the inbound via `comms.sh send`.

**Codex sandbox note:** `send`/`deliver` touch the cmux socket (`cmux.sock`), which is
outside a restricted Codex sandbox. The skills tell Codex to run those two commands
through its approved shell wrapper (`/bin/zsh -lc '...'`) **from the start** — read-only
commands (`list`/`validate`/`archive`) run directly. On an `Operation not permitted`
socket error the rule is: retry via the wrapper, never request escalation (escalation is
what produces the user's prompt); the helper itself prints the exact wrapper line on that
failure. A permission prompt is an invocation issue, never a protocol failure. If Codex
keeps prompting, the guidance is being ignored or the installed skills are stale.

## Helper CLI

Installed at `~/.agent-comms/` (or `<repo>/.agent-comms/` for pinned local installs).
Both agents — and you — can call these directly; they're plain bash, caller-shell
agnostic.

### `comms.sh`

| subcommand | effect |
|---|---|
| `root` | print the main repo's `.comms` path (worktree-safe) |
| `workspace` | print the resolved workspace name (cmux → branch → repo dir) |
| `list --as <claude\|codex> [--thread <t>]` | pending inbox messages, newest first; non-zero + "latest archived" hint when empty |
| `status` | one-screen loop summary: workspace, latest archived message + its loop fields, pending counts per inbox |
| `validate <file>` | frontmatter/body checks; reasons on stderr, non-zero on failure |
| `verdict <file>` | normalized (trimmed, uppercased) verdict |
| `archive --as <claude\|codex> <file...>` | idempotent move to `archive/`; refuses files outside your own inbox |
| `deliver <claude\|codex>` | cmux pane nudge; prints `delivered to <surface> (<how>)` / manual-pickup / `blocked` (sandboxed socket) / `FAILED` explicitly |
| `send --to <claude\|codex> <file> [--archive-inbound <file>]` | validate → deliver → record state → archive inbound, atomically; ends with a loud `RESULT:` line (`delivered`/`manual`/`blocked`/`failed`) |
| `bind <claude\|codex> [surface:N]` | pin which surface delivery targets (show current with no arg); successful deliveries auto-refresh it; ignored if the surface disappears |
| `state list \| get <thread> \| complete <thread>` | thread state inspection / closure |
| `stalled [minutes]` | threads awaiting a reply longer than the threshold (default 15) |
| `clean --as <claude\|codex> [mode] [--yes]` | guarded delete; dry-run without `--yes` |

### `fleet.sh`

Same subcommands as `/fleet` above — the command template is a thin wrapper over this
script. `fleet.sh help` prints usage.

## Typical sessions

```text
# autonomous feature, single workspace
/auto-full 5 add CSV export to the reports page

# quick design consult while implementing
/ask-codex --with-diff is the retry/backoff approach here sound?

# fan five briefs across a fleet
/fleet status
/fleet dispatch-all briefs/a.md briefs/b.md briefs/c.md briefs/d.md briefs/e.md
# review the mapping, then confirm: "yes fire all"

# loop seems quiet?
~/.agent-comms/comms.sh stalled
```
