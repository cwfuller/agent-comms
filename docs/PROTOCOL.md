# Protocol reference

How agent-comms implements the review-loop contract: transport, state, delivery, and
archive mechanics. The **contract itself** — message frontmatter and validation rules,
message types, verdict semantics (including the `pass`/`fail` synonyms and the
`gate`/`merge` profiles), loop invariants, threading rules, the compounding entry
format, and the provider turn contract — lives in **[loopspec](loopspec/SPEC.md)**,
the portable kernel this repo shares with other consumers. `helpers/comms.sh`
enforces the validatable parts, and `docs/loopspec/check.sh` proves it against the
golden fixtures in the test harness.

## Directories

All paths are relative to the **main repo root** (worktree-safe — every helper resolves
through `git worktree list`, so messages land in one place no matter which worktree an
agent runs from):

```
.comms/
  config       agent registry (optional — see below; absent = claude + codex)
  to-<agent>/  each registered agent's inbox (to-claude/, to-codex/, to-grok/, …)
  archive/     processed messages (every agent moves its own inbox here)
  state/       per-thread loop state, JSON (written by comms.sh send)
```

The **agent registry** (`.comms/config`, line-oriented) declares who participates:

```
agents = claude codex grok
default-target = codex
```

Names are `[a-z][a-z0-9-]{1,15}` and must have a supported backend
(`comms.sh agents --supported`); duplicates, multi-word defaults, and unsupported
names are hard parse errors — an unrunnable agent must never accept mail. A missing
file means `agents = claude codex grok`, `default-target = codex` (zero-config
back-compat). Two authorities replaced the old two-party complements: a thread's
`awaiting_from` is the explicit `send --to` target, and `--archive-inbound` derives
the inbound's owner from the OUTBOUND message's `from:` (validated against the
directory the inbound actually occupies; already-archived is an idempotent no-op).

`.comms/` is gitignored — messages are local plumbing, not project history.

## Worktrees & branches

Loops often run in a `git worktree` (one per cmux workspace — see `/fleet`). Two rules
keep that safe:

**Message routing is worktree-safe.** Every helper resolves `.comms/` to the **main repo
root** via `git worktree list`, so all worktrees of one repo share a single mailbox. The
`cwd:` is the per-message "which tree" hint; `head_sha:` is the immutable fallback when
that path or branch was repurposed before a delayed delivery. Readers enter `cwd`, compare
the current HEAD when `head_sha` is present, and locate the recorded commit/worktree
instead of silently reviewing unrelated contents.

**Push safety — create worktrees on their own branch, never on `main`.** The common
footgun: an agent working in a worktree runs `git push` and it lands on `main` instead of
the feature branch (because the worktree was checked out on `main`, or the branch was set
to track/push to `main`). When creating a worktree for a loop:

- **Make a dedicated branch, don't check out `main`:** `git worktree add -b <feature-branch> <path>`
  (`-b` starts a fresh branch with **no upstream** — keep it that way; never set its
  upstream to `main`).
- **Keep a bare `git push` from straying to `main`:** `git config push.default current`
  so `git push` only ever updates a remote branch of the *same name* as the current one
  (combined with the rule above — never be checked out on `main` in a loop worktree — this
  means a feature-branch push can't land on `main`).
- **First push is explicit and self-scoped:** `git push -u origin HEAD` (pushes the current
  branch to a same-named remote branch and sets its upstream). Never
  `git push origin <x>:main`, and never push while the worktree is checked out on `main`.

## Filenames

```
<workspace>_<YYYY-MM-DDTHH-MM-SS>_<slug>-<random>.md
```

- `workspace` scopes messages when several workspaces share one repo (cmux workspace
  name → git branch → repo dir, lowercased/hyphenated — both sides resolve it via the
  same `comms.sh workspace` so they can never disagree)
- the `<random>` suffix prevents same-second collisions
- readers list with `comms.sh list --as <agent>`, newest first

## Frontmatter

```markdown
---
type: review-request            # see the type table in loopspec/SPEC.md
from: claude                    # any REGISTERED agent — validate rejects others
timestamp: 2026-06-04T18:30:14Z
branch: main
head_sha: <git rev-parse HEAD>  # immutable context for delayed delivery
workspace: agent-comms
cwd: /path/to/working/dir       # worktree hint — reader cds here before touching files
message_id: <filename sans .md>
thread: rate-limiter-9331       # names the loop; constant across ALL its messages
in-reply-to: <message_id>       # when replying
workflow: auto                  # presence triggers autonomous mode (value is free-form)
phase: plan | implement
round: 2
max-rounds: 4
verdict: APPROVE | REQUEST_CHANGES   # reviewer replies only; read normalized
---
```

**Validation rules, message types, verdict semantics, and the loop invariants are
normative in [loopspec/SPEC.md](loopspec/SPEC.md)** — enforced here by
`comms.sh validate` (run by `send` before any delivery). agent-comms specifics on top
of the contract:

- Read verdicts through `comms.sh verdict <file>` — it normalizes (trim, uppercase)
  and maps the canonical synonyms (`pass` → `APPROVE`, `fail` → `REQUEST_CHANGES`),
  so `verdict:  approve ` or `verdict: fail` still steer a loop correctly.
- The reviewer-must-carry-a-verdict rule binds by TYPE — every workflow
  `review-feedback` message needs a `verdict`, whichever agent sent it (reverse-
  topology loops have Claude as the reviewer).
- On final `APPROVE`: un-actioned advisories append to `docs/advisories.md` and
  `### Process` feedback to the friction log; `comms.sh state complete <thread>`
  closes the loop's state.

## Threading

`thread` exists because two agents can run loops in the **same workspace**
simultaneously — without it, "read the newest message" lets one loop consume and
archive the other's review round (observed in the field). The threading rules
(opener mints the thread; every message copies it; `message_id`/`in-reply-to` chain
reconstruction) are in [loopspec/SPEC.md](loopspec/SPEC.md); operationally, continue
a specific loop with `comms.sh list --as <agent> --thread <t>`.

## State files

`comms.sh send` automatically writes `.comms/state/<workspace>_<thread>.json` for any
workflow message (filename components sanitized to `[A-Za-z0-9._-]`; workspace is the
**resolved** name, not the frontmatter copy, so readers and writers can't diverge):

```json
{
  "workspace": "agent-comms",
  "thread": "rate-limiter-9331",
  "workflow": "auto",
  "phase": "implement",
  "round": "2",
  "max_rounds": "10",
  "status": "in-progress",          // → "complete" via `state complete <thread>`
  "awaiting_from": "codex",         // who owes the next message; "none" when complete
  "awaiting_since": "2026-06-04T18:30:14Z",
  "awaiting_since_epoch": "1780597814",
  "last_sent": "<message_id>",
  "last_notified_at": "2026-06-04T18:30:16Z", // external recovery only
  "last_delivery": "delivered"      // delivered | manual | failed | blocked
                                    // headless adds: spawned → completed | failed
                                    // | timeout, plus held and pickup (see
                                    // loopspec/thread-state.schema.json for the
                                    // full enum)
}
```

Headless turns (see [Headless delivery](#headless-delivery-experimental)) add fields:
`last_run_dir` (written by `send` at spawn time — the watchdog's pid target) and, on
exit, the provider session id — `codex_thread_id` or `claude_session_id`, captured
from the turn's event log and printed by `runphase.sh hold` as the attach command.
Note the state copies are transient: the next round's `send` rewrites the state file
and drops them. The durable copy lives in the run dir's `result.json`; treat the state
fields as observability and attach plumbing, not yet as automatic cross-round resume
(that is a planned opt-in, not wired).

State is **advisory ground truth**: it survives compaction/restarts, records and
surfaces the loop's round/max-rounds (enforcement itself happens in the reading agent's
flow, from message frontmatter), and gives `/fleet` a source of truth beyond pane
titles — but a state write failure can never block the message flow (writes are
non-fatal by construction).

Inspection: `comms.sh state list | get <thread> | complete <thread>`, and
`comms.sh stalled [minutes]` lists threads awaiting a reply longer than the threshold
(default 15m) and marks a matching file still in the target inbox as `inbox=unread`.
That persisted-file evidence outranks a prior notification result.

## Delivery

With cmux available, `comms.sh deliver <target>` resolves the target surface in order:

1. **binding** — an explicit `comms.sh bind <target> surface:N`, or the surface cached
   from the last successful delivery. Verified against the live tree when the tree is
   readable; **if the tree read itself fails, a binding is used optimistically** — a
   dead surface then fails the send sequence loudly (`RESULT: failed`, retryable),
   which beats discarding a known target over a transient tree hiccup. Residual risk,
   accepted: if cmux ever *reuses* a surface id for a different terminal while the tree
   is unreadable, an optimistic send would land there and report `delivered` — identity
   simply cannot be verified without a tree
2. **pane-aware pick** — the *first* terminal surface (tree order = tab order) in a pane
   other than the caller's, falling back to the first other terminal anywhere

Every path that ends in "no surface" emits a stderr diagnostic naming the target,
workspace id, binding state, and what the tree contained — a manual outcome is always
explainable. `comms.sh status` adds an `ACTION NEEDED` line whenever the newest thread's
last delivery wasn't a real nudge.

Convention when a workspace has several Claude/Codex tabs: **keep the live agent as the
first tab in its pane**, or set an explicit binding — the picker cannot know agent
identity from the tree alone. Delivery output names the chosen surface and why
(`delivered to surface:146 (bound)`), so a wrong target is visible immediately.

It then types the read command into the chosen surface:

- → Codex: `$read-from-claude` + enter
- → Claude: `escape, i, /read-from-codex, escape, enter` (assumes vim mode)

The cmux path's explicit outcomes, recorded in state by `send` (headless delivery
adds its own — see [Headless delivery](#headless-delivery-experimental); the full
enum lives in `loopspec/thread-state.schema.json`):

| outcome | meaning | recovery |
|---|---|---|
| `delivered` | full keystroke sequence accepted; peer pickup remains asynchronous | `stalled`/`status` expose aged unread files |
| `manual` | no cmux / no surface — message valid on disk | trigger the read command by hand |
| `blocked` | this session cannot access `cmux.sock`; peer was not notified | configure the global `workspace-cmux` profile for new sessions; use `RECOVER:` only from a host-capable context, otherwise trigger one manual pickup |
| `failed` | cmux error mid-sequence | retry with `comms.sh send` (refreshes state); a bare `deliver` retry works but leaves the stale `failed` marker |

**Atomic send:** `comms.sh send --to <agent> <file> --archive-inbound <inbound>`
validates the outbound (refusing to deliver or archive if malformed), attempts delivery,
records state, and only then archives the inbound. A failed nudge still archives — the
inbound *was* processed; the retry surface is delivery, tracked in state.

`send` always ends with a `RESULT:` line. On `blocked`, it also emits one copy/paste
`RECOVER:` command composed of direct `cmux` calls plus
`comms.sh reconcile <message>`. The reconciliation segment runs only after every cmux
step succeeds, so a host-side fallback cannot leave `last_delivery=blocked`. A blocked
Codex session must not run the same path repeatedly or claim the peer passively polls:
configure the global profile printed by `comms.sh codex-permissions`, restart Codex, or
use one manual pickup for the already-persisted message.

**Identity resilience:** workspace resolution caches one good cmux-derived name per
cmux workspace (`.comms/.cache/`); if a later `cmux tree` read is unavailable or its
shape is unparseable, the cached identity is reused instead of flapping to a branch-name
fallback. The parser accepts the current selection/active markers and UUID-valued
`CMUX_WORKSPACE_ID`; the tree fetch itself retries before giving up.

**Late nudges are normal.** The injected read command sits in the target's input box
until its current turn ends — sometimes minutes. If the reply was already consumed by
then (e.g. by a file watcher), the late `/read-from-codex` finds an empty inbox; readers
report "latest archived: X — already processed" instead of a confusing "no messages".
That archive hint is filtered by workspace, reader direction, and optional thread, then
ordered by protocol timestamp with mtime fallback; an unrelated older round cannot win
because of filename order.

## Headless delivery (experimental)

`COMMS_DELIVERY=headless` replaces the keystroke nudge with a detached subprocess:
`deliver <target>` hands the message to `runphase.sh`, which spawns the target
provider's CLI in the background — `codex exec --json` for Codex, `claude -p
--verbose --output-format stream-json` for Claude — records the run under
`.comms/logs/<message_id>.<epoch>.<pid>/` (`prompt.md`, `events.ndjson` JSONL event
log, `result.json`, `pid`, `runner.log`), and mirrors the outcome into thread state
on exit. cmux is never touched; identity is a process handle, not a pane guess.
A loop is unattended work and should not require an open pane. Since 2026-08-26 the loop default is **ACP** (a warm per-thread session, ~1k fresh input tokens per round against ~115k for a cold headless spawn); headless is the fallback when ACP is unavailable, and cmux is opt-in via `--via cmux` / `COMMS_DELIVERY=cmux`. Consults prefer a live pane and fall back to ACP.

**Direction awareness.** Replies TO the driving session are a designed no-op: the
driver reads them when the peer turn exits, so nothing is spawned for that
direction. runphase marks it by exporting `COMMS_HEADLESS_PICKUP=<driver>` into the
child's environment; `deliver` no-ops when the target matches. Either agent can
drive: a Claude session sending to codex spawns a headless Codex turn whose replies
are picked up, and an interactive Codex sending to claude spawns a headless Claude
turn symmetrically.

**Claude turns** run with `CLAUDECODE` unset (so the child does not detect itself as
nested inside the driving session) and a non-bypass permission policy:
`--permission-mode acceptEdits --allowedTools Bash` by default, overridable via
`COMMS_RUNPHASE_CLAUDE_PERMISSION_MODE` / `COMMS_RUNPHASE_CLAUDE_ALLOWED_TOOLS` /
`COMMS_RUNPHASE_CLAUDE_ARGS`. Bypass/danger permission flags
(`--dangerously-skip-permissions`, `bypassPermissions`) are **refused** in loop
turns by policy: a novel permission need surfaces as a failed turn and gets a
scoped policy addition, never a blanket bypass.

Additional delivery outcomes in headless mode:

| outcome | meaning | recovery |
|---|---|---|
| `spawned` | peer turn running detached | `runphase.sh await <run-dir>`; reply appears in the inbox when it exits |
| `completed` | turn exited 0; reply should be in the inbox | read it |
| `failed` | provider CLI exited non-zero, or the runner aborted (its exit trap still records the failure) | inspect `events.ndjson`/`runner.log`; re-send to retry |
| `timeout` | turn killed after `COMMS_RUNPHASE_TIMEOUT_SECS` (default 1800) | raise the limit or investigate, then re-send |
| `held` | a hold marker paused the thread; nothing spawned | `runphase.sh release <thread>`, then re-send |
| `pickup` | designed no-op: a peer turn's reply to its driving session (`RESULT:` still reads `manual — …picks it up…` for the peer's expectations) | none — the driver reads the reply when the turn exits |

A runner killed with `kill -9` can write nothing, so state stays `spawned` forever; the
surfaces for that residual are `runphase.sh await` (detects the dead pid and says so)
and `comms.sh stalled`, whose **watchdog** uses the `last_run_dir` recorded in state to
distinguish "runner alive — still working", "turn finished — reply may be unread", and
"runner DEAD without a result — re-send to retry". Re-delivery is guarded: `deliver`
for a message whose runner is still alive reports "already running" and points at the
existing run dir instead of double-spawning a concurrent turn; a dead runner without a
result is retryable as usual.

**Pause/attach (hold).** `runphase.sh hold <thread>` (or `hold` with no argument for
everything) blocks NEW turns at the next turn boundary — in-flight turns finish — and
prints the exact attach commands recorded in thread state (`claude --resume
<claude_session_id>` from the loop's cwd; `codex resume <codex_thread_id>`). Sends on
a held thread report `RESULT: held`; after `release`, RE-SEND rather than bare-deliver
so state moves off `held`. Two scoping notes: per-thread holds do not block
thread-less one-shot messages (use the no-argument hold for a full stop), and bare
`deliver` resolves only the newest pending message — a held thread's newest message
shadows retries for other threads, so pass an explicit file to retry a specific one.

The spawned peer is pre-briefed that its reply `send` will report `RESULT: manual` and
that this is expected — the driving session picks the reply up when the turn ends.

Sandbox: a Codex turn runs `codex exec -s workspace-write` from the message's `cwd` (or
the main repo root); a Claude turn relies on its permission policy. For worktree turns,
`.comms/` and the main `.git/` are added via `--add-dir` so the reply and branch
operations succeed. The spawned turn inherits `COMMS_DELIVERY=headless` so nothing in
the child can reach for cmux.

## Archive discipline

Each agent archives **only its own inbox** (`comms.sh archive --as <self>` enforces
this), idempotently — an already-archived file is a no-op, never an error. The shared
`archive/` is the loop's audit trail; `/fleet` reads its newest entry per workspace to
infer loop completion (a normalized approving verdict — `APPROVE`, or its canonical
synonym `pass` — is the only completion signal).
