# Internals

Architecture, design rationale, and the rules you must follow when editing this repo —
written for human contributors and AI agents alike.

## Repo layout

```
install.sh                     installer (all scopes, local or curl-piped)
helpers/
  comms.sh                     message engine: workspace/list/validate/archive/deliver/send/state/clean
                               + bounded reads: lessons/archive-search
                               + route (delegates to route.sh)
  route.sh                     /auto query classifier: plan / effort / abstract tier
                               (policy in code; backends are opt-in)
  route_backend.py             swappable decision backends (TypeSafe/Jev is one), both rubrics,
                               the bounded reviewer state builder, the transmission permit
  route_review.py              reviewer routing DECISIONS: sticky per (thread, phase), recorded
  route_shadow.py              the shadow collector (observes; never decides)
  acp.sh                       ACP consults + the reviewer policy resolver/accessors
  policy-map.tsv               THE versioned reviewer model/effort map (the only vendor model ids)
  worktree.sh                  worktree new/list/retire, sourced by comms.sh; the ONE retire
                               gate evaluator both list and retire use
  runphase.sh                  peer-turn runner — ACP for every provider, direct headless for grok
                               only (COMMS_DELIVERY=headless): spawn → observe → record
docs/loopspec/                 the portable review-loop kernel (spec, schemas, fixtures,
                               check.sh, prompt fragments) — vendored by other consumers
templates/
  claude-commands/*.md         driver commands (thin prompt wrappers). install.sh copies
                               them to Claude and Grok command dirs and wraps them as
                               Codex SKILL.md files; identity is comms.sh whoami.
tests/run.sh                   complete-suite gate — run on the committed candidate
tests/dispatch.py              bounded scheduling and complete worker-report aggregation
tests/worker.sh                one fixture-owning group under process supervision
tests/lib/                     counters, committed coverage contracts, fixture builders
tests/groups/                  independent regression groups (mailbox default)
docs/                          this documentation + ROADMAP/advisories
```

## The template/helper split

Templates are **prompts** — they carry only what an LLM needs to reason about (flow
logic, verdict discipline, message composition). Every shell operation is a one-line
call into the installed helpers. The split criterion: *would an agent need to reason
about this, or just run it?*

Why it's this way (each reason independently sufficient):

1. **Render-time argument substitution corrupts inline code.** Claude Code substitutes
   bare `$0`–`$9` and the ARGUMENTS placeholder into slash-command markdown at
   invocation time — *including inside fenced code blocks* — and there is **no escape
   syntax**. `$0` becomes the first argument word (or empty with no args), so inline
   `awk '{print $2}'` is silently rewritten into garbage. Script files on disk are never
   rendered, which eliminates the entire failure class.
2. **Drift.** The same ~25-line shell blocks used to be copy-pasted across 9 files and
   diverged within weeks. Both agents now call one script, so the two sides provably
   resolve workspaces and paths identically.
3. **Token cost.** Command files are re-tokenized into context on every invocation. The
   extraction cut templates by half overall (the fleet command by ~87%).
4. **Testability.** Scripts get a real test harness; prompt-embedded shell can only be
   eyeballed.

## Editing rules

- **Never write bare dollar-digit tokens (or dollar-star) in any template** — not in
  code blocks, not in comments. If template-embedded shell is unavoidable, write awk
  fields as `$(0)`/`$(2)` and pass bash function inputs through named variables, never
  positionals. (Prose must avoid the literal sequences too; spell them out.)
- **Helpers are bash, never sourced.** Shebang `/bin/bash`, `set -euo pipefail`,
  compatible with bash 3.2 (macOS ships it — no associative arrays, no `${var,,}`).
  Callers may be zsh: never rely on caller-shell word splitting.
- **Advisory side-effects must not break load-bearing paths.** State writes, warnings,
  and telemetry are wrapped so no failure of theirs can interrupt
  validate → deliver → archive. When you guard a path, guard *the whole path* — the
  recurring review finding in this repo's history is "the guard covers the changed
  branch, not the whole path" (see the friction log in [ROADMAP.md](ROADMAP.md)).
- **Crosscutting changes: sweep every site.** When changing a pattern (e.g. how verdicts
  are read), grep for all occurrences — including code you restructured earlier in the
  same change.
- **Frontmatter parsing is boundary-scoped.** Field reads only match inside the leading
  `---` block; matching anywhere in the file lets a body line that *quotes* frontmatter
  (e.g. `verdict: APPROVE` in prose) fake protocol signals.

## Presence: advisory, not locks — and the one residual

Presence (`comms.sh presence`) coordinates sessions without ever holding a lock: a
stuck lease is an outage, a rare double-isolation costs ~300ms. Design rules that
took ten review rounds to converge (thread `presence-worktrees-15135`):

- **Two clocks, never unified.** TTL (I, default 2700s) is the freshness window and
  the reap-observation grace; tombstone covers hold 2I from their own unlink stamp.
  Collapsing them recreates the "ages out exactly when needed" failure.
- **Only `expire` deletes others' records**, via two-pass byte-identical reap:
  observe (original timestamp never refreshed — `expire; expire` cannot shorten the
  grace), then reap only if bytes are identical, the grace is served, and confident
  death still holds (same host, and the pid probe is THREE-VALUED: `ps -p` exit 0
  with output = alive, exit 1 with empty output = ESRCH death, and ANY other
  outcome — denied, unexecutable, truncated — is ambiguity, never death; the
  recorded `pid_started` must match for alive to hold, so pid reuse cannot keep a
  dead claim). The nonce-named tombstone is written BEFORE the unlink and GC'd only
  when old AND recordless — never because a record exists, and only the exact nonce
  file observed (a paused GC cannot clobber a newer generation).
- **The reap decides while the record is ABSENT** — expire renames the record into
  the reap dir under a staging name, compares the MOVED copy against its
  observation, then either drops it (tombstone first) or moves it back. Comparing
  in place left the record readable between the comparison and the unlink, so a
  concurrent re-check could re-pin it, see no cover yet, and answer direct-safe
  while the pass went on to delete it — two sessions authorized at once. Absence is
  the state that fails closed, so the dangerous window no longer reads as free.
- **Readers go records-first, then covers** — but this no longer means every
  interleaving shows a reader one of the two. Rename-first deliberately opens a
  brief interval that is RECORDLESS and COVERLESS. Safety there comes from the
  owner detecting its own absence (exit 5, tenure lost) and from the claiming
  session having written its own record, not from the reader always seeing a
  cover. A pass killed inside that interval parks the bytes under the staging
  name; the owner fails closed and re-claims, and cover GC collects staging files
  older than 2I so a pass about to move one back is never collected.
- **Restoring is last-writer-wins, deliberately** — if a beat writes a replacement
  record while expire is moving a mismatched staged copy back, the restore
  overwrites that newer heartbeat. It stays conservative because the beat observed
  absence, returned exit 5, and already owes a re-check; the cost is a stale
  heartbeat on a record whose owner has been told to re-claim.
- **Beats are whole-file rewrites** — a lost unlink race heals on the next beat,
  and healing restores PRESENCE, never direct tenure (exit 5 forces re-check).
- **The documented residual:** a falsely-reaped DIRECT session that performs no
  beat and no wait-checkpoint for more than 2I (an unnoticed suspend resuming
  straight into a write) while a newcomer legitimately claims. Closing it requires
  per-write lease semantics — rejected; the templates place checkpoints at every
  wait boundary, and the harness pins the reproduction to exactly these
  preconditions.
- **Worktree helpers anchor on `main_repo_root()`** (the mailbox resolver, not
  `--show-toplevel`) so creation from inside a worktree cannot nest checkouts; and
  session worktrees are excluded from artifacts three ways — gitignore at init,
  mechanical snapshot strip, and `worktree new` refusing without ignore coverage.
  The local default-branch tip (never `origin/<default>`) is the base: origin can
  lag a full unpushed day.

## Workspace resolution

One algorithm, one implementation (`comms.sh workspace`), with an explicit escape
hatch at the top: a **repo-scoped pin** (`.comms/workspace`, written by
`workspace set <name>`) IS the mailbox identity when present and beats every
inferred source below — identity is a naming decision, and a valid-but-wrong inferred
title otherwise becomes authoritative forever (the client-backup incident, field report #3).
Below it sits the **worktree pin**, which `worktree new` writes into the new tree's own git
admin dir (`<git-dir>/agent-comms-workspace`): the name the tree resolved to at creation, so a
later branch rename cannot re-key its threads under a second state file. It is per worktree by
construction (every linked worktree has its own admin dir), invisible to `git status` and review
snapshots, and removed by `git worktree remove`. It is not written with `workspace set` because
that would rename every unpinned session in the repo — including a peer mid-loop — which is
the split it exists to prevent. Below the pins the only remaining source is git: the branch
name, or the repository directory name when there is no branch. The cmux title cache and its decorated-title
guard were removed with the transport (S4-4). One rule from that design survives and is
load-bearing: a generic default branch resolves to the BRANCH name (`main` stays `main`),
not the repository directory name — substituting the directory name there changes every
message-filename prefix and hides pending messages behind the glob (field report #3).
Nothing in the corpus covered that case before S4-4; it is now pinned by assertion.
An empty scoped listing warns when unmatched files still exist in the physical inbox.

### Two root resolvers — deliberately not unified

They answer different questions, and collapsing them breaks one of the two:

| resolver | returns | used for |
|---|---|---|
| `main_repo_root()` — `git worktree list --porcelain \| head -1` | the **main** repo root | `.comms/` — one shared mailbox across every linked worktree, and the helper pin |
| `git rev-parse --show-toplevel` | the **current** worktree root | project docs (`comms.sh lessons` → `docs/advisories.md`) |

A review running in a feature worktree must read *that tree's* advisories, not main's —
so `lessons` uses `--show-toplevel`. But the helper pin and the mailbox must be shared
across worktrees — so those use `main_repo_root()`. Swapping either one is a silent
bug: `--show-toplevel` for the pin misses `<main>/.agent-comms/` and falls through to
`$HOME`; `main_repo_root()` for lessons reads the wrong tree's docs.

## Agent registry & the grok execution boundary

`.comms/config` is parsed by `comms.sh` alone (`agents [default|--drivers|--review|--provider
<id>|--others <driver>|--supported]` is the one read API — templates and runphase both consume
it, and every mode reads the same single parse). The supported-backend set is
compiled into the helpers: claude/codex are `interactive,acp` — ACP-only for review turns
since step 4; **grok is reviewer/consult-only and keeps the direct headless route**.
`deliver` routes every agent through runphase.

The grok leg is a **read-only child with a trusted parent broker**: the child runs
`grok --prompt-file … --output-format streaming-messages-json --sandbox read-only
--permission-mode dontAsk --deny 'Bash(rm *)' --deny 'Bash(git push*)'` and cannot
write the repo or the mailbox (kernel Seatbelt/Landlock); its ONLY job is to emit the
complete reply message as its final output. The runphase parent then extracts the
reply from the final `result` event (the only chunking-proof anchor — plain
streaming-json emits nondeterministic token deltas), verifies the parent-generated
message_id, validates, persists to the pickup peer's inbox, sends, and archives the
inbound. **The parent assembles the whole prompt**, and the prompt SCAFFOLDING names no
mailbox path and no comms helper: the inbound message is inlined verbatim, and
prior rounds of THIS thread are precomputed by the parent (scoped by construction —
the search term is the thread id). This matters because `read-only` restricts WRITES
only: the mailbox — every thread, every workspace, including content later scrubbed
from the tracked tree — stays readable to a prompt-injectable child. Removing the reason to look is a mitigation, not a boundary — and it has a hard
limit worth stating plainly: the inbound message and prior rounds are inlined
VERBATIM, and reviews of this project discuss `.comms` paths and helper names by
nature. Those strings therefore appear in the prompt inside quoted material, and
sanitizing them would degrade the review rather than secure it. **Path secrecy is
not the control.** Two things are: the prompt tells the child not to act on helper
mentions in quoted text, and — for untrusted-reviewer use — the operator-applied
kernel deny-profile below. An inherited env var is NOT a boundary either (a child
with shell access can unset it); that approach was tried and reverted.

`--sandbox strict` (kernel read-limit to CWD + system paths) was tried and rejected
with evidence: in a linked worktree `.git` is a file pointing at the MAIN root, so
strict kernel-denies git itself and the review turn dies in seconds. `.git` and
`.comms` are siblings, so no built-in profile isolates the mailbox without breaking
the reviewer in the primary topology. **Operators who want a kernel boundary** add a grok
custom profile to `~/.grok/sandbox.toml` and select it by name with
`COMMS_RUNPHASE_GROK_SANDBOX` (the runner honors that knob and refuses the
writable built-ins `off`/`devbox`/`workspace`, so it can only harden):

```toml
# ~/.grok/sandbox.toml
[profiles.agent-comms-review]
extends = "read-only"
deny = ["**/.comms/**"]
```

```bash
COMMS_RUNPHASE_GROK_SANDBOX=agent-comms-review   # then run the loop as usual
```

Running without it is supported but warns at turn start: under the default
`read-only` the mailbox stays readable to the child. The runner refuses the
writable built-ins (`off`/`devbox`/`workspace`), but it cannot introspect a
custom profile — that the named profile actually extends `read-only` and denies
`**/.comms/**` is a trust assumption about operator-controlled config.

`deny` globs are kernel-enforced for reads and writes. This is the same
print-it-don't-write-it posture the removed `codex-permissions` command had: the recipe is
documented, the operator applies it, and the runner honors the selection.

The parent stamps the ENTIRE
reply envelope itself (type/from/workspace/message_id/thread/in-reply-to/workflow/
phase/round/max-rounds/artifact_id/head_sha/verdict) from captured inbound values — the child's output is
body only — reviews additionally lead with a `VERDICT:` line, which is parsed ONLY
for review-feedback turns (on a consult, a stray verdict line is preserved as body
text, never a verdict field) — so no model-authored frontmatter is ever persisted
and a prompt-injected reply cannot re-thread, impersonate, retarget the artifact, or archive another turn's
inbound. `send` is the coordinator door: a review-feedback whose `artifact_id`/`head_sha`
disagree with the request is refused, and a reply is never snapshotted into a new artifact. Bypass modes (`always-approve`/`--yolo`/`bypassPermissions`) and writable
sandboxes (`off`/`devbox`/`workspace`) are refused outright in loop turns, in both
token forms, after shell-splitting the extra args. **Known carve-out:** the
`read-only` profile keeps OS temp directories writable (`/tmp`, `/var/tmp`, macOS
`/var/folders/...`) — a repo checked out UNDER a temp path is not kernel-protected
there (permission rules still apply); real checkouts under `$HOME` etc. are covered,
live-verified both ways on grok 1.0.5. The pickup
peer derives from the inbound message's `from:`, which must be a registered DRIVER other than
the turn's own identity; the old claude↔codex complement survives only as a fallback for a
driver turn whose inbound has none — a review twin's turn without a `from:` is refused.
Live-verified 2026-08-20 (grok 1.0.5, sentineled linked-worktree probe: both trees byte-identical after a
completed review turn; an instructed in-repo write attempt was denied mid-turn).

### Identity vs provider

Two Claudes could not share `to-claude/`: one inbox, one `peer_of`, one `awaiting_from`, so a
claude driver reviewing itself had its request and the reply in the same place. The fix
separates two things that used to be one word. An IDENTITY is who a message is from or to; a
PROVIDER is the runtime that serves a turn. Drivers (`agents =`) are still named after their
provider, and every driver X has a built-in review twin, `X-review`, that runs on X under its
own name. The rules for users are in
[PROTOCOL](PROTOCOL.md#identities-and-providers-same-model-review); the reasons are here.

- **Built in, not configured.** The first version (landed and replaced on the same day,
  2026-09-24) declared review identities per project, `review-agents = claude-review:claude`.
  That made same-model review a setup step every project had to discover, and let any name be
  mapped onto any provider, so every consumer had to treat the name→provider map as mutable.
  Twins are derived from the `agents =` line instead: the name is formed in one place
  (`review_twin_of`), the provider is fixed, and a twin exists exactly when its driver does.
  Naming yourself works the same in every runtime because one resolver does the swap —
  `agents --roster`, which `/auto`, `$auto` and `/user:auto` all call — rather than each
  template re-deriving the rule. Same-model review stays opt-in: `agents --others` returns a
  twin only to a lone driver, so adding twins changed no multi-driver default panel.

- **The provider is resolved in one place, at the process boundary.** Above it everything is
  keyed on the identity — inbox, leg thread, `sets.tsv`, events, `awaiting_from`, pickup,
  archive owner, shadow store. `transport`, `suppression_ok` and `agent_version` resolve the
  provider first, so no binary named after an identity is ever executed. runphase's
  `resolve_turn_agent` is the first statement of both `spawn` and `run`; after it `$provider`
  means the provider at every provider-keyed site (ACP-only rule, capability lookup,
  hostile-artifact refusals, acp.sh profile and policy, the isolation `case`) and `$agent` the
  identity at every identity site. The inverse fails OPEN — an identity in `$provider` would
  fall into the uncontained `*)` isolation arm and skip the hostile-artifact refusals, which
  match on the provider's name — which is why a caller can pass only the identity. `spawn`
  forwards the identity, never the resolved provider, and `run` re-resolves it through the
  same accessor.
- **Review-only, deliberately.** A twin never drives, authors a request or answers a
  consult: `/ask claude` already serves same-model consults, and a driving twin would need its
  own presence, whoami and loop state for no new capability. Each rule sits at
  the funnel that sees it — `whoami`/`require_driver` for driving, `validate` for authoring
  (every writer passes through it), `send` for what a target may receive (frontmatter has no
  `to:`, so validate cannot).
- **Same-provider legs are refused, not down-weighted.** Two legs on one provider run the same
  model at the same effort — one routing decision per base thread, a provider-keyed policy,
  no per-identity pins — on the same prompt and, for claude, the same `~/.claude`. Their
  agreement is not corroboration. Dispatch refuses such a roster early; compose is the
  authoritative gate because it runs over what is actually counted, which covers
  carried-forward legs, concurrent attempts and retries with no lock.
- **Provenance comes from the reply, not the registry.** compose asks `reply_provider` of each
  counted reply: a driver's is its own name, unconditionally (validate already refused a
  conflicting stamp), and a twin's is the `review_provider` its broker stamped, which validate
  holds to the twin's fixed provider. The request carries the provider `send` resolved, and
  runphase refuses a turn whose request was bound to a different provider than the twin runs
  on. With the map fixed there is no live remap left to catch; the same two checks now catch a
  forged or hand-edited stamp, or a request stamped under the retired per-project config, and
  fail the leg closed instead of publishing one model's review under a name compose would
  count as another's.
- **The marker, not a scrub, stops a reviewer resolving to its driver.** whoami's
  conflicting-signals check catches a CROSS-provider child (codex under claude). A claude
  reviewer under a claude driver carries only claude's signals and would resolve to the
  driver; `COMMS_REVIEW_TURN`, exported by `run` (always a child process) and never scrubbed,
  closes that for every child launch. The scrub (`TURN_CHILD_SCRUB`: `COMMS_SELF`,
  `COMMS_PRESENCE_*`, the Claude Code session variables) is one array applied by `acp_exec`
  and by the direct exec alike, so the two launch sites cannot drift. `CODEX_SANDBOX` and
  `GROK_AGENT` are left alone — the marker is what makes whoami safe.
- **acpx sessions stay disjoint.** acpx keys a session on (profile, cwd, name), and a twin
  shares its provider's profile, so an unmounted `claude-review` turn would resume a
  `claude` reviewer's warm session on the same thread. Its session name gains `+as+<identity>`
  (outside `safe_name`'s alphabet, like `+mount+`); a mounted session already carries the
  identity through its mount ident. Driver names are unchanged, so their sessions stay warm.
- **Byte-identical for drivers.** For a driver the identity is the provider, so idents,
  session names, state keys, events and frontmatter come out as before; `review_provider` is
  stamped only on requests to and replies from a twin. What every project does see: bare
  `agents` and every inbox enumeration now include the twins (zero-config lists six
  identities), and a twin's inbox exists only after its first send, so a missing inbox reads as
  empty.

**Residual, accepted:** the claude provider's containment (`claude-plan`) sets no config-home
override — pointing `CLAUDE_CONFIG_DIR` at the mount breaks authentication — so
`claude-review` shares `~/.claude` (settings, user instructions, memory) and the keychain
credential with a claude driver on the same machine. The twin separates the mailbox and the
session, not the model's configuration.

**The gemini provider's isolation differs from both.** Unlike claude, the Gemini CLI does honour a
relocated home: `GEMINI_CLI_HOME` names the directory that CONTAINS `.gemini/`, so a mounted turn
gets a parent-owned home beside the mount and the operator's settings, extensions, hooks and MCP
servers never reach it (so `gemini-review` does not share configuration with a gemini driver).
The operator's login is carried by construction, not by sharing the home: environment credentials
pass through, a keychain login is home-independent, and only the file-backed OAuth token and the
selected auth TYPE are copied (and cleared when the source goes away, like codex's `auth.json`).
What it shares with claude is the class of containment — the in-process `plan` mode pin under the
narrowed permission shape, network open. Its per-turn evidence is the CLI's own chat record (the
model of every answered message, and the tokens usage is read from); the thinking level, which the
CLI cannot be told over ACP and does not record, is bound through the isolated `settings.json`
and only read back, which is why its policy capability is `fixed` (docs/ROADMAP.md).

**The grok provider's isolation is a kernel sandbox applied from outside (macOS).** grok's own
sandbox is no help on Darwin, and claude's and gemini's mode pins have no grok analogue, so
`helpers/box.sh` wraps the grok CLI in a Seatbelt profile. Four design points, each forced by a
measurement (ROADMAP "grok review restored on macOS"):

- **Where tools run decides what to wrap.** acpx advertises ACP terminal and file-system capabilities
  by default, and then runs the agent's shell commands and writes in *its own* process. A profile
  around grok alone contained nothing; the owner is launched `--no-terminal --no-fs` so grok runs its
  tools in-process. The flags are printed by `box.sh prepare` beside the profile that depends on them.
  They only change what is *advertised*: acpx 0.13.1 registered the handlers regardless, so a hostile
  agent could send `terminal/create` anyway. `ACPX_VERSION_ENFORCING` (0.17.1, the first release that
  registers them only when advertised) is therefore grok's pin, and `box.sh client-check` drives the
  launcher in use with a fake agent that sends the requests anyway — preceded by a control with the
  capabilities on — so an `ACPX_BIN` or a future regression cannot slip past on a version string.
- **The contained `grok` must be the one the owner launches, on every call.** The shim directory leads
  `PATH` in `acp_exec` (the owner is spawned lazily by whichever acpx call comes first), and the shim
  logs each launch with the profile hash; `box.sh launched` after the canary turns "the self-check
  passed" into "the owner ran the contained grok". Probes prove the profile, the launch record proves it
  was used. The record is per *preparation*: the box dir is durable across rounds and the profile text
  never changes (paths are `-D` parameters), so `prepare` resets the log and draws a generation nonce
  that the shim writes into every launch line; a launch from round one cannot vouch for round two.
- **Probes are checked against the world and against a control.** Each negative probe also asserts the
  file did not appear or the process survived, and the socket and tool probes first prove the same call
  works outside the box and the tool starts inside it — a denied call from a tool that never ran would
  otherwise read as containment. `tests/groups/box.sh` weakens the profile one rule at a time and
  requires `prepare` to refuse.
- **The credential copy is deliberately lesser than the original.** The staged `auth.json` drops the
  refresh token, so the reviewer's home can never rotate the operator's login, and an access token about
  to expire is refused (after one renewal by the operator's own `grok models`) instead of dying mid-turn.
  The operator's `config.toml` is not read; only the default model and reasoning effort are carried.
  The original login is denied by its physical path (`GROK_HOME` may live outside the denied home, and
  the CLI may be installed beside it), and `prepare` probes that same path.

Backend selection is one table (`backend_for` in `box.sh`); `acp.sh containment <agent>` and `doctor`
read the same answer the runner acts on. "No backend for this OS" (exit 1) and "a backend that cannot run"
(exit 3) are different: only the first can be waved through with `COMMS_RUNPHASE_ALLOW_UNCONTAINED`.

## Grading pilot storage (`.comms/grades/`)

Local, gitignored, per-install — resolved as **per-install only**, not synced. Cross-machine
export was considered and rejected: single-user tool, no compounding benefit, and finding
prose can carry paths and proprietary code, which would reopen the disclosure surface the
archive-scope fix closed.

```
.comms/grades/
  findings.tsv          append-only observations; idempotent by finding_id
  sets.tsv              review_set_id -> thread+phase+round, artifact_id, prompt_version
  attempts/<set>        empty marker: this set was dispatched under the ATTEMPTS scheme.
                        Staked by `panel dispatch` before its plan events, its legs and its
                        index rows, so it survives a driver that dies mid-fan-out and a lost
                        events log — the two states in which the index alone cannot tell a
                        crashed modern attempt from a genuinely pre-attempts set.
  shadow/<set>/<agent>.md          the shadow reply, stored but NEVER delivered
  shadow/<set>/<agent>.result.json the turn's own outcome record
```

Three boundaries hold this together, and each is mechanical rather than a convention
someone has to remember:

- **A shadow reply never enters a mailbox and never writes thread state.**
  `runphase.sh run --no-deliver` stops the grok broker after validation and turns
  `update_thread_state` into a no-op — including its EXIT trap, which would otherwise
  clobber `awaiting_from` while the primary reviewer is still working. So a shadow verdict
  cannot gate a loop it was never delivered into, and the primary's request is never
  archived out from under it.
- **The artifact excludes untracked runtime state mechanically.** `snapshot` stages the
  working tree in a throwaway index and then removes every path under `.comms`,
  `.agent-comms` and `.claude/worktrees` that the CANDIDATE commit (`HEAD`) does not track,
  rather than trusting `.gitignore` — a grades artifact must never carry message bodies into a
  git object that could later be pushed. "Tracked" is judged against the candidate, not the
  user's index, so a mailbox file someone force-staged but never committed still stays out;
  the strip re-checks its own result and refuses to mint the artifact if any untracked
  runtime path survived. Both scans pass `--ignore-submodules=none`, so a nested repo under
  `.claude/worktrees` that `.gitmodules` marks `ignore = all` cannot hide as a gitlink. A file the candidate DOES track under those roots (a committed
  `.comms/README.md`) is ordinary tracked content: it stays, and a working-tree edit to it is
  carried like any other. Stripping the whole root used to delete such a file from every
  artifact, so a clean tree snapshotted as a synthetic commit whose `head_sha` no longer named
  the candidate — and a verdict on it could not cover the candidate (live, 2026-09-27).
- **Grades never enter reviewer context.** The ledger lives outside anything
  `comms.sh lessons` reads. That rules out `docs/advisories.md`, whose read is a *mandatory
  first step in the reviewer's own turn* — the obvious "just track grades like advisories"
  answer would hand every reviewer its own scorecard.

`refs/agent-comms/artifacts/<id>` is the retention. A `commit-tree` object is unreferenced
and would be garbage-collected; the ref is what keeps the reviewed tree resolvable weeks
later. Deleting that ref namespace discards the artifacts, not just the pointers.

## Coordinator event log (`.comms/events.tsv`)

Contraction step 3 asks for a durable coordinator log, and the reason is a specific failure:
before it, reconstructing a review turn meant joining four stores, none of which is a
history. `grades/sets.tsv` records `dispatched` and is never updated again. `.comms/state/`
is last-write-wins. `result.json` is per-run and findable only if you already know the run
dir. And every broker REFUSAL — the ones that exist precisely because a stamped verdict must
never be derived from a body the parser could not read — lived only in a `runner.log` inside
a run dir the driver may never open. A driver that died between the ACP turn exiting and
`compose` had no durable answer to "what happened to leg X".

Four decisions are load-bearing, and each one was argued down from something worse:

**The accessor never exits; only its fail-closed callers do.** `events append` reports a
refusal and RETURNS non-zero. It used to `die`, which is `exit` — so an unsound filesystem
would have taken down whatever process was appending, including a `cmd_send` in the middle of
delivering a reply, quietly converting the advisory half of the policy into the fail-closed
half.

**Fail-closed only where refusing changes nothing — three writes, all before anything has
happened.** `panel-planned` (the roster, before any leg is sent) and `request-persisted`
(after the request validates, before anything is nudged) both `die` on failure: a roster or a
request nobody could record is a panel nobody can enumerate and a leg nobody can recover, and
at those two instants nothing has happened yet. The `grades/attempts/<set>` marker joins them
as the THIRD, and is staked earliest of all — before the plan rows — because a set that cannot
record which scheme it was dispatched under is a set a later `compose` may silently
misclassify as legacy. It uses `die` rather than `set -e` because `panel dispatch` calls
`cmd_send ... || echo warning`, which suppresses errexit inside the function — an unchecked
append would have been advisory exactly where it claimed to gate. Everything after that
point is advisory and loud. The asymmetry is the whole design: `cmd_send` is also how a
brokered (and a self-sent) REPLY reaches the driver, so a fail-closed append there would
turn an already-delivered reply into a failed turn.

**The provider's result and the turn's result are two events.** They differ exactly when the
provider exits clean and the broker then refuses. Emitting one event from `write_result` put
it after every reply event on the ACP path and relabelled a broker refusal as a provider
failure.

**No lock; constrain, then detect.** A single small `printf` append is one flushed write on a
local filesystem — small matters literally: stdio's buffer is 1024 bytes on macOS, so the row
cap (newline included) is what keeps one row from becoming two `write(2)`s. That is a property
of the platform, not a POSIX guarantee, and NFS documents the opposite, so the constraint is
ENFORCED rather than assumed: **every** append classifies the filesystem of the actual append
target, by TYPE against an allowlist of known-local ones, and refuses anything else. An
allowlist rather than a blacklist of remote-looking names, because a network FUSE mount
(`s3fs`, `gcsfuse`, an rclone `remote:bucket`) looks nothing like `host:/export` and is exactly
as unsafe; checking only at creation was worse still, since a `.comms` that later migrates onto
network storage would append unchecked for the rest of its life. Refusing beats warning here because NFS's failure mode is a LOST append, which
leaves a perfectly well-formed file with an event missing — nothing downstream could ever
detect it. What detection does cover is the torn-row case: the reader validates each row
whole (full ISO timestamp, exact column count, a kind from the closed vocabulary) and reports
`skipped N malformed row(s)` instead of parsing an event nobody wrote. A `mkdir` lock was
rejected for the reason the presence work already established — a dead holder is a deadlock.

**A turn will not sign off clean over a hole in its own trace.** Runner-side appends are
advisory, so one can be lost; "absence means unknown" covers a gap, but it cannot excuse a
terminal row that positively claims `completed` while the acceptance before it is missing.
After delivering, the runner asks the READER for the acceptance of THIS turn, joined on the
reply id it minted for this execution. Nothing weaker is unique: a thread is shared by
overlapping turns, and a request id plus attempt is shared by two executions of one re-sent
request — in both cases the later turn could adopt the earlier one's acceptance and sign off
clean having recorded nothing. Not finding it, the runner writes `turn-finished
log-incomplete`. It asks the reader rather than grepping the file so that a row the reader
would reject — a partial append that happens to reach the id column — cannot satisfy the
check either; and because the reader applies the same identity transform as the writer, an
id longer than its column still matches itself.

**Not authoritative against a hostile child, and it says so.** A mounted review turn reaches
the real `.comms` through this same helper, so it can forge events until step 3's criterion 2
gives reviewer turns an enforced boundary. Read the log as the coordinator's record, the same
way the mount's PATH shim is documented as defence in depth rather than containment.

The recovery walk the log is designed to support is in
[PROTOCOL.md](PROTOCOL.md#recovering-a-loop-from-the-log).

## Review-mount cleanup: the whole store vs one retired thread

Mounts live outside the repo, under `<base>/<repo-key>/<ident>/` (`runphase.sh`, "EXTERNAL MOUNT
STORE"). Two verbs remove them, and they answer different questions.

`clean mounts` is the whole-store GC: it refuses the whole repo-key when any one ident is live or
unprovable. That is safe and, on a machine that is always reviewing something, rarely runnable.
`clean mounts --thread <T>` removes only what one RETIRED thread owns, and never reads, claims or
waits on any other ident. Load-bearing choices:

- **Retirement is a record, not an inference.** `state complete` is written every round and a loop
  resumes past it; an exited queue owner or an old timestamp is what a paused loop between rounds
  looks like. Only the caller knows the work is terminal, so it writes `state retire <T>`
  (`.comms/state/retired/`, keyed on a digest of the raw thread). A held thread is refused too.
- **Identities are computed, ownership is proven.** The idents are `acp_mount_ident` over (root, T, A)
  and (root, T-A, A); the hash already separates `a/b` from `a_b` and `task-1` from `task-10`. What
  the hash cannot separate is a leg thread that is also some thread's literal name (T's leg to
  codex and a thread called `T-codex`, both reviewed by codex, are ONE ident). The ledgers can:
  `grades/sets.tsv` records every dispatched leg and each run's `turn.tsv` records its thread,
  agent and review set. Every recorded use must belong to T or another retired thread; otherwise
  the copy is report-only. The ledgers live under `.comms/`, outside every mount, where a contained
  child cannot write. Every run record is enumerated before any is read, because a use that drops
  out of the scan is exactly how a shared copy reads as T's alone: `find -type f` skipped a
  symlinked or directory-shaped `turn.tsv`, and find never descends a symlinked run or logs dir, so
  each of those now refuses the whole call. A record is not complete just because it can be read:
  one of T or `T-<agent>` with no `agent` line (a run still writing it; `agent` is its last base
  line, and records before 2026-09-26 never carried one) could be the co-owner's, so it is an
  unattributable use that leaves the copy report-only; one with no `thread` line could concern any
  thread and refuses the whole call. The same holds for a `sets.tsv` row. The index's first line
  is skipped only once it proves to be the header naming the columns read: skipped unseen, a
  headerless index dropped its first leg row, and when that row was a live thread's the only
  evidence that a retired direct thread's copy was shared, the copy read as the retired thread's.
- **Absent only from a listing that worked.** A glob over a directory that cannot be listed reads
  as EMPTY, and `-d` fails below one that cannot be searched, so an unlistable `view/` once passed
  as "no tree" and its dirty tree reached the tombstone unverified. The ident dir, `view/` and each
  aside must list before anything under them is concluded absent. The same holds for a tombstone:
  whether it received the ident is read from its listing, so an unlistable one once read as "never
  moved" — the registration went, the payload was skipped, and dropping the "empty" tombstone
  deleted its record beside the payload, which every replay then refused. A replay touches nothing
  until the tombstone and the copy in it list, and `cm_drop_tomb` deletes the record only when a
  working listing shows nothing but journal and claims. The scope itself must list too, or a
  tombstone in it is never found and its moved ident reads as already absent (`store-error`).
- **A throwaway's name is not its owner.** `tmp-<run>` is `safe_name` of the run dir's basename, and
  `run+1`, `run_1` and a `--dir` elsewhere named `run_1` all map to one copy that the session and
  content checks cannot tell apart when both runs reviewed one artifact. The runner therefore
  records, under its claim, the physical run dir it made the copy for (`.state.run`); cleanup
  selects the copy only for that run, re-reads it under its own claim, and reports any other
  copy one of T's runs could have named.
- **"Dirty" means "not a retained artifact".** A mount is an uncommitted diff over its base by
  design, so git's dirtiness (and `git worktree remove` without `--force`) would refuse every
  mount, and with `--force` would prove nothing. The gate is tree identity against an artifact the
  thread's ledger names and `refs/agent-comms/artifacts` still retains — `mount_tree_matches`'
  rule, read through the repo's own git dir so a gitfile inside the mount is never followed.
  Equal means every byte is recoverable after the copy is gone. Asides (previous generations kept
  for a straggling cwd holder) pass the same test. Tree identity is blind below a gitlink —
  `git add -A` records a populated submodule's HEAD and never its edits or untracked files, and
  skips files dropped into an unpopulated one — so a nested repository anywhere in the tree, or
  anything inside a gitlink path, refuses (`nested-repo`) rather than being verified.
- **The scan decides nothing the claim does not re-decide.** A leg ident is shared the moment a
  live thread of the leg's literal name runs a turn in it, and that can happen between the scan and
  the claim. So under the claim the retirement, the hold and the ledger ownership are read again,
  not reused; only a turn that starts AFTER the claim is excluded by the claim itself.
- **Removal is a journaled rename.** Under a held claim and after every gate re-runs, a fresh
  `.retire.<ident>.XXXXXX` is claimed (`mount_claim_take`, exactly as a mount is), the record is
  written into it, the ident is renamed into it, the one admin registration whose back-pointer
  names the tree is dropped, and the tombstone is deleted. A kill at any boundary leaves either
  the untouched ident or a tombstone a later run finishes; a delete that fails part-way reports
  `incomplete`, never `removed`. The re-run must be able to re-prove what is left, so the delete
  is ordered around its own evidence: once the registration is dropped the record is rewritten
  with `admin=` empty, BEFORE any payload goes (a partial delete can take the moved tree's
  gitfile, the only cross-check against a re-created copy that git gave the freed admin name), and
  a throwaway's `.state.run` is deleted last (an emptied copy has nothing left to prove). The
  registration is deleted the same way: its back-pointer (`gitdir`) goes last, so a delete
  obstructed inside the admin dir keeps the one file the re-run re-proves it by, and an admin dir
  already emptied down to itself registers nothing and is dropped. One a copy re-created at the
  ident claims (its gitfile names that admin dir) is that copy's, and is left for a human. The
  record is published through a file `mktemp` creates exclusively and renamed over the old one, so
  no existing name is ever opened for writing; a leftover staging entry (`record.XXXXXX`) that is
  not a plain file refuses (`unsafe-path`) before anything is deleted. No repo-wide `git worktree
  prune`, which would also prune a peer worktree on an unmounted volume.
- **The journal has an owner.** A replay takes the tombstone's claim before touching it, so a
  maker still alive — or a second replay — is a scoped `busy-cleanup` skip, and only a maker proven
  dead is superseded. Replaying unclaimed let a concurrent cleanup read a live one's tombstone as
  "interrupted before the rename" and drop its record just before the rename landed, leaving the
  ident in a tombstone no later run could verify. The claim precedes the record, so a replay that
  reaches an empty tombstone first owns it and clears it, and its maker steps back.
- **The journal also names its owning thread.** The claim decides WHO may replay a tombstone now;
  the record decides WHOSE removal it is. A throwaway's tombstone is named after `tmp-<safe_name of
  the run dir's basename>`, which two threads' run dirs can share, and once a removal is interrupted
  after the rename the moved copy's `.state.run` is no longer where selection looks — so a record of
  only (ident, tree, admin) let thread A's cleanup finish thread B's removal, retired or not. The
  record now carries the thread, use, agent and physical run; selection reads only this thread's
  records, and a replay re-checks the record and the moved copy's `.state.run` under the claim.
- **A replay is a removal.** It deletes a payload and a registration, so it passes the gates a
  first removal passes (`cm_regate`, shared by both): a held use is refused before its tombstone
  is touched, and under the tombstone's claim the retirement, the holds and the ledger ownership
  are read again. The interrupted run proved them once; a paused loop, a withdrawn retirement or a
  live co-owner recorded since keeps the tombstone whole until they hold again. When ownership
  already fails at SELECTION, the report cannot key on the ident path alone: after a kill past the
  rename that path is gone and the copy sits in its tombstone, so a co-owner or an agentless record
  present before the retry read as "nothing selected, complete". Selection therefore also looks for
  a tombstone of the ident this thread cannot rule out (`cm_tomb_scan`) and reports it `ambiguous`,
  without replaying it.

**Residual risks, accepted.** (1) The ledgers ARE the evidence: deleting run records can hide a
direct turn on a leg-shaped thread name, and the shared copy would then read as T's alone. (2) A
detached process still holding a cwd inside the copy loses its directory, as it does when the
runner reaps an aside. (3) The isolated provider home (`home/`) is part of the copy: its raw
provider records go with it. The per-turn usage callers read was extracted into the run's
`result.json` at turn end, before unmount, and stays. (4) A turn that failed after staging but
before recording its session leaves a tree with no record; that copy refuses (`state-missing`)
exactly as the runner itself refuses to trust it, and needs a human or the whole-store GC. (5) A
throwaway made by a runner that predates `.state.run` records no run and is report-only.

## ACP consult transport (acp.sh)

Consults are synchronous by nature, so `/ask --via acp` bypasses the mailbox: one
blocking `acpx` call, answer straight to the caller, token line included. acpx is
pre-1.0 and PINNED (`ACPX_VERSION` in acp.sh, invoked via `npx -y` — cached, no
global install); Node >= 22.13 is gated at call time and the helper fails closed
naming the mailbox fallback for every error class (acpx's exit codes are a stable
contract: 3 timeout, 4 no-session, 5 all-denied). Warm by default via a named
per-repo session — measured 2026-08-20 on codex: cold one-shot 18,562 fresh input
tokens; warm round 2 **146** (~127x less). That number is why the ACP track exists;
review loops stay on runphase until this consult path proves the transport.
This is the ONLY Node-dependent surface in the repo, and it is opt-in per call.

## Reviewer model/effort routing

A reviewer turn's depth is a CONTRACT, not a hint: the isolated `CODEX_HOME` exists so the
operator's own config never reaches a review, and the rollout attestation refuses to publish a
turn that did not run the declared model and effort. Routing makes that contract per-turn without
loosening it. The stages share one decision identity and one persisted record:

```
request ─send/panel (COMMS_REVIEW_ROUTE=1, implement phase)─▶ review-route decide
          sticky per (workspace, base thread, phase); explicit, classified, or none
          .comms/route-decisions/<id>.json  ── route_decision: <id> stamped by the helper
runphase: current decision == stamped id? ─▶ acp.sh resolve ─▶ run_dir/policy.tsv (+ sha256)
          session name +p<policy_digest> ─▶ config.toml ─▶ preflight ─▶ canary ─▶ prompt
          ─▶ rollout attestation against THE SAME record ─▶ publish, or refuse unpublished
```

- **Abstract vs concrete.** Classifiers and decisions speak `fast|balanced|strong` and
  `low..xhigh` only; `policy-map.tsv` is the one place a vendor model id appears, versioned and
  recorded with every turn. A model update is one map edit, never a rubric change.
- **Precedence per dimension**: operator pin > eligible, enabled, implement-phase route > baseline.
  Missing, low-confidence, stub, not-permitted, disabled, unsupported or phase-excluded inputs all
  keep the CONCRETE baseline — never the abstract fail-open values mapped to a cheaper model.
- **Pairs are validated.** A classified dimension that forms an invalid pair falls back once
  (recorded); a pin or an explicit decision that does is refused, never substituted.
- **A session per concrete policy.** codex fixes model/effort when a session starts or resumes and
  sends its own values every prompt; a warm session is not known to adopt a changed config. So a
  mounted session is named after its `policy_digest`: an unchanged policy stays warm across rounds,
  any change (new decision, pin, map bump, routing off, plan→implement) is a fresh session verified
  by the preflight, and the old session is left untouched rather than patched or retired.
- **Evidence never relabels the expectation.** `requested_*` is written from the record at
  resolution time; `adapter_*` is what acpx reports; `observed_*` is the provider's own rollout
  (with its `cli_version`). The record is hash-checked before the config, the preflight and the
  attestation, because the reviewer runs in between.
- **Runtime-aware tiers.** A tier is an ordered model list; the resolver picks the first model the
  reviewer's codex runtime can serve (minimum runtime per `pair` row), so gpt-6.1-sol is used where
  an installed codex >= 0.159 runs the review, gpt-6-luna/sol where >= 0.155 does, and gpt-5.6
  otherwise, recorded either way. The baseline (gpt-6.1-sol, the everyday default) has no
  fallback: a runtime too old to serve it is refused, not downgraded, and `acp.sh doctor` fails
  (exit 4) on such a runtime. `strong` and the ceiling are gpt-6-astra, the frontier model, which
  needs no minimum. The
  runtime is auto-detected (or `COMMS_ACP_CODEX_PATH`), handed to the adapter as `CODEX_PATH`, and
  is part of the policy digest.
- **"use max".** `COMMS_REVIEW_MAX=1` (`/auto --max`) runs the map's `ceiling` pair on every turn
  that applies a policy; only an explicit pin outranks it, and it only ever raises depth.
- **Capabilities.** Only codex/acp-mounted is `eligible`, and a combination with no apply-and-attest
  path in code cannot be promoted by a map edit alone (`capability-unimplemented`). Claude and Grok expose model/effort
  controls in their adapters, but agent-comms neither applies them nor has isolated per-turn
  evidence, so their rows are `unsupported` and their turns record that rather than a policy.
- **Planning is read-only and uses the same resolver.** `review-route plan` validates a roster
  with the rule dispatch uses, reads the decision in force, and runs `acp.sh resolve` per leg exactly
  as runphase will, printing `acp.sh route-view`'s fields; each turn records the same fields as
  `result.json` `"route"`. A `limit` row in the map names a model's own usage limit (`limit_id`), so
  a spend planner can tell a leg that draws on a separate limit (a Spark model) from the shared one.
- **Collection is not activation.** `route --shadow --reviewer` uses the same builder and rubric
  as `review-route decide` but never writes a decision. Classification needs the same
  out-of-tree per-project permit as the shadow collector.

Routing is opt-in and off by default; whether it saves cost at acceptable quality is an
experiment still to run (docs/ROADMAP.md), not a property this mechanism establishes.

## Exact per-leg binding (capability layer, Slice 7.4)

`panel dispatch --bindings` inverts the routing above: the caller names the pair and the access profile, and the tool runs it or
refuses; it never classifies, picks a route or substitutes. The pieces, each with one owner:

- **`helpers/access_profiles.py`** reads `access.json` (one immutable entry per agent, cross-checked with `agents.json`) and owns the
  credential scrub. **`helpers/credential-env.tsv`** is the single place to extend it: non-pattern selectors (cloud route switches, base URLs,
  `AWS_*`) and one `auth` row per (adapter, billing) declaring the consumed variable, the login files and the route selector.
- **`helpers/leg_binding.py`** is the judgement (`check_leg`), shared by `panel dispatch`, `review-route plan --bindings` and the runner's
  re-check, so a plan cannot promise what dispatch refuses. It also builds the stamp, the `binding` object and the `quota` object.
  `comms.sh` runs it in a single call (`leg_bind_check`) over every leg BEFORE `request_tree_check`, the snapshot, any event or any file.
- **`acp.sh resolve --bound-model/--bound-effort`** is a new candidate source, `bound`: no tier, routed candidate, baseline, pin or
  `COMMS_REVIEW_MAX`. An equal pin is accepted, a different one is `pin-conflict`. The pair goes through the same `policy_pair_verdict`,
  disabled-model and runtime checks as a pin, and a failure is a refusal, never the baseline substitution a routed value gets.
  `--custom-profile` reads an OpenCode profile through `agent_profiles.py` instead of the map. Bound records are policy-record
  **version 2** (adds `route_id`, `access_digest`, `bound`); unbound resolutions still write version 1 byte for byte, and the readers
  accept both, each held to its own field set, so records retained across an upgrade still read. The policy digest, hence the warm session name,
  adds the access digest only for bound records, so two accounts never share a warm session.
- **Credential scrub.** The scrub set is the UNION of every configured credential name (all of `access.json`, every `agents.json` `credentials` mapping,
  the table's adapter destinations), the patterns `*_API_KEY`, `*_TOKEN`, `*_AUTH_TOKEN`, `*_SECRET*`, `*_ACCESS_KEY*`, and the table. It is
  applied as `env -u NAME` on every acpx call of the leg; only the bound `api` credential is then restored, under the variable its adapter
  reads, exported in the launch subshell. The credential is resolved ONCE, from the reference the stamped access snapshot carries; a custom harness receives it
  under the single marker `AGENT_COMMS_BOUND_CREDENTIAL` and its launcher places it under the profile's destination, so an inherited variable of the
  same name (an ambient key beside a bound Keychain reference) never stands in for it, in `serve`, `attest` or `acpx`. No prefix is exempt from the
  pattern scrub (a value is in a process environment, never in an argv, file, event or log). Configuration names come first
  because an operator-chosen name (`CODEX_METERED_KEY`, `API_KEY`) survives any pattern list. **Residual**: a credential nobody configured that
  matches no pattern and is not in the table passes through. The harness's own on-disk login is not an environment variable and is governed by the auth rows.
- **Authentication route.** Passing a key selects nothing by itself. For both billing classes the launcher applies the adapter's `auth` row (gemini: the
  isolated settings force the OAuth or API-key `selectedType`, the login files are staged only for subscription and a stale copy is cleared
  for api; codex: the staged `auth.json` and its `auth_mode`) and READS IT BACK before the first acpx call, refusing with `binding-mismatch` on a
  difference. Only a successful read-back lets `result.json` say `auth_evidence: observed`. A (adapter, billing) pair with no explicit, readable selection is
  declared `unsupported` in the table and refused (`auth-route-unsupported`) instead of being bound on the hope that an environment key beats a saved login:
  **codex `api` is such a pair today** (`forced_login_method` and `CODEX_API_KEY` exist in the installed binary, but nothing shows the mounted ACP adapter honours them).
- **Run-time re-check** (`runphase.sh bound_leg_recheck`) judges the stamp from the stamp alone against the configuration as it is now, before mounting, launching
  or prompting, and ends a changed leg `reason=binding-mismatch`. The check also compares the configured transport with the one the runner drives, and for an
  OpenCode profile verifies the runtime executable and version locally (`opencode_adapter.verify_runtime`, no credentials) so a broken final leg refuses the
  whole panel; a profile whose `connection.api_key_env` is not a variable its `credentials` mapping supplies (a local route with no mapping, or a mapping to another name)
  is refused `capability-unsupported` at the same point, because the bound scrub would remove the variable the launch requires. Environment and credential preparation re-verify the stamped access digest after the re-check's sleep and mount. The stamp and run state are
  written to `turn.tsv`, so `load_turn_identity` restores them for a synthesized result after a runner crash.
- **Quota metadata** (`leg-metadata v1`) has an explicit state because `null` cannot distinguish unsupported from missing: `observed` (a provider ledger
  snapshot; codex), `unsupported` (grok, claude, gemini, custom profiles: no rate-limit source), `unavailable` (supported, nothing in the window), `refused`
  (the existing classifier named `rate-limited` or `auth-failed`; gemini), with `reset_at` null unless a structured provider record carries one. A reset is
  never manufactured and no provider is presented as equivalent to another. Capacity policy and fallback are the caller's.

Not here: choosing models, tiers, efforts, routes, budgets or fallbacks; a model-to-tier mapping or a default (every model id comes from the caller);
making `claude` or `grok` bindable; verifying a remote bill; an OS-level network or credential sandbox.

## Delivery mechanics

`deliver` hands the message to a runner: ACP for every provider, or a direct headless turn
for grok. **Pickup is resolved before transport** — a reply addressed to the session driving
the current turn is a no-op, because that session reads it when the turn exits.

The cmux keystroke injection this section used to describe was deleted in step 4 (S4-4),
along with `RECOVER:`, `reconcile`, `doctor`, `codex-permissions`, and the
`workspace-cmux` permission profile. A keystroke nudge is self-send by another name: it
told a live agent to read and reply itself, with no parent stamping and no pinned artifact.
Delivery no longer touches any socket, so there is nothing left to be sandbox-blocked on.

## Test harness

```bash
bash tests/run.sh
```

The assertion count and section vector are pinned in committed contracts under `tests/`.
Independent groups own their fixtures; presence/signals run exclusively, then up to four
workers execute the remaining groups. The complete coordinator alone can attest after
validating every worker report and both contracts. `--group <name>` is a focused,
non-attesting development run; `--jobs 1` runs the same complete corpus serially. See
[tests/README.md](../tests/README.md) for details. Design points:

- **Hermetic, or it pokes real agents.** The suite default is `COMMS_DELIVERY=mailbox`:
  write the file, nudge nobody, no spawned child, no network. The first version of the
  harness inherited the live session's cmux and *sent an actual keystroke to a running
  agent's pane*; it later got hermeticity by asking for cmux and stubbing the binary,
  which made a transport slated for deletion load-bearing for every unrelated section.
  Rewiring the default to `mailbox` (S4-1) is what let S4-4 delete cmux without unrelated
  sections starting to spawn real agents. Keep every new test hermetic.
- Throwaway git-repo fixtures, canonicalized with `pwd -P` (macOS `/var` →
  `/private/var`).
- Regression style: every reviewer-caught bug lands with a test reproducing it
  (slash-in-thread desync, blocked state dir, dispatch-all flag propagation, …).
- Runs identically under bash- and zsh-invoked shells.

## Release/update model

No versioning yet — `main` is the release. The installer copies files; global installs
update in place, local pins don't (see [INSTALL.md](INSTALL.md)). Protocol changes must
be backward-tolerant mid-loop: new required fields start as soft warnings (the
protocol-v2 `thread`/`message_id` rollout is the precedent).

**Every installed file is written temp-then-rename (`install_file` in `install.sh`), never
`cp` in place.** "Update in place" describes the destination path, not the inode: bash reads
an executing script lazily by byte offset, so overwriting a helper that a peer session is
mid-way through shifts the bytes under it and the running shell resumes mid-token. That is
not theoretical — it killed a parked `runphase.sh await` three times on 2026-08-27, once as
`line 1326: l: command not found`. `rename(2)` unlinks only the NAME; a reader already
inside the old inode keeps it alive and finishes on the file it started with. Two
consequences bind any future edit here: the temp must be a SIBLING of the destination
(rename is atomic only within one filesystem, and a cross-device `mv` silently degrades to
a copy in place), and the mode is set on the temp before the rename, so the destination is
never observable at the wrong mode. The suite asserts this by inode identity, with a
negative control proving a plain `cp` keeps the inode.

Replacing a file by rename is not the same operation as writing through it, so three
things `cp` did incidentally are reproduced on purpose — each found in review, not in
testing:

- **Mode.** An existing destination keeps its own mode; a new one keeps the source mode
  masked by umask (what `cp` gives the temp); execute is added with `chmod +x`, which
  umask masks exactly as the old call did. A literal `755` published helpers
  world-executable under `umask 077` and reset files a user had tightened.
- **Symlinks.** A symlinked destination is resolved first, so its TARGET is replaced and
  a dotfile-managed install stays connected. This is also a correctness requirement, not
  a courtesy: `mv` follows a symlink pointing at a *directory* and moves the temp inside
  it while reporting success — and across devices that is the copy-in-place the whole
  design exists to avoid. A directory destination is refused loudly.
- **Owner and group** are restored for the same reason as mode — the old inode kept them
  and a fresh temp does not, inheriting the parent directory's group on BSD. This is a
  requirement, not a best effort: a `chown` that cannot be applied **refuses** the
  replacement, because publishing the file under the directory's group is a silent
  permission change. The trade is explicit — a destination you can write but cannot
  `chown` (a coworker-owned group-writable file, a `wheel` dest you are not in) now fails
  where `cp` succeeded by writing through, and widening access quietly is the worse of the
  two. **An ACL cannot follow a new inode at all**; that is inherent to replacing a file
  rather than writing through one, so an ACL on the destination is reported loudly instead
  of being dropped in silence. Extended attributes (`@`) are routine here and not reported.
- **An unwritable destination** is refused rather than replaced. `cp` failed with EACCES
  and aborted the install, which is the only way a user can pin a customized file;
  `rename` unlinks the directory entry regardless, so the refusal has to be explicit.

Mode is read as `%Mp%Lp` on Darwin rather than `%Lp`, which drops setuid/setgid/sticky —
`stat -c '%a'` already carries them on GNU. Every refusal exits non-zero, so a scripted
upgrade stops rather than continuing past a warning.

## Contributing checklist

1. Commit the candidate, then `bash tests/run.sh` — green, with an explicit attestation result
2. Check syntax for the shell files you changed, including files under `tests/lib/` and `tests/groups/`
3. No bare dollar-digit/dollar-star tokens anywhere under `templates/`
4. New behavior → new assertion; reviewer-caught bug → regression test
5. Docs: README stays glanceable; depth goes in `docs/`; protocol changes update
   [PROTOCOL.md](PROTOCOL.md)
