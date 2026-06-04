Full autonomous cycle: plan+review until approved, then implement+review until approved.

## Instructions

1. **Parse arguments:**
   - The argument text is the task/feature description
   - Default max rounds: 10 per phase. User can specify like "/auto-full 3 build feature X" for 3 rounds per phase.

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
   - Create the plan
   - Write the message to `$COMMS_ROOT/to-codex/` with filename `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-full-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions); use a quoted heredoc (`<<'EOF'`) or a non-interpolating tool
   - `thread` names this loop and stays constant across every message in the cycle; replies copy it. `message_id` is the filename sans `.md`
   - Use this frontmatter and body:

```markdown
---
type: review-request
from: claude
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace>
cwd: <current working directory from pwd>
message_id: <the filename, without .md>
thread: <kebab-slug-of-task>-<same random suffix as the filename>
workflow: auto-full
phase: plan
round: 1
max-rounds: <N>
status: in-progress
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
   "$COMMS_SH" send --to codex "<path of the message file you wrote>"
   ```

5. **Notify user:** "Plan created and sent to Codex for autonomous review (plan phase, round 1 of N). Full cycle: plan→approve→implement→approve." If the loop goes quiet, `"$COMMS_SH" stalled` lists threads still awaiting a reply.

**Note:** The phase transition (plan→implement) happens automatically in `/read-from-codex` when it receives an APPROVE verdict during the plan phase of an `auto-full` workflow.
