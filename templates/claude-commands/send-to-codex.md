Send a structured handoff message to Codex via `.comms/to-codex/` and auto-deliver it.

## Instructions

1. Gather context about what was just done:
   - Run `git diff main --stat` to get changed files
   - Run `git log main..HEAD --oneline` if on a branch, otherwise `git log -5 --oneline` for recent commits
   - Read any active plan or task context from the conversation
   - **Detect worktree:** Run `pwd` to get the current working directory. If it differs from the main repo root, include it as `cwd:` in the frontmatter so Codex knows where to look.

2. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```
   **ALWAYS use `$COMMS_ROOT/to-codex/` for writing messages.** This ensures messages land in the main repo's `.comms/` even when running from a worktree.

3. **Get the workspace name** for scoping:
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   ```

4. Write a message file to `$COMMS_ROOT/to-codex/` with this format:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_<short-slug>.md`
   - Content structure:

```markdown
---
type: review-request
from: claude
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace name from step 2>
cwd: <current working directory from pwd — always include>
---

## What was done
<Brief summary of the work completed>

## Files changed
<List from git diff --stat>

## Key decisions
<Architectural or design choices worth knowing about>

## Review focus
<What specifically to scrutinize — edge cases, patterns, risks>

## Context
<Any additional context that helps the reviewer — links to plans, related issues, constraints>
```

5. **Verify before delivering.** After writing the file, read it back and confirm:
   - The `---` frontmatter delimiters are intact
   - Required fields exist: `type`, `from`, `timestamp`, `workspace`
   - If autonomous: `workflow`, `phase`, `round`, `max-rounds` are present
   - The body is not empty or truncated
   If verification fails, fix the file before delivering.

6. **Auto-deliver via cmux.** After verification passes, find Codex's surface and send the read command:
   ```bash
   # Find the other terminal surface in this workspace (not the one marked "◀ here")
   CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
   # Send the read command, brief pause, then hit enter (pause needed for cmux to place text)
   cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
   ```

7. Confirm to the user that the message was verified and delivery attempted.

**If the user provides specific instructions** (e.g., "tell codex to focus on the error handling"), incorporate those into the Review focus section.

**If there's an argument provided**, treat it as additional context or specific review instructions to include.
