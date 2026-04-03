Delete messages from `.comms/` directories.

## Instructions

1. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

2. **Get the workspace name.** Prefer the active `cmux` workspace when available; otherwise fall back to the current branch name, then the repo name:
   ```bash
   WORKSPACE=$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   [ -n "$WORKSPACE" ] || WORKSPACE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
     CMUX_WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
     [ -n "$CMUX_WORKSPACE" ] && WORKSPACE="$CMUX_WORKSPACE"
   fi
   ```

3. Based on the argument provided (use `$COMMS_ROOT` for all paths):
   - **No argument or "workspace"** — Delete all messages for the current workspace (files starting with the workspace name) from both `to-codex/` and `to-claude/`, plus `archive/`
   - **"all"** — Delete ALL messages from `to-codex/`, `to-claude/`, and `archive/`
   - **"archive"** — Delete only archived messages in `archive/`
   - **A specific filename** — Delete just that file

3. Show what will be deleted and confirm with the user before removing.

4. Report how many files were cleaned up.
