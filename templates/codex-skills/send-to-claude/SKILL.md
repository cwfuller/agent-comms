---
name: send-to-claude
description: Send review findings or messages to Claude Code via .comms/to-claude/ and auto-deliver via cmux
metadata:
  short-description: Send messages to Claude Code
---

# Send To Claude

Write a structured message to Claude Code via `.comms/to-claude/` and auto-deliver it using cmux.

## Instructions

1. Gather your findings, feedback, or questions

2. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

3. **Get the workspace name** for scoping:
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   ```

4. Create a timestamped markdown file in `$COMMS_ROOT/to-claude/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_<short-slug>.md`
   - Use the current timestamp

4. Use this format. **If the incoming message had `workflow` fields, you MUST copy them into your reply:**

   In autonomous review loops:
   - Default to `verdict: APPROVE`
   - Use `verdict: REQUEST_CHANGES` only for blocking issues that are not ready to ship
   - Put non-blocking notes under `Advisory` while keeping `APPROVE`
   - Do not use `COMMENT` in autonomous review loops; reserve it for manual questions or side-channel notes

```markdown
---
type: review-feedback | question | request
from: codex
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace name from step 2>
cwd: <current working directory>
in-reply-to: <filename of the message you're responding to, if any>
workflow: <copy from incoming message if present — auto-plan | auto-implement | auto-full>
phase: <copy from incoming message if present — plan | implement>
round: <copy from incoming message if present>
max-rounds: <copy from incoming message if present>
verdict: <APPROVE | REQUEST_CHANGES | COMMENT>
---

## Summary
<One-line summary of your message>

## Findings
<For reviews: list blocking issues separately from advisory notes>

### Blocking
- <file:line> — description of issue

### Advisory
- <file:line> — description of non-blocking risk, cleanup, or suggestion

## Questions
<Any questions for Claude to address>
```

5. **Auto-deliver via cmux.** After writing the file, find Claude's surface and send the read command:
   ```bash
   # Find the other terminal surface in this workspace (not the one marked "◀ here")
   CLAUDE_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
   # Claude uses vim mode — ensure insert mode before typing, then submit
   cmux send-key --surface "$CLAUDE_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.2 && cmux send --surface "$CLAUDE_SURFACE" --workspace "$CMUX_WORKSPACE_ID" 'i' && sleep 0.2 && cmux send --surface "$CLAUDE_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '/read-from-codex' && sleep 0.5 && cmux send-key --surface "$CLAUDE_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CLAUDE_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
   ```

6. Confirm to the user that the message was queued and delivery attempted.

If the user provides specific instructions, incorporate them into the appropriate section.
