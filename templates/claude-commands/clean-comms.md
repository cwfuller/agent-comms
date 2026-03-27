Delete messages from `.comms/` directories.

## Instructions

1. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

2. **Get the workspace name:**
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   ```

3. Based on the argument provided (use `$COMMS_ROOT` for all paths):
   - **No argument or "workspace"** — Delete all messages for the current workspace (files starting with the workspace name) from both `to-codex/` and `to-claude/`, plus `archive/`
   - **"all"** — Delete ALL messages from `to-codex/`, `to-claude/`, and `archive/`
   - **"archive"** — Delete only archived messages in `archive/`
   - **A specific filename** — Delete just that file

3. Show what will be deleted and confirm with the user before removing.

4. Report how many files were cleaned up.
