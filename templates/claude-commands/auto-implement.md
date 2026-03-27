Autonomous implement + review cycle. Implements code, sends to Codex for review, and automatically fixes issues based on feedback until approved or max rounds reached.

## Instructions

1. **Parse arguments:**
   - The argument text describes what to implement (or references an existing plan)
   - Default max rounds: 10. If the user specifies a number, use that as max rounds.

2. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

3. **Get workspace name:**
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   ```

4. **Implement the code.** Based on the task description or existing plan:
   - Read any referenced plan files
   - Implement the changes
   - Run any relevant tests or type checks

5. **Send to Codex with workflow metadata.** Write a message to `$COMMS_ROOT/to-codex/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-implement.md`
   - Use this frontmatter:

```markdown
---
type: review-request
from: claude
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace>
cwd: <current working directory from pwd>
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

## Context
This is an autonomous implement+review cycle (round 1 of <N>). Reply with findings using the standard verdict format. The cycle continues until you APPROVE or max rounds are reached.
```

6. **Auto-deliver via cmux:**
   ```bash
   CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
   cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
   ```

7. **Notify user:** "Implementation complete and sent to Codex for autonomous review (round 1 of N). Watch both panes — I'll auto-fix based on feedback."
