# Advisory carry-over

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
