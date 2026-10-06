# Command & helper reference

Every driver command, Codex skill, and helper subcommand. Commands are thin
prompt-wrappers; the shell logic lives in the installed helpers (see
[INTERNALS.md](INTERNALS.md) for why).

The same five command bodies install for Claude (`~/.claude/commands/`), Grok
(`~/.grok/commands/`), and Codex (`~/.codex/skills/<name>/SKILL.md` globally;
`.agents/skills/<name>/SKILL.md` for a local pin). Identity is `comms.sh whoami`,
never a hardcoded `from: claude`.

Invocation is not the same short name on every runtime:
- Claude: `/auto`
- Grok: `/user:auto` (global) or `/local:auto` (project pin). Bare `/auto` is Grok's
  permission-mode built-in and keeps that name.
- Codex: `$auto` (a skill). Continuation is `$read-from-codex`.

## Driver commands

### `/auto [--plan|--no-plan] [--no-route] [--max] [--reviewers a,b] [--rounds N] [--via headless] <task>`

Implement → send to the other registered agents → fix blocking findings → repeat until `APPROVE` or `N`
rounds (default 10). The task text can describe work or reference an existing plan file.
Round messages keep stable context (latest findings bundle + `git diff --stat` +
validation results), never per-finding fix narration.

The default panel is `comms.sh agents --others <driver>`: the other drivers, or — when no
other driver is registered — the driver's own review twin. Same-model review is off by
default; to include your own model, name yourself: `--reviewers claude,codex` from Claude is
your own model plus codex. In every runtime `--reviewers` resolves through
`comms.sh agents --roster <driver> <list>`, which swaps your own name for your built-in review
twin (`claude-review`, running on claude — no config), collapses repeats and refuses unknown
names (see [PROTOCOL](PROTOCOL.md#identities-and-providers-same-model-review)). A request never
goes to your own name. A panel takes one reviewer per provider — `agents --roster` and
`panel dispatch` refuse two on one, and `compose` refuses two answers from one. When the
gating reviewer shares the author's model, the loop says so.

Without `--plan` / `--no-plan`, `comms.sh route` classifies the stripped task and may
enable the approach-review phase (`plan: yes`) and recommend implementer effort.
`--plan` forces the phase; `--no-plan` skips it; `--no-route` (or `COMMS_ROUTE=0`)
skips the classifier. Fail-open is `plan: no`, never a stop. The classifier does
not pick a reviewer or the panel roster, and its effort/tier are an advisory hint for
the implementer only (the named `implementer-bump-v1` policy).

Reviewer model/effort routing is separate and helper-applied (see `review-route` and
`acp.sh resolve`): opt-in with `COMMS_REVIEW_ROUTE=1`, implement phase only.
`--no-route` puts `COMMS_ROUTE=0` inline on the loop's sends, which turns reviewer routing off too;
`--max` (or `use max` in the task) puts `COMMS_REVIEW_MAX=1` inline, which runs every reviewer at
the policy map's ceiling (strongest model, highest effort) whatever routing decided;
`--plan` / `--no-plan` do not affect it.

### `/ask [agent] [question] [--with-diff] [--with-files a,b]`

One-off judgment call — no review framing, no loop, no verdict.

**Target parse:** if the first word of the argument is a registered agent name
(`comms.sh agents` — the `.comms/config` registry; zero-config default `claude codex grok`; `gemini` is supported and opt-in via `agents =`),
it names the target and the rest is the question; otherwise the whole argument —
unrecognized first word included, unmodified — is a question to the default agent
(`comms.sh agents default`). `/ask grok is X sound?` targets grok when grok is
registered; an unregistered word (e.g. `gemini`) stays part of the question text. A review
twin (`comms.sh agents --review` — every driver has one built in, e.g. `claude-review`) is
review-only: `/ask claude-review …` is refused and nothing is sent — ask the driver that runs
on that model instead.

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
exec. Every supported agent has an ACP profile (codex, claude, grok via `grok-build`, and gemini via acpx's `gemini` profile, i.e. `gemini --acp`; gemini needs the Gemini CLI >= 0.33.0 on PATH for a consult and >= 0.39.0 for a mounted review).
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
is the only mode that deletes another agent's unread mail — it covers every registered
inbox, the review twins' included.

## Codex skills

Driver skills `$auto`, `$ask`, `$send-to-codex`, `$read-from-codex`, and `$clean-comms`
install into `~/.codex/skills/` globally and `.agents/skills/` for a local pin. They are the
same loop surface Claude and Grok get, except Codex will list both copies in the `$`
selector when a pin and a global install share a name — pick one, or disable the other
with `/skills`. A Codex session driving `$auto` uses
`comms.sh whoami` (or `COMMS_SELF=codex`) so `from:` is `codex`, not a copied Claude name.

The reviewer-side skills `$read-from-claude` and `$send-to-claude` were **DELETED** in step 4
(S4-3). Every review turn you *receive* is parent-brokered over ACP and `runphase.sh` inlines the whole
prompt, so nothing resolved them; they described a codex session authoring and sending its own
reply, which is the self-send model step 4 removed. `install.sh` removes copies an earlier
install left on disk.

**Codex sandbox note:** delivery goes over ACP and needs no socket allowance, so the
`workspace-cmux` permission profile — and the `codex-permissions` and `doctor` commands that
managed it — were removed in step 4 (S4-4). Nothing needs configuring for delivery. If a sandboxed session cannot deliver, Claude was
not notified and passive polling is not assumed: do not resend from the unchanged sandbox;
use one manual pickup for the already-persisted message.

## Helper CLI

Installed at `~/.agent-comms/` (or `<repo>/.agent-comms/` for pinned local installs).
Both agents — and you — can call these directly; they're plain bash, caller-shell
agnostic.

### `comms.sh`

Every subcommand of the router is listed here; `comms.sh help` prints the one-screen
summary kept in the script's header banner, and this table is its long form.

**Exit status, unless a row says otherwise:** `0` success; `2` a usage error (unknown option,
missing required argument) from the verbs that classify one; `1` any other failure, with a
`comms.sh: …` line on stderr. Older verbs (`list`, `archive`, `send`, `deliver`, `state`,
`verdict`, `clean`, `whoami`) report a missing or unknown argument as `1`, and every verb reports
an unregistered agent name as `1`. The exception, in every verb including those older ones and
`runphase.sh spawn`/`run`/`await`: a value-taking option with nothing after it (`presence claim
--name`) is always `2`, `<verb>: <option> needs a value`, refused before anything is written.
Verbs that a program drives classify further — `integrate`,
`verify`, `compose`, `presence`, `worktree retire`, `lessons`, `archive-search`,
`error-envelope`, `reply-check` — and their rows or sections below give the full codes.

| subcommand | effect |
|---|---|
| `help` (also `-h`, `--help`, or no subcommand) | print the header banner of `comms.sh`, the summary this table expands. An unknown subcommand exits 1 and points here |
| `root` | print the main repo's `.comms` path (worktree-safe) |
| `workspace` | print the resolved workspace name (repo pin → worktree pin → branch → repo dir) |
| `agents [default\|--drivers\|--review\|--provider <id>\|--access <id> [--json]\|--others <driver>\|--roster <driver> [a,b,...]\|--supported]` | the registry. Bare: every identity, drivers first then their review twins (zero-config: `claude codex grok claude-review codex-review grok-review`). `default`: the default target (always a driver; a twin there is refused). `--drivers`: the `agents =` line of `.comms/config`. `--review`: the built-in review twins, one `<driver>-review` per driver, each running on its driver's provider — there is no config key (a leftover `review-agents` line only warns as an unknown line). `--provider <id>`: the provider an identity runs on (a driver is its own; a twin is its driver's). `--others <driver>`: the default panel, comma-separated — every other driver, or for a lone driver its own twin; refuses a twin. `--roster <driver> [a,b,...]`: the ONE reviewer-list resolver every runtime's loop uses (`/auto`, `$auto`, `/user:auto`) — no list = `--others`; with a list each name is validated (unknown: exit 1), the driver's OWN name becomes its twin (from claude, `claude,codex` → `claude-review,codex`; from grok, `grok` → `grok-review`), repeats collapse (`claude,claude-review` → `claude-review`), order is kept so the first still gates, and two reviewers on one provider are refused (exit 2, `two reviewers on provider`); a `<driver>` that is not a driver is refused. `--supported`: the PROVIDER capability table (no identity rows; `gemini` is `interactive,acp`). `gemini` is supported but NOT in the zero-config list: a project opts in with `agents = claude codex grok gemini`, which adds `gemini-review`; `gemini` and `gemini-review` are one provider, so a roster naming both is refused. See PROTOCOL "Identities and providers" `--access <id>` prints the agent's ONE immutable access profile (`access.json`: `route_id`, `transport`, hosting `provider`, `account`, `billing`, credential REFERENCE) and its sha256 `access_digest`, read together with `agents.json` so a profile that contradicts its entry is refused here exactly as dispatch refuses it; read-only, no secret is read |
| `setup [--yes] [--show] [--set KEY=VALUE ...]` | re-runnable setup: prerequisites, agent detection (writes `agents` / `default-target` in `.comms/config`, other lines kept), reviewer containment, Jev routing (key to the 0600 `secrets` file, backend, reviewer routing, project permit), Codex reviewer runtime (the auto-detected one, and the selected explicit path when one is chosen or kept, each checked against the baseline's minimum), review timeout. Saves to `~/.agent-comms/settings`, which every helper reads below the environment and a project `.comms/settings` ([INSTALL](INSTALL.md#settings-commssh-setup)). `--yes` takes the detected defaults without prompting; `--show` prints each value and its source (never the key); `--set` writes keys directly, an empty value removes one. |
| `launch <profile> [model] [--print] [--prompt TEXT]` | launch the configured OpenCode runtime as the main coding agent in Build mode. The optional model ID stays within the profile's provider and does not change its stored pin. Sets the exact matching enabled identity, otherwise starts standalone with agent-comms identity blocked. Uses credential references at launch, preserves native permissions/config, and discovers primary-checkout skills. `--print` shows only public launch settings and does not read credentials or start the runtime; `--prompt` supplies the initial task. Exit 2 for CLI usage; 1 for invalid configuration, a review-turn caller, unavailable credentials/runtime, or registry failure. Other exits come from OpenCode. See [AGENT_PROFILES](AGENT_PROFILES.md#interactive-coding-sessions). |
| `whoami` | print the driving agent: `COMMS_SELF` → session env (`GROK_AGENT=1`, `CLAUDECODE`, `CODEX_SANDBOX`, …) → ancestor executable. Fails closed on no signal, on conflicting signals, on a review twin (it never drives), and whenever `COMMS_REVIEW_TURN` is set — runphase exports that marker for every review turn, so nothing inside one resolves to a driver; never defaults to `claude` |
| `list --as <agent> [--thread <t>]` | pending inbox messages, newest first; non-zero + "latest archived" hint when empty |
| `status` | one-screen loop summary: workspace, latest archived message + its loop fields, pending counts per inbox |
| `validate <file>` | frontmatter/body checks; reasons on stderr, non-zero on failure |
| `error-envelope <file\|->` | exit 0 (printing the provider's message) iff the whole body is a provider API error envelope rather than an answer; 1 for an answer, 3 when undecidable (no python3). Structural, never a substring match: a body that quotes an error is an answer. The one predicate runphase's broker and `acp.sh consult` both use |
| `reply-check <file\|->` | the completion-evidence form of the same check, and the decoder the broker, the consult, and the compatibility canary all share: exit 10 = answer, 11 = provider API error (its message on stdout after a `verdict: error` line), 12 = undecidable (python3 missing, the classifier did not complete, or unreadable — cause on stderr). The exit status and the stdout sentinel are a PAIR, so a crashed classifier reads as 12, never as a clean answer. `error-envelope` is a thin adapter over it |
| `verdict <file>` | normalized verdict: whitespace-stripped, uppercased, loopspec synonyms mapped (`pass` → `APPROVE`, `fail` → `REQUEST_CHANGES`) |
| `archive --as <agent> <file...>` | idempotent move to `archive/`; refuses files outside your own inbox (`<agent>` is any registered identity; its inbox is `.comms/to-<agent>/`) |
| `deliver <agent> [file]` | routes via `transport`, classifying the MESSAGE: one carrying `workflow:` is a loop, anything else is a consult/one-shot. Both resolve to `acp` (a parent-brokered turn through `runphase --via acp`), to `headless` for grok, or to `mailbox`. Prints the chosen route and outcome: `spawned` / `completed` (a foreground turn, `COMMS_WAIT=1`, which `send --wait` sets) / `no nudge needed` (pickup) / manual pickup, or a `FAILED` / `failed` warning. With no `[file]` it classifies the newest message of this workspace in the target's inbox. A delivery that fails is reported, never an error exit: the message is already on disk. An unregistered agent, and an unknown `COMMS_DELIVERY` — including the removed `cmux` — are REFUSED (exit 1), not degraded. |
| `transport <agent> [--loop\|--consult]` | print the ONE transport a message to `<agent>` would take right now — `acp`, `headless` or `mailbox`, one word — so no template re-implements the choice. Routing belongs to the agent's PROVIDER: a review twin answers exactly as its driver does. A set `COMMS_DELIVERY` wins: `acp` and `mailbox` are printed as given, and `headless` only for a provider with a brokered headless path (grok) — for any other it is refused (exit 1). Unset, `--loop` answers `acp` when the provider has an ACP profile, else `headless` when `runphase.sh` is installed and the provider allows it, else `mailbox`; the default `--consult` answers `acp` when supported, else `headless` for a non-interactive provider that allows it, else `mailbox`. `deliver` asks with `--loop` exactly when the message carries `workflow:`. Exit 2 for a missing or second agent or an unknown option; 1 for an unregistered agent or an unknown `COMMS_DELIVERY`. See "Transport selection" below |
| `send --to <agent> <file> [--wait] [--archive-inbound <file>]` | validate → deliver → record state → archive inbound, atomically; ends with a loud `RESULT:` line (`spawned`/`completed`/`manual`/`pickup`/`failed`; `delivered` and `blocked` died with cmux and are read-only history). `--wait` runs the peer turn in the foreground; success is `RESULT: completed`, never "NOT spawned". A `review-feedback` inherits the request's `artifact_id`/`head_sha` and is refused on mismatch. A `review-request` must name the tree `send` runs in: when a `cwd:` line (absolute; any directory of the tree) resolves to a different git work tree, names none, or is relative, or a `branch:` line (`refs/heads/` optional, `HEAD` for detached) is not the branch checked out here, it is refused (exit 1) before anything is written — no stamp, no snapshot, no state — and stderr names both trees and prints the command to re-run from the tree the request names (the worktree holding `branch:` when there is no `cwd:`), or says no tree matches every line. Every `cwd:`/`branch:` line is judged, not only the first; blank values and a request with neither field send exactly as before. Before any durable write it refuses a `review-request` or `question` whose `from:` equals `--to` (naming the file; for a review-request the remedy is the author's own twin, `--to <self>-review`, which `agents --roster` swaps in; for a question, another driver), and anything but a `review-request` or `error` to a review twin. It stamps `review_provider:` (the twin's driver's provider) on a `review-request` or `error` to a review twin (both start a review turn there) and strips a hand-typed one from either to a driver |
| `ask --from <driver> --to <agent> [--wait] (--file F \| words...)` | the driver-neutral one-off consult — what `/ask` does, as one verb any agent can run. Writes a `type: question` (a `## Question` body: the file's content, or the words) into `<agent>`'s inbox, validates it, prints `ask: <from> -> <to>  (<message_id>)`, then hands it to `send`, whose `RESULT:` line and exit status follow. `--from` must be a registered DRIVER and `--to` a registered agent other than `--from`; a review twin is never a consult target (it only reviews). `--wait` is `send --wait`. Exit 2 for a missing `--from`, `--to` or question, a `--file` that does not exist, a self-consult or a twin target; 1 for an unregistered name, a review identity as `--from`, or an unknown `COMMS_DELIVERY` (refused before the question is written) |
| `presence claim\|beat\|others\|release\|expire\|with-beat` | advisory multi-session coordination on `.comms/sessions/` — claim-then-check (exit 0 direct-safe / 3 peers / 4 fail-closed ambiguity), whole-file heartbeats (exit 5 = healed, re-check before writing), exact-self release, two-pass byte-identical reap with nonce tombstone covers (which `claim` itself runs, so dead records are collected without anyone invoking `expire`), an auto-adopted session pid that `claim` and `beat` both verify by `ps` (explicit `--pid` first, then `COMMS_PRESENCE_PID`, then `CLAUDE_PID`, each TRIED in turn so a stale override cannot shadow a good handle; an auto-adopted value that does not verify falls back to pid-less, while an explicit `--pid` is taken as given). `beat` AND `others` both re-pin the handle, so a RESUMED session — which runs under a new harness process — is not collected while alive, including in the window before its first heartbeat, since `others` is the re-check a resumed session runs first. `others` therefore WRITES (a successful re-check beats self) and fails closed: exit 5 when this session's own record is gone or carries a reap tombstone, exit 4 when the re-pin cannot be written, and a beat-wrapper for long-running children. See PROTOCOL "Presence & worktrees" |
| `presence` flags, per verb | `claim --name N [--role R] [--state S] [--pid P]` prints `claimed: <name>  instance: <token>`, then one `peer:` row per live or unprovably-dead peer (and per young reap cover). `beat`, `others`, `release` and `with-beat` each require `--name` AND `--instance`, as flags — none reads them from the environment: `beat [--role R] [--state S] [--pid P]` rewrites the record whole (state defaults to `working`); `others` re-checks; `release` deletes exactly this record and exits 0 whether or not it was there; `with-beat [--no-heartbeat] [--timeout-secs N [--timeout-mark FILE]] -- <cmd...>` runs the command with a `beat` every TTL/3 and returns the command's exit status — 125 when its process group survived TERM and KILL, 130/143 when the wrapper itself was interrupted — and `--no-heartbeat` keeps the supervision without beating, for a caller that holds no record. `--timeout-secs N` (0 = none, the default; at most 86400) bounds the command: past it the command's process group gets TERM and CONT, then KILL after 5s, the wrapper exits 124, and `--timeout-mark FILE` is created first — the mark, not the exit status (which the command can produce itself), is how a caller tells a timeout apart. The timeout flags on any other verb, or a bad value, are exit 2. `expire [--force <name>]` takes neither `--name` nor `--instance`: it runs the two-pass reap, and with `--force` it removes every record, observation and cover of that EXACT name — the operator's way out of a forever-ambiguous foreign record, whose instance token nobody else holds (exit 1 for an invalid `--force` name). The TTL is `COMMS_PRESENCE_TTL_SECS` (default 2700). A missing or invalid `--name` / `--instance`, a non-numeric `claim --pid`, or an unknown verb or option is exit 2 |
| `worktree new [<slug>]` | session worktree under the MAIN root's `.claude/worktrees/` on branch `worktree-<slug>`, from the LOCAL default-branch tip (auto-named when the slug is omitted); refuses without ignore coverage. A bare `worktree` with no subcommand only prints usage (exit 2) — creation is always explicit. With `COMMS_PRESENCE_NAME`/`INSTANCE` exported it stamps the session as the worktree's owner (`.comms/worktrees/<slug>.owner`). It also PINS the workspace name for the new tree — the name it resolves to at creation (the repo pin when there is one, else `worktree-<slug>`), printed as `workspace: <name> (pinned for this worktree)` — in the worktree's own git admin dir (`<git-dir>/agent-comms-workspace`), so a later `git branch -m` cannot re-key its threads under a second state file. The pin is invisible to `git status` and review snapshots, goes away with `git worktree remove`, and is outranked only by the repo pin. A pin that cannot be written is a stderr warning, not a failure |
| `worktree list` | report only: one `worktree-list v1 kind= branch= on_main= tracked= untracked= ignored_unknown= secrets= nested_git= procs= presence= locked= retire= path=` line per registered worktree. `kind` is primary, managed, subagent, mount or unmanaged; `on_main` is ancestor, cherry, squash or no; `retire` is `ok`, `never` or `blocked:<gates>`. `?` means the probe could not answer, never clean. See PROTOCOL "Worktrees & branches" |
| `worktree retire <branch> [--yes]` | retirement of ONE target, re-enumerated first; dry run unless `--yes`. Refuses (exit 3) unless the tree is managed, on `main` by ancestry, clean, holds no unknown ignored files, secrets or nested repos, has no process inside, is not your cwd, is unlocked, no live presence other than yours owns it, and the branch is neither a symbolic ref nor held by a paused rebase or bisect. Removes with `git worktree remove` (never `--force`) and a compare-and-swap branch delete (never `branch -d`); exit 4 when the branch moved after it was checked (branch kept), exit 1 for any other delete failure; both say whether the worktree was removed. `integrate` never calls it; the `/auto` driver runs it for its own worktree after a landing |
| `integrate <branch> [--landing-branch <name>]` | land on `main`, or on the local branch `<name>` for a repo whose landing branch is `master` or `develop` (default `main`, so existing callers are unchanged; see [the landing branch](#the-landing-branch)): advisory lease, ff-only, suite (config `suite-cmd = ...`) at the candidate OID in a detached worktree — a FRESH checkout with no untracked or ignored files, so `suite-cmd` must provision its own prerequisites and may leave ignored files but no git-visible changes; it is whitespace-split into argv with no shell, so point it at a committed script — then CAS `update-ref` — a race loses cleanly, main only ever advances to suite-verified commits. A prose-only tree diff (`README.md`, `LICENSE`, top-level `docs/*.md`; not `docs/loopspec/`, not `AGENTS.md`) skips the suite and does not mint an attestation. A single clean checkout idling on the landing branch at the expected tip is self-healed through the landing; `suite-attest-secs = N` config accepts a fresh same-OID `attest-green` record in place of the re-run. `suite-timeout-secs = N` bounds the suite run (default 3600, `0` = none, at most 86400): past it the suite's process group is killed (TERM, then KILL after 5s) and nothing lands. Every refusal exits with a classified code, a landing prints one `integrate-result v1` line, and so does a suite timeout (see [integrate exit codes and result line](#integrate-exit-codes-and-result-line)) |
| `verify init [--yes] [--force] [--update] [--replace-suite-cmd]` | scaffold a landing suite: detects the stack by lockfile, previews the provisioning, steps and ignore status, then writes `ci/verify.sh` (the committed template) and `ci/verify.steps` (the detected checks, written out explicitly) and, when there is no `suite-cmd` yet, sets it to `bash ci/verify.sh`, keeping every other `.comms/config` line. An EXISTING `suite-cmd` is replaced only with `--replace-suite-cmd` (with `--update` it refreshes the template, repoints `suite-cmd` and keeps `ci/verify.steps`; to change only the config line, edit `.comms/config`); `verify status` only hints whether it needs a shell. Refuses to overwrite an existing `ci/verify.sh` without `--force`; an existing `ci/verify.steps` is always kept. `--update` refreshes only a `ci/verify.sh` carrying the agent-comms version header. `--force` overwrites an existing `ci/verify.sh`, and nothing else. Every write, `--update` included, needs a terminal confirmation or `--yes`. A `.comms/config` that cannot be read stops init before anything is written. Never commits. See [verify: a landing suite for any repo](#verify-a-landing-suite-for-any-repo) |
| `verify fresh [<rev>]` | run `suite-cmd` against `<rev>` (default `HEAD`, committed content only) exactly as `integrate` would, in its own throwaway checkout, without landing: same scrub, supervision, positive proof and cleanliness check, same exit classes (14 red, 15 unverified, 17 unreadable, 18 suite timeout, 10 config) and the same `suite-timeout-secs` bound. Always runs the suite (the docs-only and attestation skips are `integrate`'s). Each run has its own tree and its own log (`.comms/logs/verify-<oid>-<run>.suite.log`), so concurrent runs never share completion evidence. Success prints `verify-result v1 status=verified cand=<oid>` (see [verify fresh exit codes and result line](#verify-fresh-exit-codes-and-result-line)) |
| `verify status` | `ok`, `missing` or `needs-shell`, a tab, then the current `suite-cmd` (`needs-shell` is a HINT: a whitespace-separated word of it looks like shell syntax — `&&`, `\|`, `;`, a redirection, a glued `&&`/`\|\|` — or it starts with `VAR=value`, none of which the no-shell argv split can run. An operator inside a word, as in `grep -Eq OK\|PASS`, is an ordinary argument. The hint can be wrong both ways, so it never authorizes a rewrite) |
| `attest-green [--passed N] [--expect <oid>]` | record "suite green at this checkout's exact HEAD" (clean tracked tree required) into the main root's `.comms/cache/suite-attest.log`; a green `tests/run.sh` records itself automatically, passing `--expect` with the commit it started on so a HEAD that moved mid-run refuses instead of inheriting the result |
| `state list \| get <thread> \| complete <thread>` | thread state inspection / closure (this workspace) |
| `state idle [--days N]` | REPORT ONLY: one `idle id=<id> idle_days= last_activity= status= awaiting= unread=` line per thread, across every workspace, that is not complete or legacy and has had neither a state change (the later of its send time and the state file's mtime) nor a message on the thread (any `.md` under `.comms/`, its inboxes or `archive/`, by mtime) for N days (default 14, 1..36500); then a summary line. `<id>` is the state file's stem. Changes nothing. A message file that cannot be read fails the report (exit 1) — nothing is called idle on partial evidence |
| `state legacy [--days N] <id>...` | mark exactly the named ids legacy — never by age alone: no ids is a usage error (exit 2), and there is no "all". Each id is re-judged at marking time with the same test as `idle` and refused (exit 3, others still processed) when it is not idle for N days, already complete or legacy, unknown, or its evidence cannot be read. A mark sets `status: legacy` and `awaiting_from: none` and records `legacy_marked_at`, `legacy_prior_status`, `legacy_prior_awaiting` and `legacy_evidence` (idle days, last activity, unread count) in the state file, keeping its mtime. Legacy is not `complete`: it only drops the thread from `stalled` and the status shout, and the next `send` on the thread resumes it as in-progress |
| `state retire \| unretire \| retired <thread>` | the caller's EXPLICIT, durable record that a thread is terminal — the only authority `clean mounts --thread` accepts. `complete`, `idle`, `legacy`, an exited queue owner and an old timestamp never are: each describes an idle round, which is what a paused or resumable loop looks like. Written by whoever owns the loop's lifecycle (Basis retires a terminal task's thread) to `.comms/state/retired/<slug>-<digest>`, keyed on a digest of the RAW thread and holding it for an exact comparison, so `a/b` and `a_b` (one `safe_name`) are retired separately. `retire` is idempotent (keeps the first `retired_at`); `unretire` withdraws it for a reopened task. `retired` prints `retired retired_at=<ts>` (exit 0), `not retired` (exit 3), or refuses a marker that does not name the thread (exit 4); `retire`/`unretire` refuse such a marker (exit 1). A thread that is empty or not one line is a usage error (exit 2) |
| `stalled [minutes]` | threads awaiting a reply longer than the threshold (default 15) |
| `clean --as <agent> [workspace\|all\|archive\|<filename>] [--yes]` | guarded delete; without `--yes` it only lists what it would delete. `workspace` (the default): this workspace's messages in `<agent>`'s own inbox and in `archive/`. `all`: every file in every registered inbox (the review twins' included) and in `archive/`, every workspace. `archive`: all of `archive/`. `<filename>`: that basename wherever it sits in a registered inbox or `archive/` (exit 1 when it is nowhere). A second positional argument is a usage error (exit 2) |
| `clean mounts [--yes] [--orphans]` | GC this repo's EXTERNAL mount store (`${XDG_STATE_HOME:-$HOME/.local/state}/agent-comms/mounts`, or `COMMS_MOUNT_BASE`); dry-run without `--yes`; scoped to this repo's `<repo-key>` and refuses the whole key if any owner is live or unprovable; `--orphans` REPORTS moved-checkout keys without deleting. Needs no `--as` |
| `clean mounts --thread <thread> [--yes]` | remove the review mounts ONE retired thread owns, and nothing else; see [clean mounts --thread](#clean-mounts---thread-one-retired-threads-review-copies). Dry-run without `--yes`. Selects nothing (exit 5) unless `state retired <thread>` holds, and refuses a held thread (exit 4). Never falls back to the whole-store GC, and never reads, claims or waits on another thread's mount. `--orphans` or any other argument with `--thread` is a usage error (exit 2) |
| `lessons [--bytes N] [--surface P] [--file F]` | bounded newest-first tail of the current worktree's `docs/advisories.md` |
| `archive-search <pattern> [--bytes N] [--limit K]` | bounded newest-first search of `archive/` across workspaces |
| `route [--probe] [--task T\|--file F\|--current-tier T\|--context-tokens N\|--] <task>` | classify an `/auto` query: `plan: yes\|no`, implementer `effort`, and abstract `tier` (`fast\|balanced\|strong`). The decision backend is **opt-in**: `COMMS_ROUTE_BACKEND=typesafe` (alias `jev`) or `COMMS_ROUTE=1`. A TypeSafe key alone does not enable it. `COMMS_ROUTE_STUB` selects the stub backend (tests). Register another backend in `helpers/route_backend.py`. Policy is composed in code (overrides, low-confidence → `balanced`, then one-step up on effort and tier, cache-sticky). Fail-open is not raised. `COMMS_ROUTE_CURRENT_TIER` / `COMMS_ROUTE_CONTEXT_TOKENS` are honoured when the flags are omitted (CLI wins; invalid ambient values are ignored). Prompt overrides still apply when an enabled backend errors or returns an unusable body. Fail-open with no backend. Never selects a reviewer or a vendor model id. `COMMS_ROUTE=0` disables. Every classification (not `disabled`) is saved to the main repo's `.comms/route-decisions/implementer/<id>.json` (UTC time, workspace, bounded state, whether anything was sent, raw answers, the ten keys) and the id printed as an eleventh line, `route_id:`, which `/auto` stamps on the loop's first request; only where git confirms the record directory and the exact record and temp paths are ignored (else a stderr note and no record); the directory is not env-settable and a failed write only warns. An identical repeat (same task, policy, backend, model, questions, current tier and context) within `COMMS_ROUTE_DEDUP_SECS` (default 900, 0 = off) answers from its record with the same `route_id` and sends nothing; fail-opens and probes are never reused. `--probe` runs the path without contacting any backend (`source: probe`, record marked `probe: true`); use it instead of a throwaway task. Optional `COMMS_ROUTE_LOG` JSONL (UTC; a reuse logs `reused`) |
| `route --shadow [--thread T] [--current-tier T] [--context-tokens N] -- <task>` | OBSERVE what the classifier would decide, without deciding anything. Emits no classify key — only `shadow-decision <id>` — so `/auto` cannot read it. Refuses unless the project key is in `route-shadow-allow`; records the raw response, the shared outbound state and the effective policy inputs under the main repo's `.comms/route-shadow/`. Records carry `role`, `policy_variant` and `rubric_version` (record v2). |
| `route --shadow --reviewer --file <review-request> [--thread T]` | the same observation for the REVIEWER rubric, through the same bounded state builder and questions as `review-route decide`. Writes nothing under `route-decisions/`, so a collection can never activate a routed turn. |
| `route-eval pool [--project DIR ...] \| label [--stdin] [--relabel] [--no-reveal] \| run --live [--missing] [--limit N] \| score [--source stored\|live] [--policy P,...] [--param role.key=value] [--json] \| status` | an operator-labelled eval set for the Jev classifiers. `pool` gathers answered, non-probe, non-stub implementer and reviewer decision records (deduped by the exact state sent) plus a shipped seed of easy tasks into `~/.agent-comms/evals/jev/` (0700/0600: it holds client task text; a home that resolves into a work tree, a `.git` directory or a bare repository, directly or by symlink, or that git cannot inspect, is refused). Fail-opens are excluded even when they kept the answers they could not map, and every pooled answer must map under the production policy. `label` is blind: Jev's answer and the loop outcome are shown only after your label is saved (`-` skips, `q` quits). `score` re-maps STORED raw answers through the production policy functions (`route_policy.map_implementer`, `route_review.map_answers`) under named candidates (`current`, `gate-0.5`, `cover-0.35`, `no-bump`) or `--param` overrides, offline: per-question accuracy, within-one-level, confusion, accuracy by confidence band, and per-policy under/match/over against your labels. More than one labeller: `label --labeler NAME` (or `--import FILE`, all-or-nothing) keeps a separate `labels-NAME.json`; `items --blind` prints only id/role/project/text so a second labeller (a person or a model) labels without Jev's answers or outcomes; `score --labeler NAME` scores against them and `score --agreement A,B` lists where two labellers differ. `run --live` is the only path that calls a backend; it refuses without the flag and re-sends a client item only while its project is in `route-shadow-allow`, re-checked before every call. A malformed stored/live answer or label is listed as unusable, never a traceback; `--param` values are validated per key (probabilities in [0,1], `bump` true/false, `plan_levels` like `2,3`). Replay passes each record's current tier, context size and overrides, so `current` reproduces production exactly. |
| `review-route decide (--request <file> \| --thread T --phase P) [--tier T] [--effort E] [--replace]` | record the reviewer routing decision for (workspace, base thread, phase): an abstract candidate `tier` (`fast\|balanced\|strong\|none`) and `effort` (`low..xhigh\|none`; `none` = keep the baseline). Made ONCE and reused every round (sticky pointer); an existing decision is returned unchanged, explicit flags against one are refused without `--replace`, and `--replace` mints a NEW id. `--tier/--effort` = an explicit OPERATOR decision (strict: the resolver refuses it rather than substituting). Otherwise it classifies the request with the reviewer rubric (`reviewer-v1`, no bump, split/tied answers go deeper, low confidence or a malformed answer = `none`), but only for a project in `route-shadow-allow` (else `not-permitted`, nothing sent), only with a measurable artifact diff (risk signals come from `git diff --numstat`, never the author's stat), and a `stub` answer is recorded but never applied. Records live in `.comms/route-decisions/<id>.json` with the bounded input, omissions, raw answer and who decided. |
| `review-route plan --to <agent>[,<agent>...] [--phase P] [--thread T]` | **read-only**: each leg's resolved route BEFORE dispatch, so a planner can tell which usage limits a panel (or a single `send`) will spend. The roster is checked by the rule `panel dispatch` uses (registered names, no repeats, one leg per provider). Per leg it asks `transport --loop` (an ACP leg runs mounted), reads — never makes — the decision in force for the BASE `--thread` (routing on and phase `implement` only, the same condition under which `send`/`panel dispatch` stamp one), and runs the same `acp.sh resolve` runphase runs. Prints one line per leg in roster order: `route-plan v1 agent=<a> provider=<p> transport=<acp-mounted\|headless\|mailbox> capability=<eligible\|fixed\|unsupported> model=<m> effort=<e> limit_id=<id> model_source=<s> effort_source=<s> routing=<on\|off> decision=<id\|none\|pending> phase=<p> map_version=<v>`. `limit_id` is the usage limit the model spends when the policy map gives it one of its own (a `limit` row — a Spark model, say), `-` for the provider's shared limit, `n/a` where agent-comms applies no model (claude, grok: the provider's own configured model runs). `decision=pending` = routing is on but no decision is in force yet; dispatch will classify, so the values shown are the fail-open baseline. Decides, records, sends and classifies nothing (no request text leaves the machine). All or nothing: a leg whose policy would be refused at run time exits 1 before any line prints; usage errors exit 2. Pins (`COMMS_ACP_CODEX_*`) and `COMMS_REVIEW_MAX` apply exactly as they will at run time. The same fields are recorded per turn in `result.json` `"route"`. |
| `review-route plan --bindings FILE [--to a,b]` | **read-only, bound mode** (see [Exact per-leg binding](#exact-per-leg-binding--panel-dispatch---bindings)): judges every leg of a `leg-bindings/1` file exactly as `panel dispatch --bindings` will and prints ALL the verdicts, one `route-plan v2 ref= agent= harness= status=ok\|refused code= route_id= transport= provider= account= billing= credential= access_digest= model= effort= model_source=bound … capability_version=1` line per leg, with the **configured** (not the expected) access values so a mismatch shows both sides. Exit 0 only when every leg would run exactly as asked, 1 when any refuses (the lines still print on stdout, unlike the all-or-nothing legacy plan), 2 usage. Decides nothing, writes no event or file, reads no credential value. `--phase`/`--thread` belong to the routed plan and are refused with it |
| `review-route capability [--json]` | **read-only negotiation**: `leg-binding-capability v1 leg-bindings=1 route-view=2 leg-metadata=1`, then one `agent=<a> class=bindable\|bindable-model-only\|unbindable\|unbindable-billing harness=<provider> reason=<why\|-> billing=<class\|->` line per registered agent. A statement of fact: `claude`, `grok`, a mailbox leg and a consult-only profile are `unbindable` (no applied and attested policy exists for them), a custom OpenCode profile is `bindable-model-only` (its pin, no effort). A caller binds legs only when it has read this line; without it every existing path is unchanged |
| `review-route lookup --thread T --phase P` / `verify <id> --thread <msg thread> --phase P [--leg-dispatch D [--leg-agent A]]` / `show <id> [--thread T] [--phase P]` / `enabled` | `lookup`: the decision in force for this workspace's thread+phase. `verify`: the id a request CARRIES must be the decision in force for the record's own thread+phase (keyed on the record, so the caller's cwd or branch cannot change the answer); only a routed panel leg its panel RECORDED (`panel dispatch` writes `.comms/route-decisions/legs/<hash>`: dispatch, the stamped decision, the raw base thread, the agents — before any leg is sent) may be that thread plus `-<agent>`, compared byte for byte — a thread merely named `x-grok`, bare or with a typed `dispatch:`, never borrows `x`'s decision. `show` refuses a foreign thread or phase. `enabled` exits 0 iff `COMMS_REVIEW_ROUTE=1` and `COMMS_ROUTE` is not `0`. `send` and `panel dispatch` call `decide` after the snapshot and stamp `route_decision:` (helper-only: every other send strips it). |
| `findings [--out F [--rebuild]] [--role gating\|shadow] [--review-set ID] [--artifact ID] [--base-sha S] [--reviewer-version V] [--prompt-version V] [--header] [<message>...]` | extract review findings to TSV (default: the whole archive, oldest first); `--out` appends and is idempotent by `finding_id`, and refuses (exit 1) a ledger whose rows carry another schema version. `--rebuild` regenerates `--out` from the archive plus the shadow store into a temporary file and moves it into place only once it is complete and well-formed. `--review-set`, `--artifact`, `--base-sha`, `--reviewer-version` and `--prompt-version` stamp those columns on the extracted rows; `--header` prints only the header. `--raw` (a body with no frontmatter) and `--probe` (per-reply counts instead of rows) are the modes the runphase broker calls; they are not a reporting surface |
| `shadow --to <agent> <review-request> [--review-set ID] [--out F] [--timeout-secs N]` | run a SECOND reviewer on the same artifact; the reply is stored but never delivered and never written to thread state. `--to` may be a review twin: capability is checked on its provider, and the private request copy is stamped with the shadow target's own `review_provider` (the original request is untouched) |
| `events [list] [--set S] [--dispatch D] [--thread T] [--kind K] [--agent A] [--role R] [--request-id Q] [--message-id M] [--limit N\|--all]` | read the coordinator's append-only log (`.comms/events.tsv`): roster planned → request persisted → dispatched → turn started → provider result → reply validated/refused → reply accepted → turn finished → composition completed. The TSV header always comes first, from the same writer as the rows. Filters are exact matches and apply before the cap; `--limit` defaults to 50, and `--all` (or `--limit 0`) removes it — use that for any read that must see the whole history. A malformed row is counted and named on stderr, never parsed. No log yet is a stderr note and exit 0; exit 2 for an unknown option or argument or a non-numeric limit, 1 when the scratch file that counts malformed rows cannot be created. See PROTOCOL "Coordinator event log" for the recovery walk |
| `events append --kind <kind> [--set\|--dispatch\|--thread\|--round\|--agent\|--role\|--artifact\|--request-id\|--message-id\|--run-dir\|--status\|--note]` | the single writer every producer calls; closed kind and role vocabularies (`--role` defaults to `gating`), per-column budgets, and a refusal — on EVERY append, against an allowlist of local filesystem types — to write the log where appends are not sound. Exit 2 for a missing or unknown kind or role; 1 when the row was not written (an unsound filesystem, or a directory or header that cannot be created) — each producer decides whether that is fatal to it |
| `snapshot [create [--with-base] \| list]` | `create` (the default) retains the tree under review — tracked edits and untracked files, minus any path under `.comms/`, `.agent-comms/` or `.claude/worktrees/` that `HEAD` does not track — as a durable git object under `refs/agent-comms/artifacts/` and prints its id (a clean tree prints `HEAD`'s commit); `create --with-base` prints `artifact_id<TAB>base_sha` from the one operation. `--with-base` is an option of `create` only: `snapshot --with-base` is refused (exit 2). `list` prints the retained artifact ids |
| `workspace set <name>` | pin the repo's mailbox identity explicitly (`.comms/workspace`) — beats every other source, including a worktree pin. Name grammar `[a-z0-9][a-z0-9._-]{0,63}`, shared with `worktree new`'s pin |
| `prompt-version [--list]` | content hash of the reviewer instruction surface |
| `panel dispatch --to a,b <review-request> [--set ID]` | fan ONE review-request out to N reviewers as N parallel 2-party legs sharing one `review_set` and ONE snapshot, so every leg reviews the same artifact. The first name in `--to` is the gating reviewer. The whole roster is checked before anything durable is written: every name registered, none equal to the request's `from:`, none listed twice, no two on one provider, and the author not a review twin; the request must be a `review-request` carrying `workflow:`, and its `cwd:`/`branch:` must name the tree dispatch runs in (the same check as `send`; refused with exit 2, naming both trees and the command to re-run from the right one). Then it retains the artifact (a dirty tree is a SYNTHETIC snapshot: warned on stderr, never refused — commit first), records the reviewer routing decision when routing is on, stakes `.comms/grades/attempts/<set>`, appends one `panel-planned` event per leg, and then, leg by leg, writes the leg's index row (`.comms/grades/sets.tsv`) and sends it on thread `<thread>-<agent>` with a fresh `message_id` and `review_set:`, `dispatch:`, `artifact_id:`, `head_sha:` (and `route_decision:`) stamped in. The set id is `<thread>-<phase>-r<round>-<first 7 of the artifact id>` unless `--set` names it, sanitized and suffixed with a digest of the raw value — use the id dispatch PRINTS; the same round over the same tree yields the same id, and a re-dispatch is a new attempt of that set. Prints `panel: dispatching artifact <aid> to [<roster>] as review set <set> (gating: <agent>)`, then per leg `  leg: <agent>  thread=<leg thread>` and `send`'s output (for a spawned turn, the `await:` command to wait on), then `panel: <set> dispatched to N reviewer(s)`. A leg whose `send` reports failure prints `warning: leg for '<agent>' did not deliver — the set is incomplete` and the rest still go out. Exit 2 for a roster or request refusal; 1 for an unregistered name, an unknown `COMMS_DELIVERY`, or a snapshot, routing or event-log failure — all refused before any leg is sent |
| `panel dispatch --bindings FILE [--to a,b] <review-request> [--set ID]` | **exact per-leg binding (opt-in)**: the file's agents ARE the roster, and each leg runs exactly its named model, native effort and expected access profile or the WHOLE dispatch refuses before the first durable write (exit 1 with a `refused <agent> <code> <detail>` line per refusal; exit 2 for a malformed file or a roster violation). No tier is classified, no route chosen, no `route_decision` stamped. Ref, role and requirement are echoed into the `panel-planned` events and each leg's `result.json`. See [Exact per-leg binding](#exact-per-leg-binding--panel-dispatch---bindings) |
| `panel status [--set <id>]` | read-only. Bare: every recorded review set, newest first, as TSV under the header `set phase round legs created` (`legs` counts the set's current attempt) — a recovery DIRECTORY for a driver that lost its set id, never a verdict: re-check a set with `--set` before acting on it. With `--set`: one TSV row per planned leg under the header `reviewer thread answered verdict`, a leg counting as answered only by a valid `review-feedback` bound to this attempt's request (same round, matching `in-reply-to`) — the same binding `compose` uses. A planned leg with no index row is listed as `(no leg row recorded)`, and two answers from one provider are warned about on stderr, since `compose` will refuse them. Exit 0, including when no set is recorded yet (a stderr note); 2 outside a git repository, for an unknown option, or when the agent registry cannot be read; 1 when the set's current attempt or its roster cannot be determined — an attempt with no readable plan is UNKNOWN, never read as legacy. See PROTOCOL "Coordinator event log" |
| `compose --set <id> [--out F] [--degrade <agent>[,<agent>]]` | compose a panel's answered legs: every finding kept, labelled by support (corroborated, flagged at differing severities, uncorroborated, unanchored, advisory). Refuses (exit 3) a partial, unreadable, same-provider or superseded panel. `--degrade a,b` composes without the named legs, but only legs that are missing AND whose own log rows prove they could not review (a failed `reason=no-output` or `reason=policy-unapplied` run, with nothing of that leg still in flight); the reduction is logged first and the composition is labelled DEGRADED. Dropping a leg is the operator's call, never the driver's. `--out F` writes the prose to `F`. A published composition ends stdout with one `compose-result v1` line (see [compose result line](#compose-result-line)). Exit 0 published; 3 refused; 2 for a missing `--set`, an unknown option or argument, no recorded review sets, or a set with no legs; 1 when the log cannot say which attempt is current or the composition cannot be buffered |
| `friction [--thread T] [--severity 1-5] <note...>` | record harness friction the moment you hit it: the DRIVER's report about the tool itself (the reviewer-to-driver direction is the `### Process` section). Never shown to reviewers, never fed to `lessons`. Appends one row — `timestamp project workspace thread severity head_sha note`; severity defaults to 3, 1 = cosmetic, 5 = wrong results — to the repo's `.comms/friction.tsv` AND to the global rollup `~/.agent-comms/friction.tsv` (`$AGENT_COMMS_HOME/friction.tsv` when that is set), which is the only path a note from a client repo has back to the maintainer. The note's words are joined with spaces; quote it or not. Prints `friction: recorded (severity N) -> .comms/friction.tsv + the global rollup`. Exit 2 for no note, a severity outside 1-5, an unknown option, or outside a git repository; 1 when the project log's directory cannot be created. A rollup that cannot be written is skipped without a message |
| `friction --list` | the maintainer's inbox: the global rollup across every project, header first, then worst severity first and newest first within a severity; `friction: nothing recorded yet (<path>)` when it is empty. Exit 0 |
| `round-note <reply> --note "<text>"` | record how a reviewer performed on ONE round — for the human; never shown to reviewers (a reviewer that can see its own scorecard optimises the scorecard). The counts are derived from the reply's `### Blocking` / `### Advisory` findings exactly as `findings` extracts them; the note is your assessment. Appends one row to `.comms/grades/rounds.tsv` — `timestamp thread phase round reviewer verdict blocking advisory prompt_version note usage` — where `usage` is the leg's token usage as one line of JSON, or `null` (how the run is found: `runphase.sh` below). A ledger from before the `usage` column gets the header extended and keeps its old rows short. Prints `round-note: <reviewer> r<round> <VERDICT> — N blocking, M advisory -> .comms/grades/rounds.tsv`. Exit 2 for a missing or second reply file, a missing `--note`, an unknown option, or outside a git repository; 1 when the ledger lock (`rounds.tsv.lock`) stays held for ~10s — named, never broken — or a write fails |
| `version [--json]` | the installed kernel commit and template version, read from the `install-stamp` install.sh writes beside the helpers (see [version](#version)) |

#### Exact per-leg binding — `panel dispatch --bindings`

Capability layer, Slice 7.4. A caller that has already decided each reviewer's exact **model**, **native
effort** and **expected access profile** (a router such as Basis) has this tool run exactly that, or refuse.
The tool never reclassifies a tier, picks a route, substitutes a pair or falls back to another route; pausing,
holds, budgets and which legs exist are the caller's. Nothing here assigns a model to a tier or approves a model
mapping: every model id enters from the caller. Existing callers are untouched (no `--bindings`, no new
frontmatter, no new `result.json` value except `binding: null`, `quota: null`, and the `route` view as before).

**Negotiate first**: `review-route capability` (above). Version 1: `leg-bindings=1 route-view=2 leg-metadata=1`.

**The bindings file** (`schema: "leg-bindings/1"`, strict JSON, unique keys, at most 64 KiB and 16 legs):

```json
{ "schema": "leg-bindings/1",
  "legs": [ { "ref": "res-123", "agent": "codex", "role": "gate", "requirement": "required",
              "route_id": "codex-subscription", "model": "<exact launch id>", "effort": "<native value or null>",
              "access": { "transport": "acp", "provider": "openai", "account": "primary",
                          "billing": "subscription", "credential": null } } ] }
```

`access` must be complete (a missing field is a refusal, not a wildcard). `ref`, `role` (`gate|extra`) and
`requirement` (`required|optional`) are echoed verbatim and never interpreted. `--to`, when given, must equal the
file's agents in order; the first is the gating reviewer, as ever. **Any** listed leg that fails (an optional one
included) refuses the whole dispatch: the caller re-plans and re-submits.

**Refusal codes** (stable; the detail wording may change): `agent-unbindable`, `no-access-profile`,
`access-incomplete`, `route-mismatch`, `transport-mismatch`, `provider-mismatch`, `account-mismatch`,
`billing-mismatch`, `credential-mismatch`, `model-unservable`, `model-mismatch`, `effort-refused`,
`effort-mismatch`, `capability-unsupported` (also an OpenCode profile whose connection key variable its credential mapping does not supply), `auth-login-missing`, `auth-selected-type-conflict`,
`auth-route-unsupported`, `credential-unavailable`, `pin-conflict` (a `COMMS_ACP_<P>_MODEL/EFFORT` pin that
differs, or `COMMS_REVIEW_MAX`, in the dispatching environment; an equal pin is accepted). Roster rules are the
panel's own (registered, no duplicates, author never a leg, one leg per family). One function judges a leg for
`panel dispatch`, `review-route plan --bindings` and the runner's re-check, so a plan cannot promise what dispatch
refuses. `transport-mismatch` also covers a configured transport the runner does not drive (a `cli` entry for an agent
this runner reaches over ACP), and `model-unservable` covers a custom OpenCode runtime whose executable cannot run or
reports another version than the profile pins (a bounded local `--version` probe with no credentials, before any write).
A refused dispatch snapshots nothing and writes no event, index row, attempts marker or leg file.
A refusal prints a caller-supplied expected access value only when it has the shape its field holds (a bare token, a
`env:NAME`/`keychain:service` reference, a known transport or billing class); anything else, such as a literal key
pasted as the expected credential, is reported as `<malformed, not shown>` and never echoed.

**Run-time re-check.** Each leg carries a helper-stamped `leg_binding` / `leg_binding_digest` (set only by
`send --bound-leg`; a hand-typed key is stripped). `runphase` judges the stamp again, before it mounts, launches
or prompts anything: a changed access file, profile, credential reference, login state or map ends the turn
`status=failed reason=binding-mismatch` with nothing launched. The credential is prepared from the STAMPED access
snapshot (an entry whose digest no longer matches the stamp is refused), never from whatever the file says later. The
stamp and what the run established (`bind_state`, `bind_auth`, observed pair) are persisted in the turn record, so a
runner that dies without a result is recovered by `await` with `binding` and `quota` still present and unknown
observations still unknown. `binding-mismatch` is not a degradable reason, so
compose never drops the leg silently.

**Bound environment.** The leg's child environment is scrubbed of every configured credential name (all of
`access.json`, every `agents.json` `credentials` mapping), the patterns `*_API_KEY`, `*_TOKEN`, `*_AUTH_TOKEN`,
`*_SECRET*`, `*_ACCESS_KEY*`, and the non-pattern selectors in `helpers/credential-env.tsv`; only the leg's own
`api` credential is then restored, under the variable its adapter reads. A `subscription`, `local` or `free` leg
gets none. The launcher then reads the authentication route back (selected auth type, staged login files,
credential variable) and refuses on a difference. **Residual**: a credential nobody configured, matching no
pattern and not in the table, would still pass; no name prefix is exempt (`COMMS_*`/`AGENT_COMMS_*` credential-shaped
names are removed too); a harness's own on-disk login is governed by the auth-route rows,
not by the scrub. The auth rows declare support per (adapter, billing): gemini subscription and api, codex
subscription and custom OpenCode profiles are supported; **codex `api` is `unsupported`** (no explicit, readable
API-key selection is established for the mounted adapter) and refused as `auth-route-unsupported`.

**`result.json` for a bound leg** (each key on its own line, after the string fields; `null` for a legacy leg):
`binding` `{schema, capability_version, ref, role, requirement, status: ran|refused, route_id, access_digest,
transport, provider, account, billing, credential_ref (a reference or null, never a value), expected:{model,effort},
observed:{model,effort}, auth_evidence: observed|configured, mismatches:[codes]}`. `observed` comes from the
harness's own attestation and is null per field where it gives none, never copied from `expected`. `quota`
(`leg-metadata v1`) `{schema, provider, state: observed|unsupported|unavailable|refused, source, limit_id,
window_minutes, used_percent, resets_at, refusal}`: `observed` only where a provider ledger yielded a snapshot
(codex; `rate_limits` is kept unchanged beside it), `unsupported` for providers with no rate-limit source (grok,
claude, gemini, custom profiles), `unavailable` for a supported provider with no record in the window,
`refused` only when the existing classifier named `rate-limited` or `auth-failed` (gemini), with `reset_at`
null and `reset_state: not_provided` unless a structured provider record carries one. `route` gains `route_id` and
`access_digest` (route-view 2).

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
  --no-deliver` refuses a provider that would author and send its own reply ON THE TRANSPORT IT
  WILL USE — over ACP the parent stamps and delivers, so it is honourable for any provider, and
  it is refused only where no brokered transport is available. Because for
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

#### Transport selection — loops are ACP-first, and ACP-ONLY for claude/codex

`comms.sh transport <agent> [--loop]` is the single decision point; `deliver`, the
templates, and these docs all read from it rather than each re-deciding. Routing is a property
of the PROVIDER: a review twin routes exactly as its provider does
(`transport claude-review --loop` answers what `transport claude --loop` would).

| context | default | why |
|---|---|---|
| **loop** (`auto-*`) | `acp` → `headless` (**grok only**) → `mailbox` | cost, measured on one real review turn in this repo: cold headless ~115k fresh input tokens, warm ACP ~1,061 |
| **consult** (`/ask`) | `acp`, else `mailbox` | a consult is synchronous by nature; ACP needs no pane and warm sessions cost ~1/127 the input tokens |

`--via mailbox` / `COMMS_DELIVERY=mailbox` force manual pickup: the file is written and nobody
is nudged, which is a requested outcome rather than a failure — `deliver` and `send` report it
as intent; `status` still reports the durable `manual` fact from thread state. `--via headless`
/ `COMMS_DELIVERY=headless` (grok only since step 4; refused for claude/codex) force the
detached runner.

The `cmux` pane transport was DELETED in step 4 (S4-4), along with its pacing and backoff
knobs (`COMMS_CMUX_PACE`, `COMMS_CMUX_BACKOFF`) and the `doctor`, `bind`, `reconcile`, and
`codex-permissions` commands that served it. A keystroke nudge is self-send by another name:
it tells a live agent to read and reply itself, with no parent stamping and no pinned
artifact. `COMMS_DELIVERY=cmux` is now an unknown transport and is **REFUSED** — as is any
other unrecognised value — rather than silently substituting something you did not choose.
Unset it, or pick `acp` | `headless` (grok only) | `mailbox`.

ACP-first falls back to **mailbox**, not to a pane. grok is not an `interactive` agent, so
no pane is eligible for it; claude and codex refuse a non-ACP turn outright. A missing
`runphase.sh` therefore degrades to manual pickup with a warning —
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

#### `integrate` exit codes and result line

`integrate` is meant to be driven by a program as well as a person, so its outcome is machine-readable. The human messages on stderr are unchanged; a driver reads the exit code, and on success the result line.

| Exit | Meaning | What a driver does |
| --- | --- | --- |
| 0 | landed | record the landing from the result line |
| 1 | unclassified failure | stop and surface the stderr message |
| 2 | usage: missing or unknown argument, an unresolvable branch, a malformed `--landing-branch`, an invalid presence name or instance | fix the call |
| 10 | configuration: no, empty, or duplicate `suite-cmd` (or duplicate `suite-attest-secs`), a duplicate, empty, non-numeric or out-of-range `suite-timeout-secs`, no local landing branch (`refs/heads/main` unless `--landing-branch` names another), no repository root | fix the repo's config |
| 11 | another live session holds the integrating lease | retry later |
| 12 | the candidate is not a descendant of the landing branch (`main` by default) | rebase, re-verify, retry |
| 13 | the landing branch is checked out where it cannot be healed: a dirty or moved occupant, several occupants, or one that appeared during the suite | free `main`, retry |
| 14 | the suite exited non-zero at the candidate | fix the code; full output is kept under `.comms/logs/` |
| 15 | the suite result cannot be trusted: the candidate could not be materialized, no completion line, failures despite exit 0, a partial run, or the verification tree moved or was dirtied | investigate; do not retry blindly |
| 16 | the landing branch moved during the attempt (the compare-and-swap lost); nothing landed | re-run: it re-verifies against the new tip |
| 17 | a precondition could not be read (the sessions directory, the worktree list, the `main` occupant's state, the pinned `/usr/bin/env`), or the landing ref could not be written although it had not moved (a lock, permissions, or disk fault) | fix the environment |
| 18 | the suite ran past `suite-timeout-secs`: its whole process group was killed (TERM, then KILL after a 5s grace), nothing landed, the lease is released, the verification tree is removed, and the output so far is kept under `.comms/logs/` | find the hang (or raise the bound if the suite is legitimately that slow); a blind retry will likely hang again |

On success, after the human `LANDED` line, stdout carries exactly one line:

```
integrate-result v1 status=landed cand=<oid> main_before=<oid> main_after=<oid> branch=<ref> suite=ran|skipped-docs|attested landing=<name>
```

- Fields are space-separated `key=value` pairs. Values never contain whitespace: `branch` is the argument as given, with any byte outside `A-Z a-z 0-9 . _ / @ { } ~ ^ : + -` written as `%XX`.
- `main_before` and `main_after` are the tips of the landing branch (the field names predate `--landing-branch`). `main_after` is the value this landing wrote by compare-and-swap, not a later read; another writer may have advanced the branch since.
- `landing` names the branch that was landed on, `main` unless `--landing-branch` said otherwise; it is always present, last, with the same `%XX` escaping as `branch`.
- `suite` says how the candidate was verified: the suite ran, a prose-only diff skipped it, or a fresh `attest-green` record stood in.
- A refusal prints no result line, with ONE exception: a suite timeout (exit 18) prints

  ```
  integrate-result v1 status=refused reason=suite_timeout cand=<oid> main_before=<oid> branch=<ref> timeout_secs=<n> landing=<name>
  ```

  so a driver can tell "the suite hung and was killed" from "the suite is red" without the exit code, which a wrapper can lose. `timeout_secs` is the bound that applied. `verify fresh` prints the same refusal as `verify-result v1 status=refused reason=suite_timeout cand=<oid> timeout_secs=<n>`, with the same exit 18.
- `suite-timeout-secs` in `.comms/config` is the bound: a whole number of seconds from `0` (no timeout) to `86400`; absent means 3600. An empty, signed, fractional, leading-zero, out-of-range or duplicate value refuses with exit 10 before any suite runs. The suite always runs in its OWN process group under `presence with-beat`, so the kill never reaches `integrate` or its caller, and its stdin is `/dev/null` (a background process group that reads the terminal is stopped by SIGTTIN, which is a hang of exactly this shape).
- Parsers must ignore unknown keys; a breaking change bumps `v1`.

##### The landing branch

`--landing-branch <name>` makes `integrate` land on the local branch `<name>` instead of `main`. Every read and write of the landing ref follows it: the expected-tip read, the ancestry proof (exit 12 names the branch), the never-occupy and idle-checkout self-heal checks, the compare-and-swap `update-ref`, the `LANDED ... as <name>` line and the `integrate-result` line. The suite still runs at the candidate commit, never at the branch tip.

- The branch must exist locally (`refs/heads/<name>`); otherwise `integrate` exits 10 with `no local branch '<name>'`. It never creates one and never reads a remote ref.
- The name is restricted to `A-Z a-z 0-9 . _ / -`, must not start with `-`, and must satisfy `git check-ref-format --branch`; anything else is a usage error (2).
- Without the flag the landing branch is `main`, and a repo with no `main` refuses with exit 10 rather than guessing `master`.
- The suite's own output goes to stderr (and is kept whole under `.comms/logs/`), so nothing the suite prints can appear on stdout as a result line.
- Split stdout on LF only. The result line is printable ASCII. On every stdout line, a caller-supplied or path value has backslashes, CR, LF, other control bytes and the Unicode separators NEL, LS and PS escaped, so no value can begin a line for any reader.

#### `compose` result line

`compose` is how a driver learns what a panel decided, so a program must not have to read the prose. When a composition is published (exit 0), the LAST line of stdout is exactly one:

```
compose-result v1 gate=pass|block|escalate set=<id> dispatch=<id> round=<n> max_rounds=<n> legs=<n> answered=<n> gating=<agent> gating_verdict=<verdict> blocking=<n> corroborated=<n> gating_own=<n> lone=<n> degraded=<a,b> reason=<r>[,<r>...]
```

The gate:

| `gate` | when | what a driver does |
| --- | --- | --- |
| `pass` | every leg answered (none degraded), the gating reviewer's verdict is `APPROVE`, and there is no blocking finding at all | close the loop and land |
| `block` | a GATING blocker stands: a corroborated anchor, or a blocking finding by the gating reviewer — and the round cap has not been reached | fix the gating blockers, run the next round |
| `escalate` | anything else: a lone blocker from a non-gating reviewer, a degraded panel, a gating reviewer that was dropped or did not `APPROVE`, or any non-pass outcome on the last round | take the split to the human |

`block` outranks `escalate`: a gating blocker on a degraded panel, or beside a lone blocker, is still `block`, and its `reason` lists every condition. At the round cap (`round >= max_rounds`) nothing but `pass` survives: `block` becomes `escalate`, with `max-rounds` appended.

The fields:

- `set` is the review set; `dispatch` is the attempt composed (`-` for a set recorded before attempts existed).
- `round` is the gating leg's round from the set index. `max_rounds` is read from the request the driver wrote (the gating leg's), else from the gating reply's stamp; `-` when neither is readable, and then no `max-rounds` escalation is made — the driver's own cap applies.
- `legs` is the roster size; `answered` counts the legs whose replies were composed.
- `gating` is the gating reviewer the dispatch recorded (the roster's first). `gating_verdict` is its normalized verdict (`APPROVE`, `REQUEST_CHANGES`, `COMMENT`, …), `-` when it was dropped.
- `blocking` is every blocking finding, as the prose counts them. The gate reads three counts beside it: `corroborated` (anchors two or more reviewers filed blocking; each anchor once), `gating_own` (the gating reviewer's other blocking findings) and `lone` (every other reviewer's). Those three count anchored findings once per reviewer and anchor, and unanchored ones per finding, so they need not sum to `blocking`.
- `degraded` lists the legs dropped with `--degrade`, comma-separated; `-` when none.
- `reason` lists every condition that held, in this order: `corroborated-blocker`, `gating-blocker`, `lone-blocker`, `degraded`, `gating-absent` (the gating leg was dropped) or `gating-not-approved`, then `max-rounds`. A `pass` carries exactly `approved`.

Parsing rules:

- Fields are space-separated `key=value` pairs; a value never contains whitespace or `=`. String values are written the way `integrate`'s are: any byte outside `A-Z a-z 0-9 . _ / @ { } ~ ^ : + -` becomes `%XX`. `-` means "not applicable".
- The line is printed only after the composition is published and recorded. Every refusal (incomplete, unreadable, duplicate provider, superseded, a degraded leg that moved) exits 3 and prints no result line: its absence means nothing was gated.
- Split stdout on LF only, or decode it as UTF-8 before using any other line splitter (a lone `0x85` byte is a NEL only to a Latin-1 reader, and cannot be escaped without breaking UTF-8 text that contains it). Reviewer-authored text in the prose above has CR, every other control byte but TAB and NUL, and the separators NEL, LS and PS escaped, so no finding can begin a line for such a reader (NUL is not a line break for any of them); the result line is also always the last line. With `--out F` the prose goes to `F` and stdout carries only the `compose: wrote` notice and the result line.
- Parsers must ignore unknown keys; a breaking change bumps `v1`. The same `gate` and `reason` are recorded on the `composition-completed` event, and stated for people in the prose's `Gate:` line. The prose sections classify by support only; a gating reviewer's blocker gates wherever it is listed.

#### `version`

`comms.sh version` answers which kernel and which templates are installed, so a driver can stamp both on every attempt.

```
kernel_commit: <sha>|<sha>-dirty|unknown
template_version: sha256:<64 hex>|unknown
source: install|checkout|none
```

`--json` prints the same three keys as one object: `{"kernel_commit":"…","template_version":"…","source":"…"}`. Exit 0 in every case; `unknown` is an answer.

- `source: install` — read from `install-stamp`, which `install.sh` writes beside the helpers of every scope it installs (`~/.agent-comms/` for global, `.agent-comms/` for a local pin). It is written from the source the install copied, never recomputed later: a local pin sits inside the user's repository, whose `HEAD` is not the kernel's. The old stamp is removed before any file in that scope is replaced and the new one written only after the last one landed, so an install that fails midway leaves no stamp (`source: none`), never a stale one.
- `kernel_commit` is the source checkout's `HEAD`, with `-dirty` when any helper the install copies differed from it, including one untracked or ignored at `HEAD`. It is `unknown` for a non-git source: a piped `curl` install, a tarball, or a copy vendored inside another repository.
- `template_version` is `sha256:` over one `<sha256 of the file>  <path>` line per installed template and loopspec fragment, in install order. It is a content hash, so it changes with any template edit and a `curl` install knows it too.
- `source: checkout` — `helpers/comms.sh` run straight from an agent-comms checkout with no stamp: the kernel is that checkout's commit, `-dirty` when a tracked or untracked (not ignored) file under `helpers/` differs. Ignored files are left out here because the checkout always holds some (`__pycache__/`); the install check can include them because it names each copied helper exactly. The template version is `unknown`, because nothing installs templates from there.
- `source: none` — no stamp and not a checkout (an install that predates the stamp): both values are `unknown`. Re-run `install.sh`.
- A stamp value that is missing, duplicated or malformed reads as `unknown`, never echoed.

#### verify: a landing suite for any repo

`integrate` runs `suite-cmd` in a fresh checkout (tracked files only) with no shell, so a repo needs a committed script that installs its own dependencies and then runs its checks. `comms.sh verify init` scaffolds one; `comms.sh verify fresh` proves it before `integrate` relies on it.

```
comms.sh verify init          # preview, confirm, write ci/verify.sh + ci/verify.steps, set a missing suite-cmd
                              # (an existing suite-cmd changes only with --replace-suite-cmd)
git add ci/verify.sh ci/verify.steps && git commit -m "chore: add verify suite"
comms.sh verify fresh         # run it exactly as integrate will; nothing lands
```

`ci/verify.sh` provisions every stack it detects at the repo root with a frozen install, which never rewrites a lockfile. It checks first that each install output is gitignored.

| Lockfile | Install | Default check (no steps file) |
| --- | --- | --- |
| `package-lock.json` | `npm ci --no-audit --no-fund` | `npm run check` + `test`, else `lint` / `typecheck` / `test` (only scripts that exist) |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` (corepack when pinned) | same, with `pnpm run` |
| `yarn.lock` | `yarn install --immutable` (berry) / `--frozen-lockfile` | same, with `yarn run` |
| `bun.lock` / `bun.lockb` | `bun install --frozen-lockfile` | same, with `bun run` |
| `uv.lock` | `uv sync --frozen` | `uv run --frozen python -m pytest` (when pytest config or a tests dir exists) |
| `requirements.txt`, no `uv.lock` | `python3 -m venv .venv` + `.venv/bin/pip install -r` | `.venv/bin/python -m pytest` (same condition) |
| `Cargo.lock` | `cargo fetch --locked` | `cargo test --locked` |
| `go.sum` | `go mod download` | `go test -mod=readonly ./...` |
| `mix.lock` | `mix deps.get --check-locked` | `mix test` |

- **Rules the script enforces:**
  - More than one JavaScript lockfile is a conflict: pick one with a directive. A directive may name at most one JavaScript manager, and never pip together with uv (each pair installs into one directory).
  - `uv.lock` always wins over `requirements.txt`, even when a directive names pip.
  - A detected stack whose tool is missing fails.
  - Zero checks fails. A suite that checks nothing cannot verify a landing.
- **`ci/verify.steps`:** one shell command per line, run in order as `bash -euo pipefail -c "<line>"` with stdin closed, stopping at the first failure. Blank lines and `#` comments, indented or not, are ignored.
- **Directives:** `#@ provision: none` and `#@ provision: npm,uv` override detection.
- **Keep each line one simple command or a repo script.** A failure the line itself handles (`false || true`) or one inside a nested shell cannot be seen.
- **`CI=true` is exported** for the whole run.
- **Other install outputs must be ignored too.** The preflight knows each stack's install directory. A `requirements.txt` with `-e .` also writes `*.egg-info` beside the project: gitignore it, or the landing is refused as a dirty tree after the install.
- **Refreshing the template:** `comms.sh verify init --update` (confirm, or add `--yes`) updates `ci/verify.sh` from a newer agent-comms and leaves the steps alone.
- **`comms.sh setup`** reports the repo's landing suite and offers `verify init`, asking by name before it replaces an existing `suite-cmd`. `setup --yes` only prints the suggestion, because it never writes tracked files.

#### `verify fresh` exit codes and result line

`verify fresh` is `integrate`'s suite gate without the landing, so it shares `integrate`'s exit classes for everything it does, and a driver can run it as a preflight and read it the same way.

| Exit | Meaning |
| --- | --- |
| 0 | the suite passed at the candidate in a fresh checkout, with positive proof of completion and a clean tree afterwards |
| 2 | usage: more than one revision, an option, a revision that does not resolve to a commit, or an invalid `COMMS_PRESENCE_NAME` / `COMMS_PRESENCE_INSTANCE` |
| 10 | configuration: no repository root, no `suite-cmd` (or a duplicate or unreadable one), a `suite-cmd` that is empty once split, or a duplicate, empty, non-numeric or out-of-range `suite-timeout-secs` |
| 14 | the suite exited non-zero; its output is kept at `.comms/logs/verify-<oid>-<run>.suite.log` |
| 15 | the result cannot be trusted: the candidate could not be materialized, no completion line, failures despite exit 0, a partial run, or the verification tree moved or was dirtied |
| 17 | `/usr/bin/env` is missing, so the suite cannot be run with a scrubbed environment |
| 18 | the suite ran past `suite-timeout-secs` and its process group was killed; the output so far is kept in the run's log |

On success the last line of stdout is exactly one:

```
verify-result v1 status=verified cand=<oid>
```

- `cand` is the full commit id that was verified — the resolved `<rev>`, never the working tree. Uncommitted changes are not verified; for the default `HEAD`, tracked ones draw a stderr note saying so.
- The suite's own output goes to stderr (and whole into the log), so nothing it prints can appear on stdout as a result line. A failure prints no result line, except a suite timeout (exit 18), which prints `verify-result v1 status=refused reason=suite_timeout cand=<oid> timeout_secs=<n>`; anything but `status=verified` means nothing was verified.
- `verify fresh` itself lands nothing and records no attestation; a suite that attests its own green run (as this repo's `tests/run.sh` does) still does so. Parsers must ignore unknown keys; a breaking change bumps `v1`.

#### clean mounts --thread: one retired thread's review copies

`clean mounts` (no `--thread`) is all-or-nothing: one live or unprovable ident anywhere refuses the
whole repo-key, so on a machine that is always reviewing something it rarely runs. `--thread`
removes exactly the copies ONE retired thread owns. The caller's contract:

1. **Retire first.** `comms.sh state retire <thread>` when the work is terminal (Basis: a closed
   task), and never otherwise. Cleanup is a separate step you can run, fail and re-run after the
   landing; it is not part of it.
2. **Dry-run, then apply.** `comms.sh clean mounts --thread <thread>` lists what it would do;
   `--yes` does it. Apply re-checks every target under its own exclusion claim, so the dry run
   is a preview, never a licence.
3. **Retry on 3; hand exit 4 to a human.** A busy or half-finished target resumes on the next
   run; a refused or report-only one needs someone to look.

**What is selected.** For `<thread>` T and each agent A — every registered identity, plus every
agent the ledgers record for T, so a reviewer since dropped from the roster still counts — the
exact identities `acp_mount_ident(root, T, A)` (a direct turn) and `acp_mount_ident(root, T-A, A)`
(T's panel leg to A). Nothing is matched by name, substring, age or task number. An identity is
selected only when its ownership is PROVEN from `.comms/grades/sets.tsv` (one row per dispatched
leg) and each run's `.comms/logs/<run>/turn.tsv`: every recorded use must belong to T or to
another retired thread. The only way two threads share an identity is a leg thread that is also
a thread's literal name (T's leg to codex is `T-codex`); such a copy is report-only until both
are retired. A `tmp-<run>` throwaway (a crashed turn's leftover) is named after `safe_name` of
its run dir's basename, which several run dirs can share (`run+1`, `run_1`, or a `--dir` outside
`.comms/logs`), so the name proves nothing: it is selected only when its `.state.run` — the
physical run dir the runner recorded when it made the copy — is a run T owns. Any other copy a
run of T's could have named is report-only (`no-ownership-evidence` when it records no run,
`run-mismatch` when it records another). Every run record is enumerated before any is read: a
`.comms/logs` that is a symlink, a symlinked entry in it, or a `turn.tsv` that is not a regular
file would hide a use, so each refuses the whole call. A ledger that exists but cannot be read
refuses the whole call too (exit 4), as does a run record with no `thread` line, a `sets.tsv`
whose first line is not its header (`review_set_id`, with `thread`, `artifact_id` and
`shadow_agent` in the columns read) — a headerless index would otherwise lose its first leg row —
or a `sets.tsv` row with fewer than three columns. A record of T or `T-<agent>` with no `agent` line (a run still
writing it, or one written before records carried it) and a leg row without its agent are uses
nobody can attribute: the copy they could name is report-only (`ownership-unresolved`).

**Gates, each fail-closed and re-run under the claim:** the ident is a real directory at its own
physical path, and it, `view/` and every aside can be listed (a glob over one that cannot reads
as empty: `content-unverifiable`); no claim is live (a pid counts as dead only when `ps` says so or a v2 record's
start time differs) — read first, so a runner mid-restage is a `busy-claim` skip, not a refusal;
it holds only what the runner makes (`view/tree`, `home/`, `.state.*`, `.claim.*`,
`.aside.*/held`) and no restage no runner holds (`pending-generation`); the session record is present, well-formed
and corroborated by the acpx record for this tree, and no queue lease exists; the tree and its
admin registration name each other, the admin is not locked and git lists the tree once; and
the tree and every aside EQUAL an artifact the thread's ledger names that
`refs/agent-comms/artifacts` still retains, with no ignored residue, no nested repository
anywhere below the tree, and every gitlink path still the empty directory the checkout left
(`nested-repo` otherwise: tree identity records a submodule's HEAD, never its edits or untracked
files, and skips files dropped into an unpopulated one). A mount is dirty against HEAD by design,
so "dirty" here means "differs from its retained artifact". Under the claim the thread's
retirement, its hold and its ownership — the ledgers for a durable copy, the ledger and the
recorded run for a throwaway — are decided again from a fresh read, since a live thread can
start sharing the copy between the scan and the claim; that copy is then reported `ambiguous`
and kept.

**Removal** creates `<store>/<repo-key>/.retire.<ident>.XXXXXX`, claims it with the same
generational claim a mount takes, writes its record, renames the ident into it, drops that one
admin registration after re-verifying its back-pointer, then deletes the tombstone. No `git
worktree remove --force`, no repo-wide prune. An interrupted run leaves either the untouched
ident or a tombstone a later run finishes — only after taking its claim, so a cleanup whose
maker is still alive (or a concurrent replay) is a scoped `busy-cleanup` skip, and only a maker
proven dead is superseded. The record names its owner — the thread, the use, the agent and, for a
throwaway, the physical run — because the tombstone's name carries only the ident, which run dirs
that normalize alike share. A replay finishes it only when the record names this thread and this
exact target, and, for a throwaway, only while the moved copy's `.state.run` still names that run;
it re-reads both under the tombstone's claim. A replay destroys a payload and a registration as a
first removal does, so it passes the same authority and ownership gates: a held use is refused
(`held`) before its tombstone is touched, dry run or apply, and under the tombstone's claim the
retirement, the holds and the ledger ownership are read again (`unretired`, `held`, or
`ambiguous` for a co-owner recorded since), leaving the journal, the moved copy and its
registration as they were. Ownership that already fails at selection (a co-owner or an agentless
record present before the retry) reports the identity `ambiguous` whether its copy is still at the
ident path or already moved into a tombstone this thread's cleanup may have made: that pending
removal is reported and never replayed, and never reads as absent. A delete that stops part-way keeps that `.state.run`
beside whatever it could not remove (the run record is deleted last, and a copy already emptied
has nothing left to prove), and the record stops naming the admin registration once it is dropped
and before any payload is deleted, so a re-run finishes once the obstruction is gone and never
judges a re-created copy's same-named registration. The registration's own back-pointer (`gitdir`)
is likewise deleted last, so an admin dir that could not be fully removed (`admin-remove-failed`)
is still provably this tree's on the re-run; one with no back-pointer that still holds anything, or
one a copy re-created at the ident names, is `admin-unverified`. The record is written to a fresh
exclusively-created file and renamed into place, never through an existing name; a leftover
staging entry that is not a plain file refuses (`unsafe-path`). A tombstone (or the copy in it)
that cannot be listed refuses (`content-unverifiable`) in the dry run and before its replay touches
anything, and its record is deleted only once a listing that worked shows the tombstone holds
nothing else, so a retry after access returns finishes it. Another thread's tombstone is never selected by a
throwaway's name, and one found on a selected identity is `ambiguous` (`foreign-tombstone`), left
for that thread's own cleanup even after that thread is unretired; a record missing an owner field
refuses (`tombstone-unverifiable`). Nothing under `.comms/` is touched: replies, compositions, run records
and their `usage` stay.

One line per considered identity on stdout, then the summary, always last:

```
clean-mounts-target v1 status=<s> reason=<r> kind=durable|throwaway use=direct|panel|run agent=<a> ident=<ident> path=<path>
clean-mounts-result v1 status=<s> mode=dry-run|apply selected=N removed=N absent=N would_remove=N skipped=N incomplete=N refused=N ambiguous=N thread=<thread>
```

| target `status` | `reason` | meaning |
|---|---|---|
| `would-remove` / `removed` | `proven`, `interrupted` | selected and (to be) removed; `interrupted` = finishing an earlier run's tombstone |
| `absent` | `already-absent` | selected and already gone — an idempotent success |
| `skipped` | `busy-claim`, `busy-owner`, `busy-cleanup`, `claim-unverifiable` | a runner, a queue owner or another cleanup holds it (or `ps` could not say); re-run later |
| `incomplete` | `remove-failed`, `admin-unverified`, `admin-remove-failed` | removal started and could not finish; the tombstone is kept and the next run resumes it. Never reported as removed |
| `refused` | `unsafe-path`, `unknown-content`, `pending-generation`, `claim-unreadable`, `state-unreadable`, `state-missing`, `state-corrupt`, `owner-unprovable`, `owner-uncorroborated`, `registration-mismatch`, `registration-unverifiable`, `worktree-locked`, `dirty`, `nested-repo`, `artifact-unretained`, `content-unverifiable`, `held`, `unretired`, `ledger-unreadable`, `tombstone-failed`, `rename-failed`, `tombstone-unverifiable` | a gate failed; nothing was removed. stderr names the path and the reason |
| `ambiguous` | `no-ownership-evidence`, `ownership-unresolved`, `shared-with-live-thread`, `run-mismatch`, `foreign-tombstone`, `tombstone-mismatch` | an existing copy (or an interrupted removal's tombstone) this thread may not be the only owner of: REPORT-ONLY, never selected |

| exit | result `status` | meaning |
|---|---|---|
| 0 | `complete` (apply) / `ready` (dry run) | every selected identity is gone, or would be |
| 3 | `retry` | something was skipped or is incomplete, and nothing needs a human |
| 4 | `blocked` | something was refused or is report-only, the thread is held, or its retirement record or a ledger cannot be read |
| 5 | `not-retired` | the thread carries no retirement; nothing was selected |
| 1 | `store-error` | the mount store or this repo's git dir cannot be resolved, the store's `.root` names another checkout, or this repo's scope in the store cannot be listed (an interrupted removal's tombstone there would be invisible) |
| 2 | — | usage: a missing, empty or multi-line thread, `--orphans`, or any other argument |

Parsers must ignore unknown keys; a breaking change bumps `v1`. `COMMS_TEST_CLEAN_MOUNTS_HOOK` is
a test seam (an executable called at each boundary: `prechecked`, `claimed`, `tombstoned`,
`renamed`, `reclaimed` (a replay holds its tombstone), `unregistered`, `removed`) and is never set
in normal use.

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
An rc-0 answer that is empty, or that is the provider's own API error envelope (a
rejected `model` produces exactly this — `comms.sh error-envelope` decides), is refused
with the fallback rather than returned as an answer.

**The reviewer model/effort policy** (mounted review turns). `acp.sh resolve <agent>
[--transport acp-mounted|acp|headless|mailbox] [--tier T] [--effort E] [--decision ID] [--routing on|off]
[--phase P] [--candidate-source S]` turns an abstract candidate into the concrete pair through
`helpers/policy-map.tsv` — the ONE versioned table naming vendor models (baseline, tier→model,
effort→value, the efforts each model accepts, and a capability row per provider/transport with its
mechanism, evidence source and versions tested). Precedence per dimension: operator pin
(`COMMS_ACP_CODEX_MODEL` / `COMMS_ACP_CODEX_EFFORT`; for gemini `COMMS_ACP_GEMINI_MODEL` /
`COMMS_ACP_GEMINI_EFFORT`) > the operator's "use max" ceiling
(`COMMS_REVIEW_MAX=1`, the map's `ceiling` row) > an eligible, enabled, implement-phase route >
baseline (gpt-6.1-sol/xhigh as of map 2026-09-29.2 — the everyday default; its `ceiling` is the
frontier model, gpt-6-astra/ultra). A tier is
an ORDERED list (`fast` = gpt-6-luna then gpt-5.6-luna; `balanced` = gpt-6.1-sol, gpt-6-sol, then
gpt-5.6-terra; `strong` = gpt-6-astra): the first model the reviewer's codex runtime
can serve, by the minimum runtime on its `pair` row; a skipped preference is recorded
(`runtime-lacks:<model>`). A `disabled <provider> <transport> <model> <reason>` row marks a model the
provider has announced but nothing can serve yet: a tier skips it (`disabled:<model>`), a pin,
baseline or ceiling naming it is refused with the reason, and deleting that one row is the whole act
of enabling it — the map carries one for the not-yet-released Gemini 4 (its id is a placeholder to
replace from the CLI's model list). The pair is
validated; an invalid routed dimension falls back to the baseline once (recorded), an invalid pin,
max pair or explicit decision is refused, and so is a pinned/baseline/ceiling model the runtime
cannot serve. The record also names the usage limit the chosen model spends: `limit_id` from a
`limit <provider> <transport> <model> <limit_id>` row (a model the provider meters apart — codex's
Spark models, for example — named by the limit_id its rate-limit records report), `-` for the
provider's shared limit, `n/a` where nothing is applied. It is reported, never used to choose; the
committed map has no `limit` rows yet. `acp.sh route-view <agent> <record|-> [--format line|json]`
renders a record as the spend-planning fields `review-route plan` and `result.json` `"route"`
share. `--transport mailbox` (a leg nobody drives) resolves to `unsupported`.

**The reviewer's codex runtime.** The ACP adapter bundles its own codex and runs it unless
`CODEX_PATH` names another; the bundled copy can lag your installed CLI, and new models are served
only to new enough clients (2026-09-22: bundled 0.154.0 is refused gpt-6-luna on a ChatGPT login;
installed 0.155.1 serves gpt-6-luna and gpt-6-sol. 2026-09-29: gpt-6.1-sol, the baseline, is served
only by codex >= 0.159.0, so the bundled runtime cannot run a baseline codex review and the resolver
refuses it rather than substitute; `acp.sh doctor` and `comms.sh setup` name that refusal).
`acp.sh` resolves the runtime per turn:
`COMMS_ACP_CODEX_PATH=<path>` uses that binary, `=bundled` uses the adapter's copy, and unset it
auto-detects the installed `codex` on PATH (skipping cmux/asdf shims), falling back to bundled.
The `--version` probe is bounded (`COMMS_ACP_RUNTIME_PROBE_SECS`, default 5; the whole process group
is killed): a hanging auto-detected binary stays bundled (`runtime-probe-failed`), an explicit one
is refused.
Nothing needs setting on a new machine with a current codex installed; `acp.sh doctor` and
`acp.sh capabilities` print which runtime reviewers will use. The record carries `runtime` /
`runtime_version`, runphase passes it as the child's `CODEX_PATH` (and unsets an inherited one for
`bundled`), and the runtime is part of `policy_digest`, so an upgrade is a fresh session. Capability `eligible` may route,
`fixed` applies and attests the baseline only, `unsupported` claims nothing (`verify none`) — today
codex/acp-mounted is eligible and gemini/acp-mounted is fixed (its model has per-turn evidence, its
thinking level does not, so a routed tier is ignored and recorded `capability-fixed`; the baseline is
gemini-3.1-pro-preview at `high`, with `low` the only other mapped level, and pins can pick any mapped
model, e.g. a Flash tier model with effort `low`, `high` or `default`). The printed record (`policy_digest`, sources, `fallback`,
`map_version`, …) is what runphase persists; `policy`, `provider-config`, `policy-check` and
`policy-attest` take `--policy-file <record>` and then never re-resolve. `acp.sh capabilities`
prints the table plus both reviewer runtimes (`acp.sh doctor` also names the reviewer codex runtime and its version, and whether
that runtime can run the default (baseline) and use-max (ceiling) codex review, each with the
operator's model and effort pins applied, and the resulting (model, effort) pair judged by the same rule resolve uses, so a row is refused for a pair the model does not accept as well as for a runtime too old: a `default codex review:` and a `use-max codex review …:` line ending
`runs on this runtime` or `CANNOT RUN: <reason>`). `acp.sh runtime-check codex` is the
machine-readable form: `runtime` and `runtime_version` lines, then one TAB-separated line per row,
`<baseline|ceiling> <model> <baseline|max|pin> <minimum|-> <ok|refused> <reason|->`, the minimum
read from the model's `pair` row. Exit codes: resolve 0/1/2; check/attest 0 match, 20 mismatch, 21
undecidable; doctor 0 consults AND the default and use-max codex reviews can run, 3 no usable
node, 4 a codex review cannot run on the reviewer runtime, the runtime is refused, the Gemini CLI is
present but too old for `--acp`, or the policy map is missing, unreadable, or defective (the reason is
printed, and a final `result: FAIL` line); runtime-check 0 all ok, 4 a row refused, 1 the runtime is
refused or the policy map is missing, unreadable, or defective, 2 usage.

**The reviewer's Gemini runtime.** acpx launches the `gemini` it finds on PATH (`gemini --acp`; acpx
itself falls back to the deprecated `--experimental-acp` below 0.33.0, which this helper refuses
instead). A mounted review needs **0.39.0 or later**, the first build that writes the append-only
`.jsonl` chat record the review attestation reads (0.33–0.38 write a rewritten `.json` per session,
which cannot supply the model evidence), so every reviewer surface refuses 0.33–0.38 up front with that
reason; `consult` and `supports` need only the `--acp` flag (0.33.0). `acp.sh doctor` reports the path and version — `reviewer gemini runtime: <path> (version
X) — supports --acp` and the default/use-max gemini review lines — and treats an ABSENT Gemini CLI as
informational (it is an opt-in reviewer) but a present one below the mounted-review floor (0.39.0) as a failure (exit 4). A model the map marks `disabled` (e.g. `COMMS_ACP_GEMINI_MODEL=gemini-4-pro`) is reported `CANNOT RUN` by `doctor`/`runtime-check`, as `resolve` refuses it.
`acp.sh runtime-check gemini` is the machine-readable form (same `runtime`, `runtime_version` and row
lines; an old build exits 1 after printing its version, an absent one exits 1), `capabilities` prints
the version beside the codex runtime, `supports gemini` exits 1 for either, and `resolve gemini`
refuses rather than launch a flag the CLI lacks. There is no bundled copy and no path override. The
mounted policy is bound per leg by an isolated `GEMINI_CLI_HOME` (`provider-config gemini
[--auth-type T]` prints its `.gemini/settings.json`: `model.name`, a `modelConfigs` thinking-level
override, plan-mode model routing off, auto-update off, and only the operator's selected auth type);
the preflight reads acpx's confirmed `current_model_id`, and after the turn the model must be the one
every answered message in the CLI's own chat record names (`policy-attest`), with the thinking level read
back from the parent-written settings (`gemini-effort`) — the evidence source is recorded as
`gemini-chat-record+settings-readback`, because the CLI keeps no per-turn record of its thinking level.
`failure-reason gemini <stderr-file>` classifies a refusal (`rate-limited`, `auth-failed`).

**Reviewer containment, per provider.** `acp.sh containment <agent>` prints `backend<TAB><name>`
(exit 0) when a MOUNTED review of that agent can be contained on this host, or the reason on stderr:
exit 1 = no backend exists for this agent/OS, 3 = a backend exists but a prerequisite is missing.
`doctor` prints the same answer as `reviewer <agent> containment: ...` for codex, claude, gemini and
grok (UNAVAILABLE is a report, not a failure: an agent you do not use being uncontainable costs
nothing). `runphase.sh` acts on the same answer, so `doctor` and a refused leg cannot disagree.
`acp.sh grok-config <config.toml>` and `acp.sh grok-auth <auth.json> [refresh]` print the two files a
mounted grok turn is staged with (below).

### `box.sh`

Kernel containment for a reviewer whose tools run in its own process — grok on macOS. `runphase.sh`
calls it; it is documented here because its output is the contract.

| subcommand | effect |
|---|---|
| `supports grok` | `backend<TAB>grok-seatbelt` (exit 0); exit 1 = no backend for this OS (anything but Darwin), 3 = `/usr/bin/sandbox-exec`, `python3` or the `grok` CLI is missing (reason last on stderr) |
| `prepare grok --dir D --home H --mount M [--bin P] [--cred-dir C]` | resets `D/launch.log`, draws a fresh launch generation (`D/generation`), writes `D/box.sb` (the Seatbelt profile; paths arrive as `-D` parameters, never spliced into the text), `D/bin/box-run` (runs any command inside the profile with an allowlisted environment, `HOME` and `TMPDIR` at a per-mount scratch dir) and `D/bin/grok` (the launcher: logs a `launch ... sha=<profile hash> gen=<generation>` line to `D/launch.log`, then execs the real grok through `box-run`), then RUNS the probes below against them. `C` (default `$GROK_HOME`, else `~/.grok`) is the operator's login store: it is denied by physical path and probed, so a store outside the home is closed as well. Prints `backend`, `profile_sha`, `path_prefix` (the dir to put first on PATH for every acpx call) and `acpx_flags` (`--no-terminal --no-fs`); exit 3 with the failed probes on stderr unless every probe held |
| `client-check --dir D --flags F -- LAUNCHER...` | runs LAUNCHER (the acpx argv prefix, as `acp.sh launcher grok` prints it) against a fake ACP agent that sends `fs/read_text_file`, `fs/write_text_file` and `terminal/create` whatever was advertised, unsandboxed and under `--approve-all` as the queue owner runs. A control run with the capabilities left on must see all three honoured (else the probe proves nothing: exit 3 `could not run`); the run under F must see all three answered with an error, no file created and no file content returned. Prints `client_check<TAB>ok`; exit 3 otherwise, naming acpx `0.17.1` as the fix. The runner calls it after `prepare`, every turn |
| `launched --dir D` | exit 0 iff `D/launch.log` records a launch under the CURRENT profile hash AND the generation of THIS preparation — the runner calls it after the canary and refuses the turn (`reason: containment-unconfirmed`) if the owner never launched the contained grok. `prepare` resets the log and the generation each time, so a launch from an earlier round of a durable box dir does not count |

What the profile enforces and what it does not is the header of `helpers/box.sh`; the measured
evidence is in ROADMAP. `prepare`'s probes: positive — the scratch dir and the isolated grok home are
writable, the reviewed tree is readable; negative, each ground-truthed against the filesystem or the
live process rather than the exit status — a write to the reviewed tree, to `/tmp`, to the run directory
and to the git object store all leave no file; the real home cannot be listed and the operator's grok login
cannot be read; none of the operator's environment (`GITHUB_TOKEN`, `AWS_*`, ...) reaches the child; a
process in another session survives a `kill` from inside; `launchctl` cannot run; a loopback TCP
service on a non-443 port and a unix-domain socket (the acpx owner's control plane is one) cannot be
reached — with controls proving the tools start in the box and the same connects succeed outside it.
**acpx must run with `--no-terminal --no-fs` AND be a client that enforces them:** by default it advertises
ACP terminal and file-system capabilities and executes the agent's shell commands and file writes in its
own, unsandboxed process. acpx 0.13.1 withheld only the advertisement and still executed a request sent
anyway; 0.17.1 and later refuse it. `acp.sh launcher grok` / `acp.sh version grok` therefore pin
`ACPX_VERSION_ENFORCING` (0.17.1) for grok, other agents keep the baseline pin, and `client-check`
proves the refusal for whatever launcher is in use (an `ACPX_BIN` replaces the pin, not the check).
`acp.sh adapter codex` prints the codex ACP adapter a mounted codex review runs
(`npx -y @agentclientprotocol/codex-acp@2.1.1`; nothing for another agent), which the runner hands acpx
as `--agent` instead of the `codex` builtin: acpx 0.13.1 floats that builtin under `^1.1.5`, and 1.12.0
through 1.13.1 send a workspace-write sandbox for the `read-only` mode. `acp.sh doctor` names the pin.

### `runphase.sh` (experimental)

Headless peer-turn runner, and the host for ACP turns (`run --via acp`). Loops default to **ACP**; headless is the fallback for grok ONLY (claude and codex refuse a non-ACP turn).

**The compatibility canary.** Before every ACP review prompt, `run` pins the session mode once, then
sends a one-word `PONG` canary INTO the same session (same option vector as the real prompt) and
classifies the reply with `comms.sh reply-check`. It proves the session's runtime can serve its
configured model before the expensive review turn is spent — catching a stale bundled adapter that
would otherwise return a provider API error. A canary that is an error, times out, exits nonzero,
answers off-script, or cannot be verified refuses the turn BEFORE the real prompt, with a distinct
`reason` in `result.json` (`runtime-incompatible` / `canary-timeout` / `canary-exit-N` /
`canary-unexpected` / `reply-unverifiable`; for gemini also `rate-limited` / `auth-failed`, read from
the provider's stderr), none of which is `no-output`, so `compose` never reads
one as a droppable-leg signal. The mode is pinned ONCE (before the canary): a repeat `set-mode` after
any prompt returns "Internal error" on the live adapter, and the single pin holds through both
prompts because the mode is persistent owner state a contained canary cannot move. It runs per turn,
with no cache (`COMMS_ACP_CANARY_SECS`, default 60). Consults do not run a separate canary — a
consult's own reply is its probe, verified by the same `reply-check`.

A canary that comes back empty (exit 0, nothing but whitespace) at or past its budget is
`canary-timeout`, not `canary-unexpected`: acpx cancels a turn at its `--timeout` and exits 0 with no
output when the agent has not answered yet. That is what a codex session near its context limit does
— it compacts before it answers, and the compaction can take minutes. So a codex session that acpx
reports as `existing` (resumed) gets a canary budget of `COMMS_ACP_CANARY_COMPACT_SECS` (default 300,
or `COMMS_ACP_CANARY_SECS` if that is larger). If that canary still times out, `run` retires the
session (`acpx sessions close`, bounded by `COMMS_ACP_RETIRE_SECS`, default 60, because acpx gives
that call no deadline of its own and an owner can acknowledge it and never answer), re-creates it, runs the same bind, mode-pin and policy checks on the
new session, and sends one more canary with the ordinary budget. That happens at most once per turn
and only for `canary-timeout`; the warm context is lost. `turn.tsv` records `session_state`,
`canary_budget` and, on a retry, `canary_retry` (`retire-recreate`), `canary_retry_cause`,
`canary_retry_retired` (the old record id), `canary_retry_record` (the new one) and
`canary_retry_result` (`passed` / `failed` / `close-failed` / `close-timeout` / `not-recreated`, or `bind-refused` /
`prepare-refused` when the re-created session fails its bind or mode-pin/policy check, or `aborted` when the
runner is cancelled or dies mid-retry).

To make that rare, the mounted codex `config.toml` carries
`model_post_turn_compact_threshold_percent` (`COMMS_ACP_CODEX_COMPACT_PERCENT`, default 80; `0` omits
the key; values outside 0-100 refuse the turn). A turn that ends at or above that percent of the
model's context window compacts before it completes, inside the review's own budget, instead of
leaving the compaction to the next turn's canary.

**`--agent` is WHO reviews; the provider comes from the registry.** `spawn` and `run` take a
registered identity (default `codex`) and resolve its provider (`comms.sh agents --provider`)
before anything else reads it; a caller can never name the provider. `--provider` is the older
spelling and takes the same identity value. The identity is what the reply is stamped with
(`from: claude-review`, plus `review_provider: claude`), whose inbox the inbound is archived
from, and what events, `turn.tsv` (`agent` line) and `result.json` (`"agent"`) record; the
provider picks the acpx profile, the containment arm and the policy. An unmounted review
twin's acpx session is `<name>+as+<identity>`, so it never resumes its provider's warm
session on the same thread. The inbound `from:` must be a registered DRIVER other than the
turn's own identity, and a twin's turn is refused when its request carries no `from:` or a
`review_provider` other than the provider the twin runs on (a forged, hand-edited or pre-twin
stamp). `run` exports
`COMMS_REVIEW_TURN=<identity>` and every child launch drops the driver's session identity —
see PROTOCOL "The reviewer environment boundary".

`deliver`/`send` call `spawn` for you — `await`, `result`, `hold`, and `release` are
the operator surface:

| subcommand | effect |
|---|---|
| `run --message <file> --dir <run-dir> [--agent <identity>] [--no-deliver]` | foreground runner. `--no-deliver` produces and validates the reply in the run dir but touches **neither the mailbox nor thread state** — the measurement mode behind `comms.sh shadow` |
| `spawn --message <file> [--agent <identity>] [--via acp] [--sandbox <mode>] [--timeout-secs N]` | detach a peer turn — ACP-only for claude/codex since step 4; a non-ACP request for them is refused; prints pid + run dir immediately (plus ` agent=<id>` when the identity is not its provider's name); refuses (`HELD`) while the thread is held; won't double-spawn while a prior runner for the message is alive |
| `await <run-dir> [--timeout-secs N]` | block until the turn's `result.json` exists (or the runner dies); prints it; exit 0 only for `status=completed` |
| `result <run-dir>` | print `result.json` if present |
| `hold [thread]` | pause: block new spawns for the thread (all threads with no arg); prints the attach commands (`claude --resume <sid>` / `codex resume <tid>`) from state |
| `release [thread]` | lift a hold |

Each turn is recorded under `.comms/logs/<message_id>.<epoch>.<pid>/`: `prompt.md`
(what the peer was told), `events.ndjson` (the full JSONL event stream), `result.json`
(provider, agent, status, exit code, session id, the leg's resolved `route`, its `usage` /
`rate_limits` — below — and its staged `guidance`), `usage-snapshot.json` (the provider-record state the usage window opened on), `pid`,
`runner.log`, `policy.tsv` (the per-turn policy record resolved BEFORE the session is
launched; hash-checked before every consumer) and `turn.tsv` (identity, then
`route_decision`, `policy_*`, `requested_model/effort` at resolution time,
`policy_digest`, `acp_session`, `acpx_pinned_version`, `acpx_launcher`, `acp_adapter` (a mounted
codex turn's pinned adapter command), `adapter_check/report/source` from the preflight,
`canary_sandbox` and `observed_sandbox` (a mounted codex turn's rollout sandbox for the canary and
the review prompt: `read-only`, another type, `mixed`, `unknown`, `none` (no context in the window) or `unattested`; anything but
`read-only` refuses the turn as `containment-unconfirmed`, judged before any other failure reason; only a
failed non-timeout turn with `none` keeps its provider reason), and `observed_model/effort`, `evidence_*`,
`observed_runtime` (only when the session was created in this turn's window) and
`session_created_runtime` from the provider's own rollout — requested, adapter-reported and observed are never conflated). A
mounted codex session is named `agent-comms+mount+<ident>+p<policy_digest>`, so a
changed concrete policy is a fresh session and an unchanged one stays warm.

`result.json` `route` is what the leg was resolved to run — the fields `review-route plan`
prints after `agent=`/`provider=` (`transport`, `capability`, `model`, `effort`, `limit_id`,
`model_source`, `effort_source`, `routing`, `decision`, `phase`, `map_version`), rendered by
`acp.sh route-view` from the turn's own `policy.tsv`, so a planner can compare plan and turn field
for field. It is reported only while that record still matches the hash taken at resolution; a turn
that never resolved a policy (headless, or one that failed first) or whose record changed reads
null, never a guessed default.

`result.json` `usage` is what the leg cost, read by `helpers/leg_usage.py` from the
PROVIDER'S OWN records — never acpx's `[acpx] tokens:` line or `runner.log`. The window opens
immediately before the leg's first billable prompt (the ACP canary included) and closes when the
provider exits, before unmount, so a warm leg is not re-billed for earlier rounds. **Only a
MOUNTED leg is measured**: its cwd is unique to (thread, agent), so the records a provider keys by
cwd are that leg's alone; an unmounted leg shares the repo root with interactive sessions and
other legs and reads null. codex: the isolated `CODEX_HOME` rollout's `token_usage_record`s
summed by `turn_id`, a response recorded twice counted once, falling back to the
`token_count.info` running-total delta (a zero baseline only when nothing before the window
recorded tokens; at both ends the last spend record must itself carry the total, or null). grok: the `usage.json` `turns[]` this leg added — the session and every earlier
turn must be unchanged, since grok rewrites the file. claude: the project transcript for the
leg's cwd, deduplicated by `(message.id, requestId)`, last copy wins. Fields follow codex's convention —
`input_tokens` (INCLUDING cache reads and writes), `cached_input_tokens`,
`cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`, `total_tokens` — plus
`turns`, `responses` and `source`. gemini: the `gemini` messages of the CLI's own chat record under the
isolated `.gemini/tmp/*/chats/` (deduplicated by message id, last copy wins; `input_tokens` adds the tool-use
prompt and `output_tokens` adds the thinking tokens; cache writes, turns and rate limits are null). A codex leg also records `rate_limits`, its newest snapshot
(`limit_id`, `window_minutes`, `used_percent`, `resets_at`). **Missing is null, never 0**: no
records, an unbounded window (a file replaced, truncated or gone mid-turn), or a field some record
lacks. `round-note` copies the leg's `usage` into the last column of `.comms/grades/rounds.tsv`:
the run is the one under `logs/<in-reply-to>.*` whose `reply.md` carries the reply's
`message_id` (a shadow reply reads its store's `<name>.result.json`). Writers of one ledger are
serialised by a `rounds.tsv.lock` directory, since upgrading an old ledger's header rewrites it. A
held lock is never broken automatically — its age cannot prove the holder died — so after ~10s
`round-note` refuses and names it; remove it by hand only when no `round-note` is running.

**Shared guidance for mounted reviewer legs — `COMMS_METHOD_GUIDANCE_DIR`.** A mounted codex or grok leg runs in an
isolated home that holds only a credential and a generated config, so it reads none of the operator's global
instructions. Set `COMMS_METHOD_GUIDANCE_DIR` in `~/.agent-comms/settings` (user-only; a project `.comms/settings` is
refused with the usual message, because a project file must not choose text injected into reviewer instructions) to a
directory written by the guidance repository's `guidance.py snapshot`: `method-guidance.md` plus `snapshot.json`
(`format` 1, `guidance_file`, a 40-hex `revision`, `guidance_sha256`). Each mounted codex or grok turn stages that file as
`AGENTS.md` in the isolated home (`CODEX_HOME` / `GROK_HOME`, mode 600, written fresh and renamed into place like
`auth.json`), then `helpers/method_guidance.py verify` hashes the STAGED bytes against `guidance_sha256`. Both providers
read the mounted tree's own `AGENTS.md` files after the global one, so the reviewed project's instructions keep their
precedence. A missing, unreadable or unverifiable bundle is recorded, never fatal: nothing is staged and a copy left in
the persisted home by an earlier round is removed. Only an `AGENTS.md` that cannot be placed or removed refuses the
turn (a stale copy would otherwise keep steering reviews). Each turn appends `guidance<TAB>status<TAB>revision<TAB>sha256`
to `turn.tsv` (read back by `await` for a runner that died), a `guidance: <status>` line to `runner.log`, and sets the
`result.json` key `guidance`: `{"status", "revision", "sha256"}` with `status` `staged`, `absent` (setting unset, directory
or either file missing or not a regular file) or `rejected:<code>` (`record`, `format`, `guidance-file`, `revision`,
`digest`, `staged`, `empty`, `oversize` over 64 KiB, `hash`), revision and digest null unless staged; `null` for every leg
that is not a mounted codex or grok turn (unmounted turns, claude, gemini, OpenCode and custom profiles are not staged).
`comms.sh setup --show` lists the setting. The hash proves integrity against the sibling record, not authenticity.

Thread state mirrors the outcome (`spawned` →
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

## Configurable agent profiles

`comms.sh agents --family <id>` prints the model-family independence group.
`comms.sh agents --profile <id>` prints the canonical encoded public binding for a
custom identity (exit 1 for a built-in). `--provider` continues to mean execution
profile, and maps a custom twin to its driver. `--others` selects one reviewer per
other family; `--roster` and panel dispatch reject repeated families.

See [profile setup, credentials and containment](AGENT_PROFILES.md).
