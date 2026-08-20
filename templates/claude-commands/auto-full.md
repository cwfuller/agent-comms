Full autonomous cycle: plan+review until approved, then implement+review until approved.

## When to use this (NOT the default)
`/auto-implement` is the default — let the implementation speak for itself. Use `/auto-full`'s gated plan phase ONLY when a wrong *approach* would be expensive to discover after implementing: **novel architecture, high blast radius, safety-critical, or genuinely ambiguous scope.** The plan-review round earns its cost there (it catches design-level issues — wrong direction, missed edge cases, unsafe mechanics — before any code). For well-scoped or mechanical work it is ceremony; prefer auto-implement. Rule of thumb: most work → auto-implement; the genuinely hard stuff → auto-full.

## Instructions

1. **Parse arguments:**
   - The argument text is the task/feature description
   - Default max rounds: 10 per phase. User can specify like "/auto-full 3 build feature X" for 3 rounds per phase.
   - Optional `--reviewer <agent>` flag selects the reviewing agent. Default: `"$COMMS_SH" agents default`. Validate the name against `"$COMMS_SH" agents`; hold it in a named variable (REVIEWER) and use it for every write path and send below — headless-only agents (e.g. grok) work identically; delivery routes itself.

2. **Resolve the shared helper** — the single source of truth for comms root, workspace name, validation, delivery, and archiving. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```

3. **Start with the plan phase.** This works exactly like `/auto-plan` but with `workflow: auto-full`:
   - **Consult past lessons FIRST** (the step that makes loops compound) — both reads are
     bounded, so this costs a known number of tokens no matter how large the log and archive grow:
     ```bash
     "$COMMS_SH" lessons --surface "<keyword for this task's surface>"   # newest advisories, ≤4k
     "$COMMS_SH" archive-search "<keyword>"                             # newest prior threads, ≤4k
     ```
     Exit 3 means "you have the newest; older ones are named by path" — not an error. Drop
     `--surface` to see the newest lessons regardless of surface. Apply what's relevant and note it
     briefly in the plan (a one-line "Lessons applied: …"). Lessons are written at approve-time
     precisely so they can be READ at plan-time — a plan that repeats a recorded lesson wastes a
     review round.
   - Create the plan
   - Write the message to `$COMMS_ROOT/to-$REVIEWER/` (`mkdir -p` it first) with filename `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-full-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions); use a quoted heredoc (`<<'EOF'`) or a non-interpolating tool
   - `thread` names this loop and stays constant across every message in the cycle; replies copy it. `message_id` is the filename sans `.md`
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
workflow: auto-full
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
This is an autonomous full cycle (plan phase, round 1 of <N>). After the plan is approved, implementation will begin automatically. Reply with findings using the standard verdict format.
```

4. **Validate and deliver** — `send` refuses malformed messages and degrades to manual pickup without cmux:
   ```bash
   "$COMMS_SH" send --to "$REVIEWER" "<path of the message file you wrote>"
   ```
   On `RESULT: blocked`, execute the exact `RECOVER:` line once; relay only the final
   non-`delivered` result.
   <!-- loopspec:fragment result-spawned-exception -->
   Exception — `RESULT: spawned` (headless mode, `COMMS_DELIVERY=headless`): the peer agent's turn is running detached; await the printed run dir as a background task (`.../runphase.sh await "<run dir>"`), then `/read-from-codex`. A non-zero await means the turn failed or timed out (check its `result.json`) — report that instead of waiting for a reply.
   <!-- /loopspec:fragment -->

5. **Notify user:** "Plan created and sent to $REVIEWER for autonomous review (plan phase, round 1 of N). Full cycle: plan→approve→implement→approve." If the loop goes quiet, `"$COMMS_SH" stalled` lists threads still awaiting a reply.

**Note:** The phase transition (plan→implement) happens automatically in `/read-from-codex` when it receives an APPROVE verdict during the plan phase of an `auto-full` workflow.
