Read and act on messages from Codex in `.comms/to-claude/`.

## Instructions

1. **Resolve the shared helper** — handles comms root, workspace name, listing, validation, delivery, and archiving. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   ```

2. **List pending messages** for this workspace, newest first:
   ```bash
   "$COMMS_SH" list --as claude
   ```
   When continuing a specific loop, scope the read to that loop's thread so concurrent loops in this workspace can't consume each other's replies: `"$COMMS_SH" list --as claude --thread <thread>`.
   On an empty inbox the helper exits non-zero and reports the latest archived message on stderr — a late delivery nudge for an already-processed reply is common (the injected `/read-from-codex` queues in Claude's input box while a turn is running and submits minutes later). If that's the case, tell the user: "No pending messages — [filename] was already processed (likely a late delivery nudge for it; harmless)." Otherwise tell the user there are no messages from Codex for this workspace.

3. Read the newest pending message for each thread, not only the globally newest
   file. For multiple rounds in one thread, process the newest valid round and archive
   confirmed superseded rounds afterward.

4. **Validate the message:**
   ```bash
   "$COMMS_SH" validate "<message file>"
   ```
   This checks frontmatter delimiters, required fields (`type`, `from`, `timestamp`), workflow fields (`phase`, `round`, `max-rounds`, plus `verdict` on replies from Codex), and a non-empty body. If validation fails, **do not archive** the message. Tell the user: "Received a malformed message from Codex: [reasons from the helper]. File: [filename]". In autonomous mode, use the **error lane**: write a `type: error` reply (copy `workspace`/`workflow`/`phase`/`round`/`max-rounds`/`thread`, set `in-reply-to` to the malformed message's `message_id`, NO `verdict`, do NOT increment `round`) whose body states what is malformed and requests a clean resend, then `"$COMMS_SH" send --to codex "<error file>"`.

   **If the incoming message is `type: error`** (Codex reporting YOUR last message was malformed): fix and resend your previous message with the same `round` — an error exchange never consumes a round.

5. **Check for worktree context.** If `cwd:` differs, `cd` there before acting.
   Compare optional `head_sha:` with `git rev-parse HEAD`; if the path was repurposed,
   locate that commit/worktree instead of using unrelated current contents.

6. **Check for autonomous workflow mode.** Parse the `workflow` field from frontmatter. If it exists, follow the autonomous rules below. If not, follow the standard (manual) flow.

---

### Standard (manual) flow — no `workflow` field

1. Parse the message and summarize what Codex is saying
2. **Auto-archive — your inbox only** (the helper refuses files outside `to-claude/` and is idempotent):
   ```bash
   "$COMMS_SH" archive --as claude <files-you-just-read>
   ```
3. Ask the user how to proceed:
   - "Address all findings" — work through each item
   - "Address specific items" — let user pick
   - "Acknowledge only" — just mark as read
4. After addressing feedback, optionally `/send-to-codex`

---

### Autonomous flow — `workflow` field present

**Check termination conditions first:**

1. **If verdict is `APPROVE`** (read it normalized: `"$COMMS_SH" verdict "<file>"`):
   - Treat `APPROVE` as ship-ready. Codex may still include advisory notes; those do not reopen the loop.
   - **Carry over what would otherwise evaporate:**
     - Un-actioned `### Advisory` items → append to `docs/advisories.md` (date, thread, items) so they survive the loop's end
     - `### Process` items (meta-channel feedback) → append to the project's friction log / roadmap so they drive protocol changes
   - If `workflow: auto-full` and `phase: plan` → **Transition to implement phase:**
     - **Archive the approval message first** (`"$COMMS_SH" archive --as claude "<file>"`) — this prevents a re-triggered `/read-from-codex` from re-reading the stale approval and double-firing the implement phase
     - Notify user: "Plan approved after N rounds. Starting implementation..."
     - `"$COMMS_SH" lessons --surface "<implementation area>"` (bounded) — the plan was
       lesson-checked at draft time, but implementation surfaces new specifics
     - Implement the approved plan
     - **Live-validate when the change is model- or runtime-coupled** (a model call, network API,
       daemon): run the real surface once before handing off — green unit tests alone have shipped
       wrong premises into review rounds before
     - Write the implement-phase message with updated frontmatter: `phase: implement`, `round: 1`, same `workflow`, `max-rounds`, and `thread`
     - Include a pinned `## Acceptance criteria` section (3-7 testable statements — carry
       the approved plan's criteria forward if the plan pinned them, else derive them now).
       Later rounds are judged against these; the bar does not move with each holistic pass,
       and later rounds copy the section forward verbatim, changing it only through a clearly
       identified explicit amendment ("(amended round N: reason)")
     - Deliver: `"$COMMS_SH" send --to codex "<file>"`
   - Otherwise → **Stop. Notify user:** "Approved after N rounds." Archive: `"$COMMS_SH" archive --as claude "<file>"`, then close the thread's state: `"$COMMS_SH" state complete "<thread>"`

2. **If `round >= max-rounds`:**
   - **Stop. Escalate to user:** "Max rounds (N) reached. Remaining blocking issues from Codex:" then list the unresolved blocking findings.
   - Archive the message via the helper.

3. **If verdict is `REQUEST_CHANGES` and round < max-rounds:**
   - **Auto-address all blocking findings** from Codex's message
   - Advisory findings are optional. Fix them when they are cheap, clearly correct, or naturally part of the same change, but do not extend the loop just to polish non-blocking issues.
   - For plan workflows: refine the plan based on findings
   - For implement workflows: fix the code based on findings
   - **Write the reply** to `$COMMS_ROOT/to-codex/`:
     - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_round-N-$RANDOM.md` (N is the incremented round number; the `$RANDOM` suffix prevents same-second filename collisions)
     - Increment `round` by 1; keep same `workflow`, `phase`, `max-rounds`, and `thread`
     - Set `message_id` (filename sans `.md`) and `in-reply-to` (the incoming message's `message_id`)
     - **Keep the message body focused on stable context, not fix narration.** Do NOT narrate what you fixed per finding — that anchors the reviewer on verification instead of re-review. Instead include:
       - The latest Codex findings bundle from the prior round under a clear heading like `## Prior review context`, framed as stable context rather than an exhaustive checklist
       - For plan: the full updated plan content (so Codex can re-read it fresh)
       - For implement: `git diff --stat` showing changed files
       - **Stable metadata** (always include): what validation ran (typecheck, tests, lint), whether they passed, and any non-obvious constraints or gotchas
       - For implement rounds: the current `## Acceptance criteria`, copied forward VERBATIM
         from the previous round's message — this is the canonical bar once the round-1 inbound
         is archived. Change it only through a clearly identified explicit amendment (annotate
         the changed criterion with "(amended round N: reason)"). An amendment proposal alone
         is non-blocking — it gates nothing unless the underlying issue independently satisfies
         verdict discipline
       - A `### Scope additions` running ledger: one line per review-driven addition beyond
         the original task (what + rough cost). Copy the ledger forward verbatim each round and
         append — scope growth stays visible at every checkpoint instead of emergent. Omit the
         section only while it is empty
       - Brief one-line note: "Addressed N findings from round X. Please re-review holistically."
       - The standing `## Meta — process feedback requested` section (process friction under `### Process`, never verdict-gating)
   - **Validate, deliver, and archive the inbound in one atomic step** — the helper refuses to archive if the outbound is malformed:
     ```bash
     "$COMMS_SH" send --to codex "<your reply file>" --archive-inbound "<the incoming message file>"
     ```
     On `RESULT: blocked`, execute the exact `RECOVER:` line once; relay only the final
     non-`delivered` result.
     <!-- loopspec:fragment result-spawned-exception -->
     Exception — `RESULT: spawned` (headless mode, `COMMS_DELIVERY=headless`): the Codex turn is running detached; await the printed run dir as a background task (`.../runphase.sh await "<run dir>"`), then `/read-from-codex`. A non-zero await means the turn failed or timed out (check its `result.json`) — report that instead of waiting for a reply.
     <!-- /loopspec:fragment -->

---

## Known failure modes (compounding section — when a loop teaches a new one, add it HERE)

This section exists so process lessons land in the skill itself, not only in chat history or a project
friction log. The update rule: when process friction recurs or a new failure mode is confirmed, edit the
TEMPLATE in the agent-comms repo (`templates/claude-commands/read-from-codex.md`) and re-copy to the
installed location(s) — an installed-only edit is lost on the next install.

- **Truncate-before-read when post-processing a written message file.** Substituting placeholders with a
  one-liner that opens the WRITE handle before reading the same file (e.g.
  `open(p,"w").write(open(p).read().replace(...))` evaluated left-to-right) TRUNCATES the file first →
  a malformed/empty message; `send` refuses it and correctly does NOT archive the inbound. Always read
  into a variable FIRST, then write — and `head -3` the file before `send` as a cheap sanity check.
- **Never re-derive `thread` — copy it verbatim from the inbound message.** Observed: a reply's
  thread was rebuilt from the REVIEW FILE's random suffix (`...-policy-48271`) instead of the
  original (`...-policy-32664`), because both look like "the loop's id". The outbound still
  delivered, so nothing failed loudly — but the thread-scoped inbox lookup
  (`list --as claude --thread <thread>`) then reported NO pending message for the real thread and
  emitted a workspace-mismatch warning, while the reply sat there unread. Thread is an identity
  copied forward, not a value computed per round; only `message_id` changes each round.
  RECURRED 2026-08-18 despite this note (thread typed from a remembered suffix while
  composing the reply heredoc). The guard must be MECHANICAL, not a review step: capture
  `THREAD=$(grep -m1 '^thread:' "<inbound>" | sed 's/^thread: //')` and interpolate
  `$THREAD` into the reply — never type a thread value by hand, and still diff before `send`.
- **Unit-green ≠ live-correct for model/runtime-coupled changes.** A fix whose premise concerns a live
  surface (model latency/behavior, network API shape, daemon lifecycle) can pass every unit test and
  still fail live — observed: an item-count cap passed all suites while the real model call still
  stalled (the premise was size, not count). Live-validate once before the implement handoff.

---

**If an argument is provided**, treat it as a filter (e.g., "only the latest", "all messages", a specific filename).
