Full autonomous cycle: plan+review until approved, then implement+review until approved.

## Instructions

1. **Parse arguments:**
   - The argument text is the task/feature description
   - Default max rounds: 10 per phase. User can specify like "/auto-full 3 build feature X" for 3 rounds per phase.

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

4. **Start with the plan phase.** This works exactly like `/auto-plan` but with `workflow: auto-full`:
   - Create the plan
   - Send to Codex with:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_auto-full.md` (workspace name from step 3)
   - Use this frontmatter:

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

5. **Auto-deliver via cmux when available.** If `cmux` or `CMUX_WORKSPACE_ID` is unavailable, skip delivery and tell the user the message was written for manual pickup:
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

6. **Notify user:** "Plan created and sent to Codex for autonomous review (plan phase, round 1 of N). Full cycle: plan→approve→implement→approve."

**Note:** The phase transition (plan→implement) happens automatically in `/read-from-codex` when it receives an APPROVE verdict during the plan phase of an `auto-full` workflow.
