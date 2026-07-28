# Advisory carry-over

Un-actioned advisory findings from APPROVE-terminated review loops, so they survive
the loop's end (protocol v2 convention — see read-from-codex's APPROVE branch).

Reader output is newest-first. Agents read this file through `comms.sh lessons`, which
emits whole `## ` sections up to a byte budget, ordered by the date in each heading — so
physical order here may be mixed and writers may append or prepend freely. A section
whose heading carries no `YYYY-MM-DD` sorts last (but is never dropped).

## 2026-07-28 — thread `token-efficiency-23269` (auto-full, plan r4 + implement r3, approved)

Bounded the two unbounded runtime reads and trimmed hot-path instruction text. Findings the
loop produced that are NOT actioned by it, so they survive its end:

- **Queued-nudge accumulation** (DEFERRED, observed live, twice — 4 then 6 identical
  `/read-from-codex` in one input box): the cmux nudge is keystroke injection, so every
  round handoff while Claude is mid-turn enqueues *another* copy. Each reported `delivered`
  because cmux accepted the keys; none represented pickup. Worse than the known single
  late-nudge case because it accumulates without bound. Fix shape: detect a busy target or
  an already-queued reader command and coalesce/debounce instead of enqueueing.
- **`RESULT: manual` emits no `RECOVER:` chain** (DEFERRED): "active cmux + unreadable tree +
  no cached binding" makes `pick_surface` return empty and `cmd_deliver` bail *before* the
  RECOVER emit, so the 2026-07-28 recovery work never fires on a cold `.comms/.cache`. The
  harness is blind to it: the cmux stub's `tree` arm always succeeds and the sandbox
  assertions run right after a `bind`. Fix shape: classify the tree-read failure and emit
  direct `cmux tree` → `bind <target> surface:N` → `deliver`, which primes the cache
  permanently.
- **`RESULT: delivered` on an unverified pane fallback** (DEFERRED): the first-other-pane
  guess collapses into plain `delivered`. Caching the guess makes rounds 2+ report `bound`,
  so provenance must be recorded in the cache before the RESULT mapping can change.
- **Read-only workspace resolution costs ~2.6 s per call under the Codex sandbox**
  (DEFERRED, reported every round of this loop): full `cmux tree` retry/backoff runs before
  the cached fallback. Consider cache-first resolution, keeping backoff only for genuinely
  transient empty output.
- **`send-to-codex.md` has no workflow-carry-over guard** (DEFERRED): `send-to-claude/SKILL.md:29`
  has one; `send-to-codex.md` does not, and its frontmatter block carries no
  workflow/phase/round/thread. Such a reply validates clean and drops out of the loop. Live
  on the interactive path and the headless claude leg.
- **A verdict-less workflow reply falls through every termination branch** (DEFERRED):
  `comms.sh` binds the verdict requirement to `type: review-feedback` (correct per SPEC), but
  both prompts state the superseded *sender* rule. Fix the Claude-side empty-verdict branch
  first — it closes the hole regardless of what the Codex prompt says.
- **`runphase` timeout is wall-clock-only with no salvage** (DEFERRED): gates the cmux-default
  flip. Idle-detection on `events.ndjson` plus printing the recorded session id for
  `codex resume` / `claude --resume`.
- **`status` fires ACTION NEEDED on healthy `spawned`/`held` threads** (DEFERRED): the gate
  ignores `last_delivery` and hardcodes 900 s against 15–60 min turns.
- **`sorted_message_files` made `status`/`list` O(archive)** (DEFERRED): ~10 ms per archived
  file; ~0.9 s at 49 files, ~17 s at 1200. Not urgent; fix by stopping at the first match for
  the single-file archive hint rather than capping the window.

## 2026-07-28 — asymmetric Codex sandbox delivery incidents

- **Resolved:** `/bin/zsh -lc` is no longer presented as a universal sandbox escape.
  A blocked nested helper emits one direct-cmux `RECOVER:` chain whose final guarded
  segment reconciles `last_delivery` after success.
- **Resolved:** `status`/`stalled` now expose an aged message still present in the target
  inbox even when a prior nudge reported `delivered`; accepted keystrokes are explicitly
  not treated as peer pickup.
- **Resolved:** empty-inbox archive hints filter by workspace, reader direction, and
  optional thread, then order by protocol timestamp with mtime fallback.
- **Resolved:** current `cmux tree` markers and UUID-valued `CMUX_WORKSPACE_ID` have a
  regression fixture; cache warnings distinguish unavailable output from parse drift.
- **Resolved:** senders include optional `head_sha`, and readers verify it when a delayed
  message's `cwd` was repurposed.

## 2026-07-07 — symphony audit-fix arc field report (7 headless turns, 4 threads, driving-session feedback)

Dogfooded headless delivery end-to-end on symphony's maintenance-audit arc (threads
`audit-batch1-governor-safety-17474` … `audit-batch4-signal-shaping-hygiene-7873`; 4 loops, one
3-round). Zero message/state-layer failures; two protocol-visible findings and several polish items.

- **[P1] Wall-clock runner timeout killed an ACTIVE reviewer mid-verdict** (batch-3 thread): the
  cross-stack review legitimately ran past the 1800s default; runphase killed it (exit 124) while
  events.ndjson shows it executing the reply-filename `date` commands — the full review completed and
  the verdict died unwritten. ~30 min of Codex work lost; re-delivery re-ran the whole review.
  Diagnosability was GOOD (exit 124 + the result.json hint + `stalled` showing `last_delivery=timeout`).
  Fix candidates, in value order: (a) idle-timeout on events.ndjson silence instead of (or alongside)
  wall-clock — wall-clock alone guarantees the longest/most-thorough reviews die at their most
  expensive moment; (b) salvage on timeout — result.json already records the codex session_id; when a
  killed turn produced no message file, print (or auto-run once) the `codex resume` continuation;
  (c) raise the default to 3600s — observed normal implement-review turns run 15–60 min.
- **[P1] cmux `send` false-positive `RESULT: delivered`**: with no Codex pane open, delivery fell back
  to "first other-pane terminal" and still reported plain `delivered`; the loop idled silently until
  `stalled` was run by hand (17 min). Downgrade the fallback RESULT line (e.g.
  `delivered-unverified (unbound terminal fallback)`) and hint `COMMS_DELIVERY=headless`.
- **[P2] Headless peer-reply `RESULT: manual` is misleading** — the reviewer itself had to explain in a
  Process note that manual ≠ failure in this mode. Rename to e.g. `written-for-pickup (headless)`.
- **[P2] Reviewer-sandbox environment notes are sender tribal knowledge** — `MIX_NO_SYNC=1` had to be
  hand-embedded in every review request. A per-repo `reviewer-notes` block in `.comms/config` (or
  runphase template injection) would make it durable. (Reinforces the `.comms/config` prerequisite.)
- **[P3] Spawn output could advertise recovery affordances** (`stalled`, `runphase.sh hold`) so a run
  dir is self-documenting if the driving session dies; an `await` heartbeat option would distinguish
  "long review" from "hung runner" for humans; `send` validates an already-validated file (noise).
- **Positive signals worth keeping**: headless reviewers ran their own probes/validation suites every
  round and caught two real bugs (a phase-filtered ledger lookup, a marker-lifecycle leak) — review
  depth went UP vs cmux; re-delivery after a timeout kill (same message file, new spawn) left
  thread/round state perfectly coherent; `--archive-inbound` composes with headless; multi-round
  threads and cmux/headless interleaving were non-events.

## 2026-07-06 — thread `headless-claude-leg-13020` (headless step 2, auto-implement)

- **Bash heredoc write hung 2m in a live headless claude child** (DEFERRED) (observed once,
  first live claude turn): `cat > file <<'EOF'` into `.comms/to-codex/` sat until
  SIGTERM with nothing written; the Write tool succeeded immediately on the same
  path. Root cause unknown (possibly stdin plumbing in the `claude -p < prompt`
  runner). Soak-watch: if it recurs, teach the headless prompt to prefer
  non-heredoc writes.
- **Per-thread holds do not block thread-less one-shots** (DEFERRED) (by design — `hold` with
  no argument covers everything), and **bare `deliver` resolves only the newest
  pending message**, so a held thread's newest message shadows retries for other
  threads — pass an explicit file to retry a specific message.
- **Reverse-topology terminal APPROVE produces no reply** (DEFERRED): a headless claude turn
  consuming a final APPROVE ends the loop (advisories, state complete) without an
  outbound message, so a Codex driver's await sees `completed` with an empty
  inbox. Interpretation: await-completed + empty inbox + thread state
  `status=complete` = loop finished, not a lost reply.
- **Implement-turn timeout can strand a half-modified working tree** (DEFERRED): headless
  write turns run on the real checkout with no dirty-tree guard yet; a timeout
  KILL mid-implementation leaves partial edits that a naive retry builds on top
  of. Mitigations until the guard exists: generous `COMMS_RUNPHASE_TIMEOUT_SECS`
  for implement turns, and inspect `git status` before re-sending after a timeout.
- **Headless fan-out shares the provider rate window with the driving session** (DEFERRED)
  (observed live: a 20-agent review workflow exhausted the Claude session limit
  mid-run). Rate-limit preflight/coordination is a roadmap item (the symphony
  surplus_burn interplay from the unification plan).

## 2026-06-05 — thread `optimistic-binding-28566` (v2.1.1, auto-implement, approved r1)

- **Resolved 2026-07-28 via emitted direct recovery + `reconcile`:** after a successful
  manual `comms.sh deliver` retry, state still shows the old `manual`/`failed` outcome
  until the thread's next `send`.
- **Surface-id reuse during optimistic delivery** — documented as accepted residual risk
  in PROTOCOL.md (identity is unverifiable without a tree read).

## 2026-06-04 — thread `protocol-v2-9331` (PR 3, auto-implement, approved r3)

- **Manual-pickup state-key mismatch outside cmux** (v2.1 hardening candidate): without
  cmux, `send` keys thread state on the fallback (branch) workspace, which can diverge
  from a cmux-scoped message's filename prefix. Normal cmux-scoped sends key correctly,
  and message/archive paths stay correct either way — the gap is only that state lookups
  may miss. Proper fix: carry one workspace identity in state/frontmatter from loop start.
