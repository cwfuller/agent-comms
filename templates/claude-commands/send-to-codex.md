Send a structured handoff message to Codex via `.comms/to-codex/` and auto-deliver it.

## Instructions

1. Gather context about what was just done:
   - Detect the default branch with `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`, falling back to `main` if unavailable
   - Run `git diff <default-branch> --stat` to get changed files
   - Run `git log <default-branch>..HEAD --oneline` if on a branch, otherwise `git log -5 --oneline` for recent commits
   - Read any active plan or task context from the conversation
   - **Detect worktree:** Run `pwd` to get the current working directory. If it differs from the main repo root, include it as `cwd:` in the frontmatter so Codex knows where to look.

2. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```
   **ALWAYS use `$COMMS_ROOT/to-codex/` for writing messages.** This ensures messages land in the main repo's `.comms/` even when running from a worktree.

3. **Get the workspace name** for scoping. Run this block verbatim — cmux first, git branch second, repo dir last. Dropping the cmux lookup silently falls back to a branch name like `main` and corrupts filenames that other agents filter on:
   ```bash
   # Precedence: cmux workspace → git branch → repo dir.
   # Keep the cmux block; other agents' filename filters depend on it.
   WORKSPACE=""
   if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
     WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null \
       | grep -E 'workspace workspace:[0-9]+ "' \
       | head -1 \
       | sed 's/.*"\([^"]*\)".*/\1/' \
       | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   fi
   [ -n "$WORKSPACE" ] || WORKSPACE=$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   [ -n "$WORKSPACE" ] || WORKSPACE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then
     case "$WORKSPACE" in
       main|master|trunk|develop)
         echo "warning: cmux is active but workspace resolved to '$WORKSPACE' — verify the cmux tree grep/sed still matches the tool's output format" >&2
         ;;
     esac
   fi
   echo "WORKSPACE=$WORKSPACE"
   ```

4. Write a message file to `$COMMS_ROOT/to-codex/` with this format:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_<short-slug>-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions)
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

6. **Auto-deliver via cmux when available.** After verification passes, find Codex's surface and send the read command. If `cmux` or `CMUX_WORKSPACE_ID` is unavailable, skip auto-delivery and tell the user the verified file was written for manual pickup:
   ```bash
   if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
     # Pane-aware Codex surface picker. Prefers a [terminal] surface in a pane
     # (awk fields are written $(0)/$(N) — bare dollar-digit tokens in command markdown are clobbered by slash-command argument substitution)
     # OTHER than the one marked "◀ here", so sibling tabs in Claude's own pane
     # don't get picked. Falls back to any other terminal surface for single-pane
     # multi-tab layouts where Claude and Codex share a pane.
     CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null | awk '
       /pane:/ { for (i=1;i<=NF;i++) if ($i ~ /^pane:/) cur_pane=$i }
       /surface:.*\[terminal\]/ {
         if (match($(0), /surface:[0-9]+/)) {
           n++; surf[n]=substr($(0),RSTART,RLENGTH); pane[n]=cur_pane
           here[n] = ($(0) ~ /◀ here/) ? 1 : 0
           if (here[n]) here_pane=cur_pane
         }
       }
       END {
         for (i=1;i<=n;i++) if (!here[i] && pane[i]!=here_pane) { print surf[i]; exit }
         for (i=1;i<=n;i++) if (!here[i]) { print surf[i]; exit }
       }')
     if [ -n "$CODEX_SURFACE" ]; then
       # Send the read command, brief pause, then hit enter (pause needed for cmux to place text)
       cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
     else
       echo "warning: could not find a Codex surface; message written for manual pickup"
     fi
   else
     echo "warning: cmux not available; message written for manual pickup"
   fi
   ```

7. Confirm to the user that the message was verified and delivery attempted.

**If the user provides specific instructions** (e.g., "tell codex to focus on the error handling"), incorporate those into the Review focus section.

**If there's an argument provided**, treat it as additional context or specific review instructions to include.
