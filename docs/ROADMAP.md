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
