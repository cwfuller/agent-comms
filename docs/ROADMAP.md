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
  *(fleet.sh and the fleet engine were since retired 2026-08-26 in the `/auto`
  collapse, 80f472c; the installer now deletes them on upgrade, df96bb1.)*
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
  *(Moot: `/fleet` retired 2026-08-26, 80f472c.)*

## PR 3 — protocol v2 (from the field reports + audit)

**Status: implemented 2026-06-04 (Codex loop pending).** Harness: 79 checks green.

- [x] **Threading:** `message_id` + `thread:` + `in-reply-to` in *both* directions;
  `comms.sh list --thread` scopes reads so concurrent loops in one workspace can't
  consume each other's replies. Soft-required (validate warns, doesn't reject) so
  in-flight pre-v2 loops survive a mid-loop template upgrade.
- [x] **State:** `.comms/state/<workspace>_<thread>.json` written automatically by
  `comms.sh send` for workflow messages (workflow/phase/round, awaiting_from,
  awaiting_since, last_sent, last_delivery); `state get|list|complete`; fleet status
  surfaces `owes=<agent> <N>m` from it. *(Fleet retired 2026-08-26; the owes/awaiting
  readout now lives in `comms.sh status` and `stalled`.)*
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
  on `norm_verdict` so `" approve"` still terminates a loop. *(Gating moved to the
  reader/broker when fleet retired 2026-08-26; the verdict scan is now the unified
  whole-reply fence-skipping probe, e447e41 + 25d825c.)*
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
  *(lane set since grew to delivered|spawned|held|blocked|manual|failed, `spawned` being
  the default headless-loop lane, and every RESULT names its route — e447e41, 8c804ad)*
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
  exercises and ≥3 reverse-direction handoffs. *(Post-flip debt, 2026-08-26: the
  timeout idle/salvage fix remains OPEN — partially mitigated by 7455927, which names
  a budget-killed ACP turn instead of reporting an empty reply. The `.comms/config`
  delivery-persistence prerequisite never shipped: the registry accepts only `agents`
  and `default-target`; delivery mode is still COMMS_DELIVERY/--via only.)* cmux stays
  selectable as fallback.
- [x] **Retire fleet.sh after replacement orchestration is ready (step 5)** —
  *retired 2026-08-26 in the `/auto` command collapse (80f472c) rather than via the
  trackerless-mode gate; the gate was consciously waived when `/auto` + panel dispatch
  + `comms.sh status`/`stalled` absorbed the orchestration surface.* Original gate for
  the record: trackerless local mode covering status/dispatch/dispatch-all/
  harvest/concurrency caps/dirty-tree+push safety/stalled recovery.
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
  *(Commands collapsed into `/auto` on 2026-08-26, 80f472c; the pins now live in
  auto.md and the read-from-codex handoff.)*
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
  never negotiated.") *(Superseded 2026-08-26 by the `/auto` collapse + 10-round
  default, 80f472c + d668cd8 — auto.md now argues a low cap "is a wall, not a budget".
  If short-budget tiering is still wanted, it becomes `/auto --rounds N` guidance.)*

## Informal consult: bare `/ask-codex` "thoughts?" mode (2026-08-20, user request)

The user's most frequent manual pattern — pasting the last message(s) into Codex and
typing "thoughts?" — has no shortcut. Decided (user-confirmed): repurpose bare
`/ask-codex` rather than adding a command; with an argument it stays an explicit
question. **2026-08-20 update: the command shape is superseded by the `/ask` unification
track below (single multi-agent `/ask`); the payload/behavior spec here still stands.**

- [x] **Bare `/ask-codex` = informal consult**: replace the current no-arg prompt-back
  with: package the current discussion and ask for Codex's take. *(Superseded and
  delivered: shipped 2026-08-20 as bare `/ask` thoughts mode; ask-codex.md itself was
  deleted 2026-08-26, 80f472c.)*
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
  `/ask grok` via the registry, `--reviewer grok` on auto-* commands *(auto-* since
  collapsed into `/auto --reviewers a,b` with panel-by-default, 2026-08-26)*. Live compat
  evidence: grok 1.0.5 loads installed Claude commands (observed in
  available_commands) and follows prompt-file instructions; managed AGENTS.md-block
  ingestion not separately verified — that sliver stays open.
- [x] **Reviewer parameterization** (shipped 2026-08-20): auto-plan/auto-implement/
  auto-full accept `--reviewer <agent>` (default = registry default) *(superseded
  2026-08-26: `/auto --reviewers a,b`, default = a PANEL of every registered agent
  except the driver via `agents --others`, 51b9ef3)*; the reader
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
  *(Shipped 2026-08-26 as the `transport`/`deliver` ACP route — `runphase spawn
  --via acp` with warm per-thread sessions; cmux is now opt-in, not co-equal. The
  surviving sliver is live end-to-end coverage.)*

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
  — alias shipped 2026-08-20; dropped 2026-08-26 (80f472c; the installer removes
  retired commands on upgrade)
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
  `drift_status` is recorded explicitly. *(Superseded 2026-08-26, 1529b1f: `send` now
  snapshots and stamps `artifact_id` on every workflow message and parent-brokered
  gating turns read a pinned mount too — only self-sending cmux turns still read the
  live tree.)* agent-comms-private: no SPEC edit, no fixture
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
those exist. *(Shadow-on-8-loops superseded 2026-08-26 by panel-by-default: grok now
reviews as a GATING leg on every loop via `panel dispatch` sharing one snapshot — see
Panel & command collapse. Adjudicating the symmetric difference remains the open step.)*

**Known scoped limitation, accepted by the reviewer:** the GATING reviewer is not bound to
an artifact at dispatch, so every pair is a CANDIDATE pair and `drift_status` never asserts
more than "no drift detected during the shadow window". Binding it means `send` taking a
snapshot on every loop, shadowed or not — the next slice, deliberately not bolted onto this
one. *(That slice shipped 2026-08-26, 1529b1f: `send` snapshots every loop dispatch and
pins `artifact_id`; the limitation now applies only to self-sending cmux turns, which
mounting cannot reach.)*

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

- **Panels.** *(SHIPPED 2026-08-26 — and made the DEFAULT. See "Panel & command
  collapse": `panel dispatch` fans one snapshot to N parallel 2-party legs under one
  `review_set`, `/auto` composes before fixing, compose clusters by corroboration and
  is round-scoped with in-reply-to binding. The open residue is reciprocal
  adjudication wiring, tracked in that section.)* Original deferral for the record:
  no comparative data existed; driver/state/status were single-reviewer machines.
- **The judge.** With one reviewer there are zero conflicts to adjudicate. The consult's
  correction stands for when there are more than one: conflict-only judging is structurally
  blind to correlated agreement — including agreement by both finding *nothing*, which no
  conflict trigger can ever see. *(Resolved by design 2026-08-26: no separate judge
  will exist — condense = RECIPROCAL ADJUDICATION; the corroboration gate shipped,
  reciprocal adjudication remains the open half.)*
- **Routing.** Needs a populated (agent × category) grid, which needs a category field, a
  second reviewer, and a stable prompt version. None exist. *(Update 2026-08-26: the
  second reviewer now exists — grok gates by default on every panel — still blocked
  on a category field and a stable prompt_version.)*
- **Adjudicated-severity composition and the dispute lane** — the adjudicator is the human
  and nobody has costed that time. (Escape attribution is no longer here; it is CUT — see
  Rejected.)

## Panel & command collapse (2026-08-26)

**North star, stated by the owner:** the highest-quality code output with the least human
involvement. The tool exists because manually asking Claude, then asking Codex, then
feeding the critique back produced markedly better results — this is that loop, automated.
Two standing constraints: token spend must not be obliterated on trivia, unreal bugs, or
questionable routes; and the human is consulted at the END, or when the agents are
genuinely split, not per round.

Designed after consulting codex and grok independently on the same brief
(2026-08-25, both over ACP). They agreed on more than expected and **disagreed with the
owner on two points, with evidence** — recorded below so neither is re-litigated.

### Decided

- [x] **One command.** `/auto [--plan] [--reviewers a,b] [--rounds N] [--via cmux] <task>`.
  `/ask` stays a separate verb — a consult is not a loop. *(Shipped 2026-08-26,
  80f472c + b3cc535.)*
- [x] **Kill `/auto-plan`, `/fleet`, `/ask-codex`.** *(Kills shipped 2026-08-26 —
  80f472c, 90d258d, df96bb1.)* The second half stays open: `send-to-codex` /
  `read-from-codex` becoming pure agent-neutral internals (`send --to $REVIEWER` /
  `read --as $SELF`) is tracked under "Any agent drives".
- [x] **KEEP a plan gate as `--plan`, opt-in** *(both consults disagreed with deleting it;
  shipped 2026-08-26 in the collapse — the 2-round cap below was superseded the same
  day by the 10-per-phase default, d668cd8)*.
  Evidence: the `token-efficiency-23269` loop spent 4 plan rounds before a line of product
  code, and what that bought was bouncing a wrong approach before it became 800 lines of
  locally-correct architecture. Shape it as grok specified: a real approach doc, **capped
  at 2 rounds**, judged on a DIRECTION-only bar (wrong approach, missed invariant, unsafe
  mechanic). Plan style may never block. Today's plan phase misuses code-review verdict
  discipline, which is why plan loops turn into document-nit loops. Not the default.
- [x] **Default is a PANEL** *(owner decision 2026-08-26, reversing the consult)* — every
  registered agent except the driver, derived from the registry via `agents --others` so a
  newly registered agent joins automatically. Narrow with `--reviewers`. The consults
  argued the opposite: *(disagreed with "everyone by default")*.
  Cost is no longer the constraint — ACP made a 3-reviewer 4-round loop ~12k fresh tokens
  instead of ~1.4M. The real constraints: grok is READ-ONLY by design, and 11 of 12
  implement blockers in `multi-agent-17600` came from codex EXECUTING candidate argv, not
  reading the diff — so a default-all panel puts a non-executing reviewer on the gate.
  Plus operational tail (one live grok review took 9.5 min then broke the reply contract)
  and no comparison data yet.
- [x] **Corroboration gating** *(shipped 2026-08-26 — 50939e3 compose clustering,
  bd7b792/fb157bc reader drives panel rounds and refuses any-blocks)* — neither
  any-blocks nor primary-only. A finding gates when
  a second panelist supports it, or when it carries reproducible evidence against the
  retained artifact. A lone unsupported blocker is cross-checked, not obeyed; still split
  after one confirmation round → escalate to the human, same lane as max-rounds. This is
  what stops a noisy reviewer holding the loop hostage, and it is the token-discipline
  mechanism: unique unsupported nits never cost a round.
- [ ] **Condense = RECIPROCAL ADJUDICATION, never a separate judge.** Each panelist
  cross-checks the OTHER's findings in a cheap second ACP pass; no agent judges its own
  finding, the implementer judges nothing, and no fourth full-context call exists.
  **Dry-run on a real pair, 2026-08-25** (codex + grok on one artifact, ground truth known):
  every unique real finding SURVIVED, both agents independently downgraded the same class
  of cosmetic diagnostic wording, and nothing was dropped. That answers grok's objection
  that judgment erases unique findings; its second objection (a judged bundle is "nobody's
  review") does not apply, because every verdict stays attributed to a named agent.
- [x] **Naming.** `panel` = the collection (user-facing), `reviewer` = one agent (keep —
  the ledger column, `from:`, and round-notes are all per-agent). `review_set_id` stays the
  internal grouping key. Not "board": it implies voting, which the gate deliberately is not.
  *(Adopted throughout the shipped panel code — `cmd_panel`, `review_set_id` columns,
  per-agent reviewer rows in rounds.tsv.)*
- [x] **`max-rounds` default 10 PER PHASE** *(owner decision 2026-08-26, superseding the
  5-per-phase decision below on the same day)*. field-report-9446 is why: it returned a real
  blocking finding in EVERY one of its first five rounds — including two rounds where a
  confident "this is fixed" claim of the driver's turned out to be false — and was still
  finding them when the cap stopped it. The 5 was chosen from an archive in which no loop had
  ever reached round 5; the first loop that genuinely needed more immediately proved the
  sample was the artifact of a low cap, not evidence of convergence. The plan phase gets 10
  too: its DIRECTION-only bar, not a tight cap, is what prevents document-nit loops.
- [x] **`max-rounds` default 5 PER PHASE** *(owner decision 2026-08-26, revising the
  consult; SUPERSEDED same day — see above)*. Both consults argued for 4 and a 2-round plan cap, citing this repo's own
  "rounds 6-9 were unpriced" note. The archive says no loop ever reached round 5 — but it
  also says every loop that hit the cap **escalated to the human**, which is the
  involvement this tool exists to remove. A cap you always hit is a wall, not a budget.
  The plan phase keeps its DIRECTION-only bar, which is what actually prevents
  document-nit loops; the tight cap was never the mechanism.
- [ ] **Parent-broker every panelist.** Today codex/claude author and send their own
  replies while grok is parent-brokered — which is why `shadow` refuses codex. Under ACP
  the parent stamps for everyone; unify on that and the reviewer-side skills become prompt
  fragments rather than a second product.

### Sequence

1. [x] **Snapshot on send — the prerequisite** *(shipped 2026-08-26)*. `send` retains the
   tree and stamps `artifact_id:` onto any message carrying `workflow:` (loops only — a
   consult reviews nothing), and `runphase` mounts that artifact for the turn: worktree at
   the base, artifact materialized in, index reset to base, so HEAD matches `head_sha` and
   the change reads as an ordinary uncommitted diff. Pinned at dispatch — a resend never
   re-stamps. *(grok — neither the owner nor codex had this.)*
   **Constraint found while building it:** a mount is a linked worktree with NO `.comms`
   in it, so a reviewer that authors and sends its own reply cannot reach the mailbox from
   inside one. Mounting is therefore restricted to PARENT-BROKERED turns (ACP, and grok).
   That is the same split that makes `shadow` refuse self-sending agents, and it promotes
   "parent-broker every panelist" from tidiness to a prerequisite for pinned artifacts on
   every reviewer.
2. [x] **Command collapse + the kills** *(shipped 2026-08-26)*. 9 commands → 5; `/auto` is the
   one loop verb; `/auto-plan`, `/auto-full`, `/auto-implement`, `/fleet`, `/ask-codex` and
   `helpers/fleet.sh` are gone. `--rounds` defaults to 4; `--plan` is capped at 2 with a
   direction-only bar *(superseded same day by the 10-per-phase default, d668cd8 —
   `--plan` now gets its own `--rounds` budget, no 2-round cap)*; the plan→implement
   transition keys on `phase`, not a workflow name.
3. [x] **`--reviewers a,b` fan-out** *(shipped 2026-08-26)* — `comms.sh panel dispatch`
   writes N parallel 2-party legs (`<thread>-<agent>`) sharing one `review_set` and **one
   snapshot**, validating the whole roster before sending any leg. The message contract
   stayed 2-party, so no reader, state file or existing test had to learn about panels.
4. [x] **The corroboration gate** *(shipped 2026-08-26)* — `comms.sh compose --set` clusters
   the union by SUPPORT and drops nothing: corroborated (gates), uncorroborated (cross-check
   first), unanchored, advisory. Every finding stays attributed. A partial panel refuses to
   compose — an unanswered leg is not an approval. No model arbitrates: judgment lives in
   the gate, which is what answers grok's objection that a judged bundle erases unique
   findings, while the 2026-08-25 dry-run showed reciprocal adjudication preserving them.
   **Reciprocal adjudication itself is NOT wired in** — the dry-run validated the mechanism
   on a real pair, but `compose` deliberately ships the no-model version first.

**The arc closed 2026-08-26**, and its last two bugs were found by the panel reviewing
itself — dispatched through `panel dispatch` to codex and grok on one pinned artifact,
composed by `compose`:

- **Round staleness** *(grok)* — `compose` found replies by reviewer+thread alone, so a
  panel round 2 composed round 1's replies and reported "all answered", gating on findings
  about an artifact it was no longer reviewing. Leg identity now includes the round.
- **The panel was not in the reply lifecycle** *(codex)* — dispatch and compose existed;
  the round between them did not. The reader now recognises `review_set`, composes instead
  of acting on one leg, refuses any-blocks through the back door, and re-dispatches the
  whole panel at round N+1.

**What the first real composition showed:** 2 legs, 7 findings, 6 blocking, and **zero
corroborated**. Both reviewers found real bugs; they found different ones. Under
`any-blocks` all six would have gated a round. The corroboration rule labelled them
"cross-check first" instead and manufactured no agreement that did not exist — which is
the token discipline the whole design is for. The two agents did converge on one defect
from opposite directions (codex: `compose` counts an answer before validating the message;
grok: a `type: error` on the leg counts as answered and then yields nothing), which is the
clearest evidence so far that a panel of two is not redundant.

### Found in the field, not yet fixed

- [ ] **Dispatch should refuse an already-answered `(thread, phase, round)`.** A second
  round-1 review arrived 80 minutes after the first, `in-reply-to` the same request and
  reviewing the same commit, after round 2 had superseded it. Nothing broke — it was
  archived unactioned — but a superseded or archived inbound was re-dispatched, and with a
  PANEL that duplicate becomes a phantom extra vote. *(codex, transport-flip round 3.
  The phantom-vote consequence was closed 2026-08-26 — compose accepts only replies
  bound `in-reply-to` to THIS dispatch's request id, 21c0d82, and retry rebinds the
  set row — but the dispatch-side refusal itself is still unbuilt.)*
- [ ] **End-to-end coverage for the `deliver → acp → spawn --via acp` path.** The committed
  suite asserts the selector; the path itself is proven only by a live run. *(codex.)*

### Any agent drives (2026-08-26, owner direction)

The project was built for **Claude to drive**: Claude has commands, Codex has reviewer
skills, grok has neither. The goal is for ANY registered agent to drive a loop and put the
others — **and/or another instance of itself** — on the panel.

Most of the plumbing is already agent-neutral: the registry, `inbox_for`, `transport`,
`peer_of`, the verdict rule binding by TYPE not sender, and `panel dispatch`. What is not:

- [ ] **The LOOP surface is Claude-only.** `/auto` installs into `.claude/commands/`; a
  driving Codex or grok has no equivalent loop verb. *(Narrowed 2026-08-26: the CONSULT
  half shipped as driver-neutral `comms.sh ask --from X --to Y [--wait]`, d80c213 —
  the quoted field-report complaint is fixed. What remains is the loop verb.)* The loop
  logic already lives in `comms.sh`; what is missing is a per-agent thin surface over it.
- [ ] **`from:` is written by the template, not derived.** A driver-neutral flow has to
  learn its own identity rather than hardcode `from: claude`.
- [ ] **Agent-named internals.** `send-to-codex` / `read-from-codex` bake a peer into the
  name; they should be `send` / `read` over `$REVIEWER` / `$SELF`, which the helper
  already is underneath.
- [ ] **Same-model panelists need distinct registered identities.** Two Claudes cannot
  share `to-claude/` — one inbox, one `peer_of`, one `awaiting_from`. A self-panel needs a
  second registered identity (e.g. `claude-review`, same backend, its own inbox), which is
  a registry and protocol change rather than a prompt one. *(grok, 2026-08-25.)*
- [ ] **Reviewer instructions are per-agent products.** Codex has skills, grok gets a
  parent-built prompt. Unifying on parent-brokering (already required for artifact mounts)
  would make reviewer-side instructions prompt FRAGMENTS rather than a second install
  surface — which is also what lets any agent review without bespoke wiring.

Sequencing note: this is cheaper AFTER the panel, not before — `panel dispatch` and
`compose` are already driver-neutral, so generalizing the surface is the remaining half.

### Field report from a Codex session (2026-08-26) — codex tried to consult grok and could not

Independently demonstrated, in the reporter's own priority order. All items were
resolved 2026-08-26 (see the checkboxes below).

- [x] **A first-class synchronous consult verb** *(shipped 2026-08-26 — `comms.sh ask --from X --to Y [--wait]`)*. Codex currently has to hand-author
  frontmatter, send, capture the run directory, await it, find the reply and archive it.
  Something like `comms.sh ask --from codex --to grok --wait --file q.md` would collapse
  that to one call. The asymmetry is the point: Claude has `/ask`, Codex has nothing.
- [x] **Stop requiring a writable `~/.npm`** *(shipped 2026-08-26 — `ACPX_BIN` override, else a gitignored workspace cache; `acp.sh launcher` owns it so nothing guesses twice)*. `npx` failed with EPERM under
  `~/.npm/_cacache/tmp`. Support an `ACPX_BIN` override, or default the npm cache to a
  gitignored workspace path such as `.comms/cache/npm`. This makes ACP unusable in
  sandboxes that deny the home cache — i.e. exactly the agent sandboxes we target.
- [x] **`send --wait`** *(shipped 2026-08-26 — runs the peer turn in the foreground, no detach)*. A detached process can be reaped when the
  managed shell command that spawned it ends, which is normal inside an agent sandbox. A
  synchronous runner would work in both terminals and sandboxes.
- [x] **Public / no-worktree mode — NOT DOING, by owner decision (2026-08-26).** The
  threat model is deliberately *"the same as running this agent by hand in the repo"*,
  because that is precisely what this tool replaces. A reviewer may read the tree and the
  git history; isolating it would make it a worse reviewer without changing what the
  owner was already doing manually.
  **The line that IS drawn: read, never publish or rewrite.** A mounted turn runs with
  `--approve-all` (the mount is a throwaway worktree), which means the child has a shell —
  and a linked worktree shares the main object store and the REAL remotes, so a `git push`
  from inside one reaches production. A `git` shim on the child's PATH refuses
  `push/commit/am/rebase/reset/clean/gc/prune/filter-branch/update-ref/remote` and passes
  everything else through, so `log`/`diff`/`show` — the reviewer's actual job — still work.
  Verified: a commit inside a mount moves only the mount's detached HEAD, never the main
  branch; the shim resolves the real `git` by absolute path so it cannot recurse.
- [x] **One-off questions get their own ACP session** *(fixed 2026-08-26)*. A message with
  no `thread` fell back to `acp:agent-comms-loop`, so unrelated consults shared one warm
  context and earlier questions leaked into later answers. Now keyed on `message_id`,
  which is unique per dispatch.
- [x] **`await` writes a synthetic failed result** *(shipped 2026-08-26)* when a spawned pid dies without
  producing `result.json`. Today it reports the failure but leaves an incomplete audit
  trail — and this session hit exactly that: a grok turn whose run dir held only a `pid`.

### Deferred, recorded so it is not lost

- A human seam in the plan phase (interview-until-answered, GSD-style) — wanted, not now.
- Token-compression principles (e.g. headroom) — revisit once the panel's real spend is
  measured rather than projected.

## Token-efficiency track (2026-08-26, from the headroom consult — codex + grok)

Consulted both reviewers on stealing from headroomlabs-ai/headroom. Consensus: steal the
cache-mode INVARIANT (frozen prefix, byte-identical history, only the live zone changes),
never the product (proxy/ML compressors are the wrong layer for hand-authored markdown,
and lossy rewriting of inter-agent instructions is the `$N`-corruption class). Ranked:

- [ ] **Warm ACP sessions are silently COLD on panel legs** (grok, consult): runphase
  mounts `artifact_id` at `$run_dir/tree` and cd's there, but acpx keys session identity
  on `(agent, cwd, name)` — run_dir is per-message, so every mounted turn is a new cwd
  and a fresh ~115k context while the session NAME looks stable. Fix: stable mount path
  per `(thread, agent)`, replace contents per round, keep cwd. This gates everything
  below — without it the 127x warm number is a single-reviewer footnote.
- [ ] **Skip re-dispatch of legs that already APPROVEd the artifact** — a driver rule,
  not compression; reserve full-panel holistic re-dispatch for the final round.
- [ ] **Live-zone delta prompts on warm legs**: round N+1 over a warm session sends only
  the round header, diff --stat delta, and amendments — the instructions and prior
  findings are already IN the session. Cold/headless keeps today's full inline.
- [ ] **CCR as protocol norm**: terse summary + canonical path/ref instead of mandated
  copy-forward (prior-findings bundle, full plan text) on warm legs — the filesystem is
  already the reversible store. Copy-forward was designed for a reader with no session.
- [ ] **Instrument per-leg spend** (ships WITH the two above, not as a gate): lift
  acpx's token-usage line + events.ndjson usage into result.json and a rounds.tsv
  column, so the delta is measured.
- [ ] Tail-of-prompt verbosity steering, narrowly ("no preamble, findings are
  path:line + claim" — never "be brief": terseness that punishes reproduction buys
  cheaper, worse reviews). Error-only validation reporting (failures + counts, never
  green logs). Warn-only lint of assembled prompt.md prefix stability + ACP identity —
  NOT of mailbox files (frontmatter must change; all false positives).
- Skip (re-litigate only with new evidence): SmartCrusher/AST/ML prose compression,
  proxy + MCP machinery, SharedContext (that is `.comms/`), wrapping agent CLIs
  (documented unsupported — it fights acpx session identity).

## Multi-session concurrency track (2026-08-26, user-requested reflection — PENDING)

Three Claude sessions worked this checkout simultaneously (two review loops + one
claimed work item). The user asked for a deliberate reflection on graceful multi-agent
concurrency "and if we need any formal changes"; their observation — each session
reconstructed the others' intent from durable artifacts (commits, sets.tsv, state,
friction.tsv, reviewer-credited comments) — held up. Nothing below is decided; this
records the evidence while it is fresh.

Worked with no formal mechanism: durable artifacts as ambient coordination;
ListAgents/SendMessage for claims, stand-downs, and a stash-window negotiation;
independent cross-verification (one session caught another's case-sensitivity bug and
a sweep its author had ruled out by checking files, not hunks).

Observed failure modes (one afternoon, all real):
1. **Commit sweeps** — three whole-file/`-A` stagings captured a PEER's hunks;
   file-level "did I touch it" checks cannot detect hunk-level capture.
2. **Dirty snapshots** — two panel dispatches pinned a peer's uncommitted WIP into the
   review artifact as the visible diff-under-review; one survived only because the
   request carried an explicit out-of-scope paragraph.
3. **Half-written reads** — a running `runphase.sh await` crashed on a syntax error
   from a peer's mid-write of the same helper; unreproducible afterwards.
4. **Double-claiming** — two sessions claimed the same loop within minutes; resolved
   only by direct messaging.

**DECIDED 2026-08-26 (user):** per-session worktrees + integration branch is the
long-term direction — adopt as the next protocol arc (installer support, docs,
and loop-driver guidance). Sessions should begin practicing worktree isolation for
multi-file changes now, ahead of the formal mechanism. Related user decision the
same evening: the loop round limit moves to 10 (default `--rounds`), landed by the
field-report driver — round-budget references in docs/templates follow that change.

**Design settled later the same evening (user):**
- **`main` IS the integration branch** — no named intermediate branch. Session
  branches merge to `main` serially, suite run at the merge commit (the frozen-tree
  property by construction). A review gate on merges can be added later only if
  wanted; start minimal.
- **Worktrees are CONDITIONAL on concrete peer detection, not on task size.** The
  triviality carve-out was considered and superseded: the rule is presence-based.
  Mechanism — a presence heartbeat in `.comms/sessions/<name>.json` (role, pid,
  started, last-heartbeat; refreshed while working, removed on exit, stale after
  ~10 min or dead pid). CLAIM-THEN-CHECK ordering: write your own presence FIRST,
  then list others — shrinks the simultaneous-start race to seconds. Any live peer
  presence → work in a worktree; none → edit the shared checkout directly.
  Invariant this yields: **the shared checkout has at most one writer** (the first
  arrival; later arrivals isolate). Driver-agnostic by design — any registered
  agent writes the same file; the Claude session bus (ListAgents) is only a
  supplementary cross-check. This is the same record the role ledger wants:
  presence and declared role are one file.

**Convergent recommendation (end of day, all three drivers independently):**
per-session git worktrees with an integration branch. By close of day the staging
rule had been violated by all three sessions — including its authors, including
after writing it down — five sweeps total. A rule violated by everyone on the day
it was written is a symptom, not a rule: the root cause is a shared mutable
checkout with no lock and no notion of in-progress. Worktree isolation removes the
failure class instead of policing it; the integration branch is where composition
happens deliberately. (Proposed by a2's session, endorsed by 01 and 7b; put to the
user by all three.)

Candidate formalizations to weigh at the reflection (minimal-first):
- [ ] Staging discipline as a written rule: explicit paths / hunk-level adds in shared
  checkouts (all three sessions converged on this ad hoc the same day — and all three
  then violated it; see the convergent recommendation above).
- [ ] Snapshot guard: `snapshot create`/`panel dispatch` warns or refuses when the
  dirty diff exists, or requires the request to carry an explicit out-of-scope
  paragraph for foreign WIP (the one mitigation with observed field success).
- [ ] Atomic writes for installed/shared helpers (write temp + `mv`) so concurrent
  readers never see a half-file.
- [ ] Installed-copy lag detection: nothing warns when `~/.agent-comms` /
  `~/.claude/commands` lag the repo they are reviewing. Bit twice on 2026-08-26:
  stale panel-status logic produced a false "both answered", and the 10-round
  default self-certified green in-repo while every installed run still budgeted 5 —
  the dogfooding loop validating the change would have run at the old cap and
  appeared to confirm it. Fix shape: a version stamp (content hash) written at
  install and compared at dispatch/loop-entry; warn on mismatch, refuse on
  `COMMS_STRICT_INSTALL=1`.
- [ ] A durable claim ledger (thread/region → session), so ownership is declared in
  the repo instead of in chat; `sets.tsv` already models the shape. Refined
  2026-08-26 (user): the ledger should also carry a DECLARED ROLE per session —
  harness session names are identity-shaped (`<workspace>-<suffix>`, not
  controllable from inside a session), so the protocol names the task itself:
  `role set "panel-arc-7972 driver"` → a sessions table mapping harness name →
  role → claimed threads/regions. Same declared-beats-inferred principle as the
  `workspace set` pin; anchors naturally to the per-session worktree.

## Maintainability & implementation-language track (2026-08-26, user direction)

The shell implementation has reached a real refactor threshold, but file size alone is
not the decision. `comms.sh` is a command router and much of its size is explicit policy;
`tests/run.sh` is a regression corpus. The stronger signals are responsibility and
feedback-loop concentration: `runphase.sh`'s `cmd_run` owns argument policy, artifact
mounting, prompt construction, provider invocation, ACP sessions, supervision, timeout,
brokering, state, and cleanup; the single test script now carries roughly 800 assertions
with no subsystem selector; and structured protocol logic (frontmatter, findings,
verdicts, composition, JSON state) is implemented through repeated awk/sed boundaries.

**DECIDED 2026-08-26 (user): do NOT pursue a wholesale language rewrite.** Bash remains
the supported installer and orchestration layer for Git/worktrees, cmux, environment
setup, and external CLI execution. Do not replace all helpers, change the wire protocol,
or make a new runtime mandatory for non-ACP commands as part of a cleanup. A language
extraction is evidence-gated, not the default destination.

Sequence — begin only after the current concurrent work lands on a pinned, green tree:

1. [ ] **Behavior-preserving Bash decomposition.** Break `cmd_run` into explicit seams for
   artifact preparation/cleanup, provider command policy, ACP execution, ordinary process
   execution, and result finalization. Start within the existing helper if that avoids
   install and merge churn; smaller files are not themselves the goal.
2. [ ] **Split the harness by subsystem.** Keep one umbrella `bash tests/run.sh` gate, but
   move shared fixtures/stubs into test-only helpers, add focused section selection, and
   separate protocol, runphase/provider, panel/grading, transport, and installer tests.
   Update the documented assertion count so harness growth is visible rather than stale.
3. [ ] **Reassess the pure protocol core after those two steps.** If parsing/state defects,
   duplication, or test friction remain concrete, extract ONLY frontmatter validation,
   findings/verdict parsing, composition, and JSON state serialization behind the current
   CLI contract. Node is the preferred candidate because ACP already depends on it; use a
   dependency-light JavaScript artifact (or compiled TypeScript) and keep shell at the
   process boundary.
4. [ ] **Stop if the evidence disappears.** If decomposition and focused tests make the
   shell core safe to change, do not migrate languages for aesthetics. Any extraction
   needs before/after protocol fixtures, installed-scope coverage, and byte-for-byte
   compatibility for existing messages/state before it can ship.

**Step-3 evidence, recorded 2026-08-27 (presence-worktrees-15135 implement rounds).**
The presence arc's review history is a controlled measurement of shell friction:
of ~19 implement-phase findings across five panel rounds, ~13 were SHELL-SEMANTICS
defects, not logic defects — `wait` returning 143 under errexit, `set -e` killing a
background beater on a nonzero beat, `var=$(cmd); rc=$?` breaking on bash 4.4
inside substitutions, EXIT traps firing after function locals vanish (twice),
background stdin silently rebinding to /dev/null, PID-vs-process-group teardown,
a signal latch gap, inherited-SIG_IGN untrappability, and pipefail aborting
readers on `sed` of vanished/EACCES files at three sites. The design itself
survived ten plan rounds unchanged; the language fought the implementation.

The friction CONCENTRATES: the liveness/reap core (pure state logic) and the
`with-beat` supervisor (~40 lines that consumed most of three rounds) account for
nearly all of it, while `worktree new`/`integrate` are thin git orchestration
where shell is the right tool (the CAS is one `update-ref`). Named extraction
candidates when the gate opens: **presence liveness/reap + with-beat**, behind the
existing verb/exit-code CLI contract, as the dependency-light Node artifact step 3
describes — Node handles signals, child processes, and JSON natively, deleting
the errexit finding class outright. Integrate/worktree stay shell.

Two mitigations that lower the urgency: every shell trap found is now a pinned
behavioral regression test (the marginal risk of the shell version dropped each
round), and that suite transfers to any reimplementation as its spec — the rounds
bought a spec, whichever language executes it.

### Suite runtime (2026-08-27, user: "that seems excessive") — extends step 2

A full run is ~8–12 minutes wall-clock at ~912 assertions, and a landing costs
TWO runs (the pre-flight plus integrate's re-run at the candidate OID). Cost
profile, estimated not yet measured: per-assertion `comms.sh` spawns (fresh bash
+ several git subprocesses, likely the dominant term), deliberate real-time
waits in the cancellation/quiescence/TTL sections (~2 min), per-section
`git init` fixture churn, and fully serial execution.

Ranked work, foldable into the step-2 harness split:

1. [ ] **Profile before optimizing.** Per-section timers in `run.sh`; confirm or
   refute the spawn-overhead estimate. If spawning dominates, the durable fix is
   batching assertions per invocation, not trimming sleeps.
2. [ ] **Tier the suite.** Fast default tier skips the stress probes (the
   20-iteration cancellation loop and quiescence torture runs guard an invariant
   5 iterations still catch); full stress tier reserved for integrate and CI.
3. [x] **Attested-green shortcut for integrate.** DONE 2026-08-27 (double
   APPROVE, integrate-ergonomics r1): `attest-green` records "green at this
   HEAD" bound to the commit the run started on; integrate consumes a fresh
   same-OID record when `suite-attest-secs = N` is configured. Opt-in; the
   paranoid re-run stays the default. Landed alongside self-healing
   never-occupy-main (a clean checkout idling on `main` is fast-forwarded
   through the landing instead of refusing it after a ten-minute suite).
4. [ ] **Shard sections in parallel** with isolated TMPDIRs — except the
   signal-timing presence section, which stays in its own unshared lane (machine
   load provably flaked it during the presence arc).
5. [ ] **Back-date instead of sleep** in the remaining age-based tests (most
   already stamp epochs).

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
   *(Update 2026-08-26: grok has now run as gating AND shadow reviewer across three
   loops — rounds.tsv, sets.tsv, and findings.tsv are accumulating the comparison
   baseline, so "nothing to compare" is expiring.)*
   Escape attribution as a routing metric is cut, not deferred. Panels, routing, the judge,
   and adjudication-gated items stay deferred with reasons recorded in the track.
6. Remaining scope-dial items (dispute lane and test-evidence contract — informed by the
   grading track, but their deliverables stay tracked in the scope-dial section above;
   budget signaling; stakes-tiering docs) and the standing DEFERRED backlog in
   docs/advisories.md

## Open security item: the mounted review turn has no enforced boundary

*(field-report-9446 round 8, codex. The top open item on this track.)*

A mounted ACP review turn runs with `--approve-all`, which grants the child a shell. The
protections on that path are the mount (a throwaway linked worktree with no `.comms` in it)
and a PATH shim that permits only read-only git verbs, scrubs the config/exec environment,
and refuses write/exec flags. Both raise the cost of an accident and close the easy
deliberate paths. **Neither is a boundary.** A child can call git by absolute path or write
files with the shell, and a linked worktree shares the main object store and the real remotes.

`COMMS_RUNPHASE_GROK_SANDBOX` does NOT apply here — it configures the direct grok command
path only. Claiming it as the boundary for mounted turns was wrong, and was corrected in
round 8 after a reviewer traced the flag to its actual call site.

What would make it real, roughly in order of cost:

- `acpx --permission-policy <json>` (autoApprove/autoDeny/escalate/defaultAction) instead of
  `--approve-all`, denying writes and non-git execs while still allowing the read-only
  terminal commands a review genuinely needs. This is the ACP-layer lever that already
  exists and is unused on this path.
- An OS sandbox profile applied to the mounted turn, the way the direct grok path does it.
- Running the mount from a repository with no remotes and a detached object store, so a
  publish has nowhere to go even if a write escapes.

Until one of those lands, the honest statement is the one now in the code comment and in
acceptance criterion 9: defence in depth, tested by invariant, not a containment guarantee.

## Field report — cmux freeze incident (2026-08-27, coordinator session)

Live 90-minute recovery: the cmux host livelocked its main thread with four agent
sessions as pty children; three parked at unapprovable permission prompts, every
liveness signal went dark identically to death, and one near-miss staleness-rule
takeover targeted WIP that later fingerprinted to a DIFFERENT agent than assumed.
Full narrative in the archived report
(`field-report-cmux-freeze`, 2026-08-27). Items, feeding the presence-worktrees arc:

1. **Presence needs a third state: `blocked-on-human`.** Parked-at-prompt is the
   dominant real failure mode and reads as dead under the staleness rule. A
   Notification-hook beat (`awaiting-approval`) makes it visible for free; blocked
   agents keep leases longer than silent ones.
2. **Absence = beat staleness AND a process check.** A 12h-stale beat sat next to a
   live pid mid-await. Presence records must carry the pid; `kill -0` + children
   check disambiguated every case live. Uncheckable stays ambiguous (fail-closed).
3. **Presence records as resume manifests**: session_id, pid, cwd, and the literal
   resume command — takeover reads facts instead of doing transcript forensics.
4. **No uncommitted WIP in the shared checkout across a turn boundary** — commit to
   `wip/<agent>` or agent-tagged stash first; ownerless working-tree changes caused
   today's misattribution. (Interim practiced: `wip/01-orphan` parking.) The parking
   worked twice and lost nothing, but it is a PRACTICE, not a mechanism: it held only
   because a coordinator was awake to run it. Practices hold until the first freeze.
5. **Awaits must drain the inbox while waiting** — the file-drop channel survives a
   wedged socket only if await loops poll it; add a sentinel-file interrupt.
6. **Panel completion writes to the awaiting agent's inbox, not only the run dir** —
   verdicts sat unconsumed 40+ minutes because their only consumer died with its
   session.
7. **Reduce single-host blast radius**: detached supervisor (tmux/launchd) over
   UI-owned ptys; with item 3, agents become recoverable anywhere. (Deployment
   guidance.)

Priority per the coordinator: 1–4 small with this incident as their test case; 5–6
would have most shortened recovery; 7 is deployment guidance.


## Declared-beats-inferred (2026-08-27 — the day's unifying invariant)

Named by presence-worktrees-3a, endorsed by all drivers: **an inference that can
drift must be replaced by a declaration that cannot.** One entry, everything
cross-referenced; the individual filings fold in here. agent-comms-a7's test-layer
corollary (the session peers addressed as "01"), from the same day's grep sweep: an assertion that names a property but
observes a proxy is the suite's version of an undeclared writer — in both cases the
fix is to observe the thing itself.

- [x] **Message layer** — shipped as the stamped-authorities loop (field items #3/#6,
  a5b6bd0..8c084ba, five rounds, double APPROVE): workspace identity is a repo-scoped
  PIN, not a title inference; artifact_id/head_sha are stamped from one snapshot
  object, never hand-typed or live-derived; field presence is physical lines, never
  value truthiness; every value is checked, unstripped, then normalized.
- [ ] **Session layer** (presence arc, in flight with presence-worktrees-3a):
  declared roles + pid + start-time in `.comms/sessions/` make a resume-fork twin
  self-evident at claim-then-check; one live process per session. The pid field
  needs its definition DECLARED too (agent-comms-a7, self-caught): a record written
  with the transient tool-shell's `$$` is dead seconds later — "a field that names
  a property (this session is alive) while observing a proxy that does not track it
  (whatever shell happened to run the write)." Correct definition: the Claude
  process pid, which equals the session's socket name
  (`/tmp/cc-socks/<pid>.sock`) — an independent second liveness check that does not
  trust the number in the file. Existing records predating this rule carry absent
  or proxy pids and cannot be staleness-checked. TWO independent instances, which is
  the argument for mechanizing rather than documenting: the rule caught its own
  author first (a7's own record), then caught agent-comms-be's on the next read —
  and be's stated history ("both carried transient pids") was itself a rounding of
  what was on disk, where one record carried a proxy and the other carried nothing.
  A hand-written declaration drifts from the thing it declares in exactly the way an
  inference does; only a generated one cannot.
- [ ] **Run layer**: panel run dirs and leg filenames must EMBED the thread —
  three simultaneous `panel-codex-NNNNN` dirs were indistinguishable without opening
  messages, which enabled the 2026-08-27 wrong-kill (7b's r6 codex reviewer).
  Corollary rule, effective immediately: **killing a reviewer pid requires a
  mechanical leg-thread check first** (open the leg, match the thread), same lane as
  takeover-parking.
- [ ] **Relay layer**: coordination relays get the verify-from-source discipline
  reviews already get — two same-day relay-attribution errors (the misattributed
  tests/run.sh WIP; the 89343-as-r5 misattribution) were both resolved by opening
  the artifact instead of trusting timing/pid heuristics.
- [ ] **Arrival layer**: under acp/headless the only finished-panel signal is the
  driver's own await, and awaits die with their process (all of them died in the
  2026-08-27 freeze; verdicts became silent stalls until a human relayed them).
  Needed: a durable, re-armable driver-side arrival signal — `panel status
  --notify`, a harness-owned inbox watcher that re-arms on resume, or a
  deliver-to-driver nudge for cmux-hosted drivers.
