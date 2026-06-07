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

2. **Resolve the shared helper** — the same script Claude's commands use, so both sides derive identical workspace names and comms paths. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```

3. **Create a timestamped markdown file** in `$COMMS_ROOT/to-claude/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_<short-slug>-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions)
   - Use the current timestamp

4. Use this format. **If the incoming message had `workflow` fields, you MUST copy them into your reply:**

   In autonomous review loops:
   - Default to `verdict: APPROVE`
   - Use `verdict: REQUEST_CHANGES` only for blocking issues that are not ready to ship
   - Put non-blocking notes under `Advisory` while keeping `APPROVE`
   - Put comms-process friction under a `### Process` heading (meta channel) — it never gates the verdict
   - Do not use `COMMENT` in autonomous review loops; reserve it for manual questions or side-channel notes

   When answering a `type: question` from `/ask-codex`:
   - Use `type: response`
   - Omit `verdict` entirely — questions are not reviews
   - Body shape: `## Summary` (one line) + `## Codex Take` (your answer, with reasoning and tradeoffs). No `## Findings`, no blocking/advisory split.

```markdown
---
type: review-feedback | response | question | request | error
from: codex
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace name from step 2>
cwd: <current working directory>
message_id: <this file's name, without .md>
thread: <copy from incoming message if present — identifies the loop>
in-reply-to: <message_id of the message you're responding to, if any>
workflow: <copy from incoming message if present — auto-plan | auto-implement | auto-full>
phase: <copy from incoming message if present — plan | implement>
round: <copy from incoming message if present>
max-rounds: <copy from incoming message if present>
verdict: <APPROVE | REQUEST_CHANGES | COMMENT — omit when answering a question or sending type: error>
---

## Summary
<One-line summary of your message>

## Findings
<For reviews: list blocking issues separately from advisory notes>

### Blocking
- <file:line> — description of issue

### Advisory
- <file:line> — description of non-blocking risk, cleanup, or suggestion

### Process
- <comms-process friction or improvement suggestions, if any — never verdict-gating>

## Questions
<Any questions for Claude to address>
```

5. **Write safely.** Use a heredoc with quoted delimiter (`<<'EOF'`) or write via a tool that does not interpolate shell variables or backticks in the body. Never embed the message body inside an interpolated shell string — Markdown backticks will be evaluated.

6. **Validate, deliver, and archive in one atomic step.** The helper validates your reply (frontmatter delimiters; `type`, `from`, `timestamp`; workflow fields plus `verdict` since the reply is from codex; non-empty body), refuses to deliver or archive if malformed, nudges Claude's pane via cmux (vim-mode-aware), and only then archives the incoming message from your inbox. **`send` touches the cmux socket — run it through your approved shell wrapper (see "Sandbox & permissions" below). The wrapper resolves the helper inside the child shell, since a parent `$COMMS_SH` is NOT visible there:**
   ```bash
   /bin/zsh -lc 'C=$(git worktree list --porcelain 2>/dev/null|head -1|sed "s/^worktree //")/.agent-comms/comms.sh; [ -x "$C" ]||C="$HOME/.agent-comms/comms.sh"; "$C" send --to claude "<your reply file>" --archive-inbound "<the incoming message file>"'
   ```
   Relay the final `RESULT:` line to the user verbatim whenever it is not `delivered` — a manual, blocked, or failed outcome means Claude was NOT woken.
   Without cmux the helper degrades to "manual pickup" (and still archives the inbound — the reply is verified on disk). A mid-sequence cmux failure is reported as `delivery FAILED` and recorded in the thread's state file; the reply stays safely on disk — retry with `"$COMMS_SH" send --to claude "<reply file>"` (re-attempts the nudge AND refreshes the recorded delivery state). `send` updates `.comms/state/<workspace>_<thread>.json` automatically for workflow messages.

7. Confirm to the user that the message was verified and delivery attempted.

## Sandbox & permissions (read before step 6)

`send` and `deliver` touch the **cmux socket** (`cmux.sock`), which is normally OUTSIDE a
restricted sandbox's allowed roots. So for these two commands, in Codex:

- **Run them through your approved shell wrapper from the start** — do not call them
  bare and wait for a failure. **The wrapper must resolve the helper path *inside* the
  child shell** — a parent-shell `$COMMS_SH` is not exported into `/bin/zsh -lc`, so it
  expands to empty there:
  ```bash
  /bin/zsh -lc 'C=$(git worktree list --porcelain 2>/dev/null|head -1|sed "s/^worktree //")/.agent-comms/comms.sh; [ -x "$C" ]||C="$HOME/.agent-comms/comms.sh"; "$C" send --to claude "<reply file>" --archive-inbound "<inbound>"'
  ```
  (Read-only commands — `validate`, `list`, `archive`, file reads — don't touch the
  socket and are fine to run directly with your resolved `$COMMS_SH`.)
- **If you see `Operation not permitted` on `cmux.sock` (or the helper prints "cmux
  socket is outside this sandbox"), do NOT request escalation** — that is exactly what
  produces the user's permission prompt. Re-run the *same* command through the
  `/bin/zsh -lc '...'` wrapper. The helper itself prints the exact wrapper line on this
  failure.
- Request escalation only if no approved wrapper exists at all, and scope it to the
  `comms.sh` path — never a blanket grant.
- A permission prompt during send is an invocation issue, **not** a protocol failure —
  verify the reply file on disk, archive state, and the `RESULT:` line before diagnosing
  a comms regression.

If the user provides specific instructions, incorporate them into the appropriate section.
