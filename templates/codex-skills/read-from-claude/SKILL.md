---
name: read-from-claude
description: Read and act on messages from Claude Code in .comms/to-codex/
metadata:
  short-description: Read handoff messages from Claude Code
---

# Read From Claude

Read and act on messages from Claude Code via the local `.comms/to-codex/` directory.

## Instructions

1. **Resolve the shared helper** — the same script Claude's commands use, so both sides derive identical workspace names and comms paths. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   ```

2. **List pending messages** for this workspace, newest first:
   ```bash
   "$COMMS_SH" list --as codex
   ```
   When continuing a specific loop, scope the read to that loop's thread so concurrent loops in this workspace can't consume each other's replies: `"$COMMS_SH" list --as codex --thread <thread>`.
   On an empty inbox the helper exits non-zero and reports the latest archived message on stderr. If the latest archived message is recent, tell the user: "No pending messages — [filename] was already processed (likely a late delivery nudge; harmless)." Otherwise say there are no messages from Claude for this workspace.

3. Read the newest pending message for **each thread**, not only the globally newest
   file. This prevents a busy thread from starving an older actionable review. When a
   thread has multiple pending rounds, compare `round` and `timestamp`, process the
   newest valid round, then archive superseded rounds after confirming they belong to
   that same thread.

4. **Validate the message:**
   ```bash
   "$COMMS_SH" validate "<message file>"
   ```
   Checks frontmatter delimiters, required fields (`type`, `from`, `timestamp`), workflow fields (`phase`, `round`, `max-rounds`), and a non-empty body. If validation fails, **do not archive** the message. Tell the user: "Received a malformed message from Claude: [reasons]. File: [filename]". In autonomous mode, use the **error lane**: write a `type: error` reply (copy `workspace`/`workflow`/`phase`/`round`/`max-rounds`/`thread`, set `in-reply-to` to the malformed message's `message_id`, NO `verdict`, same `round`) stating what is malformed and requesting a clean resend, then `"$COMMS_SH" send --to claude "<error file>"`.

   **If the incoming message is `type: error`** (Claude reporting YOUR last reply was malformed): fix and resend your previous reply with the same `round` — an error exchange never consumes a round.

5. **Check for worktree context.** If the message has a `cwd:` field that differs from your current directory, `cd` there before reviewing. Compare optional `head_sha:` with `git rev-parse HEAD`; if the path was repurposed, locate that commit/worktree instead of reviewing unrelated current contents.

6. **Check for autonomous workflow mode.** Parse the `workflow` field from frontmatter. If it exists, follow the autonomous rules below. If not, follow the standard flow.

---

### Standard flow — no `workflow` field

1. Parse the frontmatter and content:
   - **type: review-request** — Review the listed files, focusing on the "Review focus" section.
   - **type: response** — Claude addressed your previous feedback. Check the fixes, then do a fresh scoped re-review.
   - **type: question** — Claude is asking for input (sent via `/ask`, formerly `/ask-codex`). Answer based on codebase analysis and the `## Current Thinking` section. Reply with `type: response` and no `verdict`. Body: `## Summary` + `## Codex Take`. Skip review framing — this is a one-off consult, not a review.
   - **type: ping** — Simple connectivity test. Respond with an acknowledgment.
2. **Auto-archive — your inbox only** (the helper refuses files outside `to-codex/` and is idempotent):
   ```bash
   "$COMMS_SH" archive --as codex <files-you-just-read>
   ```
3. After completing the review or task, use `$send-to-claude` to write your findings back.

---

### Autonomous flow — `workflow` field present

**Act immediately without waiting for user input.** This is an autonomous review cycle.

**Round semantics:** `round` counts review passes. Claude sends round 1, you review it. If you REQUEST_CHANGES, Claude fixes and sends round 2. You review again. The loop stops when you APPROVE or round reaches max-rounds. Your last possible review is at round == max-rounds.

**Your review approach depends on the round number:**

#### Round 1 — Full contextual review
Use the "Review focus" and context provided by Claude to understand the scope, then review thoroughly:
- **Consult recorded lessons first** (bounded — a known token cost however large the log grows):
  `"$COMMS_SH" lessons --surface "<keyword for this change's surface>"`. Exit 3 means "you have the
  newest; older ones are named by path", not an error. A plan that repeats a recorded lesson or
  ignores a relevant advisory is a finding — cite the entry. This is cheap and catches the
  "system knowledge existed but wasn't consulted" class of issues.
- `phase: plan` — Focus on: completeness, architecture decisions, missed requirements, risks, scalability concerns. Are all edge cases covered? Is the approach sound?
- `phase: implement` — Focus on: bugs, logic errors, security issues, edge cases, code quality. Skip style nits — report blocking issues and only high-signal advisory notes.

#### Round 2+ — Holistic re-review with stable context
<!-- loopspec:fragment holistic-rereview -->
**Do NOT just verify whether the author fixed your previous findings.** That leads to tunnel vision where you miss new issues introduced by the fixes, or issues you overlooked in round 1.

Re-review the current state holistically. Previous findings are stable context, not the scope. Keep scope, constraints, risk areas, and the latest findings bundle in view, but do not narrow yourself to checking items off one by one:
- Re-read the changed files with a blank checklist
- Scan for issues you may have missed in earlier rounds — you were likely anchored on specific areas before
- Check for regressions or new problems introduced by the fixes
<!-- /loopspec:fragment -->
- `phase: plan` — Re-read the entire plan holistically. Does it still hold together after revisions?
- `phase: implement` — Re-read all changed files. Run through the implement review checklist below.

**Judge against the pinned `## Acceptance criteria` when the round-1 implement message carries
them: the approval bar is those criteria and the verdict discipline — it does not move with each
holistic pass.** Later rounds copy the section forward verbatim; treat the copy in the newest
message as canonical. A genuinely new mandatory ask beyond the pinned criteria is an explicit
criteria amendment to propose (or an Advisory note), never a silent widening of REQUEST_CHANGES
scope — and an amendment proposal alone is non-blocking: it gates the verdict only if the
underlying issue independently satisfies the verdict discipline above.

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
<!-- loopspec:fragment verdict-discipline -->
Default to `APPROVE`. Each failed review creates another fix+review loop, so only block when the issue is truly ship-stopping.

Use `REQUEST_CHANGES` only for blocking issues such as:
- Broken correctness or logic
- Security or permission problems
- Data loss or state corruption risk
- Broken user flow or incomplete required behavior
- Likely regressions in changed paths
- Missing validation or tests for risky code where the change cannot be trusted without them

Pre-existing defects in code the change did not touch are Advisory by default — real and worth recording, but not this loop's scope unless the change makes them worse or depends on them.

Keep `APPROVE` and include comments when findings are advisory, such as:
- Documentation drift
- Minor cleanup or maintainability improvements
- Style or preference nits
- Nice-to-have tests on otherwise low-risk changes
<!-- /loopspec:fragment -->

Verdict values: `APPROVE` / `REQUEST_CHANGES` (the canonical `pass` / `fail` spellings are accepted synonyms — `comms.sh verdict` normalizes both).

#### Process feedback (meta channel)
If the incoming message carries a `## Meta` section requesting process feedback: report friction with the comms process itself (delivery, archive sequencing, message shape, round semantics) under a `### Process` heading in your reply's Findings. Process feedback never gates the verdict — do not REQUEST_CHANGES over it.

**After reviewing, determine your verdict:**
- `APPROVE` — Ship-ready. Advisory comments may still be present.
- `REQUEST_CHANGES` — Blocking issues must be addressed before approval.

**Send your review immediately via `$send-to-claude`.** The message MUST preserve the workflow metadata (`workflow`, `phase`, `round`, `max-rounds`) and add your `verdict`. `$send-to-claude`'s atomic send archives the incoming message only after your reply is validated and delivery attempted.

**Important:** In autonomous mode, do NOT ask the user how to proceed. Review and respond immediately. The loop continues until you APPROVE or max rounds are reached.

---

## Sandbox & permissions

Read-only helper commands run directly. The persistent, no-flag delivery fix is a global
Codex permission profile that extends `:workspace` and allowlists only `cmux.sock`;
`"$COMMS_SH" codex-permissions` prints the exact config. Apply it once and restart Codex.

If an older or managed session returns `RESULT: blocked`, the reply is persisted but
Claude was **not** notified. Do not claim passive polling, resend, or repeat the same
sandboxed helper. Execute `RECOVER:` only from a host or separately approved context
that can reach cmux; otherwise request one manual `/read-from-codex`.

## Message Format

You are reading the frontmatter, not authoring it — `comms.sh validate` is authoritative and
the reply schema you DO author lives in `$send-to-claude`. The full field reference is
`docs/PROTOCOL.md` (and normatively `docs/loopspec/SPEC.md`); read it only if a field is
unclear.
