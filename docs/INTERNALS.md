# Internals

Architecture, design rationale, and the rules you must follow when editing this repo —
written for human contributors and AI agents alike.

## Repo layout

```
install.sh                     installer (all scopes, local or curl-piped)
helpers/
  comms.sh                     message engine: workspace/list/validate/archive/deliver/send/state/clean
                               + bounded reads: lessons/archive-search
  runphase.sh                  headless turn runner (COMMS_DELIVERY=headless): spawn → observe → record
docs/loopspec/                 the portable review-loop kernel (spec, schemas, fixtures,
                               check.sh, prompt fragments) — vendored by other consumers
templates/
  claude-commands/*.md         Claude Code slash commands (thin prompt wrappers)
  codex-skills/*/SKILL.md      Codex skills (thin prompt wrappers)
tests/run.sh                   hermetic harness (stubbed cmux) — run before every commit
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
  death still holds (same host, pid ESRCH-absent by `ps -p` — EPERM means alive —
  and the recorded `pid_started` matches no live process; pid reuse cannot hold a
  dead claim). The nonce-named tombstone is written BEFORE the unlink and GC'd only
  when old AND recordless — never because a record exists, and only the exact nonce
  file observed (a paused GC cannot clobber a newer generation).
- **Readers go records-first, then covers** — with tombstone-before-unlink, every
  expire interleaving shows a reader at least one of the two.
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
inferred source below — identity is a naming decision, cmux ids only route
surfaces, and a valid-but-wrong inferred title otherwise becomes authoritative
forever (the fwh-backup incident, field report #3). Below the pin: an undecorated
cmux title is cached under stable `CMUX_WORKSPACE_ID`; that mapping is
authoritative for the workspace lifetime. Empty or unparseable titles fall back without poisoning the cache;
status-decorated titles use the git branch (or repository name on a generic default
branch) to seed or repair it.
This prevents auto-title spinner frames from changing message and state prefixes.
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

`.comms/config` is parsed by `comms.sh` alone (`agents [default|--supported]` is the
one read API — templates and runphase both consume it). The supported-backend set is
compiled into the helpers: claude/codex are interactive+headless; **grok is
reviewer/consult-only and headless-only** — there is no cmux idiom for it, and
`deliver` routes any non-cmux agent through runphase unconditionally.

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
print-it-don't-write-it posture as `comms.sh codex-permissions`: the recipe is
documented, the operator applies it, and the runner honors the selection.

The parent stamps the ENTIRE
reply envelope itself (type/from/workspace/message_id/thread/in-reply-to/workflow/
phase/round/max-rounds/verdict) from captured inbound values — the child's output is
body only — reviews additionally lead with a `VERDICT:` line, which is parsed ONLY
for review-feedback turns (on a consult, a stray verdict line is preserved as body
text, never a verdict field) — so no model-authored frontmatter is ever persisted
and a prompt-injected reply cannot re-thread, impersonate, or archive another turn's
inbound. Bypass modes (`always-approve`/`--yolo`/`bypassPermissions`) and writable
sandboxes (`off`/`devbox`/`workspace`) are refused outright in loop turns, in both
token forms, after shell-splitting the extra args. **Known carve-out:** the
`read-only` profile keeps OS temp directories writable (`/tmp`, `/var/tmp`, macOS
`/var/folders/...`) — a repo checked out UNDER a temp path is not kernel-protected
there (permission rules still apply); real checkouts under `$HOME` etc. are covered,
live-verified both ways on grok 1.0.5. The pickup
peer derives from the inbound message's `from:`; the old claude↔codex complement
survives only as a fallback for messages without one. Live-verified 2026-08-20
(grok 1.0.5, sentineled linked-worktree probe: both trees byte-identical after a
completed review turn; an instructed in-repo write attempt was denied mid-turn).

## Grading pilot storage (`.comms/grades/`)

Local, gitignored, per-install — resolved as **per-install only**, not synced. Cross-machine
export was considered and rejected: single-user tool, no compounding benefit, and finding
prose can carry paths and proprietary code, which would reopen the disclosure surface the
archive-scope fix closed.

```
.comms/grades/
  findings.tsv          append-only observations; idempotent by finding_id
  sets.tsv              review_set_id -> thread+phase+round, artifact_id, prompt_version
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
- **The artifact excludes the mailbox mechanically.** `snapshot` stages the working tree in
  a throwaway index and then removes `.comms` and `.agent-comms` from it, rather than
  trusting `.gitignore` — a grades artifact must never carry message bodies into a git
  object that could later be pushed.
- **Grades never enter reviewer context.** The ledger lives outside anything
  `comms.sh lessons` reads. That rules out `docs/advisories.md`, whose read is a *mandatory
  first step in the reviewer's own turn* — the obvious "just track grades like advisories"
  answer would hand every reviewer its own scorecard.

`refs/agent-comms/artifacts/<id>` is the retention. A `commit-tree` object is unreferenced
and would be garbage-collected; the ref is what keeps the reviewed tree resolvable weeks
later. Deleting that ref namespace discards the artifacts, not just the pointers.

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

## Delivery mechanics

`cmux send`/`send-key` keystroke injection with short settles between steps. The
Claude-bound nudge performs a vim-mode dance (`escape, i, <text>, escape, enter`);
the Codex-bound nudge types `$read-from-claude` directly. The whole sequence is wrapped
so a mid-sequence failure reports `FAILED` explicitly instead of dying tersely. Injected
commands queue in the target's input box until its current turn ends — that's why "late
nudges" against an already-emptied inbox are normal and handled.

When a session cannot access the socket, delivery emits a single `RECOVER:` shell chain.
Direct `cmux` segments run first; `reconcile` is last behind `&&`, so state changes to
delivered only after the entire external nudge succeeds. Recovery is for a host-capable
context, not repeated execution inside the unchanged sandbox. The durable Codex path is
the global `workspace-cmux` permission profile printed by `comms.sh codex-permissions`;
`comms.sh doctor` verifies the effective session before a loop depends on it.

## Test harness

```bash
bash tests/run.sh
```

~90 assertions covering both helpers and the installer. Design points:

- **Hermetic, or it pokes real agents.** The harness stubs `cmux` with a fake binary
  (canned `tree`/`list-workspaces` output, a call log, an opt-in failure mode) and runs
  helper invocations with `env -u CMUX_WORKSPACE_ID`. The first version inherited the
  live session's cmux and *sent an actual keystroke to a running agent's pane*. Keep
  every new test hermetic.
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

## Contributing checklist

1. `bash tests/run.sh` — green, from a clean shell
2. `bash -n install.sh helpers/*.sh tests/run.sh`
3. No bare dollar-digit/dollar-star tokens anywhere under `templates/`
4. New behavior → new assertion; reviewer-caught bug → regression test
5. Docs: README stays glanceable; depth goes in `docs/`; protocol changes update
   [PROTOCOL.md](PROTOCOL.md)
