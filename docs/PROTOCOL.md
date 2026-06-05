# Protocol reference

The message format, loop semantics, and state model both agents follow. This is the
spec — the command templates and skills implement it, and `helpers/comms.sh` enforces
the validatable parts.

## Directories

All paths are relative to the **main repo root** (worktree-safe — every helper resolves
through `git worktree list`, so messages land in one place no matter which worktree an
agent runs from):

```
.comms/
  to-codex/    Claude writes → Codex reads   (Codex's inbox)
  to-claude/   Codex writes → Claude reads   (Claude's inbox)
  archive/     processed messages (both sides move their own inbox here)
  state/       per-thread loop state, JSON (written by comms.sh send)
```

`.comms/` is gitignored — messages are local plumbing, not project history.

## Filenames

```
<workspace>_<YYYY-MM-DDTHH-MM-SS>_<slug>-<random>.md
```

- `workspace` scopes messages when several workspaces share one repo (cmux workspace
  name → git branch → repo dir, lowercased/hyphenated — both sides resolve it via the
  same `comms.sh workspace` so they can never disagree)
- the `<random>` suffix prevents same-second collisions
- readers list with `comms.sh list --as <claude|codex>`, newest first

## Frontmatter

```markdown
---
type: review-request            # see type table below
from: claude | codex
timestamp: 2026-06-04T18:30:14Z
branch: main
workspace: agent-comms
cwd: /path/to/working/dir       # worktree hint — reader cds here before touching files
message_id: <filename sans .md>
thread: rate-limiter-9331       # names the loop; constant across ALL its messages
in-reply-to: <message_id>       # when replying
workflow: auto-implement        # presence triggers autonomous mode
phase: plan | implement
round: 2
max-rounds: 10
verdict: APPROVE | REQUEST_CHANGES   # reviewer replies only; read normalized
---
```

Validation (`comms.sh validate`, enforced by `send` before any delivery):

| Rule | Severity |
|---|---|
| `---` delimiters intact, body non-empty | error |
| `type`, `from`, `timestamp` present | error |
| `workflow` present ⇒ `phase`, `round`, `max-rounds` present | error |
| workflow reply from codex (type ≠ `error`) ⇒ `verdict` present | error |
| workflow message without `thread` / `message_id` | warning (stderr) — soft so in-flight pre-v2 loops survive upgrades |

Read verdicts through `comms.sh verdict <file>` — it trims and uppercases, so
`verdict:  approve ` still terminates a loop.

## Message types

| type | direction | meaning |
|---|---|---|
| `review-request` | → reviewer | "review this plan/diff"; carries workflow fields in loops |
| `review-feedback` | reviewer → | findings + `verdict` |
| `question` | → reviewer | one-off consult (`/ask-codex`); no workflow, no verdict |
| `response` | reviewer → | answer to a `question` (no verdict) or manual follow-up |
| `ping` | either | connectivity test |
| `request` | either | freeform ask outside a loop |
| `error` | either | "your last message was malformed — resend." Verdict-free, copies the loop fields, and **never consumes a round**: the sender of the bad message resends corrected at the same `round` |

## Loop semantics

- `round` counts **review passes**. Claude sends round 1; if Codex replies
  `REQUEST_CHANGES`, Claude fixes and sends round 2; the loop ends on `APPROVE`
  or when `round` reaches `max-rounds` (then it escalates to the human).
- **Verdict discipline:** `REQUEST_CHANGES` is for blocking issues only (correctness,
  security, data loss, broken flows). Advisory notes ride along with `APPROVE` and never
  force another round.
- **Stable context, not fix narration:** a round-N reply carries the previous findings as
  context plus the current plan/diff — never a per-finding "fixed it" checklist, which
  anchors the reviewer on verification instead of fresh review. Round 2+ reviews are
  holistic re-reads with a blank checklist.
- **`auto-full` phase transition:** an `APPROVE` on `phase: plan` archives the approval
  *first* (prevents a stale re-read double-firing implementation), then starts
  `phase: implement` at `round: 1` with the same `thread`.
- **On final `APPROVE`:** un-actioned advisories are appended to `docs/advisories.md`
  (date, thread, items) and `### Process` feedback to the friction log — then
  `comms.sh state complete <thread>` closes the loop's state.
- **Meta channel:** loop messages carry a standing `## Meta` section inviting the
  reviewer to flag friction with the comms process *itself* under `### Process` in its
  reply. Process feedback never gates the verdict.

## Threading

`thread` exists because two agents can run loops in the **same workspace**
simultaneously — without it, "read the newest message" lets one loop consume and archive
the other's review round (observed in the field). Rules:

- the loop opener mints `thread` (task slug + the filename's random suffix) and every
  subsequent message copies it verbatim
- continuing a specific loop, read with `comms.sh list --as <agent> --thread <t>`
- `message_id` = filename sans `.md`; replies set `in-reply-to` so any message's chain
  can be reconstructed from the archive

## State files

`comms.sh send` automatically writes `.comms/state/<workspace>_<thread>.json` for any
workflow message (filename components sanitized to `[A-Za-z0-9._-]`; workspace is the
**resolved** name, not the frontmatter copy, so readers and writers can't diverge):

```json
{
  "workspace": "agent-comms",
  "thread": "rate-limiter-9331",
  "workflow": "auto-implement",
  "phase": "implement",
  "round": "2",
  "max_rounds": "10",
  "status": "in-progress",          // → "complete" via `state complete <thread>`
  "awaiting_from": "codex",         // who owes the next message; "none" when complete
  "awaiting_since": "2026-06-04T18:30:14Z",
  "awaiting_since_epoch": "1780597814",
  "last_sent": "<message_id>",
  "last_delivery": "delivered"      // delivered | manual | failed
}
```

State is **advisory ground truth**: it survives compaction/restarts, records and
surfaces the loop's round/max-rounds (enforcement itself happens in the reading agent's
flow, from message frontmatter), and gives `/fleet` a source of truth beyond pane
titles — but a state write failure can never block the message flow (writes are
non-fatal by construction).

Inspection: `comms.sh state list | get <thread> | complete <thread>`, and
`comms.sh stalled [minutes]` lists threads awaiting a reply longer than the threshold
(default 15m) — the recovery surface for dropped nudges.

## Delivery

With cmux available, `comms.sh deliver <target>` resolves the target surface in order:

1. **binding** — an explicit `comms.sh bind <target> surface:N`, or the surface cached
   from the last successful delivery — used only if it still exists in the tree
2. **pane-aware pick** — the *first* terminal surface (tree order = tab order) in a pane
   other than the caller's, falling back to the first other terminal anywhere

Convention when a workspace has several Claude/Codex tabs: **keep the live agent as the
first tab in its pane**, or set an explicit binding — the picker cannot know agent
identity from the tree alone. Delivery output names the chosen surface and why
(`delivered to surface:146 (bound)`), so a wrong target is visible immediately.

It then types the read command into the chosen surface:

- → Codex: `$read-from-claude` + enter
- → Claude: `escape, i, /read-from-codex, escape, enter` (assumes vim mode)

Three explicit outcomes, recorded in state by `send`:

| outcome | meaning | recovery |
|---|---|---|
| `delivered` | full keystroke sequence accepted | — |
| `manual` | no cmux / no surface — message valid on disk | trigger the read command by hand |
| `failed` | cmux error mid-sequence | retry with `comms.sh send` (refreshes state); a bare `deliver` retry works but leaves the stale `failed` marker |

**Atomic send:** `comms.sh send --to <agent> <file> --archive-inbound <inbound>`
validates the outbound (refusing to deliver or archive if malformed), attempts delivery,
records state, and only then archives the inbound. A failed nudge still archives — the
inbound *was* processed; the retry surface is delivery, tracked in state.

`send` always ends with a `RESULT:` line (`delivered` / `manual — the other agent was
NOT nudged…` / `failed — …`). Agents must relay any non-`delivered` result to the user
verbatim: a quietly-manual outcome is indistinguishable from "the reviewer is slow" and
stalls the loop.

**Identity resilience:** workspace resolution caches one good cmux-derived name per
cmux workspace (`.comms/.cache/`); if a later `cmux tree` read flakes, the cached
identity is reused instead of flapping to a branch-name fallback (which would split
message prefixes and state files mid-loop). The tree fetch itself retries 3× before
giving up.

**Late nudges are normal.** The injected read command sits in the target's input box
until its current turn ends — sometimes minutes. If the reply was already consumed by
then (e.g. by a file watcher), the late `/read-from-codex` finds an empty inbox; readers
report "latest archived: X — already processed" instead of a confusing "no messages".

## Archive discipline

Each agent archives **only its own inbox** (`comms.sh archive --as <self>` enforces
this), idempotently — an already-archived file is a no-op, never an error. The shared
`archive/` is the loop's audit trail; `/fleet` reads its newest entry per workspace to
infer loop completion (`verdict: APPROVE` is the only completion signal).
