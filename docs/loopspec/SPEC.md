# LOOPSPEC v1 — the review-loop contract

The portable, runtime-agnostic contract for autonomous review loops between coding
agents. This directory is the **kernel**: spec text, JSON schemas, golden fixtures, a
conformance checker, and the prompt fragments that carry the loop discipline. It is
deliberately small — no runtime, no scheduler, no tracker, no transport.

Consumers implement the contract independently and validate against the same fixtures:

- **agent-comms** (this repo): bash helpers + skills; `check.sh --comms <comms.sh>`
  runs in the test harness.
- **downstream consumers**: vendor this directory at a pin and run their own readers
  against the fixtures. A consumer's CI validates only its **vendored pinned copy** —
  never upstream HEAD — so unrelated upstream commits cannot break a consumer's build;
  drift is caught by a deliberate pin bump (or a scheduled check), not by coupling.

Out of scope, permanently: transport/wake (cmux, headless runners, relays), state
storage, scheduling/orchestration, tracker integration, and **merge authorization**
(see the `merge` profile note below).

## Message contract

A loop message is markdown with YAML-ish frontmatter:

```markdown
---
type: review-request            # see type table
from: <agent>                   # sender identity (agent-comms: claude | codex)
timestamp: 2026-06-04T18:30:14Z
branch: main
head_sha: <git rev-parse HEAD>  # optional immutable context for delayed delivery
workspace: agent-comms          # scoping name when several loops share a repo
cwd: /path/to/working/dir       # worktree hint — reader cds here before touching files
message_id: <filename sans .md>
thread: rate-limiter-9331       # names the loop; constant across ALL its messages
in-reply-to: <message_id>       # when replying
workflow: auto-implement        # presence triggers autonomous mode
phase: plan | implement
round: 2
max-rounds: 10
verdict: APPROVE                # reviewer replies only; see verdict semantics
---
```

Validation rules (normative — the fixtures encode them):

| Rule | Severity |
|---|---|
| `---` delimiters intact, body non-empty | error |
| `type`, `from`, `timestamp` present | error |
| `workflow` present ⇒ `phase`, `round`, `max-rounds` present | error |
| workflow `review-feedback` ⇒ `verdict` present (bound by TYPE, not sender — either agent can be the reviewer) | error |
| `verdict: COMMENT` inside a workflow loop | warning — COMMENT is reserved for manual exchanges |
| workflow message without `thread` / `message_id` | warning — soft, so in-flight loops survive upgrades |
| `verdict` value outside the recognized set (after normalization) | warning |

### Message types

| type | direction | meaning |
|---|---|---|
| `review-request` | → reviewer | "review this plan/diff"; carries workflow fields in loops |
| `review-feedback` | reviewer → | findings + `verdict` |
| `question` | → reviewer | one-off consult; no workflow, no verdict |
| `response` | reviewer → | answer to a `question` (no verdict) or manual follow-up |
| `ping` | either | connectivity test |
| `request` | either | freeform ask outside a loop |
| `error` | either | "your last message was malformed — resend." Verdict-free, copies the loop fields, and **never consumes a round** |

## Verdict semantics

Two spellings, permanently equivalent — implementations MUST accept both and MAY emit
either:

| canonical (artifact/JSON form) | message form |
|---|---|
| `status: pass` **and** `blocking_findings == 0` | `verdict: APPROVE` |
| `status: fail` **or** `blocking_findings > 0` | `verdict: REQUEST_CHANGES` |

Normalization: strip ALL whitespace (surrounding and internal), uppercase, then map
`PASS → APPROVE` and `FAIL → REQUEST_CHANGES`. `COMMENT` is reserved for manual
(non-loop) exchanges and never appears in autonomous rounds (a loop message carrying
it draws a warning). `verdict.schema.json` is the canonical artifact shape;
`fixtures/verdicts.tsv` is the normalization table.

**Two named profiles — never merged:**

- **`gate`** (shared, lenient): drives loop continuation. A missing
  `blocking_findings` count reads as 0; unknown extra fields are ignored. This is the
  profile this spec's fixtures exercise.
- **`merge`** (implementation-private, strict, fail-closed): authorizes irreversible
  actions (e.g. unattended auto-merge). Requires binding to the exact artifact
  reviewed (e.g. `head_sha`) and evidence fields (e.g. `tests_run`), and rejects on
  any missing field. Merge authorization is OUT OF SCOPE for loopspec; the profile is
  named here so no consumer mistakes `gate` leniency for merge authority.

## Loop invariants

- `round` counts **review passes**. The author sends round 1; on `REQUEST_CHANGES`
  the author fixes and sends round 2; the loop ends on `APPROVE` or when `round`
  reaches `max-rounds` (then it escalates to the human).
- **Verdict discipline** (`fragments/verdict-discipline.md` is the normative prompt
  text): `REQUEST_CHANGES` is for blocking issues only — correctness, security,
  data loss, broken flows. Advisory notes ride along with `APPROVE` and never force
  another round.
- **Stable context, not fix narration**: a round-N reply carries the previous
  findings as context plus the current plan/diff — never a per-finding "fixed it"
  checklist. Round 2+ reviews are holistic re-reads with a blank checklist
  (`fragments/holistic-rereview.md`).
- **Error lane never consumes a round**: a malformed message gets a `type: error`
  reply; the sender resends corrected at the SAME `round`.
- **Phase transition** (`plan → implement`): the plan-approval message is archived
  *first* (prevents a stale re-read double-firing implementation), then the implement
  phase starts at `round: 1` with the same `thread`.
- **On final `APPROVE`**: un-actioned advisory findings are appended to the
  compounding log (below) and process feedback to the friction log; then the loop's
  state is marked complete.
- **Meta channel**: loop messages carry a standing invitation for the reviewer to
  flag process friction; it never gates the verdict.
- **Threading**: the loop opener mints `thread`; every subsequent message copies it
  verbatim. Readers scope reads by thread; `message_id`/`in-reply-to` make any chain
  reconstructable.
- **Least privilege / no bypass**: turns run under the narrowest workable
  permission policy; bypass/danger permission flags are refused in loop turns. A
  novel permission need surfaces as a failed turn and gets a scoped policy addition.

## Compounding entry format

One entry shape lets agent-comms advisory carry-over (`docs/advisories.md`) and
downstream rework logs share the same compounding format:

```markdown
## <YYYY-MM-DD> — thread `<thread-or-issue>` (<context: workflow, round, outcome>)

- **<short title>** (<DEFERRED | ACTIONED | PROCESS>): <body — what was learned or
  deferred, with enough detail to act on later>
```

New entries SHOULD carry the status tag; entries written before loopspec v1 predate
it and are read as `DEFERRED`. Injection guidance for consumers: feed a **bounded
tail** of the newest entries (≈4k chars) into planning/review turns — lessons-first
consultation is part of the review discipline, not an afterthought. agent-comms
currently consults the file via its skills' lessons-first step; consumers can expose
the same primitive through their own prompt inputs.

## Provider turn contract

A headless peer turn (any provider) is: **spawn detached → observe (JSONL event log)
→ record**. The record is `result.json` (`result.schema.json`):

| field | values / meaning |
|---|---|
| `provider` | which CLI ran the turn |
| `status` | `completed` \| `failed` \| `timeout` (`input_required` reserved) |
| `exit_code` | provider CLI exit code (`124` timeout, `?` runner abort) |
| `session_id` | provider session/thread id, for attach/resume |
| `message_file`, `run_dir`, `started_at`, `ended_at`, `note` | provenance + diagnostics |

Invariants: the event log is teed continuously; every exit path writes `result.json`,
and it is written **last** — after state mirroring — because it is the signal awaiters
unblock on; the exit-code is ground truth for `completed` vs `failed`; a timeout kills
the turn's whole process group; thread state (`thread-state.schema.json`) mirrors the
outcome and records the session id and run dir for the watchdog and attach commands.

## Fixtures and the checker

```
fixtures/valid/*.md        must validate (exit 0)
fixtures/invalid/*.md      must be rejected; MANIFEST.tsv maps file → required stderr substring
fixtures/verdicts.tsv      raw verdict value → expected normalized form
fixtures/thread-state.json a conforming state record (all fields)
fixtures/result.json       a conforming turn result
```

`check.sh --comms <path-to-comms.sh>` runs agent-comms against the fixtures; it is
self-contained (no cmux, no network, no repo assumptions) so the whole `loopspec/`
directory can be vendored and re-run elsewhere. Other consumers implement their own
thin reader against the same fixture data.

## Prompt fragments

`fragments/*.md` (in this directory — the kernel vendors as one unit) is the single
normative home for the portable discipline text. Templates embed a fragment between
markers:

```markdown
<!-- loopspec:fragment <name> -->
...fragment text, byte-identical modulo leading indentation...
<!-- /loopspec:fragment -->
```

The test harness diffs every marked region against its fragment file
(whitespace-normalized per line) and trips on fragment signature phrases appearing
in templates OUTSIDE marked regions — drift and unmarked copies are failing checks,
not habits.

## Versioning

This is **loopspec v1**. Changes are backward-tolerant in the agent-comms tradition:
new fields and synonyms arrive as warnings/optional first; removals require a major
bump. Consumers pin by vendoring the directory (or by git tag) and upgrade
deliberately.
