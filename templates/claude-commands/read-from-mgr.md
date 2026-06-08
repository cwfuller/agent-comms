Pick up and execute a task dispatched by `mgr dispatch` — a `type: task-assignment` message in `.comms/to-claude/`.

This is the RECEIVER + EXECUTOR half of cross-workspace dispatch (the sender is `mgr dispatch`, in cmux-mgr). It is NOT `/read-from-codex` (that's the codex review-loop reader). A task-assignment is work to DO, claimed exactly once, executed under a mode-aware safety policy.

## Instructions

### 1. Resolve the shared helper (worktree-safe; local pin wins over global)
```bash
COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
[ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
[ -x "$COMMS_SH" ] || { echo "agent-comms helpers not installed — this repo is not dispatch-ready" >&2; exit 1; }
COMMS_ROOT="$("$COMMS_SH" root)"
```
**Precondition (fail clearly):** if `$COMMS_ROOT` does not resolve or `.comms/` is not present + gitignored in this repo, STOP and report "this repo is not agent-comms-initialized — run agent-comms install --scope=project first." Do no partial work.

### 2. Find the task-assignment(s)
List `to-claude/` and read the newest message whose frontmatter is `type: task-assignment` and `from: mgr` (ignore codex review messages — those are `/read-from-codex`'s). Validate with `"$COMMS_SH" validate "<file>"` AND that it carries `goal`, `stop_condition`, `write_policy`, `execution_mode`. Malformed/missing fields → report and STOP; do NOT act, do NOT archive.

If there is no `type: task-assignment` from mgr, tell the user "no dispatched task to pick up" and stop (a stale nudge is harmless).

### 3. CLAIM exactly-once (before ANY work)
A task can mutate code and possibly main — it must run at most once per `message_id`. Claim atomically:
```bash
MSG="<the assignment file>"
MID="$(basename "$MSG" .md)"
STATE_DIR="$COMMS_ROOT/dispatch-state"; mkdir -p "$STATE_DIR"
REC="$STATE_DIR/$MID.json"
# atomic create + write the record in ONE guarded step: if $REC already exists, this task is already
# claimed → STOP (never double-execute). Writing the JSON inside the noclobber guard means a crash can
# never leave an empty, useless claim record.
if ! ( set -o noclobber
       printf '{"dispatch_status":"claimed","message_id":"%s","claimed_at":"%s"}\n' \
         "$MID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$REC" ) 2>/dev/null; then
  echo "task $MID already claimed (see $REC) — not re-executing"; exit 0
fi
```
Then **archive the inbound** so a repeated `/read-from-mgr` finds nothing to run:
```bash
"$COMMS_SH" archive --as claude "$MSG"
```
> `dispatch-state/<message_id>.json` is the audit/recovery record — NOT terminal-of-the-work. A record stuck at `claimed` (process died mid-task) is surfaced for MANUAL recovery; never silently re-run.

### 4. Triage the execution mode
**`write_policy` is BINDING.** Before anything else, read the assignment's `write_policy` — the mode you ultimately execute MUST be permitted by it. If the policy is the auto-worktree form ("atlas/* worktree + branch; open a PR…"), you may NOT choose `one-shot` (no main-branch commit) — only `auto-implement`/`auto-full`. Only a `triage` policy (or an explicit `one-shot` assignment) permits the gated one-shot-to-main path. If your triage decision would violate the stated policy, default up to the most careful mode the policy allows.

Read `execution_mode` from the assignment. Honor it, with **escalate-only** authority:
- `auto-full` / `auto-implement` / `one-shot` — an explicit mode. You MAY escalate to a MORE careful mode; if you would go LESS careful than the hint, do NOT — keep the hint (or escalate).
- `triage` — YOU decide in-repo, using the rubric. **When unsure, default to `auto-full`.**

Rubric:
- **one-shot** — trivial, mechanical, unambiguous, low-risk (typo, doc tweak, an obvious one-line fix), NO design decisions. The bar is HIGH; it is additionally gated mechanically in §5c.
- **auto-implement** — well-specified, clear location + approach, design settled.
- **auto-full** — ambiguous / exploratory / intent-level brief / design decisions / higher blast radius. **The default when unsure.**

Record the chosen mode into the state file (`"mode": "<chosen>"`, plus `"escalated_from"` if you escalated).

### 5. Execute

**Verification = "can you RUN the thing?"** Across every mode, the change is not done until you have actually RUN it and observed it work — run the affected flow / feature / endpoint / path end-to-end, not just `lint`/`type-check`/unit tests (those are table stakes, already automated). If the repo has a way to exercise the change (a CLI, a dev server, a script, a simulator, the actual flow the brief names), use it and confirm the real behavior. Surface what you ran + what you observed in the review request and the final report. A change that passes tests but was never run is unverified.

All loop messages go to the MAIN repo's `.comms/` (the helper resolves it); review-request frontmatter `cwd:` must point at the FEATURE WORKTREE so Codex reviews the right files.

#### 5a. `auto-full`
1. Create + enter a worktree on a fresh branch off the default branch:
   `git worktree add -b "atlas/<slug>" "../<repo>-<slug>"` (slug from the goal). `cd` into it.
2. INLINE the auto-full PLAN-phase initiation (do NOT invoke `/auto-full` as a nested command — templates are prompt wrappers, not callable). Create the plan, then write the first `type: review-request`, `workflow: auto-full`, `phase: plan`, `round: 1` message to the MAIN repo `.comms/to-codex/` with `cwd:` = the worktree path, `thread: <slug>-<rand>`, and a body carrying the `goal` + `stop_condition`. Deliver via `"$COMMS_SH" send --to codex`.
3. The standard `/read-from-codex` loop then drives plan→approve→implement→approve in that worktree. **Runtime verification (§5) is the CHILD implement loop's responsibility before its final approval** — it is not applicable at this start step (no code exists yet); the implement phase must RUN the change before approving.
4. Update the state record to `dispatch_status: started` with `{branch, worktree, child_thread}`, and STOP. **`started` is terminal for THIS receiver command, NOT for the delegated work** — the reviewed `atlas/*` branch is the deliverable; opening the PR + marking the dispatch complete is a separate, reviewed step (a named follow-on; do not auto-open a PR or auto-merge here).

#### 5b. `auto-implement`
1. Create + enter the `atlas/<slug>` worktree (as 5a.1).
2. **Implement the change** in that worktree; run the repo's validation/tests.
3. THEN inline the auto-implement initiation: write the first `workflow: auto-implement`, `phase: implement`, `round: 1` review-request to the MAIN `.comms/to-codex/` with `cwd:` = worktree, body = goal + `git diff --stat`. Deliver.
4. Update state to `dispatch_status: started` `{branch, worktree, child_thread}`; STOP (same start-and-record semantics as 5a).

#### 5c. `one-shot` — HARD GATES (all must pass, else escalate per §6)
Only for genuinely trivial work. Before committing, ALL of these must hold:
- the worktree is CLEAN to start, on the repo's DEFAULT branch, not diverged unexpectedly;
- make the change; then run `git diff --check` and any cheap relevant lint/test;
- **RUN it** (§5 verification) — exercise the changed path and confirm it actually works; a one-shot commits to main, so "passes lint" is not enough;
- **caps:** ≤ 1 file changed and ≤ 40 changed lines (conservative);
- **risky-path denylist (refuse → escalate):** migrations, lockfiles, generated files, `.env`/secrets, CI/deploy/infra, auth/security, package manifests, broad shell scripts.

If ALL gates pass:
```bash
git add <only the files THIS run changed>
git commit -m "<concise one-line message>"   # LOCAL commit to the default branch
```
**Do NOT `git push`.** Report the commit SHA; pushing is a later, separately-reviewed action. Update state to `dispatch_status: completed` with `{commit_sha}`.

### 6. One-shot gate-trip → clean escalation
If ANY one-shot gate trips AFTER changes were made:
1. Save the candidate diff as a patch into the record dir: `git diff > "$STATE_DIR/$MID.patch"`; note the trip reason in the state record (`"escalation_reason": "..."`).
2. **Restore the main worktree to clean:** `git checkout -- . && git clean -fd <only paths this run added>` (or `git stash` then drop) — leave the default branch exactly as found.
3. **Assert clean** (`git status --porcelain` empty), then run **§5b auto-implement**: create the `atlas/<slug>` worktree, `git apply "$STATE_DIR/$MID.patch"` there to preserve the work, and continue as auto-implement.
A failed one-shot therefore NEVER leaves the default branch dirty and NEVER loses the work.

### 7. Report
Tell the user the outcome: the chosen mode, **what you RAN to verify it (§5) and what you observed**, and either the `atlas/*` branch + worktree + child thread (worktree modes — "started; the auto-loop is running; open a PR after it approves"), or the local commit SHA on the default branch (one-shot). Point at `dispatch-state/<message_id>.json`.

## Notes
- Never silently exceed the brief; surface ambiguity rather than guessing.
- The dispatcher's `execution_mode` is a HINT; you own the final safety decision and may only escalate to a more careful mode.
- Worktree modes are **start-and-record** in v1. Auto-closing (open PR + mark the dispatch completed on final APPROVE) is a named follow-on that extends `/read-from-codex`; do not do it here.
