Autonomous plan + review cycle. Creates a plan, sends to Codex for review, and automatically refines based on feedback until approved or max rounds reached.

## Instructions

1. **Parse arguments:**
   - The argument text is the task/feature description to plan for
   - Default max rounds: 10. If the user specifies a number (e.g., "/auto-plan 3 build feature X"), use that as max rounds.

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

4. **Create the plan.** Based on the user's task description:
   - Analyze the codebase as needed to inform the plan
   - Create a thorough implementation plan covering: approach, files to create/modify, key decisions, risks, and steps
   - Write the plan to a file if appropriate, or include it in the message body

5. **Send to Codex with workflow metadata.** Write a message to `$COMMS_ROOT/to-codex/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-plan.md`
   - Use this frontmatter:

```markdown
---
type: review-request
from: claude
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace>
cwd: <current working directory from pwd>
workflow: auto-plan
phase: plan
round: 1
max-rounds: <N>
status: in-progress
---

## What was done
<Summary of the plan created>

## Plan
<The full plan content, or reference to the plan file>

## Files changed
<Any files created/modified>

## Review focus
Review this plan for completeness, architecture decisions, risks, and missed edge cases. Focus on critical and warning-level issues only.

## Context
This is an autonomous plan+review cycle (round 1 of <N>). Reply with findings using the standard verdict format. The cycle continues until you APPROVE or max rounds are reached.
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

7. **Notify user:** "Plan created and sent to Codex for autonomous review (round 1 of N). Watch both panes — I'll auto-refine based on feedback."
