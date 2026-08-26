# Advisory carry-over

Un-actioned advisory findings from APPROVE-terminated review loops, so they survive
the loop's end (protocol v2 convention — see read-from-codex's APPROVE branch).

Reader output is newest-first. Agents read this file through `comms.sh lessons`, which
emits whole `## ` sections up to a byte budget, ordered by the date in each heading — so
physical order here may be mixed and writers may append or prepend freely. A section
whose heading carries no `YYYY-MM-DD` sorts last (but is never dropped).

## 2026-08-22 — thread `grading-pilot-14076` (auto-implement, APPROVED round 4)

The grading pilot's first slice, reviewed by codex over four rounds: ten blocking findings,
every one a real defect in code that was green at every step. Rounds 2 and 3 were mostly
defects in the round-1 *fixes*. What generalizes:

- **A retained artifact is not a reviewed artifact.** Round 1: `snapshot` kept the tree
  while the child read the live worktree, so `artifact_id` could name content nobody
  inspected. Round 2: mounting the synthetic commit *directly* was also wrong, and wrong in
  a way no content assertion could see — `HEAD` became the synthetic commit and `git diff`
  came back EMPTY, so the reviewer would fail its own head check and find no patch. The
  shape is the artifact: worktree at base → materialize → reset index to base.
  **Assert what the reviewer can SEE (HEAD, diff, untracked), never just file contents.**
- **Normalization is not identity.** `safe_name` mapped `a/b` and `a_b` to one directory, so
  a second set silently overwrote the first's stored reply. Any id that becomes a path needs
  a hash of the raw value, not a sanitized rendering of it.
- **Pair identity needs `phase`.** `/auto-full` keeps ONE thread across plan→implement and
  restarts at `round: 1`, so thread+round collides across phases. Anything keyed on a loop's
  identity must include phase or it will conflate two different artifacts.
- **Ephemeral provenance must be captured once and reused, not re-probed.** The CLI version
  was sampled at dispatch, persisted, and then re-probed after the review — so a mid-review
  upgrade made the live row disagree with its own sidecar and a rebuild rewrote history.
  Sample once; pass the value; never ask again.
- **A destructive migration needs a staging file.** `--rebuild` deleted the ledger before
  the replacement existed. Stage, validate the header, then atomic-rename.
- **Truncation of evidence is permanent under idempotence.** Claims were clipped to 600
  bytes and frozen by `finding_id`, losing the tail of 40 of the first 112 rows before
  anyone noticed. Store whole; excerpt at read time.
- **An empty field must never read as a clean result.** Drift was a blank column meaning
  both "no drift" and "could not check". It is now an explicit `same_endpoint` / `changed` /
  `unknown` tri-state, and pairs are called CANDIDATE pairs because the gating leg is still
  unbound.
- **A flag cannot promise what the caller controls.** `run --no-deliver` silenced state
  writes but codex/claude children are still *instructed* to send their own reply — the
  guarantee held only for parent-brokered reviewers. It now refuses the others outright.
- **Test comments rot into false claims.** One comment asserted a live edit between snapshot
  and read with no mutation behind it; the reviewer caught the dead claim, not a test failure.
- Un-actioned at loop end: nothing. The round-4 advisory (stale `thread+round` wording in
  docs and test labels) was fixed in the same change.

## 2026-08-22 — first live `comms.sh shadow` run (grading pilot, grok as second reviewer)

The first live shadow run of the grading pilot. It failed, informatively, and the
failure is the point — this is exactly the signal the pilot was built to collect.

- **grok reviewed for 9.5 minutes and then broke the reply contract.** The CLI exited 0
  and produced a full review, but its first line was the head_sha check
  ("HEAD matches `3c5b790…`. The") instead of the mandated
  `VERDICT: APPROVE|REQUEST_CHANGES`. The trusted-parent broker refused to stamp an
  envelope, correctly — but note what this means for grading: **a reviewer can fail the
  protocol without failing the task.** Verdict-line compliance is now a real, measured
  reviewer property, not a hypothetical.
- **A failed turn was discarding the reviewer's actual text.** The first version copied
  `result.json` and `runner.log` out of the run dir and then deleted it — throwing away
  `reply-raw.md`, i.e. the entire 9.5-minute review AND the only evidence of which
  contract broke. Fixed: raw output, events, and the result record are all preserved
  under `.comms/grades/shadow/<set>/`. **Preserve the artifact before classifying the
  failure**, always.
- **Preserved is not the same as scored.** The raw text is kept but never extracted into
  the ledger: a reply that failed the contract must not be counted as if it had passed
  it, and "reviewed and found nothing" must stay distinguishable from "never produced a
  usable review". Both lanes now have regression fixtures.
- **The prompt asks for two things in first position.** The review prompt tells the
  reviewer to compare `head_sha` with `git rev-parse HEAD` *and* to make `VERDICT:` the
  literal first line. grok obeyed the first instruction in the first position. That is a
  prompt defect as much as a reviewer defect — worth fixing before the 8-loop baseline
  runs, and if it is fixed it is a NEW `prompt_version` by definition.

## 2026-08-20 — thread grok-prompt-quality-18172 (auto-implement, MAX ROUNDS → user decision)

The grok reviewer-prompt loop hit max-rounds (4) with a blocking finding and was
resolved by user decision rather than another round. Lessons worth keeping:

- **A claim the architecture cannot keep is a defect, not wording.** "The child is
  given no mailbox path" was pinned as a criterion while the design inlines review
  prose verbatim — and reviews of THIS project name `.comms` paths and helpers by
  nature. Three rounds of fixes chased a guarantee that could not hold. Resolution
  (user-decided): path secrecy is NOT the control; the operator-applied kernel
  deny-profile is, with a runtime warning when it is not selected.
- **Test the contract you can actually check.** Assertions now target the prompt
  SCAFFOLDING (parent-written regions, quoted blocks excluded) plus a control that
  proves the fixture's quoted prose really does carry helper names. Earlier
  fixtures passed only because their synthetic prose happened to be path-free.
- **A fixture whose target thread has no history tests nothing.** The round-3
  isolation fixture passed vacuously because the prior-context path never ran.
- **Env vars are not boundaries.** `COMMS_ARCHIVE_SCOPE_THREAD` was proposed,
  implemented, reviewed, and reverted within two rounds: a child with shell access
  can `env -u` it or read the archive directly.
- **`--sandbox strict` is unusable for worktree reviews** (kernel-denies reads
  outside CWD, and a linked worktree's `.git` points at the MAIN root, so git
  itself dies). Recorded in-code so it is not re-attempted.
- Un-actioned at loop end: nothing blocking. The two round-4 advisories (character
  vs byte bound; the "never weakens" overclaim) were fixed in the same change.

## 2026-08-20 — first live /ask grok + /ask codex --via acp consults (cross-agent triage)

The first live run of each new consult path produced real findings about the grok
reviewer leg, triaged by codex over the ACP transport in the same sitting:

- **[BLOCKING-latent] `verdict_discipline_text` fails OPEN to empty** when the skill
  file it extracts from is missing — a review loop could run with NO review bar.
  Codex severity ruling: blocking-latent, fix fail-closed (abort review turns before
  the child runs; never load it for questions).
- **Consult/review instruction conflict in one prompt**: build_grok_prompt always says
  "you are a reviewer / review per the discipline below" and appends the verdict bar
  even on type: question turns whose vnote says "this is not a review". Fix: split
  the prompt on GROK_RTYPE the way the broker already splits envelope stamping.
- **The grok prompt withholds the loop-review playbook** the codex-side skill carries
  (holistic re-review on round 2+, phase-specific focus, implement checklist,
  judge-against-pinned-criteria) — later-round grok reviews would drift into
  fix-verification tunnel vision.
- **"Do not write" is loud; "inspect thoroughly" is absent**: no cwd/head_sha check,
  no lessons/archive guidance, no acceptance-criteria pointer — a cautious turn reads
  the message, skims named files, and stops.
- Positive signals: parent-stamped envelope, kernel read-only boundary, and
  fail-closed missing-VERDICT were all endorsed by the reviewer they constrain.
  Both consult transports worked first try (mailbox-headless ~90s; ACP warm session
  answered with repo-file citations at 6,302 fresh input tokens).

## 2026-08-20 — thread multi-agent-17600 (+continuation, auto-full, approved)

Multi-agent core + Grok Build reviewer shipped (registry, explicit routing
authorities, read-only grok leg with parent-stamped envelope). Field lessons the
loop itself produced, recorded so they survive its end:

- **Verdict-less reply happened live, from the reviewer** (field evidence for the
  standing DEFERRED item): round 3 arrived as `type: review-response` with the
  verdict only in a body heading — `comms.sh verdict` returned empty and validation
  passed. The meta channel corrected it within one round (the reviewer acknowledged
  and switched back to `review-feedback` + frontmatter verdict). The Claude-side
  empty-verdict termination branch remains the right fix and rises in priority.
- **Max-rounds escalation → user-authorized continuation thread worked first try**:
  the parent thread's history stayed intact, the continuation carried the criteria
  forward with an explicit amendment, and the scoped blocker closed in one bounded
  cycle. Pattern worth templating if it recurs.
- **The read-only sandbox's temp-dir carve-out** (documented in INTERNALS): grok's
  `read-only` profile keeps OS temp dirs writable, so a repo under `/tmp` or
  `/var/folders` is NOT kernel-protected — discovered because the live probe's
  mktemp fixture sat inside the carve-out and the "denial" the first probe reported
  had come from the permission layer instead. Probe fixtures for sandbox claims
  must live on a representative (non-temp) path.
- **Reviewer-probed findings dominated again**: 11 of 12 implement-phase blocking
  findings across both threads came from Codex EXECUTING candidate argv, reading
  installed vendor docs, or constructing adversarial inputs — not from reading the
  diff. Whatever review harness this project uses next must preserve the reviewer's
  ability to run things.

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

- **Resolved:** Codex now has a least-privilege persistent path instead of a per-message
  escape attempt. The global `workspace-cmux` permission profile extends `:workspace`
  and allowlists only `~/.local/state/cmux/cmux.sock`; a fresh Codex 0.145 sandbox
  reached `cmux list-workspaces` with no launch flag. `comms.sh doctor` verifies the
  effective session and `codex-permissions` prints the exact setup.
- **Resolved:** Codex skills no longer imply passive `.comms` polling or blindly repeat
  recovery from the unchanged sandbox. `blocked` means persisted but not notified;
  host-capable recovery or one manual pickup is required for an already-running legacy
  session.
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
- **Headless fan-out shares the provider rate window with the driving session**
  (DEFERRED): concurrent turns can exhaust that shared limit mid-run.
  Rate-limit preflight/coordination remains a roadmap item.

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

## 2026-08-26 — panel-arc-7972, round-4 close (max-rounds escalation)

Un-actioned advisories carried out of the loop so they survive its end:

- Retry-rebind orphans an already-answered leg (fail-safe, never false-approves, but
  an accidental retry after answers landed stalls until the new legs answer; a
  short-circuit for a still-bound valid reply would make retry cheaper). [codex+grok r4]
- The reader's field/index mismatch branch prints FAIL CLOSED but the snippet then
  proceeds with the index identity — comment and test overstate the stop. [grok r4]
- The broker's APPROVE-contradiction check gates on a case-sensitive
  `grep '^### Blocking'` next to a case-tolerant probe — leftover dual-scan on the
  stamp path; compose is unaffected (AC2 holds). Proper fix belongs to the
  scanner/probe unification: gate on `probe_field blocking` unconditionally. [codex+grok r4]
