# agent-comms roadmap

Backlog from the 2026-06-04 multi-agent audit (64 agents, 56 raw findings → 49 confirmed
after adversarial verification) plus field reports from three agents running the loops
daily. Items are grouped into sequenced PRs. Check items off as they land.

## PR 1 — verified bug fixes (small, independent)

**Status: implemented 2026-06-04, Codex-approved (auto-implement loop, 2 rounds).**

- [x] **read-from-codex.md** — APPROVE + `auto-full`/plan→implement branch never archives
  the consumed approval message; a re-triggered `/read-from-codex` can re-read it and
  double-fire the implement phase. Add the idempotent archive to the transition branch.
- [x] **install.sh:14** — `curl | bash` leaves `${BASH_SOURCE[0]}` unbound; the swallowed
  error makes `SCRIPT_DIR` resolve to **cwd**, so a cwd containing `templates/` is
  misdetected as a local checkout and foreign files get installed (reproduced). Guard with
  `${BASH_SOURCE[0]:-}`. Also silences the `set -u` stderr leak on every piped run.
- [x] **install.sh** — `local` scope installs shadowing files but never warns (excluded
  from `warn_local_shadowing` *and* missing from the `local)` dispatch branch). Print a
  dedicated "these now shadow any global install" note.
- [x] **install.sh** — gitignore robustness: append can swallow the separator when the
  existing `.gitignore` lacks a trailing newline; `grep -qF '.comms/'` false-matches
  substrings (use line-anchored match). Also gitignore `.codex/AGENTS.md` boilerplate.
- [x] **fleet.md dispatch** — never checks the *named* target's own pane state before
  `/new`; below `FLEET_MAX` it clobbers a running loop. Classify the target's Claude pane
  and abort if active unless `--force`.
- [x] **fleet.md dispatch-all** — free-list is computed before user confirmation and never
  re-validated at fire time (TOCTOU). Re-run the spinner check per-fire; skip+report
  targets no longer idle.
- [x] **fleet.md** — fresh-shell contract: step 2 claims `fleet_preflight` is defined in
  shared-vars but it lives in its own section; dispatch/harvest/clear consume `FLEET_LIST`
  without rebuilding it. Make every block self-contained or move definitions where claimed.
- [x] **fleet.md** — `/tmp/_fleet_free.$$` → `mktemp` + trap (match `fleet_preflight`'s
  existing pattern); orphaned on unhandled abort today.
- [x] **fleet.md** — `sed 's/--plan-first//g; s/--force//g'` corrupts brief paths containing
  those substrings and the `case *--plan-first*` substring-match flips mode; parse flags as
  whole tokens (both dispatch and dispatch-all).
- [x] **fleet.md** — `sort` → `sort -V` so `ws-10` doesn't precede `ws-2` in status/
  dispatch-all assignment tables.
- [x] **fleet.md** — remove dead `status: complete` branches (dispatch-all, harvest, prose):
  nothing in the protocol ever writes it; `verdict: APPROVE` is the only real done-signal.
  (Protocol v2's `state.json` supersedes the idea properly.)
- [x] **clean-comms.md** — no-arg default deletes the *other agent's unread inbox* and the
  shared archive. Default should clean own inbox + archive only; require explicit `all`
  for cross-inbox deletion, with the existing confirm step.
- [x] **send-to-claude/SKILL.md** — duplicate step "4" numbering; "workspace name from
  step 2" points at the wrong step.
- [x] **send templates** — timestamp-second filename collisions under rapid sends: add a
  short random suffix to the filename convention.
- [x] **README** — document the **vim-mode requirement** (Codex→Claude delivery types `i`
  before the command — breaks without vim mode), **python3** requirement for `/fleet`,
  fix the reply `type` enum (`review-feedback`), document `/clean-comms` args and its
  workspace-scoped default.
- [x] **ALL templates — `$N` argument-substitution corruption** *(discovered live while
  dogfooding `/auto-implement` on this repo)*: Claude Code substitutes bare `$0`–`$9` and
  `$ARGUMENTS` in command markdown at render time (`$0` = first arg word), and **no escape
  mechanism exists** (confirmed against official docs). Every embedded awk `$0`/`$2` and
  bash `"$*"`/`"$2"` is corrupted whenever a command is invoked with arguments — the
  rendered awk picker silently returns no surface, which is a likely root cause of the
  field-reported "delivery silently fails / Codex is slow" symptom. Fix: awk fields
  written as `$(0)`/`$(2)` (same semantics, survives substitution); fleet captures args
  via the documented `$ARGUMENTS` token and passes function inputs through named
  `FLEET_*` vars instead of positional params. PR 2 eliminates the class entirely by
  moving code into installed script files. Consider filing an upstream Claude Code issue
  requesting an escape syntax.

## PR 2 — shared comms helper (the token-efficiency project)

**Status: implemented 2026-06-04 (Codex loop in progress).** Templates: 1,537 → 732 lines
(-52%); fleet.md 511 → 68 (-87%). Test harness: 53 checks green (hermetic, stubbed cmux).
Adversarial self-review before handoff caught 2 blocking bugs (dispatch-all exit-vs-skip;
fm() unbounded frontmatter scan) — both fixed with regression tests.

- [x] Ship installed helper scripts `~/.agent-comms/{comms.sh,fleet.sh}` (local pin at
  `<repo>/.agent-comms/`): `root`, `workspace`, `list --as`, `validate`, `archive --as`
  (own-inbox, idempotent), `deliver claude|codex`, `send --to ... --archive-inbound ...`,
  `status`; fleet engine with status/dispatch/dispatch-all/harvest/clear.
- [x] Port the **hardened** workspace block into the helper so the Claude and Codex sides
  provably cannot drift (both sides resolve via the same script).
- [x] Shrink every template to helper calls (also kills the `$N` substitution class for
  all extracted code — scripts on disk are never rendered).
- [x] `install.sh` installs helpers for global and local scopes (remote/curl path too);
  `.agent-comms/` gitignored on project init; shadow warning + pin note cover helpers.
- [x] Atomicity: `comms.sh send --archive-inbound` refuses to deliver/archive on a
  malformed outbound (the interrupted-turn corruption two Codex reviewers hit).
- [x] Repeatable shell test harness (`tests/run.sh`, Codex's meta-channel ask): 53 checks,
  stubbed cmux with call log, throwaway git fixtures, bash+zsh callers, both blockers
  regression-tested.

Deferred from PR 2 (follow-ups):
- [x] `comms.sh clean` subcommand so `/clean-comms` gets the same guardrails as archive
  (own-inbox default enforced by code, not prose) — landed in PR 3.
- [ ] Harness coverage for the remote/curl install path (local http.server fixture).

Token notes beyond the extraction:
- `read-from-codex.md` round messages: keep "stable context, not fix narration" (it's the
  design's best idea) but cap the prior-findings bundle at the latest round only (already
  the rule — enforce it) and reference plan *files* by path instead of re-embedding full
  plan text when the plan lives in-repo.
- `fleet.md` is loaded in full for `/fleet help` — cheap win: helper script prints usage.

## PR 3 — protocol v2 (from the field reports + audit)

**Status: implemented 2026-06-04 (Codex loop pending).** Harness: 79 checks green.

- [x] **Threading:** `message_id` + `thread:` + `in-reply-to` in *both* directions;
  `comms.sh list --thread` scopes reads so concurrent loops in one workspace can't
  consume each other's replies. Soft-required (validate warns, doesn't reject) so
  in-flight pre-v2 loops survive a mid-loop template upgrade.
- [x] **State:** `.comms/state/<workspace>_<thread>.json` written automatically by
  `comms.sh send` for workflow messages (workflow/phase/round, awaiting_from,
  awaiting_since, last_sent, last_delivery); `state get|list|complete`; fleet status
  surfaces `owes=<agent> <N>m` from it.
- [x] **Delivery ack + liveness:** deliver reports delivered / manual-pickup /
  **FAILED mid-sequence** explicitly (Codex r3 Process ask); outcome recorded in state;
  `comms.sh stalled [minutes]` lists threads awaiting a reply too long — the recovery
  surface for dropped nudges.
- [x] **Error lane:** `type: error` (verdict-free, never consumes a round) wired into
  both read skills' malformed-message paths + both message-format specs.
- [x] **Advisory carry-over:** read-from-codex's APPROVE branch now appends un-actioned
  advisories to `docs/advisories.md` (date, thread, items) and `### Process` items to the
  friction log before closing the loop.
- [x] **Verdict normalization:** `comms.sh verdict <file>` (trim/uppercase); fleet gates
  on `norm_verdict` so `" approve"` still terminates a loop.
- [x] **`comms.sh clean`** (deferred from PR 2): guarded delete with dry-run default,
  own-inbox `workspace` mode enforced in code; `/clean-comms` is now a thin wrapper.
- [x] **Meta/process-feedback channel:** loop messages carry a standing `## Meta` section
  asking the reviewer to flag friction with the comms process *itself* (delivery, archive,
  message shape, round semantics) separately from code findings; meta feedback never gates
  the verdict and gets appended to the friction log / this roadmap on loop close. (Requested
  by user 2026-06-04; first used in the PR1 review loop, round 2.)

## v2.1 — delivery identity & resilience (field-driven, 2026-06-04)

**Status: implemented (Codex loop pending).** Driven by a live multi-terminal workspace
incident: an intermittently-empty `cmux tree` broke surface picking ("could not find a
claude surface") AND flapped workspace identity (splitting state files between the cmux
name and the branch-name fallback); a manual recovery then nudged the wrong of two
Claude tabs.

- [x] `cmux_tree()` retries (3×) — one un-retried, error-swallowed call was the shared
  root cause of the picker failure and the identity flap.
- [x] **Latent abort fixed:** with cmux active but tree output unmatched, the workspace
  pipeline's no-match grep killed the whole helper under `set -euo pipefail` (verified);
  parsing is now failure-tolerant.
- [x] **Workspace identity cache** per cmux workspace (`.comms/.cache/ws-*`): one good
  resolution sticks; flaky reads reuse it (with a warning) instead of flapping to
  `master` and splitting state.
- [x] **Agent-aware delivery:** `comms.sh bind <agent> surface:N` pins the target;
  successful deliveries auto-cache the working surface; bindings are ignored if the
  surface vanishes. Picker preference is bound → first other-pane terminal (tab order),
  with the convention that the live agent is the FIRST tab. Delivery output names the
  surface and the selection reason.
- [x] **Loud outcomes:** `send` ends with a `RESULT: delivered|manual|failed` line and
  every template instructs the agent to relay non-delivered results verbatim — a quiet
  manual outcome previously read as "sent".

### v2.1.1 follow-up (field incident #2, 2026-06-05)

A bound target was discarded because the tree read used to *verify* it failed —
the verification gate became the single point of failure ("guard the whole path",
again). Fixes: bindings are used optimistically when the tree is unreadable (a dead
surface fails the send loudly and retryably instead of silently going manual);
`cmux_tree` retries now back off across ~2.5s instead of bursting inside one
contention window; every empty pick emits a stderr diagnostic (target, workspace id,
binding, tree contents); `status` prints `ACTION NEEDED` when the newest thread's
last delivery wasn't a real nudge.

## Friction log (meta-channel feedback + live-loop observations)

- *2026-07-28, thread `token-efficiency-23269` (auto-full, 4 plan + 3 implement rounds,
  approved):* the loop's own transport was the loudest source of friction, twice observed
  from the Codex side: **4 then 6 identical `/read-from-codex` commands queued in Claude's
  input box** while a long turn ran. Each handoff reported `delivered` because cmux accepted
  the keystrokes; none was pickup. This generalizes the known single "phantom
  /read-from-codex" entry from *benign replay* to *unbounded accumulation*, and it shares a
  root cause with two other open items (`delivered` on an unverified pane fallback; no
  `RECOVER:` chain on the `manual` lane). Fix shape: coalesce/debounce when a reader command
  for the same target is already queued, or detect a busy target and defer. Recorded in
  docs/advisories.md with the rest of the loop's carry-over.
- *2026-07-28, same loop (process win):* the review caught three data-loss paths in an
  installer rewrite that the implementation's own test suite passed cleanly — nested/duplicate
  markers, marker text quoted inline, and marker lines inside a **fenced code block**. All
  three were user-content destruction, and each was found by the reviewer *constructing a file
  the author had not imagined* rather than by reading the diff. Lesson: when a change rewrites
  a file the user may have edited, ownership must be **proven** (exact full lines, counted,
  fence-aware) rather than **pattern-matched** — and the fixtures must assert byte-identity of
  the whole file, not the survival of a sentinel string.

- *2026-07-28, asymmetric Codex sandbox incident:* nested `comms.sh` and the documented
  `/bin/zsh -lc` wrapper both remained socket-blocked, while direct approved
  `cmux send`/`send-key` succeeded. Fix: blocked delivery now emits one direct `RECOVER:`
  chain ending in guarded state reconciliation; current skills execute it once and only
  surface a final failure. Also fixed direction/thread/time-aware archive hints, current
  cmux-tree parsing coverage, aged-unread observability, and delayed-worktree `head_sha`.
- *2026-07-28, follow-up on current Codex 0.145:* direct recovery also remained inside
  the sandbox in several live sessions, so persistence was reliable but Codex → Claude
  notification was still broken. Durable fix: make a `workspace-cmux` permission profile
  the global Codex default, extending `:workspace` and allowlisting only the cmux Unix
  socket. `comms.sh doctor` now tests the real boundary and `codex-permissions` prints the
  no-launch-flag setup. Blocked-session guidance no longer promises passive polling or
  tells agents to retry the unchanged sandbox.
- *2026-06-07, field incident #3 (Codex sandbox):* Codex proactively requested escalated
  permissions for the helper send, prompting the user every loop round — running the
  helper plainly (or via the session's approved shell wrapper) needs no prompt at all.
  Skills now forbid proactive escalation, prescribe wrapper-retry-then-scoped-escalation,
  and state that permission prompts are an invocation issue, never a protocol failure.
- *2026-06-07, field incident #3c (the wrapper itself was broken):* the wrapper-first
  fix told Codex to run `/bin/zsh -lc '"$COMMS_SH" send ...'` — but `$COMMS_SH` is a
  non-exported parent-shell var, empty in the child `zsh -lc`, so the recovery command ran
  an empty program. Fix: skills' wrapper now resolves the helper path INSIDE the child
  shell (self-contained one-liner); the helper's emitted hint and the new `RESULT: blocked`
  line both use the script's own LITERAL absolute path (`$0`), never `$COMMS_SH`. Lesson:
  a recovery command must be copy-paste-correct with zero hidden shell state — the safe
  path has to survive being the *only* thing that runs.
- *2026-06-07, field incident #3b (same loop, precise root cause):* the v1 fix made the
  wrapper a *fallback*, but Codex's sandbox biases toward escalating on the FIRST failure.
  Exact cause: `send`/`deliver` touch `cmux.sock`, outside the sandbox roots →
  `Operation not permitted`. Fix: skills now say run the two cmux-touching commands
  through the wrapper **from the start** (read-only commands stay direct), with the
  explicit "`cmux.sock` not permitted → wrapper, do NOT escalate" rule; and the helper
  itself now detects the socket sandbox signature on a failed deliver and prints the exact
  wrapper command instead of a generic FAILED. Lesson: a fallback the reviewer must
  *remember* to take loses to a platform default that fires first — make the safe path the
  default path.
- *2026-06-05, field incident #2:* send returned `RESULT: manual` despite an
  existing binding to a live surface — pick_surface required a successful tree read
  BEFORE consulting the binding, so a transient tree failure (3 burst retries inside one
  contention window, likely while a background terminal attached) discarded a known
  target. The new RESULT contract worked (Codex relayed it; the loop didn't silently
  stall — the human was told). Fixed in v2.1.1.
- *2026-06-05, field (multi-terminal workspace):* Codex's reply never woke Claude —
  picker found no surface, workspace flapped between cmux name and branch fallback
  (duplicate split state files), and a manual re-nudge hit the second of two Claude tabs.
  Root causes and fixes above (v2.1). Lesson: any cmux read used for identity or
  targeting needs retry + memory; "some other terminal" is not an agent identity.
- *2026-06-05, v2.1 loop r2 (Codex, Process — live-fire validation):* the cmux tree flake
  recurred DURING the review session itself; the new identity cache absorbed it ("using
  cached workspace") with no flap and no failed delivery. Fix validated in production
  while under review.

- *2026-06-04, PR1 loop r2 (Codex):* stable-context message shape endorsed; remaining
  friction is that validating prompt-embedded shell requires manually extracting and
  re-running snippets — reviewer-dependent. PR 2's shared helper + a small test harness
  makes shell-portability checks repeatable. → folded into PR 2 scope.
- *2026-06-04, "phantom /read-from-codex" explained (seen in another workspace and this repo's
  PR1 loop):* the delivery nudge is keystroke injection into Claude's INPUT BOX — if Claude
  is mid-turn, the injected command queues and only submits when the current turn ends,
  often minutes later. Meanwhile a file-watcher (or manual read) already consumed the reply,
  so the late nudge fires `/read-from-codex` against an empty inbox. It LOOKS like a
  premature/cross-session trigger relative to Codex's visible state; it's actually a stale
  nudge from the PREVIOUS round. Benign but confusing. Mitigations: empty-inbox handler now
  reports the latest archived message so the user sees "already processed" instead of "no
  messages" (shipped post-PR1); full fix is PR 3 reconciliation (state.json + in-reply-to).
- *2026-06-04, PR1 loop (observed):* argument-less invocation renders bare dollar-zero as
  EMPTY (not left literal) — the old installed read-from-codex rendered `match(, ...)`,
  invalid awk. The substitution corruption class affects no-arg invocations too.
- *2026-06-04, PR2 (observed):* the first test-harness run inherited the live session's
  `CMUX_WORKSPACE_ID` and real cmux — "no cmux" tests resolved the real workspace and one
  deliver test **sent an actual keystroke nudge to the live Codex pane**. Tests against
  agent-comms must be hermetic: `env -u CMUX_WORKSPACE_ID` + PATH-stubbed cmux, and
  canonicalize fixture paths (`pwd -P`) for macOS `/var` → `/private/var`.
- *2026-06-04, PR2 (process win):* adversarial self-review before handoff caught 2
  blocking bugs the reviewer would have bounced — pre-hardening measurably shortens loops
  (matches the earlier field report).
- *2026-06-04, PR2 loop r3 (Codex):* helper extraction + tests/run.sh "substantially
  improves reviewability." Remaining friction: a live cmux send can fail AFTER outbound
  validation and BEFORE archive — inbound is safely preserved, but the failure surfaces
  only as a terse command result. → PR 3 delivery-ack/liveness item should make
  send report delivery outcome explicitly (and write the .delivered marker only on
  confirmed nudge).
- *2026-06-04, PR2 loop (observed):* rounds 1→3 each caught a successively narrower edge
  of the same dispatch-all free-predicate state machine (--force dropped → pending scan
  missing → no-archive bypass of the pending scan). Lesson: when a reviewer flags one
  branch of a predicate, self-audit the full state matrix before resending — would have
  collapsed three rounds into two.
- *2026-06-04, PR3 loop r2 (Codex, Process):* outside cmux, `send` keys thread state on
  the fallback (branch) workspace, which can diverge from a cmux-scoped message's prefix —
  the audit's original workspace-divergence class resurfacing at the state layer. Mitigated
  by the resolved-vs-frontmatter mismatch warning; proper fix is a single workspace
  identity carried in state/frontmatter from loop start (v2.1 candidate).
- *2026-06-04, PR3 loop (observed):* "the guard covers the changed branch, not the whole
  path" recurred twice more (state-write guard missed mkdir; norm_verdict sweep missed the
  restructured dispatch-all site). When making a crosscutting change, grep for ALL sites of
  the old pattern — including ones restructured earlier in the same PR.

- *2026-06-04, docs loop r2 (Codex, Process — positive):* an interrupted archive left a
  stale round-1 message in Codex's inbox alongside round 2; Codex identified it as stale
  via the v2 thread/round fields, reviewed only the newer round, and archived the stale
  file itself. First in-the-wild self-recovery from the exact desync class v2 targets.
## Explicitly considered and rejected (audit refuted — don't re-litigate without new evidence)

- Codex-side loose workspace grep producing a *currently* different name (verified
  identical on current cmux output; it's a drift risk → solved structurally by PR 2).
- Archive mtime/freshness misclassification in fleet status; "no exit from stale state";
  workspace-death liveness gaps (mitigated by existing design).
- `protocol-version` frontmatter field (speculative until PR 3 changes the format — revisit then).
- Replacing prose verdict/findings with a structured machine block (PR 2's validator gets
  most of the value without changing the message shape).
- README `../agent-comms/install.sh` path (correct for the documented layout).

## Field-report credits

PR 3 items originate from in-the-field reflections by the agents running these loops
(thread scoping, reply wake-up, state.json, advisory evaporation, picker fragility,
reviewer-failure lane) and two Codex reviewers (comms CLI, delivery acks, schema
validation, atomic reply→deliver→archive, message ids, stale-inbound reconciliation).

## Headless / loopspec track (2026-07 — the unification roadmap)

Shipped: runphase v0 codex leg (dbc5a50), claude leg + direction-aware pickup + hold/
watchdog (05f0df5), loopspec v1 kernel (0919306). Remaining, in order:

- [x] **Downstream Level-1 adoption (step 4)** — a separate consumer validated a
  vendored, pinned kernel with its own conformance reader. This confirmed the
  fixtures and prompt fragments work across implementations without coupling a
  consumer's build to upstream HEAD.
- [x] **Make non-cmux (headless) delivery the DEFAULT** — *shipped 2026-08-25, ahead of
  the original soak gate, on user decision.* Loops are headless-first; cmux is opt-in via
  `--via cmux` / `COMMS_DELIVERY=cmux`; `comms.sh transport` owns the routing and
  classifies from the message (`workflow:` present ⇒ loop). The soak threshold below was
  the original gate: 10 successful headless loops including ≥3 claude-resume/attach
  exercises and ≥3 reverse-direction handoffs. The timeout idle/salvage fix should
  land before the flip. Prerequisites: per-repo persistence for
  the delivery mode (`.comms/config`, not env-var-only) with staged per-repo opt-in
  (low-risk repos first, higher-risk repos last); cmux stays selectable as fallback for one
  release after the flip.
- [ ] **Retire fleet.sh after replacement orchestration is ready (step 5)** —
  HARD-GATED on a trackerless local mode covering status/dispatch/dispatch-all/
  harvest/concurrency caps/dirty-tree+push safety/stalled recovery. fleet.sh is live
  orchestration until then (frozen, but kept correct — see the pass-synonym fix).
- [ ] **Delete cmux delivery (step 6)** — one release after the default flip with no
  fallback invocations; deletion audit must include every known dispatch consumer;
  keep optional log/tail viewing only if useful. Interop drill before declaring done.

## Scope-dial track

Ordered by cost/value; the first three are template-only edits.

- [x] **Verdict-discipline fragment** (shipped 2026-08-20): "pre-existing defects in code
  the change did not touch are Advisory by default" added to
  `docs/loopspec/fragments/verdict-discipline.md` and both embedded copies
  (send-to-claude, read-from-claude — tripwire-enforced). Prose fragment addition —
  backward-tolerant, no schema change; downstream consumers pick it up on their next
  pin sync. (`APPROVE_WITH_CONDITIONS` as a verdict value was rejected — it duplicates
  APPROVE + advisory carry-over and would force a loopspec major.)
- [x] **Acceptance criteria pinned at implement round 1** (shipped 2026-08-20):
  auto-implement's round-1 body and auto-full's implement handoff (read-from-codex
  transition) carry a pinned `## Acceptance criteria` section; the reviewer skill
  judges later rounds against it instead of re-deriving the bar each holistic pass.
- [x] **Scope ledger** (shipped 2026-08-20): a `### Scope additions` running list
  (review-driven additions + rough cost) copied forward verbatim each round in the
  reply spec, omitted only while empty.
- [ ] **Writer dispute/escalate lane**: a sanctioned reply that contests a blocking
  classification and pauses the loop for a user scope decision instead of complying or
  burning a round. Touches termination conditions in both read skills — design first.
  *(The grading track INFORMS this — it fixes the label semantics: a dispute is a claim that
  triggers adjudication, never a disposition. The deliverable here — the sanctioned reply and
  the termination-condition edits in both read skills — remains unbuilt and lives here.)*
- [ ] **Shared test-evidence contract in plan phase**: plan template states which layers
  get what kind of proof at which checkpoint, so evidence boundaries aren't litigated
  mid-loop.
  *(The grading track INFORMS this — it fixes the review-time weighting rule and its four
  proof conditions. The plan-template deliverable remains unbuilt and lives here; the
  weighting half is additionally blocked on the artifact hash.)*
- [ ] **Usage/budget frontmatter signal** (optional field, soft rollout): lets a loop
  anticipate provider outages/limits instead of discovering them mid-round. Pairs with
  the ACP warm-session resumability spike.
- [ ] **Docs: stakes-tiering guidance**: prototype work → auto-implement or
  `max-rounds: 2-3`; pipelines/data-integrity/provenance work → full auto-full loop.
  ("Rounds 1–5 delivered the loop's value; 6–9 delivered thoroughness whose price was
  never negotiated.")

## Informal consult: bare `/ask-codex` "thoughts?" mode (2026-08-20, user request)

The user's most frequent manual pattern — pasting the last message(s) into Codex and
typing "thoughts?" — has no shortcut. Decided (user-confirmed): repurpose bare
`/ask-codex` rather than adding a command; with an argument it stays an explicit
question. **2026-08-20 update: the command shape is superseded by the `/ask` unification
track below (single multi-agent `/ask`); the payload/behavior spec here still stands.**

- [ ] **Bare `/ask-codex` = informal consult**: replace the current no-arg prompt-back
  with: package the current discussion and ask for Codex's take. Template-only edit to
  `ask-codex.md` step 1.
- [x] **Payload is a verbatim excerpt, not a summary** (user-confirmed; shipped
  2026-08-20 in ask.md): at MINIMUM the
  user's last question and the assistant message answering it — the question is what
  Codex is opining on, the answer alone reads as a statement with no ask. Going further
  back is Claude's judgment when the topic spans turns. Pasted verbatim under
  `## Context`, size-capped (~4 KB, consistent with the bounded-read philosophy; prefer
  dropping older turns over truncating mid-message — but never drop the last question).
  Rationale: preserves the "second set of priors" value from the 2026-08-19 field
  report — Codex reacts to the actual material, not Claude's re-framing of it. Claude's
  own take is already IN the excerpt, so skip `## Current Thinking` unless there's
  something genuinely new to add.
- [x] **`## Question` body** (shipped 2026-08-20): literally informal — "Thoughts? Informal take requested on
  the discussion below." No review framing, no findings structure asked for; Codex's
  existing `type: question` → `type: response` path (send-to-claude SKILL step 4)
  already handles it with no verdict.
- [x] **Keep the existing guardrails** (shipped 2026-08-20 in ask.md): same frontmatter
  (no workflow fields), same single-shot rule, same "don't stretch into review
  territory" note — an informal consult that starts asking for blocking findings
  should redirect to `/send-to-codex`.

## Multi-agent track (2026-08-20)

Support agents beyond Claude Code + Codex; Grok Build first (xAI coding CLI, open-sourced
2026-07-15: interactive TUI, headless `grok -p --output-format streaming-json`, ACP via
`grok agent stdio`; loads CLAUDE.md/AGENTS.md automatically and claims Claude/Codex-compatible
config surfaces — the cheapest possible third agent, pending live verification of those
claims). Strategy decided: **consult/reviewer-first** — new agents join headless-only in the
two roles that need no watchable pane (`/ask` consults, loop reviewer); interactive cmux
integration is NOT ported per agent (keystroke idioms are the loudest friction source with
just two agents). Per-agent cost model: inbox (trivial once generalized) → instructions
(Grok: possibly free) → cmux nudge (skipped by strategy) → headless runphase arm (small) →
ACP (~zero once the acpx backend exists).

- [x] **Generalize the two-party core** (shipped 2026-08-20, thread multi-agent-17600):
  - agent registry in `.comms/config` (name → inbox, headless command, instruction surface);
    origins defined once
  - `inbox_for()` and every `claude|codex` case arm in comms.sh (~15 sites), clean/status
    loops over `to-*/` from the registry
  - `peer_of()` in runphase.sh breaks at 3 agents: derive the peer from the inbound
    message's `from:` field, never compute a complement
  - state session-field naming generalizes to `<agent>_session_id` (loopspec thread-state
    schema already allows it via additionalProperties; keep the two legacy names readable)
  - already N-agent-safe (no change): verdict binds by TYPE not sender; loopspec threads
    stay 2-party per thread — more agents = more pairs, never N-party threads
- [x] **Grok Build headless integration** (shipped 2026-08-20): read-only child +
  trusted-parent-broker leg in runphase (final shape: `--prompt-file` +
  streaming-messages-json result anchor — NOT `-p`/streaming-json, both live-refuted),
  `/ask grok` via the registry, `--reviewer grok` on auto-* commands. Live compat
  evidence: grok 1.0.5 loads installed Claude commands (observed in
  available_commands) and follows prompt-file instructions; managed AGENTS.md-block
  ingestion not separately verified — that sliver stays open.
- [x] **Reviewer parameterization** (shipped 2026-08-20): auto-plan/auto-implement/
  auto-full accept `--reviewer <agent>` (default = registry default); the reader
  derives the reviewer mechanically from the inbound `from:` for every continuation
  (replies, error lane, plan→implement handoff). Addresses the single-reviewer
  serialization problem.
- [x] **ACP Tier-1 spike — landed on `/ask` first** (user-reshaped 2026-08-20; shipped
  same day as `helpers/acp.sh` + `/ask --via acp`): pinned acpx 0.13.1 via npx, Node
  ≥22.13 gated, warm named-session default, mailbox fallback on every failure class.
  THE MEASUREMENT (the spike's deliverable): cold one-shot = 18,562 fresh input
  tokens; warm session round 2 = **146** (~127x reduction; acpx prints usage
  natively). Decision gate resolved: Node accepted as an OPTIONAL, opt-in surface.
  REMAINING (not this spike): `COMMS_DELIVERY=acp` for review loops — thread → named
  session, exit codes → RESULT lanes, schemas unchanged; gate it on consult-path
  soak + the requirement that reviewers can EXECUTE things (acpx
  permission policy design). cmux and runphase stay; ACP is a third backend.

## `/ask` unification (2026-08-20, supersedes the bare-`/ask-codex` decision above)

Decided (user-confirmed): ONE `/ask` template scaling across agents, not `/ask-<agent>`
copies. The informal-consult ("thoughts?") design above carries over unchanged — only the
command shape evolves:

- [x] `/ask <agent> <question>` — first word validated against the agent registry names
  the target; not an agent name → the whole text is a question to the DEFAULT agent —
  *fully delivered 2026-08-20: ask.md reads `comms.sh agents` / `agents default`*
- [x] bare `/ask` (or `/ask <agent>` alone) → thoughts mode per the informal-consult spec
  (verbatim excerpt, floor = user's last question + the answering message) — shipped
  2026-08-20 (thread ask-unification-10480)
- [x] `/ask-codex` becomes a thin deprecated alias for one transition release, then drops
  — alias shipped 2026-08-20; the drop happens next release
- [x] adding an agent touches ONLY the registry — the template reads names from it (DRY)
  — *fully delivered 2026-08-20 (`.comms/config` + `comms.sh agents`)*

## Reviewer grading & panel track (2026-08-21, revised 2026-08-22)

Grade reviewers from what the loops already produce, support a panel of reviewers over one
artifact, and eventually route work to the agent that is measurably good at that category.
Designed 2026-08-21, consulted to Codex (thread `ask-reviewer-grading-panel-mode-9753`), then
measured against the archive on 2026-08-22 and consulted a second round. Round 1: the
consult's *framing* correction stands, its *instrumentation* prescription did not survive the
measurement. Round 2: the re-scoping stands, but three claims **in this section** were wrong
and are corrected inline — matched empty reviews do not expose correlated misses, a hash
without retained content does not enable unchanged-since analysis, and disjoint findings show
diversity, not routing quality. All of it is recorded inline so none of it is re-litigated.

**Framing correction (from the consult) — the loop does NOT emit ground truth.** It emits
*claims* and later *dispositions* for findings somebody discovered; undiscovered defects
never enter the ledger. Precision is observable, recall is not, and an approve-everything
reviewer keeps looking perfect until some other process finds a defect. Consequences that
bind every item below:

- The metric is `observed_escape_rate` / `conditional_recall_proxy` — never "recall".
- Every label carries provenance, adjudicator, confidence, and a censoring window; exposure
  is counted in *subsequent review turns touching the same region*, never in elapsed days
  (the corpus has ~5 active days across 78, with 22–27 day gaps — a wall-clock denominator
  manufactures a rate from an empty risk set).
- "No escape observed yet" is **censored data, not a true negative.**

**Measurement (2026-08-22 — `.comms/archive`: 118 messages, 53 `review-feedback`, 16 threads,
149 Blocking+Advisory bullets, ~5 genuinely active days).** Five facts reshape or kill most
of what the design and the critique both assumed:

- **`head_sha` does not identify the reviewed artifact.** All 16 threads carry at most ONE
  distinct `head_sha` (8 carry none) — including every 4-round thread. The loop reviews the
  *uncommitted working tree* (`runphase.sh:373` "Your working directory IS the tree to
  review") and the message carries only `git diff --stat`, so round N's reviewed state is
  destroyed by round N+1's edits and recorded nowhere. Every SHA-bound condition in the
  consult — "the evidence existed at that reviewed SHA", "the test fails at the exact
  reviewed SHA", and the whole unchanged-since rule — is **uncomputable under today's
  protocol**. The same fact undercuts loopspec's `merge` profile, which offers `head_sha` as
  the example of binding to the exact artifact reviewed.
- **The escape metric penalizes obedience.** `fragments/holistic-rereview.md` instructs every
  round-2+ reviewer to "Scan for issues you may have missed in earlier rounds — you were
  likely anchored on specific areas before". A round-N finding on an unchanged hunk is that
  instruction's intended output, and none of the consult's four promotion conditions filters
  it. 32 of 53 reviews are round ≥2 — the entire escape-candidate pool — and all 32 are
  codex-on-codex.
- **`false_approve_rate` has no possible numerator.** All 17 threaded APPROVEs are the
  terminal round of their phase (SPEC: "the loop ends on APPROVE"), so an escape can only
  ever land on a REQUEST_CHANGES round. Out-of-loop detection over 2.5 months yields 5
  file-level coincidences, all on the repo's hottest files. Report "N approvals, M
  re-examined" — never a rate, never an interval.
- **"There is no per-finding structure" was false** (the design's founding premise, which the
  consult reinforced rather than corrected). 53/53 review-feedback messages already carry
  template-mandated `### Blocking` / `### Advisory` / `### Process`; 149 bullets, 65% with a
  backtick `path:line` anchor. The archive lacks *dispositions*, not *structure* — a ~25-line
  awk extractor already yields them with thread/round/severity/anchor provenance
  (149 raw bullets; **112 substantive findings** once `None.` placeholders and `### Process`
  are dropped — the second number is the one the ledger records).
- **There is nothing to compare.** 53/53 reviews are `from: codex`; `--reviewer grok` shipped
  2026-08-20 and has produced zero reviews. The bottleneck is not measurement — it is that
  the comparison has never been run.

### Prerequisites — nothing downstream is computable without these

- [x] **RETAIN the artifact, not just a hash of it** *(shipped 2026-08-22, `comms.sh
  snapshot`)*. A hash proves two canonical inputs were identical but cannot resurrect
  either, so it does not enable unchanged-since analysis once the worktree moves. The
  working tree is written as a real commit object (tracked edits AND untracked files, the
  mailbox removed mechanically) and anchored under `refs/agent-comms/artifacts/` so gc
  cannot eat it; a clean tree returns HEAD rather than minting a synonym. `git stash
  create` was the obvious tool and is wrong — it silently drops untracked files even with
  `--include-untracked` (caught by the harness), so the tree is built in a throwaway index.
  The shadow reviewer runs against a MOUNT of that artifact — worktree at the base,
  artifact materialized into it, index reset to base — so `HEAD` matches the request's
  `head_sha` and the reviewed change reads as an ordinary uncommitted diff. The GATING
  reviewer still reads the live tree, which is why a pair is a CANDIDATE pair and
  `drift_status` is recorded explicitly. agent-comms-private: no SPEC edit, no fixture
  change, no pin bump.
- [x] **Do NOT change the finding format before the baseline runs** *(held 2026-08-22 —
  no template edit shipped; extraction reports the anchored subset as a column instead)* *(corrected r2)*.
  Extract every finding bullet and report the anchored subset as a separate column —
  mandating `path:line` would discard valid prose and cross-file findings AND move the
  instrument before the experiment. If the template is ever changed, it is a NEW
  `prompt_version`, never an invisible comparison against history. A WARNING-level
  `cmd_validate` check stays available, but it ships after the pilot, not before it.

### First slice — the comparison, not the ledger

- [x] **Retro-extract the archive** *(shipped 2026-08-22)* — `comms.sh findings` over `.comms/archive` → an
  append-only TSV (thread, round, reviewer, verdict, severity, anchor, claim). ~25 lines of
  awk gets all 112 today, with no protocol change and no prompt change. It is the single-
  reviewer baseline the shadow pairs are compared against, and it prices anchor coverage,
  severity mix, and per-round yield from real data instead of assumption. It cannot dry-run
  unchanged-since — the archive never retained the reviewed artifacts, which is why the
  prerequisite above exists and why escape attribution is cut rather than deferred.
- [x] **The second reviewer** *(shipped 2026-08-22)* — `comms.sh shadow --to <agent> <review-request>`: re-stamp
  run the second reviewer through `runphase.sh run --no-deliver` and append to the same TSV.
  The shadow verdict never gates, MECHANICALLY: the reply is produced and validated but never
  delivered to an inbox and never written to thread state, so it cannot steer a loop it was
  never delivered into. (It deliberately does NOT reuse `cmd_send` — sending is the one thing
  it must not do — and it refuses any agent that authors and sends its own replies.)
  ~60–85 lines, one helper, no new dependency. Run it on the next 8 loops against the
  retained snapshot. Method: isolated fresh sessions, neither output exposed to the other,
  randomized primary/shadow assignment, and rate-limit/transport failures classified
  separately from review quality. **Matched pairs on an identical artifact beat 112 unmatched
  single-reviewer observations** — but what they measure is agreement, unique-finding yield,
  zero-finding disagreement, severity mix, anchor coverage, latency, and operational failure.
  *(Corrected r2: two empty reviews do NOT "surface correlated misses" — that is mutual
  silence with no observation of the missed defect. Eight pairs are a schema/feasibility
  pilot, not a reviewer grade.)*
- [ ] **Adjudicate a SAMPLE of the pairwise symmetric difference — the minimum third
  signal** *(added r2)*. Disjoint findings show diversity and noise, **not** quality: a noisy
  reviewer wins a raw-yield comparison. Only the findings one reviewer raised and the other
  did not need a human verdict, and only a sample of those — far cheaper than grading every
  finding, and the only thing that converts diversity into a routing claim. Until it runs,
  shadow output supports exploratory diversity-based routing at most, never quality gating.
- [x] **Dispositions are OMITTED from the pilot** *(held 2026-08-22 — nothing built)* *(r2: there is no cheap reliable producer)*.
  A terminal APPROVE does not confirm each preceding finding and diff overlap only shows that
  code moved — never synthesize dispositions from either. The smallest honest producer, if
  one is ever wanted, is an out-of-band author sidecar (`comms.sh label` after the fix turn)
  recorded as `author_claim`, never as confirmed truth and never injected into the next
  reviewer's prompt — which preserves "stable context, not fix narration" but still costs
  protocol work. The pilot skips it and leans on the adjudicated sample instead.
- [x] **Capture the EPHEMERAL, defer the derivable** *(shipped 2026-08-22)*. One append-only
  TSV, nullable disposition with explicit provenance. The emitted header is exactly:
  `schema_version`, `finding_id`, `review_set_id`, `artifact_id`, `base_sha`, `thread`,
  `phase`, `round`, `reviewer`, `reviewer_version`, `prompt_version`, `role` (gating|shadow),
  `lane`, `anchor`, `claim`, `verdict`, `source_message_id`. Two deviations from the consult,
  both deliberate: **there is no separate `observation_id`** — it could only diverge from
  `finding_id` if two rows were mechanically recognizable as the same claim, and claim
  fingerprinting was rejected, so one id is the honest count; and the runtime column is
  `reviewer_version` (the CLI's self-reported identity) — **grades do NOT partition on model
  or provider config**, which nothing currently captures, so no such claim is made. Columns
  can be added later; artifact contents, runtime identity, prompt version, isolation, and
  role **cannot be reconstructed after the run**.
  Still ~85 lines against ~1,000 — in a repo where `jq` appears 0 times in `helpers/` and the
  JSON reader is `json_get()`, sed-based by design.

**Baseline measured 2026-08-22, first run of `comms.sh findings` over this repo's own
archive:** 112 substantive findings (50 blocking / 62 advisory) across 53 reviews and 17
threads, 86 of them (77%) carrying a resolvable `path:line` anchor — and **112 of 112 from
codex**, which is the whole argument for shipping the shadow leg before any ledger.

**The slice landed 2026-08-22, thread `grading-pilot-14076` (auto-implement, codex-approved
round 4 of 4).** Ten blocking findings across three rounds, every one a real defect in code
that was green at every step; rounds 2 and 3 were largely defects in the round-1 fixes. The
generalizable lessons are in `docs/advisories.md`. Its own first live shadow run (grok) also
found six issues before codex ever saw the code — the comparison this track exists to make
produced evidence before the ledger held a single scored row.

Remaining in this slice: install the corrected reviewer prompt (a NEW `prompt_version` by
construction — and note `prompt-version` hashes the INSTALLED surface, so the hash moves on
`install.sh`, not on the edit), then run `shadow --to grok` on the next 8 loops, then
adjudicate a sample of the pairwise symmetric difference. Nothing else is buildable until
those exist.

**Known scoped limitation, accepted by the reviewer:** the GATING reviewer is not bound to
an artifact at dispatch, so every pair is a CANDIDATE pair and `drift_status` never asserts
more than "no drift detected during the shadow window". Binding it means `send` taking a
snapshot on every loop, shadowed or not — the next slice, deliberately not bolted onto this
one.

### Held as design constraints (free to keep, nothing to build)

- [ ] **Escapes are candidates, never automatic misses** — unchanged-since is necessary, not
  sufficient: findings are semantic and cross-file, and churn can rewrite a defect and hide
  its ancestry. Uncertain lineage → `ambiguous_churn` / `new_context`, never counted as
  either a hit or a clean review. Escapes where reviewer(N) == reviewer(N-1) are `self_escape`
  and never enter a routing metric — today that is 100% of them.
- [ ] **Adjudicated severity, not reviewer-self-declared**, wherever a verdict composes;
  otherwise `any-blocks` lets one noisy reviewer halt a panel by calling a concern "security".
  Process still never gates; style-by-majority stands. **The adjudicator is the human** — the
  repo's only precedent (the dispute lane "pauses the loop for a user scope decision"; an
  advisories entry "resolved by user decision") — so every adjudication-gated item is an
  unbudgeted human-labor line, and is deferred below on exactly that ground.
- [ ] **Test-evidence weighting** — a test-backed finding earns higher weight only when the
  test fails at the reviewed artifact, passes after the fix, targets the claimed behavior, and
  was not weakened or disabled to obtain green. Blocked on the artifact hash above.
  Implementer-authored tests are evidence, not independent truth; preserve authorship.
- [ ] **Goodhart guards.** "Not inlined" is **not** a boundary — this repo already reverted
  `COMMS_ARCHIVE_SCOPE_THREAD` on exactly that ground (`advisories.md`: "Env vars are not
  boundaries"). Grades live outside the reviewed worktree or behind the operator deny-profile,
  and **never** in any file `comms.sh lessons` reads — which rules out `docs/advisories.md`,
  whose read is a mandatory first step in the reviewer's own turn. No agent adjudicates its
  own findings.
- [ ] **Loopspec stays lenient** — grading is an ADDITIVE companion artifact and message
  `verdict` compatibility is unchanged. Finding IDs stay **implementation-private to
  agent-comms**, like the `merge` verdict profile. *(Reversed 2026-08-22: the earlier
  "soft-required exactly as `thread`/`message_id`" framing was wrong — those are a normative
  row in SPEC's validation table, so the analogy commits to a SPEC edit + fixtures +
  `check.sh` + a pin bump for every vendoring consumer. The consult never asked for that; it
  put `finding_id` in the event schema, never in the message contract.)*
- [x] **`prompt_version` is required on any grade record** *(shipped 2026-08-22 —
  `comms.sh prompt-version`)* (a fragment-tree content hash —
  the drift harness already computes one). Every active review day is a day the reviewer's
  instruction text changed, so grades do not carry across a prompt edit; partition on it,
  never pool. Absent from the consult's otherwise-exhaustive field list.

### Rejected (measured, not re-litigated)

- **Event-sourced ledger with 7 event types, dual `finding_id` + rename-mapped semantic
  fingerprint.** Right shape for a data platform, wrong for ~60 findings/month from one
  reviewer in a bash tool. Two of the seven events have no writer: `outcome_observed` has no
  producer and no out-of-loop source, and `disposition_claimed`'s natural producer is the
  author's round-N reply, which SPEC forbids ("never a per-finding 'fixed it' checklist") —
  so the "no behavior change" claim was false. The fingerprint also specifies a consumer for
  data no producer emits: 0% of real findings carry symbol/region, invariant, or evidence
  signature.
- **Shrinkage / credible intervals per (agent × category).** Degenerate here — one agent
  holds 100% of the reviews and the finding format has no category field, so the grid is 1×1
  and shrinkage collapses to the identity. Show raw n plus "1 reviewer, 1 prompt version";
  that looks uncertain without pretending to a posterior.
- **Risk-weighted audit sample as specified.** Its `same-model/provider agreement` arm selects
  *nothing* with one reviewer, while its other arms select the majority of the corpus as
  unbudgeted human labor. The shadow-pair run above buys the same signal mechanically.
- **Rotating seeded mutation.** More expensive than the static golden-bug suite the consult
  itself declined, and actively unsafe here: a caught-but-unfixed seeded defect is appended to
  the tracked `docs/advisories.md` on APPROVE and re-injected into later reviewer turns via
  `comms.sh lessons`; the miss case leaves an APPROVE on a deliberately defective tree. The
  consult offered it as the second branch of a disjunction — keep only the cheap branch (a
  periodic independent shadow challenger, which item 2 of the first slice already is).
- **Escape attribution as a reviewer-routing metric** *(cut r2, stronger than the earlier
  deferral)*. Even a perfect snapshot establishes textual lineage, not semantic attribution:
  a later cross-file objection may have been valid earlier while touching no identical hunk.
  Retain "later-pass yield" as a **process observation only**, and never charge a reviewer
  for its own later discovery. Revisit only if artifact lineage AND adjudication both exist.
- **Cross-machine redacted export/import.** Ledger portability resolved as **per-install
  only**: single-user tool, no compounding benefit, and it reopens the disclosure surface
  3c5b790 just closed.
- **`cost_per_confirmed` as a reported column, for now.** No review transport meters usage —
  token accounting lives only in `acp.sh`, reachable only from `/ask`, whose replies carry no
  verdict and no findings by contract. Any cost figure also needs `transport` and
  `session_state` (cold|warm) beside it: the one measured number swings ~127x on warmth.

### Deferred (reason recorded, so it is not mistaken for oversight)

- **Panels.** No comparative data exists yet. When they land: N parallel 2-party threads under
  a `review_set_id` — the MESSAGE CONTRACT holds unchanged, but the driver, state layer, and
  status surface do not. `comms.sh` `status` evaluates its ACTION NEEDED branch against only
  the newest state file (`ls -t … | head -1`), so N-1 panel legs go invisible; `auto-implement`
  binds a single `REVIEWER` variable across every write path; state is keyed
  `<ws>_<thread>.json` with a singular `awaiting_from` and has no home for a composed verdict.
  Condensation, when built, auto-collapses only high-confidence exact matches and retains every
  source finding and reviewer.
- **The judge.** With one reviewer there are zero conflicts to adjudicate. The consult's
  correction stands for when there are more than one: conflict-only judging is structurally
  blind to correlated agreement — including agreement by both finding *nothing*, which no
  conflict trigger can ever see.
- **Routing.** Needs a populated (agent × category) grid, which needs a category field, a
  second reviewer, and a stable prompt version. None exist.
- **Adjudicated-severity composition and the dispute lane** — the adjudicator is the human
  and nobody has costed that time. (Escape attribution is no longer here; it is CUT — see
  Rejected.)

## Priorities (2026-08-20, user-confirmed order)

1. **`/ask` unification + thoughts mode** — one template change, daily-use pain, and doing
   the informal-consult edit on the new shape avoids reworking `/ask-codex` twice
2. **Scope-dial template trio** — verdict-discipline sentence, pinned acceptance criteria,
   scope ledger (the three template-only scope-dial fixes)
3. **Multi-agent core + Grok Build headless** — registry/generalization, then Grok as
   consult + reviewer
4. **ACP Tier-1 spike** — DONE 2026-08-20 (/ask --via acp; warm r2 146 vs cold 18,562 tokens, ~127x)
5. **Reviewer grading — the comparison, not the ledger** *(re-scoped 2026-08-22 after
   measuring the archive, amended the same day by consult round 2)*: retain the reviewed
   artifact as a durable snapshot (the one prerequisite — the finding format deliberately
   does NOT change before the baseline), then retro-extract the 112 archived findings, run a
   shadow second reviewer on the next 8 loops, and adjudicate a sample of the pairwise
   symmetric difference — the minimum third signal, since diversity alone is not quality.
   The event-sourced ledger is NOT built until those produce numbers: with 53/53 reviews from
   one agent there is nothing to compare, and `--reviewer grok` has shipped and never run.
   Escape attribution as a routing metric is cut, not deferred. Panels, routing, the judge,
   and adjudication-gated items stay deferred with reasons recorded in the track.
6. Remaining scope-dial items (dispute lane and test-evidence contract — informed by the
   grading track, but their deliverables stay tracked in the scope-dial section above;
   budget signaling; stakes-tiering docs) and the standing DEFERRED backlog in
   docs/advisories.md
