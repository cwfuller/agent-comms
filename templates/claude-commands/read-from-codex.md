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
   This checks frontmatter delimiters, required fields (`type`, `from`, `timestamp`), workflow fields (`phase`, `round`, `max-rounds`, plus `verdict` on replies from Codex), and a non-empty body.

   **Derive the reviewer BEFORE acting on validation results** — the extractor emits the FIRST `from:` field (matching the helper's first-field parse, so validation and routing always select the same sender) and ONLY after seeing BOTH frontmatter delimiters (a missing close must yield empty, never fall through into body text; CRLF tolerated); the value is registry-checked:
   ```bash
   REVIEWER=$(awk '{sub(/\r$/,"")} NR==1 && $(0)!="---" {exit} NR>1 && $(0)=="---" {ok=1; exit} NR>1 && !seen && index($(0),"from:")==1 {v=$(0); sub(/^from:[[:space:]]*/,"",v); seen=1} END {if (ok) print v}' "<message file>")
   "$COMMS_SH" agents | tr ' ' '\n' | grep -qx "$REVIEWER" || REVIEWER=""
   ```
   If `REVIEWER` comes back empty (missing/unclosed frontmatter, or a missing or unregistered `from:`), FAIL CLOSED: report the malformed message to the user and do NOT route an error reply anywhere.

   If validation fails, **do not archive** the message. Tell the user: "Received a malformed message from Codex: [reasons from the helper]. File: [filename]". In autonomous mode, use the **error lane**: write a `type: error` reply (copy `workspace`/`workflow`/`phase`/`round`/`max-rounds`/`thread`, set `in-reply-to` to the malformed message's `message_id`, NO `verdict`, do NOT increment `round`) whose body states what is malformed and requests a clean resend, then `"$COMMS_SH" send --to "$REVIEWER" "<error file>"` — using the reviewer derived above; with an empty `REVIEWER` there is nowhere trustworthy to route, so stop at the user report.

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

### Harness friction — record it the moment you hit it

If anything about the TOOL went wrong during this loop — a false verdict, a parser that
found nothing, a message in the wrong inbox, a transport that did not do what
`transport` said it would — record it in one line, immediately:

```bash
"$COMMS_SH" friction --thread "<thread>" --severity 4 "compose reported 0 findings on replies that used numbered lists"
```

Severity 1 is cosmetic, 5 means the harness produced a WRONG RESULT. Do not save it for
the end and do not decide it is too small — a false all-clear from a list-form parser
survived an entire real loop because the only record of it was a human noticing
afterwards. This costs one line and goes to `.comms/friction.tsv`; reviewers never see it.

### Reviewer performance note — EVERY round, no exceptions

Before reporting a round's outcome to the user, record how the reviewer performed:

```bash
"$COMMS_SH" round-note "<the reviewer's reply file>" --note "<one or two lines>"
```

Counts (blocking/advisory) are derived from the reply — never typed. The prose is YOUR
assessment, and it is the part worth reading a month from now:

- what it caught that actually mattered;
- anything it got wrong, or filed as blocking that was not;
- anything it missed that another reviewer or a later round found;
- for a panel round, who caught what the other did not.

Then surface the same one-liner to the user alongside the verdict. Two rules:

- **A reviewer never sees its own note.** It goes to `.comms/grades/rounds.tsv` and to
  the human. A reviewer that can read its scorecard optimises the scorecard.
- **Write it even when the round was clean.** "Approved, no findings, nothing missed" is
  a data point; a gap in the log reads as a round nobody assessed.

Over time `rounds.tsv` is how you see which reviewer is carrying which kind of work —
the observation that one model was vastly superior in a given phase should be visible in
the log, not only in memory.

### Panel rounds — when the message carries `review_set`

A panel leg is an ordinary 2-party `review-feedback`; what changes is that **one leg is
not the round**. If the inbound carries `review_set:`, do NOT act on it alone:

```bash
SET="$(grep -m1 '^review_set:' "<inbound>" | sed 's/^review_set: *//')"
"$COMMS_SH" panel status  --set "$SET"     # which legs have answered
"$COMMS_SH" compose --set "$SET"           # exits non-zero while any leg is missing
```

- **`compose` refuses a partial panel.** An unanswered leg is not an approval. Archive the
  leg you just read, say which reviewers are still out, and stop — the loop resumes when
  the set completes.
- **When it composes, work the composition, not the union.** Fix the **corroborated**
  findings, the gating reviewer's blockers, and any uncorroborated blocker that
  independently meets verdict discipline. **Do NOT auto-address every blocking bullet from
  every reviewer** — that is `any-blocks` through the back door, and it is how one noisy
  reviewer holds the loop hostage.
- **Still split after one confirmation round → escalate to the user**, same lane as
  max-rounds. The human is the only adjudicator this protocol admits.
- **Round N+1 re-dispatches the whole panel** with `panel dispatch`, at the new round.
  Never reply to one leg and leave the others on the old artifact: `compose` is
  round-scoped, so a half-advanced set reports incomplete forever.
- Record a `round-note` per leg, not one for the panel — performance is per reviewer.

### Autonomous flow — `workflow` field present

**The reviewer is the `REVIEWER` derived mechanically in step 4** (frontmatter-bounded,
registry-checked — same rule as the thread capture: never type it by hand).
In a SINGLE-REVIEWER loop, every continuation in this flow — round-2+ replies, the
error lane, and the plan→implement handoff — writes to `$COMMS_ROOT/to-$REVIEWER/` and
sends `--to "$REVIEWER"`. Never assume codex: an initial `--reviewer grok` loop must
keep the SAME reviewer for its entire lifecycle.

**In a PANEL loop (the inbound carries `review_set:`), the panel IS the reviewer** and
the Panel rounds section above overrides every `--to "$REVIEWER"` below: continuations
are authored ONCE as a `review-request` on the BASE thread and fanned with
`panel dispatch --to <roster>` — round 2+, and the plan→implement handoff alike. A
panel-approved plan implemented under one leg silently sheds the rest of the panel;
the roster is captured mechanically from the set index, never from memory:
```bash
REQ_MID="$(grep -m1 '^in-reply-to:' "<the inbound reply>" | sed 's/^in-reply-to: *//')"
SETS="$COMMS_ROOT/grades/sets.tsv"
SET="$(awk -F'\t' -v m="$REQ_MID" 'NR>1 && $(2)==m {print $(1); exit}' "$SETS")"
ROSTER="$(awk -F'\t' -v s="$SET" 'NR>1 && $(1)==s {print $(10)}' "$SETS" | paste -sd, -)"
```
(Only the error lane stays per-leg: a malformed reply is one leg's problem and its
error reply routes to that leg's reviewer alone.)

**Check termination conditions first:**

1. **If verdict is `APPROVE`** (read it normalized: `"$COMMS_SH" verdict "<file>"`):
   - Treat `APPROVE` as ship-ready. The reviewer may still include advisory notes; those do not reopen the loop.
   - **Carry over what would otherwise evaporate:**
     - Un-actioned `### Advisory` items → append to `docs/advisories.md` (date, thread, items) so they survive the loop's end
     - `### Process` items (meta-channel feedback) → append to the project's friction log / roadmap so they drive protocol changes
   - If `phase: plan` → **Transition to implement phase.** Keyed on the PHASE, never on
     the workflow's value: there is one loop command now (`/auto`), and `--plan` is a flag
     on it rather than a separate workflow name. Any approved plan phase continues into
     implementation on the same thread.
     - **Archive the approval message first** (`"$COMMS_SH" archive --as claude "<file>"`) — this prevents a re-triggered `/read-from-codex` from re-reading the stale approval and double-firing the implement phase
     - Notify user: "Plan approved after N rounds. Starting implementation..."
     - `"$COMMS_SH" lessons --surface "<implementation area>"` (bounded) — the plan was
       lesson-checked at draft time, but implementation surfaces new specifics
     - Implement the approved plan
     - **Live-validate when the change is model- or runtime-coupled** (a model call, network API,
       daemon): run the real surface once before handing off — green unit tests alone have shipped
       wrong premises into review rounds before
     - Write the implement-phase message with updated frontmatter: `phase: implement`,
       `round: 1`, same `workflow` and `thread`. **Do NOT copy `max-rounds` from a plan
       message** — the plan phase is capped at 2, and carrying that forward gives
       implementation 2 rounds instead of its real budget. Restore it from the plan
       message's `loop-rounds:` field; if that field is absent (a pre-2026-08-26 loop),
       fall back to 5 and say so in the handoff. The implement phase gets its OWN full
       budget — the phases do not share one. Capture it mechanically, never by
       memory. The APPROVAL REPLY YOU ARE HOLDING is the source — reviewers preserve
       `loop-rounds` onto their replies and the broker stamps it mechanically, so the
       field is in hand at the handoff; the thread's state file (`loop_rounds`) and the
       archived plan message are the fallbacks, in that order:
       ```bash
       LOOP_ROUNDS="$(grep -m1 '^loop-rounds:' "<the approval reply you just read>" | sed 's/^loop-rounds: *//')"
       [ -n "$LOOP_ROUNDS" ] || LOOP_ROUNDS="$(sed -n 's/.*"loop_rounds": "\([^"]*\)".*/\1/p' "$COMMS_ROOT/state/${WORKSPACE}_${THREAD}.json" 2>/dev/null | head -1)"
       [ -n "$LOOP_ROUNDS" ] || LOOP_ROUNDS=5
       ```
       *(grok found the starvation; codex found the fix had no durable source — the
       field now rides reply frontmatter and thread state, not memory.)*
     - Include a pinned `## Acceptance criteria` section (3-7 testable statements — carry
       the approved plan's criteria forward if the plan pinned them, else derive them now).
       Later rounds are judged against these; the bar does not move with each holistic pass,
       and later rounds copy the section forward verbatim, changing it only through a clearly
       identified explicit amendment ("(amended round N: reason)")
     - Deliver to the SAME review surface that approved the plan:
       - Single-reviewer loop: write it into `$COMMS_ROOT/to-$REVIEWER/` and
         `"$COMMS_SH" send --to "$REVIEWER" "<file>"`.
       - Panel loop: author it as `type: review-request` on the BASE thread and
         `"$COMMS_SH" panel dispatch --to "$ROSTER" "<file>"` — the WHOLE roster that
         reviewed the plan (captured mechanically above) reviews the implementation;
         handing it to one approving leg sheds the rest of the panel at the exact
         moment the change grows a diff. (codex + grok, panel r1.)
   - Otherwise → **Stop. Notify user:** "Approved after N rounds." Record the reviewer
     performance note (see above), archive: `"$COMMS_SH" archive --as claude "<file>"`,
     then close the thread's state: `"$COMMS_SH" state complete "<thread>"`

2. **If `round >= max-rounds`:**
   - **Stop. Escalate to user:** "Max rounds (N) reached. Remaining blocking issues from the reviewer:" then list the unresolved blocking findings.
   - Archive the message via the helper.

3. **If verdict is `REQUEST_CHANGES` and round < max-rounds:**
   - **Panel loop: this branch fires on the COMPOSITION, not on one leg** — gate on
     `compose` per the Panel rounds section, work the composed findings, then author the
     next round ONCE as a `review-request` on the base thread and re-dispatch with
     `panel dispatch --to "$ROSTER"` instead of the single-reviewer `send` below.
   - **Record the reviewer performance note first** (see above) — before fixing anything,
     while the review's quality is still fresh and unmixed with your own work.
   - **Auto-address all blocking findings** from the reviewer's message
   - Advisory findings are optional. Fix them when they are cheap, clearly correct, or naturally part of the same change, but do not extend the loop just to polish non-blocking issues.
   - For plan workflows: refine the plan based on findings
   - For implement workflows: fix the code based on findings
   - **Write the reply** to `$COMMS_ROOT/to-$REVIEWER/`:
     - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_round-N-$RANDOM.md` (N is the incremented round number; the `$RANDOM` suffix prevents same-second filename collisions)
     - Increment `round` by 1; keep same `workflow`, `phase`, `max-rounds`, and `thread`
     - Set `message_id` (filename sans `.md`) and `in-reply-to` (the incoming message's `message_id`)
     - **Keep the message body focused on stable context, not fix narration.** Do NOT narrate what you fixed per finding — that anchors the reviewer on verification instead of re-review. Instead include:
       - The latest reviewer findings bundle from the prior round under a clear heading like `## Prior review context`, framed as stable context rather than an exhaustive checklist
       - For plan: the full updated plan content (so the reviewer can re-read it fresh)
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
     "$COMMS_SH" send --to "$REVIEWER" "<your reply file>" --archive-inbound "<the incoming message file>"
     ```
     On `RESULT: blocked`, execute the exact `RECOVER:` line once; relay only the final
     non-`delivered` result.
     <!-- loopspec:fragment result-spawned-exception -->
     Exception — `RESULT: spawned` (headless mode, `COMMS_DELIVERY=headless`): the peer agent's turn is running detached; await the printed run dir as a background task (`.../runphase.sh await "<run dir>"`), then `/read-from-codex`. A non-zero await means the turn failed or timed out (check its `result.json`) — report that instead of waiting for a reply.
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
