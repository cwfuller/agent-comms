Autonomous implement + review cycle: implement, send to one or more reviewers, and fix on their findings until approved or max rounds. `--plan` adds a short, capped approach-review first.

## When to use this
This is THE loop command. Most work: `/auto <task>` — let the implementation speak for
itself. A wrong approach surfaces fast in the implement review and you fix it there.

Reach for `--plan` ONLY when a wrong *approach* would be expensive to discover after
implementing: novel architecture, high blast radius, safety-critical, or ambiguous scope.
It is capped at 2 rounds and judged on DIRECTION, never on the prose of the plan.

## Instructions

1. **Parse arguments:**
   - The argument text describes what to implement (or references an existing plan).
   - `--rounds N` sets max rounds. **Default 4.** Rounds 1–5 have historically delivered
     the value; 6–9 delivered thoroughness whose price was never negotiated.
   - `--plan` runs a capped approach review first (step 3). Off by default.
   - `--reviewers a,b` selects the reviewing agents. Default: `"$COMMS_SH" agents default`
     (one). Validate EVERY name against `"$COMMS_SH" agents`. Hold them as a LIST, never a
     single scalar copied across write paths:
     ```bash
     REVIEWERS="codex"                     # or the parsed comma list
     GATING="${REVIEWERS%%,*}"             # first named reviewer gates the loop
     ```
   - `--via cmux` forces the watchable pane; `--via headless` forces the detached runner.
     **Default is ACP** — a warm per-thread session, ~1k fresh input tokens per round
     against ~115k for a cold spawn. Export the choice once, before any `send`/`deliver`:
     ```bash
     case "$ARGUMENTS" in *"--via cmux"*) export COMMS_DELIVERY=cmux ;; *"--via headless"*) export COMMS_DELIVERY=headless ;; esac
     "$COMMS_SH" transport "$GATING" --loop   # acp | headless | cmux | mailbox
     ```
   - Strip every flag from the task text — none may reach the message body.

2. **Resolve the shared helper** — the single source of truth for comms root, workspace
   name, validation, delivery, and archiving. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   ```

3. **`--plan` only — the approach round.** Skip entirely without the flag.
   - Write the approach: the goal, the mechanism, the invariants it must not break, and
     what you deliberately are NOT doing. A real approach doc, not a 2-line intent.
   - Frontmatter: `workflow: auto`, `phase: plan`, `round: 1`, `max-rounds: 2`.
     **The 2 is the PLAN cap only.** When you continue into implementation, write
     `max-rounds: <N>` — the loop's real budget from `--rounds` (default 4). Copying the
     plan's cap forward starves implementation of half its rounds, and it is invisible
     because both messages look well-formed. *(grok, collapse round 1.)*
   - **The bar is DIRECTION, and the message must say so.** A plan has no ship-stopping
     bugs; it has wrong directions. `REQUEST_CHANGES` on a plan means: wrong approach, a
     missed invariant, or an unsafe mechanic. Style, wording, and completeness of the
     document itself can NEVER block. Copy this sentence into the plan message's
     `## Review focus` verbatim so the reviewer is not left applying code-review
     discipline to a document.
   - On APPROVE (or at 2 rounds, whichever first), archive the approval FIRST, then
     continue to step 4 at `phase: implement`, `round: 1`, **same thread**.

4. **Implement the code.**
   - **Consult past lessons FIRST** (bounded): `"$COMMS_SH" lessons --surface "<keyword>"`.
     Exit 3 means "you have the newest", not an error. Repeating a recorded lesson wastes
     a review round.
   - Implement; run the relevant tests and type checks.
   - **Live-validate when the change is model- or runtime-coupled**: green unit tests are
     NOT sufficient evidence for correctness that depends on a live surface (a model call,
     a network API, a daemon). A unit-green fix that fails live burns a whole round on a
     wrong premise.

5. **Write the review request** — ONE message, written once. With several reviewers the
   helper fans it out; you never hand-write per-reviewer copies.
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-$RANDOM.md`
   - Write with a quoted heredoc (`<<'EOF'`) so backticks and dollar signs are never
     evaluated.
   - `thread` names this loop and is constant across every message in it; `message_id` is
     the filename sans `.md`.

```markdown
---
type: review-request
from: claude
timestamp: <ISO 8601>
branch: <current branch>
head_sha: <git rev-parse HEAD>
workspace: <workspace>
cwd: <pwd>
message_id: <filename, without .md>
thread: <kebab-slug-of-task>-<same random suffix as the filename>
workflow: auto
phase: implement
round: 1
max-rounds: <N>
---

## Intent / approach
<2-4 lines: the GOAL and the approach taken. Context so the reviewer never reads cold.>

## What was done
<Summary of the implementation>

## Acceptance criteria
<3-7 testable statements. PINNED at round 1 — later rounds are judged against these; the
bar does not move with each holistic pass. If a finding genuinely changes the bar, amend
explicitly in the next round and say so — never silently re-derive.>

## Files changed
<git diff --stat, generated from the reviewed commit — not hand-written>

## Key decisions
<Architectural or design choices made during implementation>

## Review focus
Review for bugs, logic errors, edge cases, and code quality. Critical and warning-level
issues only — skip style nits.

## Meta — process feedback requested (standing section)
Flag friction with the comms process itself (delivery, archive sequencing, message shape,
round semantics) under a `### Process` heading. Process feedback never gates the verdict.

## Context
Autonomous implement+review cycle (round 1 of <N>). Reply with findings using the standard
verdict format. The cycle continues until APPROVE or max rounds.
```

6. **Validate and deliver.** `send`/`panel dispatch` refuse malformed messages, retain the
   artifact under review, and degrade to manual pickup rather than failing silently.

   **One reviewer:**
   ```bash
   "$COMMS_SH" send --to "$GATING" "<path of the message file>"
   ```

   **Several reviewers — fan out, never hand-roll the copies:**
   ```bash
   "$COMMS_SH" panel dispatch --to "$REVIEWERS" "<path of the message file>"
   ```
   That writes one 2-party leg per reviewer (`<thread>-<agent>`), all sharing one
   `review_set` and **one snapshot**, and validates the whole roster before sending any
   leg — a half-fanned panel silently drops a voice from the composed gate. It prints the
   `review_set` id; keep it, you need it to compose.

   Either way the message is stamped with `artifact_id:` and the tree is pinned, so every
   reviewer reads the SAME artifact rather than whatever the working tree happens to hold
   when each one starts.

   **When the legs answer, compose before fixing anything:**
   ```bash
   "$COMMS_SH" compose --set "<review_set id>"
   ```
   It clusters the union by SUPPORT and drops nothing:
   - **Corroborated** (an anchor two reviewers independently flagged) — these gate.
   - **Uncorroborated** — cross-check before spending a round on it. A lone unsupported
     blocker is not obeyed automatically; that is what stops one noisy reviewer holding
     the loop hostage, and it is the token discipline that keeps a panel affordable.
   - **Unanchored** / **Advisory** — carried, never gating.

   `compose` REFUSES a partial panel. An unanswered leg is not an approval.
   **Do not auto-address every blocking bullet from every reviewer** — work the
   corroborated set, the gating reviewer's blockers, and any unique blocker that
   independently meets verdict discipline. Still split after one confirmation round →
   escalate to the user, same lane as max-rounds.
   On `RESULT: blocked`, execute the exact `RECOVER:` line once; relay only the final
   non-`delivered` result.
   <!-- loopspec:fragment result-spawned-exception -->
   Exception — `RESULT: spawned` (headless mode, `COMMS_DELIVERY=headless`): the peer agent's turn is running detached; await the printed run dir as a background task (`.../runphase.sh await "<run dir>"`), then `/read-from-codex`. A non-zero await means the turn failed or timed out (check its `result.json`) — report that instead of waiting for a reply.
   <!-- /loopspec:fragment -->

7. **Notify the user:** which reviewers were sent to, the phase, and round 1 of N. If the
   loop goes quiet, `"$COMMS_SH" stalled` lists threads still awaiting a reply.
