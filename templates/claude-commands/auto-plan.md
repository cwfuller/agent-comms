Autonomous plan + review cycle. Creates a plan, sends to Codex for review, and automatically refines based on feedback until approved or max rounds reached.

## Instructions

1. **Parse arguments:**
   - The argument text is the task/feature description to plan for
   - Default max rounds: 10. If the user specifies a number (e.g., "/auto-plan 3 build feature X"), use that as max rounds.

2. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

3. **Get workspace name:**
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
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

6. **Auto-deliver via cmux:**
   ```bash
   CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
   cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
   ```

7. **Notify user:** "Plan created and sent to Codex for autonomous review (round 1 of N). Watch both panes — I'll auto-refine based on feedback."
