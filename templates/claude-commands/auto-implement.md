Autonomous implement + review cycle. Implements code, sends to Codex for review, and automatically fixes issues based on feedback until approved or max rounds reached.

## When to use this (the DEFAULT)
This is the default workflow — **let the implementation speak for itself.** Modern models rarely need a separate, gated plan-approval round; a wrong approach surfaces fast in the implement review and you just fix + re-review. Reach for `/auto-full` (the gated plan phase) ONLY when the work is genuinely high-stakes: novel architecture, high blast radius, safety-critical, or ambiguous scope where a wrong *approach* would be expensive to discover after implementing. Rule of thumb: most work → auto-implement; the genuinely hard stuff → auto-full.

No separate plan is reviewed here — but the handoff includes a short `## Intent / approach` (see the message body) carrying the goal + how you went about it, as CONTEXT so Codex never reviews cold. That looser, non-gated "plan as context" is the point: Codex knows what you set out to do and how, without a plan-approval loop.

## Instructions

1. **Parse arguments:**
   - The argument text describes what to implement (or references an existing plan)
   - Default max rounds: 10. If the user specifies a number, use that as max rounds.

2. **Resolve the shared helper** — the single source of truth for comms root, workspace name, validation, delivery, and archiving. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```

3. **Implement the code.** Based on the task description or existing plan:
   - **Consult past lessons FIRST**: read the project's `docs/advisories.md` (if present) and its
     friction log for entries touching this surface — repeating a recorded lesson wastes a review round.
   - Read any referenced plan files
   - Implement the changes
   - Run any relevant tests or type checks
   - **Live-validate when the change is model- or runtime-coupled**: green unit tests alone are NOT
     sufficient evidence for changes whose correctness depends on a live surface (a model call, a
     network API, a daemon). Run the real surface once before sending the review request — a unit-green
     fix that fails live burns a full review round on a wrong premise.

4. **Write the review request** to `$COMMS_ROOT/to-codex/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-implement-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions)
   - Write with a quoted heredoc (`<<'EOF'`) or a non-interpolating tool so backticks and dollar signs in the body are never evaluated
   - `thread` names this loop and stays constant across every message in the cycle; replies copy it. `message_id` is the filename sans `.md`. These let concurrent loops in one workspace coexist and let replies be threaded
   - Use this frontmatter and body:

```markdown
---
type: review-request
from: claude
timestamp: <ISO 8601>
branch: <current branch>
head_sha: <git rev-parse HEAD>
workspace: <workspace>
cwd: <current working directory from pwd>
message_id: <the filename, without .md>
thread: <kebab-slug-of-task>-<same random suffix as the filename>
workflow: auto-implement
phase: implement
round: 1
max-rounds: <N>
status: in-progress
---

## Intent / approach
<2-4 lines: the GOAL this change is after + the approach you took to get there. This is the looser, non-gated "plan as context" — it replaces a separate plan-approval round so Codex reviews with intent, not cold. Keep it tight; the diff carries the detail.>

## What was done
<Summary of the implementation>

## Files changed
<git diff --stat output>

## Key decisions
<Architectural or design choices made during implementation>

## Review focus
Review the implementation for bugs, logic errors, edge cases, and code quality. Focus on critical and warning-level issues only — skip style nits.

## Meta — process feedback requested (standing section)
Separate from code findings: flag any friction with the comms process itself (delivery, archive sequencing, message shape, round semantics) under a `### Process` heading. Process feedback never gates the verdict.

## Context
This is an autonomous implement+review cycle (round 1 of <N>). Reply with findings using the standard verdict format. The cycle continues until you APPROVE or max rounds are reached.
```

5. **Validate and deliver** — `send` refuses malformed messages and degrades to manual pickup without cmux:
   ```bash
   "$COMMS_SH" send --to codex "<path of the message file you wrote>"
   ```
   On `RESULT: blocked`, execute the exact `RECOVER:` line once; relay only the final
   non-`delivered` result.
   <!-- loopspec:fragment result-spawned-exception -->
   Exception — `RESULT: spawned` (headless mode, `COMMS_DELIVERY=headless`): the Codex turn is running detached; await the printed run dir as a background task (`.../runphase.sh await "<run dir>"`), then `/read-from-codex`. A non-zero await means the turn failed or timed out (check its `result.json`) — report that instead of waiting for a reply.
   <!-- /loopspec:fragment -->

6. **Notify user:** "Implementation complete and sent to Codex for autonomous review (round 1 of N). Watch both panes — I'll auto-fix based on feedback." If the loop goes quiet, `"$COMMS_SH" stalled` lists threads still awaiting a reply.
