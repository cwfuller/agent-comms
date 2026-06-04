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

2. **Dry-run the requested mode** — the helper enforces inbox scoping in code (no hand-rolled `rm`):
   ```bash
   "$COMMS_SH" clean --as claude <mode>
   ```
   Modes: **no argument / `workspace`** (this workspace's files from your inbox `to-claude/` + `archive/` only — never Codex's unread mail), **`all`** (everything in both inboxes + archive — the only mode that touches the other agent's inbox), **`archive`** (archive/ only), or **a specific filename**.

3. Show the dry-run's "would delete" list to the user and confirm.

4. On confirmation, re-run with `--yes`:
   ```bash
   "$COMMS_SH" clean --as claude <mode> --yes
   ```

5. Report how many files were cleaned up (the helper prints the count).
