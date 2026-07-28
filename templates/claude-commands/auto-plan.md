Autonomous plan + review cycle. Creates a plan, sends to Codex for review, and automatically refines based on feedback until approved or max rounds reached.

## Instructions

1. **Parse arguments:**
   - The argument text is the task/feature description to plan for
   - Default max rounds: 10. If the user specifies a number (e.g., "/auto-plan 3 build feature X"), use that as max rounds.

2. **Resolve the shared helper** — the single source of truth for comms root, workspace name, validation, delivery, and archiving. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```

3. **Create the plan.** Based on the user's task description:
   - **Consult past lessons FIRST** — both reads are bounded, so this costs a known number of
     tokens no matter how large the log and archive grow:
     ```bash
     "$COMMS_SH" lessons --surface "<keyword for this task's surface>"   # newest advisories, ≤4k
     "$COMMS_SH" archive-search "<keyword>"                             # newest prior threads, ≤4k
     ```
     Exit 3 means "you have the newest; older ones are named by path" — not an error. Drop
     `--surface` to see the newest lessons regardless of surface. Apply what's relevant and note
     it briefly in the plan ("Lessons applied: …") — a plan that repeats a recorded lesson wastes
     a review round.
   - Analyze the codebase as needed to inform the plan
   - Create a thorough implementation plan covering: approach, files to create/modify, key decisions, risks, and steps
   - Write the plan to a file if appropriate, or include it in the message body

4. **Write the review request** to `$COMMS_ROOT/to-codex/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-plan-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions)
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
workflow: auto-plan
phase: plan
round: 1
max-rounds: <N>
---

## What was done
<Summary of the plan created>

## Plan
<The full plan content>

## Review focus
Review this plan for completeness, architecture decisions, risks, and missed edge cases.

## Meta — process feedback requested (standing section)
Separate from plan findings: flag any friction with the comms process itself (delivery, archive sequencing, message shape, round semantics) under a `### Process` heading. Process feedback never gates the verdict.

## Context
This is an autonomous plan+review cycle (round 1 of <N>). Reply with findings using the standard verdict format. The cycle continues until you APPROVE or max rounds are reached.
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

6. **Notify user:** "Plan created and sent to Codex for autonomous review (round 1 of N). I'll refine it based on feedback until approved." If the loop goes quiet, `"$COMMS_SH" stalled` lists threads still awaiting a reply.
