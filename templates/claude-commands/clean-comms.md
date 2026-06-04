Delete messages from `.comms/` directories.

## Instructions

1. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

2. **Get the workspace name.** Run this block verbatim — cmux first, git branch second, repo dir last. Dropping the cmux lookup silently falls back to a branch name like `main` and corrupts filenames that other agents filter on:
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

3. Based on the argument provided (use `$COMMS_ROOT` for all paths):
   - **No argument or "workspace"** — Delete this workspace's messages (files starting with the workspace name) from **your inbox (`to-claude/`) and `archive/` only**. Do NOT touch `to-codex/` — that's Codex's inbox and may hold messages Codex hasn't read yet; deleting those requires explicit `all`.
   - **"all"** — Delete ALL messages from `to-codex/`, `to-claude/`, and `archive/` (both inboxes — this is the only mode that deletes the other agent's unread mail)
   - **"archive"** — Delete only archived messages in `archive/`
   - **A specific filename** — Delete just that file

4. Show what will be deleted and confirm with the user before removing.

5. Report how many files were cleaned up.
