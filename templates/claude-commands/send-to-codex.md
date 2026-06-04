Send a structured handoff message to Codex via `.comms/to-codex/` and auto-deliver it.

## Instructions

1. Gather context about what was just done:
   - Detect the default branch with `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`, falling back to `main` if unavailable
   - Run `git diff <default-branch> --stat` to get changed files
   - Run `git log <default-branch>..HEAD --oneline` if on a branch, otherwise `git log -5 --oneline` for recent commits
   - Read any active plan or task context from the conversation
   - **Detect worktree:** Run `pwd` to get the current working directory. If it differs from the main repo root, include it as `cwd:` in the frontmatter so Codex knows where to look.

2. **Resolve the shared helper** — handles comms root, workspace name, validation, delivery, and archiving. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```
   **ALWAYS write messages to `$COMMS_ROOT/to-codex/`** — this lands in the main repo's `.comms/` even when running from a worktree.

3. **Write the message file** to `$COMMS_ROOT/to-codex/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_<short-slug>-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions)
   - Write with a quoted heredoc (`<<'EOF'`) or a non-interpolating tool so backticks and dollar signs in the body are never evaluated
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

4. **Validate and deliver** — `send` refuses malformed messages (frontmatter delimiters, required fields, non-empty body) and degrades to manual pickup without cmux:
   ```bash
   "$COMMS_SH" send --to codex "<path of the message file you wrote>"
   ```

5. Confirm to the user that the message was verified and delivery attempted.

**If the user provides specific instructions** (e.g., "tell codex to focus on the error handling"), incorporate those into the Review focus section.

**If there's an argument provided**, treat it as additional context or specific review instructions to include.
