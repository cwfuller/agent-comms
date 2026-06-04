Autonomous implement + review cycle. Implements code, sends to Codex for review, and automatically fixes issues based on feedback until approved or max rounds reached.

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
   - Read any referenced plan files
   - Implement the changes
   - Run any relevant tests or type checks

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

6. **Notify user:** "Implementation complete and sent to Codex for autonomous review (round 1 of N). Watch both panes — I'll auto-fix based on feedback." If the loop goes quiet, `"$COMMS_SH" stalled` lists threads still awaiting a reply.
