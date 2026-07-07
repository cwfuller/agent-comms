# Advisory carry-over

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

- **Bare `deliver` doesn't refresh `last_delivery`** (v2.2 candidate): after a successful
  manual `comms.sh deliver` retry, state still shows the old `manual`/`failed` outcome
  until the thread's next `send`. `status`'s ACTION line now says so explicitly; the
  proper fix is `deliver` taking an optional thread/message argument so it can update
  state on success.
- **Surface-id reuse during optimistic delivery** — documented as accepted residual risk
  in PROTOCOL.md (identity is unverifiable without a tree read).

Un-actioned advisory findings from APPROVE-terminated review loops, so they survive
the loop's end (protocol v2 convention — see read-from-codex APPROVE branch).

## 2026-06-04 — thread `protocol-v2-9331` (PR 3, auto-implement, approved r3)

- **Manual-pickup state-key mismatch outside cmux** (v2.1 hardening candidate): without
  cmux, `send` keys thread state on the fallback (branch) workspace, which can diverge
  from a cmux-scoped message's filename prefix. Normal cmux-scoped sends key correctly,
  and message/archive paths stay correct either way — the gap is only that state lookups
  may miss. Proper fix: carry one workspace identity in state/frontmatter from loop start.
