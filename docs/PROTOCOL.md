# Protocol reference

How agent-comms implements the review-loop contract: transport, state, delivery, and
archive mechanics. The **contract itself** — message frontmatter and validation rules,
message types, verdict semantics (including the `pass`/`fail` synonyms and the
`gate`/`merge` profiles), loop invariants, threading rules, the compounding entry
format, and the provider turn contract — lives in **[loopspec](loopspec/SPEC.md)**,
the portable kernel this repo shares with other consumers. `helpers/comms.sh`
enforces the validatable parts, and `docs/loopspec/check.sh` proves it against the
golden fixtures in the test harness.

## Directories

All paths are relative to the **main repo root** (worktree-safe — every helper resolves
through `git worktree list`, so messages land in one place no matter which worktree an
agent runs from):

```
.comms/
  config       agent registry (optional — see below; absent = claude codex grok)
  to-<agent>/  each registered identity's inbox (to-claude/, to-codex/, to-grok/,
               to-gemini/ when enabled, to-claude-review/, …) — created on first send; a missing one reads as empty
  archive/     processed messages (every agent moves its own inbox here)
  state/       per-thread loop state, JSON (written by comms.sh send)
```

The **agent registry** (`.comms/config`, line-oriented) declares who participates, and carries
the landing gate's suite keys:

```
agents = claude codex grok
default-target = codex
suite-cmd = bash ci/verify.sh
suite-attest-secs = 600
suite-timeout-secs = 3600
```

`suite-cmd` is what `integrate` runs at the candidate OID. It is **split on whitespace into
argv with no shell**, so `npm ci && tsc` does not work — commit a script and point at it. It
runs in a FRESH checkout (tracked content only: no untracked files, no ignored ones), so it
must provision its own prerequisites; it may leave ignored files but no git-visible changes.
`suite-attest-secs = N` lets a fresh same-OID `attest-green` record stand in for integrate's
re-run. `suite-timeout-secs = N` bounds the suite run (default 3600, `0` = none, at most 86400):
a suite past it has its whole process group killed and `integrate` refuses with exit 18 and an
`integrate-result v1 status=refused reason=suite_timeout` line, so a hung suite can no longer
block a landing forever. An empty, non-numeric or out-of-range value is refused, never read as the
default. All three keys are single-valued: duplicates are refused rather than resolved by precedence.

Names are `[a-z][a-z0-9-]{1,15}` and must have a supported backend
(`comms.sh agents --supported`); duplicates, multi-word defaults, and unsupported
names are hard parse errors — an unrunnable agent must never accept mail. A missing
file means `agents = claude codex grok`, `default-target = codex` (zero-config
back-compat; `gemini` is supported but opt-in — add it to the `agents =` line). Two authorities replaced the old two-party complements: a thread's
`awaiting_from` is the explicit `send --to` target, and `--archive-inbound` derives
the inbound's owner from the OUTBOUND message's `from:` (validated against the
directory the inbound actually occupies; already-archived is an idempotent no-op).

`.comms/` is gitignored — messages are local plumbing, not project history.

### Identities and providers (same-model review)

An **identity** is a name in the mailbox: whose inbox, whose `from:`, whose leg thread
(`<thread>-<identity>`), whose thread state (`awaiting_from`), events (`agent`), shadow store
and acpx session. A **provider** is the runtime that serves a turn — `claude`, `codex`, `grok`
or `gemini` — and it keys everything at the process boundary: transport capability, the ACP-only
rule, the acpx profile, the isolation/containment arm, the hostile-artifact refusals and the
reviewer policy map row. The `agents =` line lists **drivers**, each named after its provider,
so for a driver the two are the same word and nothing about it changed.

**Every driver has a built-in review twin.** For each driver X on the `agents =` line there is a
review-only identity `X-review` running on provider X under its own name — `claude-review`,
`codex-review` and `grok-review` in the zero-config registry — with its own inbox
(`to-claude-review/`), leg thread, state, events and `from:`. It lets a driver be reviewed by
its own model without the request and the reply sharing one inbox, one thread and one
`awaiting_from`. There is **no config key**: a twin exists exactly when its driver does, and
its provider is fixed — `claude-review` always runs on `claude`. `comms.sh agents --review`
lists the twins and `agents --provider <twin>` prints the model behind one. Twins are derived,
never declared: `claude-review` on the `agents =` line is still an unsupported agent, a
`default-target` naming a twin is refused (it must be a driver), and a leftover
`review-agents = …` line from the short-lived per-project config is an unknown line — it warns
(`warning: config: unknown line`) and registers nothing.

A review twin is **review-only**, and each rule sits at the one funnel that sees it:

- **It never drives.** `whoami` refuses it (so `COMMS_SELF=<twin>` fails), as do
  `agents --others`, `agents --roster`, `ask --from` and `panel dispatch` when it is the author.
- **It authors only the `review-feedback` its broker stamps.** `validate` refuses anything
  else from it, so every writer — `send`, panel legs, the broker, `ask`, `shadow` — is covered.
- **It receives only a `review-request` or an `error`** (the per-leg error lane). `send`
  refuses anything else, before any durable write.
- **It is never consulted.** `ask --to <twin>` is a usage error. A same-model consult is
  `/ask` of the driver that runs on that model over ACP (a separate session); the mailbox path
  refuses a question addressed to its own author.

It inherits everything provider-keyed from its driver's provider — containment (`grok-review`
is contained exactly as grok is: by the Seatbelt backend on macOS, and refused without
`COMMS_RUNPHASE_ALLOW_UNCONTAINED` where grok has none), transport, and the policy map
row. There are no per-identity pins or map rows, and one routing decision per base thread
covers every leg.

**The grok provider's containment.** Two questions are answered separately and must not be
confused. *Transport selection* (`comms.sh transport grok --loop` -> `acp`, route
`transport=acp-mounted capability=unsupported`) only says how a turn is delivered; `unsupported` is
the reviewer MODEL/effort policy (agent-comms applies none to grok), not containment. *Containment* is
decided by the runner, per turn, by `helpers/box.sh`: on macOS the grok CLI runs inside a Seatbelt
profile agent-comms applies itself, in an isolated `GROK_HOME` beside the mount (the operator's
`config.toml` is not read; only their default model and reasoning effort are carried; their login is
staged without its refresh token, so the reviewer's copy can never rotate it, and is refused if it is
expired or within ten minutes of expiry after one attempt to renew it with the operator's own `grok
models`). The queue owner is launched with `--no-terminal --no-fs` and a contained `grok` first on its
PATH, using an acpx that enforces those flags (pinned `0.17.1` for grok; `box.sh client-check` sends
the forbidden requests through the launcher actually in use, `ACPX_BIN` included, and the turn is
refused unless every one is denied); the operator's login store is denied by its physical path even when
`GROK_HOME` points outside the home. After the canary the runner requires a launch record under the
current profile hash AND the generation of this turn's preparation, so a launch left by an earlier round
does not count (`reason: containment-unconfirmed` otherwise). `box.sh prepare` runs a battery of positive and
negative probes against the exact profile each turn and refuses on any failure. On a host with no
backend (not macOS) a mounted grok turn is refused unless `COMMS_RUNPHASE_ALLOW_UNCONTAINED=1`; where a
backend exists but cannot run (no `sandbox-exec`, no `grok`, a failed probe) the turn is refused and the
override is NOT consulted — it covers a provider with no backend, not one whose backend is broken.
Both the foreground (`send --wait`) and detached runners reach the same `cmd_run`, so they cannot
disagree; `acp.sh doctor` and `acp.sh containment grok` report the same answer ahead of time.

**The gemini provider** (a fourth model family, Google's, so it can gate work claude or codex
wrote). It is **supported but opt-in**: `gemini` is not in the zero-config registry, so an install
without the Gemini CLI never acquires a reviewer it cannot run — a project enables it with
`agents = claude codex grok gemini`, which also creates `gemini-review` (`agents --roster claude
gemini` is then one reviewer, and `gemini,gemini-review` is refused as two on one provider). Its
family, for the independence rule, is `gemini`. Reviews are **ACP-only** (`gemini --acp`, through
acpx's own `gemini` profile; there is no headless arm) and need the Gemini CLI on `PATH` at
**0.39.0 or later** for a mounted review (the first build that writes the `.jsonl` chat record the
attestation reads; `--acp` itself arrived in 0.33.0): `acp.sh doctor`, `runtime-check gemini`,
`capabilities` and `resolve` refuse an older build with the same wording, while `consult` and `supports`
need only 0.33.0. A mounted
gemini turn gets its own `GEMINI_CLI_HOME` beside the mount (the CLI keeps `.gemini/` inside it), so
the operator's settings, extensions, hooks and MCP servers never reach a review; the leg's model and
thinking level are written to that home's `settings.json` from the policy record (the ACP surface has
no thinking control) and the model is set on the session by acpx (`--model`). The operator's login
keeps working: an API key or Vertex setting in the environment is inherited, a keychain login needs
nothing, and the file-backed login (`oauth_creds.json`, `google_accounts.json`, and `gemini-credentials.json`,
the CLI's own file store when there is no keychain) and the selected auth TYPE (read from the operator's
`settings.json` with comments allowed, as the CLI reads it) are carried across — all mirrored each round,
so one the operator rotated or removed, or the CLI migrated into the reused home, does not outlive its source. The containment
is the in-process **`plan` mode** pin ("Read-only mode") under `--approve-reads
--non-interactive-permissions deny`, the same class as claude's and not a kernel sandbox: the child's
network stays open and the copied OAuth token is readable. It fails closed where it can be checked (an
unconfirmed `set-mode plan` refuses the turn) but was not measured against a live gemini turn.
The CLI's plan policy denies `run_shell_command` outright, so a gemini reviewer **cannot run read-only
`git diff` / `log` / `show`**: it reads the mounted files, and a review that needs a diff or history must
carry it in the request body. The model it ran is attested from the CLI's own chat record in the REVIEW
prompt's window only (a snapshot taken after the canary), so a review the CLI streamed but never recorded
is withheld rather than published on the canary's evidence, and the CLI's own synthetic `gemini` messages
(no model, no tokens) are neither counted nor treated as missing evidence;
a reviewed tree carrying `.gemini/` or `.env` is refused unread, like `.codex/config.toml`. A model pin
is `COMMS_ACP_GEMINI_MODEL` / `COMMS_ACP_GEMINI_EFFORT`, and a refusal is recorded as a failed turn with
its reason (`rate-limited`, `auth-failed` — see below). **Residual:** `claude-review` runs under the same `~/.claude` (settings, user
instructions, memory) and keychain credential as a claude driver on the same machine. The twin
separates the mailbox, not the model's configuration.

**Self-address is refused.** `send` refuses a `review-request` or `question` whose `from:`
equals `--to`, naming the stranded outbound. For a review-request the remedy it prints is the
author's own twin (`--to <self>-review`; `agents --roster` swaps it in for you); for a question
it points at another driver, since a twin never answers a consult. Replies are unaffected, and
`from: claude` → `--to claude-review` is legal.

**One provider, one voice.** Two reviewers on one provider are one model reviewing twice —
same routing decision, same policy, same prompt — so their agreement is not corroboration.
`agents --roster` and `panel dispatch` refuse a roster with two reviewers on one provider
(early and friendly, before any durable write), and `compose` refuses to count two answered
legs from one provider (exit 3, `composition-refused` with status `duplicate-provider`).
compose reads each reply's provider from the reply itself, never from the registry as it reads
now: a driver's reply is its own name, a twin's is the `review_provider` its broker stamped —
which `validate` holds to the twin's fixed provider (see Frontmatter). So a retry, a concurrent
dispatch or a forged stamp cannot make one model count twice. `panel status --set` applies the
same rule and warns on stderr, so it never shows a healthy panel that compose will refuse.

**Choosing reviewers.** Same-model review is **off by default**. `agents --others <driver>` —
the default panel — is the other drivers; only a lone driver (no other driver registered) gets
its own twin, since that is the only reviewer there is. `agents --roster <driver> [a,b,...]`
is the ONE reviewer-list resolver every runtime's loop uses (claude `/auto`, codex `$auto`,
grok `/user:auto`), so naming yourself means the same thing everywhere. With no list it is
`--others`. With a list it validates each name (an unknown one exits 1), swaps the driver's
OWN name for its twin, collapses repeats, keeps the order (the first name gates), and refuses
two reviewers on one provider (exit 2, `two reviewers on provider`) — before anything is
written. `<driver>` must be a driver; a twin there is refused.

```
agents --roster claude                         ->  codex,grok   (the default panel)
agents --roster claude claude,codex            ->  claude-review,codex
agents --roster grok grok                      ->  grok-review
agents --roster claude claude,claude-review    ->  claude-review
agents --roster claude codex,codex-review      ->  refused: two reviewers on provider 'codex'
```

**Enabling it.** Nothing to configure: name yourself in `--reviewers`.
`/auto --reviewers claude,codex` from a claude driver is your own model plus codex
(`claude-review,codex`); `--reviewers claude` alone is same-model review only, and naming the
twin directly (`--reviewers claude-review`) resolves the same way. A request never goes to the
driver's own name — `send` and `panel dispatch` refuse that; the twin is the only route to your
own model. A single-driver project needs only `agents = claude`: with no `default-target`
line the default target is `codex` when registered and otherwise the first driver, and the
default panel is then `claude-review` (`comms.sh setup` accepts a single driver too).

## Presence & worktrees (multi-session coordination)

Sessions coordinate through ADVISORY presence, not locks. The rule, mechanized by
`comms.sh presence` (see COMMANDS.md):

1. **Claim then check.** Before touching the tree, a session records its presence
   (`.comms/sessions/<name>-<instance>.json` — role, state, host, long-lived pid)
   and THEN evaluates peers. Exit 0 = no live/ambiguous REGISTERED
   peers — which is not the same as a clean tree: an unregistered session, a human,
   or an open editor can still hold uncommitted work, so check `git status` before
   staging; exit 3/4 = isolate into a session worktree
   (`comms.sh worktree new`). Task size never matters; peer presence does.
2. **Never occupy `main` with WORK.** Every checkout a session works in runs on
   a session branch; `main` is a ref that advances and never carries WORK. It may
   be checked out only by the supported idle-console exception below —
   `integrate`'s verification worktree is DETACHED at the candidate and never has
   `main` checked out. That exception is now
   supported (2026-08-27): the primary checkout may IDLE on `main` as the
   owner's console — integrate self-heals it through each landing (rule 3), so
   it always shows landed reality. The moment work happens there, it is an
   occupant with changes and landings refuse; move the work to a session branch.
   Migration for a working checkout: `comms.sh workspace set <name>` FIRST
   (pins mailbox identity so the branch switch cannot flap prefixes), then
   `git checkout -b`.
3. **Landing = `comms.sh integrate <branch>`.** Advisory lease, ff-only, the suite
   runs at the CANDIDATE OID in a throwaway detached worktree — a FRESH checkout carrying
   tracked content only, so `suite-cmd` must provision its own prerequisites and may leave
   ignored files but no git-visible changes (see the config block above) — and `main` moves by
   compare-and-swap `update-ref` — a race loses cleanly, an untested or non-ff OID
   cannot land, and main never points at a commit the suite has not passed at.
   Integrate small and often: isolation removes collision, but cross-session
   visibility lives in landed work. Two ergonomics on that skeleton, added after
   the first real landing paid for both (2026-08-27): a SINGLE clean checkout
   idling on `main` at the expected tip is **self-healed** — detached for the
   landing and re-attached to the advanced `main` after the CAS (a fast-forward
   of an idle tree; dirty, diverged, or multiple occupants still refuse, decided
   BEFORE the suite spends ten minutes) — and with `suite-attest-secs = N` in
   `.comms/config`, a fresh `attest-green` record for EXACTLY the candidate OID
   stands in for integrate's re-run (a green suite attests its own commit; an
   identical OID cannot have changed, so the second run proves nothing). Both
   default off-path: no config, no attestation, no occupant → the paranoid
   behavior is unchanged.
4. **Direct is re-earned, never tenure.** After every wait (reviewer round, await,
   resume) a direct session re-runs `presence others` before its next write; a
   `beat` that heals a vanished record (exit 5) demands the same re-check.
5. **The liveness handle is recorded automatically.** A record can only ever be
   proven dead through its pid, so a pid-less one is unreapable at any age and
   lingers as a permanent ambiguous peer — which is how a field of abandoned
   records accumulates until isolation becomes unconditional. `claim` therefore
   adopts the agent harness's own session pid (`CLAUDE_PID`, or
   `COMMS_PRESENCE_PID` for a harness that publishes none) when the caller passes
   no `--pid`. It is adopted ONLY if numeric and confirmed present by `ps`: a pid
   naming no process is worse than none, because such a record evaluates dead
   immediately and the next reap would collect a live session's own claim. Any
   unverifiable value falls back to pid-less, which is the fail-closed direction. Each
   source is TRIED rather than merely preferred, so a stale override cannot shadow a
   good handle. **`beat` re-pins it.** A resumed session runs under a NEW harness
   process, so a heartbeat that merely preserved the recorded pid would leave a live
   session named by an exited one — collected while alive, and then read as a free
   field by the next claimer. That is strictly worse than the immortality this rule
   fixes, and it is reachable only because records became reapable. A beat refreshes
   the handle only with a pid that verifies, and otherwise keeps what is recorded;
   blanking it would manufacture the immortal record all over again. **`others` re-pins
   too**, because rule 4's re-check is the first thing a resumed session runs and would
   otherwise leave a window, before that session's first heartbeat, in which it is dead
   to every reader and collectable while alive. `others` refreshes an EXISTING exact-self
   record only; a vanished one is never manufactured there, since healing is `beat`'s
   exit-5 path and a session is meant to learn its tenure is gone. **`others` is therefore
   a write, not a read** — a successful re-check is a heartbeat of self, so
   `last_heartbeat` means "last beat or re-check". And it **fails closed**: a checkpoint
   whose own record is absent, or bears a reap tombstone, or cannot be re-written, answers
   exit 5 (tenure lost, re-claim) or exit 4 (isolate) rather than direct-safe. Without
   that, a session that was collected and whose collector then released would be shown a
   free field by the very verb that exists to stop it writing. A **missing** sessions
   directory is the same answer, not an empty field: an identity that already claimed
   lost its record along with the directory.
   `expire` supports this by deciding while the record is ABSENT — it renames the record
   aside, compares the moved copy against its observation, and either drops it or puts it
   back. Comparing in place left the record readable between the comparison and the
   unlink, so a concurrent re-check could re-pin it, see no cover yet, and answer
   direct-safe while the pass deleted it.
6. **`claim` collects the provably dead.** Reaping is not a verb anyone remembers
   to run, so `claim` runs it, before recording itself and before evaluating
   peers — the exit status a session acts on then describes the field as it is,
   not as a departed session left it. This does not weaken rule 7: a claim may
   only OBSERVE a record it has not seen before, and collects only on a later
   claim a full TTL afterwards with the bytes unchanged throughout, so a
   suspended or mid-write session is never taken. A reap that cannot run leaves
   every record in place. Its output goes to stderr, so claim's stdout stays the
   `claimed:`/`peer:` contract that callers parse. Collection is not instant
   release: the nonce tombstone still reads as a peer until the cover ages out.
7. **Fail closed.** Corrupt records, foreign hosts, unverifiable pids, an
   unwritable sessions dir, and freshly-reaped covers all read as peers.
   Staleness alone never implies death (suspend); only `expire`'s two-pass
   byte-identical reap with confident-death evidence removes another session's
   record, and its nonce tombstones shield the transition. The one documented
   residual and its exact preconditions live in INTERNALS.

## Worktrees & branches

Loops often run in a `git worktree` (one per concurrent session). Two rules
keep that safe:

**Message routing is worktree-safe.** Every helper resolves `.comms/` to the **main repo
root** via `git worktree list`, so all worktrees of one repo share a single mailbox. The
`head_sha` is STAMPED BY THE HELPER at send time — for loop messages it is the retained
artifact's base commit (artifact_id and head_sha come out of one snapshot operation, so
a concurrent commit in a shared checkout cannot desync them); for consults it is live
HEAD at send. A hand-typed value is overwritten. Drivers never type a SHA.

**A managed worktree's identity is pinned.** `worktree new` pins the workspace name the new
tree resolves to at creation in that tree's own git admin dir, so a later `git branch -m` there
cannot re-key its thread state under a second file. Only the repo pin (`workspace set`)
outranks it. See [INTERNALS](INTERNALS.md#workspace-resolution).

`cwd:` is the per-message "which tree" hint; `head_sha:` is the immutable fallback when
that path or branch was repurposed before a delayed delivery. Readers enter `cwd`, compare
the current HEAD when `head_sha` is present, and locate the recorded commit/worktree
instead of silently reviewing unrelated contents.

**The artifact is the tree the request names.** `send` and `panel dispatch` snapshot the tree
they run in, so a `review-request` whose `cwd:` or `branch:` names a different tree is REFUSED
before anything is written, with both trees named and the command to re-run from the right one.
Send a request from the tree it was written in — for a lane worktree, from inside that worktree.
A request with neither field is snapshotted from wherever it is sent, as before. The
`workspace:` field is not a tree: a mismatch there still only warns.

A `review-feedback` reply is the same artifact as the request it answers. The parent
copies `artifact_id`/`head_sha` onto the stamped envelope; `send` inherits them from
`--archive-inbound` or `in-reply-to` when the reply omitted them, and refuses a
mismatch. `--archive-inbound` and `in-reply-to` must name the same request; an
identity-bearing reply whose request cannot be resolved is refused rather than
skipping validation. A reply is never snapshotted into a new artifact — that would
make round 2 review a newer SHA than the request the moment the author committed.

**Push safety — create worktrees on their own branch, never on `main`.** The common
footgun: an agent working in a worktree runs `git push` and it lands on `main` instead of
the feature branch (because the worktree was checked out on `main`, or the branch was set
to track/push to `main`). When creating a worktree for a loop:

- **Make a dedicated branch, don't check out `main`:** `git worktree add -b <feature-branch> <path>`
  (`-b` starts a fresh branch with **no upstream** — keep it that way; never set its
  upstream to `main`).
- **Keep a bare `git push` from straying to `main`:** `git config push.default current`
  so `git push` only ever updates a remote branch of the *same name* as the current one
  (combined with the rule above — never be checked out on `main` in a loop worktree — this
  means a feature-branch push can't land on `main`).
- **First push is explicit and self-scoped:** `git push -u origin HEAD` (pushes the current
  branch to a same-named remote branch and sets its upstream). Never
  `git push origin <x>:main`, and never push while the worktree is checked out on `main`.

**Retirement is explicit, never a side effect.** `integrate` lands the branch and leaves the
worktree and branch in place. The `/auto` driver's last step (and AGENTS.md review-loop step
6) retires its OWN worktree once `integrate` exits 0 with `integrate-result v1 status=landed`:
from the main checkout, with its presence inline so retire recognises it as the owner, then
releases presence. Every gate below still applies; a refusal is reported in retire's own words
about what was removed or left, and does not fail the loop. A session that worked in the shared checkout has
nothing to retire. `comms.sh worktree
list` reports every registered worktree on one `worktree-list v1` line — kind, branch, whether
the tip is on `main` (by ancestry, `git cherry`, or squash patch-id), tracked and untracked
dirt, ignored content off the regenerable list, secret-named files, nested repositories,
processes with a cwd or open file inside (one `lsof` snapshot), presence and lock — and the
retire verdict. `comms.sh worktree retire <branch>` acts on ONE target, re-enumerated from git
at that moment, and is a dry run unless `--yes`. It refuses unless every gate holds:

| Gate | Refuses when |
|---|---|
| kind | the tree is the primary checkout, a review mount (use `clean mounts`), or not managed (`worktree-<slug>` at `.claude/worktrees/<slug>`, no symlinked component) |
| landed | the tip is not on `main` by ANCESTRY; cherry- and squash-equivalence are reported, never accepted |
| clean | any tracked change or untracked path, including edits hidden by skip-worktree or assume-unchanged (raw bytes, exact link text and mode compared to `HEAD`; a clean filter or autocrlf difference refuses rather than hides) |
| ignored | ignored content not on the regenerable list (`node_modules/`, build output, caches, husky's `.husky/_/` and the files git lists inside it, `*.tsbuildinfo` files — directory names match directories only, and a file git lists individually inside a generic-named directory such as `build/` is judged on its own), a secret-named file (`.env*`, keys, credentials), or a nested repository anywhere (a `.git`, or a bare repo's `HEAD` beside `objects/` and `refs/`) |
| private refs | a per-worktree ref (`refs/worktree/*`, `refs/bisect/*`, `refs/rewritten/*`) names history not on `main` — removal deletes it |
| backend | the repository's ref storage is not `files` (e.g. reftable): the gates read the files layout and are not guessed elsewhere |
| unused | a process has its cwd or an open file inside, or processes cannot be listed; or the caller stands in it |
| unclaimed | a live or ambiguous presence record owns it (the owner stamp `worktree new` writes, or a record named like the slug — matched by filename, so an unreadable record still blocks) and is not the caller's own; or git has it locked |
| ref | the branch is a symbolic ref; a paused rebase, bisect or `rebase --update-refs` reservation in any worktree holds it; an am, cherry-pick, revert, merge, sequencer or notes merge is in progress on it; or that operation state exists but cannot be read |

Removal is `git worktree remove` without `--force`, then `update-ref -d` with the checked tip
as the old value and `--no-deref` — a compare-and-swap, never `git branch -d`, which asks "merged into HEAD?"
rather than "on main?". A branch advanced after the worktree was removed is left in place
(exit 4); any other delete failure exits 1, and both say whether the worktree was removed. A
branch with no worktree is retired by the landed and ref gates alone. The ref gate is
re-checked immediately before removal. Residuals, stated rather than hidden: an ignored file or
an operation started between that last check and `git worktree remove` is lost, and the
worktree's HEAD reflog is deleted with it (gating on the reflog would block every tree that ever
amended a commit). Every probe that
cannot answer is a refusal.

## Filenames

```
<workspace>_<YYYY-MM-DDTHH-MM-SS>_<slug>-<random>.md
```

- `workspace` scopes messages when several workspaces share one repo. Resolution:
  the repo-scoped PIN (`.comms/workspace`, written by `comms.sh workspace set`) →
  explicit pin → git branch → repo dir, lowercased/hyphenated — both sides
  resolve via the same `comms.sh workspace` so they can never disagree, and the pin
  makes the identity an explicit decision rather than an inference
- the `<random>` suffix prevents same-second collisions
- readers list with `comms.sh list --as <agent>`, newest first

## Frontmatter

```markdown
---
type: review-request            # see the type table in loopspec/SPEC.md
from: claude                    # a REGISTERED identity; a review twin only on review-feedback
timestamp: 2026-06-04T18:30:14Z
branch: main
head_sha: <stamped by send>     # the artifact's base commit — helper-stamped, never hand-typed
workspace: agent-comms
cwd: /path/to/working/dir       # worktree hint — reader cds here before touching files
message_id: <filename sans .md>
thread: rate-limiter-9331       # names the loop; constant across ALL its messages
in-reply-to: <message_id>       # when replying
workflow: auto                  # presence triggers autonomous mode (value is free-form)
phase: plan | implement
round: 2
max-rounds: 4
verdict: APPROVE | REQUEST_CHANGES   # reviewer replies only; read normalized
route_decision: <stamped by send>    # reviewer routing only (COMMS_REVIEW_ROUTE=1); helper-stamped,
                                     # stripped everywhere else, never shown to the reviewer
review_provider: claude              # review twins only; helper-stamped, never hand-typed
---
```

`review_provider` names a provider, and which one depends on direction:

- **On a `review-request` or an `error`** it is the RECIPIENT's provider — both start a review
  turn at a review twin (the error lane asks it to answer again). `send` stamps it on either
  when the target is a twin (its driver's provider) and strips a hand-typed value when the
  target is a driver, so driver-bound messages stay byte-identical. `shadow` stamps its private
  request copy for the shadow's own target. `validate` only checks that a present value is a
  single supported provider — a `codex`-authored request to `claude-review` stamped `claude`
  is valid.
- **At execution** runphase refuses a twin's turn whose inbound `review_provider` is absent or
  differs from the provider the twin runs on (`result.json` note: "… was bound to provider …").
  A twin's provider is fixed, so a mismatch is a forged or hand-edited stamp, or a request left
  over from the retired `review-agents` config, which could map a name onto another provider:
  the leg fails closed — it reads unanswered — rather than running one model under a name that
  claims another.
- **On a `review-feedback`** it is the SENDER's provider, stamped by the broker on a twin's
  reply. `validate` requires it there and requires it to equal the twin's own provider — a
  `claude-review` reply stamped `codex` is refused ("claims review_provider 'codex', but
  'claude-review' runs on 'claude'"). A driver's reply may carry no stamp or its own name,
  nothing else. This stamp is what `compose` counts.

**Validation rules, message types, verdict semantics, and the loop invariants are
normative in [loopspec/SPEC.md](loopspec/SPEC.md)** — enforced here by
`comms.sh validate` (run by `send` before any delivery). agent-comms specifics on top
of the contract:

- Read verdicts through `comms.sh verdict <file>` — it normalizes (trim, uppercase)
  and maps the canonical synonyms (`pass` → `APPROVE`, `fail` → `REQUEST_CHANGES`),
  so `verdict:  approve ` or `verdict: fail` still steer a loop correctly.
- The reviewer-must-carry-a-verdict rule binds by TYPE — every workflow
  `review-feedback` message needs a `verdict`, whichever agent sent it (reverse-
  topology loops have Claude as the reviewer).
- On final `APPROVE`: un-actioned advisories append to `docs/advisories.md` and
  `### Process` feedback to the friction log; `comms.sh state complete <thread>`
  closes the loop's state.
- **Findings are markdown list items** (`- `, `* `, `1. `), one per finding, and a
  `### Blocking` / `### Advisory` subsection holds nothing else (a bare `None.` is the
  empty form). This is load-bearing, not style: when a reply omits its `VERDICT:` line the
  parent DERIVES the verdict from the blocking count, so a finding written any other way
  extracts as zero and the derivation reads that zero as consent. A lane carrying lines the
  parser cannot classify is now COUNTED as unread. A lane with **no** parsed findings and
  unread residue is a failed read, not a clean review: the broker refuses to derive or stamp
  an `APPROVE` over it, and `compose` refuses to gate on it — including for a self-authored
  envelope, which never passes through the broker. A lane with real findings *and* residue
  only warns, naming the leg whose counts are short. Silence and consent are different
  statements; the pipeline can finally tell them apart.
- **Lazy continuation is deliberately not supported.** In CommonMark an unindented line can
  continue the preceding list item; here it is counted as residue instead. That is a
  narrowing on purpose — honouring lazy continuation would fold a real finding written after
  a `- None.` placeholder into that placeholder as one claim, which is the false all-clear
  this rule exists to prevent. Indent a continuation line, or make it its own list item.

## Threading

`thread` exists because two agents can run loops in the **same workspace**
simultaneously — without it, "read the newest message" lets one loop consume and
archive the other's review round (observed in the field). The threading rules
(opener mints the thread; every message copies it; `message_id`/`in-reply-to` chain
reconstruction) are in [loopspec/SPEC.md](loopspec/SPEC.md); operationally, continue
a specific loop with `comms.sh list --as <agent> --thread <t>`.

## State files

`comms.sh send` automatically writes `.comms/state/<workspace>_<thread>.json` for any
workflow message (filename components sanitized to `[A-Za-z0-9._-]`; workspace is the
**resolved** name, not the frontmatter copy, so readers and writers can't diverge):

```json
{
  "workspace": "agent-comms",
  "thread": "rate-limiter-9331",
  "workflow": "auto",
  "phase": "implement",
  "round": "2",
  "max_rounds": "10",
  "status": "in-progress",          // → "complete" via `state complete <thread>`,
                                    // or "legacy" via `state legacy <id>` (idle, named)
  "awaiting_from": "codex",         // who owes the next message; "none" when complete/legacy
  "awaiting_since": "2026-06-04T18:30:14Z",
  "awaiting_since_epoch": "1780597814",
  "last_sent": "<message_id>",
  "last_notified_at": "2026-06-04T18:30:16Z", // external recovery only
  "last_delivery": "delivered"      // delivered | manual | failed | blocked
                                    // headless adds: spawned → completed | failed
                                    // | timeout, plus held and pickup (see
                                    // loopspec/thread-state.schema.json for the
                                    // full enum)
}
```

Headless turns (see [Headless delivery](#headless-delivery-experimental)) add fields:
`last_run_dir` (written by `send` at spawn time — the watchdog's pid target) and, on
exit, the provider session id — `codex_thread_id` or `claude_session_id`, captured
from the turn's event log and printed by `runphase.sh hold` as the attach command.
Note the state copies are transient: the next round's `send` rewrites the state file
and drops them. The durable copy lives in the run dir's `result.json`; treat the state
fields as observability and attach plumbing, not yet as automatic cross-round resume
(that is a planned opt-in, not wired).

State is **advisory ground truth**: it survives compaction/restarts, records and
surfaces the loop's round/max-rounds and loop-rounds budget (enforcement itself happens
in the reading agent's flow, from message frontmatter), and gives any dashboard a
source of truth beyond pane titles — but a state write failure can never block the
message flow (writes are non-fatal by construction).

Inspection: `comms.sh state list | get <thread> | complete <thread> | retired <thread>`, and
`comms.sh stalled [minutes]` lists threads awaiting a reply longer than the threshold
(default 15m) and marks a matching file still in the target inbox as `inbox=unread`.
That persisted-file evidence outranks a prior notification result.

**Idle threads are marked, never closed by age.** `comms.sh state idle [--days N]` reports,
across every workspace, the threads that are neither complete nor legacy and have had no state
change and no message on the thread for N days (default 14); it changes nothing.
`comms.sh state legacy [--days N] <id>...` marks only the ids the operator names, re-judging
each at marking time and refusing any that is not idle, and writes the evidence and the prior
status into the state file (`legacy_*` fields). A legacy thread leaves `stalled` and the status
shout; it is not `complete`, and the next `send` on it resumes it as in-progress.

**Retirement is the caller's, and it is the only thing that frees a thread's review copies.**
`complete`, `legacy`, an idle thread, an exited queue owner and an old timestamp each describe a
round that is not running NOW — which is also what a paused or resumable loop between rounds
looks like. None of them may authorize deleting that thread's warm mounts. Whoever owns the
loop's lifecycle records the terminal decision explicitly: `comms.sh state retire <thread>`
(Basis does this for a terminal task; `state unretire` withdraws it for a reopened one). The
record lives in `.comms/state/retired/`, keyed on a digest of the RAW thread — never `safe_name`
alone, which maps `a/b` and `a_b` to one name — and holds the thread for an exact comparison.
`comms.sh clean mounts --thread <thread> [--yes]` then removes exactly the copies that thread
provably owns (its direct turns' mount, its panel legs' mounts, and a crashed run's throwaway),
refuses a held thread, and never touches another thread's mount or anything under `.comms/`.
Cleanup is separate from landing: it can be run after it, fail, and be re-run (exit 3 = retry
later; 4 = a human must look). See COMMANDS.md for the gates and the result lines.

## Coordinator event log

`.comms/events.tsv` is the coordinator's own append-only record of what IT did. It is not
the mailbox (that is the wire the reviewed agent writes on) and not ACP (a session is not a
record). Every row is written by `comms.sh events append`, the single writer; nothing else
formats a row.

```
ts  workspace  event  review_set  dispatch  thread  round  agent  role  artifact_id  request_id  message_id  run_dir  status  note
```

File order **is** the sequence — `ts` is for humans, not for sorting. `agent` names the
LEG's reviewer (the target of a request, the author of a reply), never the send target. It is
the IDENTITY (`claude-review`), never the provider it ran on; a review twin's
`turn-started` note carries `provider=claude agent=claude-review`.
`role` is `gating` or `shadow`; a `--no-deliver` measurement turn is recorded and is
structurally distinguishable from the leg that gates.

The attempt a reader binds to is the one named by the LAST `panel-planned` for the set — the
plan rows are written before any leg goes out, one per PLANNED REVIEWER sharing a single
attempt id, so they are the only record of which roster is in progress. (One row per reviewer,
not one per fan-out: a roster that lives in a single row's note is a roster nothing can
enforce, which is how a driver dying between two leg rows once gated as a complete panel.) A dispatch preserves earlier attempts' index rows rather than
replacing them, and readers filter.

Sets recorded before attempts existed have no plan event and still bind the old way, from
their index rows — so every reader needs a way to tell "no attempt was ever planned" from
"an attempt was planned and its record is gone". The index cannot answer that: an attempt
that dies between its plan and its first leg row leaves rows shaped exactly like a legacy
set's, and reading them as legacy composes the PREVIOUS round's bound replies while
silently discarding the newer attempt. So `panel dispatch` stakes an empty marker file at
`.comms/grades/attempts/<review_set_id>` before anything else it writes — before the plan
events, before the legs, before the index rows. **The marker, not the shape of the index
rows, is what settles whether a set is legacy.** Its absence means no attempt was ever
planned here; its presence with no readable plan means UNKNOWN, and the readers that GATE —
`compose` and `panel status --set` — refuse rather than degrading to the legacy path.

One reader deliberately does not: the BARE `panel status` listing. It counts the legs of
whatever attempt the plan events name, and with no readable plan that is the empty attempt —
so for a crashed set it still prints the previous round's leg count. That is the surface a
driver reaches for after losing its set id, so read it as a directory, never as a verdict:
re-run `panel status --set <id>` on anything it lists before acting, and that call will refuse.
The listing gates nothing, which is why it is allowed to stay lossy rather than grow a refusal
that would make an inventory command fail on one bad row.

**The un-wedge, because the refusal is permanent and there is no `panel forget`.** A set whose
marker is present and whose log is legitimately gone — pruned, archived, never recoverable — is
UNKNOWN forever, and `compose --set` and `panel status --set` will refuse it every time. The
operator's recovery is to delete the marker (`rm .comms/grades/attempts/<review_set_id>`), which
demotes the set to legacy and lets it bind from its index rows again. Do that only when you know
no newer attempt is being discarded: deleting the marker is exactly the state the marker exists
to distinguish, so it trades a loud refusal for the silent misread. Losing the marker is quiet;
losing the index is loud. Re-dispatching the round is usually the better answer.

**Treat `grades/attempts/` as inseparable from `grades/sets.tsv`.** The marker check is
deliberately fail-OPEN in one direction: a marker that is missing or unreadable falls through
to the old index-shape inference, so a set that loses only its marker — while keeping stale
legacy-shaped rows and no readable log — can recreate the false-legacy composition. Nothing in
this repository removes markers, so reaching that state needs out-of-band corruption; the rule
that keeps it out of reach is that anything which copies, backs up, restores, prunes or
relocates one of those two paths must do the same to the other. Copy `sets.tsv` without
`attempts/` and every set in it silently becomes legacy.

`dispatch` is the ATTEMPT id, and it is what makes a retry readable. A `review_set` id is
deterministic — same thread, phase, round and artifact produce the same one — and a retry
deliberately rebinds the set's rows, so two concurrent attempts would otherwise interleave
in one file with nothing to separate them. `panel dispatch` mints one id per fan-out,
stamps it on every leg's frontmatter (`dispatch:`), and every event of that attempt carries
it. **The last `panel-planned` for a set, by file order, is the current attempt; an event
belongs to the attempt its `dispatch` names.** A bare `send` (no panel) carries no dispatch
id — an empty column means "not a panel attempt", never "attempt unknown". `request_id`
binds a reply to the request it answers (`in-reply-to`); a re-send of the same request
appends another `request-persisted`, and the LAST pair for that request id is the live one.

One consequence of that, worth knowing before it looks like a bug: a self-send turn records
no `dispatch` on its reply, and the runner's acceptance check joins on the reply id it minted,
so a legacy self-send leg can finish `turn-finished log-incomplete` even though its reply
arrived. Conservative by design — the arm is scheduled for deletion, not extension.

Two exceptions to "every event of an attempt carries its `dispatch`", both deliberate: a
bare `send` outside a panel has no attempt to name, and the legacy self-send arm copies
`review_set` onto its reply but not `dispatch`, so its `reply-accepted` carries none. That
arm is scheduled for deletion rather than extension.

A `question` never enters the request lifecycle: consults are recorded as
`message-dispatched` and nothing more, because nothing in this log completes them.

The lifecycle, in the order it is written:

| event | written by | means |
|---|---|---|
| `panel-planned` | `panel dispatch`, before any leg | the roster this set expects |
| `request-persisted` | `send`, after validation, before any nudge | the request exists on disk |
| `request-dispatched` | `send`, after delivery | how the nudge actually went (`status` = outcome) |
| `message-dispatched` | `send`, for consults and anything not a loop turn | |
| `turn-started` | the detached runner | a provider turn is running |
| `provider-result` | the runner, where the provider exits | the CLI's own result, before brokering |
| `reply-validated` | the broker | a stamped reply passed validation (`status` = verdict) |
| `reply-refused` | the broker | it refused to STAMP, and why (`note`) |
| `reply-accepted` | `send`, for a reply | the reply reached the driver's inbox (`status` = verdict) |
| `turn-finished` | the runner (or `await`, for a runner that died) | the TURN's terminal status, which differs from the provider's; `log-incomplete` when an event this turn produced never reached the log; the note opens `exit=N reason=R` when the turn recorded a reason |
| `composition-completed` / `composition-refused` | `compose` | the gate ran, or refused a partial/unreadable panel or two answers from one provider (`duplicate-provider`) |

Read it with
`comms.sh events [--set S] [--dispatch D] [--thread T] [--kind K] [--agent A] [--limit N]`.
Filters apply before the limit, so `--set X --limit 1` is the newest row of THAT set. A row
that is not a well-formed event — a torn write, a hand-edit, an unknown kind — is counted
and named on stderr rather than parsed.

**Not every route produces every event.** The strict order
`turn-started -> provider-result -> reply-* -> turn-finished` is the ACP/brokered path. On
the self-send arm the child sends its own reply before exiting, so `reply-accepted` precedes
`provider-result`, and `reply-validated` / `reply-refused` never appear at all (no broker
runs). A turn that fails before the provider starts — mount claim refused, artifact
unresolvable, prompt build — has a `turn-finished` and no `provider-result`. A shadow turn
validates and never accepts. Read the log per route, not against one canonical shape.

The log must live on a local filesystem, and EVERY append checks: the type of the actual
append target is matched against an allowlist of known-local filesystems, and anything else —
NFS, SMB, a network FUSE mount, or a type nothing can classify — is refused. (NFS simulates
`O_APPEND` and can drop a whole append, leaving a well-formed file with an event missing: a
loss no reader can detect, which is why this is a refusal and not a warning.) A refusal
returns; it never takes down the process that was appending.

### Recovering a loop from the log

After a driver dies, `comms.sh events --set <id>` answers what to do next:

- a leg named by `panel-planned` with **no `request-dispatched`** — it never went out; re-send it.
- **two `turn-finished` rows for one run dir** — the runner recorded its terminal event, died
  before publishing `result.json`, and `await` synthesized one. The later row is authoritative.
- **`turn-started` with no `provider-result`** — it may still be running or have been killed;
  inspect its `run_dir`. Do not re-spawn blind (the mount claim refuses a second owner anyway).
- **`reply-refused`**, or a failed/timeout `turn-finished` with no `reply-accepted` — do not
  compose; re-dispatch that leg or escalate, using the `note` as the reason.
- **`reply-validated` with no `reply-accepted`** — do NOT re-dispatch. The stamped body is in
  `<run_dir>/reply.md` and may already be in the inbox; compose may simply succeed.
- **every planned leg `reply-accepted`, no `composition-*`** — compose now. "Planned" means
  named by a `panel-planned` row of the current attempt, not merely present in the index: a
  dispatch that died between two leg rows leaves the index short, and `compose` refuses that
  gap rather than gating a truncated roster.
- The bare `panel status` listing is a RECOVERY LISTING, not a gate. It skips rows it cannot
  read and can therefore show a previous attempt's `legs` while `--set` and `compose` refuse
  outright. Read it to find sets; read `--set` to decide anything.
- **`role=shadow` rows** — drop them first. A measurement turn shares its gating leg's thread
  and attempt, so leaving it in makes a shadow look like the leg that gates. `events --role
  gating` does this for you.
- **`composition-refused`** — a human decides; `status` says whether the panel was partial or
  a leg was unreadable. `duplicate-provider` means two counted replies came from one provider
  (the `note` names the legs): re-dispatch with one reviewer per provider.

Two corroborations belong in that walk, because the log alone cannot settle them: the
MAILBOX decides compose-versus-re-dispatch (a reply already in the inbox needs no new turn),
and the run dir's `pid` decides running-versus-dead. A missing `panel-planned` with N
`request-persisted` rows means **roster unknown** — never "N was the whole panel".

`panel dispatch` fails closed on the roster event and on each leg's `request-persisted`, so
a dispatch can exit non-zero with earlier legs already in flight. Await those run dirs
before re-dispatching the set; a re-dispatch mints a new attempt id and the old legs' events
stay readable under the old one.

One rule governs all of it: **the absence of a runner-side event means UNKNOWN, never "it did
not happen".** Everything the runner writes is advisory (a turn that produced a valid reply is
never killed to record an event about it), so a consumer that reads absence as proof will
re-dispatch a leg that was already paid for. The one thing that is never ambiguous is a
`turn-finished log-incomplete`: that turn is telling you its own trace has a hole.

## Delivery

`comms.sh deliver <target>` hands the message to a RUNNER. There is no pane and no surface
picking: the cmux transport was deleted in step 4 (S4-4) because a keystroke nudge is
self-send by another name — it tells a live agent to read and reply itself, with no parent
stamping and no pinned artifact.

The routing decision belongs to `comms.sh transport`, which is the single decision point:

- **acp** — the default for every provider. The parent brokers the reply.
- **headless** — a detached runner, **grok only**.
- **mailbox** — the honest outcome when no runner can take it: the file is on disk and
  nobody was nudged. This is a SUCCESS when it was asked for, not a broken install.

**Pickup is resolved before transport.** A reply addressed to the session driving the current
turn needs no nudge at all — it is read when the turn exits — so `deliver` short-circuits on
`COMMS_HEADLESS_PICKUP` ahead of the routing decision. Asking the transport question first was
a live bug: an inherited `COMMS_DELIVERY=headless` made the routing gate refuse before pickup
was consulted, killing the broker's own send while the already-copied reply made the turn look
answered. (grok, S4-2 r3.)

`comms.sh status` adds an `ACTION NEEDED` line whenever the newest thread's last delivery
wasn't a real nudge.

Outcomes recorded in state by `send` (the full enum lives in
`loopspec/thread-state.schema.json`. `delivered` and `blocked` are retained ONLY for reading
ARCHIVED state written before step 4 and have no emitter left; `failed` is still produced — a
headless spawn failure emits it):

| outcome | meaning | recovery |
|---|---|---|
| `pickup` | the reply is for the driving session; it reads it when this turn ends | none needed |
| `manual` | no runner available — message valid on disk | trigger the read command by hand |
| `spawned` | a peer turn is running detached; the reply lands in the inbox when it exits | await the printed run dir |

**Atomic send:** `comms.sh send --to <agent> <file> --archive-inbound <inbound>`
validates the outbound (refusing to deliver or archive if malformed), attempts delivery,
records state, and only then archives the inbound. A failed nudge still archives — the
inbound *was* processed; the retry surface is delivery, tracked in state.

`send` always ends with a `RESULT:` line. The `RECOVER:` mechanism and `comms.sh reconcile`
went with the cmux transport (S4-4): there is no socket left to be blocked on. A sandboxed
session that cannot deliver must not run the same path repeatedly or claim the peer passively
polls — use one manual pickup for the already-persisted message.

**Identity resilience:** workspace identity comes from an explicit `.comms/workspace` pin if
one exists, otherwise from the branch name, otherwise the repository directory name. The cmux
title cache and its decorated-title guard are gone (S4-4). One rule survives from that design
and is load-bearing: the `main` branch resolves to `main`, NOT to the repository directory
name — substituting the directory name there would change every message-filename prefix and
hide pending messages and thread state behind the glob.

**Late reads are normal.** A reply can be consumed before the reader that was told about it
gets there (e.g. by a file watcher, or by a driver picking it up when its turn ends), so a
later `/read-from-codex` finds an empty inbox; readers report "latest archived: X — already
processed" instead of a confusing "no messages". The keystroke-injection version of this —
a nudge queued in a pane's input box — went with cmux in step 4; the empty-inbox case did not.
That archive hint is filtered by workspace, reader direction, and optional thread, then
ordered by protocol timestamp with mtime fallback; an unrelated older round cannot win
because of filename order.

## Headless delivery (experimental)

`COMMS_DELIVERY=headless` replaces the keystroke nudge with a detached subprocess:
`deliver <target>` hands the message to `runphase.sh`, which spawns the target
provider's CLI in the background — since step 4 that is `grok` alone; the Codex
(`codex exec --json`) and Claude (`claude -p`) direct arms were DELETED — records the run under
`.comms/logs/<message_id>.<epoch>.<pid>/` (`prompt.md`, `events.ndjson` JSONL event
log, `result.json`, `pid`, `runner.log`, and for ACP turns `policy.tsv` + `turn.tsv` — the
per-turn policy record and the requested/adapter/observed ledger), and mirrors the outcome into thread state
on exit. Identity is a process handle, not a pane guess.
A loop is unattended work and should not require an open pane. **Since step 4 (2026-09-01), claude
and codex review turns are ACP-ONLY**: the self-send path they used on the headless transport was
deleted, so a non-ACP turn for those providers fails closed rather than degrading — it would
otherwise produce an unstamped, unmounted reply that still reported success. Headless survives for
**grok only**, which is parent-brokered on its direct path. When ACP is unavailable for claude or
codex the honest outcome is `mailbox` (written, nobody nudged); a loop is never silently routed to
a pane, because a pane nudge is the same self-send model under another name. Repair ACP rather
than reaching for headless. Consults follow the same rule.

**Direction awareness.** Replies TO the driving session are a designed no-op: the
driver reads them when the peer turn exits, so nothing is spawned for that
direction. runphase marks it by exporting `COMMS_HEADLESS_PICKUP=<driver>` into the
child's environment; `deliver` no-ops when the target matches. Either agent can drive, but the SPAWNED side is grok: a Claude or Codex session
sending to grok spawns a headless grok turn whose replies are picked up. The symmetric
"headless Codex turn" / "headless Claude turn" this example used to describe is REFUSED
since step 4 — those providers are reached over ACP, where the parent brokers the reply.
The pickup rule itself is transport-independent and is resolved in `deliver` BEFORE
transport selection, so an inherited `COMMS_DELIVERY=headless` cannot make the
reply-to-driver direction fail. (grok, S4-2 r3, blocking.)

**Claude turns over ACP** are mode-pinned by the ACP backend (`claude-plan`), which sets the
permission mode on the session itself. The `CLAUDECODE` unset and the
`--permission-mode` / `--allowedTools` / `COMMS_RUNPHASE_CLAUDE_*` knobs below describe the
DELETED direct arm and no longer drive a live turn; they are retained as history because the
bypass refusal they document still applies to any future direct arm:
`--permission-mode acceptEdits --allowedTools Bash` by default, overridable via
`COMMS_RUNPHASE_CLAUDE_PERMISSION_MODE` / `COMMS_RUNPHASE_CLAUDE_ALLOWED_TOOLS` /
`COMMS_RUNPHASE_CLAUDE_ARGS`. Bypass/danger permission flags
(`--dangerously-skip-permissions`, `bypassPermissions`) are **refused** in loop
turns by policy: a novel permission need surfaces as a failed turn and gets a
scoped policy addition, never a blanket bypass.

Additional delivery outcomes in headless mode:

| outcome | meaning | recovery |
|---|---|---|
| `spawned` | peer turn running detached | `runphase.sh await <run-dir>`; reply appears in the inbox when it exits |
| `completed` | turn exited 0; reply should be in the inbox | read it |
| `failed` | provider CLI exited non-zero, or the runner aborted (its exit trap still records the failure) | **`panel status --set <id>` FIRST — a failed turn may already have delivered its reply**; only then inspect `events.ndjson`/`runner.log` and re-send |
| `timeout` | turn killed after `COMMS_RUNPHASE_TIMEOUT_SECS` (default 1800) | **`panel status --set <id>` first, same reason** — a turn can have its reply written and then be killed; then raise the limit or investigate, and re-send |
| `held` | a hold marker paused the thread; nothing spawned | `runphase.sh release <thread>`, then re-send |
| `pickup` | designed no-op: a peer turn's reply to its driving session (`RESULT:` still reads `manual — …picks it up…` for the peer's expectations) | none — the driver reads the reply when the turn exits |

A runner killed with `kill -9` can write nothing, so state stays `spawned` forever; the
surfaces for that residual are `runphase.sh await` (detects the dead pid and says so)
and `comms.sh stalled`, whose **watchdog** uses the `last_run_dir` recorded in state to
distinguish "runner alive — still working", "turn finished — reply may be unread", and
"runner DEAD without a result — re-send to retry". Re-delivery is guarded: `deliver`
for a message whose runner is still alive reports "already running" and points at the
existing run dir instead of double-spawning a concurrent turn; a dead runner without a
result is retryable as usual.

**Pause/attach (hold).** `runphase.sh hold <thread>` (or `hold` with no argument for
everything) blocks NEW turns at the next turn boundary — in-flight turns finish — and
prints the exact attach commands recorded in thread state (`claude --resume
<claude_session_id>` from the loop's cwd; `codex resume <codex_thread_id>`). Sends on
a held thread report `RESULT: held`; after `release`, RE-SEND rather than bare-deliver
so state moves off `held`. Two scoping notes: per-thread holds do not block
thread-less one-shot messages (use the no-argument hold for a full stop), and bare
`deliver` resolves only the newest pending message — a held thread's newest message
shadows retries for other threads, so pass an explicit file to retry a specific one.

The spawned peer is pre-briefed that its reply `send` reports a deliberate pickup
(`RESULT: manual` on a mailbox route) and that this is expected — the driving session
picks the reply up when the turn ends.

**The inbox is the system of record; an await is only a convenience.** Where a conforming
reply is produced at all, it is written into the DRIVER's inbox by the detached runner
before `result.json` exists — the broker copies and sends it, every route being
parent-brokered since step 4 — so a driver that dies mid-turn loses its await, never the
reply. Two limits on that guarantee, both by design. A `failed`, `timeout` or aborted turn **may**
have no reply, because there may be no verdict to persist — but "failed" does not imply
"nothing arrived": the broker writes the reply into the inbox *before* it sends, so a send
that fails afterwards records `failed` with the reply already there, and a turn can be
killed after its reply landed. **Check `panel status` before re-sending
ANY non-completed turn** — `failed`, `timeout` or aborted alike — or a round is paid for
twice. A turn can have its reply written and *then* be killed or trip its exit trap, so the
outcome label describes how the turn ended, never whether a verdict arrived. Second — and this
is now HISTORICAL — the deleted self-send route marked a turn `completed` from the child's exit
status alone, so a child that exited 0 without sending yielded a completed result and an empty
inbox. Step 4 removed that route precisely because of this hole; every surviving route is
parent-brokered, and the parent performs the write itself. Recovery is
therefore a read, not a re-run: `comms.sh panel status` with no `--set` lists the review
sets from the durable append-only index, `panel status --set <id>` shows each leg's reply
and verdict, and `compose --set <id>` gates. Both readers scan the archive and **every
registered agent's inbox**, so which agent drove the panel does not change what they can
see; a leg is answered by the round + `in-reply-to` + `type` + validation binding, never by
the directory a message arrived in.

**A reviewer that cannot answer at all.** Quota exhaustion, an outage, or a provider with no
verified isolation backend all end the same way: the child exits non-zero having produced
zero bytes, and the provider says nothing about why — the case this was built against
reported only `RUNTIME QUEUE_RUNTIME_PROMPT_FAILED Internal error`. The runner therefore
records what it OBSERVED, not a diagnosis: `reason: no-output` in `result.json` and on the
`provider-result` event. One refinement: a provider whose refusals have a stable wording is
classified from the diagnostics acpx relayed on stderr (never from the reply), and the turn is
recorded under that reason instead — gemini's are `rate-limited` (a 429 / `RESOURCE_EXHAUSTED` /
exhausted quota) and `auth-failed` (`Authentication required`, `UNAUTHENTICATED`, an invalid key),
on a refused canary, a refused review prompt or a session that could not be created, with a note that
says what to do (wait for the limit to reset; log in again). Like the `canary-*` refusals they are
retry-and-fix conditions: `compose --degrade` does not treat them as droppable-leg evidence. That is a fact about the ROSTER, distinct from a reply that arrived
and failed the verdict contract, which is a fact about the REVIEW.

A reviewer whose review can never be PUBLISHED is the same roster fact. When the broker
cannot attest the model/effort a turn actually ran, it withholds the reply unpublished
(`reason: policy-unapplied`) — the provider exited clean, so the `provider-result` says
`completed`, and the evidence lives on the turn's own terminal row instead:
`turn-finished failed` with `exit=N reason=policy-unapplied` at the head of its note. A failed
`turn-finished` written through `result.json` carries its `reason=` there, in that anchored
position, so nothing later in the row (a session id, a free-text refusal message) can forge it.
A `log-incomplete` row (`turn=<status> exit=N reason=R ...`) never ADDS evidence, because its
own trace has a hole: a policy refusal whose trace lost an event is not droppable. It does close
its run, so a `reason=no-output` that run's `provider-result` already recorded still stands. This covers every
`policy-unapplied` refusal, including the pre-prompt ones (a preflight mismatch, a policy
record that changed, a rollout snapshot that failed), so the banner says the policy "could not
be applied or attested", never that the review ran. The other refusal reasons — `containment-unconfirmed`, `runtime-incompatible`,
`canary-*` — are conditions to fix and retry, and stay undroppable.

`compose` still refuses such a panel by default, because a missing voice is not an approval.
An operator — never the driver on its own judgement — may then drop the leg with
`compose --set <id> --degrade <agent>`. It is gated on evidence, not on the flag: the named
agent must actually be missing, the log must carry its evidence — a failed `provider-result`
with `reason=no-output`, or a failed `turn-finished` with `reason=no-output` or
`reason=policy-unapplied` — every missing leg must be named, and a reduction that would leave NO reviewer is refused outright, because
that is not a degraded panel but an unreviewed change. Accepting one writes `leg-unavailable`
per dropped agent BEFORE composing, closes as `composed-degraded`, and labels the output
DEGRADED with the reviewers who were actually present. A degraded approval must never be
reconstructible as a full-panel one.

The evidence must belong to THIS attempt: a marker left by an earlier dispatch of the same
set would otherwise authorize dropping a leg that has since been redispatched and may still
be running, so the lookup is bound to the current dispatch and to a row whose status is
`failed`. Binding to the dispatch is still not sufficient on its own: a re-send of a failed
leg KEEPS that dispatch, so the leg's LATEST turn must be the failed one. An attempt that has
begun and not yet reported is a reviewer working right now, and is never droppable. "Begun"
counts `request-persisted` as well as `turn-started`, and that choice is load-bearing:
`turn-started` is advisory, so losing it would hide a live re-send, while the request event is
written fail-closed before delivery and therefore cannot be missing from one. The rule is
QUIESCENCE, not attribution: a leg is droppable only when nothing about it can still be in
motion. (1) Every send has recorded its delivery: each send mints an attempt id, written as
`attempt=<id>` at the head of both its `request-persisted` and `request-dispatched` notes, and
every persist needs its own delivery row (counted, so a repeated id still needs one per send) — a
send between the two may yet spawn a runner. (2) Every run the log knows of has finished: a run
named by any `request-dispatched`, `turn-started`, `provider-result` or `turn-finished` row stays
open until its own `turn-finished`. (3) The run that finished last recorded the failure. Nothing
here trusts WHICH run an attempt attached to — row order, a delayed delivery row, an "already
running" line, a late start of the same request and a foreground `--wait` run racing a detached
one each made an attribution rule unsafe in review — because none of them can make an open run
look finished. The cost is availability, and re-sending the leg does not heal a gap: an unmatched
persist or an open run stays in the leg's history under that dispatch. `await` synthesizes a
terminal row only for a runner that died before publishing `result.json`; any other gap (a lost
delivery row, a lost `turn-finished` beside a published result) needs a fresh `panel dispatch`,
whose new dispatch id starts a clean history. Run identity is the
`run_dir` column, stored through the same head-plus-digest transform as the other identity
columns, so two run dirs that differ only past its width stay distinct. Only `role=gating` rows are read: a
`comms.sh shadow` turn runs under the same set and dispatch, possibly as an agent that is also a
gating leg, and its failures say nothing about that leg. Because
"latest" is a sample, each dropped leg's turn history is fingerprinted from the same read that
judged it eligible and re-verified immediately before the composition is published, beside the dispatch
supersession check. **A residual remains and is not closable in shell**: the gap between that
final check and the write itself. Closing it would need locking; it is recorded here rather
than chased. A turn killed at its budget (`rc=3`) is deliberately NOT marked: it was working
and may answer with more budget, which is a retry, not a roster reduction. And the operator
gate is procedural, not authenticated — the CLI cannot tell an operator from an agent, so
"a human chose this" is a rule the driver keeps, not one the tool enforces.

Sandbox: over ACP a Codex turn runs under its own kernel sandbox and a Claude turn under a
pinned permission mode. For worktree turns, `.comms/` and the main `.git/` are added via
`--add-dir` so the reply and branch operations succeed. The spawned turn does **not** inherit
`COMMS_DELIVERY`: exporting `headless` onto the child also landed it on the driver, where it
tripped the parent's own delivery gate and killed the broker's `send` while the copied reply
made every leg look answered. (grok, S4-2 r1, blocking.)

**The reviewer environment boundary.** A review turn is launched from the driver's shell, so
without a boundary it inherits the driver's identity. `runphase.sh run` exports
`COMMS_REVIEW_TURN=<identity>` for the whole turn, and `comms.sh whoami` fails closed whenever
it is set — nothing inside a review turn resolves to a driver. The marker, not a scrub, is what
covers a claude reviewer under a claude driver: that child carries only claude's session
signals, which is exactly the case whoami's conflicting-signals check cannot see. Every child
launch (acpx, and grok's direct exec) also drops `COMMS_SELF`, `COMMS_PRESENCE_NAME`,
`COMMS_PRESENCE_INSTANCE`, `COMMS_PRESENCE_PID`, `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
`CLAUDE_CODE_CHILD_SESSION` and `CLAUDE_CODE_SESSION_ID`, so a claude reviewer launched by a
claude driver sees what one launched by codex or grok always saw.

The DETACHED runner that `spawn` starts drops `COMMS_PRESENCE_*` and `COMMS_SELF` as well. It
can outlive the driver, and its broker's `send` would otherwise keep beating the driver's
released presence record back into existence as a pid-less peer nobody can reap. The
foreground `send --wait` run keeps them (the driver is alive), and the driver's own `await`
beats while it waits.

## Archive discipline

Each agent archives **only its own inbox** (`comms.sh archive --as <self>` enforces
this), idempotently — an already-archived file is a no-op, never an error. The shared
`archive/` is the loop's audit trail; its newest entry per workspace is how any reader
infers loop completion (a normalized approving verdict — `APPROVE`, or its canonical
synonym `pass` — is the only completion signal).

## Custom profile bindings

Custom `review-request`, retry `error`, and mailbox `question` messages, plus
parent-brokered replies, carry `agent_profile` (canonical JSON
encoded as URL-safe base64), `agent_profile_digest` (SHA-256 of that canonical JSON),
`review_family`, and `review_model`. The public profile contains credential references,
never resolved credentials. Execution compares the frozen binding with the operator
profile. Replies must match their retained request; model/family metadata without
the complete binding is invalid. Composition counts recorded families rather than
looking up today's configuration. Legacy built-in replies retain their existing
provider rules. Keep the original request (normally in `.comms/archive`) for as
long as its reply may be composed. An absent request makes that reply invalid;
`validate <reply>` reports the missing request. These integrity checks bind local
records; they are not signatures.

See [AGENT_PROFILES.md](AGENT_PROFILES.md) for the configuration and evidence contract.

## Leg bindings (exact per-leg binding, capability layer Slice 7.4)

`panel dispatch --bindings FILE` is an opt-in mode negotiated with `review-route capability`
(`leg-binding-capability v1 leg-bindings=1 route-view=2 leg-metadata=1`). A caller that names, per leg, the exact model,
native effort and expected access profile gets exactly that or a refusal of the WHOLE dispatch before the first
durable write; the tool never reclassifies a tier, picks a route or falls back. Without `--bindings` nothing here
applies and no new frontmatter key is written. The file format, the refusal codes, the run-time re-check and
the `result.json` contract are in [COMMANDS.md](COMMANDS.md#exact-per-leg-binding--panel-dispatch---bindings); the
configuration is in [AGENT_PROFILES.md](AGENT_PROFILES.md#access-profiles-accessjson).

Protocol facts:

- **Dispatch-time refusal** writes nothing: no snapshot, event, index row, attempts marker or leg file. Exit 1 lists a
  `refused <agent> <code> <detail>` line per refusal; exit 2 is a malformed file or roster violation. Which legs exist,
  and which are optional, is the caller's decision, so a refusing optional leg refuses the dispatch too.
- **Stamped frontmatter** on each leg's `review-request`: `leg_binding` (URL-safe base64 of the canonical binding: expected
  model, effort, access, the configured `access_digest`, `ref`, `role`, `requirement`) and `leg_binding_digest`. Both are
  written only by `send --bound-leg` (internal to `panel dispatch`), verified against the leg's own agent before being
  written, and stripped from any other message, hand-typed values included. The `panel-planned` event note carries
  `bound=1 ref= role= requirement= route_id=`; no `route_decision` is stamped in this mode.
- **Run-time re-check**: the runner judges the stamp again before it mounts, launches or prompts. A changed access file,
  profile, credential reference, login state, pin or map ends the turn `status=failed reason=binding-mismatch` with nothing
  launched. `binding-mismatch` is a terminal, non-degradable reason: a refused bound leg stays an unanswered leg and compose never
  drops it from the roster. The honest guarantee: no leg starts unless every leg was valid at dispatch, and a leg whose
  configuration changed afterwards refuses itself rather than run something else; an already-running sibling is not recalled.
- **Authority**: pauses, holds, budgets, fallback and retry on another route belong to the caller. This layer only fails closed.

