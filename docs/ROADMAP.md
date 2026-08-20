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

- *2026-08-19, external 18-round loop (writer-side retrospective, relayed by user):* the
  loop's costs were structural, not incidental — the reviewer controls scope (binary
  verdict → rounds 6–8 hardened a prototype nobody asked to harden), one reviewer
  serializes everything (an outage froze the loop), and the writer felt themself
  optimizing messages to pass review. Full carry-over in docs/advisories.md 2026-08-19;
  actionable asks tracked in the scope-dial track below. Validations: atomic
  send+archive perfect across 18+ rounds, full-plan restatement credited for plan
  convergence, process channel delivered the report itself.

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
- *2026-06-05, field incident #2 (atlas):* send returned `RESULT: manual` despite an
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

- [x] **Symphony Level-1 adoption (step 4)** — shipped 2026-07-06, symphony commit
  84996ae (local main): vendored kernel at a PIN via `scripts/sync-loopspec.sh` +
  an ExUnit conformance reader; ReviewCheck verdict synonyms (strip-all
  normalization, gate-only); `Workflow.Advisories` closes the pass-round
  advisory-death gap (machine-local, LESSONS-style — the repo-commit path is the
  named Level-2 follow-up); holistic-rereview fragment embedded verbatim with a
  containment test; lessons in the compounding format. Fragments are consumed via
  the builtin templates rather than `.symphony/workflows` override slots (overrides
  replace whole prompts; verbatim containment beats file generation). Reviewed by
  the first cross-repo headless loop: APPROVE round 1.
- [ ] **Make non-cmux (headless) delivery the DEFAULT** — decided 2026-07-06, gated on
  the soak threshold: 10 successful headless loops including ≥3 claude-resume/attach
  exercises and ≥3 reverse-direction handoffs. Soak progress 2026-07-07: +7 turns / 4
  full loops from symphony's audit-fix arc (incl. one 3-round thread and one
  timeout-kill → re-delivery recovery — state stayed coherent); still needed:
  resume/attach and reverse-direction exercises. Field findings (runner wall-clock
  timeout, cmux false-`delivered`, RESULT naming) recorded in docs/advisories.md
  2026-07-07 — the timeout idle/salvage fix should land before the flip. Prerequisites: per-repo persistence for
  the delivery mode (`.comms/config`, not env-var-only) with staged per-repo opt-in
  (hobby repos first, client repos last); cmux stays selectable as fallback for one
  release after the flip.
- [ ] **Retire fleet.sh into symphony (step 5)** — HARD-GATED on a trackerless
  `symphony run` local mode covering status/dispatch/dispatch-all/harvest/concurrency
  caps/dirty-tree+push safety/stalled recovery. fleet.sh is live orchestration until
  then (frozen, but kept correct — see the pass-synonym fix).
- [ ] **Delete cmux delivery (step 6)** — one release after the default flip with no
  fallback invocations; deletion audit must include cmux-mgr dispatch (live consumer);
  keep optional log/tail viewing only if useful. Interop drill before declaring done.

## Scope-dial track (2026-08-19 external field report)

From the 18-round writer-side retrospective (carry-over: docs/advisories.md 2026-08-19).
Ordered by cost/value; the first three are template-only edits.

- [ ] **Verdict-discipline fragment**: add "pre-existing defects in code the change didn't
  touch are Advisory by default" to `docs/loopspec/fragments/verdict-discipline.md` and
  its embedded copies (send-to-claude, send-to-codex). Prose fragment addition —
  backward-tolerant, no schema change. (`APPROVE_WITH_CONDITIONS` as a verdict value:
  rejected — duplicates APPROVE + advisory carry-over, forces a loopspec major on symphony.)
- [ ] **Acceptance criteria pinned at implement round 1**: auto-implement/auto-full
  templates add an `## Acceptance criteria` section to the round-1 implement message;
  reviewer prompts judge later rounds against it instead of re-deriving the bar each
  holistic pass.
- [ ] **Scope ledger**: a `### Scope additions` running list (review-driven additions +
  rough cost) carried forward each round alongside prior-review context.
- [ ] **Writer dispute/escalate lane**: a sanctioned reply that contests a blocking
  classification and pauses the loop for a user scope decision instead of complying or
  burning a round. Touches termination conditions in both read skills — design first.
- [ ] **Shared test-evidence contract in plan phase**: plan template states which layers
  get what kind of proof at which checkpoint, so evidence boundaries aren't litigated
  mid-loop.
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

- [ ] **Generalize the two-party core** (prerequisite for everything):
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
- [ ] **Grok Build headless integration**: runphase provider arm (shape ≈ the claude leg:
  `-p` + streaming-json + session id from events), `/ask grok` via the registry, reviewer
  role via `--reviewer grok` on auto-* commands. Verify live: does it read our AGENTS.md
  managed block and Claude-format commands as claimed?
- [ ] **Reviewer parameterization**: auto-plan/auto-implement/auto-full accept
  `--reviewer <agent>` (default codex); templates stop naming codex in prose where the
  reviewer is meant. Also answers the field report's "serialization on one reviewer" —
  a third reviewer with different priors is outage resilience AND diversity.
- [ ] **ACP delivery backend (Tier 1 spike, scoped 2026-08-19)**: `COMMS_DELIVERY=acp` via
  acpx (headless CLI ACP client; pin — pre-1.0). Decision gate: Node ≥22.13 dependency
  acceptable as an OPTIONAL backend. The spike's deliverable is ONE measurement: round-2+
  token cost warm ACP session vs cold `runphase` spawn (runphase re-pays full instruction
  payload every round — session ids are recorded but never resumed). Mapping is clean:
  thread → named session, exit codes → RESULT lanes, loopspec result/thread-state schemas
  unchanged (delivery-agnostic, no symphony impact). Second justification: makes agents
  4+ (gemini, copilot, cursor — all ship ACP adapters) near-zero marginal cost. cmux and
  runphase stay; ACP is a third backend, not a replacement.

## `/ask` unification (2026-08-20, supersedes the bare-`/ask-codex` decision above)

Decided (user-confirmed): ONE `/ask` template scaling across agents, not `/ask-<agent>`
copies. The informal-consult ("thoughts?") design above carries over unchanged — only the
command shape evolves:

- [ ] `/ask <agent> <question>` — first word validated against the agent registry names
  the target; not an agent name → the whole text is a question to the DEFAULT agent
  (codex, set in `.comms/config`) — *partially delivered 2026-08-20 (hard-coded
  known-agents seam in ask.md); registry semantics land with the multi-agent core*
- [x] bare `/ask` (or `/ask <agent>` alone) → thoughts mode per the informal-consult spec
  (verbatim excerpt, floor = user's last question + the answering message) — shipped
  2026-08-20 (thread ask-unification-10480)
- [x] `/ask-codex` becomes a thin deprecated alias for one transition release, then drops
  — alias shipped 2026-08-20; the drop happens next release
- [ ] adding an agent touches ONLY the registry — the template reads names from it (DRY)
  — *partially delivered 2026-08-20 (single prose-defined list in ask.md is the interim
  one-place set); registry semantics land with the multi-agent core*

## Priorities (2026-08-20, user-confirmed order)

1. **`/ask` unification + thoughts mode** — one template change, daily-use pain, and doing
   the informal-consult edit on the new shape avoids reworking `/ask-codex` twice
2. **Scope-dial template trio** — verdict-discipline sentence, pinned acceptance criteria,
   scope ledger (the three template-only field-report fixes)
3. **Multi-agent core + Grok Build headless** — registry/generalization, then Grok as
   consult + reviewer
4. **ACP Tier-1 spike** — warm-vs-cold measurement; gated on the Node-dependency decision
5. Remaining scope-dial items (dispute lane needs design; test-evidence contract; budget
   signaling; stakes-tiering docs) and the standing DEFERRED backlog in docs/advisories.md
