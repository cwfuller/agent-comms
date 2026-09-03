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
found four blocking defects that the fully green suite had missed — twice
because the tests exercised the safe path and the author concluded the unsafe one was
covered. Expect review to find real things, and write the request so it can.

## Before you touch anything: check for other sessions

Multiple agents work this repo concurrently. Claim presence first, then let the answer
decide where you work. **Capture and export the instance token the claim prints** — every
later presence verb requires `--name` *and* `--instance`, and `send` / `await` /
`integrate` only heartbeat on your behalf when the environment carries them:

```bash
export COMMS_PRESENCE_NAME=<descriptive-name>
CLAIM="$(helpers/comms.sh presence claim --name "$COMMS_PRESENCE_NAME" --role "<what you're doing>")"
RC=$?                                    # capture FIRST — see the warning below
export COMMS_PRESENCE_INSTANCE="$(printf '%s' "$CLAIM" | sed -n 's/.*instance: //p')"
echo "$CLAIM"; echo "presence rc=$RC"
```

**`RC=$?` must be the very next line.** The claim's exit STATUS is the isolation decision,
and any command in between — an `echo`, a check, anything — overwrites it with its own
success. On exit 4 (unreadable sessions dir, fail-closed) stdout carries only the `claimed:`
line with no peer rows, so a lost status looks exactly like a free shared checkout in the
case the protocol exists to catch.

**Only `RC` 0 permits working in the shared checkout.** Every other status isolates or
stops — there is no "probably fine" branch:

- **`RC` 0** — no REGISTERED live peers. That is not the same as "this tree is exclusively
  mine": presence answers who has CLAIMED, not whether the working tree is clean. An
  unregistered session, a human, or an open editor can all have uncommitted work here. **Run
  `git status` before you stage anything**, and treat anything you did not create as someone
  else's. (Field report 2026-09-02, a **claude** session: it read this line as permission, ran
  `git add -A`, and swept two files from a different session into its commit.)
- **`RC` 3 or 4** — peers are present (or liveness is unverifiable, which counts as
  present). Isolate: `helpers/comms.sh worktree new <slug>` and work in that worktree.
- **anything else** (e.g. 2, an invalid name; or a helper that failed outright) — the
  claim did NOT succeed, `COMMS_PRESENCE_INSTANCE` is empty, and you have no record at
  all. Stop, fix the cause, and re-claim. Do not proceed on an empty instance: every
  later verb will usage-error, and you are invisible to peers while you work.

Heartbeat while you work (`presence beat --name … --instance …`), and `presence release
--name … --instance …` when done. Wrap long-running children in `presence with-beat --name
… --instance … -- <cmd>` so the record stays fresh without a babysitter — the default TTL
is 2700s and a panel round can outlast it. A record that goes unbeaten does not vanish;
it goes **stale**, and staleness alone is never treated as death, so it lingers as an
ambiguous peer that forces everyone else to isolate. Beating is how you avoid becoming
that obstacle, not how you avoid disappearing.

**Re-check after every wait.** Direct access is re-earned, never tenured: after a reviewer
round, an `await`, or a session resume, run

```bash
helpers/comms.sh presence others --name "$COMMS_PRESENCE_NAME" --instance "$COMMS_PRESENCE_INSTANCE"
RC=$?          # same rule as the claim: the STATUS is the decision, not the output
```

and branch on `RC` exactly as above — 0 keeps the shared checkout, anything else isolates
or stops. **Do not read this off stdout.** Exit 3 prints `peer:` rows so the output looks
conclusive, but exit 4 (unreadable sessions dir) prints its ISOLATE warning on *stderr*
and leaves stdout empty — so "no peer lines" reads as "the field is free" in precisely the
fail-closed case. `presence others` also requires both flags and, unlike `send` / `await` /
`integrate`, does *not* read them from the environment.

A session that claimed `RC` 0, waited out a panel, and wrote without re-checking will
collide with the peer that arrived during the wait. A `beat` returning exit 5 healed a
vanished record and demands the same re-check.

Task size is not the criterion. Peer presence is.

## Branches: `main` is the finish line, not a workspace

- Never commit to `main` directly, and never `git merge` by hand.
- Work on a session branch; land with `helpers/comms.sh integrate <branch>`.
- `integrate` takes an advisory lease, verifies fast-forward, runs the suite **at the
  candidate commit** in a throwaway worktree, and moves `main` by compare-and-swap. A race
  loses cleanly; `main` only ever points at a commit the suite passed at.
- A single clean checkout idling on `main` is fine — `integrate` detaches it, lands, and
  re-attaches it at the new tip. It refuses when that checkout has uncommitted work, when
  its HEAD is not the current `main` tip, or when more than one worktree holds `main`. To
  move a working checkout off `main`, run `helpers/comms.sh workspace set <name>` FIRST
  (pins mailbox identity so the branch switch cannot flap message prefixes), then
  `git checkout -b <branch>`.
- `.comms/config` must carry a single non-empty `suite-cmd` line or `integrate` refuses to
  land unverified; in this repo that value is `bash tests/run.sh`. Duplicate `suite-cmd`
  or `suite-attest-secs` lines are refused outright rather than resolved by precedence.

## The review loop (required for code changes)

Measurement, profiling, and reading need no review. **Editing `helpers/`, `tests/`,
`templates/`, or this file does** — `AGENTS.md` is the onboarding contract for sessions
that have no slash commands, and a defect here misleads every future agent silently. (It
earned its place in this list: review caught a lost exit status in these very
instructions, which would have sent a fresh agent into the shared checkout while peers
were live.)

1. Make the change on your branch; get the suite green; **commit before dispatching**.
   The snapshot stages your working tree — tracked edits *and* untracked files — so a
   dirty dispatch pins half-finished work as the artifact under review. A clean tree
   snapshots as HEAD, which is the thing you actually want reviewed and later landed.
2. Write a review-request file — YAML frontmatter (`type: review-request`, `from`
   [your own registered agent name], `timestamp` [**required**; validation refuses the
   message without it], `message_id` [**also required in practice**: dispatch only
   *replaces* an existing line, so omitting it leaves the legs without an authoritative
   id, replies carry no usable `in-reply-to`, and `compose` can never complete],
   `workspace`, `thread`, `workflow: auto`, `phase`, `round`,
   `max-rounds`) and a body with **Intent**, **Prior review
   context** (last round's findings — reviewers need continuity), **What was done this
   round**, and a **Review ask** naming the specific things you want attacked. Working
   models live in `.comms/archive/*panel-codex-*`.
3. Dispatch to every other agent as one panel — build the roster, never hardcode it
   (`panel dispatch` refuses a request whose `from:` appears in `--to`, so a literal
   `codex,grok` breaks the moment a non-claude agent drives):
   ```bash
   ME=<your-registered-agent-name>              # claude | codex | grok — must EQUAL the request's `from:`
   ROSTER="$(helpers/comms.sh agents --others "$ME")"    # already one comma-separated line
   COMMS_RUNPHASE_TIMEOUT_SECS=3600 helpers/comms.sh panel dispatch --to "$ROSTER" <request-file>
   ```
   Substitute your OWN agent name — do not copy a literal `claude` here, and do not copy
   `from: claude` out of an example request either. Dispatch refuses a roster containing
   the author, so impersonating another agent fails loudly; the quieter damage is a review
   attributed to an agent that did not write it. `ME` is the *registered agent* name, not
   the presence name from the section above; they are unrelated. Dispatch prints an
   `await:` command per leg, and every leg reviews the same snapshot.
4. **Wait for every leg, then compose** — `helpers/comms.sh compose --set <id>` (the set
   id is printed by dispatch; `panel status --set <id>` shows who has answered). Compose
   refuses a partial panel and labels findings by corroboration. A lone approval is not
   the gate: landing while a leg is unanswered discards a review you paid for.
5. Address every blocking finding, and every advisory you agree with. "Address" is not
   always "obey": composition gates on blockers that are **corroborated** or raised by the
   **gating reviewer**; a lone uncorroborated blocker is meant to be cross-checked, not
   automatically obeyed — that rule is what stops one noisy reviewer holding the loop
   hostage. Support is counted per DISTINCT REVIEWER at an anchor, ACROSS severities, so a
   defect one reviewer filed blocking and another filed advisory prints under *flagged at
   different severities*: it does not gate, but do not read it as weaker than a lone
   blocker — it is the corroborated case the detector was blind to until 2026-09-03.
   What you may never do is silently drop one. If you disagree, say so in the next
   round's request and argue it.
6. Repeat until the **gating reviewer** (first in the roster) approves *and* the panel is
   composed. Then `round-note` each reply, archive them, mark threads complete, and
   `integrate`.

Write the review ask adversarially. "Confirm this looks right" wastes a round; "here is
the interleaving I think is safe — find one where it isn't" earns its tokens.

## Tests

```bash
bash tests/run.sh
```

One umbrella suite. It is still slow — measured 2026-08-30 at **~563s for 1395 assertions**
on a machine at load ~10, down from **672s on the identical corpus** immediately before the
hot-wait fixes landed. Reducing it further is active work; see the "Suite runtime" subsection
of `docs/ROADMAP.md`, which carries the full profile. The cost is concentrated, not spread:
ten sections account for ~87% of runtime, and spawn overhead is ~5%, not the dominant term it
was once estimated to be.

**Read every runtime figure here as paired with its corpus size, and never compare across
them.** Three separate optimizations have each cut 20–35% *on identical trees* — the state
wait (505s → 326s) and the watchdog poll (430s → 364s), both historical matched A/Bs whose
corpus sizes were NOT recorded — so they are internally valid and comparable to nothing else,
which is precisely the drift this rule exists to stop — and the hot waits (672s → 563s, at
1387 and 1395 assertions). Absolute wall clock rose anyway, because the corpus grew from ~929
to 1395 assertions over the same period. That the first two examples cannot satisfy the rule
they illustrate is the point: the counts were not written down at the time, and no amount of
later care recovers them. A bare "the suite takes N seconds" goes stale the moment anyone lands assertions.
This is not pedantry: an unmatched baseline is exactly how a 1.6x sharding estimate survived
long enough to be planned around, and how a later session read a 594s run as a regression
against a 448s figure measured on a corpus 200 assertions smaller. If you are about to quote a
runtime, quote the assertion count with it or measure both sides yourself.

- A **fully green** run records an attestation for the exact commit it started on
  (`attest-green`), which lets `integrate` skip a redundant re-run of identical code when
  `suite-attest-secs = N` is configured. **Only a complete run may attest.** If you tier,
  shard, or subset the suite, a partial green must never mint an attestation — that would
  let `integrate` land code the deep tests never touched.
- That rule is now MECHANICAL, not procedural. `tests/expected-counts.tsv` records how many
  assertions the corpus contains (`total`) and names each assertion allowed to be skipped for
  environmental reasons (`skip_ok <id>`). Both the suite's **exit status** and the attestation
  mint require the expected number of assertions to have actually run — gating only the mint
  would leave the exit status, which `integrate` reads as its PRIMARY gate, still reporting a
  partial run as a pass. Until this landed, a run that executed 300 of 954 assertions with no
  failures was byte-identical to a full green run for every consumer.
- **Changing what the corpus covers is therefore a reviewable diff**: add or remove an
  assertion and the suite goes red until `tests/expected-counts.tsv` is updated in the same
  commit. Skips are IDENTIFIED, not merely counted — `skip <id> <desc>` fails outright unless
  `<id>` is listed as `skip_ok`, AND its registered condition actually holds, AND it has not
  already been used. A named-but-unused skip ticket would otherwise be spare capacity on any
  machine where its condition is false. The contract path is NOT settable from the environment:
  `integrate` inherits the caller's env, so an override would let a branch attest against a
  reduced total, and it is read from the COMMITTED BLOB at the commit under test — not from
  the working tree — so deleting the contract and recreating it untracked with a smaller total
  reads as ABSENT and fails closed. Changing the counts therefore means committing the contract.
- `tests/section-counts.tsv` pins the counts **per section**, and it is checked the same way.
  The total proves the corpus did not SHRINK; only the per-section vector proves assertions did
  not MOVE between sections — which is what a section-function wrap or a lane split has to
  preserve, and what a total alone is blind to. Verified by control: moving one assertion across
  a section boundary leaves `passed:` identical and is caught by the vector.
- **Pin a DELTA, never an absolute, when you plan test-count changes.** In a repo with concurrent
  landings an absolute like "1109 → 1137" is a hidden dependency on nobody else shipping: it goes
  stale the moment another session lands, and the resulting red gate reads as a defect in your
  change rather than as stale arithmetic. Compute `+N` against the contract committed **at the
  commit under test**. (Found by a peer whose plan had pinned an absolute that a landing
  invalidated mid-review.)
- The gate is the `coverage_verdict` function, and the suite runs it against adversarial inputs
  as part of its own corpus (short run, absent/non-numeric/out-of-range contract, unpermitted
  skip). An `EXIT` sentinel refuses any exit-0 that never reached the gate, so the invariant is
  durable rather than positional.
- Assertion COUNTS drive that gate, so anything generating assertions dynamically must
  enumerate the **git index**, not the filesystem (`tracked_paths`). A filesystem glob would
  let a candidate delete a tracked file, recreate the path untracked before the pre-flight run,
  keep the count stable, and land a commit missing the file — `attest-green` only refuses
  TRACKED dirtiness.
- `integrate` scrubs shell-startup variables (`BASH_ENV`, `ENV`, `SHELLOPTS`, …) before running
  the suite and requires POSITIVE PROOF that it completed — its own completion line, with counts
  matching the contract committed at the candidate. Environment-conditional assertions must be
  named `skip`s, never uncounted notes: an uncounted note makes the corpus size machine-dependent,
  and a fixed contract then refuses every run on the hosts that omit them (e.g. Darwin-only ACL
  probes on Linux). An exit status alone is not evidence: a
  `BASH_ENV` hook is sourced before the script runs, so `bash tests/run.sh` can return 0 having
  executed nothing. The suite output of a run `integrate` judges is kept under `.comms/logs/`.
- The presence/signal section is timing-sensitive and demonstrably flakes under machine
  load. Keep it serial; never shard it.
- Check `uptime` before long runs. This suite has been killed mid-flight by machine
  contention; a kill is not a red suite, so retry rather than "fixing" a phantom failure.

## Conventions

- **Commit messages: one line, semantic prefix, no body.** `fix:`, `feat:`, `docs:`,
  `test:`, `chore:`. No trailers, no attribution footers, no generated-by lines.
- **Commit only your own paths** (`git commit -- <paths>`): peers may have work staged in
  the shared index, and a bare `git commit` sweeps it into your commit.
- **Never `git add -A` / `git add .` in a shared checkout.** The path-limited commit above
  protects the COMMIT; it does not protect the INDEX. `git add -A` stages every dirty file in
  the tree including work you have never seen, and it leaves it staged for whoever commits
  next. Stage explicit paths (`git add <paths>`), and verify before committing:
  ```bash
  git diff --cached --name-only        # necessary: must list ONLY files you edited
  git diff --cached                    # SUFFICIENT: the name check cannot see a foreign
                                       # HUNK inside a file you also touched
  ```
  **The name check alone is not enough.** If another session edited the same file, its hunks
  stage under a filename that looks like yours. **`git diff --cached` is the step that actually
  closes it** — read the staged diff before committing. (`git add -p` also works but needs a
  TTY, so it is a human option, not something an agent can run.)
  (codex + grok, staging-safety r1/r2.)
- **`git commit -a` is the same footgun for TRACKED files.** It needs no `add` at all and would
  have swept the modified file in the 2026-09-02 report on its own. Named here because a rule
  that lists only `git add -A` invites it. (grok, staging-safety r1.)
  A snapshot pins the WHOLE tree, so foreign files also reach your reviewers as part of the
  artifact — the claude session that filed this had to hand-write a "please ignore"
  note to a panel that had already read the foreign files.
- Prefer DRY, single-responsibility shell: one accessor per concern, used by every
  consumer. A validation that a second caller can bypass is the bug shape this codebase
  keeps rediscovering.
- Record friction the moment you hit it: `helpers/comms.sh friction --severity N "<note>"`.
  It feeds the maintainer's inbox and costs nothing to file.
- **Your session name is not your presence name.** Presence records are keyed by whatever
  `--name` you claimed under, so a peer cannot map a record back to a session by looking.
  Claim under a name that describes the work, and when a peer asks which record is yours,
  answer explicitly — never let them infer it.

## Where things live

| | |
|---|---|
| `helpers/comms.sh` | the command router: messaging, presence, worktrees, panels, integrate |
| `helpers/runphase.sh` | spawning and awaiting peer review turns over ACP |
| `templates/` | the slash commands and skills that `install.sh` deploys into user projects |
| `tests/run.sh` | the whole regression corpus |
| `.comms/` | live mailboxes, thread state, presence records, archive — runtime, not source |
| `docs/PROTOCOL.md` | message format, loop semantics, presence & worktree rules |
| `docs/COMMANDS.md` | the command reference (not exhaustive — `panel`, `compose`, `friction`, `round-note` currently live only in `helpers/comms.sh`'s header banner, which is the real catalog) |
| `docs/INTERNALS.md` | architecture and the rationale behind the load-bearing choices |
| `docs/ROADMAP.md` | decisions, field reports, and what's next — read before proposing work |
| `docs/advisories.md` | lessons carried out of finished loops |

When you change behavior, update the doc that describes it in the same commit. Stale docs
here are worse than absent ones: the next agent has no other way to learn the rules.
