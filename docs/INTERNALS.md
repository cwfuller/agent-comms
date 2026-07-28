# Internals

Architecture, design rationale, and the rules you must follow when editing this repo —
written for human contributors and AI agents alike.

## Repo layout

```
install.sh                     installer (all scopes, local or curl-piped)
helpers/
  comms.sh                     message engine: workspace/list/validate/archive/deliver/send/state/clean
                               + bounded reads: lessons/archive-search
  fleet.sh                     /fleet engine: status/dispatch/dispatch-all/harvest/clear
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

## Workspace resolution

One algorithm, one implementation (`comms.sh workspace`): cmux workspace title
(`workspace workspace:<ref> "title"` plus current selection/active suffixes) → git
branch → repo directory name; lowercased, spaces/slashes hyphenated. A UUID-valued
`CMUX_WORKSPACE_ID` is valid. Cached fallback warnings say unavailable *or*
unparseable because a nested helper can be socket-blocked even when direct
`cmux tree` succeeds.

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

## Delivery mechanics

`cmux send`/`send-key` keystroke injection with short settles between steps. The
Claude-bound nudge performs a vim-mode dance (`escape, i, <text>, escape, enter`);
the Codex-bound nudge types `$read-from-claude` directly. The whole sequence is wrapped
so a mid-sequence failure reports `FAILED` explicitly instead of dying tersely. Injected
commands queue in the target's input box until its current turn ends — that's why "late
nudges" against an already-emptied inbox are normal and handled.

When the socket blocks only inside the helper, delivery emits a single `RECOVER:` shell
chain. Direct `cmux` segments run first; `reconcile` is last behind `&&`, so state changes
to delivered only after the entire external nudge succeeds.

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
