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
   <!-- loopspec:fragment verdict-discipline -->
   Default to `APPROVE`. Each failed review creates another fix+review loop, so only block when the issue is truly ship-stopping.

   Use `REQUEST_CHANGES` only for blocking issues such as:
   - Broken correctness or logic
   - Security or permission problems
   - Data loss or state corruption risk
   - Broken user flow or incomplete required behavior
   - Likely regressions in changed paths
   - Missing validation or tests for risky code where the change cannot be trusted without them

   Keep `APPROVE` and include comments when findings are advisory, such as:
   - Documentation drift
   - Minor cleanup or maintainability improvements
   - Style or preference nits
   - Nice-to-have tests on otherwise low-risk changes
   <!-- /loopspec:fragment -->
   Additionally, in loop replies:
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
head_sha: <git rev-parse HEAD>
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

6. **Validate, deliver, and archive in one atomic step.** The helper validates your reply (frontmatter delimiters; `type`, `from`, `timestamp`; workflow fields plus `verdict` since the reply is from codex; non-empty body), refuses to deliver or archive if malformed, attempts the cmux nudge, records state, and then archives the processed inbound:
   ```bash
   "$COMMS_SH" send --to claude "<your reply file>" --archive-inbound "<the incoming message file>"
   ```
   If it returns `RESULT: blocked`, follow **Sandbox & permissions** below — the single home for that path.
   <!-- loopspec:fragment result-headless-codex-side -->
   Exceptions in headless mode (`COMMS_DELIVERY=headless`): `RESULT: manual — headless mode: the reply is on disk...` is EXPECTED when you are the spawned peer (the driving session picks your reply up when your turn ends — do not retry). `RESULT: spawned` means a detached headless Claude turn is now processing your message: await the printed run dir (`.../runphase.sh await "<run dir>"`), then `$read-from-claude` for the reply; a non-zero await means the turn failed or timed out — check its `result.json` and report that instead of waiting.
   <!-- /loopspec:fragment -->
   Without cmux the helper degrades to "manual pickup" (and still archives the inbound — the reply is verified on disk). A non-sandbox mid-sequence cmux failure is reported as `delivery FAILED`; retry the send once. `send` updates `.comms/state/<workspace>_<thread>.json` automatically for workflow messages.

7. Confirm to the user that the message was verified and delivery attempted.

## Sandbox & permissions (read before step 6)

`send` and `deliver` touch `cmux.sock`. Some Codex sandboxes block that access even
inside `/bin/zsh -lc`, while allowing direct approved `cmux send`/`send-key` commands.
Run the helper normally. On `RESULT: blocked`, execute its exact `RECOVER:` line once;
the final `reconcile` segment runs only after every direct cmux step succeeds. Do not
request escalation, retry the wrapper, or resend after successful recovery. Read-only
commands (`validate`, `list`, `archive`, file reads) remain direct.

If the user provides specific instructions, incorporate them into the appropriate section.
