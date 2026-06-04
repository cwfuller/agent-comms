Delete messages from `.comms/` directories.

## Instructions

1. **Resolve the shared helper** for comms root and workspace name. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```

2. Based on the argument provided (use `$COMMS_ROOT` for all paths):
   - **No argument or "workspace"** — Delete this workspace's messages (files starting with the workspace name) from **your inbox (`to-claude/`) and `archive/` only**. Do NOT touch `to-codex/` — that's Codex's inbox and may hold messages Codex hasn't read yet; deleting those requires explicit `all`.
   - **"all"** — Delete ALL messages from `to-codex/`, `to-claude/`, and `archive/` (both inboxes — this is the only mode that deletes the other agent's unread mail)
   - **"archive"** — Delete only archived messages in `archive/`
   - **A specific filename** — Delete just that file

3. Show what will be deleted and confirm with the user before removing.

4. Report how many files were cleaned up.
