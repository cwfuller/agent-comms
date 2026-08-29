# Command & helper reference

Every Claude Code command, Codex skill, and helper subcommand. Commands are thin
prompt-wrappers; the shell logic lives in the installed helpers (see
[INTERNALS.md](INTERNALS.md) for why).

## Claude Code commands

### `/auto [--plan] [--reviewers a,b] [--rounds N] [--via cmux] <task>`

Implement → send to Codex → fix blocking findings → repeat until `APPROVE` or `N`
rounds (default 10). The task text can describe work or reference an existing plan file.
Round messages keep stable context (latest findings bundle + `git diff --stat` +
validation results), never per-finding fix narration.

### `/ask [agent] [question] [--with-diff] [--with-files a,b]`

One-off judgment call — no review framing, no loop, no verdict.

**Target parse:** if the first word of the argument is a registered agent name
(`comms.sh agents` — the `.comms/config` registry; zero-config default `claude codex grok`),
it names the target and the rest is the question; otherwise the whole argument —
unrecognized first word included, unmodified — is a question to the default agent
(`comms.sh agents default`). `/ask grok is X sound?` targets grok when grok is
registered; an unregistered word (e.g. `gemini`) stays part of the question text.

**Explicit question:** body carries `## Question` (verbatim), optional `## Context` /
`## Current Thinking` (your draft take so the agent refines rather than starts blank),
and `## Grounding` when `--with-diff` (attaches `git diff <default-branch> --stat`) or
`--with-files` is set. The reply is `type: response`: `## Summary` + `## Codex Take`.
Follow-ups are a new `/ask`.

**Thoughts mode:** bare `/ask` (or `/ask codex` alone) sends an informal consult on
the current discussion instead of prompting you for a question. The payload is a
VERBATIM excerpt, not a summary: at minimum the most recent completed user-message
(question or request) → assistant-answer pair — that pair overrides the ~4 KB soft
cap and is never truncated mid-message; older complete turns are included only while
they fit. With no completed prior exchange the command fails closed and asks what to
send. The message is written with a non-interpolating writer (verbatim excerpts can
contain any heredoc delimiter).

`/ask-codex` was removed in the 2026-08-26 collapse; the installer deletes it on upgrade.

**`--via acp` (synchronous transport):** skips the mailbox entirely — the consult
runs as one blocking acpx call (pinned, via npx; Node >= 22.13) and the answer
lands directly in context, followed by acpx's token-usage line. Warm by default: a
named per-repo session makes follow-ups pay only the delta (measured 2026-08-20:
cold one-shot 18,562 fresh input tokens vs warm round-2 146 — ~127x). `--oneshot` forces a stateless
exec. All three registered agents have ACP profiles (codex, claude, and grok via `grok-build`).
On any failure the helper names the fallback: rerun without `--via acp`.

> **Internals.** `/send-to-codex` and `/read-from-codex` are the loop's individual steps.
> The loop drives them; you rarely type them. They are documented here because delivery
> nudges them by name, not because they are part of the everyday surface.

### `/send-to-codex [instructions]`

One-shot review request for work you just did: gathers diff stat, recent commits, and
plan context; writes a `review-request`; validates + delivers. Extra argument text
becomes review-focus instructions.

### `/read-from-codex [filter]`

List and act on pending messages. Manual flow (no `workflow` field): summarize, archive,
ask how to proceed. Autonomous flow: enforce verdict/round semantics (normative in
[loopspec/SPEC.md](loopspec/SPEC.md)), reply, atomically archive. An empty inbox
reports the latest archived message — a late delivery nudge for an already-processed
reply is common and harmless. Filter argument: "only the latest", "all messages", a
filename, or a thread.

### `/clean-comms [workspace|all|archive|<filename>]`

Guarded cleanup via `comms.sh clean` — always dry-runs first, deletes only after you
confirm (`--yes`). Default `workspace` mode touches **your inbox + archive only**; `all`
is the only mode that deletes the other agent's unread mail.

## Codex skills

### `$read-from-claude`

Mirror of `/read-from-codex` for Codex's inbox. In autonomous mode it reviews
immediately (no user prompt): round 1 = full contextual review; round 2+ = holistic
re-review with a blank checklist; every round runs the implement checklist
(auth/state-transitions/entry-points/async/tests); final round adds a broad quality
sweep. Verdict bar: default `APPROVE`; `REQUEST_CHANGES` only for ship-stopping issues.

### `$send-to-claude`

Write findings (`### Blocking` / `### Advisory` / `### Process`), copy the loop's
workflow fields + `thread`, set `in-reply-to`, then atomically validate + deliver +
archive the inbound via `comms.sh send`.

**Codex sandbox note:** set the global `workspace-cmux` permission profile once so every
new Codex session inherits normal workspace access plus the one cmux Unix socket
allowance; `comms.sh codex-permissions` prints the exact config and `comms.sh doctor`
verifies it. No launch flag is required. If an old or managed session reports
`RESULT: blocked`, Claude was not notified and passive polling is not assumed. Do not
resend from the unchanged sandbox; use a host-capable `RECOVER:` or one manual pickup.

## Helper CLI

Installed at `~/.agent-comms/` (or `<repo>/.agent-comms/` for pinned local installs).
Both agents — and you — can call these directly; they're plain bash, caller-shell
agnostic.

### `comms.sh`

| subcommand | effect |
|---|---|
| `root` | print the main repo's `.comms` path (worktree-safe) |
| `workspace` | print the resolved workspace name (cmux → branch → repo dir) |
| `doctor` | verify this session can reach cmux; exit 3 plus the persistent setup command when the socket is sandbox-blocked |
| `codex-permissions [socket]` | print the least-privilege global Codex permission profile for cmux delivery (opt-in since 2026-08-25) |
| `agents [default\|--supported]` | registered agents from `.comms/config` (zero-config: `claude codex grok`), the default target, or the supported-backend table |
| `list --as <agent> [--thread <t>]` | pending inbox messages, newest first; non-zero + "latest archived" hint when empty |
| `status` | one-screen loop summary: workspace, latest archived message + its loop fields, pending counts per inbox |
| `validate <file>` | frontmatter/body checks; reasons on stderr, non-zero on failure |
| `verdict <file>` | normalized verdict: whitespace-stripped, uppercased, loopspec synonyms mapped (`pass` → `APPROVE`, `fail` → `REQUEST_CHANGES`) |
| `archive --as <claude\|codex> <file...>` | idempotent move to `archive/`; refuses files outside your own inbox |
| `deliver <claude\|codex> [file]` | routes via `transport`, classifying the MESSAGE: one carrying `workflow:` is a loop (headless-first, `spawned`), anything else is a consult/one-shot (live pane first, then ACP — the `acp` route runs a parent-brokered turn through `runphase --via acp`). Prints `delivered to <surface> (<how>)` / `spawned` / manual-pickup / `blocked` (sandboxed socket) / `FAILED`. `COMMS_DELIVERY=cmux` forces the pane; `=headless` forces the runner |
| `send --to <claude\|codex> <file> [--archive-inbound <file>]` | validate → deliver → record state → archive inbound, atomically; ends with a loud `RESULT:` line (`delivered`/`spawned`/`manual`/`blocked`/`failed`) |
| `reconcile <message-file\|message-id>` | record a successful external/direct nudge; used as the final guarded segment of `RECOVER:` |
| `bind <claude\|codex> [surface:N]` | pin which surface delivery targets (show current with no arg); successful deliveries auto-refresh it; ignored if the surface disappears |
| `presence claim\|beat\|others\|release\|expire\|with-beat` | advisory multi-session coordination on `.comms/sessions/` — claim-then-check (exit 0 direct-safe / 3 peers / 4 fail-closed ambiguity), whole-file heartbeats (exit 5 = healed, re-check before writing), exact-self release, two-pass byte-identical reap with nonce tombstone covers, and a beat-wrapper for long-running children. See PROTOCOL "Presence & worktrees" |
| `worktree new [<slug>]` | session worktree under the MAIN root's `.claude/worktrees/` on branch `worktree-<slug>`, from the LOCAL default-branch tip; refuses without ignore coverage |
| `integrate <branch>` | land on `main`: advisory lease, ff-only, suite (config `suite-cmd = ...`) at the candidate OID in a detached worktree, then CAS `update-ref` — a race loses cleanly, main only ever advances to suite-verified commits. A single clean checkout idling on `main` at the expected tip is self-healed through the landing; `suite-attest-secs = N` config accepts a fresh same-OID `attest-green` record in place of the re-run |
| `attest-green [--passed N] [--expect <oid>]` | record "suite green at this checkout's exact HEAD" (clean tracked tree required) into the main root's `.comms/cache/suite-attest.log`; a green `tests/run.sh` records itself automatically, passing `--expect` with the commit it started on so a HEAD that moved mid-run refuses instead of inheriting the result |
| `state list \| get <thread> \| complete <thread>` | thread state inspection / closure |
| `stalled [minutes]` | threads awaiting a reply longer than the threshold (default 15) |
| `clean --as <claude\|codex> [mode] [--yes]` | guarded delete; dry-run without `--yes` |
| `lessons [--bytes N] [--surface P] [--file F]` | bounded newest-first tail of the current worktree's `docs/advisories.md` |
| `archive-search <pattern> [--bytes N] [--limit K]` | bounded newest-first search of `archive/` across workspaces |
| `findings [--out F] [--role gating\|shadow] [--review-set ID] [--artifact ID] [--reviewer-version V] [--prompt-version V] [--header] [<message>...]` | extract review findings to TSV (default: the whole archive, oldest first); `--out` appends and is idempotent by `finding_id` |
| `shadow --to <agent> <review-request> [--review-set ID] [--out F] [--timeout-secs N]` | run a SECOND reviewer on the same artifact; the reply is stored but never delivered and never written to thread state |
| `events [--set S] [--dispatch D] [--thread T] [--kind K] [--agent A] [--role R] [--limit N]` | read the coordinator's append-only log (`.comms/events.tsv`): roster planned → request persisted → dispatched → turn started → provider result → reply validated/refused → reply accepted → turn finished → composition completed. Filters apply before `--limit`; a malformed row is named on stderr, never parsed. See PROTOCOL "Coordinator event log" for the recovery walk |
| `events append --kind <kind> [--set\|--dispatch\|--thread\|--round\|--agent\|--role\|--artifact\|--request-id\|--message-id\|--run-dir\|--status\|--note]` | the single writer every producer calls; closed kind and role vocabularies, per-column budgets, and a refusal — on EVERY append, against an allowlist of local filesystem types — to write the log where appends are not sound |
| `snapshot [create\|list] [--with-base]` | retain the tree under review as a durable git object under `refs/agent-comms/artifacts/`; `--with-base` prints `artifact_id<TAB>base_sha` from the one operation |
| `workspace set <name>` | pin the repo's mailbox identity explicitly (`.comms/workspace`) — beats every inferred source; cmux ids then only route surfaces |
| `prompt-version [--list]` | content hash of the reviewer instruction surface |

#### The grading pilot — `findings`, `shadow`, `snapshot`, `prompt-version`

These four exist to answer one question: **which reviewer is good at what.** They are
deliberately not a grading system — the pilot's job is to find out whether that
comparison is measurable at all before anything richer is justified. See the
"Reviewer grading & panel track" section of [ROADMAP.md](ROADMAP.md).

- **The archive is already the baseline.** Every `review-feedback` message carries
  template-mandated `### Blocking` / `### Advisory` sections, so `findings` reads 112
  real findings out of this repo's own history with no protocol change and no prompt
  change. `### Process` is never extracted — it never gates a verdict, so it is not a
  graded observation either.
- **Unknown fields stay empty, never guessed.** A retro-extracted row honestly has no
  `artifact_id`, no `reviewer_version`, and no `prompt_version`; inventing them is the
  exact failure this track exists to avoid.
- **`snapshot` retains CONTENT, not a hash.** A hash proves two inputs were identical
  but cannot resurrect either, so unchanged-since analysis needs the tree itself. The
  working tree (tracked edits *and* untracked files, mailbox mechanically excluded) is
  written as a real commit without touching the worktree, the index, or the stash, then
  anchored under `refs/agent-comms/` — **the anchor is the retention**; an unreferenced
  object is garbage-collection bait. A clean tree returns `HEAD` rather than minting a
  synonym for identical content. (`git stash create` is the obvious tool and is wrong:
  it silently drops untracked files even with `--include-untracked`.)
- **`shadow` cannot gate, mechanically.** The second reviewer's reply is produced and
  validated but never delivered to an inbox and never written to thread state, so it
  cannot steer a loop it was never delivered into and cannot archive the primary's
  request out from under it. A crashed shadow turn is recorded as an operational
  failure, never as a reviewer that reviewed and found nothing. `runphase.sh run
  --no-deliver` refuses any provider that authors and sends its own reply, because for
  those the flag would silence the state write while the delivery still happened.
- **The artifact is MOUNTED, and shaped like the worktree it came from.** Retaining a
  commit while the reviewer reads the live tree would let `artifact_id` name content
  nobody inspected — one edit during a nine-minute review is enough. But checking the
  synthetic artifact commit out directly is also wrong, and wrong in a way no content
  check can see: `HEAD` becomes that synthetic commit rather than the request's
  `head_sha`, and `git diff` comes back **empty** because every reviewed change is
  already committed inside it — so the reviewer fails its own head check and finds no
  patch. `shadow` therefore creates the worktree at the **base**, materializes the
  artifact into it, and resets the index back to base: `HEAD` matches `head_sha`, the
  reviewed changes read as uncommitted, and files that were untracked are untracked
  again. Only `cwd:` is rewritten (inserted when absent), byte-preservingly, into a
  deliberately neutral mount path.
- **Pairs are CANDIDATES, and `drift_status` is a tri-state.** `same_endpoint` means only
  that no drift was detected during the shadow window — never that the gating reviewer
  read this artifact, which nothing currently binds. `changed` names the new artifact;
  `unknown` means the post-run snapshot could not be taken. An empty field must never be
  read as confirmed-identical, which is why the status is explicit rather than inferred
  from a blank column.
- **One pairing per thread+PHASE+round, enforced at write time.** A second shadow after
  the tree or prompt moved would silently stamp later gating findings with the older
  artifact, and "take the first row" is an arbitrary answer to a question with no right
  answer. `shadow` refuses it and names the existing set. Phase is part of the key
  because `/auto --plan` keeps one thread across the plan→implement transition and
  restarts at round 1 — plan r1 and implement r1 are different artifacts under the same
  thread and round.
- **The claim is stored whole.** Rows are immutable and idempotent by `finding_id`, so a
  display-length clip is permanent — v1 lost the tail of 40 of its first 112 claims.
  Truncation is the reader's job. A schema change is refused rather than mixed into an
  existing ledger; `findings --out F --rebuild` regenerates from the archive plus the
  shadow store.
- **`prompt-version` hashes what the reviewer actually RUNS** — the installed surface,
  not your working copy. Editing `helpers/runphase.sh` in this repo does not move the
  hash until `install.sh` copies it out. Collect a baseline against the installed
  surface, or the version column will understate the churn.
- **The set index does the join.** The gating reviewer replies later through the normal
  loop, knowing nothing about any of this; `.comms/grades/sets.tsv` maps thread+phase+round to
  the shared `review_set_id` and `artifact_id` so the pair reconciles without re-running
  anything.
- **`prompt-version` partitions, it does not pool.** Grades do not carry across an edit
  to a reviewer instruction, and in this repo every active review day has also been a
  day that text changed.

What is deliberately absent: dispositions (no cheap honest producer — a terminal
`APPROVE` does not confirm each preceding finding), escape attribution (textual lineage
is not semantic attribution), and any score. Disjoint findings show diversity, not
quality; converting that into a routing claim needs a human verdict on a sample of the
findings one reviewer raised and the other did not.

#### Transport selection — loops are headless-first

`comms.sh transport <agent> [--loop]` is the single decision point; `deliver`, the
templates, and these docs all read from it rather than each re-deciding.

| context | default | why |
|---|---|---|
| **loop** (`auto-*`) | `acp` → `headless` → `cmux` | cost, measured on one real review turn in this repo: cmux ~43–85k fresh input tokens, cold headless ~115k, warm ACP **~1,061**. A cold spawn rebuilds context from nothing each round; a live pane keeps the conversation but still re-sends a large uncached prefix per model call. Only a named per-thread ACP session makes round N pay a delta |
| **consult** (`/ask`) | pane if one is live, else `acp` | a consult is synchronous by nature; ACP needs no pane and warm sessions cost ~1/127 the input tokens |

Opting back into the watchable pane: `--via cmux` on an `auto-*` command, or
`COMMS_DELIVERY=cmux`. `--via headless` / `COMMS_DELIVERY=headless` force the detached
runner. If cmux is explicitly requested and no surface is live, delivery reports
`mailbox` rather than silently substituting a transport you did not choose.

Headless-first falls back to a pane **only** when `runphase.sh` is genuinely missing —
flipping the default must not strand every loop on an install where it never landed.

#### The bounded readers

`lessons` and `archive-search` exist because the two "consult past lessons" reads were
the only unbounded ones in the protocol — `docs/advisories.md` is append-only and
`archive/` grows with every loop, so both cost more tokens every week. Both now
guarantee one invariant:

```
combined(stdout + stderr) <= --bytes + 256      # 256 = DIAGNOSTIC_MAX, a constant
```

That constant only holds because every echoed caller-controlled value (path, pattern,
heading) is clipped to a fixed width first — otherwise a long `--file` argument would
inflate the "constant" and defeat the cap.

- **Whole units, never byte slices.** `lessons` emits whole `## ` sections; a byte
  slice can hand an agent a truncated bullet that reads like a complete instruction.
- **Nothing vanishes silently.** A section that does not fit is named in place
  (`## <heading> — OMITTED (N B) — read <path>`), and whatever could not even be named
  is counted in a trailing summary line.
- **Exit `3` means truncated, not failed** — "you have the newest; the rest are named
  by path". Exit `2` is a usage error; `0` is complete.
- **Ordering is by the date in each `## ` heading**, so the writer may append or
  prepend. Undated sections sort last and are never dropped.
- **`lessons` resolves `docs/advisories.md` from the CURRENT worktree**
  (`git rev-parse --show-toplevel`), not from `comms.sh root` — see the resolver note
  in [INTERNALS.md](INTERNALS.md#workspace-resolution).
- **`archive-search` filters by match first, then sorts the matches globally, then
  applies `--limit`** — so the limit can never discard a newer match, and the per-file
  frontmatter parse runs only on hits.

### `docs/loopspec/check.sh`

Conformance checker for the [loopspec](loopspec/SPEC.md) kernel:
`check.sh --comms <path-to-comms.sh>` runs the implementation against the golden
fixtures (valid/invalid messages, verdict-normalization table, schema smoke). The test
harness runs it on every `bash tests/run.sh`; consumers that vendor `docs/loopspec/`
re-run it (or their own reader) against the same fixtures in their CI.

### `acp.sh` (experimental)

Synchronous `/ask --via acp` transport over pinned acpx (`consult <agent>
[--oneshot] [--file <path>] [words...]`, `doctor`). Warm named-session default;
acpx exit codes translated to mailbox-fallback guidance; fails closed on missing
Node, unsupported agents, or acpx errors — the mailbox path is always available.

### `runphase.sh` (experimental)

Headless peer-turn runner, and the host for ACP turns (`run --via acp`). Loops default to **ACP**; headless is the fallback when ACP is unavailable; cmux is opt-in via `--via cmux` / `COMMS_DELIVERY=cmux`.
`deliver`/`send` call `spawn` for you — `await`, `result`, `hold`, and `release` are
the operator surface:

| subcommand | effect |
|---|---|
| `run --message <file> --dir <run-dir> [--provider ...] [--no-deliver]` | foreground runner. `--no-deliver` produces and validates the reply in the run dir but touches **neither the mailbox nor thread state** — the measurement mode behind `comms.sh shadow` |
| `spawn --message <file> [--provider codex\|claude] [--sandbox <mode>] [--timeout-secs N]` | detach a peer turn (`codex exec --json` / `claude -p --output-format stream-json`); prints pid + run dir immediately; refuses (`HELD`) while the thread is held; won't double-spawn while a prior runner for the message is alive |
| `await <run-dir> [--timeout-secs N]` | block until the turn's `result.json` exists (or the runner dies); prints it; exit 0 only for `status=completed` |
| `result <run-dir>` | print `result.json` if present |
| `hold [thread]` | pause: block new spawns for the thread (all threads with no arg); prints the attach commands (`claude --resume <sid>` / `codex resume <tid>`) from state |
| `release [thread]` | lift a hold |

Each turn is recorded under `.comms/logs/<message_id>.<epoch>.<pid>/`: `prompt.md`
(what the peer was told), `events.ndjson` (the full JSONL event stream — token usage
lives here), `result.json` (provider, status, exit code, session id), `pid`,
`runner.log`. Thread state mirrors the outcome (`spawned` →
`completed`/`failed`/`timeout`), records `last_run_dir` (the `stalled` watchdog's pid
target), and records the provider session id (`codex_thread_id` /
`claude_session_id`) for attach/resume. Env knobs: `COMMS_RUNPHASE_SANDBOX` (codex,
default `workspace-write`), `COMMS_RUNPHASE_TIMEOUT_SECS` (default 1800; a turn budget is
whole seconds in `1-999999`, leading zeros are stripped so `08` means 8, and anything
outside that — including `0` and a non-number — falls back to the default with a warning
naming the budget actually used),
`COMMS_RUNPHASE_CLAUDE_PERMISSION_MODE` (default `acceptEdits`),
`COMMS_RUNPHASE_CLAUDE_ALLOWED_TOOLS` (default `Bash`), `COMMS_RUNPHASE_CLAUDE_ARGS`
(extra flags; bypass/danger permission flags are refused),
`COMMS_RUNPHASE_STATE_WAIT_SECS` (default 6; how long a turn waits for the thread-state
file when `send` declared one is coming — out-of-range or non-integer values fall back to
the default rather than aborting teardown).

## Typical sessions

```text
# autonomous feature, single workspace
/auto --plan --rounds 5 add CSV export to the reports page

# quick design consult while implementing
/ask --with-diff is the retry/backoff approach here sound?

# loop seems quiet?
~/.agent-comms/comms.sh stalled
```
