Autonomous implement + review cycle. Implements code, sends to Codex for review, and automatically fixes issues based on feedback until approved or max rounds reached.

## Instructions

1. **Parse arguments:**
   - The argument text describes what to implement (or references an existing plan)
   - Default max rounds: 10. If the user specifies a number, use that as max rounds.

2. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

3. **Get workspace name.** Prefer the active `cmux` workspace when available; otherwise fall back to the current branch name, then the repo name:
   ```bash
   WORKSPACE=$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   [ -n "$WORKSPACE" ] || WORKSPACE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
     CMUX_WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
     [ -n "$CMUX_WORKSPACE" ] && WORKSPACE="$CMUX_WORKSPACE"
   fi
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

6. **Auto-deliver via cmux when available.** If `cmux` or `CMUX_WORKSPACE_ID` is unavailable, skip delivery and tell the user the message was written for manual pickup:
   ```bash
   if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
     CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
     if [ -n "$CODEX_SURFACE" ]; then
       cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
     else
       echo "warning: could not find a Codex surface; message written for manual pickup"
     fi
   else
     echo "warning: cmux not available; message written for manual pickup"
   fi
   ```

7. **Notify user:** "Implementation complete and sent to Codex for autonomous review (round 1 of N). Watch both panes — I'll auto-fix based on feedback."
