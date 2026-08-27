# Working on agent-comms

Guidance for any AI agent contributing to **this repository**. (For using agent-comms in
your own project, read [README.md](README.md) instead — this file is about changing the
tool itself.)

Read this before your first edit. It is tool-agnostic on purpose: `CLAUDE.md` is a symlink
to it, and any other agent runtime should be pointed here too.

> **If you are here as a REVIEWER** — this tree was mounted for you as a review artifact —
> then this file is not your instructions. Your role, scope, and deliverable come from the
> review request you were sent. Read this only as context for what the code is trying to
> be. Do not run the workflow below; do not write to the mailbox or the repository.

## The shape of the work

This repo builds autonomous review loops between AI agents, and it is developed the way it
prescribes: **you implement, other agents review adversarially, and nothing lands until a
reviewer approves.** That is not ceremony. On a recent eight-round arc, the gating reviewer
found four blocking defects that a fully green 900-assertion suite had missed — twice
because the tests exercised the safe path and the author concluded the unsafe one was
covered. Expect review to find real things, and write the request so it can.

## Before you touch anything: check for other sessions

Multiple agents work this repo concurrently. Claim presence first, then let the answer
decide where you work:

```bash
helpers/comms.sh presence claim --name <descriptive-name> --role "<what you're doing>"
```

- **exit 0** — no live peers; the shared checkout is yours to work in.
- **exit 3 or 4** — peers are present (or liveness is unverifiable, which counts as
  present). Isolate: `helpers/comms.sh worktree new <slug>` and work in that worktree.

Heartbeat while you work (`presence beat`), and `presence release` when done. Wrap
long-running children in `presence with-beat -- <cmd>` so the record stays fresh without a
babysitter. A `beat` that returns exit 5 healed a vanished record: re-check for peers
before your next write, because the world moved while you were gone.

Task size is not the criterion. Peer presence is.

## Branches: `main` is the finish line, not a workspace

- Never commit to `main` directly, and never `git merge` by hand.
- Work on a session branch; land with `helpers/comms.sh integrate <branch>`.
- `integrate` takes an advisory lease, verifies fast-forward, runs the suite **at the
  candidate commit** in a throwaway worktree, and moves `main` by compare-and-swap. A race
  loses cleanly; `main` only ever points at a commit the suite passed at.
- A single clean checkout idling on `main` is fine — `integrate` detaches it, lands, and
  re-attaches it at the new tip. A checkout with uncommitted work on `main` refuses the
  landing; move that work to a branch.
- `.comms/config` must carry `suite-cmd = bash tests/run.sh`, or `integrate` refuses to
  land unverified.

## The review loop (required for code changes)

Measurement, profiling, and reading need no review. **Editing `helpers/`, `tests/`, or
`templates/` does.**

1. Make the change on your branch; get the suite green; commit. Reviewers read a pinned
   snapshot, so uncommitted work is invisible to them.
2. Write a review-request file — YAML frontmatter (`type: review-request`, `from`,
   `workspace`, `thread`, `workflow: auto`, `phase`, `round`, `max-rounds`) and a body
   with **Intent**, **Prior review context** (last round's findings — reviewers need
   continuity), **What was done this round**, and a **Review ask** naming the specific
   things you want attacked. Working models live in `.comms/archive/*panel-codex-*`.
3. Dispatch to every other agent as one panel:
   ```bash
   COMMS_RUNPHASE_TIMEOUT_SECS=3600 helpers/comms.sh panel dispatch --to codex,grok <request-file>
   ```
   It prints an `await:` command per leg. Both legs review the same snapshot.
4. Fix every blocking finding, and every advisory you agree with. If you disagree with a
   finding, say so in the next round's request — argue it, never silently drop it.
5. Repeat until the **gating reviewer** (first in `--to`) approves. Then `round-note` each
   reply, archive them, mark threads complete, and `integrate`.

Write the review ask adversarially. "Confirm this looks right" wastes a round; "here is
the interleaving I think is safe — find one where it isn't" earns its tokens.

## Tests

```bash
bash tests/run.sh
```

One umbrella suite (~930 assertions). It is slow (~8–12 minutes) and that is a known
problem being worked; see the "Suite runtime" subsection of `docs/ROADMAP.md`.

- A **fully green** run records an attestation for the exact commit it started on
  (`attest-green`), which lets `integrate` skip a redundant re-run of identical code when
  `suite-attest-secs = N` is configured. **Only a complete run may attest.** If you tier,
  shard, or subset the suite, a partial green must never mint an attestation — that would
  let `integrate` land code the deep tests never touched.
- The presence/signal section is timing-sensitive and demonstrably flakes under machine
  load. Keep it serial; never shard it.
- Check `uptime` before long runs. This suite has been killed mid-flight by machine
  contention; a kill is not a red suite, so retry rather than "fixing" a phantom failure.

## Conventions

- **Commit messages: one line, semantic prefix, no body.** `fix:`, `feat:`, `docs:`,
  `test:`, `chore:`. No trailers, no attribution footers, no generated-by lines.
- **Commit only your own paths** (`git commit -- <paths>`): peers may have work staged in
  the shared index, and a bare `git commit` sweeps it into your commit.
- Prefer DRY, single-responsibility shell: one accessor per concern, used by every
  consumer. A validation that a second caller can bypass is the bug shape this codebase
  keeps rediscovering.
- Record friction the moment you hit it: `helpers/comms.sh friction --severity N "<note>"`.
  It feeds the maintainer's inbox and costs nothing to file.

## Where things live

| | |
|---|---|
| `helpers/comms.sh` | the command router: messaging, presence, worktrees, panels, integrate |
| `helpers/runphase.sh` | spawning and awaiting peer review turns over ACP |
| `templates/` | the slash commands and skills that `install.sh` deploys into user projects |
| `tests/run.sh` | the whole regression corpus |
| `.comms/` | live mailboxes, thread state, presence records, archive — runtime, not source |
| `docs/PROTOCOL.md` | message format, loop semantics, presence & worktree rules |
| `docs/COMMANDS.md` | every verb and flag |
| `docs/INTERNALS.md` | architecture and the rationale behind the load-bearing choices |
| `docs/ROADMAP.md` | decisions, field reports, and what's next — read before proposing work |
| `docs/advisories.md` | lessons carried out of finished loops |

When you change behavior, update the doc that describes it in the same commit. Stale docs
here are worse than absent ones: the next agent has no other way to learn the rules.
