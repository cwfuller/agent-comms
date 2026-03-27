---
name: read-from-claude
description: Read and act on messages from Claude Code in .comms/to-codex/
metadata:
  short-description: Read handoff messages from Claude Code
---

# Read From Claude

Read and act on messages from Claude Code via the local `.comms/to-codex/` directory.

## Instructions

1. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

2. **Get the workspace name** for filtering:
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   ```

3. **List matching messages** using this exact command:
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms" && WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]') && find "$COMMS_ROOT/to-codex" -maxdepth 1 -type f -name "${WORKSPACE}_*" | sort -r
   ```
   If no files are returned, tell the user there are no messages from Claude for this workspace.

4. Read the most recent matching message (or all if user asks).

5. **Validate the message.** Before acting on it, check:
   - The file starts with `---` and has a closing `---` (valid frontmatter)
   - Required fields are present: `type`, `from`, `timestamp`
   - If `workflow` is present: `phase`, `round`, `max-rounds` must also be present
   - The body below frontmatter is not empty
   If validation fails, **do not archive** the message. Tell the user: "Received a malformed message from Claude: [describe what's wrong]. File: [filename]". In autonomous mode, send an error reply back to Claude requesting a clean resend.

6. **Check for worktree context.** If the message has a `cwd:` field that differs from your current directory, `cd` to that path before reading or reviewing any files. This ensures you're looking at the correct worktree branch.

7. **Check for autonomous workflow mode.** Parse the `workflow` field from frontmatter. If it exists, follow the autonomous rules below. If not, follow the standard flow.

---

### Standard flow — no `workflow` field

1. Parse the frontmatter and content:
   - **type: review-request** — Review the listed files, focusing on the "Review focus" section.
   - **type: response** — Claude addressed your previous feedback. Check the fixes, then do a fresh scoped re-review.
   - **type: question** — Claude is asking for input. Answer based on codebase analysis.
   - **type: ping** — Simple connectivity test. Respond with an acknowledgment.
2. **Auto-archive:** Move processed message(s) to `$COMMS_ROOT/archive/` (create if needed).
3. After completing the review or task, use `$send-to-claude` to write your findings back.

---

### Autonomous flow — `workflow` field present

**Act immediately without waiting for user input.** This is an autonomous review cycle.

**Round semantics:** `round` counts review passes. Claude sends round 1, you review it. If you REQUEST_CHANGES, Claude fixes and sends round 2. You review again. The loop stops when you APPROVE or round reaches max-rounds. Your last possible review is at round == max-rounds.

**Your review approach depends on the round number:**

#### Round 1 — Full contextual review
Use the "Review focus" and context provided by Claude to understand the scope, then review thoroughly:
- `phase: plan` — Focus on: completeness, architecture decisions, missed requirements, risks, scalability concerns. Are all edge cases covered? Is the approach sound?
- `phase: implement` — Focus on: bugs, logic errors, security issues, edge cases, code quality. Skip style nits — report blocking issues and only high-signal advisory notes.

#### Round 2+ — Holistic re-review with stable context
**Do NOT just verify whether Claude fixed your previous findings.** That leads to tunnel vision where you miss new issues introduced by the fixes, or issues you overlooked in round 1.

Re-review the current state holistically. Previous findings are stable context, not the scope. Keep scope, constraints, risk areas, and the latest findings bundle in view, but do not narrow yourself to checking items off one by one:
- Re-read the changed files with a blank checklist
- Scan for issues you may have missed in earlier rounds — you were likely anchored on specific areas before
- Check for regressions or new problems introduced by the fixes
- `phase: plan` — Re-read the entire plan holistically. Does it still hold together after revisions?
- `phase: implement` — Re-read all changed files. Run through the implement review checklist below.

#### Implement review checklist (every round)
Run through this checklist every round, not just the final one:
- Auth/scopes: are permissions correct for any new API calls or resources?
- State transitions: are all status/phase changes valid and complete?
- All entry points: are all callers/consumers of changed code accounted for?
- Async paths: are post-success and post-error paths both handled?
- Tests/types/imports: are tests present, types correct, imports clean?

#### Final round (round == max-rounds)
In addition to the checklist above, do an explicit broad quality sweep:
- Test coverage for new/changed code
- Type safety across boundaries
- Dead imports or unused code
- Consistency with project conventions

#### Review bar and verdict discipline
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

**After reviewing, determine your verdict:**
- `APPROVE` — Ship-ready. Advisory comments may still be present.
- `REQUEST_CHANGES` — Blocking issues must be addressed before approval.

**Send your review immediately via `$send-to-claude`.** The message MUST preserve the workflow metadata. Use `$send-to-claude` which will copy `workflow`, `phase`, `round`, `max-rounds` into your reply frontmatter along with your `verdict`.

**Auto-archive** the incoming message to `$COMMS_ROOT/archive/` (create if needed).

**Important:** In autonomous mode, do NOT ask the user how to proceed. Review and respond immediately. The loop continues until you APPROVE or max rounds are reached.

---

## Message Format

Messages are markdown files with frontmatter:

```markdown
---
type: review-request | response | question | ping
from: claude
timestamp: ISO 8601
branch: branch-name
workspace: workspace-name
cwd: /path/to/working/directory                     # if in a worktree, cd here before reviewing
workflow: auto-plan | auto-implement | auto-full    # optional, triggers autonomous mode
phase: plan | implement                              # optional
round: 1                                             # optional
max-rounds: 3                                        # optional
---
```
