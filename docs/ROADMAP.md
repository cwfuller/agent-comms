# agent-comms roadmap

**Current program: [Contraction (2026-08-28)](#contraction-2026-08-28--current-program).**
Do that sequence. Historical tracks below are evidence, not the queue.
"Priorities (2026-08-20)" is superseded.

Backlog from the 2026-06-04 multi-agent audit (64 agents, 56 raw findings → 49 confirmed
after adversarial verification) plus field reports from three agents running the loops
daily. Check items off as they land.

## Contraction (2026-08-28) — current program

### Step 4 status and the S4-2 plan verdict (2026-09-01)

**Step 3 is COMPLETE** — all five increments on main: the provider-neutral broker, brokered
claude/codex ACP legs, the measured claude isolation arm, shadow gating on (agent, transport),
and the review bar as installed data. The gate on step 4 is cleared.

**S4-1 (suite off cmux)** is double-APPROVED. `mailbox` is now an accepted INPUT to
`cmd_transport`, the suite's default is `mailbox` rather than `cmux`, and the five sections that
had been INHERITING cmux from the global default now ask for it explicitly. The plan predicted 18
explicit call sites and assumed that was the dependency; it was not — those five inherited it
silently and would have changed meaning when cmux is deleted.

**S4-2 (delete self-send): planned, NOT yet implemented. The plan round corrected the approach on
two points, and both corrections are load-bearing — do not skip them.**

1. **Deleting the self-send arm ALONE produces false-success turns, not ACP-only behaviour.**
   A non-ACP claude/codex run would skip `build_grok_prompt`, invoke the provider with no newly
   built prompt, and still take the generic `rc=0 -> completed` branch, because only grok calls
   `grok_broker`. The increment must ATOMICALLY: make non-ACP claude/codex unreachable or
   fail closed; change `cmd_transport` so it never selects `headless`; remove or refuse the
   explicit `COMMS_DELIVERY=headless` route; and give direct `run`/`spawn` callers a clear
   ACP-required failure. (codex, S4-2 plan r1, blocking.)

2. **"Re-point the existing tests to ACP first" is NOT a safe green intermediate** — it removes
   coverage before removing behaviour. Most of the 45 `runphase v0` assertions are not
   transport-agnostic: they specify headless routing, self-send pickup, child-environment
   propagation, direct CLI execution, and self-send success/failure semantics. Re-pointing them
   while headless is still live leaves a still-supported path untested. Correct order: FIRST add
   the missing ACP equivalents while RETAINING the direct tests; THEN atomically remove direct
   routing plus self-send behaviour and its path-specific assertions. Two commits is fine; that
   order is not optional. (codex, S4-2 plan r1, blocking.)

**Measured blast radius, and then MEASURED AGAIN by experiment.** Section sizes are
`runphase v0: headless delivery via stubbed codex` = 45 and
`runphase step 2: claude backend, direction pickup, hold, watchdog` = 33, plus 12 `run_headless`
call sites. The roadmap's earlier estimate of ~19 path-specific assertions is wrong.

The SPLIT was then established empirically rather than by reading: land the ACP-only guard alone
(no test edits) and let the suite enumerate what breaks. Result — **25 of the 45 and 17 of the 33
are path-specific**, i.e. ~42 die with the behaviour and ~36 are transport-agnostic and need ACP
equivalents BEFORE the removal. That experiment is cheap and repeatable; do it again rather than
trusting this number if the corpus has moved.

**S4-2 REMOVAL: code done, test surgery outstanding (2026-09-01).** The behaviour change is
written and internally coherent on `worktree-selfsend-removal`; the suite is RED by design and the
remaining work is enumerated below. Do not land until it is green.

Code, done: the 62-line self-send arm deleted (0 self-send instruction sites remain); the ACP-only
guard for claude/codex; the artifact suppression removed, so EVERY review turn is now
artifact-bound — the self-send path was the one place that promise did not hold; and a single
`headless_ok` predicate gating all four headless rungs in `cmd_transport`.

**That last one was a real trap.** Gating only the explicit `COMMS_DELIVERY=headless` input left
the loop ladder and consult fallback still SELECTING headless for codex, so `transport` promised a
route `runphase` then refused — surfacing as "codex was NOT spawned … likely runphase.sh missing",
i.e. blaming a broken install for a deliberate change. Transport and runner must be gated on the
same predicate or they drift.

**Test surgery remaining — 74 assertions across 4 sections**, measured with the code in place:
- `runphase v0: headless delivery via stubbed codex` — 38 of 45 fail. Mostly DELETE: they specify
  the self-send prompt, direct CLI argv, child-env propagation, headless routing.
- `runphase step 2: claude backend, direction pickup, hold, watchdog` — 24 of 33. Same shape.
- `the coordinator's event log` — 8. These are NOT about the deleted path: the fixtures drive a
  codex turn and relied on headless to spawn it. RE-POINT to ACP (an acpx stub in PATH) or grok.
- `comms.sh: transport selection` — 4. Semantics changed on purpose; retarget to assert headless
  is grok-only and refused for codex.

**The removal map, computed rather than estimated (2026-09-01).**

- `helpers/runphase.sh` — the self-send arm is lines **2423..2483** of the prompt fork that opens
  at 2414 (`else` at 2422, `fi` at 2484): **61 lines**. Verified self-contained: every local it
  sets (`self_desc`, `instr_a`, `instr_b`, `instr_note`, `comms_q`, `msg_q`, `prev_d`) is read
  NOWHERE after the fork, so they die with it. `$peer` IS still read 3 times afterwards and must
  survive; trim the declaration at 2399 to `peer` alone.
- `helpers/comms.sh` — three headless rungs: the explicit input (4075), the loop ladder
  (4119, `runphase_available`), and the consult fallback (4145, non-`*interactive*`).

**A qualification the plan's sketch got wrong, and it matters.** "Make `cmd_transport` never
select `headless`" cannot be taken literally: grok's registry capability is
`headless,reviewer-consult-only`, so GROK'S DIRECT PATH *IS* the headless transport — and grok is
parent-brokered there (the `provider = grok` disjunct), so it is not self-send and must keep
working. After the arm is deleted the correct rule is **headless is valid only for a provider that
is brokered without ACP, i.e. grok**; claude/codex must fail closed. Removing the headless rungs
outright would break grok's direct path, which step 4 never intended to touch.

**The guard itself is written and verified** on `worktree-selfsend-removal`: a non-ACP claude or
codex `run` now dies with "review turns are ACP-only — re-run with --via acp". That guard is what
makes deleting the arm safe rather than silently wrong, and it is the piece to keep if this branch
is otherwise restarted.

**Known trap:** `broker_extract_stream` parses `{"type":"result", …}`, which matches grok and
`claude -p --output-format stream-json` but NOT `codex exec --json`. The direct arm therefore
cannot simply be re-pointed at the broker — it dies with the self-send prompt, or it needs a
per-provider extractor first.

**Still open after S4-2:** S4-3 (retire the reviewer-side codex skills through `RETIRED_*`, not
deletion — `prompt_surface_files()` hashes those paths, so `prompt-version` shifts and PARTITIONS
the grading ledger), S4-4 (delete cmux), S4-5 (docs).


Decided after independent grok + codex re-evals of the product (local `9c3b10e`,
main 43 commits ahead of origin) and a merge pass. Owner confirmed the sequence
and that **strict is the default** — this tool is only installed on projects that
want that bar. Re-litigate only with new evidence.

**The product** is a cross-vendor, artifact-bound adversarial review gate:
snapshot a tree, independent reviewers read that snapshot over ACP, the
coordinator stamps and records everything, composition applies an explicit gate,
the author fixes or a human is asked.

**Not in the installed product:** presence, session worktrees, `integrate`,
grading, suite attestation, cmux. Those stay this-repo contributor tooling until
step 7 removes them from the install surface.

**Keep:** loopspec, retained artifacts, two-party legs, fail-closed parsing,
provenance, partial-panel refusal, human escalation. Markdown is the human
archive. ACP is transport and session. The coordinator's event log is the source
of truth — never the model's mailbox, never ACP itself.

**Nothing is in flight (2026-08-31).** Both branches this block used to reserve have
landed: `acp-warm-mount` (step 1) is on main, and `suite-lanes` carried the per-section
assertion vector and the watchdog-poll fix, which are on main too — `worktree-suite-lanes`
now has zero commits ahead. Read a branch's real distance from main before treating this
block as a reservation; it was stale for a day before anyone checked. `suite-perf` /
`worktree-suite-shard` also has no commits vs main. Do not start a new suite effort:
sharding was measured at 1.07x and rejected (ranked item 4), and the vector — the thing
that detects assertions MOVING between sections — is already landed and earning its place.

### Freeze

No new *product* tracks until step 4 has deleted cmux/self-send: grading,
routing, a judge, dispute lane, presence-heal, findings-grammar widenings,
Node extraction. **Suite runtime is not frozen** — it is step 2, owner pain.
The named zombie presence records (`7b`, `a2`, `a7`, `be`) may be force-reaped
exactly; that is not a license to weaken the presence model (see step 7).

### Sequence (do in this order)

1. **Land `acp-warm-mount`.** The README's "~1k vs ~115k" claim is currently
   false on the default panel path: mounts go to `$run_dir/tree` while acpx keys
   identity on `(agent, cwd, name)`, so every mounted turn is cold. Someone is
   already fixing it. This also makes later token claims measurable. Do not
   start a second copy.

2. **Cut the suite wall-clock.** Owner, 2026-08-28: five-plus minutes is a
   first-class pain, not a later maintainability leftover. Profiled 2026-08-27
   (see [Suite runtime](#suite-runtime-2026-08-27-user-that-seems-excessive--extends-step-2)):
   504.8s → 325.8s after the unconditional state-wait was removed; the landed
   tree is ~340s because new assertions spend ~25s exercising that wait. Spawns
   are ~5%, sleeps ~27s, `git init` is noise. The cost is concentrated: ten of
   59 sections were 87% of the original runtime; the largest section after the
   fix is ~50s.

   **Superseded — sharding was built, measured at 1.07x and REJECTED; see ranked
   item 4.** What actually moved the number was profiling: a `sleep 1` in the
   provider watchdog cost 58s a run (13%), and polling it finely took 430s -> 364s
   ON IDENTICAL TREES (the absolute figures are stale — the corpus has grown since;
   pair every runtime with its assertion count).
   `suite-lanes` still earns its place for the per-section vector, which detects
   assertions moving between sections — but nothing here should be read as an
   instruction to shard.
   - **a sharded or partial run must never mint an attestation** (the
     coverage contract is the gate, not a courtesy)
   - do not "tier" the suite as a speed hack — a subset that attests is how
     `integrate` lands untested code
   - `attest-green` already skips integrate's *second* run; it does not
     shrink the pre-flight 5 minutes, which is the pain

   Back-dating age-based tests instead of `sleep` is worth ~27s at most;
   do it for determinism under load, not as the answer.

3. **Parent-broker Claude and Codex on ACP — before deleting anything that
   still works.** Reviewer children return a structured body only (`VERDICT:` +
   findings). The parent stamps identity, thread, artifact, round, verdict, and
   delivery (the grok path already). Keep cmux/self-send **working and
   unadvertised** until parity is proven. Headless `exec`/`-p` stays an
   undocumented recovery/test adapter on the same criteria, then go or stay —
   not a product surface.

   This step is not done until all four hold:

   - **Durable coordinator log** (append-only events, not the model mailbox,
     not ACP): request persisted → turn started → provider result persisted →
     reply validated → reply accepted → composition completed. A crash between
     ACP exit and compose recovers from this log.
     **LANDED 2026-08-30** as `.comms/events.tsv` + the `events` verb, after two
     plan rounds and **ten implement rounds** — the longest arc this repo has run,
     and every round after the fifth was the same shape: a guard that existed and
     protected nothing. Plan rounds: codex found the fail-closed boundary was drawn
     on the wrong line and that `write_result` cannot carry the provider's result on
     the ACP path; grok found that `cmd_send` is also how a REPLY lands, so a
     fail-closed append there turns a delivered reply into a failed turn. The last
     three implement rounds, in order: a composition published before the attempt it
     names was re-verified (r9); legacy-ness inferred from an index shape that a
     crashed modern attempt also produces (r10, closed by the durable
     `grades/attempts/<set>` marker); and — found by the author's own adversarial
     pass, not the panel — four assertions covering that marker that all stayed green
     on a tree with the marker staked LAST, i.e. with the defect live again. Closed
     with a double APPROVE. The roster is persisted
     before any leg, every event of an attempt carries a `dispatch` id because a
     set id is deterministic and a retry rebinds it, and a turn whose own trace
     lost an event signs off `log-incomplete` rather than `completed`. Recovery
     walk in PROTOCOL; the design rationale in INTERNALS. Criterion 4 falls out
     of placement: everything from `turn-started` on is written by the detached
     runner, and `await` records a terminal event for a runner that died.
   - **Enforced reviewer permissions** (acceptance criteria, not a follow-up):
     deny repo writes; deny commit/ref/remote/publish; allow read-only
     inspection; tests only if the mode says so; the mount must not share the
     real remotes when practical. `--approve-all` on a linked worktree is not a
     boundary. (Closes the [open security item](#open-security-item-the-mounted-review-turn-is-contained-for-reviewer-behavior-not-yet-for-a-hostile-artifact).)
     **PARTLY LANDED 2026-08-30** (double APPROVE, 6 implement rounds after a 4-round plan cap):
     mounted codex turns run under an isolated `CODEX_HOME` + `INITIAL_AGENT_MODE=read-only`
     kernel sandbox, applied to every owner-spawning acpx invocation and re-pinned+verified
     before each prompt; MEASURED to deny writes, `/tmp`, child network, and the owner
     control-plane socket while leaving reads and the model API. A provider with no verified
     backend (grok on Darwin) is REFUSED (`COMMS_RUNPHASE_ALLOW_UNCONTAINED=1` overrides). A
     reviewed tree carrying `.codex/config.toml` is refused (the confirmed MCP-RCE vector).
     This ENFORCES reviewer BEHAVIOR (model-generated commands); it is NOT yet general
     hostile-artifact containment, so the security item **stays open** for: general
     project-config (composite-review-root cwd change), grok-on-Darwin, toolchain integrity
     pinning, credential-read/redacted-evidence, and the stale-credential and repo-footgun
     follow-ups below.
   - Timeouts and truncations already named as what they are — no derived
     `APPROVE` from a cut-off body.
   - A valid reply always lands in the coordinator log even if the driver
     process dies.

4. **Advertise ACP-only, then delete cmux and self-send.** After step 3 is
   green on live loops: templates, README, `transport` default, `--via cmux`
   gone. Then delete surface picking, bindings, `cmux_tree`, `doctor` /
   `codex-permissions`, and self-send prompt arms. Mailbox-as-model-wire goes
   with them. Coordinator-owned durable records stay.

5. **Modes.** Three, named. **`strict` is the installed `/auto` default**
   (owner, 2026-08-28: every project this is installed on wants that bar). The
   consults argued for `standard` as the default so a challenger cannot hostage
   a round; that is what `standard` is *for*, and it remains an explicit opt-in.
   Today's panel-by-default roster is already closest to `strict`; this step
   adds reciprocal confirmation and disposition, not "turn panels on."

   | Mode | Reviewers | Automatic gate | Unique blockers | Who |
   |---|---|---|---|---|
   | **strict** | full panel | reciprocal confirmation of the *claim*, or a test that fails on the retained artifact | see step 6 — must not APPROVE while one is unresolved | **default** (`/auto`) |
   | **standard** | primary + independent **non-gating** challenger | **primary only** | challenger uniques are recorded and shown, never dropped, never hostage a round | `--standard` |
   | **fast** | one reviewer | that reviewer's blockers | they all gate | `--fast` / `--reviewers` one |

   Skip re-dispatch of a leg that already APPROVEd an **unchanged** artifact.
   `--plan` stays opt-in. `--rounds` stays a wall, not a budget. Anchors are
   display/grouping only: two bullets on the same `path:line` are not
   consensus. (`compose` today clusters on exact shared anchor; that is a
   grouping, not a predicate — do not promote it.)

6. **Strict disposition. Nothing silent.** Automatic gate stays: confirmed
   claim, or reproducible artifact-bound test. Every unique blocker gets an
   explicit disposition before the loop may APPROVE:

   - **confirmed** → gates
   - **disproved / downgraded**, with a written reason → does not gate, still
     archived
   - **unresolved** (no confirmation, no disproof, failed confirmation round)
     → **human escalation**; strict **must not APPROVE**

   `standard` may APPROVE on the primary while challenger uniques ride out as
   recorded, un-dropped findings (advisories / carry-over). That is the mode
   distinction. `strict` is "nothing silently dropped **and** nothing
   auto-obeyed."

7. **Contributor tooling leaves the install. This repo always-worktrees.**
   Strip presence / worktree / integrate / attest / grading from what
   `install.sh` puts on a user machine. `/auto` and `/ask` should not mention
   them.

   **This repo:** every writing session gets a worktree; `main` is
   integration-only; `integrate` CAS serializes landing; presence is a listing
   and **cannot authorize a write**. No "pid or beat inside TTL" halfway
   model — that *is* the unsolved liveness question, and a Claude-only pid
   also fights vendor-neutrality. If always-worktree is refused, **keep** the
   current tombstone/heal machinery and only force-reap the named zombies.
   Do not weaken it. Halfway is how the zombies won. Always-worktree is the
   better of those two: creation is cheap relative to a review turn;
   inference is not.

8. **Reassess the shell. Extract only what is still fighting.** After steps
   3–7, the remaining coordinator job is parse, state/events, panel
   collection, supervision, serialize. If that is still drowning in
   Bash-semantics defects, extract **that** into a small Node artifact behind
   the current CLI. Git, install, and provider launch stay shell. If it is
   not, stop. Do not extract presence, cmux, or self-send — those should
   already be gone. (This is the [maintainability track](#maintainability--implementation-language-track-2026-08-26-user-direction)
   stop-rule, sequenced after the obsolete paths are removed rather than
   instead of removing them.)

9. **Prove it off this repo.** 20–30 `/auto` runs on ordinary product work,
   **strict** mode (the default), sampled human adjudication of unique
   findings. No stronger quality or token claims until that exists.
   Step 1 makes the token claim measurable; step 3 makes the quality claim
   attributable to the coordinator rather than to prompt-mediated mailboxes.

### Explicitly not now

- Grading platform, routing, a judge, dispute lane, test-evidence contract
- More fail-closed presence machinery (heal provenance, suite wrappers
  manufacturing records)
- Another findings-grammar widening (residue was the right fix; remaining 0/0
  holes want parent-brokered structure, not more list shapes)
- Wholesale language rewrite
- Deleting cmux before parent-broker parity
- Making ACP the source of truth
- Treating `--approve-all` on a mount as the permission story
- Running `suite-lanes` or a new shard effort **in parallel with** warm-mount
  (both touch `tests/run.sh`); after warm-mount lands, suite-lanes **is**
  the next commit
- "Tiering" the suite so a subset can attest — that is a fake green, not a
  faster green

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
  timeout idle/salvage fix is CLOSED as of 2026-08-28. 7455927 named a budget-killed ACP
  turn instead of reporting an empty reply, but only when the child had printed NOTHING
  and the turn had already failed — so the expensive case stayed silent: a turn killed at
  its budget that got PARTIAL bytes out. A review opens with its verdict and an empty
  blocking list, so a turn cut off while writing its advisories emits exactly the fragment
  that parses, and the parent stamped an authoritative `verdict: APPROVE` from a reviewer
  that never finished reading the diff, delivered as `completed` with an empty note. The
  overrun is now decided ONCE, before the success/failure fork: the failure path leads with
  the budget (the broker complaint demoted to a parenthetical, since leading with it is
  what sent an operator hunting prompt-format bugs), and the success path carries a
  TRUNCATED warning rather than a refusal — `elapsed >= timeout` is genuinely ambiguous, so
  refusing would sometimes discard a complete, expensive review. The budget is also
  validated as an integer now; `--timeout-secs notanumber` used to leak a bash arithmetic
  error and silently revert to the pre-fix note. The `.comms/config`
  delivery-persistence prerequisite never shipped: the registry accepts only `agents`
  and `default-target`; delivery mode is still COMMS_DELIVERY/--via only.)* cmux stays
  selectable as fallback.
- [x] **Retire fleet.sh after replacement orchestration is ready (step 5)** —
  *retired 2026-08-26 in the `/auto` command collapse (80f472c) rather than via the
  trackerless-mode gate; the gate was consciously waived when `/auto` + panel dispatch
  + `comms.sh status`/`stalled` absorbed the orchestration surface.* Original gate for
  the record: trackerless local mode covering status/dispatch/dispatch-all/
  harvest/concurrency caps/dirty-tree+push safety/stalled recovery.
- [ ] **Delete cmux delivery (step 6)** — *sequenced under [Contraction step 4](#contraction-2026-08-28--current-program):
  parent-broker Claude/Codex on ACP (step 3) first, with cmux kept working and
  unadvertised until parity; then advertise ACP-only and delete.* Original text:
  one release after the default flip with no fallback invocations; deletion
  audit must include every known dispatch consumer; keep optional log/tail
  viewing only if useful. Interop drill before declaring done.

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

## The parser could not say "I could not read this" (2026-08-28)

Closed the class behind the friction log's only severity-5 entry ("compose reported 0
findings — false all-clear over real blocking findings"). The entry as written was fixed by
3f12bd7, which added numbered lists; the CLASS was not, and it fired seven more times after
that commit.

**The structural fault.** `findings_extract` answers "how many findings did I parse?" and
the broker derives a verdict from that number while believing it asked "did the reviewer
find anything?". Those differ exactly when the parser fails, and a `### Blocking` lane whose
content is not a list item extracts zero. Measured over the 123 raw replies in `.comms/logs`:
**seven derived `APPROVE` over a blocking section they had failed to read.** The clearest is a
codex reply whose real finding — *attestation is not bound to the commit actually tested* —
was written as `blocking<TAB>tests/run.sh:4948<TAB>…` and produced
`DERIVED 'APPROVE' from 0 blocking finding(s)`.

**Why widening the grammar again would not have worked.** This was the fourth widening
(column-0 `- `, then numbered, then indented/tabbed, now lead-token and bold-lead). Each one
left the same hole, because the gate kept measuring what it understood instead of what
defeated it. The fix counts the RESIDUE: any non-blank, non-placeholder line in a findings
lane that no rule claimed. The broker then fails closed on it in the shape `unclosed_fence`
already established. `compose` applies the same rule to legs the broker never touched — a
self-authored envelope is validated but never brokered — and the two cases differ on purpose:
a lane with NO parsed findings plus residue, or a body truncated by an unclosed fence, is a
failed read and REFUSES (exit 3, no count printed); a MIXED lane with real findings *and*
residue only warns, because that leg is already REQUEST_CHANGES and refusing would block a
correct change request over an unreadable nit.

Deriving `REQUEST_CHANGES` from residue was considered and rejected — it invents a verdict
the reviewer did not write, which the fence check already refuses to do.

Measured cost before shipping: extraction is byte-identical across all 348 archived messages
(no `finding_id` renumbers, no `findings.tsv` rebuild); the explicit-`APPROVE` cross-check
refuses **zero** historical replies; the derivation gate refuses the seven true positives.
The reviewers were also never actually told the rule — the ACP review prompt asked only for
the subsections — so the prompt now states it.

- [ ] **`panel status` and `compose` disagree about a leg compose refuses.** Status reports
  the envelope verdict (`APPROVE`) for a self-authored reply whose body compose now refuses
  as a failed read. The disagreement predates this work — status reads the stamped verdict,
  compose reads the body — but there are now two more shapes where a driver glancing at
  status sees a clean panel that will not compose. (grok, parser-residue r5.)
- [ ] **A heading-shaped finding at the SAME level or shallower still probes 0/0.**
  `### The attestation is not bound…` under a live `### Blocking` closes the lane before the
  residue rule runs, exactly as `### Process` legitimately does. Depth cannot separate the
  two — only policy can — so this is the same shape as the fenced-findings item below and
  wants the same kind of rule, not a deeper heuristic. (grok, parser-residue r3.)
- [ ] **A live `### Blocking` whose findings sit inside a CLOSED fence still probes 0/0.**
  The fence lexer `next`s those lines before any residue rule sees them, so a heading
  outside with the findings quoted inside — no live list item, no placeholder — is still a
  zero-count consent path. Deliberately NOT fixed with the residue counter: counting every
  fenced line as residue would refuse the legitimate "quote the prior round, then `- None.`"
  shape that clean approvals use. Needs its own item and its own rule. (grok, parser-residue
  r2.)

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
- [x] **`helpers/acp.sh cmd_consult` had the same class of hole — FIXED 2026-08-31.** The
  `/ask --via acp` transport passed NO `--timeout` (a hung acpx blocked forever) and never
  inspected its own output — acpx stdout went straight to the caller, so rc=0 with zero bytes
  returned success silently. Now it pins an acpx `--timeout` (`COMMS_ACP_CONSULT_TIMEOUT_SECS`,
  default 300; a malformed budget falls back rather than taking the turn down, matching the
  runphase rule) and CAPTURES the answer so a rc-0-with-blank-body turn is refused with the
  mailbox fallback instead of handed back as success. The answer is now buffered rather than
  streamed (as the runphase reply is). Covered by the acp.sh consult section: `--timeout` on the
  prompt, warm-ensure and oneshot argv; the malformed-budget default; the leading-zero (`08→8`),
  oversized (`2^64→300`), and 6-vs-7-digit boundary normalizations; the empty-answer refusal; and a
  failing `sessions ensure` surfacing its stdout.

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

### Event-triggered headless entry (2026-09-01, from the Grok Bot comparison) — DEFERRED

Recorded so it is not lost; **do not start it**. It is a new product track, and the
Contraction freeze holds until step 4 has deleted cmux/self-send.

**Where it came from.** A Grok Bot port of this loop was evaluated on 2026-09-01 and
rejected: every bot there shares one vendor, one VM, and one set of credentials, handoffs
are chat messages, and the coordinator would be a model reading chat — i.e. the model's
mailbox as the source of truth, which Contraction explicitly rejects. The one thing the
"ship while you sleep" pattern offers that this tool lacks is the **trigger**: review
starts because something changed (a pushed branch, an opened PR), not because someone
typed `/auto` in a session. That part needs no Grok Bot.

**What already exists.** The mechanics are all shell and none of them need a pane:
`snapshot create --with-base` retains the tree as a git object, `panel dispatch` fans it
out over ACP, `panel status --set` is already the recovery surface for an await that died
with its session, `compose --set` applies the gate, and the events log records what the
coordinator did. A runner that checks out the candidate SHA and runs those verbs in order
is most of the feature.

**What is missing (the actual work).**

1. **An author with no driver.** The request body (Intent, Prior review context, What was
   done this round, Review ask) is written by the implementer today. A trigger has only
   commits and a PR body. The honest v1 derives Intent from the PR body and "what was done"
   from the commit range, and marks the Review ask **ABSENT** rather than inventing one — a
   reviewer with no ask reviews the diff cold, which is a weaker review and must be labelled
   as one, never passed off as the adversarial ask the loop is built around.
2. **Round continuity across invocations.** Round N+1 needs round N's findings, and a
   trigger fires once per push. Thread identity must key on the branch or PR, not on the
   session, and `in-reply-to` binding must survive a fresh runner process.
3. **A sink that is a projection, not a record.** The coordinator's event log stays the
   source of truth; a PR comment or check status is a projection of the composed verdict.
   The trigger reviews. It never merges — landing stays a human or `integrate` decision.
4. **Containment on the runner — the open security item, with more force.** A runner holds
   git credentials and network by construction, and mounted turns are refused without a
   verified isolation backend per provider per OS. Linux may have what Darwin lacks —
   `runphase.sh` already records that grok's child-network blocking is seccomp-enforced on
   Linux and a no-op on macOS — but that is a measurement to make, not an assumption to
   plan on. No credentialed runner runs a panel until it is made.
5. **Cold cost per trigger.** A fresh runner has no warm ACP session, so every leg pays the
   cold price (18,562 vs 146 input tokens, the Tier-1 spike measurement) times the roster,
   once per push. Budget it in writing before enabling on a busy branch.

**Gate to start:** Contraction step 4 done; a verified isolation backend for every roster
provider on the runner's OS; a written per-trigger token budget.
**Success:** a composed panel verdict for a pushed SHA with no interactive session
anywhere, recorded in the events log, and reproducible by re-running the runner on the
same SHA.

**Not this:** a GitHub Action in this repo (contributor tooling is not the installed
product).

**If Grok Bot is ever the trigger surface, this is the shape (sketched 2026-09-01, not
planned).** Grok Bot has no public inbound API: nothing outside can start a bot except a
person's message or a routine fired by a Cursor-integration event (Slack message, GitHub
notification). So the round trip has to ride an external bus, and the honest one is the
forge itself:

- *Trigger:* the person tells the bot "review branch X" from a phone, or a routine fires on
  a PR notification. The bot's only skill posts a structured comment (`/review <sha>`) on
  the PR via `gh`.
- *Runner:* the headless entry above, on a machine the operator controls (the contained
  Darwin path already measured, or a Linux runner once its backend is verified), polls or
  is webhooked for that comment, checks out the SHA, dispatches, composes, and posts the
  composed verdict back as a PR comment. The events log is still the record; the comment
  is a projection.
- *Round trip:* the bot's routine wakes on the notification, reads the verdict, and puts
  it in front of the person with the one question that matters — land, fix, or stop.
  "Land" becomes another comment (`/land <sha>`) that the runner turns into `integrate`.
  Grok Bot never holds repo credentials, never runs a provider, and never merges.

The alternative — the bot's own VM as the runner — puts API keys and git credentials on a
machine every other bot in the account shares, has no verified containment, loses anything
outside `/workspace` on recovery (the mount store lives under `~/.local/state`), pays cold
ACP price every run, and stalls on the weekly cap. Rejected as a first shape.

What the forge-bus shape actually adds over a Slack or GitHub notification on a phone is a
model that can summarise a composed verdict and take "land it" in plain language. That is
thin. Re-evaluate only if xAI ships a public bot-trigger API, native GitHub-event routines,
or a model picker — any of those turns Grok Bot from a chat front-end into a transport.

## Token-efficiency track (2026-08-26, from the headroom consult — codex + grok)

Consulted both reviewers on stealing from headroomlabs-ai/headroom. Consensus: steal the
cache-mode INVARIANT (frozen prefix, byte-identical history, only the live zone changes),
never the product (proxy/ML compressors are the wrong layer for hand-authored markdown,
and lossy rewriting of inter-agent instructions is the `$N`-corruption class). Ranked:

- [x] **Warm ACP sessions are silently COLD on panel legs** (grok, consult): runphase
  mounted `artifact_id` at `$run_dir/tree` and cd'd there, but acpx keys session identity
  on `(agent, cwd, name)` — run_dir is per-message, so every mounted turn was a new cwd
  and a fresh ~115k context while the session NAME looked stable.
  **LANDED 2026-08-28** (thread `warm-acp-mount-32182`, 10 plan rounds, double APPROVE).
  The mount was originally `$root/mounts/<slug>-<hash12>-<agent>/tree` (in-repo), keyed on a
  hash of the
  RAW thread (`safe_name` maps `a/b` and `a_b` onto one token, and under a stable cwd that
  collapse would merge two threads into one warm session), scoped to `--via acp` because
  `shadow` runs a non-ACP grok turn on the same thread concurrently by design.
  **The premise the item was written on was wrong, and the correction is the useful part:**
  warmth is not process reuse. acpx's queue owner is spawned with no `cwd` in its spawn
  options, so it holds an inode, and its idle TTL is 300s — shorter than a panel round.
  Warmth is RECORD resume through the provider's prompt cache, measured on this repo's own
  store at 6,579 fresh input tokens against 201,472 cache reads on a record spanning 15.6
  hours whose agent had been respawned. So the mount is REBUILT every round rather than
  reused: renamed aside (a live cwd holder follows the rename, so its writes land in the
  aside), re-created at an mktemp-unique path whose admin id is therefore generation-unique,
  then `mv` + `worktree repair` back to the stable path. Nothing the child controls is
  dereferenced, written through, or validated — it is moved away and abandoned. The owner
  is retired by a short `--ttl` and observed self-exit, never by a signal: its pid cannot be
  authenticated (the lease records `createdAt`, not a start time), and since it is detached,
  a mistaken signal would hit an unrelated process group.
  Cost accepted: one checkout per (thread, agent) persists per mount, plus one
  aside per round until reaped — as is already true of `.comms/logs`, which nothing prunes.
  (RELOCATED 2026-08-30: these checkouts moved OUT of `.comms/mounts` to an external base —
  see the criterion-2 "INCREMENT 1 LANDED" note below — and `comms.sh clean mounts` now GCs them.)
  Residual, tracked against the enforced-boundary item below and NOT closed here: a survivor
  that re-resolves the stable path after restage is *detected* by a tree-identity check
  before the prompt and again before stamping, not prevented. Full containment needs the
  enforced boundary, and enumerating hostile shapes is the pattern `docs/advisories.md`
  records as repeatedly failing on this track.
  **Second residual, same item, named by codex at implement r12 and NOT closed:** the mount's
  bookkeeping (`.state.record`, `.state.home`) lives beside the mount, so a child with a shell
  can write a fake record id *and* a store that corroborates it; both lease probes then hash
  the fake id and miss the live lease under the real one, and the mount restages under a live
  owner. Everything reachable was closed — a deleted record no longer reads as a first turn, an
  unreadable one degrades, the corroborated store is cross-checked against the runner's own
  `$HOME` — but an identity the child can forge cannot be authenticated by state the child can
  write. Closing it needs bookkeeping outside the child's reach, i.e. the enforced boundary.
  **The landing was made on an explicit human instruction with codex's final verdict at
  REQUEST_CHANGES on this residual**; grok approved. Recorded here rather than in a commit
  message so the next session finds it.
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
- [x] Atomic writes for installed/shared helpers (write temp + `mv`) so concurrent
  readers never see a half-file. *(Shipped 2026-08-27 — `install_file` in `install.sh`;
  all six copy sites go through it.)* The framing in this bullet understated it: the
  hazard is not a reader seeing a half-file at one instant, it is that **bash reads an
  executing script lazily by byte offset**, so a `cp` over a running helper shifts the
  bytes under a reader that is minutes into it and the shell resumes mid-token. The
  field log records three strikes in one day (`.comms/friction.tsv`), the loudest a
  parked `runphase.sh await` dying with `line 1326: l: command not found`. The window is
  as long as an await: `cmd_await`'s default timeout is 7200s. Two details are
  load-bearing and are pinned by test: the temp is a SIBLING of the destination (a
  cross-device `mv` degrades to a copy in place and silently reintroduces the bug), and
  the mode is set on the temp before the rename. Asserted by inode identity, with a
  negative control proving a plain `cp` keeps the inode — otherwise the assertion could
  never fail. **This unblocks installed-copy lag detection below**, which was self-blocked:
  lag detection exists to prompt a mid-run reinstall, and until now that prompt was an
  invitation to crash a peer.
  Four review rounds, closing on a double APPROVE. The last three were entirely about one
  fact: **replacing a file is not the same operation as writing through it**, so every
  incidental property of `cp` had to be reproduced deliberately — mode (including the
  special nibble Darwin's `%Lp` silently drops), owner and group (restoration is REQUIRED;
  a `chown` that cannot be applied refuses the replacement, because publishing under the
  directory's group widens access silently), symlink write-through, and the abort a
  read-only destination used to produce. Two reviewer findings are worth carrying as
  general lessons: an ACL cannot be detected by the `+` mode marker on Darwin, because
  `ls` prints `@` INSTEAD of `+` when extended attributes are present — and they are
  routine — so the probe reads the ACL entries themselves, through `/bin/ls` rather than
  whatever `ls` is on PATH (locally, `eza`). And `chown` clears setuid/setgid even as a
  no-op, so ownership must be applied BEFORE the mode. Two carried advisories, neither
  blocking:
  - [ ] `emit_note` (a capability this machine lacks) prints a visible note and counts
    nothing, but it does not mechanically make the run PARTIAL — `FAIL` stays 0 and
    `attest-green` still records an attestation. Acceptable while platform skips are
    intended, but it sits against the attestation invariant and belongs with the
    suite-coverage-gate work rather than bolted on here. The Linux `+`-marker branch of
    the ACL probe is also unexercised, the fixture being Darwin-only. (codex.)
  - [ ] The ACL probe greps `ls -lde` output for numbered entry lines, so a resolved
    symlink target containing an embedded newline followed by `0:` could match the
    filename. The consequence is a spurious warning on a fixed set of install names, so it
    is recorded rather than defended against. (codex.)
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

### Pid-less records are permanently ambiguous (2026-08-27, observed live)

Found by the `suite-perf` session on its first claim — the first outside use of the
presence system, which is exactly what it was supposed to surface.

`presence_expire`'s reap loop is gated on `[ "$(presence_eval "$f")" = "dead" ]`, and
`presence_eval` can only reach "dead" through a pid check. `--pid` is OPTIONAL at claim
time, and a Claude session has no stable long-lived pid to give it (every Bash call is a
fresh process), so its record carries `"pid": ""` and can never evaluate dead — **not
"stale enough to reap eventually", but unreapable by construction, at any age.** Observed:
a record 111 minutes past a 2700s TTL, still listed as an ambiguous peer.

The design anticipated the case (`--force` is commented "explicit operator path for
forever-ambiguous entries (foreign host, no pid)"), so this is an ERGONOMICS gap, not a
correctness one. What it costs is the feature's whole point: abandoned pid-less records
accumulate, every later claim sees peers, and isolation becomes permanent — deleting the
"no overhead when you are alone" property the claim-then-check design exists to provide.

Candidates, none decided:
- [ ] Say it at the point of pain: when `others` reports a peer that is past TTL AND
  pid-less, print the `expire --force <name>` line. The escape hatch exists and nobody
  knows it does.
- [ ] Make abandonment self-healing for the pid-less case only: the two-pass
  byte-identical observation over a full TTL is itself evidence that nothing is writing
  the record. Weigh against the founding rule that staleness never implies death — a
  SUSPENDED session also stops beating, and reaping it is the failure this design refused
  to risk. If adopted, it must be a distinct, narrower rule, not a loosening of the
  general one.
- [ ] Have long-lived drivers claim under `with-beat` so the record cannot go stale while
  the session lives, making abandonment mean what it looks like.
- [ ] Legacy records predating the instance scheme (`agent-comms-7b`, `-a2`, `-a7`, `-be`)
  have no `instance` field, print malformed (`peer: name-  state=`), and are ambiguous by
  the same rule. Force-clean them once their owners confirm — never unilaterally.

Also observed: a session's harness NAME and its presence NAME are unrelated, so a peer
cannot map a record to a session. The suite-perf session correctly refused to infer which
record was mine and asked. That is the declared-beats-inferred principle earning its keep,
and it is an argument for the role ledger above.

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

**Promoted 2026-08-28 into [Contraction step 2](#contraction-2026-08-28--current-program).**
Owner: five-plus minutes is current pain, not a later cleanup. This subsection
is the measurement and the remaining work; the queue is the contraction
sequence. Sharding is NOT the remaining lever — it was built and measured at
1.07x (item 4). `suite-lanes` lands after warm-mount for its coverage vector and
its watchdog fix, not as a shard precondition.

**PROFILED 2026-08-27 (suite-perf). The original estimate below was REFUTED on
both of its main claims; the measured numbers replace it.** A landing still costs
TWO runs (the pre-flight plus integrate's re-run at the candidate OID), which is
what makes the wall-clock hurt. (`attest-green` can skip the second; it does
not shrink the first.)

*Superseded estimate, kept so the next reader can see what was wrong and why:*
~8–12 min at ~912 assertions; per-assertion `comms.sh` spawns "likely the
dominant term"; ~2 min of deliberate sleeps; per-section `git init` churn.

Measured on an unloaded machine (load ~8), instrumented clone at `3be9044`:

- **Baseline: 504.8s for 932 assertions.** Two independent runs agreed within 1%.
- **Spawns are ~5%, not dominant.** 1,165 helper spawns total (989 `comms.sh`,
  107 `runphase.sh`, 47 `acp.sh`, 22 `install.sh`), and one `comms.sh`
  invocation costs **23.6ms** (bare `bash -c true` baseline: 3.5ms). All
  spawning together is ~28s. Batching assertions per invocation — the fix the
  old item 1 called durable — has a ceiling of about 5% and is NOT worth doing.
- **Deliberate sleeps are ~27s, not ~2 min.** 15 `sleep` sites: 2×6s watchdog
  waits, 2×2s stub waits, ~9s in the presence `with-beat` signal tests. The
  "~2 min" figure came from summing two `sleep 30`s that the tests kill early
  *by design* — killing them early is the assertion.
- **`git init` fixture churn is not a term worth chasing.** A full worktree
  add + read-tree + reset + remove measures 92ms.
- **The cost is CONCENTRATED, not spread.** Ten of 62 sections = 86.6% of
  runtime; the top two = 35.8% on just 77 of 932 assertions. The remaining 52
  sections share 67s between them.

**Root cause of the worst offenders, found and fixed 2026-08-27: a 6-second
sleep-poll in `update_thread_state` (`helpers/runphase.sh`).** The runner waited
`for i in 1 2 3; do [ -f "$sf" ] && break; sleep 2; done` for the thread-state
file that `send` writes just after it spawns the runner. The window is real —
`cmd_send` calls `cmd_deliver` first and only then `state_update_from`, because
the state write consumes the run dir deliver returns, so the ordering is forced.
But the wait was UNCONDITIONAL, so every turn with no `send` behind it — a bare
`comms.sh deliver`, which is a public verb, and every direct `runphase.sh run`
in the suite — paid a flat 6s for a file that was never coming. It was invisible
because the "no thread state file to update" note goes to stderr and every
caller redirects it into a variable or `/dev/null`.

Fix (declared-beats-inferred, applied to a spawn): `cmd_send` exports
`COMMS_RUNPHASE_EXPECT_STATE=1` when it is actually going to write, and the
runner waits only on that declaration. Both sides gate on ONE predicate,
`state_write_expected`, so the writer's rule and the waiter's expectation cannot
drift. The budget is retained and configurable
(`COMMS_RUNPHASE_STATE_WAIT_SECS`, default 6 = prior behaviour) and now polls at
0.1s instead of 2s, so the live race case returns as soon as the file lands
instead of sitting out a fixed tick. **Measured on identical trees: 504.8s →
325.8s (−35%).** The branch as landed measures ~340s, because its 22 new
assertions deliberately spend ~25s exercising the wait budget, the poll
wake-up, and the malformed/overflow fallbacks. Quote the −35% against the fix, not against the branch. This also
removes 6s from every non-`send` spawn in production, not only in tests.

Ranked work, foldable into the step-2 harness split:

1. [x] **Profile before optimizing.** DONE 2026-08-27 — see the numbers above.
   The estimate it was meant to test was wrong in both directions, which is the
   whole argument for the item: implementing on the guess would have bought ~5%
   and left the real 35% in place.
2. [ ] **Tier the suite.** DEPRIORITISED by the profile: the stress probes are
   not where the time is. The presence section — the most obvious "stress"
   candidate — is 34s for 91 assertions, the second-best density in the top ten.
   Re-open only if a specific probe shows up hot in a fresh profile.
3. [x] **Attested-green shortcut for integrate.** DONE 2026-08-27 (double
   APPROVE, integrate-ergonomics r1): `attest-green` records "green at this
   HEAD" bound to the commit the run started on; integrate consumes a fresh
   same-OID record when `suite-attest-secs = N` is configured. Opt-in; the
   paranoid re-run stays the default. Landed alongside self-healing
   never-occupy-main (a clean checkout idling on `main` is fast-forwarded
   through the landing instead of refusing it after a ten-minute suite).
4. [x] **Shard sections in parallel — MEASURED AND REJECTED 2026-08-29.** Built in full
   (dependency closures, lane derivation, a driver with union-minimising packing, a
   merged-vector coverage gate and owned-failure crediting) and measured on a quiet
   machine against the same corpus:
   - **serial 424s -> 4 lanes 397s = 1.07x**, with coverage verified complete.
   - An earlier 1.6x figure was OPTIMISTIC and is withdrawn: it skipped isolating the
     presence lane and was two sections short of full coverage. With both corrected the
     win disappears.
   The blocker is DUPLICATION, not concurrency. Parallelism itself scales near-ideally
   here (two lanes: 285s sequential -> 132s concurrent; a 5-lane wall clock equalled its
   heaviest lane exactly), but a lane must run its dependencies: **98 section-runs for 62
   sections = 1.58x the work**. And the coupling is not removable by hoisting — simulated
   hoisting the shared definitions and the closures did not shrink, because the edges are
   `REPLY`, `DUP_OUT`, `HL_WF`: state produced by other sections' ASSERTIONS, not
   definitions that can move. The presence/signal section also has to run alone (80s and
   0 failures in isolation; 3 signal assertions fail when it shares the machine), which
   adds a serial phase on top.
   Two traps worth keeping: splitting naively by fixture family ran 655 of 1138
   assertions while reporting only 5 failures — silent coverage loss, now caught by the
   per-section vector; and a derived lane script placed outside the repo resolves `REPO`
   from `BASH_SOURCE` to the wrong directory and fails every section for reasons that
   have nothing to do with coupling.
   **Where the time actually was:** profiling instead of parallelising found a `sleep 1`
   in the provider watchdog — a loop whose only job is to notice the child exited, while
   a stub-backed turn exits in milliseconds. Measured at 58s per run, 13% of the suite.
   Polling at 0.1s took 430s -> 364s, beating the entire sharding effort with one line,
   no concurrency and no coverage risk. Two other suspects were measured first and were
   NOT hot (the spawn delay: 12s, already zeroed at 86 of 98 sites; the kill/await
   graces: never fired). The prototype tooling is the right instrument if this is ever
   revisited, but it is not landed.

5. [ ] **Back-date instead of sleep** in the remaining age-based tests (most
   already stamp epochs). Worth ~27s at the absolute most — do it for
   determinism under load, not for speed.
6. [x] **Make silent stalls visible.** DONE 2026-08-28 as the coverage-gate arc
   (48506fe, eight review rounds, double APPROVE). The suite could not tell a
   partial run from a full one — exit status AND attestation were both
   `[ "$FAIL" -eq 0 ]` with no coverage conjunct — so a run of 300 of 954
   assertions was byte-identical to a green one for every consumer, with
   `suite-attest-secs = 1800` live. Now `tests/expected-counts.tsv` is read from
   the COMMITTED BLOB at the tested commit, both the exit status and the mint
   require the full count, skips are named/condition-bound/single-use, the
   dynamic corpus enumerates the git index, and `integrate` scrubs shell-startup
   hooks and demands the suite's own completion line rather than trusting an
   exit code. Seven distinct routes to a green partial run were found by review
   and closed; `integrate` now also keeps the output of runs it rejects.

7. [ ] **`presence with-beat` heals records it does not own** (integrate-advisory-beat
   r1-r4, 2026-08-28). `with-beat`'s beater calls `presence beat`, which HEALS a vanished
   record by design — so a record unlinked mid-run is recreated **pid-less**, and a
   pid-less record can never be classified dead, so `presence expire` can never reap it.
   `integrate` used to trigger this on every run under a foreign identity — at its two
   explicit beats AND, fifteen minutes in, via the `with-beat` wrapper around the suite,
   which no short fixture could observe. All three are fixed by checking before beating
   (never manufacture a record you do not own). The residual
   case — a record that vanishes DURING a long child — is not fixed and is deliberately
   not claimed by `integrate`: three review rounds establishing ownership across signals,
   nested arms and repositories produced a cross-repo identity collision, a shared
   healmark race, and a non-atomic ownership handoff, each found by review. The fix
   belongs in presence, not in its callers. Candidates: `with-beat` refuses to heal and
   reports instead; or records carry their creator so a healed one is distinguishable.

8. [ ] **A suite with no presence identity runs unsupervised** (codex,
   integrate-advisory-beat r7, advisory, pre-existing). When `COMMS_PRESENCE_NAME`/
   `INSTANCE` are unset, `integrate` runs the suite without `with-beat`, so the
   detached-descendant escape it now closes for the absent-record case remains open on
   that supported path. `--no-heartbeat` makes the fix available without a record; it
   needs a synthetic identity or a supervision-only verb.

9. [ ] **Remaining defence-in-depth on the suite proof** (codex, coverage-gate r8,
   advisory, explicitly NON-blocking). A `BASH_ENV` hook defining `command()` can
   still forge the completion line. This sits outside the stated boundary — such a
   hook already runs code as the user and could move refs directly — so it was not
   fixed before landing. Cheap option if ever wanted: a subshell that sets
   `POSIXLY_CORRECT=1`, unsets a `command` function, then invokes
   `command /usr/bin/env`. Strictly stronger, still not containment.

10. [ ] **Make silent stalls visible.** This defect survived because a
   six-second wait announced itself only on stderr, into `/dev/null`. Consider
   whether the runner should record waits it actually served somewhere a human
   or the suite reads. A stall nobody can see is the shape of the next one.

### The attempts marker: a shape a crash also produces (2026-08-30, LANDED)

`set_index_has_attempts` decided "was this set dispatched under the attempts scheme?" by
scanning `sets.tsv` for a leg row with a non-empty `dispatch` column. A modern dispatch that
dies after its plan events and before its first index row, whose `events.tsv` is later lost,
leaves an index holding only the PREVIOUS round's legacy-shaped rows — indistinguishable from
a genuinely pre-attempts set. Every reader then called it legacy, composed those old bound
replies, and silently discarded the newer attempt. Fixed by staking an empty
`grades/attempts/<review_set_id>` marker BEFORE the plan events, the legs and the index rows;
the marker, not the shape of the rows, now settles legacy-ness. Implementing it exposed a
third reader — `set_current_dispatch` — carrying its own inline copy of the rule.
Panel: codex APPROVE, grok APPROVE, 0 blocking.

**The part worth carrying:** the first four assertions written for this marker were all green
on a tree with the marker staked LAST — i.e. with the defect fully live. Every one of them
built its crash BY HAND, after a dispatch that ran to completion, so none of them observed the
one thing that is the mechanism: WHEN the marker is written. The author's own adversarial pass
caught it, not the panel. A fixture that constructs the post-crash state is not a test of the
code that survives the crash.

**Follow-ups the panel filed, in priority order:**

1. **The order fixture still does not fully pin the order.** (codex, advisory.) It kills the
   dispatch at its FIRST LEG, which is after every `panel-planned` append — so moving marker
   creation below the plan loop but above the leg loop still passes, and a crash *during* that
   multi-row plan loop would again leave an attempt trace with no marker. Production ordering is
   correct; the coverage is one notch looser than the invariant. Pinning it needs a death
   BETWEEN two plan rows, which needs a hook in `cmd_events append`.
2. **Marker loss is fail-open, by construction.** (codex + grok, corroborated.) A missing or
   unreadable marker falls through to index-shape inference, so losing only the marker while
   keeping stale legacy rows recreates the false-legacy composition. Nothing in the repo removes
   markers, so this needs out-of-band corruption — but any tooling that copies, prunes, restores
   or relocates `grades/sets.tsv` must do the same to `grades/attempts/`. Documented in PROTOCOL;
   nothing enforces it. Same shape as follow-up 3 of the section-accounting item: an invariant
   established by documentation and left unenforced.
3. **The two reader-side `case 3)` arms are unreachable and uncovered.** Both callers hit
   `set_current_dispatch` first, which refuses for the same condition; the arms only cover a
   concurrent dispatch landing between the caller's two reads. Deliberately kept — deleting a
   race guard because the suite cannot force two reads to disagree is worse than landing it
   uncovered — but a future reader will see dead code. Covering it needs a shim of the same class
   as the r4 `log-incomplete` one.
4. **There is no `panel forget`.** A set whose marker survives and whose log is legitimately
   pruned is UNKNOWN forever; the only un-wedge is `rm .comms/grades/attempts/<id>`, which trades
   a loud refusal for the silent misread. A first-class recovery verb would not have to.

### Section accounting: the vector's own bypass (2026-08-29, LANDED 03ee675)

A section landed using the OLD banner form — a bare `echo "== ... =="` — instead of
`section "..."`. The banner prints identically in the output, but `section()` is the only
caller of `_flush_section`, so that section emitted **no row of its own** and its 47
assertions were credited to the **previous** section (44 + 47 became one row of 91). The
total gate is blind to this by construction: the corpus did not shrink.

The root cause is not the stray banner. Converting the 62 banners **established** the
invariant and nothing **enforced** it, so the next section to land was free to bypass it.
Fixed by an assertion that fails on any raw banner, excluding `section()`'s own emitter.
Panel: codex APPROVE, grok APPROVE, 0 blocking. The landing consumed the attestation
(625s old, 1800s window) and skipped integrate's re-run — a landing at one run, not two.

**Follow-ups the panel filed, in priority order:**

1. **Unify the two derivations — but not before an independent check exists.** The golden is
   regenerated from run OUTPUT; the gate builds its vector from `section()` CALLS. Those agree
   only by convention, and a raw banner is exactly the input on which they disagreed. Writing
   `$SECTION_VECTOR` to a caller-supplied path would let the golden come from the same code path
   that checks it (`$WORK` is `rm -rf`'d at exit, which is the only reason it is output-derived).
   **codex's caveat is the load-bearing part: do NOT unify until an independent banner-versus-vector
   check is preserved** — otherwise the bypasses in (2) become invisible, because the only two
   things that could have disagreed have been made the same thing. The emit is write-only and
   cannot weaken the verdict; the golden stays the committed blob at `TESTED_OID`.
2. **The guard's exclusion has a hole of its own.** `-vF 'echo "== $1 =="'` also hides a SECOND
   copy of that exact body — say a `banner()` helper — which would never flush. Tighter
   formulation: assert EXACTLY ONE `^[[:space:]]*echo "== .* =="` in the file, which drops the
   exclusion and fails on a duplicate. Neither form sees `printf '%s\n' "== ... =="`,
   `echo '== ... =='`, `echo -e`, or `echo "$banner"` built elsewhere. (`section` called through a
   variable is the harmless direction — it still flushes, and only evades the uniqueness `sed`.)
3. **Same class, still unenforced:** an `ok`/`fail`/`skip` BEFORE the first `section()` or AFTER
   the final `_flush_section` increments the total and not the vector, so bumping
   `expected-counts.tsv` alone leaves both gates green with an unattributed assertion. Today the
   layout happens to prevent it; nothing pins it. Cheap pin: the vector's covered sum equals
   `PASS+FAIL+SKIP`, excluding the probe subshells that re-point `SECTION_VECTOR`.
4. **Widen the greps when a lane split adds files.** Both the uniqueness check and the banner
   guard read only `tests/run.sh`.

**The lesson worth carrying beyond this item:** this is the second time in this arc that an
invariant was established by a one-time edit and left unenforced — the coverage total was the
first. Ask it of every such edit: *what makes the NEXT change obey this?* If the answer is
"the author will notice", it is not enforced. The reviewers found both; reading did not.

### Hot waits: five fixed sleeps that were sized for the slow case (2026-08-30, LANDED f8c8866)

Matched A/B, same corpus, back to back: **672s -> 563s (-109s, 1.19x)**, with the optimized run
carrying HIGHER observed load than the baseline (10.7 vs 6.2 at start). Read that as a
conservative INDICATION, not proof of a floor: load average does not identify the competing
workload, CPU versus I/O pressure, or its timing within the run. What is defensible is the
plain statement — the optimized run reached 563s despite higher observed load.
(codex, runtime-figures r1, advisory.)
Suite: 1395 assertions, 0 failures.

- **`gs_files` spawned one `shasum` PLUS one `cut` per file** inside a `while read` loop, from
  ten call sites: 409ms -> 22ms per call. `find -exec shasum {} +`, not `xargs` — with no input
  `xargs` runs `shasum` with no arguments and leaves it reading stdin, hanging the suite.
- **`run_rp` paid a literal 1s spawn delay** at 15 sites for stub-backed turns that exit in
  milliseconds. ~80 other spawn sites were already zeroed; this helper was missed.
- **Three `runphase.sh` flat sleeps became polls** — the await loop (on every spawned turn's
  path), the runner-death grace, and `kill_codex`'s TERM->KILL grace. Same budgets; they can
  only return sooner.
- **cmux keystroke pacing and tree backoff are real-terminal concerns a STUB cannot have.**
  Both are now overridable with defaults unchanged, scrubbed then set to 0 by the harness.

**The review found three defects, every one in the ~20 lines of VALIDATION added beside the
optimizations, none in the optimizations themselves.** In order: (1) the override validated
CHARACTERS not TOKENS, so `1..2` reached `sleep` as an invalid operand and a whitespace-only
value expanded to NO tokens and silently deleted the retry schedule — fail-open exactly where
the delay is load-bearing; (2) the replacement split with an unquoted `for t in $1`, so
PATHNAME EXPANSION ran before validation and `COMMS_CMUX_BACKOFF='*'` in a directory holding a
file named `0.1` globbed into a valid-looking schedule — a validator steerable by the caller's
cwd; (3) the regression written to prove (2) was NOT discriminating, because a bare `*` in a
populated fixture also expands to non-decimal names and trips the fallback regardless, so it
would have passed against the very bug it existed to catch. **If you add a guard beside a
change, review the guard harder than the change.**

### The sharding rejection, adversarially re-audited (2026-08-30)

Item 4's verdict was re-attacked by four independent lenses (critical path, edge breaking,
partition quality, alternative levers), each trying to OVERTURN it. Three claimed sharding was
rescuable; **none survived adversarial check.** The verdict STANDS, and the audit added two
reasons stronger than the recorded one:

- **Sharding never mints an attestation**, so `integrate` still pays the full serial run. It
  cannot speed the LANDING gate, which is the actual pain.
- The best measured 4-lane run (1.96x) carried **3 failures and 3 coverage holes**, and bought
  its speed by having the driver read `section-counts.tsv` from the WORKING TREE — reopening
  the hole the gate deliberately closed.

**Treat the audit's supporting details as unverified.** Its claim that the `REPLY` / `DUP_OUT` /
`HL_WF` edges "do not exist at HEAD" is FALSE — they occur 30 / 4 / 9 times. Its claim that the
1.58x duplication tax was an analyser artifact (34 of 86 edges pointing forward) is plausible
and unverified. The conclusion is corroborated; the arithmetic behind it is not. Re-derive
before acting on any of it.

### Review loop blocked for grok on Darwin (2026-08-30, filed as friction sev 4)

Since 21cb780 / c913006, mounted review turns require a per-provider isolation backend and
there is none verified for grok on Darwin, so every grok leg is refused in ~4s. `compose`
requires ALL legs, so the two-reviewer loop cannot complete on this machine at all — repo-wide,
not branch-specific. grok answered panels normally on 2026-08-29. The only bypass is
`COMMS_RUNPHASE_ALLOW_UNCONTAINED=1`, whose own warning states such a turn can write outside
the mount and reach the network with git credentials; that is an operator decision, not a
session's. f8c8866 landed on the gating reviewer alone, by explicit operator choice, with grok
recorded as MECHANICALLY UNAVAILABLE rather than silent.

## Priorities (2026-08-20, user-confirmed order)

**Superseded 2026-08-28** by [Contraction (2026-08-28)](#contraction-2026-08-28--current-program).
Kept as the record of what that order actually delivered. Do not take this list as
the queue.

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

## Open security item: the mounted review turn is contained for reviewer behavior, not yet for a hostile artifact

### Claude containment MEASURED on Darwin (2026-08-31) — write-contained, network NOT contained

> **INVALIDATED IN PART, 2026-09-01 — read this before the table below.** The probes in this
> section were run under `--approve-all`, which is what a mounted turn used at the time, and they
> only ever proved containment **while the session stayed in `plan`**. They never tested asking to
> LEAVE it. grok found the hole by reading acpx's option resolution: `--approve-all` picks an
> `allow_once` option before any reject, claude's `ExitPlanMode` offers exactly that, the adapter
> then calls `setPermissionMode("default")`, and the next write is auto-approved. Re-measured and
> CONFIRMED by ground truth: `EXITPLAN: ALLOWED`, `WRITE_AFTER_EXIT: SUCCEEDED`, file on disk.
>
> **What closed it:** a mounted claude turn now runs `--approve-reads --non-interactive-permissions
> deny`, NOT `--approve-all`. A FORCED `ExitPlanMode` call is then rejected by the client
> ("User rejected request to exit plan mode", `PERMISSION_DENIED`, rc 5) while `git log` and reads
> still work. The forcing matters: an earlier attempt showed the MODEL declining, which is
> politeness, not enforcement. `--permission-policy '{"autoDeny":["ExitPlanMode"]}'` was tried
> first and did NOT hold — the escape still succeeded.
>
> Note (grok): if a turn's only client-visible permission request is a denied `ExitPlanMode`,
> acpx exits 5 (`requested > 0 && approved === 0`), discarding an otherwise complete reply. That
> is fail-closed, and it is not a reason to hand out `allow_once` again.
>
> The table below remains accurate for IN-PLAN tool use, which is what it measured.


Run before writing any `claude)` arm, using the protocol that earned codex its arm. Versions:
acpx 0.13.1, `@agentclientprotocol/claude-agent-acp@^0.60.0`, `@agentclientprotocol/codex-acp@^1.1.5`,
macOS (Darwin), scratch git fixture, `--approve-all`.

**The mode names are NOT codex's, and that is why this looked impossible at first.** `set-mode read-only`
returns `Internal error` for claude, which reads exactly like "modes are unimplemented" — it is not.
The claude adapter implements Claude Code's own ids: `plan`, `default`, `acceptEdits`,
`bypassPermissions` all return `mode set: <id>`. `plan` is the read-only analogue, and it yields the
same EXACT-stdout confirmation (`mode set: plan`) that the codex arm's verified re-pin depends on.
A future session that tries codex's id, sees `Internal error`, and concludes claude cannot be contained
would be wrong — check the provider's own vocabulary before declaring a backend absent.

| control | codex backend | claude `plan` |
|---|---|---|
| workspace write | denied by OS | denied by harness ✓ |
| `/tmp` write | denied by OS | denied by harness ✓ |
| write via bash evasion (`>` redirect, `python open('w')`, `tee`, `sed -i`, `curl -o`) | denied | **5/5 denied** ✓ |
| reads, `git log` | allowed | allowed ✓ |
| child network | dead | **ALLOWED (HTTP 200 to example.com)** ✗ |
| credential isolation | isolated `CODEX_HOME` + copied `auth.json` | **not possible** ✗ |
| mode pin, verifiable | `mode set: read-only` | `mode set: plan` ✓ |

Every write result is GROUND-TRUTHED against the filesystem, not taken from the model's own report —
which matters, because the first probe answered "write not attempted", i.e. indistinguishable from
politeness. Re-run forcing Bash, then forcing five evasion shapes: the harness refused all of them and
no file ever appeared.

**Two residuals that codex does not have, and they compound.** (1) Network is open. (2) Claude Code
keeps its credentials in the **macOS Keychain** (`security find-generic-password -s "Claude Code-credentials"`),
not in a config file, so `CLAUDE_CONFIG_DIR` isolates settings but NOT credentials — there is no
`auth.json` analogue to stage, scope, or withhold, and the keychain is ambient to the user session.
An open network plus an unscopable credential is exactly the exfiltration shape this track exists to
close, so **claude `plan` does not meet the codex bar**.

Enforcement is also in-process tool policy, not a kernel sandbox. It held against every evasion tried,
but a classifier is a different class of guarantee than `EPERM`, and the honest statement for claude is
defence in depth, not containment.

**DECIDED AND SHIPPED 2026-09-01 (owner):** the write-contained-only arm. `claude)` now pins
`plan` through the same verified re-pin codex uses — the mode id became DATA (`acp_iso_mode`)
rather than a hardcoded `read-only`, which is what lets ONE exact-confirmation mechanism serve
both providers' vocabularies. `set-mode read-only` returning `Internal error` for claude reads
exactly like "modes are unimplemented"; it is not, and that misreading is what made this look
impossible at first. The `.mcp.json` / `.claude/settings.json` / `.claude/settings.local.json`
refusal shipped in the SAME commit, because enabling a provider without it would have opened the
confirmed provider-config vector for precisely the provider being enabled. The arm sets NO
`CLAUDE_CONFIG_DIR`: measured, that isolates settings only and breaks the turn outright
("Authentication required"), and the credential it would supposedly protect is not there to
protect — it is in the Keychain.

**The item stays OPEN, and the reason is now narrower.** claude is contained against reviewer
BEHAVIOUR (writes, ground-truthed against five bash evasion shapes), NOT against a hostile
artifact's reach: the child's network is open and its credential is unscopable. grok on Darwin
still has no backend at all. A shipped `claude)` arm is not this item closing.


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

- ~~`acpx --permission-policy <json>` … denying writes and non-git execs while still allowing
  the read-only terminal commands a review genuinely needs.~~ **STRUCK 2026-08-30: measured
  false.** Policy rules match exact whole tokens (kind / title / toolName / title-head) or `*`;
  **argv is never a token**, so no policy can separate `git log` from `git push`. Worse, a
  provider that self-authorises never issues a permission request at all, so the client has
  nothing to deny — five parent-side controls were measured to be no-ops against codex. Do not
  implement this; it is the lever that looks like a fix and is not one.
- **LANDED 2026-08-30 for codex:** the provider's OWN kernel sandbox, selected by the parent —
  an isolated `CODEX_HOME` plus `INITIAL_AGENT_MODE=read-only`, applied to every acpx invocation
  that can spawn or reuse a queue owner, with the mode re-pinned and verified before each prompt.
  Verified live through `panel dispatch`: workspace and `/tmp` writes refused by the OS, child
  network dead, reads and `git log` alive. A provider with no verified backend on this OS is
  REFUSED (`COMMS_RUNPHASE_ALLOW_UNCONTAINED=1` to override deliberately).
- A parent-authored `sandbox-exec` profile was considered and rejected: Seatbelt is inherited by
  the whole tree, has no hostname rules ("host must be * or localhost"), and `(allow default)`
  leaves Mach/AppleEvents/socket deputies — so it cannot express "deny GitHub, allow the model
  API". The providers already make that split natively.
- Running the mount from a repository with no remotes and a detached object store, so a
  publish has nowhere to go even if a write escapes.

**Partly landed 2026-08-30 (see the codex bullet above and the LANDED section below).** For
codex the boundary is now enforced AGAINST MODEL-GENERATED SHELL COMMANDS (and the confirmed
`mcp_servers` artifact vector is refused); it is NOT general hostile-artifact containment, and
for grok on Darwin there is no backend at all — so the item stays OPEN. Until grok is contained (or refused everywhere it can mount), the honest statement for the
UNCONTAINED providers is the one in the code comment and in acceptance criterion 9: defence in
depth, tested by invariant, not a containment guarantee.

### What a four-round plan arc measured (2026-08-30, thread `reviewer-boundary-71ce143`)

**No code changed. The plan hit its 4-round cap with both reviewers at REQUEST_CHANGES, and the
decision it surfaced belongs to the maintainer.** Recorded here so the next agent does not spend
four rounds rediscovering it. Versions: `acpx@0.13.1`, `@agentclientprotocol/codex-acp` resolved
**1.6.2** (acpx names `^1.1.5` — the boundary runs on floating ranges), grok CLI 1.0.13.

**1. The first lever this section proposes does not work.** `--permission-policy` matches on exact
whole-token equality against `{inferred kind, raw kind, title, toolName, title-head}` or `*`
(`findPolicyRule`/`permissionMatchTokens`). **argv is never a token**, so no policy can "deny
writes and non-git execs while allowing the read-only terminal commands a review needs". Both
reviewers confirmed independently. *That bullet above is false and should be struck when this
item is next touched.*

**2. Five parent-side controls were measured to be no-ops against codex**, because
`~/.codex/config.toml` — installed by **our own `codex-permissions` recipe**
(`helpers/comms.sh:155`, `default_permissions = "workspace-cmux"` extending `:workspace`) — makes
the agent self-authorise, so no `session/requestPermission` is ever issued and there is nothing
for the client to deny: permission policy, `--no-terminal`, `--deny-all`, `acpx set-mode
read-only`, and an isolated `CODEX_HOME` carrying `sandbox_mode`. The ACP layer can only deny what
the agent chooses to ask about.

**3. There IS a working per-provider backend for codex.** Isolated `CODEX_HOME` **plus
`INITIAL_AGENT_MODE=read-only`** (the adapter reads that env var, not `sandbox_mode`, and defaults
to `AgentMode.Agent`) gives, measured on Darwin:

| probe | result |
|---|---|
| write in the workspace | `operation not permitted` (OS refusal), file absent |
| write to `/tmp` | `operation not permitted`, file absent |
| `cat`, `git log` | exit 0 — reads and history work |
| `curl https://api.github.com/` | exit 6, `Could not resolve host` — child network denied |
| the turn itself | completed — the model API still works |

**4. The same is NOT true of grok on macOS, and that is the blocker.** Per the vendor's own
installed docs (`~/.grok/docs/user-guide/18-sandbox.md`): *"Child-network blocking is enforced on
Linux only (via seccomp). On macOS it is a no-op."* `read-only` also write-allows `/tmp`. So a grok
reviewer on Darwin can clone to `/tmp` and push with the inherited `osxkeychain` / `gh` helpers —
and the mount carries a live `origin` push URL (verified: `git -C <mount> remote -v`).

**The decision this forces:** on macOS the default two-reviewer panel cannot have both legs
contained. Either mounted grok turns are refused on Darwin — which costs the cross-vendor
corroboration that is this repo's whole gate — or the security item stays open with a named
product hole. That is a product call, not an implementation detail.

**Design work the panel named — status after the isolation implement arc (2026-08-30):**

LANDED and verified by reproducible probe — enforced against MODEL-GENERATED SHELL COMMANDS
(the reviewer's own actions), NOT against a hostile artifact's own provider config (see the
CONFIRMED MCP hole under STILL OPEN). What is verified:
- Isolation wraps every invocation that can spawn or reuse a queue owner (`sessions ensure`,
  `set-mode`, and the prompt send — acpx spawns the owner on the *send*). ✓
- The mode is re-pinned to `read-only` and CONFIRMED (rc 0 + exact stdout `mode set: read-only`,
  stderr excluded) before every prompt; an unconfirmed pin refuses the turn. ✓
- The owner control-plane socket is unreachable from inside a turn: a child's unix-socket
  `connect` returns `Operation not permitted` under the read-only sandbox, so it cannot reach
  the owner to raise its own mode to `AgentFullAccess`. ✓ (measured, not a hermetic suite test —
  see the probe note on why)
- Ancestor/project `.codex` config **values** cannot widen the sandbox: a hostile `sandbox_mode
  = "danger-full-access"` planted at repo root and cwd did NOT override the isolated home's
  read-only mode — a subsequent shell write was still denied. ✓ (This is only the config-VALUE
  path. The config-EXECUTION path via `mcp_servers` is handled separately and is now CLOSED by
  refusal — see the CLOSED bullet below.)

STILL OPEN (why the item is not closed):
- **A hostile artifact's `.codex/config.toml` `mcp_servers` — CONFIRMED, now CLOSED by refusal.**
  A mounted codex turn whose reviewed tree carries `.codex/config.toml` AT ALL is now REFUSED
  before spawn (parallel to the existing `.acpxrc.json` refusal): codex reads that file from the
  cwd, and an MCP server declared there runs provider-side, outside the command sandbox. The
  refusal does NOT parse the file — content-matching is bypassable because TOML permits quoted
  and space-padded keys (`["mcp_servers"]`, `[ mcp_servers.x ]`) that a grep misses (both
  reviewers found this), so any such file is refused outright. This closes the confirmed RCE
  vector. It is still a DENYLIST, not a general project-config boundary: the complete fix remains
  the composite-review-root cwd change (run from a clean cwd so the artifact's `.codex` is never
  the cwd codex reads). Hooks are separately trust-gated by codex and did not run untrusted.
  This is the one the mount's own purpose — reviewing possibly-hostile artifacts — makes matter. The enforced boundary above covers MODEL-GENERATED
  SHELL COMMANDS (the reviewer's own actions, including a prompt-injected reviewer). It does NOT
  cover the provider's own config: the codex provider process must keep model-network access, so
  it runs outside the command sandbox, and codex loads `mcp_servers` from the **cwd's**
  `.codex/config.toml` — which, for a mounted turn, is the artifact. **Measured:** a project
  `.codex/config.toml` declaring an MCP server whose command writes `/tmp/marker` produced the
  marker (a write the sandboxed shell is denied); removing the project `.codex` removed the
  marker (control); the same config one directory ABOVE cwd was NOT loaded (codex reads cwd's
  `.codex`, not ancestors'). Hooks are trust-gated (`--dangerously-bypass-hook-trust` implies
  persisted trust is required) and did not run, but MCP is not. **This specific vector is now
  CLOSED** (the codex backend refuses any mounted tree carrying `.codex/config.toml`); the codex
  backend is "enforced against model-generated commands" AND refuses this artifact-config file,
  but is still NOT general hostile-artifact containment. The general fix (so an artifact could
  legitimately carry a benign `.codex/config.toml` and still be reviewed) is the composite
  review-root cwd change: run from a clean cwd with the artifact as a subdir, since codex reads
  only the cwd's `.codex` — a load-bearing change grok flagged as needing its own careful landing.

  **REJECTED as a cwd-move (2026-08-30, plan panel, both REQUEST_CHANGES, measured).** Moving the
  turn's cwd to `$mount_kdir` does NOT close the vector — it makes it worse, because the mount
  lives UNDER the live repo (`.comms/mounts/<ident>/`):
  - `git rev-parse --show-toplevel` from `$mount_kdir` returns the LIVE checkout, not the
    artifact (measured: container→live repo, `tree/`→artifact). A bare `git log`/`diff` from the
    reviewer would then read whatever the developer is sitting on — the exact escape the mount
    exists to prevent. The prompt is not a cage; a `git -C tree` shim-injection would be required.
  - Codex's `repo` config layer is `$(git rev-parse --show-toplevel)/.codex/config.toml`, which
    from `$mount_kdir` is the LIVE checkout — so a developer-local `.codex/config.toml` becomes
    the MCP vector instead of the artifact's. (grok, plan r1, blocking.)
  - The session-corroboration guard compares the acpx record cwd to `$mount_kdir/tree`; a cwd move
    makes every existing durable record mismatch → permanent degrade, not "one-time warmth loss."
    A real mount migration would be required. (grok, plan r1, blocking.)

  **Why the landed denylist is the correct resting point:** `tree/` IS a git worktree, and that
  boundary is exactly what bounds codex's config discovery to `tree/` — so refusing `tree/.codex`
  is complete for the cwd. Moving cwd off the worktree is what breaks the bound. The general fix
  (an artifact carrying a BENIGN `.codex/config.toml` and still being reviewable) is not a cwd
  move at all; it requires **relocating the mount OUTSIDE the live repo tree** (e.g. a detached
  location with its own object store), so no ancestor is the live checkout. That touches snapshot,
  mount build, and verification — a separate, larger arc, and the maintainer's call to prioritize
  against advertising ACP-only (step 4). Until then the denylist stands and criterion 2 rests
  where it is: reviewer BEHAVIOR enforced, the confirmed artifact-config vector refused, the
  security item open.

  **INCREMENT 1 LANDED (2026-08-30, mount-relocation panel, double APPROVE): mounts now live
  OUTSIDE the repo.** The relocation the paragraph above called for is the first of three reviewed
  increments, and it is done. Mounts move from `$root/mounts/<ident>/tree` to a validated external
  base — `${XDG_STATE_HOME:-$HOME/.local/state}/agent-comms/mounts` by default, `COMMS_MOUNT_BASE`
  to override (the suite points it at a throwaway) — laid out
  `<base>/<repo-key>/<ident>/{ view/tree, home/, .state.* }`, where repo-key is the full sha256 of
  the CANONICAL (`pwd -P`) repo root and each key dir records that root in `.root` (a differing
  stored root is refused, never adopted or deleted). The base accessor validates every dir it
  creates (mode 700, uid-owned, `pwd -P` identity, not a symlink) and every existing ancestor it
  did not create (a symlink or world-writable-non-sticky component is refused below `$HOME`; a
  sticky world-writable ancestor like `/tmp` is allowed for an override outside `$HOME`), refuses a
  base under the repo, and NEVER falls back to an in-repo path. Legacy in-repo mounts are
  QUARANTINED — never selected, `mkdir`'d, corroborated, used as cwd, or deleted; the `.comms`-ignore
  / `$root/mounts` durable gate is gone. Every degrade path (missing/unreadable/malformed record,
  corroboration mismatch, unprovable owner, the non-ACP else-branch) now lands on an EXTERNAL
  THROWAWAY (`<base>/<repo-key>/tmp-<run-id>/`) that `unmount_artifact` removes whole, so isolated
  `auth.json` copies no longer accumulate. The GIT_* environment is scrubbed through a single
  `acp_exec` ACP-launch wrapper used by every acpx invocation. A new `comms.sh clean mounts`
  (delegating to `runphase.sh clean-mounts`) GCs this repo's store: dry-run by default, `--yes` to
  act, scoped to `<base>/<repo-key>` after a `pwd -P` identity + `.root` match, refusing the whole
  repo-key if any owner claim is live or unprovable, with a REPORT-ONLY `--orphans` scan for moved
  checkouts (never auto-deletes — a stored root may be a temporarily unmounted volume).
  **What increment 1 does NOT do:** the turn's cwd stays `view/tree` and the `.codex` denylist
  stays, so it closes NO general project-config vector by itself. The no-git-ancestor probe on the
  container is computed and LOGGED but does NOT gate the turn yet. Increment 2 will move the cwd up
  to the container behind a runtime no-git-ancestor assert (now that the container is external, its
  git ancestry is no longer the live repo); increment 3 will live-probe the config layer from the
  external cwd and then drop the denylist. **Criterion 2 stays OPEN until increment 3** — do not
  describe increment 1 as closing it.

  **Round-2 GC/claim hardening (impl panel, codex 3 + grok 1 blocking, all addressed).** The first
  implementation had real GC-safety holes the panel caught: `clean mounts` classified an ident as
  gone then deleted it without holding any exclusion (a runner could claim in the gap); the
  throwaway ident was never claimed, so a LIVE throwaway (non-ACP grok, or an ACP degrade after the
  ~20s ttl owner exits) read as dead and `--yes` would `rm -rf` it mid-turn; the claim check
  `continue`d past unreadable/pid-less claims instead of treating them as live; and `mount_alloc`
  adopted an attacker-planted repo-key dir on a shared sticky base (`chmod` failure ignored, no
  owner/mode check before writing `.root`). Fixed: `mount_use_throwaway` claims the throwaway like a
  durable ident (fail-closed); `mount_ident_live` treats any non-released claim it cannot fully
  read+parse as live; `mount_alloc` requires the repo-key dir uid-owned + mode 700 with a
  fail-closed `chmod` before `.root`; and `clean mounts --yes` HOLDS a claim on every candidate
  across the owner re-check AND the delete (refusing the whole repo-key if any claim fails), never
  following a symlinked `view/tree`. The `acp_exec` scrub was extended to `GIT_INDEX_FILE` /
  `GIT_OBJECT_DIRECTORY` / `GIT_ALTERNATE_OBJECT_DIRECTORIES`, and the cwd gate now fails closed on
  an unresolvable cwd.

  **Known limits (accepted, documented).** (1) Two legitimate setups fail closed and need
  `COMMS_MOUNT_BASE` pointed at a physical path outside the repo: a checkout whose `pwd -P` is
  literally `$HOME` (the default base would then sit under the snapshot), and a symlinked `~/.local`
  (or any user-controlled tail component below `$HOME`) — the accessor refuses a symlinked tail
  below `$HOME` by design. (2) `clean mounts` refuses the WHOLE repo-key when any one ident is live
  or its ownership is unprovable, and a recycled claim pid reads as live, so a single permanently
  ambiguous ident can wedge GC of unrelated stale idents. This is fail-SAFE (it never deletes a live
  mount, only declines to delete), and per-ident retained claims would relax it later if needed.

  **Advisory follow-ups (impl r2 double-APPROVE, non-blocking — carry into increment 2's rework
  of this code).** (a) `clean mounts` and `unmount_artifact` never-follow a symlinked `view/tree`,
  but `[ -d "$d/view/tree" ]` still resolves THROUGH a symlinked `view/` PARENT, so a leftover
  `view -> <other worktree>` (only plantable by an uncontained-override child) could make
  `git worktree remove --force` target another worktree — add a `! -L "$d/view"` guard.
  (b) `mount_ident_live` treats a zero-byte `.claim.N` as live, while `mount_claim_take` treats a
  readable zero-byte claim as a legacy release tombstone; the conservative disagreement is safe but
  can wedge GC of an ident that carries one — share one claim-classification helper.
  (c) `mount_ident_live` skips a non-regular dirent at `.claim.N` (`[ -f ] || continue`) rather than
  treating it as live. (d) A deterministic scan/claim/delete interleaving test would protect the GC
  race fix from later reordering (the current test is structural). (e) A stale `mount_restage`
  comment still calls an ephemeral kdir "its run dir". None gate increment 1; the panel approved.
- **grok on Darwin has no backend.** Its sandbox is a documented macOS network no-op, so a grok
  mounted turn is REFUSED by default (`COMMS_RUNPHASE_ALLOW_UNCONTAINED=1` to override). The
  default panel therefore loses cross-vendor corroboration on macOS unless reviews run on Linux.
  This is the product decision above, unchanged.
- **Toolchain is not integrity-pinned.** acpx names codex-acp `^1.1.5`; it resolved to 1.6.2 here.
  The backend's guarantees are version-specific and nothing binds the resolved versions to owner
  identity or fails closed on an unapproved combination.
- **Credential read.** The sandbox allows reads, so a contained reviewer can read the isolated
  `auth.json` into its review body; network is dead so it cannot post it, but the parent reads
  that text. A redacted evidence pack (never raw `git config --show-origin` or remote URLs) is
  the intended mitigation and is not built.
- **Stale isolated credential — CLOSED 2026-08-31.** The isolated home persists across rounds for
  warmth, so if the source `auth.json` was later removed or replaced (a logout, a credential
  rotation, or the source becoming a symlink we refuse to follow), the previous per-mount copy
  lingered in the home and silently undid the removal — the next mounted turn ran on a revoked
  credential. The staging block now has an else-branch: when there is no usable source, the
  isolated `auth.json` is removed, FAIL-CLOSED (a copy it cannot delete refuses the turn rather
  than running on a possibly-revoked credential). Verified by a code-shape assertion in the
  isolation section (the codex backend itself is a reproducible-by-hand probe, like every other
  isolation boundary here — the suite stubs acpx and does not run a real codex Seatbelt turn).
  Reproducible probe: stage a round with `~/.codex/auth.json` present, remove it, run a second
  round on the same mount, and confirm the isolated `auth.json` is gone. (codex, isolation impl r6,
  advisory.) Double-APPROVE over two implement rounds; the shape assertion was strengthened in r2 to
  bind to the source gate and require the fail-closed `die` after the `rm` (which also rejects an
  inverted gate). **Follow-up when this is next touched (impl r2, both reviewers, non-blocking):** the
  assertion matches the `die` STRING after the `rm` but not the `[ -e ] || [ -L ]` recheck predicate,
  so an unconditional `die` replacing the conditional recheck would still pass — add those predicates
  between the `rm` and the `die` in the awk. A functional codex mounted turn (round-1 stage /
  round-2 clear) was built and works standalone but is timing-fragile in the full suite under this
  machine's game-driven load, so it was not committed; it becomes worthwhile once the suite is robust
  under load.
- **The `.codex/config.toml` refusal is a repo footgun until composite-root.** A developer with a
  local (untracked) `.codex/config.toml` in the checkout has it snapshotted into every artifact
  (snapshot-on-send captures untracked files), and every mounted codex review of THIS repo then
  refuses. `.gitignore` now excludes it, which removes the footgun for the default case; the
  general fix (an artifact that legitimately carries a benign `.codex/config.toml` and is still
  reviewable) is the composite-review-root cwd change. (grok, isolation impl r6, advisory.)
- The behavioral probes above are REPRODUCIBLE BY HAND, not hermetic suite tests: a real codex
  Seatbelt turn needs live auth + network + minutes, which the suite deliberately avoids (it
  stubs acpx). The suite asserts the code SHAPE; the boundary itself is verified by the probes
  recorded below. A hermetic test would exercise a fake sandbox — testing the stub, not the
  boundary — which is weaker, not stronger.

### Isolation probes (Darwin; acpx 0.13.1, codex-acp 1.6.2, codex read-only) — reproducible

Isolated `CODEX_HOME` (credentials + `sandbox_mode="read-only"`) with `INITIAL_AGENT_MODE=read-only`,
turn driven through the real `panel dispatch` path:

| probe (child shell inside the mounted turn) | result |
|---|---|
| write in the mount / write to `/tmp` | `operation not permitted`, file absent |
| `curl https://api.github.com/` | exit 6, `Could not resolve host` |
| `python3` unix-socket `connect` to a parent-created listener at `/tmp/*.sock` | `PermissionError: [Errno 1] Operation not permitted` |
| hostile ancestor+cwd `.codex/config.toml` = `danger-full-access`, then write | `operation not permitted`, file absent |
| hostile **cwd** `.codex/config.toml` `[mcp_servers]` command writes `/tmp/marker` | **marker WRITTEN** — MCP ran outside the sandbox (the vector; now REFUSED before spawn) |
| same, with the project `.codex` removed (control) | marker absent |
| same `.codex` one directory ABOVE cwd | marker absent — codex reads cwd's `.codex`, not ancestors' |
| `cat`, `git log` | exit 0 |
| the turn itself | completes (model API alive) |

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
  **Corrected and half-shipped 2026-08-27.** The premise above is wrong on DURABILITY
  and was hiding a real defect underneath it. Where a conforming reply exists it is
  already written into the driver's inbox — the self-sending peer sends it
  (`runphase.sh:1085`), the broker copies and sends it for grok and for ACP
  (`runphase.sh:793-796`, `:1299`) — from a `nohup`-detached runner, and `result.json` is
  deliberately written LAST. One route is weaker than that and it is worth naming: the
  self-sending arm marks a turn `completed` from the child's exit code alone
  (`runphase.sh:1361-1368`) without checking that anything landed, so a child exiting 0
  without sending produces a completed result and an empty inbox. Parent-brokered routes
  do not have that hole because the parent performs the write. (grok, panel r1.) So a dead
  await loses a notification, never a verdict; field item #6 ("panel completion writes
  to the awaiting agent's inbox, not only the run dir") asks for a write that already
  happens on every route. Field item #5 ("awaits must drain the inbox") also loses its
  stated justification: `cmd_await` polls `result.json` and the runner pid and has no
  socket in the path — it is already a file-drop poller.
  What was actually broken, and is now fixed: `panel status` and `compose` scanned the
  archive and a **hardcoded `to-claude`**, so any panel a non-claude agent drove was
  invisible to its own gate — replies land in the driver's inbox, both readers saw
  nothing, and compose refused a COMPLETE panel as INCOMPLETE. One accessor
  (`leg_reply_candidates`) now yields the archive plus every registered inbox; the
  binding chain that decides answeredness is untouched, so the widened scan only makes a
  bound reply reachable. Every pre-existing panel test used `from: claude`, which is why
  it survived. And the durable record is now DISCOVERABLE: bare `panel status` lists the
  review sets instead of usage-erroring, so a resumed session can ask what it was waiting
  for rather than needing the set id its dead await printed.
  Remaining, and genuinely open: **notification**. Nothing watches; a driver still has to
  come back and look. Build it on the driver-neutral readers above — a notifier written
  against the old `to-claude` scan would have been silent for exactly the drivers that
  most need it.
  Carried out of that loop's advisories, none blocking, all recorded so they are not lost:
  - [ ] The `result-spawned-exception` loopspec fragment and the four generated templates
    still tell an agent to report any non-zero await instead of checking for a reply that
    may already have arrived. `docs/PROTOCOL.md` now says otherwise in both the paragraph
    and the outcome table, so the fragment is the surface that disagrees — and changing it
    is a fragment edit plus a pin sync for every vendoring consumer, which is why it was
    not folded into a docs round. (codex.)
  - [ ] `sorted_message_files` treats a MISSING inbox directory as a failing `find` under
    `pipefail`. `cmd_status` already papers over it with `|| true`; the panel scan now
    walks every registered inbox, and `install.sh` creates only `to-claude` and `to-codex`
    while the zero-config registry is `claude codex grok`. bash 3.2 hides it inside
    `$(...)`; bash 4.4+ would abort the substitution mid-list, and a registry listing a
    never-created inbox FIRST would hide every inbox after it. One line at the top of the
    accessor (`[ -d "$dir" ] || return 0`) makes every caller match what `cmd_status`
    already assumes. Pre-existing, not introduced by the panel scan, but the scan is what
    made it reachable on a default layout. (grok.)
  - [ ] The malformed-registry regression tests cannot distinguish the caller-reads-once
    fix from the older `inbox_for` version — both fail at the caller's initial read. A test
    that invalidates the config AFTER that snapshot would cover the swallowed inner
    revalidation directly. (codex.)
