Full autonomous cycle: plan+review until approved, then implement+review until approved.

## Instructions

1. **Parse arguments:**
   - The argument text is the task/feature description
   - Default max rounds: 10 per phase. User can specify like "/auto-full 3 build feature X" for 3 rounds per phase.

2. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

3. **Get workspace name:**
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   ```

4. **Start with the plan phase.** This works exactly like `/auto-plan` but with `workflow: auto-full`:
   - Create the plan
   - Send to Codex with this frontmatter:

```markdown
---
type: review-request
from: claude
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace>
cwd: <current working directory from pwd>
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

## Context
This is an autonomous full cycle (plan phase, round 1 of <N>). After the plan is approved, implementation will begin automatically. Reply with findings using the standard verdict format.
```

5. **Auto-deliver via cmux:**
   ```bash
   CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
   cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
   ```

6. **Notify user:** "Plan created and sent to Codex for autonomous review (plan phase, round 1 of N). Full cycle: plan→approve→implement→approve."

**Note:** The phase transition (plan→implement) happens automatically in `/read-from-codex` when it receives an APPROVE verdict during the plan phase of an `auto-full` workflow.
