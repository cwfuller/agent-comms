#!/bin/bash
# agent-comms shared helper — the single source of truth for shell logic that was
# previously copy-pasted across the command/skill templates (and drifted).
#
# Always executed (never sourced), always bash — the caller's shell (zsh, etc.)
# and Claude Code's slash-command $N argument substitution cannot affect it.
#
# Subcommands (docs/COMMANDS.md is the long form, with every flag and exit code):
#   help | -h | --help          print this banner (also with no subcommand)
#   root                        print the main repo's .comms path (worktree-safe)
#   workspace [set <name>]      print the mailbox identity (repo pin > worktree pin >
#                               branch > repo dir); `set` pins it repo-scoped in .comms/workspace
#   agents [default|--drivers|--review|--provider <id>|--others <driver>|
#           --family <id>|--profile <id>|--access <id> [--json]|
#           --roster <driver> [a,b,...]|--supported]
#                                  registered identities: every identity (bare), the
#                                  drivers (`agents =` in .comms/config), their built-in
#                                  review twins (<driver>-review, no config), one
#                                  identity's provider, or the provider capability table.
#                                  --others is the default panel for a driver (the OTHER
#                                  drivers; a lone driver gets its own twin). --roster is
#                                  the ONE reviewer-list resolver /auto uses: no list =
#                                  --others; a list naming the driver itself swaps in its
#                                  twin. (zero-config: claude codex grok, target codex;
#                                  gemini is supported and opt-in: `agents = ... gemini`)
#                                  --access prints an agent's ONE immutable access profile
#                                  (access.json: route, transport, hosting provider, account,
#                                  billing class, credential REFERENCE) and its digest, read
#                                  together with agents.json; read-only, no secret is read
#   whoami                      print the driving agent (COMMS_SELF → session env →
#                               ancestor executable). Fails closed on no signal, on
#                               conflicting signals, on a review-only identity, and
#                               inside a review turn; never defaults to claude.
#   launch <profile> [model] [--print] [--prompt TEXT]
#                               open an interactive coding session using an operator profile
#   list --as <agent> [--thread <t>]   pending inbox messages, newest first; exit 1 when none
#   status                      one-screen loop state: latest archive, verdict, pending counts
#   validate <file>             frontmatter + body checks; non-zero exit and reasons on failure
#   error-envelope <file|->     exit 0 (printing the provider's message) iff the body is a provider
#                               API error envelope rather than an answer; 1 = an answer; 3 = undecidable
#   reply-check <file|->        classify a reply body with a POSITIVE completion contract: exit 10 =
#                               answer, 11 = provider API error (message on stdout), 12 = undecidable
#                               (cause on stderr). The one decoder broker/consult/canary share.
#   verdict <file>              normalized (trimmed, uppercased) verdict from frontmatter
#   archive --as <agent> <file...>   idempotent move to archive/; own inbox only
#   deliver <agent> [file]      hand the message to a runner (ACP, or headless for grok); reports
#                               spawned/completed/manual pickup/FAILED explicitly — a failed
#                               delivery is reported, never an error exit (a bad agent or
#                               COMMS_DELIVERY still is). COMMS_DELIVERY=headless routes to
#                               runphase.sh instead (detached turn; grok only since step 4 —
#                               claude and codex review turns are ACP-only and refuse headless)
#   transport <agent> [--loop|--consult]
#                               which transport would actually be used right now:
#                               headless | acp | mailbox (default --consult). One decision
#                               point, so templates never re-implement surface detection.
#   send --to <agent> <file> [--wait] [--archive-inbound <file>]
#                               --wait runs the peer turn in the FOREGROUND instead of
#                               detaching — required inside sandboxes that reap the
#                               children of a finished shell command. Success is
#                               RESULT: completed (never "NOT spawned"). A review
#                               reply inherits the request's artifact_id/head_sha.
#                               A review-request whose cwd:/branch: name another tree
#                               is refused before anything is written (exit 1).
#                               validate, deliver, update thread state, then archive inbound
#   state <get|list|complete> [thread]      .comms/state/ thread ground truth (JSON)
#   state idle [--days N]       report threads with no state change and no message for N days
#                               (default 14), every workspace; changes nothing
#   state legacy [--days N] <id>...
#                               mark ONLY the named ids legacy, each re-judged idle, with the
#                               evidence written in; never by age alone. Exit 0 / 2 usage / 3 refused
#   state <retire|unretire|retired> <thread>
#                               the caller's EXPLICIT, durable "this thread is terminal" record —
#                               the only authority `clean mounts --thread` accepts (complete, idle
#                               and a stopped reviewer never are). Keyed on the RAW thread.
#                               retired: exit 0 retired / 3 not retired / 4 marker unverifiable
#   stalled [minutes]           threads awaiting a reply older than N minutes (default 15)
#   presence <claim|beat|others|release|expire|with-beat> [--name N] [--instance I]
#            [--role R] [--state S] [--pid P] [--force <name>] [--no-heartbeat]
#            [--timeout-secs N] [--timeout-mark F] [-- <cmd>]
#                               advisory multi-session coordination on .comms/sessions/.
#                               claim-then-check: 0 direct-safe / 3 peers / 4 isolate.
#                               `others` re-pins self and so WRITES: 0 / 3 / 4 as claim,
#                               5 tenure lost (own record gone). beat exit 5 = healed a
#                               vanished record; re-check before writing. Every verb but
#                               claim and expire needs --name AND --instance as flags.
#   worktree                    no subcommand: prints usage, exit 2 (never creates)
#   worktree new [<slug>]       session worktree under the MAIN root, local-tip base;
#                               stamps the creating session as owner when
#                               COMMS_PRESENCE_NAME/INSTANCE are exported, and pins
#                               the tree's workspace name (a branch rename cannot re-key it)
#   worktree list               one `worktree-list v1` line per worktree: kind (primary/
#                               managed/subagent/mount/unmanaged), branch, on_main
#                               (ancestor/cherry/squash/no), tracked/untracked dirt, ignored
#                               content off the regenerable list, secrets, nested repos,
#                               processes (lsof cwd + open files), presence, lock, and the
#                               retire verdict. Report only; `?` = could not tell
#   worktree retire <branch> [--yes]
#                               ONE target, re-enumerated first; dry run unless
#                               --yes. Refuses unless the tip is on main by ANCESTRY, the
#                               tree is managed, clean, holds no unknown ignored files,
#                               secrets or nested repos, no process uses it, no live
#                               presence owns it, it is unlocked and not your cwd. Then
#                               `git worktree remove` (never --force) and a CAS branch
#                               delete (never branch -d). Exit 0 / 2 usage / 3 refused /
#                               4 the branch moved after the check (left in place).
#                               integrate never retires anything; the /auto driver
#                               retires its own worktree after a landing.
#   integrate <branch> [--landing-branch <name>]
#                               land on main (or <name>, a local branch): lease + ff + suite at the candidate OID
#                               in a detached worktree + CAS update-ref (suite-cmd
#                               config required). A prose-only tree diff (README.md,
#                               LICENSE, top-level docs/*.md) skips the suite and
#                               does not mint an attestation. Nested docs (the
#                               review bar) and AGENTS.md are not prose. A clean
#                               checkout idling on main at the expected tip is
#                               self-healed through the landing; suite-attest-secs
#                               = N config accepts a fresh attest-green record for
#                               the candidate OID in place of the re-run.
#                               suite-timeout-secs = N (default 3600, 0 = none) bounds
#                               the suite: past it its process group is killed.
#                               Exit: 0 landed / 2 usage / 10 config / 11 lease held /
#                               12 not ff / 13 main occupied / 14 suite red /
#                               15 suite unverified / 16 CAS lost / 17 unreadable env /
#                               18 suite timed out / 1 other. A landing prints one line
#                               `integrate-result v1 status=landed cand= main_before=
#                               main_after= branch= suite=ran|skipped-docs|attested landing=`;
#                               a timeout prints `integrate-result v1 status=refused
#                               reason=suite_timeout cand= main_before= branch= timeout_secs= landing=`
#   verify init [--yes] [--force] [--update] [--replace-suite-cmd] | fresh [<rev>] | status
#                               landing suite for any repo: `init` scaffolds a committed
#                               ci/verify.sh + ci/verify.steps (stack detection, frozen
#                               installs) and sets a missing suite-cmd; `fresh [<rev>]` runs
#                               suite-cmd exactly as integrate would, without landing
#                               (integrate's exit classes; success prints one line
#                               `verify-result v1 status=verified cand=`); `status` prints
#                               ok|missing|needs-shell<TAB>suite-cmd
#   attest-green [--passed N] [--expect <oid>]
#                               record "suite green at this exact HEAD" (clean
#                               tracked tree required) for integrate's opt-in skip.
#                               --expect binds the record to the commit the CALLER
#                               verified: HEAD moving mid-run refuses instead of
#                               attesting a commit the run was not about
#   clean --as <agent> [workspace|all|archive|<file>] [--yes]
#                               guarded delete; dry-run without --yes; own-inbox default
#   clean mounts [--yes] [--orphans]
#                               GC this repo's EXTERNAL mount store (dry-run default;
#                               refuses the whole repo-key on any live owner; --orphans reports
#                               moved-checkout keys without deleting). No --as; needs no mailbox.
#   clean mounts --thread <thread> [--yes]
#                               remove ONE retired thread's proven review mounts (dry-run
#                               default). Exact identities only; a busy target is skipped,
#                               never the whole key. `clean-mounts-target v1` / `-result v1`
#                               lines; exit 0 done / 3 retry later / 4 needs a human / 5 not retired
#   lessons [--bytes N] [--surface P] [--file F]
#                               bounded newest-first tail of docs/advisories.md (whole
#                               "## " sections, never a byte slice). Exit 3 = truncated.
#   archive-search <pattern> [--bytes N] [--limit K]
#                               bounded newest-first search of archive/ across workspaces;
#                               metadata + clipped context, not whole messages. Exit 3 = truncated.
#   findings [--out F [--rebuild]] [--role gating|shadow] [--review-set ID] [--artifact ID]
#            [--base-sha S] [--reviewer-version V] [--prompt-version V] [--header] [<message>...]
#                               extract review findings to TSV (default: the whole archive,
#                               oldest first). --out appends, idempotent by finding_id;
#                               --rebuild regenerates it from the archive + shadow store.
#                               Observations only — no dispositions, no scores.
#   shadow --to <agent> <review-request> [--review-set ID] [--out F] [--timeout-secs N]
#                               have a SECOND reviewer read the same artifact. The reply is
#                               produced and stored but NEVER delivered and never written to
#                               thread state — a shadow verdict cannot gate the loop.
#   ask --from <driver> --to <agent> [--wait] (--file F | words...)
#                               one-off consult, driver-neutral: composes the question,
#                               validates it, sends it. Any driver can ask any other
#                               agent; a review twin is never a consult target.
#   route [--probe] [--task T|--file F|--current-tier T|--context-tokens N|--] <task>
#                               classify an /auto query: plan yes/no, implementer
#                               effort, and abstract tier (fast|balanced|strong).
#                               Decision backends are opt-in (COMMS_ROUTE_BACKEND
#                               or COMMS_ROUTE=1); TypeSafe/Jev is one backend.
#                               Fail-open with no backend, on timeout, or on a
#                               malformed answer. Prompt overrides win. Never
#                               selects a reviewer or a vendor model id. --probe
#                               runs the path without contacting any backend.
#   route --shadow [--thread T] [--current-tier T] [--context-tokens N] -- <task>
#   route --shadow --reviewer --file <review-request> [--thread T]
#                               OBSERVE what the classifier would decide (permitted
#                               projects only); prints only `shadow-decision <id>`.
#   route-eval pool|label|run --live|score|status
#                               operator-labelled eval set for the Jev classifiers
#                               (route_eval.py): pool saved decisions, label them
#                               blind, re-score stored answers under candidate
#                               policies offline; data in ~/.agent-comms/evals/jev.
#   review-route decide (--request <review-request> | --thread T --phase P) [--tier T] [--effort E] [--replace]
#   review-route lookup --thread T --phase P
#   review-route verify <decision-id> --thread <message thread> --phase P [--leg-dispatch D [--leg-agent A]]
#   review-route show <decision-id> [--thread T] [--phase P]
#   review-route enabled
#                               the REVIEWER routing decision for a (thread, phase): an
#                               abstract tier/effort candidate (or `none` = baseline), made ONCE
#                               and reused every round; --replace mints a new one. Only phase
#                               `implement` is routed. Classifying sends request text to the
#                               backend ONLY for a project in the route-shadow-allow permit.
#                               send / panel dispatch stamp `route_decision:` from it ONLY
#                               when COMMS_REVIEW_ROUTE=1 (and COMMS_ROUTE is not 0), and
#                               strip any hand-typed value otherwise. runphase resolves it
#                               per turn with `acp.sh resolve`. `enabled` exits 0 iff on.
#   review-route plan --to <agent>[,<agent>...] [--phase P] [--thread T]
#                               READ-ONLY: each leg's resolved route before dispatch, one
#                               `route-plan v1 agent= provider= transport= capability= model=
#                               effort= limit_id= model_source= effort_source= routing=
#                               decision= phase= map_version=` line per leg. Decides, records
#                               and sends nothing; `decision=pending` = dispatch will classify.
#                               The same fields land in each leg's result.json "route".
#   review-route plan --bindings FILE [--to a,b]
#                               READ-ONLY, bound mode: judge every leg of a leg-bindings file
#                               exactly as `panel dispatch --bindings` will and print ALL the
#                               verdicts, `route-plan v2 ref= agent= harness= status=ok|refused
#                               code= route_id= transport= provider= account= billing=
#                               credential= access_digest= model= effort= model_source=bound
#                               ... capability_version=1`, with the CONFIGURED access values.
#                               Exit 0 only if every leg would run exactly as asked, 1 if any
#                               refuses (lines still print), 2 usage. Writes nothing.
#   review-route capability [--json]
#                               READ-ONLY negotiation: `leg-binding-capability v1 leg-bindings=1
#                               route-view=2 leg-metadata=1`, then one line per registered agent:
#                               bindable | bindable-model-only | unbindable (claude, grok, a
#                               mailbox leg, a consult-only profile) | unbindable-billing, with
#                               the reason. A statement of fact, not a roadmap.
#   setup [--yes] [--show] [--set KEY=VALUE ...]
#                               configure agent-comms: agents, reviewer containment, Jev
#                               routing, codex reviewer runtime, timeouts. Re-runnable; writes
#                               ~/.agent-comms/settings (+ 0600 secrets), which every helper
#                               reads. Env vars override. See docs/INSTALL.md "Settings".
#   panel dispatch --to a,b <review-request> [--set ID]
#                               fan ONE artifact out to N reviewers as N parallel 2-party
#                               legs sharing a review_set. One snapshot for the whole set;
#                               the first reviewer gates. The roster, and that the
#                               request's cwd:/branch: name the tree it runs in, are
#                               validated before anything is written. Compose with the
#                               set id it prints.
#   panel dispatch --bindings FILE [--to a,b] <review-request> [--set ID]
#                               EXACT PER-LEG BINDING (opt-in). FILE (leg-bindings/1) names, per
#                               leg, the exact model, native effort and expected access profile;
#                               its agents ARE the roster. Every listed leg is judged before the
#                               first durable write, and ANY leg that cannot run exactly as bound
#                               (an optional one included) refuses the whole dispatch: exit 1
#                               with a `refused <agent> <code> <detail>` line per refusal, exit 2
#                               for a malformed file or a roster violation. Nothing is
#                               snapshotted, logged, indexed or sent. No tier is classified and
#                               no route chosen. Each leg carries a helper-stamped `leg_binding`
#                               the runner judges AGAIN before launching anything.
#   panel status [--set <id>]   with --set: which legs have answered, and with what
#                               verdict. Bare: every recorded review set, newest first —
#                               the recovery surface after an await dies with its session.
#   compose --set <id> [--out F] [--degrade <agent>[,<agent>]]
#                               cluster every leg's findings and label them by SUPPORT:
#                               corroborated (gates), flagged-at-differing-severities (2+
#                               reviewers, mixed severity — does NOT gate), uncorroborated
#                               (cross-check first), unanchored, advisory. Support is counted
#                               per DISTINCT REVIEWER at an anchor, across severities: a
#                               blocking and an advisory report of one defect are two
#                               reviewers, not one. Drops nothing; no model arbitrates.
#                               A published composition ends stdout with ONE line
#                               `compose-result v1 gate=pass|block|escalate set= dispatch=
#                               round= max_rounds= legs= answered= gating= gating_verdict=
#                               blocking= corroborated= gating_own= lone= degraded= reason=`
#                               (block: a corroborated or gating-reviewer blocker; escalate:
#                               a lone blocker, a degraded or unapproving gate, or any
#                               non-pass at the round cap). A refusal (exit 3) prints none.
#   events [list] [--set S] [--dispatch D] [--thread T] [--kind K] [--agent A] [--role R]
#          [--request-id Q] [--message-id M] [--limit N (default 50) | --all]
#   events append --kind <kind> [--set|--dispatch|--thread|--round|--agent|--role|--artifact|
#                               --request-id|--message-id|--run-dir|--status|--note]
#                               the coordinator's append-only log of what IT did: roster
#                               planned -> request persisted -> dispatched -> turn started
#                               -> provider result -> reply validated/refused -> reply
#                               accepted -> turn finished -> composition completed. Not the
#                               mailbox, not ACP. The durable answer to "what happened to
#                               leg X" after an await dies with its session.
#   friction [--thread T] [--severity 1-5] "<note>"  |  friction --list
#                               record harness friction the moment you hit it. Appends
#                               .comms/friction.tsv AND the global rollup
#                               ~/.agent-comms/friction.tsv. Never shown to reviewers.
#                               --list reads the GLOBAL rollup across every project: the
#                               maintainer's inbox for what actually broke in the field.
#   round-note <reply> --note "<text>"
#                               record how a reviewer performed on ONE round: counts are
#                               derived from the reply, the prose is your assessment.
#                               Appends .comms/grades/rounds.tsv, whose last column is the
#                               leg's token usage from its result.json (or null).
#                               Never shown to reviewers.
#   snapshot [create [--with-base] | list]
#                               retain the tree under review as a durable git object
#                               (a real commit object anchored under refs/agent-comms/);
#                               create --with-base prints "artifact_id<TAB>base_sha"
#   prompt-version [--list]     content hash of the reviewer instruction surface; grades
#                               are partitioned on it, never pooled across an edit
#   version [--json]            the installed kernel commit (<sha>, <sha>-dirty, or unknown
#                               for a non-git install) and template version (sha256:<hex>),
#                               read from the install-stamp install.sh writes beside the
#                               helpers; `source: install|checkout|none`. Always exit 0
#
# Environment:
#   COMMS_DELIVERY              acp | headless (grok only) | mailbox. Unset picks the ladder.
#                               Any other value — including the removed `cmux` — is REFUSED.
set -euo pipefail

die() { echo "comms.sh: $*" >&2; exit 1; }

# Absolute path to this script — emitted in wrapper-retry hints so the recovery
# command carries a literal path, not a parent-shell variable the child can't see.
# Every SELF-INVOCATION uses it too, never "$0": the verification routine re-enters this script
# from inside the fresh checkout, where a relative "$0" (`.agent-comms/comms.sh integrate`, the
# form AGENTS.md shows) no longer resolves and the suite died with 127. (field report, 2026-09-25.)
case "$0" in
  /*) SELF="$0" ;;
  *)  SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac

# User/project SETTINGS (helpers/settings.sh): fills unset variables from the settings files, so
# a setting works in every shell — including agent tool shells that never read the shell rc.
# Absent next to this script (an old install, a bare copy) it is simply skipped: env still works.
[ -f "$(dirname "$SELF")/settings.sh" ] && . "$(dirname "$SELF")/settings.sh"

main_repo_root() {
  # Consumes the WHOLE stream: `head -1` exits early and SIGPIPEs git once the worktree
  # listing outgrows the pipe buffer, which kills the caller under `set -euo pipefail`.
  git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p'
}





cmd_root() {
  local r
  r="$(main_repo_root)"
  [ -n "$r" ] || die "not inside a git repository"
  echo "$r/.comms"
}

# Filesystem-safe name (defined early — cache paths below need it).
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
# The same mapping over a stream, one name per line. `-` stays LAST in the set: GNU tr reads
# `_-\n` as a reverse range and aborts. (claude-review, slice0b r1.)
safe_name_lines() { tr -c 'A-Za-z0-9._\n-' '_'; }

# Every token must be a COMPLETE non-negative decimal. Filtering by CHARACTER is not enough,
# and the first version of this did exactly that: `1..2`, `1.2.3` and `.` are built entirely
# from permitted characters yet reach `sleep` as invalid operands, and a whitespace-only value
# passes the character filter while expanding to NO tokens — which silently reduces the retry
# loop to its final single attempt and removes the very contention retries this backoff exists
# to provide. That is fail-OPEN in the one place the delay is load-bearing. The fallback is
# ATOMIC: one bad token rejects the whole list rather than yielding a half-honoured schedule.
# (codex, suite-hot-waits r1, blocking.)

# workspace resolution AND surface picking in the same session.



repo_workspace_name() {
  local ws root_name
  ws="$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')"
  root_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')"
  # The cmux branch that used to sit here substituted <repo-name> for a generic default
  # branch, but ONLY when CMUX_WORKSPACE_ID was set — so it was already inert for every
  # non-cmux user and deleting it is behaviour-preserving. Do NOT make that substitution
  # unconditional: it would flip every unpinned repo on `main` from `main` to <repo-name>,
  # changing the message-filename prefix and hiding pending messages and thread state behind
  # the glob (field report #3). The `${ws:-$root_name}` fallback below is the detached-HEAD
  # path and is NOT cmux-related — it stays. (S4-4.)
  printf '%s\n' "${ws:-$root_name}"
}

# The ONE workspace-name grammar, shared by every writer of a pin (`workspace set`, and
# `worktree new` for the worktree it creates). The name becomes a filename prefix. 64 chars, not
# 32: `worktree new` pins `worktree-<slug>` and a slug may be 41 chars, so a 32-char cap would
# leave exactly the long-slug worktrees unpinned. Loosening only — every old name still fits.
WORKSPACE_NAME_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
workspace_name_ok() {  # <name> — whole-scalar: grep validates LINES, a pin must be ONE line
  case "$1" in ""|*$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s' "$1" | grep -qE "$WORKSPACE_NAME_RE"
}

# The WORKTREE-scoped pin lives in the checkout's OWN git admin dir (`.git/worktrees/<name>/` for a
# linked worktree): per-worktree by construction, invisible to `git status`, to review snapshots
# and to retire's cleanliness gates, and deleted by `git worktree remove` with the rest of the
# admin dir — so it needs no cleanup of its own and cannot outlive the tree it names.
worktree_pin_file() {  # [dir] -> the pin path for that checkout (the file may not exist)
  local gd
  gd="$(git -C "${1:-.}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -n "$gd" ] || return 1
  printf '%s/agent-comms-workspace\n' "$gd"
}

read_pin() {  # <file> — the first line, whitespace-stripped; empty (exit 1) when absent or blank
  local v
  [ -f "$1" ] || return 1
  v="$(head -1 "$1" 2>/dev/null | tr -d ' \t\r')"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

cmd_workspace() {
  # `workspace set <name>` writes the explicit repo-scoped pin — the mailbox
  # identity, shared by every session and worktree of this repo. Everything
  # below it (branch, dirname) is INFERENCE, and a valid-but-wrong
  # inference (title "client-backup" in the client-app repo) was cached as
  # authoritative forever and hid pending replies behind the filename glob.
  # a pin is a naming decision and outranks every inferred source
  # once a pin exists. (field report #3.)
  #
  # Order: repo pin > worktree pin > branch > directory. The worktree pin is what `worktree new`
  # writes: the name the new tree resolved to at creation, frozen so a later `git branch -m`
  # cannot re-key its threads under a second state file (basis slice 0b). The repo pin still
  # outranks it, because `workspace set` promises to name EVERY session in the repo.
  if [ "${1:-}" = "set" ]; then
    local pname="${2:-}" wroot
    [ -n "$pname" ] || usage_err "workspace set: name required"
    workspace_name_ok "$pname" \
      || usage_err "workspace set: invalid name '$(clip "$pname")' — must match [a-z0-9][a-z0-9._-]{0,63} (it becomes a filename prefix)"
    wroot="$(main_repo_root)" || usage_err "workspace set: not inside a git repository"
    [ -n "$wroot" ] || usage_err "workspace set: not inside a git repository"
    mkdir -p "$wroot/.comms" 2>/dev/null || usage_err "workspace set: cannot create $wroot/.comms"
    printf '%s\n' "$pname" > "$wroot/.comms/workspace" \
      || usage_err "workspace set: cannot write the pin"
    echo "workspace pinned to '$pname' — this file ($wroot/.comms/workspace) is now the mailbox identity for every session in this repo"
    return 0
  fi
  local pinf
  pinf="$(main_repo_root 2>/dev/null || true)"
  [ -n "$pinf" ] && read_pin "$pinf/.comms/workspace" && return 0
  pinf="$(worktree_pin_file 2>/dev/null || true)"
  [ -n "$pinf" ] && read_pin "$pinf" && return 0
  # cmux DELETED (S4-4). This resolved a cmux workspace TITLE through a cache and a
  # decorated-title guard; with no cmux there is exactly one source left, and the explicit
  # `.comms/workspace` pin above still wins over it.
  echo "$(repo_workspace_name)"
}

# ---------- agent registry (.comms/config) ----------
# Line-oriented, bash-3.2-parseable. Missing file => built-in defaults (zero-config
# back-compat). Names become directory suffixes and state-field prefixes, so the
# grammar is enforced hard. A name may be registered only when a supported backend
# exists for it — otherwise /ask etc. would accept mail that can never be served.
#
# IDENTITY vs PROVIDER. An identity is who a message is from / to, whose inbox, whose leg
# thread, whose events. A provider is the runtime that serves a turn (acpx profile,
# isolation arm, policy map row). A DRIVER identity (`agents =`) is named after its
# provider. Every driver X has a built-in REVIEW TWIN, `X-review`, running on provider X under
# its own name — no config — so a driver can be reviewed by its own model without the two
# sharing an inbox, a thread, or awaiting_from. A twin is review-only: it never drives,
# authors a request, or answers a consult. Everything above the process boundary is keyed on
# the identity; only the spawn resolves the provider (registry_provider).
# the PROVIDERS. claude/codex/gemini: interactive+acp; grok: headless reviewer/consult. gemini is supported but
# NOT a zero-config default: a project opts in with `agents = ... gemini`, so an install without the
# Gemini CLI never sees a third-family reviewer it cannot run.
SUPPORTED_AGENTS="claude codex grok gemini"
REGISTRY_DEFAULT_AGENTS="claude codex grok"
REGISTRY_DEFAULT_TARGET="codex"

registry_file() { echo "$(cmd_root)/config"; }

profile_helper() { python3 "$(dirname "$SELF")/agent_profiles.py" "$@"; }
# The access profiles (access.json) and the exact per-leg binding judgement. Both are optional files and
# optional helpers: nothing on an unbound path reads either.
access_helper() { python3 "$(dirname "$SELF")/access_profiles.py" "$@"; }
leg_binding_py() { python3 "$(dirname "$SELF")/leg_binding.py" "$@"; }
custom_profile_names() {
  local f="${AGENT_COMMS_HOME:-$HOME/.agent-comms}/agents.json"
  if [ -e "$f" ] || [ -L "$f" ]; then profile_helper names; else printf '\n'; fi
}

# is_provider <value> — EXACT membership: one supported provider name, nothing else. A substring
# test against " $SUPPORTED_AGENTS " would accept "claude codex", which compose would then count
# as a provider of its own.
is_provider() {
  case "$1" in ""|*[!a-z0-9-]*) return 1 ;; esac
  case " $SUPPORTED_AGENTS " in *" $1 "*) return 0 ;; esac
  local custom
  custom="$(custom_profile_names)" || return 1
  case " $custom " in *" $1 "*) return 0 ;; esac
  return 1
}

validate_agent_name() {  # <name> [source] — grammar: ^[a-z][a-z0-9-]{1,15}$
  printf '%s' "$1" | grep -qE '^[a-z][a-z0-9-]{1,15}$' \
    || die "config: invalid agent name '$1'${2:+ in $2} — must match [a-z][a-z0-9-]{1,15} (it becomes a directory suffix)"
}

# registry_parse — ONE full-config validation path, run by EVERY accessor. A
# config that criterion-level rules call malformed (duplicate keys, bad names,
# unsupported/duplicate agents, empty values, invalid default) is a hard error
# no matter which command touched it first; unknown keys warn everywhere.
# Prints three lines: the DRIVER list, the default target, then the review map
# (`<driver>-review:<driver> ...`, one built-in twin per driver). Read it only through the
# accessors below — each concern has exactly one.
review_twin_of() { printf '%s-review\n' "$1"; }   # <driver> — the ONE place a twin's name is formed

review_twins_of() {  # <driver list> -> "X-review:X ..."
  local d out=""
  for d in $1; do out="$out $(review_twin_of "$d"):$d"; done
  printf '%s\n' "${out# }"
}

registry_parse() {
  local f agents_ct default_ct line a agents="" dflt review=""
  local supported custom
  custom="$(custom_profile_names)" || die "config: invalid operator agent profiles"
  supported="$SUPPORTED_AGENTS${custom:+ $custom}"
  f="$(registry_file)"
  if [ ! -f "$f" ]; then
    printf '%s\n%s\n%s\n' "$REGISTRY_DEFAULT_AGENTS" "$REGISTRY_DEFAULT_TARGET" "$(review_twins_of "$REGISTRY_DEFAULT_AGENTS")"
    return 0
  fi
  agents_ct="$(grep -c '^[[:space:]]*agents[[:space:]]*=' "$f" 2>/dev/null || true)"
  default_ct="$(grep -c '^[[:space:]]*default-target[[:space:]]*=' "$f" 2>/dev/null || true)"
  [ "${agents_ct:-0}" -le 1 ] || die "config: duplicate 'agents' key in $f"
  [ "${default_ct:-0}" -le 1 ] || die "config: duplicate 'default-target' key in $f"
  # The suite keys are validated through the SAME accessor their consumers use
  # (config_scalar dies on duplicates), so this path and integrate's can never
  # disagree about what the config says. (codex, ergonomics r1-r2.)
  local cfg_root
  cfg_root="$(main_repo_root)"
  if [ -n "$cfg_root" ]; then
    config_scalar "$cfg_root" suite-cmd >/dev/null
    config_scalar "$cfg_root" suite-attest-secs >/dev/null
    config_scalar "$cfg_root" suite-timeout-secs >/dev/null
  fi
  grep -vE '^[[:space:]]*(#|$|agents[[:space:]]*=|default-target[[:space:]]*=|suite-cmd[[:space:]]*=|suite-attest-secs[[:space:]]*=|suite-timeout-secs[[:space:]]*=)' "$f" \
    | head -3 | sed 's/^/warning: config: unknown line: /' >&2 || true
  if [ "${agents_ct:-0}" -eq 1 ]; then
    line="$(sed -n 's/^[[:space:]]*agents[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
    [ -n "$line" ] || die "config: 'agents' key present but empty in $f (delete the line for zero-config defaults)"
    set -f   # a config value is data: never glob-expand it against the caller's cwd
    for a in $line; do
      validate_agent_name "$a" "$f"
      case " $supported " in
        *" $a "*) ;;
        *) die "config: unsupported agent '$a' in $f — supported: $supported" ;;
      esac
      case " $agents " in
        *" $a "*) die "config: duplicate agent '$a' in $f" ;;
      esac
      agents="$agents $a"
    done
    set +f
    agents="${agents# }"
  else
    agents="$REGISTRY_DEFAULT_AGENTS"
  fi
  # REVIEW TWINS are derived, never declared: one per driver, named `<driver>-review`. A
  # driver name is always a provider name (checked above), so a twin can never collide with a
  # driver, and `claude-review` on the agents line itself stays "unsupported".
  review="$(review_twins_of "$agents")"
  if [ "${default_ct:-0}" -eq 1 ]; then
    line="$(sed -n 's/^[[:space:]]*default-target[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
    [ -n "$line" ] || die "config: 'default-target' key present but empty in $f"
    set -f; set -- $line; set +f
    [ "$#" -eq 1 ] || die "config: default-target must be exactly one agent (got: $line)"
    dflt="$1"
  else
    # The built-in default (codex) when it is registered; otherwise the first driver, so a
    # config listing only `agents = claude` works without also naming its default target.
    case " $agents " in
      *" $REGISTRY_DEFAULT_TARGET "*) dflt="$REGISTRY_DEFAULT_TARGET" ;;
      *) dflt="${agents%% *}" ;;
    esac
  fi
  # The default target serves /ask and single-reviewer handoffs for EVERY driver, so it
  # must be a driver: a review identity there would make same-model review the silent
  # default for its own provider's driver, and a consult target it can never answer.
  case " $review " in
    *" $dflt:"*) die "config: default-target '$dflt' is a review-only identity — it must be a driver (one of: $agents)" ;;
  esac
  case " $agents " in
    *" $dflt "*) ;;
    *) die "config: default-target '$dflt' is not a registered agent (registered: $agents)" ;;
  esac
  printf '%s\n%s\n%s\n' "$agents" "$dflt" "$review"
}

# ONE ACCESSOR PER CONCERN, every one fed by the single parse above.
registry_drivers() { registry_parse | sed -n 1p; }

registry_default() { registry_parse | sed -n 2p; }

registry_review_map() { registry_parse | sed -n 3p; }   # "name:provider ..."

# EVERY identity — drivers first, review identities last. This is the membership set:
# inboxes, `from:` validation, require_agent and every to-<agent> enumeration need the
# review inboxes too. Drivers first keeps a never-created review inbox from ever
# preceding a real one in a scan.
registry_agents() {
  registry_parse | awk 'NR==1 { d = $0 }
    NR==3 { n = split($0, P, " "); for (i = 1; i <= n; i++) { sub(/:.*/, "", P[i]); r = r " " P[i] } }
    END { if (d != "") printf "%s%s\n", d, r }'
}

registry_review_agents() {  # the review identities' names, space-separated
  local map a out=""
  map="$(registry_review_map)" || exit 2
  for a in $map; do out="$out ${a%%:*}"; done
  printf '%s\n' "${out# }"
}

registry_provider() {  # <identity> — its provider (a driver is its own); 1 if unregistered
  local out a
  out="$(registry_parse)" || exit 2
  for a in $(printf '%s\n' "$out" | sed -n 1p); do
    [ "$a" = "$1" ] && { printf '%s\n' "$1"; return 0; }
  done
  for a in $(printf '%s\n' "$out" | sed -n 3p); do
    [ "${a%%:*}" = "$1" ] && { printf '%s\n' "${a#*:}"; return 0; }
  done
  return 1
}

# Family is an operator-declared independence group; runtime and API endpoint are separate.
registry_family() {
  local provider
  provider="$(registry_provider "$1")" || return 1
  case "$provider" in claude|codex|grok|gemini) printf '%s\n' "$provider" ;;
    *) profile_helper field "$provider" family ;;
  esac
}

reply_family() {
  local encoded
  encoded="$(frontmatter_field "$1" agent_profile)"
  if [ -n "$encoded" ]; then profile_helper binding-field "$encoded" family
  else reply_provider "$1"; fi
}

registry_is_review() {  # <identity> — 0 iff a review-only identity; malformed config exits
  local map a
  map="$(registry_review_map)" || exit 2
  for a in $map; do [ "${a%%:*}" = "$1" ] && return 0; done
  return 1
}

# reply_provider <reply> — the provider that PRODUCED a reply, and the one rule for it: a driver
# identity is its own provider, unconditionally; a review identity's is its broker's
# `review_provider` stamp. validate (consistency), compose (independence) and panel status all
# read it here, so none of them can consult the CURRENT registry map for a historical fact.
reply_provider() {
  local from
  from="$(frontmatter_field "$1" from)"
  if registry_is_review "$from"; then
    frontmatter_field "$1" review_provider
  else
    printf '%s\n' "$from"
  fi
}

# stamp_review_provider <request> <target> — the ONE writer of `review_provider:` on a request
# (a review-request, or the error lane — both start a review turn at a review identity).
# A request to a review identity carries the provider the registry maps it to NOW (runphase
# refuses the turn if that has changed by the time it runs); any other request has a hand-typed
# value removed. Two callers: cmd_send, and shadow's private request copy.
stamp_review_provider() {
  local f="$1" to="$2" want="" has
  if registry_is_review "$to"; then
    want="$(registry_provider "$to")" || return 1
  fi
  has="$(LC_ALL=C awk 'NR == 1 { if ($0 !~ /^---\r?$/) exit; next }
    /^---\r?$/ { exit }
    index($0, "review_provider:") == 1 { print "y"; exit }' "$f")"
  if [ -n "$want" ] || [ -n "$has" ]; then
    stamp_fm_key "$f" review_provider "$want"
  fi
  local provider binding="" key value
  provider="$(registry_provider "$to")" || return 1
  case "$provider" in claude|codex|grok|gemini) ;;
    *) binding="$(profile_helper binding "$provider")" || return 1 ;;
  esac
  local old_binding
  old_binding="$(frontmatter_field "$f" agent_profile)"
  if [ -n "$old_binding" ] && [ "$old_binding" != "$binding" ]; then
    echo "agent profile changed since this request was stamped; create a new request" >&2
    return 1
  fi
  for key in agent_profile agent_profile_digest review_family review_model; do
    value=""
    if [ -n "$binding" ]; then
      case "$key" in
        agent_profile) value="$binding" ;;
        agent_profile_digest) value="$(profile_helper binding-field "$binding" digest)" ;;
        review_family) value="$(profile_helper binding-field "$binding" family)" ;;
        review_model) value="$(profile_helper binding-field "$binding" model)" ;;
      esac
    fi
    # Strip user-supplied values even when sending to a legacy provider.
    if [ -n "$value" ] || [ -n "$(frontmatter_field "$f" "$key")" ]; then
      stamp_fm_key "$f" "$key" "$value" || return 1
    fi
  done
  return 0
}

registry_has() {  # <name> — 0 iff registered; a MALFORMED config exits hard
  # Capture-with-check: `for a in $(...)` swallows a failing substitution, which
  # would collapse "config is broken" into ordinary "not registered".
  local a reg
  reg="$(registry_agents)" || exit 2
  for a in $reg; do [ "$a" = "$1" ] && return 0; done
  return 1
}

require_agent() {  # <name> [context] — die unless registered
  [ -n "${1:-}" ] || die "${2:-agent}: agent name required (registered: $(registry_agents))"
  registry_has "$1" || die "${2:-agent}: unknown agent '$1' (registered: $(registry_agents))"
}

require_driver() {  # <name> [context] — die unless a registered DRIVER (never a review identity)
  require_agent "$@"
  if registry_is_review "$1"; then
    die "${2:-agent}: '$1' is a review-only identity — it reviews, it never drives or authors (drivers: $(registry_drivers))"
  fi
}

# Detect the driving agent. Templates MUST call this rather than writing a
# literal name: copying `from: claude` is how a grok or codex driver impersonates
# Claude, and dispatch then fans the request back at the driver.
#
# Order: COMMS_SELF (explicit override) → session env → ancestor executable →
# fail closed. Never default to claude. GROK_AGENT is the Grok TUI's session
# flag (value "1"); runphase uses the same variable as the child agent NAME, so
# only the TUI's "1" counts here.
whoami_from_ancestors() {
  local pid exe base hops=0
  pid="${PPID:-}"
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$hops" -lt 16 ]; do
    hops=$((hops + 1))
    exe="$(ps -p "$pid" -o args= 2>/dev/null | awk '{print $1}')"
    [ -n "$exe" ] || return 1
    base="$(basename "$exe")"
    case "$base" in
      grok|grok-*) printf '%s\n' grok; return 0 ;;
      gemini)      printf '%s\n' gemini; return 0 ;;
      claude)      printf '%s\n' claude; return 0 ;;
      codex)       printf '%s\n' codex; return 0 ;;
    esac
    pid="$(ps -p "$pid" -o ppid= 2>/dev/null | awk '{print $1}')"
  done
  return 1
}

cmd_whoami() {
  # INSIDE A REVIEW TURN nothing is a driver. runphase exports the marker for the whole
  # turn; without it a reviewer child on its driver's OWN provider (claude-review under a
  # claude driver) carries exactly one provider's signals, so the conflicting-signals net
  # below — which catches CROSS-provider children — would resolve it to the driver.
  [ -z "${COMMS_REVIEW_TURN:-}" ] \
    || die "whoami: this process is inside a review turn for '$(clip "$COMMS_REVIEW_TURN")' — a reviewer never drives or authors; its parent brokers the reply"
  local me="${COMMS_SELF:-}"
  if [ -z "$me" ]; then
    # Collect EVERY matching session signal. Silent precedence (GROK_AGENT beating
    # CLAUDECODE beating CODEX_*) is how a nested launch impersonates the parent.
    # Two distinct hits fail closed; a single hit wins; none falls through to ancestors.
    local hits="" hit seen="" n=0
    [ "${GROK_AGENT:-}" = "1" ] && hits="$hits grok"
    # Gemini CLI marks the shells it spawns with GEMINI_CLI=1 (its own identification variable).
    [ "${GEMINI_CLI:-}" = "1" ] && hits="$hits gemini"
    { [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${CLAUDE_PID:-}" ]; } && hits="$hits claude"
    { [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ]; } && hits="$hits codex"
    for hit in $hits; do
      case " $seen " in *" $hit "*) continue ;; esac
      seen="$seen $hit"
      n=$((n + 1))
    done
    seen="${seen# }"
    if [ "$n" -gt 1 ]; then
      die "whoami: conflicting identity signals ($seen) — set COMMS_SELF to a registered name"
    elif [ "$n" -eq 1 ]; then
      me="$seen"
    else
      me="$(whoami_from_ancestors || true)"
    fi
  fi
  [ -n "$me" ] || die "whoami: cannot detect the driving agent — set COMMS_SELF to a registered name"
  require_driver "$me" "whoami"
  printf '%s\n' "$me"
}

cmd_agents() {
  case "${1:-}" in
    "")          registry_agents ;;
    default)     registry_default ;;
    --drivers)   registry_drivers ;;
    --review)    registry_review_agents ;;
    --provider)
      shift
      [ -n "${1:-}" ] || usage_err "agents --provider <identity>: an identity is required"
      # One parse, not three: every review turn calls this (runphase's resolution and peer rule).
      registry_provider "$1" || die "agents --provider: unknown agent '$1' (registered: $(registry_agents))"
      ;;
    --family)
      shift; [ -n "${1:-}" ] || usage_err "agents --family: an identity is required"
      registry_family "$1" || die "agents --family: unknown agent '$1'"
      ;;
    --profile)
      shift; [ -n "${1:-}" ] || usage_err "agents --profile: an identity is required"
      local profile_provider
      profile_provider="$(registry_provider "$1")" || die "agents --profile: unknown agent '$1'"
      case "$profile_provider" in claude|codex|grok|gemini) return 1 ;; esac
      profile_helper binding "$profile_provider"
      ;;
    --access)
      # The one immutable access profile of an agent (access.json, read together with agents.json so a
      # profile that contradicts its entry is refused here exactly as dispatch refuses it). Read-only:
      # a credential is a REFERENCE, and its value is never read to print this line.
      shift
      [ -n "${1:-}" ] || usage_err "agents --access: an identity is required"
      registry_has "$1" || die "agents --access: unknown agent '$1' (registered: $(registry_agents))"
      access_helper show "$1" ${2:+"$2"}
      ;;
    --others)
      # The default panel for a loop <driver> is driving: every OTHER DRIVER. Its own review twin
      # is opt-in — same-model review is off unless asked for — EXCEPT when no other driver
      # exists, where the twin is the only reviewer there is. Derived from the registry so adding
      # an agent changes the panel without editing a template.
      shift
      [ -n "${1:-}" ] || usage_err "agents --others <agent>: an agent name is required"
      require_driver "$1" "agents --others"
      local drv oth="" d family seen_families own_family
      drv="$(registry_drivers)" || exit 2
      own_family="$(registry_family "$1")" || exit 2
      seen_families=" $own_family "
      for d in $drv; do
        family="$(registry_family "$d")" || exit 2
        case "$seen_families" in *" $family "*) continue ;; esac
        oth="$oth $d"; seen_families="$seen_families$family "
      done
      [ -n "$oth" ] || oth="$(review_twin_of "$1")"
      printf '%s\n' "${oth# }" | tr ' ' ','
      ;;
    --roster)
      # THE reviewer-list resolver every runtime's /auto uses (one template serves claude, codex
      # and grok), so "name yourself to be reviewed by your own model" means the same thing
      # everywhere. No list: the default panel (--others). With a list: each name is validated,
      # the driver's OWN name becomes its review twin (a driver never reviews itself under its
      # own name — send and panel dispatch still refuse that), repeats collapse, and two
      # reviewers on one provider are refused here, before anything is written.
      shift
      [ -n "${1:-}" ] || usage_err "agents --roster <driver> [a,b,...]: the driving agent is required"
      local rself="$1" rwant="${2:-}" rr rout="" rprovs=" " rp
      require_driver "$rself" "agents --roster"
      if [ -z "$rwant" ]; then cmd_agents --others "$rself"; return; fi
      set -f
      for rr in $(printf '%s' "$rwant" | tr ',' ' '); do
        [ "$rr" = "$rself" ] && rr="$(review_twin_of "$rself")"
        require_agent "$rr" "agents --roster"
        case " $rout " in *" $rr "*) continue ;; esac
        rp="$(registry_family "$rr")" || exit 2
        case "$rprovs" in
          *" $rp "*) usage_err "agents --roster: two reviewers on provider '$rp' in '$rwant' — one model reviewing twice is not two reviews; keep one" ;;
        esac
        rprovs="$rprovs$rp "; rout="$rout $rr"
      done
      set +f
      [ -n "$rout" ] || usage_err "agents --roster: '$rwant' names no reviewer"
      printf '%s\n' "${rout# }" | tr ' ' ','
      ;;
    --supported)
      # NOT 'headless': headless_ok refuses both, and runphase requires --via acp. A caller
      # reading the registry instead of cmd_transport would infer a route that fails.
      # (codex, S4-2 r3, blocking.) Do NOT add reviewer-consult-only here — see below.
      printf '%s\tinteractive,acp\n' claude
      printf '%s\tinteractive,acp\n' codex
      printf '%s\tinteractive,acp\n' gemini
      printf '%s\theadless,reviewer-consult-only\n' grok
      local ca custom_supported
      custom_supported="$(custom_profile_names)" || exit 2
      for ca in $custom_supported; do printf '%s\tacp\n' "$ca"; done
      ;;
    *) die "agents: unknown argument '$1' (expected: default | --drivers | --review | --provider <id> | --family <id> | --profile <id> | --access <id> [--json] | --others <driver> | --roster <driver> [a,b,...] | --supported)" ;;
  esac
}

inbox_for() {
  require_agent "$1" "inbox"
  echo "to-$1"
}

cmd_list() {
  local as="" thread=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) need_value "list" $# "$1"; shift; as="$1" ;;
      --thread) need_value "list" $# "$1"; shift; thread="$1" ;;
      *) die "list: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$as" ] || die "list: --as <agent> is required (registered: $(registry_agents))"
  local root ws inbox
  root="$(cmd_root)"; ws="$(cmd_workspace)"; inbox="$(inbox_for "$as")"
  mkdir -p "$root/$inbox" 2>/dev/null || true
  local files
  files="$(sorted_message_files "$root/$inbox" "$ws" "" "$thread" newest)"
  if [ -n "$files" ]; then
    echo "$files"
  else
    local unmatched_count
    unmatched_count="$(find "$root/$inbox" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [ "${unmatched_count:-0}" -gt 0 ]; then
      # Name the identities, never just count them: "N unmatched" is undiagnosable,
      # and the client-backup incident sat invisible behind exactly that. Frontmatter
      # workspace: wins; filename prefix is the fallback for pre-v2 files.
      # Bounded inside awk (no head in the pipe: SIGPIPE under pipefail could kill
      # list before the warning prints — the exact inbox shape this diagnostic
      # exists for) and split by CAUSE: foreign identities get the repair hint;
      # same-workspace files that merely miss a --thread filter are not an
      # identity problem and must not claim to be one. (grok, stamped-authorities
      # round 1.)
      local foreign_ct others
      foreign_ct="$(find "$root/$inbox" -maxdepth 1 -type f ! -name "${ws}_*" 2>/dev/null | wc -l | tr -d ' ' || true)"
      if [ "${foreign_ct:-0}" -gt 0 ]; then
        others="$( { find "$root/$inbox" -maxdepth 1 -type f ! -name "${ws}_*" 2>/dev/null | while IFS= read -r uf; do
            uw="$(frontmatter_field "$uf" workspace)"
            # Prefix parse for envelope-less legacy files: prefer cutting at the
            # timestamp (workspace names may contain underscores); a date-less
            # name loses only its final _component. First-underscore truncation
            # misreported foo_bar as foo. (codex, stamped-authorities round 1.)
            # `.md` is stripped by basename, NOT by a sed substitution: `t` branches if
            # ANY s/// succeeded since the last line was read, so stripping the extension
            # in the same script fired the branch unconditionally and the final
            # _component strip never ran -- the warning then named a FILENAME where it
            # promised an identity ("other-workspace_pending.md" for "other-workspace").
            [ -n "$uw" ] || uw="$(basename "$uf" .md | sed -e 's/_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T.*$//' -e 't' -e 's/_[^_]*$//')"
            printf '%s\n' "$uw"
          done | sort | uniq -c | sort -rn | awk 'NR<=5 {printf "%s(%s) ", $(2), $(1)}'; } || true)"
        echo "warning: inbox holds $foreign_ct pending message(s) for OTHER workspace identities: ${others:-unknown }— resolved identity here is '$ws'. If one of those IS this repo, repair it once: 'comms.sh workspace set <name>'. Stale debris is a 'clean' matter; nothing is deleted." >&2
      fi
      if [ "${unmatched_count:-0}" -gt "${foreign_ct:-0}" ]; then
        echo "note: $(( unmatched_count - foreign_ct )) pending message(s) for THIS workspace fall outside the current filter" >&2
      fi
    fi
    # Late delivery nudges for already-processed replies are common. Scope the
    # hint to messages that actually came TO this reader and, when supplied, to
    # this thread; otherwise an unrelated archive can masquerade as the reply.
    # Direction is "not written by me" — correct for two agents and for twenty.
    local latest
    latest="$(sorted_message_files "$root/archive" "$ws" "!$as" "$thread" newest | head -1 || true)"
    if [ -n "$latest" ]; then
      echo "no pending messages; latest archived: $(basename "$latest")" >&2
    else
      echo "no pending messages for workspace '$ws'" >&2
    fi
    return 1
  fi
}

# frontmatter_field <file> <field>          — the value, or nothing
# frontmatter_field --each <field> <file>... — one answer per file that has the field, in order
# The ONE frontmatter-field rule (CRLF-tolerant; the value keeps any trailing whitespace, which is
# what the state writer keys on): the frontmatter opens on line 1 with `---`, and the first
# `<field>:` inside it wins. The batch form is the idle scan's, so the two can never drift apart.
# Self-contained on purpose: tests extract this function by name and eval it alone.
frontmatter_field() {
  local one=1 field
  if [ "${1:-}" = --each ]; then
    one=0; field="$2"; shift 2
    [ "$#" -gt 0 ] || return 0   # no files: answer nothing, never read stdin
  else
    field="$2"; set -- "$1"
  fi
  awk -v f="$field" -v one="$one" 'FNR==1 {inFM=0; seen=0} {sub(/\r$/, "")}
    FNR==1 && $0=="---" {inFM=1; next}
    !inFM || seen {next}
    $0=="---" {seen=1; if (one) exit; next}
    index($0, f ":")==1 {sub("^" f ":[[:space:]]*", ""); print; seen=1; if (one) exit}' "$@"
}

# fm_field_lines <file> <field> — every value line of <field> in the frontmatter,
# blank values preserved as empty lines. Consumers must read this via PROCESS
# SUBSTITUTION, never $() into a heredoc: command substitution strips trailing
# newlines, which made a trailing blank duplicate line invisible to the
# validation loops. (codex, stamped-authorities round 4.)
fm_field_lines() {
  LC_ALL=C awk -v f="$2" '{sub(/\r$/,"")} NR==1 && $0=="---"{fm=1;next} fm && $0=="---"{exit} fm && index($0, f ":")==1 {sub("^" f ":[[:space:]]*", ""); print}' "$1"
}

# resolve_message_path <path>
# The file at <path>, or its archive copy when a successful turn has already
# moved it. `send --wait` archives the outbound before cmd_send returns from
# deliver; later readers must not open a path whose owner may have moved it
# (ROADMAP 2026-09-02: awk "can't open file" then RESULT: NOT spawned after a
# successful consult). Archive first matches leg_reply_candidates.
resolve_message_path() {
  local p="${1:-}" root base
  [ -n "$p" ] || return 1
  [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  base="$(basename "$p")"
  root="$(cmd_root)"
  [ -f "$root/archive/$base" ] && { printf '%s' "$root/archive/$base"; return 0; }
  return 1
}

# resolve_inbound_path <path-or-basename>
# --archive-inbound accepts a full path OR a bare filename (cmd_archive looks
# the basename up in the sender's inbox). bind_reply_identity must use the same
# surface or a still-pending `request.md` dies as "gone". Archive first, then
# every inbox — never the outbound itself (caller excludes).
resolve_inbound_path() {
  local p="${1:-}" root base d
  [ -n "$p" ] || return 1
  [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  root="$(cmd_root)"
  base="$(basename "$p")"
  [ -f "$root/archive/$base" ] && { printf '%s' "$root/archive/$base"; return 0; }
  for d in "$root"/to-*; do
    [ -d "$d" ] || continue
    [ -f "$d/$base" ] && { printf '%s' "$d/$base"; return 0; }
  done
  return 1
}

# find_message_by_id <message_id>
# Locate a message by its frontmatter message_id (or `<id>.md` basename).
# Archive first, then every inbox — same order as leg_reply_candidates, so a
# just-archived request is what a reply bind sees.
find_message_by_id() {
  local mid="${1:-}" root d f
  [ -n "$mid" ] || return 1
  root="$(cmd_root)"
  for d in "$root/archive" "$root"/to-*; do
    [ -d "$d" ] || continue
    if [ -f "$d/${mid}.md" ]; then
      printf '%s' "$d/${mid}.md"
      return 0
    fi
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      [ "$(frontmatter_field "$f" message_id)" = "$mid" ] || continue
      printf '%s' "$f"
      return 0
    done
  done
  return 1
}

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

mtime_iso() {
  local epoch="$1" out=""
  out="$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  [ -n "$out" ] || out="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  printf '%s' "${out:-0000-00-00T00:00:00Z}"
}

# sort_paths_by_timestamp <newest|oldest> [from] [thread] — reads paths on stdin
# Protocol timestamp is authoritative; mtime breaks ties and is the fallback
# for legacy/malformed files. Physical inbox direction remains authoritative,
# so `from` filtering is used only where a shared archive needs disambiguation.
# Split out from sorted_message_files so a caller that has already narrowed the
# candidate set (archive-search's match filter) pays the per-file frontmatter
# parse only for the files it kept, not for the whole directory.
sort_paths_by_timestamp() {
  # <sender> matches an exact `from:`; a leading '!' EXCLUDES that sender instead.
  # "Addressed to me" is "not written by me", which is true for any number of
  # agents — the two-agent complement trick it replaces silently stopped working
  # the moment a third agent was registered.
  local order="${1:-oldest}" sender="${2:-}" thread="${3:-}"
  local f ts mt rows exclude=""
  case "$sender" in !?*) exclude="${sender#!}"; sender="" ;; esac
  rows="$(
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -z "$sender" ] || [ "$(frontmatter_field "$f" from)" = "$sender" ] || continue
      [ -z "$exclude" ] || [ "$(frontmatter_field "$f" from)" != "$exclude" ] || continue
      [ -z "$thread" ] || [ "$(frontmatter_field "$f" thread)" = "$thread" ] || continue
      ts="$(frontmatter_field "$f" timestamp)"
      mt="$(file_mtime "$f")"
      printf '%s' "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' \
        || ts="$(mtime_iso "$mt")"
      printf '%s\t%020d\t%s\n' "$ts" "$mt" "$f"
    done
  )"
  [ -n "$rows" ] || return 0
  if [ "$order" = "newest" ]; then
    printf '%s\n' "$rows" | sort -r | cut -f3-
  else
    printf '%s\n' "$rows" | sort | cut -f3-
  fi
}

# sorted_message_files <dir> <workspace> [from] [thread] [newest|oldest] [name-pattern]
# name-pattern defaults to "<workspace>_*" — the workspace-scoped behavior every
# existing caller relies on. archive-search passes "*" because the archive is one
# repo's shared history and a sibling workspace's thread is a legitimate hit.
sorted_message_files() {
  local dir="$1" ws="$2" sender="${3:-}" thread="${4:-}" order="${5:-oldest}" pat="${6:-}"
  [ -n "$pat" ] || pat="${ws}_*"
  # A registered inbox that was never created is an EMPTY inbox, not an error: under pipefail a
  # failing find killed the whole scan, so one never-used review identity could hide every
  # inbox listed after it. (ROADMAP: missing-inbox hazard.)
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name "$pat" 2>/dev/null \
    | sort_paths_by_timestamp "$order" "$sender" "$thread"
}

# leg_reply_candidates <root> <workspace> <from-agent> <thread>
# Every place a panel leg's reply can be sitting, archive first.
#
# `panel status` and `compose` both used to scan the archive and a hardcoded
# `to-claude`, which quietly made "claude drives the loop" load-bearing in the one
# layer that is supposed to be agent-neutral: a codex- or grok-driven panel's replies
# land in `to-codex` / `to-grok`, so status reported `answered no` and compose refused
# a COMPLETE panel as INCOMPLETE — a reviewer's whole turn discarded because of the
# directory it arrived in. The directory is not identity. Identity is the round +
# `in-reply-to` + `type` + `validate` chain both callers apply to every candidate, and
# that chain is unchanged here; widening the scan only makes a bound reply REACHABLE.
#
# Archive stays first so ordering semantics are identical for the common case.
#
# The agent list is a PARAMETER, resolved once by the caller in its own shell, and that is
# load-bearing rather than tidy. Reading the registry in here — even with the
# capture-then-check idiom — cannot fail the command: this function is only ever called
# inside `$(...)`, so `exit 2` terminates the substitution subshell, the expansion comes
# back empty, and `for cand in <empty>` succeeds. A malformed config would then report
# every leg unanswered and exit 0, which is a worse version of the bug this exists to fix.
# The caller reads the registry where a failure can still abort. (codex, panel round 1 —
# it is the exact hazard I asked about, and my answer was wrong.)
leg_reply_candidates() {  # <root> <workspace> <from-agent> <thread> <registered-agents>
  local root="$1" ws="$2" ag="$3" th="$4" reg="$5" a
  sorted_message_files "$root/.comms/archive" "$ws" "$ag" "$th" newest
  for a in $reg; do
    # `to-$a` rather than `inbox_for "$a"`: inbox_for revalidates through registry_parse,
    # which puts a registry read back INSIDE this substitution — where a failure is
    # swallowed exactly as before. $reg was already validated by the caller, so the
    # validation would buy nothing and reopen the hole. (codex, panel round 2.)
    sorted_message_files "$root/.comms/to-$a" "$ws" "$ag" "$th" newest
  done
}

# ---------------------------------------------------------------------------
# Bounded reads — `lessons` and `archive-search`
#
# Both promise ONE invariant, asserted as a byte measurement by the harness:
#
#     combined(stdout + stderr) <= --bytes + DIAGNOSTIC_MAX
#
# DIAGNOSTIC_MAX is a constant, never a function of any input. That only holds
# because every echoed caller-controlled value (path, pattern, heading) is
# clipped first and stderr is capped to a single clipped line — without that, a
# pathological --file or --surface argument inflates the "constant" and the cap
# these subcommands exist to enforce leaks.
#
# Byte counting is locale-independent (LC_ALL=C) and the truncation marker is
# ASCII, so the arithmetic is exact rather than approximately right in UTF-8.
# ---------------------------------------------------------------------------
DIAGNOSTIC_MAX=256      # hard cap on the single stderr line, marker included
CLIP_WIDTH=64           # fixed width for any echoed caller-controlled value
LESSONS_MIN_BYTES=512   # below this a bounded summary cannot be guaranteed

usage_err() { echo "comms.sh: $*" >&2; exit 2; }

# need_value <context> <argc> <option> — THE guard for a value-taking option, called BEFORE the
# shift that consumes the value, with the parse loop's own $#:
#     --name) need_value "presence $sub" $# "$1"; shift; name="$1" ;;
# Without it the bare `shift; name="${1:-}"` shape, given the option LAST, leaves $# at 0, and the
# loop's trailing shift then fails under errexit: exit 1, nothing on stderr, nothing done — a usage
# mistake that reads as a crash. Refuses as usage (exit 2), naming the option as it was spelled.
need_value() { [ "$2" -ge 2 ] || usage_err "$1: $3 needs a value"; }

clip() {  # clip <string> [max-total-bytes] — fixed width, visibly marked
  local LC_ALL=C s="$1" w="${2:-$CLIP_WIDTH}"
  if [ "${#s}" -le "$w" ]; then printf '%s' "$s"; else printf '%s...' "${s:0:$((w - 3))}"; fi
}

byte_len() { local LC_ALL=C; printf '%s' "$1" | wc -c | tr -d ' '; }

emit_diagnostic() {  # at most one line, never wider than DIAGNOSTIC_MAX
  # The trailing newline counts against the cap, so the payload gets one byte
  # less — otherwise the primitive's own guarantee is off by one for a caller
  # that ever builds a diagnostic right at the limit.
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$(clip "$1" $((DIAGNOSTIC_MAX - 1)))" >&2
}

require_budget() {  # shared --bytes validation for both bounded readers
  case "$1" in ''|*[!0-9]*) usage_err "$2: --bytes must be a positive integer" ;; esac
  [ "$1" -ge "$LESSONS_MIN_BYTES" ] \
    || usage_err "$2: --bytes below the $LESSONS_MIN_BYTES floor leaves no room for the omission summary"
}

# Index a markdown file's "## " sections as: <date> <seq> <start> <end> <heading>
# Sections whose heading carries no YYYY-MM-DD get 0000-00-00, which sorts LAST
# under a descending date sort — undated entries are never silently dropped,
# they just follow the dated ones in their original file order.
section_index() {
  awk '
    /^## / {
      if (n) end[n] = NR - 1
      n++; start[n] = NR; head[n] = $0; date[n] = "0000-00-00"
      if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
        date[n] = substr($0, RSTART, RLENGTH)
    }
    END {
      if (n) { end[n] = NR
        for (i = 1; i <= n; i++)
          printf "%s\t%06d\t%d\t%d\t%s\n", date[i], i, start[i], end[i], head[i] }
    }' "$1" | sort -k1,1r -k2,2n
}

cmd_lessons() {
  local bytes=4000 surface="" surface_set=false file="" top=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bytes)   need_value "lessons" $# "$1"; shift; bytes="$1" ;;
      --surface) need_value "lessons" $# "$1"; shift; surface="$1"; surface_set=true ;;
      --file)    need_value "lessons" $# "$1"; shift; file="$1" ;;
      *) usage_err "lessons: unknown argument '$(clip "$1")'" ;;
    esac
    shift || true
  done
  require_budget "$bytes" lessons
  if [ "$surface_set" = true ] && [ -z "$surface" ]; then
    usage_err "lessons: --surface needs a pattern (an empty one is not 'match everything')"
  fi

  # Project docs belong to the tree under review — NOT to `comms.sh root`, which
  # deliberately resolves the MAIN repo root so linked worktrees share one
  # mailbox. Reusing that resolver here would make a review in a feature
  # worktree silently read main's advisories.
  if [ -z "$file" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || { emit_diagnostic "lessons: not inside a git repository"; return 0; }
    file="$top/docs/advisories.md"
  fi
  [ -f "$file" ] || { emit_diagnostic "lessons: no lessons file at $(clip "$file")"; return 0; }

  local idx undated=0 kept=() date seq start end head text
  idx="$(section_index "$file")"
  [ -n "$idx" ] || { emit_diagnostic "lessons: no '## ' sections in $(clip "$file")"; return 0; }

  while IFS=$'\t' read -r date seq start end head; do
    [ -n "$start" ] || continue
    [ "$date" != "0000-00-00" ] || undated=$((undated + 1))
    if [ -n "$surface" ]; then
      text="$(sed -n "${start},${end}p" "$file")"
      printf '%s' "$text" | grep -qiF -- "$surface" || continue
    fi
    kept+=("$start	$end	$head")
  done <<< "$idx"

  if [ "${#kept[@]}" -eq 0 ]; then
    emit_diagnostic "lessons: no section matches '$(clip "$surface")' in $(clip "$file")"
    return 0
  fi

  # Reserve room for the summary BEFORE emitting anything, so a nearly-full
  # budget can never consume the line that reports what was left out.
  local clipped_file summary_max reserve emitted=0 omitted=0 unnamed=0 out sz ph
  clipped_file="$(clip "$file")"
  summary_max="$(byte_len "## ... +${#kept[@]} further section(s) omitted - read $clipped_file")"
  reserve=$((bytes - summary_max - 1))
  [ "$reserve" -gt 0 ] || reserve=0

  for row in "${kept[@]}"; do
    IFS=$'\t' read -r start end head <<< "$row"
    out="$(sed -n "${start},${end}p" "$file")"
    sz="$(byte_len "$out")"
    if [ $((emitted + sz + 1)) -le "$reserve" ]; then
      printf '%s\n' "$out"
      emitted=$((emitted + sz + 1))
      continue
    fi
    omitted=$((omitted + 1))
    # Whole section does not fit: name it in place so nothing vanishes silently.
    # A named section is NOT counted again by the trailing summary — the summary
    # covers only what could not even be named.
    ph="$(clip "$head" 72) - OMITTED (${sz} B) - read $clipped_file"
    sz="$(byte_len "$ph")"
    if [ $((emitted + sz + 1)) -le "$reserve" ]; then
      printf '%s\n' "$ph"
      emitted=$((emitted + sz + 1))
    else
      unnamed=$((unnamed + 1))
    fi
  done

  local diag=""
  if [ "$unnamed" -gt 0 ]; then
    printf '## ... +%d further section(s) omitted - read %s\n' "$unnamed" "$clipped_file"
  fi
  if [ "$omitted" -gt 0 ]; then
    # Count against the sections that MATCHED, not every section in the file —
    # "1 of 40" is misleading when --surface narrowed the set to two.
    diag="lessons: $omitted of ${#kept[@]} section(s) omitted; raise --bytes or read $clipped_file"
  fi
  [ "$undated" -eq 0 ] || diag="${diag:+$diag; }lessons: $undated section(s) without a date sort last"
  emit_diagnostic "$diag"
  [ "$omitted" -eq 0 ] || return 3
}

cmd_archive_search() {
  local pattern="" bytes=4000 limit=3 opts=true
  # `--` ends option parsing so a literal pattern can start with a dash. Flags
  # and shell options are among the most useful things to search this archive
  # for, and without a terminator `archive-search --archive-inbound` is simply
  # unrunnable.
  while [ $# -gt 0 ]; do
    if [ "$opts" = true ]; then
      case "$1" in
        --)      opts=false; shift; continue ;;
        --bytes) need_value "archive-search" $# "$1"; shift; bytes="$1"; shift; continue ;;
        --limit) need_value "archive-search" $# "$1"; shift; limit="$1"; shift; continue ;;
        -?*)     usage_err "archive-search: unknown option '$(clip "$1")' (use -- before a literal pattern starting with '-')" ;;
      esac
    fi
    [ -z "$pattern" ] || usage_err "archive-search: one pattern only"
    pattern="$1"; shift
  done
  [ -n "$pattern" ] || usage_err "archive-search: a search pattern is required"
  require_budget "$bytes" archive-search
  case "$limit" in ''|*[!0-9]*) usage_err "archive-search: --limit must be a positive integer" ;; esac
  [ "$limit" -gt 0 ] || usage_err "archive-search: --limit must be greater than zero"

  local root arch matches sorted
  root="$(main_repo_root)"; [ -n "$root" ] || usage_err "archive-search: not inside a git repository"
  arch="$root/.comms/archive"
  [ -d "$arch" ] || { emit_diagnostic "archive-search: no archive at $(clip "$arch")"; return 0; }

  # Match-filter FIRST, then globally sort only the matches, then --limit. There
  # is no arbitrary pre-cap: the sole pre-filter is "does this file match", which
  # by construction cannot discard a newer *match*. The expensive per-file
  # frontmatter parse therefore runs on the match set, not the whole archive.
  matches="$(grep -rilF --include='*.md' -- "$pattern" "$arch" 2>/dev/null || true)"
  [ -n "$matches" ] || { emit_diagnostic "archive-search: no archived message matches '$(clip "$pattern")'"; return 0; }
  sorted="$(printf '%s\n' "$matches" | sort_paths_by_timestamp newest)"

  local total considered=0 emitted=0 omitted=0 reserve summary_max f rel body hit sz
  total="$(printf '%s\n' "$sorted" | grep -c . || true)"
  summary_max="$(byte_len "... +${total} older match(es) omitted - refine the pattern or raise --bytes")"
  reserve=$((bytes - summary_max - 1))
  [ "$reserve" -gt 0 ] || reserve=0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    considered=$((considered + 1))
    if [ "$considered" -gt "$limit" ]; then omitted=$((omitted + 1)); continue; fi
    rel="${f#"$root"/}"
    # Repo-relative path, and it is placed BEFORE any clipping so the follow-up
    # read stays directly actionable rather than pointing at a truncated path.
    hit="$(printf '%s r%s %s %s %s' \
      "$(frontmatter_field "$f" thread)" "$(frontmatter_field "$f" round)" \
      "$(frontmatter_field "$f" verdict)" "$(frontmatter_field "$f" timestamp)" "$rel")"
    body="$(grep -iF -m2 -A1 -- "$pattern" "$f" 2>/dev/null | sed 's/^/    /' || true)"
    body="$(clip "$body" 400)"
    sz="$(byte_len "$hit$body")"
    if [ $((emitted + sz + 2)) -le "$reserve" ]; then
      printf '%s\n' "$hit"
      [ -z "$body" ] || printf '%s\n' "$body"
      emitted=$((emitted + sz + 2))
    else
      omitted=$((omitted + 1))
    fi
  done <<< "$sorted"

  if [ "$omitted" -gt 0 ]; then
    printf '... +%d older match(es) omitted - refine the pattern or raise --bytes\n' "$omitted"
    emit_diagnostic "archive-search: $omitted of $total match(es) omitted"
    return 3
  fi
}

# ---------------------------------------------------------------------------
# Grading pilot — `findings`, `snapshot`, `prompt-version`
#
# These answer ONE question: which reviewer is good at what. They are
# deliberately NOT a grading system. The pilot's job is to find out whether the
# comparison is measurable at all before anything richer is justified — see
# docs/ROADMAP.md "Reviewer grading & panel track" and consult thread
# `ask-reviewer-grading-panel-mode-9753`.
#
# The schema records what is EPHEMERAL — the reviewed tree, runtime identity,
# prompt version, gating-vs-shadow role — because none of it can be
# reconstructed after the run. Anything derivable later is left out, and an
# unknown field is EMPTY rather than guessed: a retro-extracted row honestly has
# no artifact_id, and pretending otherwise is the failure mode this whole track
# exists to avoid.
#
# There is no separate observation_id. It could only diverge from finding_id if
# two rows were mechanically recognizable as the same claim, and claim
# fingerprinting was explicitly rejected in the consult — so one id is the
# honest count.
#
# What is NOT here, on purpose: dispositions (no cheap honest producer — a
# terminal APPROVE does not confirm each preceding finding), escape attribution
# (textual lineage is not semantic attribution), and any score.
# ---------------------------------------------------------------------------
# v2 (2026-08-22): the claim is stored WHOLE. v1 clipped it to 600 bytes, and because
# rows are immutable and idempotent by finding_id, that clip was permanent — 40 of the
# first 112 rows lost the evidence a later adjudication would need. A display excerpt is
# the reader's job; the ledger's job is to keep what was said. (codex, round 1.)
FINDINGS_SCHEMA_VERSION=2
ARTIFACT_REF_NS="refs/agent-comms/artifacts"

findings_header() {
  printf 'schema_version\tfinding_id\treview_set_id\tartifact_id\tbase_sha\tthread\tphase\tround\treviewer\treviewer_version\tprompt_version\trole\tlane\tanchor\tclaim\tverdict\tsource_message_id\n'
}

hash_stdin() {  # short content hash; whichever digest this box actually has.
  # `cksum` is CRC32 and is NOT collision-resistant, which matters now that this feeds the
  # identity suffix. Git is already mandatory here, so its hash-object is a better last
  # resort than a checksum. (codex, implement r5, advisory.)
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-12
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-12
  elif command -v git >/dev/null 2>&1; then git hash-object --stdin | cut -c1-12
  else cksum | tr -d ' ' | cut -c1-12
  fi
}

findings_extract() {  # <file> <role> <set> <artifact> <reviewer_version> <prompt_version> [base_sha]
  local f="$1" role="$2" rsid="$3" aid="$4" rver="$5" pver="$6" bsha="${7:-}" mid
  # FINDINGS_RAW: parse a frontmatter-less body (the reply-raw.md a broker reads
  # BEFORE any envelope exists). Without it the broker needed a parser of its own,
  # which is exactly how the two rules drifted apart.
  if [ "${FINDINGS_RAW:-}" = "1" ]; then
    mid="$(basename "$f" .md)"
  else
    [ "$(frontmatter_field "$f" type)" = "review-feedback" ] || return 0
    mid="$(frontmatter_field "$f" message_id)"
    [ -n "$mid" ] || mid="$(basename "$f" .md)"
  fi
  # The GATING reviewer's reply arrives later through the normal loop and knows
  # nothing about the shadow run, so its artifact/set identity is joined here
  # from the set index rather than asked of a message that cannot carry it.
  # Explicit flags always win; a miss leaves the fields empty, never guessed.
  if [ -z "$rsid" ] && [ -z "$aid" ] && [ "${FINDINGS_RAW:-}" != "1" ]; then
    local root_j hit
    root_j="$(main_repo_root)" || root_j=""
    if [ -n "$root_j" ]; then
      hit="$(findings_set_lookup "$root_j" "$(frontmatter_field "$f" thread)" "$(frontmatter_field "$f" round)" "$(frontmatter_field "$f" phase)")"
      if [ -n "$hit" ]; then
        rsid="$(printf '%s' "$hit" | cut -f1)"
        aid="$(printf '%s' "$hit" | cut -f2)"
        [ -n "$pver" ] || pver="$(printf '%s' "$hit" | cut -f3)"
      fi
    fi
  fi
  # In raw mode EVERY metadata field is empty. Reading them from the file let a child
  # author its own: `thread: fake<TAB>extra` arrives through `awk -v` as a real tab and
  # shifts `lane` from TSV column 13 to 14, so a caller filtering on $13 counts zero
  # blockers and derives APPROVE -- then the parent stamps trusted metadata and normal
  # extraction sees the blocker. Untrusted input supplies BODY only. (codex, round 4.)
  local rm_thread="" rm_phase="" rm_round="" rm_from="" rm_base="" rm_verdict=""
  if [ "${FINDINGS_RAW:-}" != "1" ]; then
    rm_thread="$(frontmatter_field "$f" thread)"
    rm_phase="$(frontmatter_field "$f" phase)"
    rm_round="$(frontmatter_field "$f" round)"
    rm_from="$(frontmatter_field "$f" from)"
    rm_base="${bsha:-$(frontmatter_field "$f" head_sha)}"
    rm_verdict="$(frontmatter_field "$f" verdict)"
  fi
  awk -v raw="${FINDINGS_RAW:-}" \
      -v probe="${FINDINGS_PROBE:-}" \
      -v schema="$FINDINGS_SCHEMA_VERSION" \
      -v mid="$mid" \
      -v thread="$rm_thread" \
      -v phase="$rm_phase" \
      -v round="$rm_round" \
      -v reviewer="$rm_from" \
      -v base="$rm_base" \
      -v verdict="$rm_verdict" \
      -v role="$role" -v rsid="$rsid" -v aid="$aid" -v rver="$rver" -v pver="$pver" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    # THE placeholder rule. Not "a" rule: the broker verdict derivation reaches this
    # same function through `findings --raw`, because two copies drifted twice --
    # first on list form (numbered findings read as zero), then on CASE (a lowercase
    # "- none" read as a real finding). Each drift let a stamped verdict contradict
    # the body it was stamped onto.
    function isplaceholder(s,   t) {
      t = s; gsub(/[*`_]/, "", t)
      t = trim(t); t = tolower(t)
      return (t == "none" || t == "none.")
    }
    # Emit the buffered bullet. Anchors are best-effort BY DESIGN: 35% of real
    # findings are prose or cross-file and carry none, and dropping those would
    # discard exactly the findings a line-anchored schema is worst at seeing.
    function flush(   claim, anchor, fid) {
      if (buf == "") return
      claim = trim(buf); buf = ""
      if (isplaceholder(claim)) return
      gsub(/\t/, " ", claim)
      anchor = ""
      if (match(claim, /`[^`]+`/)) {
        anchor = substr(claim, RSTART + 1, RLENGTH - 2)
        if (anchor !~ /\// && anchor !~ /\./ && anchor !~ /:[0-9]/) anchor = ""
      }
      # Backtick-free fallback: the pre-2026-07 corpus opened findings with a
      # bare `path:line -` and would otherwise read as unanchored, understating
      # anchor coverage for exactly the oldest half of the baseline.
      if (anchor == "" && match(claim, /^[A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+:[0-9]+([-,][0-9]+)?/))
        anchor = substr(claim, RSTART, RLENGTH)
      gsub(/\t/, " ", anchor)
      seq[blane]++
      fid = mid "#" substr(blane, 1, 1) seq[blane]
      if (probe == "1") { nblock[blane]++; return }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        schema, fid, rsid, aid, base, thread, phase, round, reviewer, rver, pver, \
        role, blane, anchor, claim, verdict, mid
    }
    { sub(/\r$/, "") }
    # Raw mode parses the ENTIRE input as body -- a child that wrapped its reply in
    # horizontal rules could otherwise hide a blocking item inside fake frontmatter.
    NR == 1 && $0 == "---" && raw != "1" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm { next }
    # THE fence lexer, and the only one. Delimiter-AWARE, the same rule install.sh
    # already uses: a fence closes only on the same character, at least as long as the
    # opener, with nothing after it. A length-blind toggle let a 4-backtick wrap around
    # a 3-backtick block expose the quoted findings inside it. Verdict counting,
    # structure presence and finding extraction all read this one lexer, because three
    # copies of "what is a quote" is how rounds 3 and 4 both went wrong.
    {
      line = $0
      if (match(line, /^[ \t]*(```+|~~~+)/)) {
        m = line; sub(/^[ \t]*/, "", m)
        match(m, /^(`+|~+)/); tok = substr(m, 1, RLENGTH)
        ch = substr(tok, 1, 1); len = length(tok)
        rest = substr(m, RLENGTH + 1)
        if (!fence) { fence = 1; fch = ch; flen = len }
        else if (ch == fch && len >= flen && rest ~ /^[ \t]*$/) { fence = 0 }
        next
      }
    }
    fence { next }
    # Verdict lines and structure presence are decided HERE, by the same pass that
    # extracts findings, so the broker can never disagree with its own parser about
    # whether a quoted prior round counted. (codex + grok, round 4.)
    /^VERDICT: (APPROVE|REQUEST_CHANGES)$/ {
      vn++
      if (vn == 1) { vline = NR; vval = substr($0, 10) }
      next
    }
    # Headings are case-tolerant for the same reason placeholders are: a model that
    # writes "### blocking" has still written the section, and treating it as absent
    # skipped the APPROVE cross-check entirely. (grok, round 4.)
    # ATX headings may carry up to three leading spaces and STILL be headings, so the
    # heading rules below read a left-trimmed copy. Requiring column zero meant an indented
    # `   ### Blocking` opened no lane at all: its findings were invisible, the probe said
    # `blocking_section=no`, and an explicit APPROVE sailed through the cross-check.
    # (codex, panel r3.)
    { hline = $0; hsp = 0
      while (hsp < 3 && substr(hline, 1, 1) == " ") { hline = substr(hline, 2); hsp++ } }
    # A TAB is as valid an ATX boundary as a space. Matching only a literal space meant
    # `###<TAB>Blocking` opened no lane, then fell to the generic recognizer, which DID
    # accept the tab as a boundary and closed the (absent) lane -- so the heading and every
    # finding under it were discarded, probing `blocking_section=no` with no residue, and an
    # explicit APPROVE survived. The two recognizers must agree on what a boundary is.
    # (codex, panel r4.)
    tolower(hline) ~ /^###[ \t]+blocking/ { flush(); lane = "blocking"; hasblocking = 1; next }
    tolower(hline) ~ /^###[ \t]+advisory/ { flush(); lane = "advisory"; next }
    # Any other heading at the SAME level or shallower closes the lane -- `### Process`
    # never gates a verdict and is not a code finding, so it is not a graded observation.
    #
    # But a DEEPER heading is structurally inside the lane, not a sibling that ends it, and
    # treating every `^#` as a terminator was a fail-open path: `### Blocking` followed by
    # `#### the attestation is not bound to the tested commit` cleared the lane before any
    # residue rule could see it, probing `blocking_section=yes blocking=0
    # blocking_unparsed=0` -- a derived APPROVE over a heading-shaped finding. Counting the
    # depth is what distinguishes "this section ended" from "someone wrote their finding as
    # a sub-heading". (codex blocking + grok, panel r2.)
    hline ~ /^#/ {
      hlev = 0
      while (substr(hline, hlev + 1, 1) == "#") hlev++
      hb = substr(hline, hlev + 1, 1)
      if (hb == "" || hb == " " || hb == "\t") {
        # A real ATX heading. Same level or shallower ends the lane; DEEPER is content
        # inside it, so it is unread residue like any other unclassifiable line.
        if (lane == "" || hlev <= 3) { flush(); lane = ""; next }
        flush()
        if (!isplaceholder($0)) unparsed[lane]++
        next
      }
      # `##text` is NOT a heading -- ATX requires a space or end of line after the run of
      # hashes. Treating it as one closed a live lane and produced another 0/0 consent
      # path, which is the same fail-open shape by a different door. (codex, panel r3.)
      if (lane != "") { flush(); if (!isplaceholder($0)) unparsed[lane]++ }
      next
    }
    lane == "" { next }
    # A finding is a LIST ITEM, in any markdown list form, indented 0-3 spaces (4+ is a
    # code block, not a list). Matching only column-0 "- " silently extracted nothing
    # from a numbered list, and later nothing from a legally indented one -- and because
    # the verdict is derived from the same count, a review with real blocking findings
    # was stamped APPROVE and composed as a clean panel. Observed in the field.
    {
      li = $0
      lind = 0
      while (substr(li, lind + 1, 1) == " ") lind++
      li = substr(li, lind + 1)
    }
    # A TAB after the marker is valid markdown and was silently dropped -- the same class as
    # the numbered-list miss that started this whole thread, found again at round 10.
    lind <= 3 && li ~ /^[-*+][ \t]/ { flush(); blane = lane; sub(/^[-*+][ \t]+/, "", li); buf = li; next }
    lind <= 3 && li ~ /^[0-9]+[.)][ \t]/ { flush(); blane = lane; sub(/^[0-9]+[.)][ \t]+/, "", li); buf = li; next }
    buf != "" && /^[[:space:]]+[^[:space:]]/ { buf = buf " " trim($0); next }
    buf != "" && /^[[:space:]]*$/ { flush(); next }
    # RESIDUE. Every rule above answers "how many findings did I parse?". Nothing has ever
    # been able to answer "was there anything I FAILED to parse?" -- and the broker derives
    # a verdict from the first question while believing it asked the second. A `### Blocking`
    # lane whose content is not a list item extracts zero, and zero is then read as consent:
    # seven real replies in the archive here were stamped APPROVE that way, one of them over
    # a defect that got fixed twelve minutes later.
    #
    # This is the FOURTH widening of the list-item grammar (column-0 `- `, then numbered,
    # then indented/tabbed, now lead-token and bold-lead paragraphs). Each widening left the
    # same structural hole, because the gate kept asking how much it parsed instead of
    # whether anything defeated it. Counting the residue is what ends the sequence: a fifth
    # grammar would not.
    #
    # FLUSH FIRST, then count. The earlier version guarded on `buf == ""` to protect a
    # lazily-continued list item, and that guard was itself a false all-clear: `- None.`
    # leaves buf set, so an unindented finding on the NEXT line matched no rule at all --
    # not the continuation rule (it wants leading whitespace), not the blank flush, and not
    # this one. It was dropped with no trace, END discarded the placeholder, and the probe
    # reported `blocking=0 blocking_unparsed=0`: a derived APPROVE over a real finding,
    # which is the precise defect this counter exists to end. Both reviewers found it
    # independently, on the question this round asked them to attack.
    #
    # Flushing here means a genuinely un-indented second paragraph of a finding is counted
    # as residue too. That is the honest reading -- the parser did not attach it to
    # anything -- and it does not refuse: a lane with a parsed finding is already
    # REQUEST_CHANGES, so residue there only raises the compose warning. Measured across
    # 134 raw replies: zero occurrences either way.
    #
    # `isplaceholder` still keeps a bare `None.` from counting.
    lane != "" && /[^[:space:]]/ { flush(); if (!isplaceholder($0)) unparsed[lane]++; next }
    END {
      flush()
      if (probe == "1") {
        # An unclosed fence fails CLOSED: everything after it was skipped, so the
        # counts below describe a truncated read and must not be trusted as a verdict.
        printf "verdicts\t%d\nverdict_line\t%d\nverdict\t%s\nblocking_section\t%s\nunclosed_fence\t%s\nblocking\t%d\nadvisory\t%d\nblocking_unparsed\t%d\nadvisory_unparsed\t%d\n", \
          vn + 0, vline + 0, vval, (hasblocking ? "yes" : "no"), (fence ? "yes" : "no"), \
          nblock["blocking"] + 0, nblock["advisory"] + 0, \
          unparsed["blocking"] + 0, unparsed["advisory"] + 0
      }
    }
  ' "$f"
}

findings_rebuild_shadow_rows() {  # <root> — stored shadow replies, re-joined via sets.tsv
  local root="$1" idx d agent set_id aid pver base rver_hist f
  idx="$(findings_set_index "$root")"
  [ -d "$root/.comms/grades/shadow" ] || return 0
  for d in "$root"/.comms/grades/shadow/*/; do
    [ -d "$d" ] || continue
    set_id="$(basename "$d")"
    aid=""; pver=""; base=""
    if [ -f "$idx" ]; then
      aid="$(awk -F'\t' -v s="$set_id" 'NR>1 && $1==s {print $6; exit}' "$idx")"
      pver="$(awk -F'\t' -v s="$set_id" 'NR>1 && $1==s {print $7; exit}' "$idx")"
      base="$(awk -F'\t' -v s="$set_id" 'NR>1 && $1==s {print $8; exit}' "$idx")"
    fi
    # *.md only, and never the *.raw.md of a turn that failed the reply contract —
    # rebuilding must not quietly score what the original run refused to score.
    for f in "$d"*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in *.raw.md) continue ;; esac
      agent="$(basename "$f" .md)"
      # The version RECORDED at run time, or empty. Probing the CLI now would rewrite a
      # historical observation with today's build. (codex, round 2.)
      rver_hist=""
      [ -f "$d$agent.version" ] && rver_hist="$(head -1 "$d$agent.version" | tr -d '\r\n')"
      findings_extract "$f" shadow "$set_id" "$aid" "$rver_hist" "$pver" "$base"
    done
  done
}

cmd_findings() {
  local out="" role="gating" rsid="" aid="" rver="" pver="" bsha="" files="" header_only=false rebuild=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)              need_value "findings" $# "$1"; shift; out="$1" ;;
      --role)             need_value "findings" $# "$1"; shift; role="$1" ;;
      --review-set)       need_value "findings" $# "$1"; shift; rsid="$1" ;;
      --artifact)         need_value "findings" $# "$1"; shift; aid="$1" ;;
      --reviewer-version) need_value "findings" $# "$1"; shift; rver="$1" ;;
      --prompt-version)   need_value "findings" $# "$1"; shift; pver="$1" ;;
      --base-sha)         need_value "findings" $# "$1"; shift; bsha="$1" ;;
      --raw)              FINDINGS_RAW=1; export FINDINGS_RAW ;;
      --probe)            FINDINGS_PROBE=1; export FINDINGS_PROBE ;;
      --header)           header_only=true ;;
      --rebuild)          rebuild=true ;;
      -?*)                usage_err "findings: unknown option '$(clip "$1")'" ;;
      *)                  files="$files$1
" ;;
    esac
    shift
  done
  case "$role" in gating|shadow) ;; *) usage_err "findings: --role must be 'gating' or 'shadow'" ;; esac
  if [ "$header_only" = true ]; then findings_header; return 0; fi

  local root
  root="$(main_repo_root)"; [ -n "$root" ] || usage_err "findings: not inside a git repository"

  # The schema guard is about the OUTPUT file, so it runs before any input can
  # short-circuit: an empty archive was letting a stale-generation ledger through
  # untouched, which is the one case where silence is worst.
  if [ -n "$out" ] && [ -s "$out" ] && [ "$rebuild" != true ]; then
    local have
    have="$(awk -F'\t' 'NR==2 {print $1; exit}' "$out")"
    if [ -n "$have" ] && [ "$have" != "$FINDINGS_SCHEMA_VERSION" ]; then
      die "findings: $(clip "${out##*/}") holds schema v$have rows but this is v$FINDINGS_SCHEMA_VERSION — append would mix generations; re-run with --rebuild to regenerate it from the archive and the shadow store"
    fi
  fi

  # No explicit files: the whole archive, oldest first, so the TSV reads as an
  # append-only history rather than a reverse-chronological listing.
  if [ -z "$files" ]; then
    local arch="$root/.comms/archive"
    if [ -d "$arch" ]; then
      files="$(find "$arch" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort_paths_by_timestamp oldest)"
    else
      emit_diagnostic "findings: no archive at $(clip "$arch")"
    fi
  fi
  # An empty archive is not a reason to stop: --rebuild still has the shadow store to
  # recover, and a rebuild that silently no-ops would leave a stale ledger in place.
  if [ -z "$files" ] && [ "$rebuild" != true ]; then
    emit_diagnostic "findings: no messages to extract"
    return 0
  fi

  local rows f
  rows="$(
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || { emit_diagnostic "findings: no such message $(clip "$f")"; continue; }
      findings_extract "$f" "$role" "$rsid" "$aid" "$rver" "$pver" "$bsha"
    done <<< "$files"
  )"

  # Probe mode answers the broker three questions in one pass -- how many verdict
  # lines, is there a live `### Blocking` section, how many real blockers -- so the
  # broker never needs a grep of its own to disagree with. No header, no rows.
  if [ "${FINDINGS_PROBE:-}" = "1" ]; then
    printf '%s\n' "$rows"
    return 0
  fi
  if [ -z "$out" ]; then
    [ -n "$rows" ] || { emit_diagnostic "findings: no findings extracted"; return 0; }
    findings_header
    printf '%s\n' "$rows"
    return 0
  fi

  # Append-only, and idempotent by finding_id: re-extracting the archive after
  # new reviews land must add only the new rows, never duplicate the old ones.
  mkdir -p "$(dirname "$out")" 2>/dev/null || die "findings: cannot create $(clip "$(dirname "$out")")"
  # A rebuild is written to a TEMP file and moved into place only once it is complete.
  # The earlier version deleted the ledger first, so an interruption or any later write
  # failure left a partial ledger and no original — destroying the very rows the rebuild
  # exists to preserve. (codex, round 2.)
  local target="$out"
  if [ "$rebuild" = true ]; then
    target="$out.rebuild.$$"
    rm -f "$target"
    findings_header > "$target" || die "findings: cannot stage a rebuild next to $(clip "${out##*/}")"
    rows="$rows
$(findings_rebuild_shadow_rows "$root")"
  fi
  [ -s "$target" ] || findings_header > "$target"
  local added=0 skipped=0 fid
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    fid="$(printf '%s' "$f" | cut -f2)"
    if cut -f2 "$target" | grep -qxF -- "$fid"; then skipped=$((skipped + 1)); continue; fi
    printf '%s\n' "$f" >> "$target"
    added=$((added + 1))
  done <<< "$rows"
  if [ "$rebuild" = true ]; then
    # Validate the replacement before it becomes the ledger: a header-only result would
    # otherwise silently replace a populated one.
    if [ "$(head -1 "$target")" != "$(findings_header)" ]; then
      rm -f "$target"; die "findings: rebuild produced a malformed ledger — the original is untouched"
    fi
    mv -f "$target" "$out" || { rm -f "$target"; die "findings: could not install the rebuilt ledger — the original is untouched"; }
  fi
  printf 'findings: +%d new, %d already recorded -> %s\n' "$added" "$skipped" "${out#"$root"/}"
}

# The set index pairs a shadow observation with the gating one. It exists so the
# PRIMARY reviewer's findings — which arrive later, through the normal loop, and
# know nothing about any of this — can be joined to the same artifact without
# re-running anything or touching the loop.
findings_set_index() { printf '%s/.comms/grades/sets.tsv' "$1"; }

# set_attempts_marker <index> <set-id> — the durable per-set record that this set was
# dispatched by a build that plans ATTEMPTS. `panel dispatch` creates it before the first
# plan event, so it outlives the two failures that made the index alone unreliable: a
# driver that dies between planning and its first leg row, and a coordinator log that has
# gone unreadable. Absence of an attempt-bearing leg row cannot prove no modern plan
# existed — it is equally the signature of a plan that crashed early — and reading it as
# proof composes the PREVIOUS round's bound replies while silently discarding the newer
# attempt. The marker is the proof; the index rows are only corroboration.
# (codex, implement r9, blocking.)
set_attempts_marker() { printf '%s/attempts/%s\n' "$(dirname "$1")" "$(safe_name "$2")"; }

# ONE definition of the index header. It was written out twice — `panel dispatch` and
# `shadow` — which is a column-drift waiting to happen the moment either grows a field.
findings_set_header() {
  printf 'review_set_id\trequest_message_id\tthread\tround\tphase\tartifact_id\tprompt_version\tbase_sha\tgating_agent\tshadow_agent\tdrift_status\tdrift_artifact_id\tcreated\tdispatch\n'
}

# set_current_dispatch <index> <set-id> — the attempt a reader should bind to: the LAST row
# recorded for that set, by file order.
#
# A set id is deterministic (thread, phase, round, artifact) and a retry deliberately
# rebinds the set's rows, so set+agent alone cannot separate two concurrent attempts: their
# legs interleave in one index, and a status or composition built from that mixture reports
# a panel that never existed. Rows written before this column existed carry an empty value,
# and an empty current dispatch selects exactly those — legacy sets compose as they always
# did. (codex, implement r1, blocking.)
# set_plan_snapshot <set-id> — ONE validated read of the plan events, and the ONLY source of
# every attempt decision.
#
# The bound attempt, the roster it planned, the union it inherits and the artifact it reviews
# used to come from four separate reads of a file another dispatch can append to between
# them. A concurrent attempt landing mid-compose could therefore supersede the bound one
# while carry-forward silently adopted its NEWER leg as a previous one, and any read that
# failed degraded to an empty value that meant "no roster" or "any artifact" rather than
# "unknown". One read, one snapshot, and every failure is a refusal. (codex, implement r7.)
#
# stdout, one field per line:
#   dispatch <id>        the attempt to bind
#   artifact <id>        the artifact that attempt planned against
#   now <agents...>      planned BY that attempt
#   union <agents...>    planned by it or by any attempt before it
#   chain <ids...>       attempt ids up to and including it, in order
# exit 0 usable | 2 refuse (torn after the plan, unreadable, or incoherent) | 3 no plan
set_plan_snapshot() {
  local f; f="$(events_file)"
  [ -f "$f" ] || return 3
  EV_Q_SET="$(event_identity "$1" "$EVENT_W_SET")" \
  awk -F'\t' -v hdr="$EVENTS_HEADER" -v ev_kinds="$EVENT_KINDS" -v ev_roles="$EVENT_ROLES" \
      "$EVENTS_AWK_LIB"'
    BEGIN { ev_ncols = split(hdr, H, "\t"); s = ENVIRON["EV_Q_SET"] }
    $0 == hdr { next }
    !ev_wellformed() { if (NF) lastbad = NR; next }
    $3 == "panel-planned" && $4 == s {
      lastplan = NR
      if ($5 != last_seen) { chain[++nch] = $5; last_seen = $5 }
      cur = $5
      if (!(($5 SUBSEP $8) in seen_ag)) { seen_ag[$5 SUBSEP $8] = 1; ag[$5] = ag[$5] " " $8 }
      art[$5] = $10
    }
    END {
      if (lastplan == 0) exit 3
      # A torn row AFTER the plan could BE a newer plan; one before it cannot hide anything.
      if (lastbad > lastplan) exit 2
      if (cur == "" || art[cur] == "" || ag[cur] == "") exit 2
      u = ""
      for (i = 1; i <= nch; i++) u = u ag[chain[i]]
      c = ""
      for (i = 1; i <= nch; i++) c = c " " chain[i]
      printf "dispatch\t%s\n", cur
      printf "artifact\t%s\n", art[cur]
      printf "now\t%s\n", ag[cur]
      printf "union\t%s\n", u
      printf "chain\t%s\n", c
    }' "$f"
}

# set_index_has_attempts <index> <set-id> — 0 when this set was dispatched under the
# attempts scheme. Legacy-ness is settled ONCE: for such a set, a plan that has gone
# missing is UNKNOWN, never absent. Reading a later empty snapshot as "legacy" let a
# vanished log clear the roster and compose straight from partial index rows.
# (codex, implement r8, blocking.) The MARKER answers first and the leg rows only
# corroborate, because a modern attempt that crashed between its plan and its first leg
# row leaves an index carrying nothing but legacy-shaped rows — proof of nothing.
# (codex, implement r9, blocking.)
set_index_has_attempts() {
  [ -f "$(set_attempts_marker "$1" "$2")" ] && return 0
  awk -F'\t' -v s="$2" 'NR>1 && $1==s && $14!="" {f=1} END {exit !f}' "$1"
}

# snap_field <snapshot> <name> — one field out of a snapshot, deduplicated.
snap_field() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k {print $2}' \
    | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

# set_current_dispatch <index> <set-id> — the bound attempt, or a refusal. Kept as the name
# every caller already uses; the decision now comes from the snapshot above.
set_current_dispatch() {
  local snap rc
  snap="$(set_plan_snapshot "$2")" && rc=0 || rc=$?
  case "$rc" in
    0) printf '%s\n' "$(snap_field "$snap" dispatch | tr -d ' ')"; return 0 ;;
    2) emit_diagnostic "panel: the coordinator log cannot be trusted about which dispatch attempt of '$(clip "$2")' is current — refusing to guess"
       return 2 ;;
  esac
  # No plan at all: a set recorded before this column existed may still bind, but one
  # dispatched under a recorded attempt may not — that would be last-row-wins again.
  # THROUGH THE ACCESSOR, never a private copy of its rule: this site carried its own inline
  # index scan, so the marker would have settled legacy-ness for two readers and left the
  # third — the one every caller goes through for the bound attempt — deciding it the old,
  # crash-blind way. (codex, implement r9.)
  if set_index_has_attempts "$1" "$2"; then
    emit_diagnostic "panel: '$(clip "$2")' was dispatched under a recorded attempt but no panel-planned event says which is current — refusing to bind (is .comms/events.tsv missing?)"
    return 2
  fi
  printf '\n'
}

# set_agent_leg <index> <set-id> <dispatch> <agent> <prior-dispatch-ids> <artifact>
#
# A reviewer planned by the CURRENT attempt must have a CURRENT row. Carry-forward is for
# union members this attempt did not plan, and only from an attempt EARLIER IN THE CHAIN —
# "any row that is not the bound one" would happily adopt a NEWER concurrent attempt's leg —
# and only from a row that reviewed the same artifact. (codex, implement r6 and r7.)
set_agent_leg() {
  awk -F'\t' -v s="$2" -v d="$3" -v a="$4" -v prior=" $5 " -v art="$6" '
    NR>1 && $1==s && $10==a {
      row = $10 "\t" $3 "\t" $4 "\t" $2
      if ($14 == d) cur = row
      else if (prior != "  " && index(prior, " " $14 " ") > 0 && art != "" && $6 == art) prev = row
    }
    END { print (cur != "" ? cur : (prior != "  " ? prev : "")) }' "$1"
}

# set_legs <index> <set-id> <dispatch> — one line per leg of THAT attempt:
#   <agent> <thread> <round> <request_message_id>, tab separated.
set_legs() {
  awk -F'\t' -v s="$2" -v d="$3" 'NR>1 && $1==s && $14==d {print $10 "\t" $3 "\t" $4 "\t" $2}' "$1"
}

# BOUNDED AT THE SOURCE. A set id longer than the events column was stored encoded there and
# raw in sets.tsv, so the bare listing joined the two forms and reported zero legs for a
# perfectly valid set. Bounding the id itself — rather than teaching each store to re-encode
# — means every store holds the same bytes. (codex + grok, implement r5, advisory.)
safe_set_id() {  # a review_set_id is used as a DIRECTORY NAME — treat it as hostile
  # safe_name NORMALIZES, and normalization is not identity: `a/b` and `a_b` both become
  # `a_b`, so two distinct legal sets would share one directory and the second would
  # overwrite the first's stored reply. Bind the raw value with a hash so distinct inputs
  # stay distinct. (codex, round 2.)
  local raw="$1" out h
  out="$(safe_name "$raw")"
  case "$out" in
    ""|.|..|-*) usage_err "shadow: --review-set '$(clip "$raw")' is not a usable identifier" ;;
  esac
  case "$out" in
    */*|*..*) usage_err "shadow: refusing a review-set id that resolves to a path: $(clip "$raw")" ;;
  esac
  h="$(printf '%s' "$raw" | hash_stdin | cut -c1-8)"
  # Bounded to the events column so the id is stored IDENTICALLY everywhere. Unbounded, a
  # long id went into sets.tsv raw and into the log encoded, and the bare listing joined the
  # two forms and reported zero legs for a valid set. The digest already makes the truncated
  # head unambiguous. (codex + grok, implement r5.)
  printf '%s' "$(event_identity "$(printf '%s-%s' "$out" "$h")" "$EVENT_W_SET")"
}

findings_set_lookup() {  # <root> <thread> <round> <phase> -> set\tartifact\tprompt_version
  # Keyed on thread+phase+round, never thread+round: `/auto-full` keeps one thread across
  # the plan->implement transition and restarts at round 1, so plan r1 and implement r1
  # are different artifacts under the same thread+round. (codex, round 3.)
  local idx; idx="$(findings_set_index "$1")"
  [ -f "$idx" ] || return 0
  # A duplicate here would mean two artifacts claim one thread+phase+round, and there is no
  # right way to choose between them — `shadow` refuses to create that state, so if it
  # exists the file was edited by hand and the honest answer is to join nothing.
  # DISTINCT SET IDS, not rows. Now that a retry preserves the previous attempt's rows
  # instead of deleting them, one thread legitimately has several rows — all naming the same
  # set. Counting rows would read that as an ambiguous join and refuse it. (grok, r2.)
  local n
  n="$(awk -F'\t' -v t="$2" -v r="$3" -v ph="${4:-}" 'NR>1 && $3==t && $4==r && $5==ph && !seen[$1]++ {n++} END {print n+0}' "$idx")"
  if [ "${n:-0}" -gt 1 ]; then
    emit_diagnostic "findings: $n review sets claim thread '$(clip "$2")' ${4:-<no phase>} round $3 — refusing an ambiguous join; fix .comms/grades/sets.tsv"
    return 0
  fi
  awk -F'\t' -v t="$2" -v r="$3" -v ph="${4:-}" 'NR>1 && $3==t && $4==r && $5==ph {print $1 "\t" $6 "\t" $7; exit}' "$idx"
}

cmd_route() {
  # A missing sibling must not abort /auto: fail-open, same as a missing key.
  local sh
  sh="$(cd "$(dirname "$0")" && pwd)/route.sh"
  if [ ! -f "$sh" ]; then
    # The fail-open KEYS block is the CLASSIFY contract and nothing else. A missing helper
    # answering `--shadow` with those ten keys would hand a caller a decision the collector
    # never made, and would defeat the stdout isolation the shadow path is built on. Refuse
    # any non-classify argv loudly instead. (grok, shadow-collector plan r1.)
    # Scan OPTIONS ONLY, stopping at `--`, exactly as route.sh does. A flattened `$*` match
    # loses argument boundaries and the terminator, so `route -- "document the --shadow flag"`
    # was refused instead of failing open — ordinary task text is not an option.
    # (codex P2 + grok, implement r1.) `--shadow-map` is not matched: it has no implementation.
    local _want_shadow=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --) break ;;
        --shadow) _want_shadow=1; shift ;;
        # VALUE-TAKING options consume their argument, so `route --task --shadow` classifies
        # the literal task "--shadow" rather than selecting the collector.
        --task|--file|--current-tier|--context-tokens|--thread) shift 2 || shift ;;
        -*) shift ;;
        *) break ;;   # positional: the task starts here, options are over
      esac
    done
    if [ "$_want_shadow" -eq 1 ]; then
      echo "comms.sh: route: helper missing at $sh — cannot run the shadow collector" >&2
      return 1
    fi
    echo "comms.sh: route: helper missing at $sh — fail-open" >&2
    # Must match route.sh KEYS_FAIL_OPEN (stable 10-key set including tier/gate).
    printf 'plan: no\neffort: medium\ncomplexity: standard\ntier: balanced\ngate: fail-open\nplan_p: -\neffort_p: -\ncomplexity_confidence: -\nsource: fail-open\nreason: route.sh is not installed next to comms.sh\n'
    return 0
  fi
  # Display-only label for the decision record (route.sh cannot resolve a pinned workspace itself).
  COMMS_ROUTE_RECORD_WORKSPACE="$(cmd_workspace 2>/dev/null || true)"; export COMMS_ROUTE_RECORD_WORKSPACE
  if [ -x "$sh" ]; then
    exec "$sh" "$@"
  fi
  exec /bin/bash "$sh" "$@"
}

# REVIEWER ROUTING IS OPT-IN, decided in ONE place. On only when COMMS_REVIEW_ROUTE says so, and
# COMMS_ROUTE=0 (or `/auto --no-route`, which exports it) is the master switch that also turns it
# off. The implementer classifier's own opt-in (COMMS_ROUTE=1 / a backend) does NOT enable it: a
# reviewer turn changing depth is a separate decision from an advisory implementer hint.
review_routing_enabled() {
  case "${COMMS_ROUTE:-}" in 0|false|no|off|FALSE|NO|OFF) return 1 ;; esac
  # NOT gated on COMMS_RUNPHASE_ALLOW_UNCONTAINED. An uncontained reviewer can write the decision
  # store — and equally the mailbox, the thread state and the tree under review; that is what the
  # operator accepted by setting it. Routing would widen nothing, and operators export the override
  # globally, so gating on it would silently make routing unreachable for exactly them.
  case "${COMMS_REVIEW_ROUTE:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; esac
  return 1
}

cmd_review_route() {
  local verb="${1:-}" py
  [ -n "$verb" ] && shift
  py="$(cd "$(dirname "$SELF")" && pwd)/route_review.py"
  case "$verb" in
    enabled) review_routing_enabled; return ;;
    verify)
      # verify <id> --thread <message thread> --phase <p> [--leg-dispatch <d> [--leg-agent <a>]]
      # — the id a request CARRIES, checked against the decision IN FORCE (the record names its
      # own workspace, so the caller's cwd or branch cannot change the answer). The thread must
      # equal the decision's thread, EXCEPT for a routed panel leg its panel recorded (dispatch,
      # this exact decision, raw base thread, agent — see record_panel_route). A `dispatch:` value
      # the author typed earns no exception, so a thread merely NAMED `x-codex` never borrows
      # `x`'s decision. (codex, implement r1/r2.)
      local _vid="${1:-}" _vt="" _vp="" _vd="" _va="" _vbase="" _vleg=""; [ "$#" -gt 0 ] && shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --thread)       need_value "review-route verify" $# "$1"; _vt="$2"; shift 2 ;;
          --phase)        need_value "review-route verify" $# "$1"; _vp="$2"; shift 2 ;;
          --leg-dispatch) need_value "review-route verify" $# "$1"; _vd="$2"; shift 2 ;;
          --leg-agent)    need_value "review-route verify" $# "$1"; _va="$2"; shift 2 ;;
          *) usage_err "review-route verify: unknown option '$(clip "$1")'" ;;
        esac
      done
      printf '%s' "$_vid" | grep -qE '^rd-[0-9a-f]{32}$' || { echo "comms.sh: review-route verify: '$(clip "$_vid")' is not a decision id" >&2; return 1; }
      [ -n "$_vt" ] && [ -n "$_vp" ] || usage_err "review-route verify: --thread and --phase are required"
      command -v python3 >/dev/null 2>&1 || die "review-route: python3 is required"
      [ -f "$py" ] || die "review-route: route_review.py is not installed next to comms.sh — re-run install.sh"
      # A request that names a dispatch is a PANEL LEG and is judged ONLY by its panel's record:
      # no match refuses. Falling back to the standalone exact-thread rule let a decision that
      # merely belongs to a thread named `<base>-<agent>` replace the one the panel stamped.
      # (codex, implement r3.)
      if [ -n "$_vd" ]; then
        _vleg="$(panel_leg_agent "$_vt" "$_vd" "$_vid" "$_va")" || {
          echo "comms.sh: review-route verify: $(clip "$_vid") is not the decision dispatch $(clip "$_vd") recorded for leg thread $(clip "$_vt")" >&2
          return 1
        }
      fi
      python3 "$py" verify --root "$(cmd_root)" --thread "$_vt" --phase "$_vp" ${_vleg:+--leg-agents "$_vleg"} -- "$_vid"
      return ;;
    plan) review_route_plan "$@"; return ;;
    capability) review_route_capability "$@"; return ;;
    decide|show|lookup) ;;
    *) usage_err "review-route: expected decide|lookup|show|verify|enabled|plan|capability" ;;
  esac
  command -v python3 >/dev/null 2>&1 || die "review-route: python3 is required"
  [ -f "$py" ] || die "review-route: route_review.py is not installed next to comms.sh — re-run install.sh"
  if [ "$verb" = decide ]; then
    python3 "$py" decide --root "$(cmd_root)" --workspace "$(cmd_workspace)" \
      --by "$(cmd_whoami 2>/dev/null || echo unknown)" "$@"
  elif [ "$verb" = lookup ]; then
    python3 "$py" lookup --root "$(cmd_root)" --workspace "$(cmd_workspace)" "$@"
  else
    # `--` before the id: an option-shaped value can never be parsed as a flag (e.g. `-h`).
    local _sid="${1:-}"; [ "$#" -gt 0 ] && shift
    printf '%s' "$_sid" | grep -qE '^rd-[0-9a-f]{32}$' || { echo "comms.sh: review-route show: '$(clip "$_sid")' is not a decision id" >&2; return 1; }
    python3 "$py" show --root "$(cmd_root)" "$@" -- "$_sid"
  fi
}

# review_route_plan --to <roster> [--phase P] [--thread T] — each leg's RESOLVED route before
# dispatch: the provider, model, effort and usage limit a panel (or a single `send`) would spend,
# so a planner can tell which usage limits it is about to draw on. READ-ONLY by construction: it
# validates the roster with the rule dispatch uses, asks `transport` which way each leg would go,
# reads (never makes) the routing decision in force, and resolves each leg with the same
# `acp.sh resolve` call runphase makes — then prints. Nothing is decided, recorded, sent or
# classified, and no request text leaves the machine.
#
# One line per leg, in roster order, all or nothing (a leg whose policy would be refused at run
# time refuses the plan, exit 1, before any line is printed):
#   route-plan v1 agent=<a> provider=<p> <acp.sh route-view fields>
# `decision=pending` means routing is on for an implement phase but no decision is in force for
# the thread yet: dispatch will classify, so the values shown are what a `none` candidate — the
# fail-open answer — would run. Pass --thread (the BASE thread) to read the one in force.
review_route_plan() {
  local to="" phase=implement thread="" acp rc bindings="" legacy_opt=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --to)     need_value "review-route plan" $# "$1"; to="$2"; shift 2 ;;
      --phase)  need_value "review-route plan" $# "$1"; phase="$2"; legacy_opt=1; shift 2 ;;
      --thread) need_value "review-route plan" $# "$1"; thread="$2"; legacy_opt=1; shift 2 ;;
      --bindings) need_value "review-route plan" $# "$1"; bindings="$2"; shift 2 ;;
      *) usage_err "review-route plan: unknown option '$(clip "$1")'" ;;
    esac
  done
  if [ -n "$bindings" ]; then
    [ -z "$legacy_opt" ] || usage_err "review-route plan: --bindings names each leg's exact pair; --phase and --thread belong to the routed plan"
    review_route_plan_bound "$bindings" "$to"
    return
  fi
  [ -n "$to" ] || usage_err "review-route plan: --to <agent>[,<agent>...] is required"
  [[ "$phase" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || usage_err "review-route plan: phase '$(clip "$phase")' is not a bare token"
  case "$thread" in *"$(printf '\t')"*|*"
"*) usage_err "review-route plan: a thread may not contain a tab or newline" ;; esac
  # The same gate the routing verbs take, in THIS shell: an unknown COMMS_DELIVERY is refused
  # here rather than inside a substitution below.
  require_known_transport
  local roster
  panel_roster_check "$to" "" "review-route plan"
  roster="$PANEL_ROSTER"   # a local copy, as dispatch keeps: nothing in the loop can clobber it
  acp="$(cd "$(dirname "$SELF")" && pwd)/acp.sh"
  [ -x "$acp" ] || die "review-route plan: acp.sh is not installed next to comms.sh — re-run install.sh"

  # THE DECISION, as the runner would see it. send/panel dispatch stamp one only when routing is
  # on AND the phase is implement (route_decision_for); otherwise the leg carries none.
  local routing=off did=none tier=none effort=none src=none cur root
  review_routing_enabled && routing=on
  if [ "$routing" = on ] && [ "$phase" = implement ]; then
    did=pending
    root="$(cmd_root)"
    if [ -n "$thread" ] && [ -d "$root" ]; then
      command -v python3 >/dev/null 2>&1 || die "review-route plan: python3 is required to read a routing decision"
      cur="$(python3 "$(dirname "$acp")/route_review.py" lookup --root "$root" --workspace "$(cmd_workspace)" \
               --thread "$thread" --phase "$phase" --absent-ok)" && rc=0 || rc=$?
      case "$rc" in
        0) did="$(sed -n 's/^decision: //p' <<<"$cur")"
           tier="$(sed -n 's/^tier: //p' <<<"$cur")"
           effort="$(sed -n 's/^effort: //p' <<<"$cur")"
           src="$(sed -n 's/^source: //p' <<<"$cur")"
           [[ "$did" =~ ^rd-[0-9a-f]{32}$ ]] && [ -n "$tier" ] && [ -n "$effort" ] && [ -n "$src" ] \
             || die "review-route plan: the decision in force for thread '$(clip "$thread")' could not be read" ;;
        3) ;;
        *) die "review-route plan: the routing decision for thread '$(clip "$thread")' is unreadable — dispatch would refuse it too" ;;
      esac
    fi
  fi

  local ag prov tr ptr rec view out=""
  for ag in $roster; do
    prov="$(registry_provider "$ag")" || die "review-route plan: cannot resolve the provider of '$ag'"
    tr="$(cmd_transport "$ag" --loop)" || die "review-route plan: no transport for '$ag'"
    # A loop leg over ACP always runs MOUNTED: send and dispatch stamp the artifact, and runphase
    # mounts every stamped review.
    case "$tr" in
      acp) ptr=acp-mounted ;;
      headless|mailbox) ptr="$tr" ;;
      *) die "review-route plan: '$ag' would use an unknown transport '$(clip "$tr")'" ;;
    esac
    rec="$("$acp" resolve "$prov" --transport "$ptr" --tier "$tier" --effort "$effort" --decision "$did" \
             --routing "$routing" --phase "$phase" --candidate-source "$src")" \
      || { echo "comms.sh: review-route plan: the reviewer policy for '$ag' would be refused at run time (above) — nothing was planned" >&2; exit 1; }
    view="$("$acp" route-view "$prov" - <<<"$rec")" \
      || { echo "comms.sh: review-route plan: could not read the resolved policy for '$ag'" >&2; exit 1; }
    out="$out
route-plan v1 agent=$ag provider=$prov $view"
  done
  printf '%s\n' "${out#?}"
}

# ---- EXACT PER-LEG BINDING (capability layer, Slice 7.4) ----
# `panel dispatch --bindings FILE` runs exactly the model, native effort and expected access profile the
# caller names per leg, or refuses the WHOLE dispatch before anything is written. leg_bind_check is the
# one accessor `panel dispatch`, `review-route plan --bindings` and the runner's run-time re-check share
# (the judgement is helpers/leg_binding.py check_leg), so a plan can never promise what dispatch refuses.

# leg_bind_roster <bindings> <to-or-empty> <author-or-empty> <verb> — the bindings file's agents ARE the
# roster. --to, when given, must name exactly them, in order (the gating reviewer is the first, as ever);
# the roster rules every panel shares then run unchanged (panel_roster_check sets PANEL_ROSTER).
leg_bind_roster() {
  local file="$1" to="$2" author="$3" verb="$4" listed
  command -v python3 >/dev/null 2>&1 || die "$verb: python3 is required for --bindings"
  [ -f "$(dirname "$SELF")/leg_binding.py" ] || die "$verb: leg_binding.py is not installed next to comms.sh — re-run install.sh"
  listed="$(leg_binding_py agents --bindings "$file")" || exit 2
  if [ -n "$to" ] && [ "$(printf '%s' "$to" | tr -d ' ')" != "$listed" ]; then
    usage_err "$verb: --to '$(clip "$to")' must name exactly the bindings file's agents, in order ($listed)"
  fi
  panel_roster_check "$listed" "$author" "$verb"
}

# leg_bind_check <bindings> <verb> [<stamps-out>] — one `route-plan v2` line per leg on stdout, a
# `refused <agent> <code> <detail>` line per refusal on stderr. Exit 0 every leg would run exactly as
# asked, 1 any leg refuses, 2 the file is malformed. Reads configuration and the policy map only: it
# decides nothing, writes no event, reads no credential value and sends nothing. The roster is
# PANEL_ROSTER, set by leg_bind_roster in the caller's shell.
leg_bind_check() {
  local file="$1" verb="$2" stamps="${3:-}" ag prov tr
  local -a pargs=(check --bindings "$file")
  for ag in $PANEL_ROSTER; do
    prov="$(registry_provider "$ag")" || die "$verb: cannot resolve the provider of '$ag'"
    tr="$(cmd_transport "$ag" --loop)" || die "$verb: no transport for '$ag'"
    pargs+=(--ctx "$ag:$prov:$tr")
  done
  [ -z "$stamps" ] || pargs+=(--stamps-out "$stamps")
  leg_binding_py "${pargs[@]}"
}

review_route_plan_bound() {  # <bindings> <to-or-empty>
  local rc=0
  require_known_transport
  leg_bind_roster "$1" "$2" "" "review-route plan"
  leg_bind_check "$1" "review-route plan" || rc=$?
  [ "$rc" = 0 ] || echo "comms.sh: review-route plan: not every leg would run exactly as bound (above); dispatch would refuse it too" >&2
  return "$rc"
}

# review_route_capability [--json] — the negotiation line Basis reads before it binds legs, then one line
# per registered agent stating whether it is bindable. A statement of fact, not a roadmap: an agent with no
# applied and attested policy (claude, grok), a mailbox leg and a consult-only profile are `unbindable` with
# the reason. Read-only.
review_route_capability() {
  local ag prov tr json=""
  local -a pargs=(capability)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) usage_err "review-route capability: unknown option '$(clip "$1")'" ;;
    esac
  done
  require_known_transport
  command -v python3 >/dev/null 2>&1 || die "review-route capability: python3 is required"
  [ -f "$(dirname "$SELF")/leg_binding.py" ] || die "review-route capability: leg_binding.py is not installed next to comms.sh — re-run install.sh"
  local reg; reg="$(registry_agents)" || exit 2
  for ag in $reg; do
    prov="$(registry_provider "$ag")" || die "review-route capability: cannot resolve the provider of '$ag'"
    tr="$(cmd_transport "$ag" --loop)" || die "review-route capability: no transport for '$ag'"
    pargs+=(--ctx "$ag:$prov:$tr")
  done
  [ -z "$json" ] || pargs+=(--json)
  leg_binding_py "${pargs[@]}"
}

# stamp_route_decision <file> <id-or-empty> — the ONLY writer of `route_decision:`. Drops every
# existing line of the key in the frontmatter (a hand-typed value, a duplicate, a blank) and, when
# an id is given, inserts one canonical line at the frontmatter close. The requesting driver is
# the author under review, so the depth of its own review is helper-stamped, never author-typed.
stamp_route_decision() { stamp_fm_key "$1" route_decision "$2"; }

# stamp_fm_key <file> <key> <value-or-empty> — the one writer of a HELPER-STAMPED frontmatter
# key: drops every existing line of <key> (hand-typed, duplicate, blank) and, when a value is
# given, inserts one canonical line at the frontmatter close.
stamp_fm_key() {
  local sf="$1" key="$2" val="$3" stamped
  stamped="$(mktemp "${TMPDIR:-/tmp}/agent-comms-stamp.XXXXXX")" || return 1
  LC_ALL=C awk -v key="$key:" -v val="$val" '
    NR == 1 { nl = ($0 ~ /\r$/) ? "\r\n" : "\n" }
    { probe = $0; sub(/\r$/, "", probe) }
    NR == 1 && probe == "---" { fm = 1; print; next }
    fm && probe == "---" { if (val != "") printf "%s %s%s", key, val, nl; fm = 0; print; next }
    fm && index(probe, key) == 1 { next }
    { print }
  ' "$sf" > "$stamped" && mv -f "$stamped" "$sf" || { rm -f "$stamped" 2>/dev/null; return 1; }
}

# send_role_check <file> <to> — the role rules that need the TARGET. Frontmatter has no `to:`,
# so validate cannot see them; cmd_send is the funnel every template path, every panel leg and
# the broker's reply all reach. Runs before any durable write.
send_role_check() {
  local file="$1" to="$2" ftype ffrom
  [ -f "$file" ] || return 0   # a missing file is validate's refusal, with its own message
  ftype="$(frontmatter_field "$file" type)"
  ffrom="$(frontmatter_field "$file" from)"
  # A review identity receives exactly what a reviewer turn consumes: the request, and the
  # per-leg error lane (`error` is either-direction). Anything else would be turned into an
  # unrequested review by runphase, or is a consult it is not allowed to answer.
  if registry_is_review "$to"; then
    case "$ftype" in
      review-request|error) ;;
      *) die "send: '$to' is a review-only identity — it accepts a review-request or an error, not '${ftype:-<no type>}'" ;;
    esac
  fi
  # SELF-ADDRESS. An agent never reviews or answers its own request: the request and the reply
  # would share one inbox, one thread and one awaiting_from. panel dispatch, ask and shadow each
  # refused this; the single-reviewer send did not, so `/auto --reviewers <self>` worked by
  # omission. Same-model review is a review IDENTITY — a different name, compared as a name.
  case "$ftype" in
    review-request|question)
      if [ -n "$ffrom" ] && [ "$ffrom" = "$to" ]; then
        local remedy
        if registry_is_review "$to"; then
          remedy="A review twin never authors a request."
        elif [ "$ftype" = "review-request" ]; then
          remedy="Same-model review goes to its review twin: --to $(review_twin_of "$to") (\`agents --roster\` swaps it in for you)."
        else
          # A review identity never answers a consult, so it is not the remedy here.
          remedy="Consult another driver ($(registry_drivers))."
        fi
        die "send: '$to' authored this $ftype — an agent cannot review or answer its own request. $remedy Nothing was sent; remove the outbound if it sits in an inbox: $file"
      fi ;;
  esac
}

# live_tree_root — the work tree a send or panel dispatch acts on: the toplevel of the process
# cwd, else the main checkout. The snapshot, the dirty-tree warning, the consult HEAD stamp and
# request_tree_check all resolve through it, so the tree that is checked IS the tree that is pinned.
live_tree_root() {
  local t
  t="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$t" ] || t="$(main_repo_root)"
  printf '%s' "$t"
}

# tree_branch <dir> — the branch checked out in <dir>, spelled as `ask` records it: `HEAD` when
# detached; an unborn branch still answers its name.
tree_branch() {
  git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null \
    || git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

# abs_file <path> — <path> made absolute (physical directory), for a command printed to be re-run
# from a different directory. A directory that cannot be entered keeps the path as given, made
# absolute against $PWD — never a bare `/<basename>`.
abs_file() {
  local d
  if d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)"; then printf '%s/%s' "$d" "$(basename "$1")"
  else case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac
  fi
}

# request_tree_check <request> <verb> <rerun argv...> — THE ARTIFACT A REVIEWER JUDGES MUST BE THE TREE THE
# REQUEST NAMES. A review-request's `cwd:` and `branch:` say which tree it is about; send and
# panel dispatch pin whatever tree they RUN in. Run from the primary for a request written in a
# lane worktree, they pinned main's HEAD and only warned about the workspace — a review of the
# wrong tree that nothing downstream could detect. (field report 2026-09-25, severity 3.)
#
# Every value line is judged, not only the first: a duplicate that disagrees is a request naming
# two trees. Blank values name nothing and are skipped; a request with neither field passes
# untouched. A cwd: that is relative, missing, or outside any git work tree is refused, since
# it cannot be shown to be this tree. Prints nothing and returns 0 when the request names this
# tree; otherwise explains on stderr — both trees, and the command to run from the right place
# (this script with <rerun argv>, which should carry the request's ABSOLUTE path) — and returns 1.
# Reads only: callers run it before any durable write.
request_tree_check() {
  local req="$1" verb="$2" here here_phys here_branch v top phys want_branch="" want_top=""
  local reasons="" where="" abs_req cand cand_ok rerun a
  shift 2
  here="$(live_tree_root)"
  here_phys=""; [ -z "$here" ] || here_phys="$(cd "$here" 2>/dev/null && pwd -P)" || here_phys=""
  here_branch=""; [ -z "$here" ] || here_branch="$(tree_branch "$here")"
  while IFS= read -r v; do
    v="$(printf '%s' "$v" | sed 's/[[:space:]]*$//')"
    [ -n "$v" ] || continue
    case "$v" in
      /*) ;;
      *) reasons="$reasons
  cwd: '$(clip "$v" 512)' is not an absolute path — it names no tree unambiguously"; continue ;;
    esac
    top="$(git -C "$v" rev-parse --show-toplevel 2>/dev/null)" || top=""
    phys=""; [ -z "$top" ] || phys="$(cd "$top" 2>/dev/null && pwd -P)" || phys=""
    if [ -z "$phys" ]; then
      reasons="$reasons
  cwd: '$(clip "$v" 512)' is not inside a git work tree on this machine"
    elif [ "$phys" != "$here_phys" ]; then
      reasons="$reasons
  cwd: '$(clip "$v" 512)' is in the tree $phys"
      [ -n "$want_top" ] || want_top="$phys"
    fi
  done < <(fm_field_lines "$req" cwd)
  while IFS= read -r v; do
    v="$(printf '%s' "$v" | sed 's/[[:space:]]*$//')"
    v="${v#refs/heads/}"
    [ -n "$v" ] || continue
    [ -n "$want_branch" ] || want_branch="$v"
    if [ "$v" != "$want_branch" ]; then
      reasons="$reasons
  branch: '$(clip "$v")' disagrees with the request's other branch: line '$(clip "$want_branch")'"
    elif [ "$v" != "$here_branch" ]; then
      reasons="$reasons
  branch: '$(clip "$v")' is not the branch checked out here"
    fi
  done < <(fm_field_lines "$req" branch)
  [ -n "$reasons" ] || return 0

  # WHERE TO RUN IT INSTEAD: the tree cwd: names, else the worktree holding branch:. Offered
  # only when that tree satisfies EVERY field — a remedy that would be refused again is not one.
  cand="$want_top"
  if [ -z "$cand" ] && [ -n "$want_branch" ]; then
    # awk reads the WHOLE listing: an early `exit` SIGPIPEs git under pipefail (main_repo_root).
    cand="$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$want_branch" '
      /^worktree / { wt = substr($0, 10) } $0 == "branch " b && !n++ { print wt }')" || cand=""
  fi
  if [ -n "$cand" ]; then
    cand_ok=1
    [ -z "$want_branch" ] || [ "$(tree_branch "$cand")" = "$want_branch" ] || cand_ok=0
    while IFS= read -r v; do
      v="$(printf '%s' "$v" | sed 's/[[:space:]]*$//')"
      [ -n "$v" ] || continue
      top="$(git -C "$v" rev-parse --show-toplevel 2>/dev/null)" || top=""
      phys=""; [ -z "$top" ] || phys="$(cd "$top" 2>/dev/null && pwd -P)" || phys=""
      [ "$phys" = "$(cd "$cand" 2>/dev/null && pwd -P)" ] || cand_ok=0
    done < <(fm_field_lines "$req" cwd)
    [ "$cand_ok" = 1 ] && where="$(cd "$cand" 2>/dev/null && pwd -P)" || where=""
  fi
  abs_req="$(abs_file "$req")"
  rerun="$(printf '%q' "$SELF")"
  for a in "$@"; do rerun="$rerun $(printf '%q' "$a")"; done
  {
    echo "comms.sh: $verb: refused — this review-request names a different tree than the one $verb runs in; the snapshot would pin a tree the request does not name. Nothing was written."
    printf '%s\n' "${reasons#?}"
    echo "  running in: ${here_phys:-<not a git work tree>} on branch ${here_branch:-<none>}"
    if [ -n "$where" ]; then
      printf '  run it from the named tree:  (cd %q && %s)\n' "$where" "$rerun"
    else
      echo "  no tree here matches every cwd:/branch: line — correct them (or remove them) in $abs_req, then re-run $verb from the tree they name"
    fi
  } >&2
  return 1
}

# THE PANEL'S OWN RECORD OF ITS ROUTED LEGS. When a routed panel is dispatched it writes, before
# any leg is sent, exactly which decision it stamped, for which RAW base thread, and to which
# agents. The leg exception is granted only against this record, compared byte for byte. The
# coordinator log was not enough: it stores a long thread as a shortened identity, and that
# shortened form is itself a valid thread name, so a request named after it could pass as a leg
# of the long thread's panel. (codex, implement r2.)
panel_routes_file() {  # <dispatch> -> path
  local h; h="$(printf '%s' "$1" | hash_stdin)"
  printf '%s/route-decisions/legs/%s\n' "$(cmd_root)" "$h"
}
record_panel_route() {  # <dispatch> <decision> <raw base thread> <agents...>
  local disp="$1" rid="$2" base="$3" f tmp ag; shift 3
  case "$base" in *"$(printf '\t')"*|*"
"*) die "panel dispatch: a routed base thread may not contain a tab or newline" ;; esac
  f="$(panel_routes_file "$disp")"
  mkdir -p "$(dirname "$f")" || die "panel dispatch: cannot create $(dirname "$f")"
  tmp="$(mktemp "$f.XXXXXX")" || die "panel dispatch: cannot stage the panel route record"
  { printf 'dispatch\t%s\n' "$disp"; printf 'decision\t%s\n' "$rid"; printf 'base\t%s\n' "$base"
    for ag in "$@"; do printf 'agent\t%s\n' "$ag"; done
  } > "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; die "panel dispatch: cannot record the panel's routed legs"; }
}
# panel_leg_agent <thread> <dispatch> <decision> [<agent>] — the agent whose ROUTED PANEL LEG this
# thread is, per the panel's own record: the record names this dispatch and this decision, and
# <thread> == <raw base>-<agent> for one of its agents (optionally only the given one). Prints the
# agent and returns 0, else returns 1.
panel_leg_agent() {
  local thr="$1" disp="$2" rid="$3" only="${4:-}" f
  [ -n "$thr" ] && [ -n "$disp" ] && [ -n "$rid" ] || return 1
  f="$(panel_routes_file "$disp")"
  [ -f "$f" ] || return 1
  THR="$thr" DISP="$disp" RID="$rid" ONLY="$only" LC_ALL=C awk -F'\t' '
    $1 == "dispatch" { nd++; d = $2; next }
    $1 == "decision" { nr++; r = $2; next }
    $1 == "base"     { nb++; b = $2; next }
    $1 == "agent"    { ag[++na] = $2; next }
    END {
      if (nd != 1 || nr != 1 || nb != 1 || d != ENVIRON["DISP"] || r != ENVIRON["RID"] || b == "") exit 1
      for (i = 1; i <= na; i++) {
        if (ENVIRON["ONLY"] != "" && ag[i] != ENVIRON["ONLY"]) continue
        if (ENVIRON["THR"] == b "-" ag[i]) { print ag[i]; exit 0 }
      }
      exit 1
    }' "$f"
}

# route_decision_for <request> <base-thread> <phase> <artifact> <base> — decide (or reuse) the
# reviewer decision for (base thread, phase) and print its id. Empty output + status 0 when
# routing is off or the phase is not routed. Dies when routing is on and no decision can be
# recorded: a request that asked to be routed must not silently go out unrouted. Called AFTER the
# snapshot, so the decider measures the artifact itself rather than the author's summary of it.
route_decision_for() {
  local req="$1" thr="$2" ph="$3" aid="$4" base="$5" out rid
  review_routing_enabled || return 0
  # Only the implement phase is routed in this slice: an approach review keeps the baseline.
  [ "$ph" = implement ] || return 0
  [ -n "$thr" ] || die "reviewer routing is on but the request has no thread — cannot key a decision"
  out="$(cmd_review_route decide --request "$req" --thread-override "$thr" --phase "$ph" \
           ${aid:+--artifact "$aid"} ${base:+--base "$base"})" \
    || die "reviewer routing: could not record a decision for thread '$thr' phase '$ph'"
  rid="$(printf '%s\n' "$out" | sed -n 's/^decision: //p' | head -1)"
  [ -n "$rid" ] || die "reviewer routing: the decider printed no decision id"
  printf '%s\n' "$rid"
}

cmd_ask() {
  # ask --from <agent> --to <agent> [--wait] (--file F | words...)
  #
  # The synchronous consult verb, and the FIRST driver-neutral one. Claude has /ask;
  # every other agent had to hand-author frontmatter, send, capture a run dir, await it,
  # find the reply and archive it — six steps for "ask a question". That asymmetry is why
  # this tool is Claude-to-drive rather than any-agent-to-drive. (Field report from a
  # codex session, 2026-08-26.)
  local from="" to="" qfile="" wait_flag="" words=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) need_value "ask" $# "$1"; shift; from="$1" ;;
      --to)   need_value "ask" $# "$1"; shift; to="$1" ;;
      --file) need_value "ask" $# "$1"; shift; qfile="$1" ;;
      --wait) wait_flag="--wait" ;;
      -?*)    usage_err "ask: unknown option '$(clip "$1")'" ;;
      *)      words="${words:+$words }$1" ;;
    esac
    shift
  done
  [ -n "$from" ] || usage_err "ask: --from <agent> is required (who is asking)"
  [ -n "$to" ]   || usage_err "ask: --to <agent> is required"
  require_driver "$from" "ask"; require_agent "$to" "ask"
  [ "$from" != "$to" ] || usage_err "ask: '$from' cannot consult itself"
  # A review identity is review-only: it answers review requests, never consults.
  if registry_is_review "$to"; then
    usage_err "ask: '$to' is a review-only identity — consult a driver instead (drivers: $(registry_drivers))"
  fi
  [ -n "$qfile" ] || [ -n "$words" ] || usage_err "ask: a question is required (--file F or words)"
  [ -z "$qfile" ] || [ -f "$qfile" ] || usage_err "ask: no such file '$(clip "$qfile")'"

  local root ws ts mid f
  root="$(cmd_root)"; ws="$(cmd_workspace)"
  ts="$(date -u +%Y-%m-%dT%H-%M-%S)"
  mid="$(safe_name "$ws")_${ts}_ask-${from}-to-${to}-$$"
  f="$root/$(inbox_for "$to")/${mid}.md"
  mkdir -p "$(dirname "$f")" 2>/dev/null || die "ask: cannot create $(dirname "$f")"
  {
    printf -- '---\n'
    printf 'type: question\n'
    printf 'from: %s\n' "$from"
    printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'branch: %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    printf 'workspace: %s\n' "$ws"
    printf 'cwd: %s\n' "$(pwd)"
    printf 'message_id: %s\n' "$mid"
    printf -- '---\n\n'
    printf '## Question\n\n'
    if [ -n "$qfile" ]; then cat "$qfile"; else printf '%s\n' "$words"; fi
  } > "$f"
  cmd_validate "$f" >/dev/null || die "ask: composed a malformed question (this is a bug)"
  echo "ask: $from -> $to  ($mid)"
  cmd_send --to "$to" $wait_flag "$f"
}

# panel_roster_check <to> <author-or-empty> <verb> — the roster rules every panel shares, in the
# CALLER's shell (it sets PANEL_ROSTER, space-separated, rather than printing it, so a usage_err
# cannot be swallowed by a command substitution): every name registered, the author (when known)
# never a leg, no name twice, and one leg per PROVIDER. `panel dispatch` refuses a roster with it
# before anything is written; `review-route plan` refuses the same roster, so a plan can never
# describe a panel that dispatch would not send.
panel_roster_check() {
  local to="$1" author="$2" verb="$3" ag roster="" prov provs=""
  [ -n "$(printf '%s' "$to" | tr -d ', ')" ] || usage_err "$verb: --to names no reviewer"
  for ag in $(printf '%s' "$to" | tr ',' ' '); do
    require_agent "$ag" "$verb"
    # IDENTITY compare, deliberately: a leg on the author's own PROVIDER under its own name
    # (claude-review reviewing claude) is the point of review identities.
    [ -z "$author" ] || [ "$ag" != "$author" ] || usage_err "$verb: '$ag' authored this request — it cannot review it"
    case " $roster " in *" $ag "*) usage_err "$verb: '$ag' listed twice" ;; esac
    # Two legs on one PROVIDER are one model reviewing twice: same routing decision, same
    # provider-keyed policy, same prompt — compose would count their agreement as two
    # independent reviewers. This is the early, friendly refusal; compose re-checks what it
    # actually counts, from the replies' own provider stamps.
    prov="$(registry_family "$ag")" || usage_err "$verb: cannot resolve the family of '$ag'"
    case " $provs " in
      *" $prov "*) usage_err "$verb: two legs on provider '$prov' ($(printf '%s' "$to" | tr ',' ' ')) — a panel's reviewers must be independent; keep one '$prov'-backed reviewer" ;;
    esac
    provs="$provs $prov"
    roster="$roster $ag"
  done
  PANEL_ROSTER="${roster# }"
}

cmd_panel() {
  # panel dispatch --to a,b <review-request>   — fan one artifact out to N reviewers
  # panel status  --set <id>                   — which legs have answered
  #
  # N PARALLEL 2-PARTY LEGS, never an N-party thread. Each reviewer gets its own thread
  # (`<base>-<agent>`) so the wire protocol, the state layer and every existing reader
  # keep working unchanged; a shared `review_set` links them and the DRIVER composes
  # above them. That is the whole trick: nothing below the driver has to learn about
  # panels.
  #
  # ONE snapshot for the whole set. If each leg snapshotted itself they would review
  # different trees and "they saw the same artifact" would be false in the one place it
  # has to be true.
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in dispatch|status) ;; *) usage_err "panel: expected 'dispatch' or 'status'" ;; esac

  local root; root="$(main_repo_root)"; [ -n "$root" ] || usage_err "panel: not inside a git repository"

  if [ "$sub" = "status" ]; then
    local set_id=""
    while [ $# -gt 0 ]; do
      case "$1" in --set) need_value "panel status" $# "$1"; shift; set_id="$1" ;; -?*) usage_err "panel status: unknown option '$(clip "$1")'" ;; esac
      shift
    done
    local idx; idx="$(findings_set_index "$root")"
    [ -f "$idx" ] || { emit_diagnostic "panel: no review sets recorded yet"; return 0; }
    # Bare `panel status` LISTS the sets. The durable record already survives the
    # driver's death — every route writes the reply into the driver's inbox before
    # result.json, and sets.tsv is append-only — but until now nothing could enumerate
    # it, so a resumed session had to already know the set id it was waiting for. That
    # made a recoverable panel unrecoverable in practice: an await dies with its
    # process, and the id it printed died with the scrollback.
    #
    # This is a pure read of sets.tsv — no message is opened and no leg is resolved, so
    # the listing cannot be wrong about state it did not inspect. `--set <id>` answers
    # who has replied; this answers which sets exist. Newest last in an append-only
    # file, so it is walked backwards rather than by parsing timestamps.
    if [ -z "$set_id" ]; then
      # The header is printed by the SAME awk as the rows. From the shell it sat in the
      # stdio buffer bash uses whenever stdout is a pipe, so `panel status | head -1` could
      # see a row before the header — the identical defect the events reader had, one level
      # up, and the reason the pinned header could not be asserted positionally.
      # `legs` counts the CURRENT attempt, not every attempt ever recorded. Preserving a
      # retry's rows (which is what makes attempt isolation possible) would otherwise make a
      # two-leg set dispatched twice report four legs — and the header is a pinned output
      # contract, so the count is what had to change, not its name. (codex, implement r4.)
      local curf; curf="$(mktemp "${TMPDIR:-/tmp}/agent-comms-cur.XXXXXX" 2>/dev/null || true)"
      if [ -n "$curf" ] && [ -f "$(events_file)" ]; then
        awk -F'\t' -v hdr="$EVENTS_HEADER" -v ev_kinds="$EVENT_KINDS" -v ev_roles="$EVENT_ROLES" \
          "$EVENTS_AWK_LIB"'
          BEGIN { ev_ncols = split(hdr, H, "\t") }
          $0 == hdr { next }
          !ev_wellformed() { next }
          $3 == "panel-planned" { cur[$4] = $5 }
          END { for (k in cur) printf "%s\t%s\n", k, cur[k] }' "$(events_file)" > "$curf" 2>/dev/null \
          || : # an unreadable log degrades the COUNT; it must not kill the listing, which is
               # the surface a driver reaches for after losing its set id. As the last
               # command of an `if` body this exit status was errexit's, and the whole
               # process died having printed nothing. (self-review, round 6.)
      fi
      # NF>=13: a truncated row would otherwise be counted as a leg and printed with
      # blank metadata, which is the listing lying about durable state. (codex, r1.)
      awk -F'\t' -v curf="${curf:-/dev/null}" '
      BEGIN {
        print "set\tphase\tround\tlegs\tcreated"
        while ((getline line < curf) > 0) { split(line, P, "\t"); cur[P[1]] = P[2] }
      }
      NR>1 && NF>=13 && $1!="" {
        if (!($1 in seen)) { seen[$1]=1; order[++n]=$1; ph[$1]=$5; rd[$1]=$4; cr[$1]=$13 }
        want = ($1 in cur) ? cur[$1] : ""
        if ($14 == want) legs[$1]++
      }
      END { for (i=n; i>=1; i--) { k=order[i]; printf "%s\t%s\t%s\t%s\t%s\n", k, ph[k], rd[k], legs[k]+0, cr[k] } }' "$idx"
      [ -z "$curf" ] || rm -f "$curf" 2>/dev/null || true
      emit_diagnostic "panel: 'panel status --set <id>' shows each leg's reply and verdict"
      return 0
    fi
    # Resolve the workspace ONCE — per-candidate calls also re-emit the resolver's
    # stderr warning per leg, which interleaves into 2>&1 captures of this table.
    local status_ws; status_ws="$(cmd_workspace)"
    # Read the registry HERE, in cmd_panel's own shell, where a malformed config can still
    # abort the command. Inside the per-leg scan it is a substitution subshell and the
    # failure is unobservable. The `local` is split from the assignment on purpose:
    # `local x="$(cmd)"` reports the status of `local`, not of the command.
    local status_reg; status_reg="$(registry_agents)" || exit 2
    # Header and rows from ONE writer. Printed from the shell it sat in the stdio buffer
    # bash uses whenever stdout is a pipe, so `panel status --set X | head -1` could see a
    # row first — the same defect fixed for the bare listing and the events reader.
    # (grok, implement r5, advisory.)
    # Same binding as compose: a leg is answered by the reply to THIS set's request,
    # never by whatever the newest same-agent same-thread message happens to be. A
    # status that says "answered / APPROVE" off a stale or type:error message is the
    # false all-clear compose exists to refuse. (grok, panel r1.)
    local status_dispatch one_row pag one_carry status_prior
    status_dispatch="$(set_current_dispatch "$idx" "$set_id")" \
      || die "panel status: cannot determine which dispatch attempt of '$(clip "$set_id")' is current"
    # Planned legs with no index row are listed too: a leg that vanished from the index is
    # exactly what a recovering driver needs to SEE, not something to omit. (codex, r5.)
    local status_planned
    local status_snap status_rc status_planned status_now status_art status_chain
    status_snap="$(set_plan_snapshot "$set_id")" && status_rc=0 || status_rc=$?
    case "$status_rc" in
      0) status_planned="$(snap_field "$status_snap" union)"
         status_now="$(snap_field "$status_snap" now)"
         status_art="$(snap_field "$status_snap" artifact | tr -d ' ')"
         status_chain="$(snap_field "$status_snap" chain)"
         status_dispatch="$(snap_field "$status_snap" dispatch | tr -d ' ')" ;;
      3) set_index_has_attempts "$idx" "$set_id" \
           && die "panel status: '$(clip "$set_id")' was dispatched under a recorded attempt but has no readable plan — that is UNKNOWN, not legacy"
         status_planned=""; status_now=""; status_art=""; status_chain="" ;;
      *) die "panel status: the coordinator log cannot be trusted about the roster of '$(clip "$set_id")'" ;;
    esac
    { if [ -n "$status_planned" ]; then
        for pag in $status_planned; do
          case " $(printf '%s' "$status_now" | tr '\n' ' ') " in
            *" $pag "*) one_carry=0 ;;
            *)          one_carry=1 ;;
          esac
          status_prior=""
          [ "$one_carry" = 1 ] && status_prior="$(printf '%s' "$status_chain" | sed "s/ *$status_dispatch *\$//")"
          one_row="$(set_agent_leg "$idx" "$set_id" "$status_dispatch" "$pag" "$status_prior" "$status_art")"
          if [ -n "$one_row" ]; then printf '%s\n' "$one_row"
          else printf '%s\t(no leg row recorded)\t\t\n' "$pag"; fi
        done
      else
        set_legs "$idx" "$set_id" "$status_dispatch"
      fi
    } | { printf 'reviewer\tthread\tanswered\tverdict\n'
    local st_provs="" st_dup=""
    while IFS=$'\t' read -r ag th rnd req_mid; do
      [ -n "$ag" ] || continue
      local reply="" verdict="" answered=no cand
      for cand in $(leg_reply_candidates "$root" "$status_ws" "$ag" "$th" "$status_reg"); do
        [ -f "$cand" ] || continue
        [ -z "$rnd" ] || [ "$(frontmatter_field "$cand" round)" = "$rnd" ] || continue
        [ -z "$req_mid" ] || [ "$(frontmatter_field "$cand" in-reply-to)" = "$req_mid" ] || continue
        [ "$(frontmatter_field "$cand" type)" = "review-feedback" ] || continue
        # Validate like compose does, or the two disagree: a bound reply with a
        # missing verdict/body shows "answered" here and INCOMPLETE there.
        # (codex, panel r2.)
        cmd_validate "$cand" >/dev/null 2>&1 || continue
        reply="$cand"; break
      done
      if [ -n "$reply" ]; then
        answered=yes; verdict="$(cmd_verdict "$reply" 2>/dev/null || true)"
        # The same provenance rule compose gates on (reply_provider), so status cannot show a
        # healthy panel that compose will refuse. Reported on stderr: the table is a pinned shape.
        local st_p st_first
        st_p="$(reply_family "$reply")"
        if [ -n "$st_p" ]; then
          st_first="$(printf '%s\n' "$st_provs" | awk -F'\t' -v p="$st_p" '$1 == p { print $2; exit }')"
          if [ -n "$st_first" ]; then
            st_dup="$st_dup
panel status: WARNING — $st_first and $ag both answered on provider $st_p; compose will refuse this set"
          else
            st_provs="$st_provs
$st_p	$ag"
          fi
        fi
      fi
      printf '%s\t%s\t%s\t%s\n' "$ag" "$th" "$answered" "$verdict"
    done
    [ -z "$st_dup" ] || printf '%s\n' "${st_dup#?}" >&2; }
    return 0
  fi

  # ---- dispatch ----
  local to="" req="" set_id="" bindings=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)  need_value "panel dispatch" $# "$1"; shift; to="$1" ;;
      --set) need_value "panel dispatch" $# "$1"; shift; set_id="$1" ;;
      --bindings) need_value "panel dispatch" $# "$1"; shift; bindings="$1" ;;
      -?*)   usage_err "panel dispatch: unknown option '$(clip "$1")'" ;;
      *)     [ -z "$req" ] || usage_err "panel dispatch: one review-request only"; req="$1" ;;
    esac
    shift
  done
  [ -n "$to" ] || [ -n "$bindings" ] || usage_err "panel dispatch: --to a,b is required"
  [ -n "$req" ] || usage_err "panel dispatch: a review-request file is required"
  [ -f "$req" ] || usage_err "panel dispatch: no such file '$(clip "$req")'"
  [ "$(frontmatter_field "$req" type)" = "review-request" ] \
    || usage_err "panel dispatch: only a review-request can be fanned out"

  local author base_thread phase round maxr wf
  author="$(frontmatter_field "$req" from)"
  base_thread="$(frontmatter_field "$req" thread)"
  phase="$(frontmatter_field "$req" phase)"; round="$(frontmatter_field "$req" round)"
  maxr="$(frontmatter_field "$req" max-rounds)"; wf="$(frontmatter_field "$req" workflow)"
  [ -n "$wf" ] || usage_err "panel dispatch: the request carries no workflow — a panel reviews a loop turn"

  # Validate the whole roster BEFORE dispatching any leg: a half-fanned panel is worse
  # than none, because the composed gate would silently be missing a voice.
  # The AUTHOR must be a driver: a review identity never authors (validate refuses it too, but
  # only per leg, after the plan events are written — too late to refuse cleanly).
  [ -n "$author" ] && registry_has "$author" && registry_is_review "$author" \
    && usage_err "panel dispatch: '$author' is a review-only identity — it cannot author a review request"
  local roster LEG_STAMPS=""
  # EXACT PER-LEG BINDING (opt-in; without --bindings nothing below differs from before). The bindings
  # file's agents ARE the roster, and every listed leg is judged BEFORE the first durable write: any leg
  # that cannot run exactly as bound — an optional one included, because which legs exist is the
  # caller's decision, not this tool's — refuses the whole dispatch, and nothing is snapshotted,
  # logged, indexed or sent.
  if [ -n "$bindings" ]; then
    leg_bind_roster "$bindings" "$to" "$author" "panel dispatch"
    roster="$PANEL_ROSTER"
    local stamps_file lrc=0
    stamps_file="$(mktemp "${TMPDIR:-/tmp}/agent-comms-legs.XXXXXX")" || die "panel dispatch: cannot stage the leg bindings"
    leg_bind_check "$bindings" "panel dispatch" "$stamps_file" >/dev/null || lrc=$?
    if [ "$lrc" != 0 ]; then
      rm -f "$stamps_file" 2>/dev/null || true
      echo "comms.sh: panel dispatch: refused — a listed leg cannot run exactly as bound (each refusal above); nothing was written and no leg was started" >&2
      [ "$lrc" = 2 ] && exit 2
      exit 1
    fi
    LEG_STAMPS="$(cat "$stamps_file")"; rm -f "$stamps_file" 2>/dev/null || true
    [ -n "$LEG_STAMPS" ] || die "panel dispatch: the leg bindings produced no stamps — refusing"
  else
    panel_roster_check "$to" "$author" "panel dispatch"
    roster="$PANEL_ROSTER"
  fi
  # The request must name the tree this dispatch runs in — checked before the snapshot, so a
  # refusal pins nothing and writes no leg, event or index row.
  local -a rerun_legs=(--to "$to")
  [ -z "$bindings" ] || rerun_legs=(--bindings "$(abs_file "$bindings")")
  request_tree_check "$req" "panel dispatch" panel dispatch "${rerun_legs[@]}" \
    ${set_id:+--set "$set_id"} "$(abs_file "$req")" || exit 2

  local aid pver dispatch_pair dispatch_base synthetic_note=""
  dispatch_pair="$(cmd_snapshot create --with-base)" || die "panel dispatch: could not retain the artifact"
  aid="${dispatch_pair%%	*}"
  dispatch_base="${dispatch_pair#*	}"
  [ "$dispatch_base" = "$dispatch_pair" ] && dispatch_base=""
  # REVIEWER ROUTING: decided ONCE for the base thread and phase, after the snapshot (so the
  # decider measures THIS artifact) and before any durable write (so a routing failure refuses
  # the whole panel rather than half of it). Every leg carries the same id and each leg's send
  # validates it without re-deciding; resolution per PROVIDER happens in runphase.
  # A bound dispatch makes NO routing decision: the caller named the pair, so there is no tier to classify.
  local panel_route_id=""
  if [ -z "$bindings" ]; then
    panel_route_id="$(route_decision_for "$req" "$base_thread" "$phase" "$aid" "$dispatch_base")" \
      || die "panel dispatch: reviewer routing failed — refusing to fan out"
  fi
  # A SYNTHETIC snapshot means the tree was DIRTY at dispatch: the artifact reviewers read is
  # not any commit you made, and every uncommitted file — including work belonging to another
  # session in a shared checkout — is inside it. This needs no knowledge of WHOSE files they
  # are, which is what made it available when a doc rule was not: cmd_snapshot already returns
  # artifact == base for a clean tree and artifact != base for a synthetic one. Warn, never
  # refuse — a deliberate dirty dispatch is legitimate, an accidental one is what cost a claude
  # session a hand-written "please ignore" note to a panel that had already read the files.
  # (codex + grok, staging-safety r1, corroborated.)
  if [ -n "$dispatch_base" ] && [ "$aid" != "$dispatch_base" ]; then
    # THE TREE THAT WAS SNAPSHOTTED, not the main checkout. cmd_snapshot reads `show-toplevel`,
    # so a dispatch from a worktree snapshots THAT worktree — reporting `$(cmd_root)/..` listed
    # the main checkout's dirt instead, which is both wrong and reassuring in the worst case.
    # (codex + grok, staging-safety r2, corroborated blocking.)
    local dirty_root dirty_list
    # cmd_snapshot's OWN resolver (live_tree_root), fallback included — re-querying blind is how
    # the r2 wrong-tree bug happened. (codex + grok, r3, advisory.)
    dirty_root="$(live_tree_root)"
    # Captured in ONE read, not piped into `head`: under `set -euo pipefail` a `git status |
    # head -10` pipeline returns nonzero when head closes the pipe early, so a tree with more
    # than ten dirty files would have KILLED the dispatch it was meant to warn about.
    # (codex, r2, blocking.)
    dirty_list=""
    [ -n "$dirty_root" ] && dirty_list="$(git -C "$dirty_root" status --porcelain 2>/dev/null || true)"
    echo "warning: dispatching a SYNTHETIC snapshot — the tree was dirty, so reviewers will read uncommitted work:" >&2
    printf '%s\n' "$dirty_list" | sed -n '1,10p' | sed 's/^/  /' >&2
    [ "$(printf '%s\n' "$dirty_list" | grep -c .)" -gt 10 ] && echo "  … and more" >&2
    echo "  commit first if that is not what you meant (AGENTS.md: 'commit before dispatching')." >&2
    synthetic_note=" [SYNTHETIC snapshot: dirty tree]"
  fi
  pver="$(cmd_prompt_version 2>/dev/null || true)"
  [ -n "$set_id" ] || set_id="$(printf '%s-%s-r%s-%s' "${base_thread:-panel}" "${phase:-nophase}" "${round:-1}" "$(printf '%s' "$aid" | cut -c1-7)")"
  set_id="$(safe_set_id "$set_id")"

  local idx; idx="$(findings_set_index "$root")"
  mkdir -p "$(dirname "$idx")" 2>/dev/null || true
  [ -s "$idx" ] || findings_set_header > "$idx"

  local gating="${roster%% *}" leg_thread leg_file leg_mid ts n=0 dispatch_id
  # THE ATTEMPT ID. A set id is deterministic — same thread, phase, round and artifact
  # produce the same one — and a retry deliberately rebinds the set's rows. So set+agent
  # cannot tell two CONCURRENT attempts apart: plan-A, plan-B, A/codex, B/codex, B/grok,
  # A/grok interleave in one file and neither "latest plan" nor "latest request per agent"
  # reconstructs an unmixed attempt. Every event of a leg carries the id of the dispatch it
  # belongs to, and the legs carry it on the wire so the runner and the broker can stamp it
  # too. (codex, plan r2, blocking.)
  dispatch_id="d-$(date -u +%Y%m%dT%H%M%S)-$$-${RANDOM}"
  # STAKED BEFORE ANY OTHER DURABLE TRACE OF THIS ATTEMPT — before the plan events, before
  # the legs, before the index rows. Every one of those can be missing after a crash or an
  # unreadable log; this cannot, and it is what lets a reader tell "genuinely legacy" from
  # "a modern attempt that died young". Refusing here is right: a set that cannot record
  # what scheme it was dispatched under is a set a later compose may misclassify.
  local attempts_marker; attempts_marker="$(set_attempts_marker "$idx" "$set_id")"
  mkdir -p "$(dirname "$attempts_marker")" 2>/dev/null || true
  : >> "$attempts_marker" \
    || die "panel dispatch: could not record that '$(clip "$set_id")' plans dispatch attempts — refusing to fan out a panel a later reader could mistake for legacy"
  # THE EXPECTED ROSTER, PERSISTED BEFORE ANY LEG GOES OUT. Legs are sent sequentially, so
  # a crash after leg 1 of 2 leaves a history that is otherwise indistinguishable from a
  # legitimate one-leg panel — and `compose` would gate on that roster believing it was
  # complete. A re-dispatch writes a second row; the LAST one is authoritative, exactly as
  # the sets.tsv rebind already treats a retry. (codex, plan r1, blocking.)
  # ONE ROW PER PLANNED LEG, all sharing this attempt. The roster used to live only in a
  # note, so nothing could ENFORCE it: `compose` counted whatever leg rows the index happened
  # to hold, and a driver that died between two leg rows left "1 of 1" — a truncated panel
  # gating as a complete one, which is the hole the roster event was added to close.
  # Recording the planned reviewer in the `agent` column makes the roster a set of rows any
  # reader can compare against. (codex, implement r5, blocking.)
  # The routed legs are recorded BEFORE any leg is sent; each leg's send and runphase verify
  # against this record rather than guessing a base thread from the leg's name.
  if [ -n "$panel_route_id" ]; then
    # shellcheck disable=SC2086
    record_panel_route "$dispatch_id" "$panel_route_id" "$base_thread" $roster
  fi
  local plan_ag plan_bound
  for plan_ag in $roster; do
    # A bound leg's opaque resolution reference, role and requirement are echoed verbatim, never interpreted.
    plan_bound=""
    [ -z "$LEG_STAMPS" ] || plan_bound="$(printf '%s\n' "$LEG_STAMPS" | awk -F'\t' -v a="$plan_ag" '$1 == a { printf " bound=1 ref=%s role=%s requirement=%s route_id=%s", $4, $5, $6, $7; exit }')"
    cmd_events append --kind panel-planned --set "$set_id" --dispatch "$dispatch_id" \
      --thread "${base_thread:-panel}" \
      --round "$round" --agent "$plan_ag" --artifact "$aid" \
      --request-id "$(frontmatter_field "$req" message_id)" --status planned \
      --note "roster=$(printf '%s' "$roster" | tr ' ' ',') legs=$(printf '%s' "$roster" | wc -w | tr -d ' ') phase=${phase:-} gating=$gating$plan_bound" \
      || die "panel dispatch: could not record the roster in the coordinator log — refusing to fan out a panel whose legs nothing can enumerate"
  done
  echo "panel: dispatching artifact ${aid} to [$roster] as review set $set_id (gating: $gating)"
  for ag in $roster; do
    ts="$(date -u +%Y-%m-%dT%H-%M-%S)"
    leg_thread="${base_thread:-panel}-${ag}"
    leg_mid="$(safe_name "$(cmd_workspace)")_${ts}_panel-${ag}-$$-${n}"
    leg_file="$root/.comms/$(inbox_for "$ag")/${leg_mid}.md"
    mkdir -p "$(dirname "$leg_file")" 2>/dev/null || true
    # Same body, same artifact, same round — only identity and routing differ. Anything
    # else here would make the legs incomparable, which is the point of fanning out.
    LC_ALL=C awk -v th="$leg_thread" -v mid="$leg_mid" -v setid="$set_id" -v aid="$aid" -v base="$dispatch_base" -v disp="$dispatch_id" -v rid="$panel_route_id" '
      NR == 1 { nl = ($0 ~ /\r$/) ? "\r\n" : "\n" }
      { probe = $0; sub(/\r$/, "", probe) }
      NR == 1 && probe == "---" { fm = 1; print; next }
      fm && probe == "---" {
        printf "review_set: %s%s", setid, nl
        printf "dispatch: %s%s", disp, nl
        printf "artifact_id: %s%s", aid, nl
        if (base != "") printf "head_sha: %s%s", base, nl
        if (rid != "") printf "route_decision: %s%s", rid, nl
        fm = 0; print; next
      }
      # An inbound routing id is never carried: the helper decided the panel id above.
      fm && index(probe, "route_decision:") == 1 { next }
      fm && index(probe, "thread:") == 1 { printf "thread: %s%s", th, nl; next }
      fm && index(probe, "message_id:") == 1 { printf "message_id: %s%s", mid, nl; next }
      fm && index(probe, "artifact_id:") == 1 { next }
      # A request derived from a prior panel inbound can already carry review_set —
      # appending the new one after it loses to grep -m1 and the round would gate on
      # the OLD set. Replace, exactly like artifact_id. (grok, panel r2.)
      fm && index(probe, "review_set:") == 1 { next }
      fm && index(probe, "dispatch:") == 1 { next }
      fm && index(probe, "head_sha:") == 1 { next }
      { print }
    ' "$req" > "$leg_file"
    cmd_validate "$leg_file" >/dev/null || die "panel dispatch: leg for '$ag' did not validate"
    # A RETRY of the same request over the same tree deterministically recreates the
    # set id, but the fresh legs carry NEW message ids. Keeping the old row binds the
    # leg to a request nobody was sent: the new replies can never satisfy status or
    # compose — or, if the old set had completed, its stale replies replay as this
    # dispatch's answers. Rebind the agent's row to THIS dispatch. (codex, panel r3.)
    # SCOPED TO THIS ATTEMPT. Deleting every same-set/same-agent row deleted the OTHER
    # attempt's leg, which is what defeated the dispatch column: interleave two dispatches
    # (A plans, B plans, A/codex, B/codex replacing it, B/grok, A/grok replacing it) and the
    # index ends holding B/codex and A/grok — one leg per attempt, so the selected attempt
    # composes as a COMPLETE one-leg panel. Rows of other attempts are now preserved and
    # `set_legs` filters them out instead. (codex + grok, implement r2, corroborated.)
    if awk -F'\t' -v s="$set_id" -v a="$ag" -v d="$dispatch_id" 'NR>1 && $1==s && $10==a && $14==d' "$idx" | grep -q .; then
      local idx_tmp; idx_tmp="$(mktemp "${TMPDIR:-/tmp}/agent-comms-sets.XXXXXX")"
      awk -F'\t' -v s="$set_id" -v a="$ag" -v d="$dispatch_id" '!(NR>1 && $1==s && $10==a && $14==d)' "$idx" > "$idx_tmp" \
        && command mv -f "$idx_tmp" "$idx" \
        && emit_diagnostic "panel: retry — rebound $ag's leg of $set_id to this dispatch's request"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$set_id" "$leg_mid" "$leg_thread" "$round" "$phase" "$aid" "$pver" \
      "${dispatch_base:-$(frontmatter_field "$req" head_sha)}" "$gating" "$ag" "dispatched" "" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dispatch_id" >> "$idx"
    echo "  leg: $ag  thread=$leg_thread"
    local -a bound_send=()
    if [ -n "$LEG_STAMPS" ]; then
      # The binding rides with the leg, helper-stamped by `send --bound-leg`, so the runner can judge it
      # again from the stamp alone before it launches anything.
      local bound_row
      bound_row="$(printf '%s\n' "$LEG_STAMPS" | awk -F'\t' -v a="$ag" '$1 == a { print; exit }')"
      [ -n "$bound_row" ] || die "panel dispatch: no binding stamp for '$ag' — refusing to send an unbound leg of a bound panel"
      bound_send=(--bound-leg "$(printf '%s' "$bound_row" | cut -f2)" --bound-digest "$(printf '%s' "$bound_row" | cut -f3)")
      echo "  bound: ref=$(printf '%s' "$bound_row" | cut -f4) route_id=$(printf '%s' "$bound_row" | cut -f7) model=$(printf '%s' "$bound_row" | cut -f8) effort=$(printf '%s' "$bound_row" | cut -f9)"
    fi
    cmd_send --to "$ag" ${bound_send[@]+"${bound_send[@]}"} "$leg_file" || echo "  warning: leg for '$ag' did not deliver — the set is incomplete"
    n=$((n + 1))
  done
  echo "panel: $set_id dispatched to $n reviewer(s)$synthetic_note; compose with 'comms.sh panel status --set $set_id'"
}

# ONE definition of "this event row proves the leg's review can never be published", as an awk
# function the degrade walk concatenates into its program. degrade_reason() returns the reason
# the row records, or "" when the row is not evidence. Only a FAILED row qualifies, and only for
# a reason the runner itself wrote, in the position it writes it:
#   provider-result  reason=no-output         — the provider exited non-zero having produced
#                                               nothing (runphase.sh, where the provider exits)
#   turn-finished    reason=no-output|policy-unapplied
#                                             — the TURN's terminal row (runphase.sh write_result).
#                                               policy-unapplied: the broker refused to publish a
#                                               review whose model/effort could not be attested.
# The turn-finished match is ANCHORED to the prefix write_result emits (`exit=N reason=R `), so a
# free-text note or a provider-reported session id later in the row cannot forge the token.
# Other refusal reasons (containment-unconfirmed, runtime-incompatible, canary-*) stay undroppable:
# they are retry-and-fix conditions, not an operator's roster decision.
DEGRADE_EVIDENCE_AWK='
function degrade_reason(   s) {
  if ($14 != "failed") return ""
  if ($3 == "provider-result") return ($15 ~ /(^| )reason=no-output( |$)/) ? "no-output" : ""
  if ($3 == "turn-finished" && match($15, /^exit=[0-9]+ reason=(no-output|policy-unapplied)( |$)/)) {
    s = substr($15, 1, RLENGTH); sub(/^exit=[0-9]+ reason=/, "", s); sub(/ $/, "", s); return s
  }
  return ""
}'

degrade_reason_text() {  # <reason> — what a dropped leg's evidence means, for the log and the banner
  case "$1" in
    no-output)        printf 'produced no output at all' ;;
    # Covers every policy-unapplied refusal, pre-prompt ones included (a preflight mismatch, a
    # policy record that changed, a rollout snapshot that could not be taken) — not only a
    # post-turn attestation, so it must not claim the review ran. (grok, r1 advisory.)
    policy-unapplied) printf 'its review was refused publication: the reviewer model/effort policy could not be applied or attested' ;;
    *)                printf 'recorded reason %s' "$1" ;;
  esac
}

# degrade_why <agent> — the evidence reason compose recorded for a dropped leg. Reads
# DEGRADED_WHY (`agent<TAB>reason` lines, a cmd_compose local) by dynamic scope.
degrade_why() { printf '%s\n' "${DEGRADED_WHY:-}" | awk -F'\t' -v a="$1" '$1==a {r=$2} END {print r}'; }

# degrade_leg_events <set> <dispatch> <agent> — the leg's GATING event rows, every one. The ONE
# read both the evidence walk and the fingerprint are computed from, so eligibility and the
# baseline it is re-checked against describe the same history: fingerprinting in a second read
# let a boundary landing between the two become part of a baseline nobody judged. (codex, r1.)
# `--role gating`, because `comms.sh shadow` runs the leg's request copy under the SAME set and
# dispatch with its rows marked `role=shadow`, and the shadow target can be a gating agent of the
# set: a shadow's failed attestation would otherwise drop a live gating reviewer. (grok, r1.)
# `--all`, because this is a CORRECTNESS read: a capped window can cut a run's first row off and
# make its late terminal row look like a fresh run. (See degrade_evidence.)
degrade_leg_events() {
  cmd_events --all --role gating --set "$1" --dispatch "$2" --agent "$3" 2>/dev/null
}

# degrade_evidence < events — print the reason the leg's attempts prove it cannot publish, exit 0;
# or print why not, exit 1. The rule is QUIESCENCE, not attribution: a leg is droppable only when
# nothing about it can still be in motion, judged from the leg's own gating rows.
#   1. every send has finished delivering — each `request-persisted` is matched by a
#      `request-dispatched` carrying the same per-send attempt id (`attempt=` at the head of both
#      notes; counted, so a repeated id still needs a delivery row per send). A send between its
#      persist and its delivery may yet spawn a runner.
#   2. every run the log knows of has finished — any run named by a `request-dispatched`,
#      `turn-started`, `provider-result` or `turn-finished` has a `turn-finished`.
#   3. the run that finished LAST (by its first `turn-finished`) recorded qualifying evidence:
#      degrade_reason, filed under that run. A non-qualifying provider-result clears it; a
#      non-qualifying turn-finished (older rows had no reason; log-incomplete) adds nothing.
# Attributing rows to "the current run" was tried first and every signal it rested on turned out
# to be advisory, delayed or shared: row order (a dedupe looked like a replacement), a clipped
# run path, a delayed delivery row, a dead predecessor named by `already running`, a late start of
# the same request, a foreground `--wait` run racing a detached one. (codex + grok, r1–r4.) None of
# them can make a live run look finished here: a run is open until its OWN terminal row. The cost
# is availability, never safety: a gap does not heal by re-sending (the old persist or run stays in
# this dispatch's history). `await` fills only a runner that died before its result.json; any other
# gap needs a fresh `panel dispatch`. (codex, r5 advisory.)
# Run identity is the run_dir column, stored through event_identity (unique past its width).
degrade_evidence() {
  awk -F'\t' "$DEGRADE_EVIDENCE_AWK"'
    function attempt_id(n) { return match(n, /^attempt=[A-Za-z0-9._-]+/) ? substr(n, 9, RLENGTH - 8) : "" }
    function seen(r) { if (r != "" && !(r in open)) open[r] = 1 }
    NR>1 && $3=="request-persisted"  { sent[attempt_id($15)]++; next }
    NR>1 && $3=="request-dispatched" { a = attempt_id($15); if (sent[a] > done[a]) done[a]++; seen($13); next }
    NR>1 && $3=="turn-started"       { seen($13); next }
    NR>1 && $3=="provider-result"    { if ($13 == "") next; seen($13); ev[$13] = degrade_reason(); next }
    NR>1 && $3=="turn-finished"      {
      if ($13 == "") next
      seen($13); if (open[$13]) { open[$13] = 0; last = $13 }
      r = degrade_reason(); if (r != "") ev[$13] = r
      next
    }
    END {
      for (a in sent) if (sent[a] > done[a]) { print "a send of this leg has not recorded its delivery yet"; exit 1 }
      for (r in open) if (open[r]) { print "a run of this leg has not finished: " r; exit 1 }
      if (last == "") { print "no run of this leg has finished"; exit 1 }
      if (ev[last] == "") { print "its last finished run recorded no reason=no-output or reason=policy-unapplied failure"; exit 1 }
      print ev[last]; exit 0
    }'
}

# The state of a leg's turn history, as one comparable string. Used to accept a degradation
# and then to RE-CHECK it immediately before publishing: "latest turn" sampled once is a
# TOCTOU, because another process can re-send the leg while the composition is being built and
# the live reviewer would still be dropped. (codex, implement r3, blocking — the concurrency
# form of the same stale-evidence defect, found after the dispatch and re-send forms.)
degrade_boundary_state() {  # <set> <dispatch> <agent> [<events already read>] -> a comparable state string
  # `--all`, because this is a CORRECTNESS read. The default cap is 50 rows: once a leg had
  # that many boundary events, appending another dropped one from the window and left the
  # count pinned at 50, so history could move with every sampled field identical.
  # (codex, implement r4, blocking.)
  #
  # The fingerprint identifies the terminal row ITSELF — run dir, request and message id, and
  # the note — not just its shape. A one-second timestamp resolution plus a re-send that lands
  # and finishes with the same kind and status would otherwise compare equal, and a failed
  # result WITHOUT the marker could replace qualifying evidence undetected.
  # `request-persisted` is a BOUNDARY too, and it is the load-bearing one. `turn-started` is
  # written through advisory `log_event`: if that append fails the review still runs, with
  # LOG_INCOMPLETE=1 — so a re-send could leave the OLD no-output result as the latest visible
  # boundary and both fingerprints would match while a reviewer worked. `request-persisted` is
  # appended FAIL-CLOSED before delivery, so a re-send cannot happen without one.
  # (codex, implement r5, blocking — and its own diagnosis of the whole arc: the recurring weak
  # point was never the comparison, it was which durable event marks an attempt beginning.)
  # `turn-finished` and `request-dispatched` are fingerprinted because the evidence walk reads
  # them (the evidence row, and the run an attempt attached to); the fingerprint must cover every
  # row the evidence walk reads — from the same read, when
  # the caller has one (degrade_leg_events).
  { if [ $# -ge 4 ]; then printf '%s\n' "$4"; else degrade_leg_events "$1" "$2" "$3"; fi; } \
    | awk -F'\t' '
        NR>1 && ($3=="request-persisted" || $3=="request-dispatched" || $3=="turn-started" || $3=="provider-result" || $3=="turn-finished") {
          n++; ts=$1; k=$3; st=$14; rd=$13; rq=$11; mid=$12; note=$15
        }
        END { printf "%d|%s|%s|%s|%s|%s|%s|%s", n+0, ts, k, st, rd, rq, mid, note }'
}

cmd_compose() {
  # compose --set <id> [--out F] — read every leg's findings, cluster them, and say what
  # the panel actually gates on.
  #
  # THIS IS NOT A JUDGE. Nothing is dropped, nothing is rewritten, and no model is asked
  # to arbitrate: the union is preserved verbatim and each finding is labelled by how much
  # SUPPORT it has. Judgment lives in the gate, not in a rewritten bundle — a bundle that
  # is "nobody's review" is how unique real findings vanish without a trace, and recall is
  # already unobservable here.
  #
  # The gate is CORROBORATION, deliberately neither of the two obvious rules:
  #   any-blocks      — one noisy reviewer holds every loop hostage
  #   primary-only    — unique findings never gate, which wastes the panel entirely
  #
  # DEGRADATION is opt-in, explicit, and evidence-gated. `--degrade a,b` drops named legs and
  # composes over the rest, but ONLY for a leg the coordinator's own log shows could not
  # review at all (`provider-result ... reason=no-output`: the provider exited non-zero
  # having produced zero bytes). A leg that is merely slow, or that answered unusably, is
  # never droppable — the first will still arrive and the second is a review, not an absence.
  # The reduction is written to the log before anything is composed, so a degraded verdict is
  # never reconstructible as a full-panel one.
  local set_id="" out="" degrade="" DEGRADED_AGENTS="" DEGRADED_STATE="" DEGRADED_WHY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --degrade) need_value "compose" $# "$1"; shift; degrade="$1" ;;
      --set) need_value "compose" $# "$1"; shift; set_id="$1" ;;
      --out) need_value "compose" $# "$1"; shift; out="$1" ;;
      -?*)   usage_err "compose: unknown option '$(clip "$1")'" ;;
      *)     usage_err "compose: unexpected argument '$(clip "$1")'" ;;
    esac
    shift
  done
  [ -n "$set_id" ] || usage_err "compose: --set <id> is required"
  local root; root="$(main_repo_root)"; [ -n "$root" ] || usage_err "compose: not inside a git repository"
  local idx; idx="$(findings_set_index "$root")"
  [ -f "$idx" ] || usage_err "compose: no review sets recorded"

  local ws; ws="$(cmd_workspace)"
  # Same reason as panel status: the registry has to be read where a failure can abort.
  local reg; reg="$(registry_agents)" || exit 2
  # The ROUND is part of a leg's identity. Finding replies by reviewer+thread alone
  # makes round 2 compose round 1's replies and report "all answered" — the panel would
  # gate on findings about an artifact it is no longer reviewing. (grok, panel r1.)
  local compose_dispatch
  compose_dispatch="$(set_current_dispatch "$idx" "$set_id")" \
    || die "compose: cannot determine which dispatch attempt of '$(clip "$set_id")' is current — refusing to gate on a guessed roster"
  # ONE snapshot, taken once, for every attempt decision below. Deriving them from separate
  # reads let a concurrent dispatch change the answer between two of them. (codex, r7.)
  local compose_snap compose_rc planned_all planned_now compose_art compose_chain
  compose_snap="$(set_plan_snapshot "$set_id")" && compose_rc=0 || compose_rc=$?
  case "$compose_rc" in
    0) planned_all="$(snap_field "$compose_snap" union)"
       planned_now="$(snap_field "$compose_snap" now)"
       compose_art="$(snap_field "$compose_snap" artifact | tr -d ' ')"
       compose_chain="$(snap_field "$compose_snap" chain)"
       compose_dispatch="$(snap_field "$compose_snap" dispatch | tr -d ' ')" ;;
    3) set_index_has_attempts "$idx" "$set_id" \
         && die "compose: '$(clip "$set_id")' was dispatched under a recorded attempt but has no readable plan — that is UNKNOWN, not legacy; refusing to gate from index rows alone"
       planned_all=""; planned_now=""; compose_art=""; compose_chain="" ;;
    *) die "compose: the coordinator log cannot be trusted about the roster of '$(clip "$set_id")' — refusing to gate on a roster it cannot enumerate" ;;
  esac
  local legs=""
  if [ -n "$planned_all" ]; then
    local one_ag one_row one_carry
    for one_ag in $planned_all; do
      # planned by THIS attempt -> its row must come from this attempt; otherwise it may be
      # carried forward, but only from the same artifact.
      case " $(printf '%s' "$planned_now" | tr '\n' ' ') " in
        *" $one_ag "*) one_carry=0 ;;
        *)             one_carry=1 ;;
      esac
      # prior attempts only: the chain minus the bound attempt itself.
      local compose_prior=""
      [ "$one_carry" = 1 ] && compose_prior="$(printf '%s' "$compose_chain" | sed "s/ *$compose_dispatch *\$//")"
      one_row="$(set_agent_leg "$idx" "$set_id" "$compose_dispatch" "$one_ag" "$compose_prior" "$compose_art")"
      [ -n "$one_row" ] && legs="${legs:+$legs
}$one_row"
    done
  else
    legs="$(set_legs "$idx" "$set_id" "$compose_dispatch")"
  fi
  # THE PLAN IS THE ROSTER. Counting index rows alone let a dispatch that died between two
  # leg rows compose as a complete one-leg panel. A planned reviewer with no leg row is a leg
  # that was promised and never recorded — unanswerable, and never a quorum.
  # (codex, implement r5, blocking.)
  local planned missing="" pag
  planned="$planned_all"
  if [ -n "$planned" ]; then
    for pag in $planned; do
      printf '%s\n' "$legs" | awk -F'\t' -v a="$pag" '$1==a' | grep -q . || missing="$missing $pag"
    done
  fi
  if [ -n "$missing" ]; then
    echo "compose: INCOMPLETE — this attempt planned legs for [$(printf '%s' "$planned" | tr '\n' ' ')] but the index records none for:$missing"
    echo "compose: refusing to gate on a roster the dispatch never finished recording"
    cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" \
      --status roster-incomplete --note "planned=$(printf '%s' "$planned" | tr '\n' ',') missing=$(printf '%s' "$missing" | tr ' ' ',')" \
      || echo "warning: coordinator log not updated (composition-refused)" >&2
    return 3
  fi
  [ -n "$legs" ] || usage_err "compose: review set '$(clip "$set_id")' has no legs"

  local rows="" ag th rnd req_mid reply cand n_legs=0 n_answered=0 pending="" unread="" blind="" answered_agents="" leg_providers=""
  # The GATING reviewer is the one the bound attempt recorded (sets.tsv column 9, written by
  # dispatch as the roster's first name). A leg carried forward from an earlier attempt does not
  # get to redefine it, so the row is read for THIS dispatch only; the roster order is the
  # fallback for an index row that predates the column.
  local gating_ag gating_rnd="" gating_req="" gating_reply=""
  gating_ag="$(awk -F'\t' -v s="$set_id" -v d="$compose_dispatch" 'NR>1 && $1==s && $14==d && $9!="" {print $9; exit}' "$idx")"
  [ -n "$gating_ag" ] || gating_ag="$(printf '%s' "$planned_now" | awk '{print $1}')"
  [ -n "$gating_ag" ] || gating_ag="$(printf '%s\n' "$legs" | awk -F'\t' 'NF {print $1; exit}')"
  while IFS=$'\t' read -r ag th rnd req_mid; do
    [ -n "$ag" ] || continue
    n_legs=$((n_legs + 1))
    [ "$ag" = "$gating_ag" ] && { gating_rnd="$rnd"; gating_req="$req_mid"; }
    reply=""
    for cand in $(leg_reply_candidates "$root" "$ws" "$ag" "$th" "$reg"); do
      [ -f "$cand" ] || continue
      # Same round, or nothing. A reply from an earlier round answers an earlier
      # question.
      [ -z "$rnd" ] || [ "$(frontmatter_field "$cand" round)" = "$rnd" ] || continue
      # BOUND to this set's request, or nothing. Round+thread alone is not identity:
      # dispatch reuses <base>-<agent> leg threads, and plan r1 / implement r1 collide
      # on thread+round — archived plan approvals composed as a clean implement panel
      # in a live repro. The request_message_id is already in sets.tsv and every
      # conformant reply stamps it as in-reply-to; an unbound reply is not an answer.
      # (codex + grok, panel r1.)
      [ -z "$req_mid" ] || [ "$(frontmatter_field "$cand" in-reply-to)" = "$req_mid" ] || continue
      # A leg is answered only by a VALID review-feedback — checked INSIDE the scan,
      # skip-and-continue, exactly like panel status. Stopping at the first bound hit
      # and validating after the break made the two disagree whenever the newest bound
      # candidate was invalid but an older valid one existed. (codex, panel r1;
      # codex + grok scan-order asymmetry, panel r3.)
      if [ "$(frontmatter_field "$cand" type)" != "review-feedback" ] \
         || ! cmd_validate "$cand" >/dev/null 2>&1; then
        emit_diagnostic "compose: skipping an invalid or non-review message on $ag's leg"
        continue
      fi
      reply="$cand"; break
    done
    if [ -z "$reply" ]; then pending="$pending $ag"; continue; fi
    n_answered=$((n_answered + 1)); answered_agents="$answered_agents $ag"
    [ "$ag" = "$gating_ag" ] && gating_reply="$reply"
    leg_providers="$leg_providers
$ag	$(reply_family "$reply")"
    # A panel must never print a finding count over content it could not read. The broker
    # refuses to STAMP such a reply, but a leg can reach compose by other routes (a
    # self-sending agent authors its own envelope), and a partially-unreadable lane is not
    # refusable — it has real findings AND residue, so it under-reports rather than
    # blocking. This is the only surface that tells the driver the counts below are short.
    # Residue-only and truncated legs REFUSE (below); a MIXED lane — real findings plus
    # residue — is the note-never-a-gate case, and it fires on roughly a third of the
    # replies in this archive that carry real findings.
    local leg_probe leg_resid leg_block leg_fence
    leg_probe="$(FINDINGS_PROBE=1 findings_extract "$reply" gating "$set_id" "" "" "" "" 2>/dev/null)"
    leg_resid="$(printf '%s\n' "$leg_probe" | awk -F'\t' '$1=="blocking_unparsed"{print $2; exit}')"
    leg_block="$(printf '%s\n' "$leg_probe" | awk -F'\t' '$1=="blocking"{print $2; exit}')"
    leg_fence="$(printf '%s\n' "$leg_probe" | awk -F'\t' '$1=="unclosed_fence"{print $2; exit}')"
    # The broker refuses an unclosed fence and an unreadable probe before it will stamp
    # anything; compose sees replies the broker never touched (a self-sending agent authors
    # its own envelope), so it has to refuse on the SAME signals or the gate simply moves.
    # An unclosed fence means parsing STOPPED there: zero blockers and zero residue describe
    # a truncated read, not a clean review. (codex, panel r4.)
    if [ -z "$leg_probe" ] || [ "$leg_fence" = "yes" ]; then
      blind="$blind
compose: ${ag}s leg could not be read to the end (${leg_fence:+unclosed code fence}${leg_fence:+; }the counts below would describe a truncated read, not a clean review): $reply"
    elif [ "${leg_resid:-0}" -gt 0 ] && [ "${leg_block:-0}" -eq 0 ]; then
      # REFUSE, not warn. The broker applies this same rule before stamping, but a leg can
      # reach compose without passing through it — a self-sending agent authors its own
      # envelope, and a `verdict: APPROVE` over an unreadable Blocking lane passes
      # cmd_validate. Composing it prints "0 findings (0 blocking)" and empty gates, and the
      # loop treats a successful composition as actionable: the same false all-clear, one
      # layer out. (codex, panel r3.)
      blind="$blind
compose: ${ag}s leg reports NO blocking findings, but its Blocking section carries ${leg_resid} line(s) this parser could not read — that zero is a failed read, not a clean review: $reply"
    elif [ "${leg_resid:-0}" -gt 0 ]; then
      # Mixed lane: real findings AND residue. Warning only, deliberately — the leg is
      # already REQUEST_CHANGES, so the verdict is safe and refusing would block a correct
      # change request over an unreadable nit.
      unread="$unread
compose: WARNING — the Blocking section on ${ag}s leg carries ${leg_resid} line(s) this parser could not read as findings; the counts below UNDERSTATE that leg. Open it and read that section yourself before acting on this composition: $reply"
    fi
    rows="$rows
$(findings_extract "$reply" gating "$set_id" "" "" "" "")"
  done <<< "$legs"

  # An unanswered leg is NOT an approval. A panel that quietly composes over a missing
  # voice is worse than one reviewer, because it looks like more.
  if [ -n "$pending" ]; then
    # A DEGRADED composition is allowed only when the operator named the missing legs AND
    # the log proves each one could not review. Both halves matter: naming alone would let a
    # slow leg be discarded, and evidence alone would let silence lower the bar by itself.
    local degraded_ok="" degrade_bad="" ag_d p_d why_d ev_d
    if [ -n "$degrade" ]; then
      for ag_d in $(printf '%s' "$degrade" | tr ',' ' '); do
        case " $(printf '%s' "$pending" | tr -s ' ') " in
          *" $ag_d "*) ;;
          *) degrade_bad="$degrade_bad
compose: '$ag_d' is not a missing leg in this set — refusing to drop a reviewer that is not absent"; continue ;;
        esac
        # THE LEG'S LATEST TURN MUST BE THE FAILED ONE. Binding to the dispatch was still not
        # enough: recovery deliberately allows re-sending a failed leg, and a re-send KEEPS the
        # dispatch identity — so the sequence "turn fails, marker recorded, operator re-sends,
        # new turn still running" let the stale marker drop a leg that was actively reviewing.
        # (codex, implement r2, blocking; the r1 fix closed only the cross-dispatch half.)
        # The walk itself, and why each row kind counts, is degrade_evidence. The fingerprint
        # the drop is later re-checked against is taken from this SAME read.
        ev_d="$(degrade_leg_events "$set_id" "$compose_dispatch" "$ag_d")"
        if why_d="$(printf '%s\n' "$ev_d" | degrade_evidence)"; then
          degraded_ok="$degraded_ok $ag_d"
          DEGRADED_WHY="$DEGRADED_WHY
$ag_d	$why_d"
          DEGRADED_STATE="$DEGRADED_STATE
$ag_d	$(degrade_boundary_state "$set_id" "$compose_dispatch" "$ag_d" "$ev_d")"
        else
          degrade_bad="$degrade_bad
compose: '$ag_d' has no recorded evidence it could not review in THIS attempt (${why_d:-its events could not be read}, under dispatch $compose_dispatch) — it may still answer, so it is not droppable"
        fi
      done
    fi
    # Every missing leg must be covered, or this is still a partial panel wearing a flag.
    local uncovered=""
    for p_d in $(printf '%s' "$pending" | tr -s ' '); do
      case " $degraded_ok " in *" $p_d "*) ;; *) uncovered="$uncovered $p_d" ;; esac
    done
    if [ -n "$degrade" ] && [ -z "$degrade_bad" ] && [ -z "$uncovered" ] && [ "$n_answered" -eq 0 ]; then
      echo "compose: --degrade would drop EVERY leg, leaving no reviewer at all — that is not a degraded panel, it is an unreviewed change"
      cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" --status partial \
        --note "degrade would empty the roster; 0 of $n_legs legs answered" \
        || echo "warning: coordinator log not updated (composition-refused)" >&2
      return 3
    fi
    if [ -n "$degrade" ] && [ -z "$degrade_bad" ] && [ -z "$uncovered" ]; then
      for ag_d in $degraded_ok; do
        why_d="$(degrade_why "$ag_d")"
        cmd_events append --kind leg-unavailable --set "$set_id" --dispatch "$compose_dispatch" \
          --agent "$ag_d" --role gating --status unavailable \
          --note "reason=$why_d: $(degrade_reason_text "$why_d"); roster reduced by explicit operator decision before composing" \
          || echo "warning: coordinator log not updated (leg-unavailable for $ag_d)" >&2
      done
      DEGRADED_AGENTS="$degraded_ok"
    else
      [ -n "$degrade_bad" ] && printf '%s\n' "$degrade_bad"
      echo "compose: INCOMPLETE — no reply yet from:$pending ($n_answered of $n_legs legs answered)"
      if [ -n "$degrade" ] && [ -n "$uncovered" ]; then
        echo "compose: --degrade did not name every missing leg; still missing:$uncovered"
      elif [ -z "$degrade" ]; then
        echo "compose: refusing to gate on a partial panel; re-run when the set is complete"
        echo "compose: if a reviewer cannot answer at all, an operator may drop it explicitly with --degrade <agent>"
      fi
      cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" --status partial \
        --note "$n_answered of $n_legs legs answered; no reply yet from:$pending" \
        || echo "warning: coordinator log not updated (composition-refused)" >&2
      return 3
    fi
  fi

  # TWO ANSWERS FROM ONE PROVIDER ARE NOT TWO REVIEWERS. Dispatch refuses a same-provider roster,
  # but only for the roster it was handed: concurrent attempts, carried-forward legs and a
  # remapped review identity can all put two replies from one model into what is counted here.
  # So the evidence is the counted replies themselves (reply_provider: a driver is its own
  # provider, a review identity's is its broker's stamp) — never the registry as it reads now.
  local dup_prov
  dup_prov="$(printf '%s\n' "$leg_providers" | awk -F'\t' 'NF == 2 && $2 != "" {
      if ($2 in first) { printf "%s and %s both answered on provider %s\n", first[$2], $1, $2 } else first[$2] = $1 }')"
  if [ -n "$dup_prov" ]; then
    printf '%s\n' "$dup_prov" | sed 's/^/compose: /'
    echo "compose: refusing to count one model's agreement with itself as corroboration — re-dispatch with one reviewer per provider"
    cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" --status duplicate-provider \
      --note "$(printf '%s' "$dup_prov" | tr '\n' ' ')" \
      || echo "warning: coordinator log not updated (composition-refused)" >&2
    return 3
  fi

  # A leg whose zero-blocking count is a FAILED READ is not an answer either, for the same
  # reason a missing leg is not: the panel would report a clean review it never read.
  if [ -n "$blind" ]; then
    printf '%s\n' "${blind# }"
    echo "compose: refusing to gate on a review this parser could not read"
    cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" --status unreadable \
      --note "$(printf '%s' "${blind# }" | tr '\n' ' ')" \
      || echo "warning: coordinator log not updated (composition-refused)" >&2
    # The remedy depends on WHY it could not be read: telling someone whose reply was cut
    # off by a stray fence to use list items sends them at the wrong fix. (grok, panel r5.)
    case "$blind" in
      *"unclosed code fence"*) echo "compose: close the code fence in the named reply, or re-run that leg" ;;
    esac
    case "$blind" in
      *"could not read as findings"*) echo "compose: findings must be markdown list items ('- ', '* ' or '1. ')" ;;
    esac
    return 3
  fi

  # Cluster on the anchor ONLY, and only exact matches. Two findings on one anchor may
  # still assert different things, so every source line is retained and printed.
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/agent-comms-compose.XXXXXX")"
  local compose_buf; compose_buf="$(mktemp "${TMPDIR:-/tmp}/agent-comms-composed.XXXXXX")" \
    || die "compose: cannot buffer the composition — refusing to publish one that was never verified"
  printf '%s\n' "$rows" | awk -F'\t' 'NF>5 && $15 != ""' > "$tmp"
  local total blocking corroborated mixed unique
  total="$(grep -c . "$tmp" || true)"
  blocking="$(awk -F'\t' '$13=="blocking"' "$tmp" | grep -c . || true)"

  # ONE per-anchor classification, computed ONCE and shared by the counts and every renderer.
  # Repeating the distinct-reviewer logic across separate awk expressions is how the bug this
  # fixes survived three reports: the count and the printer must never disagree. (codex, plan r2.)
  #
  # THE BUG: `corroborated` filtered `$13=="blocking"` BEFORE clustering, so a finding one
  # reviewer filed blocking and another filed advisory AT THE SAME ANCHOR contributed a single
  # row and never reached m>1. Corroboration across DIFFERENT SEVERITIES was structurally
  # invisible, and no panel in the record ever scored a corroborated blocker. Filed 2026-08-27,
  # recurred 2026-09-03 (client-app), confirmed here.
  #
  # `$14!=""` is kept on BOTH passes. Without it every unanchored finding groups under the empty
  # key, so two reviewers with UNRELATED prose blockers would falsely corroborate — fixing a
  # false negative by shipping a false positive. (grok, plan r3, blocking.)
  local cls; cls="$(mktemp "${TMPDIR:-/tmp}/agent-comms-cls.XXXXXX")" \
    || die "compose: cannot classify findings — refusing to publish a composition that was never verified"
  # THE ANCHOR IS NEVER RECOVERED BY SPLITTING A COMPOSITE KEY. `anchor SUBSEP reviewer`
  # is written only to de-duplicate one reviewer's repeated findings; the per-anchor tallies
  # are incremented at read time under the ORIGINAL `$14`. An earlier revision recovered the
  # anchor with `split(k,parts,SUBSEP)`, which silently truncated any anchor CONTAINING the
  # SUBSEP byte (0x1c) — `findings_extract` strips tabs but permits it inside a backticked
  # anchor. `$cls` then held the truncated anchor while every renderer looked up the full
  # one, so the row matched no class, was anchored so it missed the unanchored sections, and
  # vanished from the output entirely. A DROPPED FINDING, which is the one thing composition
  # promises never to do. (codex, implement r1, blocking.)
  awk -F'\t' '
    $14!="" {
      anchors[$14]=1
      if (!(($14 SUBSEP $9) in seen)) { seen[$14 SUBSEP $9]=1; nrev[$14]++ }
      if ($13=="blocking" && !(($14 SUBSEP $9) in blk)) { blk[$14 SUBSEP $9]=1; nblk[$14]++ }
    }
    END{
      for (anc in anchors){
        if (nblk[anc] > 1)                       print anc "\tgates"
        else if (nrev[anc] > 1 && nblk[anc] > 0) print anc "\tmixed"
        else if (nblk[anc] > 0)                  print anc "\tuncorroborated"
        else                                     print anc "\tadvisory"
      }
    }' "$tmp" > "$cls"
  corroborated="$(awk -F'\t' '$2=="gates"' "$cls" | grep -c . || true)"
  mixed="$(awk -F'\t' '$2=="mixed"' "$cls" | grep -c . || true)"
  unique=$(( ${blocking:-0} - 0 ))

  # THE GATE, from the SAME classification every section below is rendered from. Blocking
  # findings split three ways, one count each:
  #   corroborated — anchors classed `gates` (each anchor once, whoever filed it)
  #   gating_own   — the gating reviewer's blocking findings that are not at such an anchor
  #   lone         — every other reviewer's blocking findings not at such an anchor
  # Anchored findings count once per reviewer and anchor, as the classifier does; unanchored
  # ones count per finding, because nothing can say two of them are the same defect.
  local gate_counts gc_corr gc_own gc_lone gating_verdict="" maxr=""
  gate_counts="$(awk -F'\t' -v g="$gating_ag" -v clsf="$cls" '
    BEGIN { while ((getline line < clsf) > 0) { split(line, c, "\t"); klass[c[1]] = c[2] } }
    $13 != "blocking" { next }
    $14 != "" && klass[$14] == "gates" { if (!($14 in cg)) { cg[$14] = 1; corr++ }; next }
    $14 != "" { if (($14 SUBSEP $9) in seen) next; seen[$14 SUBSEP $9] = 1 }
    $9 == g { own++; next }
    { lone++ }
    END { printf "%d %d %d", corr, own, lone }' "$tmp")"
  read -r gc_corr gc_own gc_lone <<< "$gate_counts"
  [ -z "$gating_reply" ] || gating_verdict="$(norm_verdict_value "$(frontmatter_field "$gating_reply" verdict 2>/dev/null)")" || gating_verdict=""
  # The round cap comes from the REQUEST the driver wrote (the gating leg's), and only when
  # that is gone from the reply the broker stamped from it. Every read is GUARDED: a request
  # found by name but unreadable, or archived between the lookup and the read, falls through to
  # the next source and finally to `-` — it never aborts a composition. (codex, r2, blocking.)
  local gating_req_file; gating_req_file="$(find_message_by_id "$gating_req" 2>/dev/null)" || gating_req_file=""
  [ -z "$gating_req_file" ] || maxr="$(frontmatter_field "$gating_req_file" max-rounds 2>/dev/null)" || maxr=""
  [ -n "$maxr" ] || [ -z "$gating_reply" ] || maxr="$(frontmatter_field "$gating_reply" max-rounds 2>/dev/null)" || maxr=""
  local compose_gate_out; compose_gate_out="$(compose_gate "${gc_corr:-0}" "${gc_own:-0}" "${gc_lone:-0}" \
    "$gating_ag" "$gating_verdict" "$DEGRADED_AGENTS" "$gating_rnd" "$maxr")"
  local gate="${compose_gate_out%% *}" gate_reasons="${compose_gate_out#* }"

  # <section> — every row for the anchors in that class, with reviewer AND severity, so a gated
  # anchor's advisory dissent prints INSIDE its own section and nowhere else. One section per
  # anchor. (codex + grok, plan r3, blocking: the earlier spec contradicted itself here.)
  _compose_rows() {
    awk -F'\t' -v want="$1" -v clsf="$cls" '
      BEGIN{ while ((getline line < clsf) > 0){ split(line,c,"\t"); klass[c[1]]=c[2] } }
      $14!="" && klass[$14]==want { k[$14]=k[$14] "\n- [" $9 "] (" $13 ") " $15 }
      END{ for (a in k) printf "### %s%s\n\n", a, k[a] }' "$tmp"
  }

  {
    printf '# Panel composition — review set %s\n\n' "$set_id"
    if [ -n "$DEGRADED_AGENTS" ]; then
      # Say it FIRST and say who. A degraded approval quoted later as "the panel approved"
      # is exactly the drift the archive exists to prevent.
      printf 'DEGRADED PANEL — composed WITHOUT:%s (dropped by explicit operator decision).\n' "$DEGRADED_AGENTS"
      local dg_ag dg_why
      for dg_ag in $DEGRADED_AGENTS; do
        dg_why="$(degrade_why "$dg_ag")"
        printf -- '- %s: %s (reason=%s).\n' "$dg_ag" "$(degrade_reason_text "$dg_why")" "$dg_why"
      done
      printf 'Reviewers present:%s. Read every verdict below as theirs alone, not the panel'"'"'s.\n' \
        "$answered_agents"
    fi
    # The undegraded line is unchanged, deliberately: it is the common case and other
    # readers already match on it. Only a degraded panel gets different words, because only
    # a degraded panel means something different.
    if [ -n "$DEGRADED_AGENTS" ]; then
      printf '%s of %s legs answered, the rest dropped. %s findings (%s blocking).\n' \
        "$n_answered" "$n_legs" "${total:-0}" "${blocking:-0}"
    else
      printf '%s legs, all answered. %s findings (%s blocking).\n' "$n_legs" "${total:-0}" "${blocking:-0}"
    fi
    # Printed WITH the counts, not above them: the warning qualifies these numbers, and a
    # reader who takes the count without the caveat is the failure being prevented.
    [ -n "$unread" ] && printf '%s\n' "${unread# }"
    printf 'Anchored blocking findings supported by MORE THAN ONE reviewer: %s\n' "${corroborated:-0}"
    printf 'Anchors flagged by 2+ reviewers with differing severity: %s\n' "${mixed:-0}"
    # The sections below classify by SUPPORT; the gate also counts the gating reviewer's own
    # blockers wherever they are listed, so say so beside the decision. (grok, r1 advisory.)
    printf 'Gate: %s (%s). A blocking finding by the gating reviewer (%s) gates wherever it is listed below.\n\n' \
      "$gate" "$gate_reasons" "${gating_ag:-unknown}"
    printf '## Gates (corroborated — an anchor two reviewers independently flagged)\n\n'
    _compose_rows gates
    # Deliberately contains neither "Gates" nor "corroborated": those words mean GATING
    # everywhere else in this output, and this class does not gate. It sits ABOVE
    # Uncorroborated because it is stronger evidence, not weaker. (grok, plan r2.)
    printf '## Flagged by more than one reviewer at different severities (does not gate)\n\n'
    _compose_rows mixed
    printf '## Uncorroborated blocking findings (cross-check before spending a round)\n\n'
    _compose_rows uncorroborated
    printf '## Unanchored blocking findings (no anchor — cannot be clustered)\n\n'
    awk -F'\t' '$13=="blocking" && $14==""{printf "- [%s] %s\n", $9, $15}' "$tmp"
    printf '\n## Advisory (never gates)\n\n'
    awk -F'\t' -v clsf="$cls" '
      BEGIN{ while ((getline line < clsf) > 0){ split(line,c,"\t"); klass[c[1]]=c[2] } }
      $13=="advisory" && ($14=="" || klass[$14]=="advisory") {
        printf "- [%s] %s%s\n", $9, ($14!="" ? "`" $14 "` — " : ""), $15 }' "$tmp"
  } | inert_lines | {
    # No /dev/stdout reopen: managed sandboxes deny it, failing ordinary
    # composition even with every leg answered. Plain cat IS stdout; a file
    # target gets a real redirect. (codex, stamped-authorities round 3 —
    # pre-existing, advisory.)
    # BUFFERED, never published yet. The supersession check below runs after the composition
    # is built, so writing it here put an authoritative-looking "all answered" document on
    # stdout — and permanently into --out — before anything had verified the attempt was
    # still current. The guard existed and protected nothing observable.
    # (codex, implement r8, blocking.)
    cat > "$compose_buf"
  }
  rm -f "$tmp" "$cls"
  # Composition is the last coordinator act of a round, so it closes the trace the roster
  # event opened: a set with a panel-planned and no composition-* is a round nobody gated.
  # A newer attempt may have landed while this composition was being built. Recording a
  # completion for a superseded attempt would gate a panel that no longer exists.
  # (codex, implement r7, blocking.)
  local recheck_snap recheck_rc recheck_disp
  # Nothing below may publish until the recheck passes.
  recheck_snap="$(set_plan_snapshot "$set_id")" && recheck_rc=0 || recheck_rc=$?
  recheck_disp=""
  [ "$recheck_rc" = 0 ] && recheck_disp="$(snap_field "$recheck_snap" dispatch | tr -d ' ')"
  # A plan that has VANISHED since the first read is not "no plan" — it is a plan this
  # process can no longer verify, and exempting it let a composition complete over it.
  # Once an attempt was bound, only the SAME attempt still being current may publish.
  local recheck_bad=0
  if [ "$compose_rc" = 0 ]; then
    [ "$recheck_rc" = 0 ] && [ "$recheck_disp" = "$compose_dispatch" ] || recheck_bad=1
  else
    [ "$recheck_rc" = 3 ] || recheck_bad=1
  fi
  # THE DEGRADATION RE-CHECK BELONGS HERE, beside the dispatch one and AFTER the buffer is
  # built. Checking it at the top of the producer left the whole rendering pass — and the plan
  # re-read below — outside the window, so a re-send starting during either was still invisible.
  # (codex, implement r4, blocking.) A residual check-to-write race remains and cannot be
  # closed without locking; it is documented rather than chased.
  if [ "$recheck_bad" = 0 ] && [ -n "$DEGRADED_STATE" ]; then
    local dst_ag dst_want dst_now
    while IFS="$(printf '\t')" read -r dst_ag dst_want; do
      [ -n "$dst_ag" ] || continue
      dst_now="$(degrade_boundary_state "$set_id" "$compose_dispatch" "$dst_ag")"
      [ "$dst_now" = "$dst_want" ] && continue
      echo "compose: '$dst_ag' changed while this composition was being built — refusing to publish a panel that drops a leg whose turn history moved"
      cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" \
        --status superseded --note "degrade superseded: $dst_ag turn history moved during composition" \
        || echo "warning: coordinator log not updated (composition-refused)" >&2
      rm -f "$compose_buf" 2>/dev/null || true
      return 3
    done <<< "$DEGRADED_STATE"
  fi
  if [ "$recheck_bad" = 1 ]; then
    echo "compose: the attempt this composition was built from (${compose_dispatch:-legacy}) is no longer the current one (${recheck_disp:-unreadable}) — refusing to publish or record it"
    cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" \
      --status superseded --note "bound=${compose_dispatch:-legacy} current=${recheck_disp:-unreadable}" \
      || echo "warning: coordinator log not updated (composition-refused)" >&2
    rm -f "$compose_buf" 2>/dev/null || true
    return 3
  fi
  # Still current: publish, THEN record.
  if [ -n "$out" ]; then cat "$compose_buf" > "$out"; else cat "$compose_buf"; fi
  rm -f "$compose_buf" 2>/dev/null || true
  cmd_events append --kind composition-completed --set "$set_id" --dispatch "$compose_dispatch" \
    --status "$([ -n "$DEGRADED_AGENTS" ] && echo composed-degraded || echo composed)" \
    --note "legs=$n_legs findings=${total:-0} blocking=${blocking:-0} corroborated=${corroborated:-0} mixed=${mixed:-0}${DEGRADED_AGENTS:+ degraded-without:$DEGRADED_AGENTS} gate=$gate reason=$gate_reasons" \
    || echo "warning: coordinator log not updated (composition-completed)" >&2
  [ -z "$out" ] || printf 'compose: wrote %s\n' "$(integrate_oneline "${out#"$root"/}")"
  # THE MACHINE-READABLE RESULT: exactly one line, always the LAST line of stdout, printed only
  # once the composition is published. Every refusal above returns before it, so its absence
  # is itself the answer "nothing was gated". Defined in docs/COMMANDS.md.
  local dg_list; dg_list="$(printf '%s' "$DEGRADED_AGENTS" | tr -s ' ' | sed 's/^ //; s/ $//' | tr ' ' ',')"
  printf 'compose-result v1 gate=%s set=%s dispatch=%s round=%s max_rounds=%s legs=%s answered=%s gating=%s gating_verdict=%s blocking=%s corroborated=%s gating_own=%s lone=%s degraded=%s reason=%s\n' \
    "$gate" "$(integrate_kv "$set_id")" "$(integrate_kv "${compose_dispatch:--}")" \
    "$(integrate_kv "${gating_rnd:--}")" "$(integrate_kv "${maxr:--}")" "$n_legs" "$n_answered" \
    "$(integrate_kv "${gating_ag:--}")" "$(integrate_kv "${gating_verdict:--}")" "${blocking:-0}" \
    "${gc_corr:-0}" "${gc_own:-0}" "${gc_lone:-0}" "$(integrate_kv "${dg_list:--}")" "$gate_reasons"
}

# compose_gate <corroborated> <gating_own> <lone> <gating-agent> <gating-verdict> <degraded agents>
#              <round> <max-rounds>  ->  "<gate> <reason[,reason...]>"
#
# THE ONE DEFINITION of what a composition means for the driver, kept apart from rendering so
# the rule reads in one place (docs/COMMANDS.md, "compose result line", is its contract):
#   block    — a GATING blocker stands: a corroborated anchor, or the gating reviewer's own.
#   escalate — a split the driver may not settle alone: a lone blocker from another reviewer,
#              a degraded panel, a gating reviewer that was dropped or did not APPROVE, or any
#              non-pass outcome at the round cap (a block there has no round left to fix it in).
#   pass     — every leg answered, the gating reviewer approved, and no blocker of any kind.
# Reasons are every condition that held, in a fixed order, so a caller never has to re-derive
# them from counts. A pass carries exactly `approved`.
compose_gate() {
  local corr="$1" own="$2" lone="$3" g="$4" gv="$5" dg="$6" rnd="$7" maxr="$8" reasons="" gate at_cap=0 absent=0
  case " $dg " in *" $g "*) absent=1 ;; esac
  case "$rnd" in ''|*[!0-9]*) ;; *)
    case "$maxr" in ''|*[!0-9]*) ;; *) [ "$((10#$maxr))" -gt 0 ] && [ "$((10#$rnd))" -ge "$((10#$maxr))" ] && at_cap=1 ;; esac ;;
  esac
  [ "$corr" -gt 0 ] && reasons="$reasons,corroborated-blocker"
  [ "$own" -gt 0 ] && reasons="$reasons,gating-blocker"
  [ "$lone" -gt 0 ] && reasons="$reasons,lone-blocker"
  [ -n "$(printf '%s' "$dg" | tr -d ' ')" ] && reasons="$reasons,degraded"
  if [ "$absent" = 1 ]; then reasons="$reasons,gating-absent"
  elif [ "$gv" != "APPROVE" ]; then reasons="$reasons,gating-not-approved"
  fi
  if [ $((corr + own)) -gt 0 ]; then gate=block
  elif [ -n "$reasons" ]; then gate=escalate
  else gate=pass
  fi
  if [ "$gate" != pass ] && [ "$at_cap" = 1 ]; then gate=escalate; reasons="$reasons,max-rounds"; fi
  [ "$gate" = pass ] && reasons=",approved"
  printf '%s %s' "$gate" "${reasons#,}"
}

# ---------- the coordinator's event log ----------
#
# Contraction step 3, criterion 1: a DURABLE COORDINATOR LOG — append-only events owned by
# this process. Not the model mailbox (that is the wire the thing under review writes on),
# not ACP (a session is not a record), not `result.json` (per-run, and findable only if you
# already know the run dir it lives in).
#
# What existed before this was four stores, none of them a history: `grades/sets.tsv`
# records `dispatched` and is never updated again, `.comms/state/` is last-write-wins, and
# a broker REFUSAL ("refusing to stamp a verdict derived from an unread body") lived only
# in a run dir's runner.log. A driver that died between the ACP turn exiting and `compose`
# had no durable answer to "what happened to leg X". This is that answer.
#
# ONE writer, so no producer invents its own row shape, and ONE reader, so recovery never
# means joining four stores by hand.
#
# NOT AUTHORITATIVE YET, and this is deliberate: a mounted review child reaches the real
# `.comms` through this same helper, so it can forge events until step 3's criterion 2
# gives reviewer turns an enforced boundary. Same honesty as the mount's own "defence in
# depth, not containment" note — read this log as the coordinator's record, not as proof
# against a hostile child. (codex, plan r1, advisory.)
# 1024 is not a round number here: stdio's buffer on macOS is 1024 bytes, so a single
# `printf` longer than that is flushed as MORE THAN ONE write(2) — and two writes are two
# chances for a concurrent appender to land between them. Keeping every row under the
# buffer is what makes "one row, one write" true rather than hopeful.
EVENT_ROW_MAX=1024
# PER-COLUMN budgets that SUM (with their 14 delimiters) to less than the row cap, so the
# cap is a property of the columns rather than a trim applied to the finished row. Trimming
# the row would cut trailing delimiters off and break the fixed-column contract every
# reader depends on. (codex, plan r1, advisory.)
EVENT_W_WS=48; EVENT_W_SET=80; EVENT_W_DISPATCH=40; EVENT_W_THREAD=80; EVENT_W_ROUND=8
EVENT_W_AGENT=24; EVENT_W_ARTIFACT=44; EVENT_W_REQID=72; EVENT_W_MID=72; EVENT_W_RUNDIR=160
EVENT_W_STATUS=32
# A CLOSED vocabulary. An open one lets a typo mint a kind no reader ever selects for,
# which is a hole that reads exactly like a turn that never happened.
EVENT_KINDS=" panel-planned request-persisted request-dispatched message-dispatched turn-started provider-result turn-finished reply-validated reply-refused reply-accepted leg-unavailable composition-completed composition-refused "
EVENT_ROLES=" gating shadow "
EVENTS_HEADER="ts	workspace	event	review_set	dispatch	thread	round	agent	role	artifact_id	request_id	message_id	run_dir	status	note"

events_file() { printf '%s/events.tsv\n' "$(cmd_root)"; }

# ONE definition of "this row is a well-formed event", as an awk function every consumer
# concatenates into its own program. The reader had it inline and the runner's acceptance
# lookup had its own raw-TSV match — two rules for one question, so a partial append that
# reached field 12 satisfied the lookup while the reader rejected the same row.
# (codex, implement r4, blocking.)
EVENTS_AWK_LIB='function ev_wellformed() { return ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ && NF == ev_ncols && index(ev_kinds, " " $3 " ") > 0 && index(ev_roles, " " $9 " ") > 0) }'

# event_identity <value> <max-bytes> — the value as it is STORED, and as it must be QUERIED.
#
# Identity columns are exact-match join keys, and a plain clip breaks the join silently: a
# set id longer than its column dispatches fine and then can never find its own plan row, so
# status and compose refuse forever. An over-long value keeps a readable head plus a digest
# of the whole, which is stable and collision-resistant — and because writer and reader both
# call this, still an exact match. (codex, implement r4, blocking.)
event_identity() {
  local v="$1" max="${2:-48}" h
  local LC_ALL=C
  v="$(printf '%s' "$v" | tr '\t\n\r' '   ')"
  if [ "${#v}" -le "$max" ]; then printf '%s' "$v"; return 0; fi
  h="$(printf '%s' "$v" | hash_stdin | cut -c1-12)"
  printf '%s~%s' "$(printf '%s' "$v" | cut -b1-$(( max - 13 )))" "$h"
}

event_field() {  # event_field <value> <max-bytes> — never a delimiter, never a line break
  local v; v="$(printf '%s' "${1:-}" | tr '\t\n\r' '   ')"
  clip "$v" "${2:-48}"
}

# fs_events_device <path> — what the filesystem calls itself, or empty.
fs_events_device() { df -P "$1" 2>/dev/null | awk 'NR==2{print $1}'; }
# fs_events_mountpoint <path> — where it is mounted, or empty.
# Fields 6..NF, not $NF: `df -P` puts the mount point last and it may contain spaces, which
# would otherwise truncate to the final word. (grok, implement r3.)
fs_events_mountpoint() {
  df -P "$1" 2>/dev/null | awk 'NR==2{ for (i=6; i<=NF; i++) printf "%s%s", $i, (i<NF ? " " : "") }'
}

# The filesystem types on which a small O_APPEND write is one atomic write. An ALLOWLIST,
# because the shape blacklist it replaces was blind to every network FUSE mount — `s3fs`,
# `gcsfuse`, a rclone `remote:bucket` — which look nothing like `host:/export` and are
# exactly as unsafe. Anything not named here fails CLOSED. (codex, implement r2, blocking.)
# msdos/vfat/exfat are deliberately ABSENT: the header is created exactly once with a hard
# link, which those filesystems do not support, so a log there could never be initialised.
# (codex, implement r3, advisory.)
EVENT_LOCAL_FSTYPES=" apfs hfs hfsplus ext2 ext2/ext3 ext3 ext4 xfs btrfs zfs tmpfs ramfs overlay overlayfs f2fs jfs reiserfs ufs "

# fs_events_type <path> — a lowercase filesystem-type token, or empty when nothing answers.
fs_events_type() {
  local t mp
  # GNU coreutils answers directly. BSD `stat` reads -f as its FORMAT flag and cheerfully
  # echoes the string "-c" back, so the answer is only believed when it looks like a
  # filesystem type — which "-c" does not. Without that guard this probe classified every
  # macOS disk as unknown and refused a perfectly local log.
  t="$(stat -f -c %T "$1" 2>/dev/null || true)"
  case "$t" in
    [A-Za-z]*) printf '%s\n' "$t" | tr 'A-Z' 'a-z'; return 0 ;;
  esac
  # BSD/macOS `stat` has no -c, so read the mount table instead: `/dev/disk3s1 on / (apfs,
  # local, journaled)`. The type is the first token in the parentheses.
  mp="$(fs_events_mountpoint "$1")"
  [ -n "$mp" ] || return 0
  mount 2>/dev/null | awk -v m=" on $mp " 'index($0, m) {print; exit}' \
    | sed -n 's/.*(\([A-Za-z0-9_]*\).*/\1/p' | tr 'A-Z' 'a-z'
}

# fs_events_safe <dir> — 0 only on a filesystem where an append-only log is sound.
#
# The atomicity this log relies on (one small `printf` is one flushed write at the append
# offset) holds on local filesystems. NFS SIMULATES O_APPEND and documents corruption under
# concurrent appenders — and its failure mode is worse than a torn row, because a lost
# append leaves a perfectly well-formed file with an event missing, which no reader can
# detect. So this REFUSES rather than warning: a diagnostic after accepting the risk is not
# an enforced constraint, and an unclassifiable filesystem fails closed like every other
# unverifiable check in this tool. (codex, plan r2, blocking.)
fs_events_safe() {
  local dev; dev="$(fs_events_device "$1")"
  [ -n "$dev" ] || return 1                    # unclassifiable is not "probably fine"
  # Shape first, because it costs nothing and names the obvious remotes: //server/share
  # (SMB), host:/export (NFS), remote:bucket (rclone and friends).
  case "$dev" in //*|*:*) return 1 ;; esac
  local t; t="$(fs_events_type "$1")"
  [ -n "$t" ] || return 1                      # nothing could answer: fail closed
  case "$EVENT_LOCAL_FSTYPES" in *" $t "*) return 0 ;; esac
  return 1
}

cmd_events() {
  # events append --kind K [...]                                    — the single writer
  # events [--set S] [--dispatch D] [--thread T] [--kind K] [--agent A] [--limit N] — reader
  local sub="list"
  case "${1:-}" in
    append) sub=append; shift ;;
    list)   shift ;;
    ""|-*)  ;;
    *)      usage_err "events: unknown argument '$(clip "${1:-}")' (append|list)" ;;
  esac

  local kind="" set_id="" dispatch="" thread="" round="" agent="" role="" artifact="" \
        reqid="" mid="" run_dir="" status="" note="" limit=50
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)       need_value "events $sub" $# "$1"; shift; kind="$1" ;;
      --set)        need_value "events $sub" $# "$1"; shift; set_id="$1" ;;
      --dispatch)   need_value "events $sub" $# "$1"; shift; dispatch="$1" ;;
      --thread)     need_value "events $sub" $# "$1"; shift; thread="$1" ;;
      --round)      need_value "events $sub" $# "$1"; shift; round="$1" ;;
      --agent)      need_value "events $sub" $# "$1"; shift; agent="$1" ;;
      --role)       need_value "events $sub" $# "$1"; shift; role="$1" ;;
      --artifact)   need_value "events $sub" $# "$1"; shift; artifact="$1" ;;
      --request-id) need_value "events $sub" $# "$1"; shift; reqid="$1" ;;
      --message-id) need_value "events $sub" $# "$1"; shift; mid="$1" ;;
      --run-dir)    need_value "events $sub" $# "$1"; shift; run_dir="$1" ;;
      --status)     need_value "events $sub" $# "$1"; shift; status="$1" ;;
      --note)       need_value "events $sub" $# "$1"; shift; note="$1" ;;
      --limit)      need_value "events $sub" $# "$1"; shift; limit="$1" ;;
      --all)        limit=0 ;;
      -?*)          usage_err "events: unknown option '$(clip "$1")'" ;;
      *)            usage_err "events: unexpected argument '$(clip "$1")'" ;;
    esac
    shift
  done

  local f; f="$(events_file)"

  if [ "$sub" = list ]; then
    case "$limit" in ''|*[!0-9]*) usage_err "events: --limit must be a positive integer" ;; esac
    # `--all` (limit 0) is for CORRECTNESS reads. A cap on a roster read silently shrinks the
    # union it is enumerating — a big panel or a long retry history would drop members and
    # false-complete — and dispatch enforces no matching maximum. (codex, implement r6.)
    [ "$limit" -gt 0 ] || [ "$limit" = 0 ] || usage_err "events: --limit must be a positive integer"
    [ -f "$f" ] || { emit_diagnostic "events: no coordinator log yet ($f)"; return 0; }
    # ONE pass, ONE predicate. What the reader prints and what it refuses are decided in
    # the same place, so they cannot drift: a row that is not a well-formed event — a torn
    # write, a hand-edit, a second header — is counted and NAMED rather than parsed into an
    # event nobody wrote. There is no lock (a dead holder is a deadlock the presence work
    # already taught us), so detection is the guarantee. Filtering happens BEFORE the cap,
    # or a global tail would answer a --set question with other sets' rows. (grok, plan r1.)
    # No /dev/null fallback: if the channel that reports skipped rows cannot be created, the
    # evidence of a torn log silently vanishes and every consumer then trusts a file nothing
    # validated. Refuse instead. (codex, implement r4, blocking.)
    # RETURN trap, so a reader killed by SIGPIPE mid-write (`events | head -1`) still removes
    # its scratch file instead of leaving one per invocation. (self-review, round 6.)
    local tornf; tornf="$(mktemp "${TMPDIR:-/tmp}/agent-comms-events.XXXXXX" 2>/dev/null || true)"
    trap '[ -z "${tornf:-}" ] || rm -f "$tornf" 2>/dev/null' RETURN
    if [ -z "$tornf" ]; then
      emit_diagnostic "events: cannot create a temporary file to record skipped rows — refusing to read a log whose malformed rows could not be counted"
      return 1
    fi
    # Identity filters go through the SAME transform the writer used, or a value long enough
    # to be reshaped on the way in could never match itself on the way out. One transform,
    # both directions. (codex, implement r4, blocking.)
    # Query values travel through the ENVIRONMENT, not `-v`: awk unescapes `\t`, `\n` and
    # friends in a -v assignment, so a thread or id containing a literal backslash was
    # transformed on the way in and could never match the row that stores it verbatim.
    # (self-review, round 6.)
    EV_Q_SET="$(event_identity "$set_id" "$EVENT_W_SET")" \
    EV_Q_DISPATCH="$(event_identity "$dispatch" "$EVENT_W_DISPATCH")" \
    EV_Q_THREAD="$(event_identity "$thread" "$EVENT_W_THREAD")" \
    EV_Q_MID="$(event_identity "$mid" "$EVENT_W_MID")" \
    EV_Q_REQ="$(event_identity "$reqid" "$EVENT_W_REQID")" \
    EV_Q_KIND="$kind" EV_Q_AGENT="$agent" EV_Q_ROLE="$role" \
    awk -F'\t' \
        -v hdr="$EVENTS_HEADER" -v ev_kinds="$EVENT_KINDS" -v ev_roles="$EVENT_ROLES" \
        -v tornf="$tornf" -v lim="$limit" "$EVENTS_AWK_LIB"'
      # The header is printed HERE, by the same process as the rows. Emitted from the shell
      # it sat in the stdio buffer bash uses whenever stdout is a pipe, so a piped read
      # (events --set X | head) could see the rows arrive first, or lose the header
      # entirely to SIGPIPE. One writer, one stream, one order. Found by the suite.
      BEGIN {
        print hdr; ev_ncols = split(hdr, H, "\t")
        s = ENVIRON["EV_Q_SET"]; d = ENVIRON["EV_Q_DISPATCH"]; t = ENVIRON["EV_Q_THREAD"]
        m = ENVIRON["EV_Q_MID"]; q = ENVIRON["EV_Q_REQ"]
        k = ENVIRON["EV_Q_KIND"]; a = ENVIRON["EV_Q_AGENT"]; r = ENVIRON["EV_Q_ROLE"]
      }
      # EXACT match. Skipping anything whose first field is "ts" would drop a real row that
      # merely began with that token, and would swallow a foreign header from an older
      # schema instead of naming it. Anything else header-shaped falls through to the
      # malformed count, where it is reported. (codex, implement r1, blocking.)
      $0 == hdr { next }
      # Whole-field checks against every closed vocabulary. ev_wellformed() is the single
      # definition, shared with the acceptance lookup in the runner.
      !ev_wellformed() { if (NF) torn++; next }
      # The cap applies to the ROWS, never to the header, so it is a bounded ring buffer
      # here rather than a `tail` on the whole stream.
      (s == "" || $4 == s) && (d == "" || $5 == d) && (t == "" || $6 == t) \
        && (k == "" || $3 == k) && (a == "" || $8 == a) && (r == "" || $9 == r) \
        && (m == "" || $12 == m) && (q == "" || $11 == q) {
        buf[++n] = $0
        if (lim > 0 && n > lim) delete buf[n - lim]
      }
      END {
        start = ((lim > 0 && n > lim) ? n - lim + 1 : 1)
        for (i = start; i <= n; i++) print buf[i]
        if (torn) print torn > tornf
      }
    ' "$f"
    local torn; torn="$(cat "$tornf" 2>/dev/null || true)"
    rm -f "$tornf" 2>/dev/null || true
    [ -z "$torn" ] || emit_diagnostic "events: skipped ${torn} malformed row(s) — the log holds a torn or hand-edited line; inspect $f"
    return 0
  fi

  # ---- append ----
  [ -n "$kind" ] || usage_err "events append: --kind is required"
  case "$EVENT_KINDS" in
    *" $kind "*) ;;
    *) usage_err "events append: unknown kind '$(clip "$kind")' — the vocabulary is:$EVENT_KINDS" ;;
  esac
  [ -n "$role" ] || role=gating
  case "$EVENT_ROLES" in
    *" $role "*) ;;
    *) usage_err "events append: unknown role '$(clip "$role")' —$EVENT_ROLES" ;;
  esac
  local dir; dir="$(dirname "$f")"
  # RETURN, not die — the same reason the filesystem refusal returns. A `die` here exits the
  # whole process, so a post-delivery `reply-accepted` append would kill the `send` that just
  # delivered the reply, skip the inbound archive, and make the broker report a delivered
  # reply as failed. (codex, implement r3, blocking.)
  if ! mkdir -p "$dir" 2>/dev/null; then
    emit_diagnostic "events: cannot create $(clip "$dir") — the coordinator log was not written"
    return 1
  fi
  # EVERY append, not just the first. Checking only at creation left the refusal trivially
  # bypassable: a `.comms` that migrates onto a network mount — or an events.tsv copied
  # there — appends unchecked for the rest of its life, which is the silent-loss mode this
  # refusal exists to prevent. One `df` per event is cheap next to a review turn.
  # (codex + grok, implement r1 — both found it.)
  # RETURN, never `die`. `die` is `exit`, so an unsound filesystem here would take down the
  # whole process — including `cmd_send` delivering a reply, whose `if ! cmd_events` branch
  # would never run. The two fail-closed producers keep their own `|| die`; everything else
  # stays advisory, which is the entire point of the split. (grok, implement r2.)
  local fs_target="$dir"
  [ -e "$f" ] && fs_target="$f"
  if ! fs_events_safe "$fs_target"; then
    emit_diagnostic "events: refusing to write the coordinator log on '$(fs_events_device "$fs_target")' (type '$(fs_events_type "$fs_target")') — an append-only log is only sound on a local filesystem; point .comms at local storage"
    return 1
  fi
  # Create the header exactly ONCE, even with N detached runners appending at once.
  # `[ -s ] || printf > file` lets two first-creators truncate each other and lose a row,
  # and a second header read as a row is the log lying about an event. `ln` is atomic and
  # fails if the name exists, so the loser simply discards its copy. Same filesystem by
  # construction (same directory). (grok, plan r1.)
  if [ ! -f "$f" ]; then
    # The seed lives in the log's OWN directory so `ln` cannot fail with EXDEV. (grok, r2.)
    local seed; seed="$(mktemp "$dir/.events.XXXXXX" 2>/dev/null || true)"
    if [ -n "$seed" ]; then
      # Linked only after the seed is verified to HOLD the header. A partial write or ENOSPC
      # would otherwise link an empty or truncated file as the permanent log, which passes
      # the -f postcondition and then collects rows under a header that is not there.
      # (codex, implement r4, blocking.)
      # Byte count AND content: command substitution strips trailing newlines, so a seed
      # holding the header with no terminating newline compared EQUAL and was linked — the
      # short write this check exists to catch. (grok, implement r5, advisory.)
      local want_bytes; want_bytes="$(printf '%s\n' "$EVENTS_HEADER" | wc -c | tr -d ' ')"
      if printf '%s\n' "$EVENTS_HEADER" > "$seed" 2>/dev/null \
         && [ "$(wc -c < "$seed" 2>/dev/null | tr -d ' ')" = "$want_bytes" ] \
         && [ "$(cat "$seed" 2>/dev/null)" = "$EVENTS_HEADER" ]; then
        ln "$seed" "$f" 2>/dev/null || true
      fi
      rm -f "$seed" 2>/dev/null || true
    fi
    # POSTCONDITION. Without it a failed mktemp or link left the first append to create a
    # HEADERLESS log — which every reader then reports as one malformed row after another.
    # (codex, implement r2, advisory.)
    if [ ! -f "$f" ]; then
      emit_diagnostic "events: could not create the coordinator log with its header at $(clip "$f") — refusing to write a headerless log"
      return 1
    fi
  fi
  local fixed room
  fixed="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(event_field "$(cmd_workspace 2>/dev/null || true)" "$EVENT_W_WS")" \
    "$kind" \
    "$(event_identity "$set_id" "$EVENT_W_SET")" "$(event_identity "$dispatch" "$EVENT_W_DISPATCH")" \
    "$(event_identity "$thread" "$EVENT_W_THREAD")" \
    "$(event_field "$round" "$EVENT_W_ROUND")" "$(event_field "$agent" "$EVENT_W_AGENT")" \
    "$role" \
    "$(event_field "$artifact" "$EVENT_W_ARTIFACT")" "$(event_identity "$reqid" "$EVENT_W_REQID")" \
    "$(event_identity "$mid" "$EVENT_W_MID")" "$(event_identity "$run_dir" "$EVENT_W_RUNDIR")" \
    "$(event_field "$status" "$EVENT_W_STATUS")")"
  # One `printf` of one small row: on a local filesystem that is one flushed write at the
  # append offset, which is what keeps concurrent runners from tearing each other's rows.
  # The note is the only variable-width column, so it takes whatever room is left.
  # Two bytes are reserved, not one: the delimiter before the note AND the newline. The cap
  # is about what reaches write(2), and the newline is part of that — budgeting only the tab
  # let a maximum row reach 1025 bytes, one past the bound the whole argument rests on, and
  # the test that accepted 1025 hid it. (codex, implement r1, blocking.)
  room=$(( EVENT_ROW_MAX - $(byte_len "$fixed") - 2 ))
  [ "$room" -ge 8 ] || room=0
  if [ "$room" -eq 0 ]; then note=""; else note="$(event_field "$note" "$room")"; fi
  printf '%s\t%s\n' "$fixed" "$note" >> "$f"
}

cmd_friction() {
  # friction [--thread T] [--severity 1-5] "<note>" — record harness friction, mid-loop.
  #
  # The `### Process` meta-channel already carries REVIEWER-to-driver friction. This is the
  # other direction and the one that was missing: the DRIVER hitting something wrong with
  # the harness itself. Without a seam that costs one line, friction reaches the owner only
  # if a human happens to write it up afterwards — which is exactly how a false all-clear
  # from a numbered-list parser survived a whole loop before anyone noticed.
  #
  # Deliberately NOT in anything `lessons` feeds to reviewers: this is a report about the
  # tool, not a lesson about the code, and a reviewer reading it would just be noise.
  local note="" thread="" sev=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --thread)   need_value "friction" $# "$1"; shift; thread="$1" ;;
      --severity) need_value "friction" $# "$1"; shift; sev="$1" ;;
      --list)     cmd_friction_list; return 0 ;;
      -?*)        usage_err "friction: unknown option '$(clip "$1")'" ;;
      *)          note="${note:+$note }$1" ;;
    esac
    shift
  done
  [ -n "$note" ] || usage_err "friction: a note is required — what went wrong, in one or two lines"
  case "${sev:-3}" in [1-5]) ;; *) usage_err "friction: --severity must be 1-5 (1 = cosmetic, 5 = wrong results)" ;; esac
  local root; root="$(main_repo_root)"; [ -n "$root" ] || usage_err "friction: not inside a git repository"
  # Written TWICE, on purpose. The project log keeps it next to the work; the GLOBAL
  # rollup is the only path back to whoever maintains this tool — `.comms/` is gitignored,
  # so a note recorded in a client repo is invisible everywhere else and reaches the
  # maintainer only if a human happens to paste it. That is exactly how a false all-clear
  # survived a whole loop.
  local hdr row
  hdr="$(printf 'timestamp\tproject\tworkspace\tthread\tseverity\thead_sha\tnote')"
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$root")" "$(cmd_workspace)" "${thread:-}" \
    "${sev:-3}" "$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)" \
    "$(printf '%s' "$note" | tr '\t\n' '  ')")"
  local out="$root/.comms/friction.tsv"
  mkdir -p "$(dirname "$out")" 2>/dev/null || die "friction: cannot create $(dirname "$out")"
  [ -s "$out" ] || printf '%s\n' "$hdr" > "$out"
  printf '%s\n' "$row" >> "$out"
  # The rollup lives beside the installed helpers, never in a repo — it spans projects and
  # its notes can name private paths, so it must not be committable by accident.
  local roll="${AGENT_COMMS_HOME:-$HOME/.agent-comms}/friction.tsv"
  if mkdir -p "$(dirname "$roll")" 2>/dev/null; then
    [ -s "$roll" ] || printf '%s\n' "$hdr" > "$roll"
    printf '%s\n' "$row" >> "$roll"
  fi
  printf 'friction: recorded (severity %s) -> %s + the global rollup\n' "${sev:-3}" "${out#"$root"/}"
}

cmd_friction_list() {
  # friction --list — every project's friction in one place. This is the maintainer's
  # inbox: read it at the start of a session on this tool and you see what actually broke
  # in the field, instead of what someone remembered to mention.
  local roll="${AGENT_COMMS_HOME:-$HOME/.agent-comms}/friction.tsv"
  [ -s "$roll" ] || { echo "friction: nothing recorded yet ($roll)"; return 0; }
  # Worst first: severity 5 means the harness produced a wrong result.
  { head -1 "$roll"; tail -n +2 "$roll" | sort -t"$(printf '\t')" -k5,5r -k1,1r; }
}

# reply_leg_usage <reply-file> — the `usage` object of the leg turn that produced this reply, as
# one line of compact JSON, or `null`.
#
# THE RUN IS IDENTIFIED BY ITS OWN OUTPUT, not inferred. Every runner writes the reply it stamped
# to <run-dir>/reply.md before delivering it, and run dirs are named <request id>.<epoch>.<pid>, so
# the one run dir under that request whose reply.md carries THIS reply's message_id is the attempt
# that produced it — no timestamp ordering (retries can finish in the acceptance's second; clocks
# step), and no path read back through the event log (which stores long values digest-encoded).
# A shadow reply lives in its shadow store beside `<name>.result.json`. Any gap — a mailbox reply
# with no runner, a pruned run dir, an ambiguous match, a result.json from before usage existed —
# is null, never 0.
reply_leg_usage() {
  local f="$1" mid req d rj="" n=0
  mid="$(frontmatter_field "$f" message_id 2>/dev/null || true)"
  req="$(frontmatter_field "$f" in-reply-to 2>/dev/null || true)"
  case "$f" in
    */shadow/*.md) [ -f "${f%.md}.result.json" ] && rj="${f%.md}.result.json"; n=1 ;;
  esac
  if [ -z "$rj" ] && [ -n "$mid" ] && [ -n "$req" ]; then
    for d in "$(cmd_root)/logs/$(safe_name "$req")".*; do
      [ -f "$d/reply.md" ] && [ -f "$d/result.json" ] || continue
      [ "$(frontmatter_field "$d/reply.md" message_id 2>/dev/null || true)" = "$mid" ] || continue
      rj="$d/result.json"; n=$((n + 1))
    done
  fi
  if [ "$n" = 1 ] && [ -n "$rj" ] && command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
u=json.load(open(sys.argv[1])).get("usage")
if u is not None and not isinstance(u,dict): u=None
sys.stdout.write(json.dumps(u,sort_keys=True,separators=(",",":")))' "$rj" 2>/dev/null && return 0
  fi
  printf 'null'
}

# rounds_lock <ledger> / rounds_unlock <ledger> — serialise every writer of one rounds.tsv. The
# header upgrade REWRITES the file, so without this a writer that copied the old ledger could
# publish its copy over a row another writer appended in between. mkdir is the atomic test-and-set.
# A held lock is NEVER broken automatically: its age cannot prove the holder died (a paused writer
# is indistinguishable), and two contenders that both judge it stale can each remove the other's
# fresh lock. After ~10s the writer refuses and names the lock for a human to clear.
rounds_lock() {
  local l="$1.lock" i=0
  until mkdir "$l" 2>/dev/null; do
    [ "$i" -lt 100 ] || die "round-note: $(clip "$l") is held — another round-note is writing, or one died holding it; if none is running, remove that directory and retry"
    sleep 0.1; i=$((i + 1))
  done
}
rounds_unlock() { rmdir "$1.lock" 2>/dev/null || true; }

cmd_round_note() {
  # round-note <reply-file> --note "<one or two lines>" — record how a reviewer
  # performed on ONE round.
  #
  # The counts are derived from the reply, never typed: a hand-entered number is a
  # number nobody can trust later. The prose is the reader's assessment — what the
  # review caught that mattered, what it got wrong, what it missed that another
  # reviewer found.
  #
  # This is written FOR THE HUMAN and never enters a reviewer's context. A reviewer
  # that can see its own scorecard optimises the scorecard.
  local f="" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) need_value "round-note" $# "$1"; shift; note="$1" ;;
      -?*)    usage_err "round-note: unknown option '$(clip "$1")'" ;;
      *)      [ -z "$f" ] || usage_err "round-note: one reply file only"; f="$1" ;;
    esac
    shift
  done
  [ -n "$f" ] || usage_err "round-note: a reviewer reply file is required"
  [ -f "$f" ] || usage_err "round-note: no such file '$(clip "$f")'"
  [ -n "$note" ] || usage_err "round-note: --note is required (a round with no assessment records nothing worth reading later)"

  local root; root="$(main_repo_root)"; [ -n "$root" ] || usage_err "round-note: not inside a git repository"
  local rows blocking advisory
  rows="$(findings_extract "$f" gating "" "" "" "" 2>/dev/null || true)"
  blocking="$(printf '%s\n' "$rows" | awk -F'\t' '$13=="blocking"' | grep -c . || true)"
  advisory="$(printf '%s\n' "$rows" | awk -F'\t' '$13=="advisory"' | grep -c . || true)"

  local out="$root/.comms/grades/rounds.tsv"
  local hdr_old hdr
  hdr_old="$(printf 'timestamp\tthread\tphase\tround\treviewer\tverdict\tblocking\tadvisory\tprompt_version\tnote')"
  hdr="$(printf '%s\tusage' "$hdr_old")"
  mkdir -p "$(dirname "$out")" 2>/dev/null || die "round-note: cannot create $(clip "$(dirname "$out")")"
  local clean_note row
  clean_note="$(printf '%s' "$note" | tr '\t\n' '  ')"
  # usage LAST, after the free-text note: one line of compact JSON (the leg's `usage` from its
  # result.json) or `null`. JSON never carries a raw tab or newline, so the row stays one TSV row.
  # Composed BEFORE the lock, so the critical section is file writes only.
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(frontmatter_field "$f" thread)" "$(frontmatter_field "$f" phase)" \
    "$(frontmatter_field "$f" round)" "$(frontmatter_field "$f" from)" \
    "$(cmd_verdict "$f" 2>/dev/null || true)" "${blocking:-0}" "${advisory:-0}" \
    "$(cmd_prompt_version 2>/dev/null || true)" "$clean_note" \
    "$(reply_leg_usage "$f" | tr '\t\n' '  ')")"
  rounds_lock "$out"
  if [ ! -s "$out" ]; then
    printf '%s\n' "$hdr" > "$out" || { rounds_unlock "$out"; die "round-note: could not write $(clip "$out")"; }
  elif [ "$(head -1 "$out")" = "$hdr_old" ]; then
    # A ledger from before the usage column: extend its HEADER only. Older rows keep ten fields,
    # which a TSV reader sees as an empty (unknown) usage — never as a measured zero.
    { printf '%s\n' "$hdr"; tail -n +2 "$out"; } > "$out.tmp.$$" && mv "$out.tmp.$$" "$out" \
      || { rm -f "$out.tmp.$$"; rounds_unlock "$out"; die "round-note: could not add the usage column to $(clip "$out")"; }
  fi
  printf '%s\n' "$row" >> "$out" || { rounds_unlock "$out"; die "round-note: could not append to $(clip "$out")"; }
  rounds_unlock "$out"
  printf 'round-note: %s r%s %s — %s blocking, %s advisory -> %s\n' \
    "$(frontmatter_field "$f" from)" "$(frontmatter_field "$f" round)" \
    "$(cmd_verdict "$f" 2>/dev/null || true)" "${blocking:-0}" "${advisory:-0}" "${out#"$root"/}"
}

cmd_shadow() {
  # shadow --to <agent> <review-request> — have a SECOND reviewer read the exact
  # same artifact, and record what it found.
  #
  # The reply is produced, validated, and stored, but never delivered and never
  # written to thread state (runphase --no-deliver). That is deliberate and it is
  # the whole safety argument: a shadow verdict cannot gate a loop it was never
  # delivered into, so "the shadow never gates" is mechanical rather than a rule
  # someone has to remember.
  local to="" req="" rsid="" out="" timeout=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)           need_value "shadow" $# "$1"; shift; to="$1" ;;
      --review-set)   need_value "shadow" $# "$1"; shift; rsid="$1" ;;
      --out)          need_value "shadow" $# "$1"; shift; out="$1" ;;
      --timeout-secs) need_value "shadow" $# "$1"; shift; timeout="$1" ;;
      -?*)            usage_err "shadow: unknown option '$(clip "$1")'" ;;
      *)              [ -z "$req" ] || usage_err "shadow: one review-request only"; req="$1" ;;
    esac
    shift
  done
  [ -n "$to" ] || usage_err "shadow: --to <agent> is required (registered: $(registry_agents))"
  require_agent "$to" "shadow"
  # --no-deliver suppresses the TRUSTED-PARENT broker, and whether that is possible depends on
  # the TRANSPORT as well as the agent — see suppression_ok. An agent that authors and
  # sends its own reply (claude, codex) would still write into an inbox and still
  # record thread state, so for those the "cannot gate" guarantee would be a
  # convention rather than a mechanism — and this command's whole value is that it
  # is a mechanism. Refuse rather than silently downgrade. (grok, live 2026-08-22.)
  local shadow_via="" shadow_prov
  # Capability is a property of the PROVIDER; the shadow's name, store and stamp stay the identity.
  shadow_prov="$(registry_provider "$to")" || usage_err "shadow: cannot resolve the provider of '$to'"
  shadow_via="$(suppression_ok "$shadow_prov")" \
    || usage_err "shadow: '$to' would author and send its own reply here, so a shadow run could not be prevented from reaching an inbox — it can only be shadowed over a parent-brokered transport (ACP), and ACP is not available for it on this machine"
  [ -n "$req" ] || usage_err "shadow: a review-request file is required"
  [ -f "$req" ] || usage_err "shadow: no such file '$(clip "$req")'"

  local rtype author thread round phase
  rtype="$(frontmatter_field "$req" type)"
  [ "$rtype" = "review-request" ] || usage_err "shadow: '$(clip "$req")' is type '$rtype' — only a review-request can be shadowed"
  author="$(frontmatter_field "$req" from)"
  # A shadow of the author is not a second opinion.
  [ "$to" != "$author" ] || usage_err "shadow: '$to' wrote this request — shadow a DIFFERENT agent"
  thread="$(frontmatter_field "$req" thread)"
  round="$(frontmatter_field "$req" round)"
  phase="$(frontmatter_field "$req" phase)"
  [ -n "$round" ] || round=1

  local rp; rp="$(dirname "$SELF")/runphase.sh"
  [ -x "$rp" ] || die "shadow: runphase.sh not found next to comms.sh — re-run install.sh"

  local root; root="$(main_repo_root)"; [ -n "$root" ] || usage_err "shadow: not inside a git repository"
  local aid pver base gating reqid
  aid="$(cmd_snapshot create)" || die "shadow: could not retain the reviewed artifact"
  pver="$(cmd_prompt_version)" || die "shadow: could not compute the prompt version"
  base="$(frontmatter_field "$req" head_sha)"
  reqid="$(frontmatter_field "$req" message_id)"
  # The gating reviewer is the inbox this request was dispatched to — derived, never
  # typed, so the pair records who the shadow is actually being compared against.
  gating="$(basename "$(dirname "$req")")"; gating="${gating#to-}"
  registry_has "$gating" || gating=""
  [ -n "$rsid" ] || rsid="$(printf '%s-%s-r%s-%s' "${thread:-untracked}" "${phase:-nophase}" "$round" "$(printf '%s' "$aid" | cut -c1-7)")"
  rsid="$(safe_set_id "$rsid")"

  # One mapping per thread+phase+round, enforced at WRITE time. The join reads by
  # that same key, so a second successful shadow after the tree or prompt moved would
  # silently stamp later gating findings with the older artifact — and picking "the
  # first row" is an arbitrary answer to a question that has no right answer.
  # (codex, round 1.)
  local idx_pre; idx_pre="$(findings_set_index "$root")"
  if [ -f "$idx_pre" ]; then
    local dup
    dup="$(awk -F'\t' -v t="$thread" -v r="$round" -v ph="$phase" 'NR>1 && $3==t && $4==r && $5==ph {print $1; exit}' "$idx_pre")"
    # Unconditional: re-running with the SAME id was overwriting the stored reply while
    # leaving the earlier ledger rows in place, which is the ambiguity this guard exists
    # to prevent, not an exemption from it. (codex, round 2.)
    if [ -n "$dup" ]; then
      usage_err "shadow: thread '$thread' phase '${phase:-<none>}' round $round is already paired as review set '$dup' — this pilot records ONE shadow per thread+phase+round; remove that set to redo it"
    fi
  fi

  # Never overwrite a stored observation: it is the evidence, and a silent clobber is
  # indistinguishable from never having run. (codex, round 2.) Checked BEFORE anything is
  # spent: a contract-break leaves <agent>.raw.md but writes no set row, so a retry cleared
  # the pairing guard, ran the reviewer for ten minutes, and only then hit this check —
  # throwing away the work it had just paid for. (grok, first passing shadow run.)
  local store="$root/.comms/grades/shadow/$rsid"
  if [ -e "$store/$to.md" ] || [ -e "$store/$to.raw.md" ]; then
    die "shadow: $to already has a recorded result in ${store#"$root"/} — refusing to overwrite it (nothing was run)"
  fi

  local tmpdir
  # Neutral on purpose: the reviewer can see its own working directory, and a path
  # containing "shadow" or "grade" would announce the measurement role the design keeps
  # out of its view. (codex, round 2.)
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ac-wt.XXXXXX")" || die "shadow: cannot create a work dir"
  cmd_validate "$req" >/dev/null || { rm -rf "$tmpdir"; die "shadow: the review-request does not validate"; }

  # THE ARTIFACT IS MOUNTED, AND SHAPED LIKE THE WORKTREE IT CAME FROM.
  #
  # Checking the synthetic artifact commit out directly was wrong in a way that content
  # checks could not see: HEAD became the synthetic commit rather than the request's
  # head_sha, and `git diff` came back EMPTY because every reviewed change was already
  # committed inside it. The reviewer would fail its own head check and find no patch at
  # all. So: create the worktree at the BASE, materialize the artifact into it, then put
  # the index back to base — HEAD == head_sha, the reviewed changes read as uncommitted,
  # and files that were untracked are untracked again. (codex, round 2.)
  #
  # The mount name is deliberately opaque: 'agent-comms-shadow' in a path the reviewer
  # can see would announce the measurement role the design keeps out of its view.
  local tree="$tmpdir/w"
  local mount_base="$base"
  [ -n "$mount_base" ] || mount_base="$(git -C "$root" rev-parse -q --verify "$aid^" 2>/dev/null || printf '%s' "$aid")"
  git -C "$root" worktree add --detach --quiet "$tree" "$mount_base" 2>/dev/null \
    || { rm -rf "$tmpdir"; die "shadow: could not check out base $(clip "$mount_base")"; }
  shadow_cleanup() { git -C "$root" worktree remove --force "$tree" 2>/dev/null || true; rm -rf "$tmpdir"; }
  git -C "$tree" read-tree -u --reset "$aid" 2>/dev/null \
    || { shadow_cleanup; die "shadow: could not materialize artifact $(clip "$aid")"; }
  git -C "$tree" reset -q --mixed "$mount_base" 2>/dev/null \
    || { shadow_cleanup; die "shadow: could not restore the base index in the mount"; }

  # The child sees the request unchanged EXCEPT for cwd:, which must name the tree it was
  # actually given. That single field is routing, not content — it does not tell the
  # reviewer it is being measured, which is the contamination that matters and the reason
  # review_set/artifact_id/role stay out of its view. (grok, round 0.)
  #
  # Replace-or-INSERT: a request with no cwd: would otherwise leave runphase falling back
  # to the live main root, silently un-mounting the artifact. And the rewrite is
  # byte-preserving — the earlier awk normalized CRLF on every line of the message.
  # (codex, round 2.)
  local child_msg="$tmpdir/$(basename "$req")"
  if grep -q '^cwd:' "$req"; then
    LC_ALL=C sed "s|^cwd:.*|cwd: $tree|" "$req" > "$child_msg"
  else
    LC_ALL=C awk -v tree="$tree" '
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm && $0 == "---" { printf "cwd: %s\n", tree; fm = 0; print; next }
      { print }
    ' "$req" > "$child_msg"
  fi
  grep -q "^cwd: $tree\$" "$child_msg" || { shadow_cleanup; die "shadow: could not point the request at the mounted artifact"; }
  # The private copy is addressed to the SHADOW, not to whoever the original went to, so it
  # carries the shadow target's provider stamp (or none) — never an inherited one. The
  # original request is not touched.
  stamp_review_provider "$child_msg" "$to" || { shadow_cleanup; die "shadow: could not stamp the review provider on the private copy"; }
  cmd_validate "$child_msg" >/dev/null || { shadow_cleanup; die "shadow: the mounted-artifact copy did not validate"; }

  local rver_now; rver_now="$(agent_version "$shadow_prov")"
  local run_dir="$tmpdir/run"
  mkdir -p "$run_dir"
  echo "shadow: $to reviewing artifact ${aid} (set $rsid) in an isolated checkout — not delivered, cannot gate"
  local rc=0
  # The transport is the thing that MAKES suppression honourable for a self-sending agent, so it
  # is passed, not assumed: without it runphase refuses the flag at its own boundary — correctly.
  ( cd "$tree" && RUNPHASE_NO_DELIVER=1 "$rp" run --message "$child_msg" --dir "$run_dir" \
      --agent "$to" --no-deliver ${shadow_via:+--via "$shadow_via"} \
      ${timeout:+--timeout-secs "$timeout"} ) >/dev/null 2>&1 || rc=$?
  git -C "$root" worktree remove --force "$tree" 2>/dev/null || true

  # Did the live tree move while the reviewer was reading? The shadow is immune (it read
  # the mount), but the GATING reviewer reads the live tree, so drift is when the pair is
  # not on one artifact. Recorded as an explicit TRI-STATE: equal endpoints mean only
  # "no drift detected during the shadow window", never "confirmed identical", and a
  # snapshot that could not be taken is `unknown` rather than silently empty — an empty
  # field must never read as a clean result. (codex, round 2.)
  local aid_after drift="" drift_status="unknown"
  aid_after="$(cmd_snapshot create 2>/dev/null || true)"
  if [ -z "$aid_after" ]; then
    drift_status="unknown"
  elif [ "$aid_after" = "$aid" ]; then
    drift_status="same_endpoint"
  else
    drift_status="changed"; drift="$aid_after"
  fi

  mkdir -p "$store" 2>/dev/null || { rm -rf "$tmpdir"; die "shadow: cannot create $(clip "$store")"; }
  # WHAT DEPTH THE SHADOW RAN AT, requested and observed, kept before the run dir is deleted: a
  # routed-vs-baseline comparison is meaningless without it.
  cp "$run_dir/turn.tsv" "$store/$to.turn.tsv" 2>/dev/null || true
  cp "$run_dir/policy.tsv" "$store/$to.policy.tsv" 2>/dev/null || true
  # Success is the RUNNER's verdict, not the presence of a file: grok_broker
  # writes reply.md and validates it afterwards, so a stamped-but-degenerate
  # reply exists on disk after a failed turn. Keying on the file alone would
  # score exactly the AC5 case this is supposed to catch. (grok, live 2026-08-22.)
  if [ "$rc" != "0" ] || [ ! -s "$run_dir/reply.md" ]; then
    # A failed shadow turn is DATA, not an error to swallow: a reviewer that
    # times out, crashes, or breaks the reply contract is a real operational
    # result and must stay distinguishable from one that reviewed and found
    # nothing. Keep the RAW text too — on the very first live run grok produced
    # a full review and merely omitted the mandated 'VERDICT:' first line, and
    # throwing that text away would have discarded the entire turn plus the only
    # evidence of which contract it broke.
    printf '%s\n' "$rver_now" > "$store/$to.version"
    cp "$run_dir/reply-raw.md" "$store/$to.raw.md" 2>/dev/null || true
    cp "$run_dir/result.json" "$store/$to.failed.json" 2>/dev/null || true
    cp "$run_dir/runner.log" "$store/$to.runner.log" 2>/dev/null || true
    cp "$run_dir/events.ndjson" "$store/$to.events.ndjson" 2>/dev/null || true
    rm -rf "$tmpdir"
    # The raw text is NOT extracted into the ledger: a reply that failed the
    # contract must not be scored as if it had passed it.
    echo "shadow: $to produced no usable reply (rc=$rc) — recorded as an OPERATIONAL FAILURE in ${store#"$root"/}, not as a clean review"
    [ -s "$store/$to.raw.md" ] && echo "shadow: its raw output is preserved at ${store#"$root"/}/$to.raw.md (unscored)"
    return 1
  fi
  cp "$run_dir/reply.md" "$store/$to.md"
  cp "$run_dir/result.json" "$store/$to.result.json" 2>/dev/null || true
  # The reviewer's CLI identity is EPHEMERAL — asking again at rebuild time would stamp a
  # historical observation with today's upgraded version. Persist what was actually
  # observed, and let rebuild read it or leave the field empty. (codex, round 2.)
  printf '%s\n' "$rver_now" > "$store/$to.version"
  rm -rf "$tmpdir"

  local idx; idx="$(findings_set_index "$root")"
  mkdir -p "$(dirname "$idx")" 2>/dev/null || true
  [ -s "$idx" ] || findings_set_header > "$idx"
  if ! cut -f1 "$idx" | grep -qxF -- "$rsid"; then
    # A shadow row carries no attempt id: it is a MEASUREMENT of a thread, not a leg of a
    # dispatch, and giving it one would make it selectable as a leg of that attempt.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rsid" "$reqid" "$thread" "$round" "$phase" "$aid" "$pver" "$base" "$gating" "$to" \
      "$drift_status" "$drift" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "" >> "$idx"
  fi
  case "$drift_status" in
    changed) echo "shadow: WARNING - the live tree moved during the review ($aid -> $drift). The shadow read the mounted artifact; the gating reviewer may not have." ;;
    unknown) echo "shadow: NOTE - could not re-snapshot after the run, so drift is UNKNOWN, not absent." ;;
  esac
  echo "shadow: this is a CANDIDATE pair - same_endpoint means no drift was detected during the shadow window, never that the gating reviewer read this artifact."

  [ -n "$out" ] || out="$root/.comms/grades/findings.tsv"
  cmd_findings --out "$out" --role shadow --review-set "$rsid" --artifact "$aid" \
    --base-sha "$base" \
    --prompt-version "$pver" --reviewer-version "$rver_now" "$store/$to.md"
  echo "shadow: reply stored at ${store#"$root"/}/$to.md (never delivered; the loop is untouched)"
}

agent_version() {  # best-effort CLI identity — empty beats a guess
  local a="$1" v=""
  command -v "$a" >/dev/null 2>&1 || { printf ''; return 0; }
  v="$("$a" --version 2>/dev/null | head -1 | tr -d '\t\r' | cut -c1-60)" || true
  printf '%s' "${v:-}"
}

# ---------- presence: advisory multi-session coordination ----------
# Plan thread presence-worktrees-15135 (10 review rounds; design decisions in
# docs/ROADMAP.md "Design settled" + INTERNALS "Presence & worktrees"). Everything
# here is ADVISORY: refusals on visible state, documented race windows, no locks.
# Correctness never depends on this layer — the CAS in cmd_integrate and the
# fail-closed reading rules are what carry the invariants.
#
# Two clocks, deliberately distinct (grok, plan r5/r10):
#   TTL (I)      — freshness window; a live session beats at least once per I.
#   cover (2I)   — how long a tombstone shields a reaped name-instance.
PRESENCE_TTL_SECS="${COMMS_PRESENCE_TTL_SECS:-2700}"

presence_dir() { printf '%s/.comms/sessions' "$(main_repo_root)"; }
pgroup_stop() {  # <pgid> <signal> — stop a whole process group; 0 iff it is gone afterwards
  # THE ONE TEARDOWN for a supervised group, used by with-beat's quiescence sweep and by its
  # timeout. <signal> first (the latched identity, or TERM), then CONT: a STOPPED member (a
  # background read of the terminal draws SIGTTIN) holds every signal but KILL pending until it
  # is continued. Then bounded escalation: 5s for the group to leave, KILL, 2s more. The caller
  # decides what a survivor means. `sleep || true`: a group-INT during the poll must not abort
  # the wrapper before the KILL escalation (grok, impl r5).
  local pg="$1" sig="$2" n=0
  kill -"$sig" -- "-$pg" 2>/dev/null || true
  kill -CONT -- "-$pg" 2>/dev/null || true
  while kill -0 -- "-$pg" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -ge 50 ] && break; sleep 0.1 || true
  done
  if kill -0 -- "-$pg" 2>/dev/null; then
    kill -KILL -- "-$pg" 2>/dev/null || true
    n=0
    while kill -0 -- "-$pg" 2>/dev/null; do
      n=$((n + 1)); [ "$n" -ge 20 ] && break; sleep 0.1 || true
    done
  fi
  ! kill -0 -- "-$pg" 2>/dev/null
}

presence_validate_ids() {  # <name> [instance] — strict grammar at EVERY entry point:
  # these values become record paths, glob deletions, an rm -rf target, and trap
  # text. Validating only at claim left every later verb injectable. (codex, impl r1.)
  # '.tomb.' is a RESERVED delimiter: names may contain dots, and a name like
  # 'foo.tomb.bar' mis-split the cover parse at three sites — force reported
  # success while removing nothing. (codex, impl r6.)
  case "$1" in *.tomb.*) return 1 ;; esac
  # Newlines are rejected FIRST: grep validates LINES, so a multiline value like
  # 'alpha<NL>../../tmp' passed because its first line matched — and the later
  # lines reached record paths, glob deletions, and the string-built integrate
  # trap. With newlines gone, grep's line semantics equal whole-scalar semantics.
  # (codex, impl r7.)
  case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s' "$1" | grep -qE '^[a-z0-9][a-z0-9._-]{0,40}$' || return 1
  if [ $# -ge 2 ] && [ -n "$2" ]; then
    case "$2" in *$'\n'*|*$'\r'*) return 1 ;; esac
    printf '%s' "$2" | grep -qE '^[a-z0-9]{8,64}$' || return 1
  fi
  return 0
}
presence_host() { hostname 2>/dev/null || echo unknown-host; }
presence_field() {
  # Pipefail-tolerant: on bash 4.4+ set -e reaches command substitutions, and a
  # record unlinked between a caller's [ -f ] and this read would abort the whole
  # reader instead of fail-closing as ambiguity. (grok, impl r3.)
  { sed -n 's/.*"'"$2"'": "\([^"]*\)".*/\1/p' "$1" 2>/dev/null || true; } | head -1
}

presence_self_pid() {  # -> this session's long-lived pid, or EMPTY. Never fails.
  # A pid is the ONLY thing that can ever prove a record dead: presence_eval reaches
  # "dead" solely through a ps probe, so a pid-less record is unreapable AT ANY AGE
  # and lingers as a permanent ambiguous peer. Every abandoned record this repo
  # accumulated was pid-less, which is why `expire` had nothing to collect.
  #
  # A tool shell's own $$ is useless here — it dies within seconds and would make a
  # LIVE session's record read as a phantom. What is wanted is the agent harness's
  # own session process, which the harness publishes in the environment.
  #
  # ADOPTED ONLY IF VERIFIED PRESENT. An unverified pid is strictly WORSE than none:
  # a record naming a process that does not exist evaluates `dead` immediately, so
  # the next reap would collect a LIVE session's claim out from under it. Numeric,
  # then confirmed by ps; every other case yields empty, which is exactly today's
  # pid-less behaviour (ambiguous, isolate) — the fail-closed direction.
  # Each source is TRIED, not merely preferred: a stale COMMS_PRESENCE_PID that no
  # longer verifies must not shadow a good CLAUDE_PID. First one that verifies wins.
  # (grok, implement r1.)
  local p
  for p in "${COMMS_PRESENCE_PID:-}" "${CLAUDE_PID:-}"; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    # A ps that cannot answer (EPERM in a sandbox) must also yield empty, not a pid
    # we could not confirm. Guarded so errexit cannot abort the caller.
    ps -p "$p" -o pid= >/dev/null 2>&1 || continue
    printf '%s' "$p"; return 0
  done
  return 0
}

presence_resolve_handle() {  # <explicit-pid> <recorded-pid> <recorded-start>
  # Sets PRESENCE_HANDLE_PID / PRESENCE_HANDLE_START to the handle that should be
  # RECORDED: a freshly verified one when one is available, otherwise exactly what was
  # already recorded. It never blanks a recorded handle — doing so would manufacture the
  # pid-less immortal record this whole mechanism exists to stop.
  #
  # It also never compares only the pid NUMBER. A recycled pid keeps its number while its
  # start time changes, and a claim whose lstart probe failed recorded a pid with an EMPTY
  # start that stale evaluation reads as ambiguous forever; a number-only check left both
  # unrepaired. Writing the verified pair unconditionally repairs both. (grok, implement r2.)
  PRESENCE_HANDLE_PID="$2"; PRESENCE_HANDLE_START="$3"
  local xpid="$1" newpid newstart
  if [ -n "$xpid" ]; then newpid="$xpid"; else newpid="$(presence_self_pid)"; fi
  [ -n "$newpid" ] || return 0
  newstart="$(ps -p "$newpid" -o lstart= 2>/dev/null)" || newstart=""
  [ -n "$newstart" ] || return 0
  PRESENCE_HANDLE_PID="$newpid"; PRESENCE_HANDLE_START="$newstart"
}

presence_write() {  # <dest> <name> <instance> <role> <state> <pid> <pid_started> <started>
  # Whole-file temp+mv, temps OUT of the readers' record glob (.tmp/). A beat is a
  # full rewrite, never an update — a deleted record heals on the next beat, and the
  # bytes always change (the heartbeat), which is what invalidates reap observations.
  local dest="$1" dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir/.tmp" 2>/dev/null || return 1
  tmp="$dir/.tmp/$(basename "$dest").$$.$RANDOM"
  printf '{\n  "name": "%s",\n  "instance": "%s",\n  "role": "%s",\n  "state": "%s",\n  "host": "%s",\n  "pid": "%s",\n  "pid_started": "%s",\n  "started": "%s",\n  "last_heartbeat": "%s",\n  "last_heartbeat_epoch": "%s"\n}\n' \
    "$(json_escape "$2")" "$3" "$(json_escape "$4")" "$5" "$(presence_host)" \
    "$6" "$(json_escape "$7")" "$8" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" \
    > "$tmp" 2>/dev/null || return 1
  command mv -f "$tmp" "$dest" 2>/dev/null
}

presence_eval() {  # <record> — prints live|dead|ambig. FAIL CLOSED: every uncertain case is ambig.
  local f="$1" host hb pid pstart now age
  host="$(presence_field "$f" host)"
  hb="$(presence_field "$f" last_heartbeat_epoch)"
  case "$hb" in ''|*[!0-9]*) echo ambig; return 0 ;; esac   # corrupt/unreadable → peer
  # Foreign host: a pid from another machine is meaningless here — ambiguous, never
  # dead, never GC'd (01's cross-host analysis, folded plan r2).
  [ "$host" = "$(presence_host)" ] || { echo ambig; return 0; }
  now="$(date +%s)"; age=$((now - hb))
  [ "$age" -le "$PRESENCE_TTL_SECS" ] && { echo live; return 0; }
  # Stale. Staleness alone NEVER implies death (suspend/clock skew): only a recorded
  # pid can prove anything, and only existence-by-ps (EPERM-safe), with the recorded
  # start-time identity so a recycled pid cannot keep a dead claim alive.
  pid="$(presence_field "$f" pid)"
  case "$pid" in ''|*[!0-9]*) echo ambig; return 0 ;; esac  # stale + no pid → ambig
  # `ps` failing is NOT death: in a sandbox ps itself can be permission-denied
  # (exit 126) and a live stale session would have been reaped. Only exit 1 with
  # empty output is the-pid-does-not-exist; every other failure is ambiguous.
  # (codex, impl r1 — found running in exactly such a sandbox.)
  # `var=$(failing-cmd); rc=$?` is not errexit-safe on bash 4.4+ (set -e is
  # enforced inside command substitutions there): eval would abort with empty
  # output, expire would never reap, and dead records would become permanent
  # peers. Same shape as the lstart probe below. (grok, impl r2.)
  local psout psrc
  psout="$(ps -p "$pid" -o pid= 2>/dev/null)" && psrc=0 || psrc=$?
  if [ "$psrc" -eq 0 ] && [ -n "$psout" ]; then
    pstart="$(presence_field "$f" pid_started)"
    [ -n "$pstart" ] || { echo ambig; return 0; }   # live pid, no recorded identity → ambig
    local nowstart
    nowstart="$(ps -p "$pid" -o lstart= 2>/dev/null)" || { echo ambig; return 0; }
    [ -n "$nowstart" ] || { echo ambig; return 0; } # identity uncheckable → ambig
    # Whitespace-normalized compare: COLUMNS/ps padding must not flake liveness.
    [ "$(echo $nowstart)" = "$(echo $pstart)" ] \
      && { echo live; return 0; }     # same process, just stale (suspend) → live
    echo dead; return 0               # pid recycled: the recorded process is gone
  elif [ "$psrc" -eq 1 ] && [ -z "$psout" ]; then
    echo dead                          # ESRCH-confirmed absent
  else
    echo ambig                         # ps could not answer — never death
  fi
}

presence_peers() {  # <self-name> <self-instance> — prints peers; 0 none / 3 peers / 4 unreadable.
  # Reader protocol (plan r9): RECORDS first, then reap artifacts. The tombstone is
  # written BEFORE its record's unlink, so every expire interleaving shows a reader
  # at least one of the two until the cover legitimately ages out.
  local dir self="$1-$2.json" found=0 f verdict base tomb tepoch now covered counted=" "
  dir="$(presence_dir)"
  [ -d "$dir" ] || return 0
  # Readability is validated HERE, in the shared reader, for records AND covers:
  # `claim` used to skip this and return direct-safe from a directory it could
  # write but not enumerate — silent empty globs read as an empty field.
  # (codex, impl r2.)
  { [ -r "$dir" ] && [ -x "$dir" ]; } || { echo "presence: sessions dir unreadable — ISOLATE" >&2; return 4; }
  if [ -d "$dir/.reap" ]; then
    { [ -r "$dir/.reap" ] && [ -x "$dir/.reap" ]; } || { echo "presence: reap dir unreadable — ISOLATE" >&2; return 4; }
  fi
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$self" ] && continue
    verdict="$(presence_eval "$f")"
    [ "$verdict" = "dead" ] && continue
    found=1
    counted="$counted$(basename "$f" .json) "
    printf 'peer: %s  state=%s  role=%s  (%s)\n' \
      "$(presence_field "$f" name)-$(printf '%.8s' "$(presence_field "$f" instance)")" \
      "$(presence_field "$f" state)" "$(presence_field "$f" role)" "$verdict"
  done
  now="$(date +%s)"
  for tomb in "$dir"/.reap/*.tomb.*; do
    [ -f "$tomb" ] || continue
    base="$(basename "$tomb")"; base="${base%%.tomb.*}"
    # Skip a cover only when its record was ACTUALLY COUNTED in the first scan —
    # tracked by basename, never re-read: re-evaluating live state here let a
    # heal that landed between the two scans hide its own cover while `found`
    # stayed zero (the newcomer returned direct-safe beside a live peer).
    # (codex, impl r2.)
    case "$counted" in *" $base "*) continue ;; esac
    [ "$base" = "$1-$2" ] && continue             # own reaped ghost is not a peer to self
    # Guarded read: an EACCES/unlinked tomb aborted the whole reader under
    # pipefail (verified: a chmod-000 tomb made `others` exit 1 mid-print).
    # Unreadable OR corrupt both fail closed as a YOUNG cover. (grok, impl r4;
    # codex, impl r3.)
    tepoch="$({ sed -n 's/^#tomb \([0-9]*\).*/\1/p' "$tomb" 2>/dev/null || true; } | head -1)"
    case "$tepoch" in ''|*[!0-9]*) tepoch="$now" ;; esac
    covered=$((now - tepoch))
    if [ "$covered" -le $((PRESENCE_TTL_SECS * 2)) ]; then
      found=1
      printf 'peer: %s  (reaped-cover, heals or expires in %ss)\n' "$base" $((PRESENCE_TTL_SECS * 2 - covered))
    fi
  done
  [ "$found" = 0 ] && return 0 || return 3
}

cmd_presence() {
  # presence claim|beat|others|release|expire|with-beat — see docs/COMMANDS.md.
  # Exit contract for claim/others: 0 = recorded, no live/ambiguous peers (direct
  # work is safe); 3 = peers listed (isolate); 4 = the claim could not be recorded
  # or the sessions dir is unreadable — ambiguous ENVIRONMENT, isolate (fail
  # closed), never a hard error. beat exits 5 when it HEALED a vanished record:
  # presence is restored but DIRECT tenure is not — re-run claim-then-check before
  # the next shared-checkout write.
  local sub="${1:-}"; shift 2>/dev/null || true
  local name="" instance="" role="" state="" pid="" force="" presence_no_heartbeat=""
  local presence_timeout_secs="" presence_timeout_mark=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)     need_value "presence $sub" $# "$1"; shift; name="$1" ;;
      --instance) need_value "presence $sub" $# "$1"; shift; instance="$1" ;;
      --role)     need_value "presence $sub" $# "$1"; shift; role="$1" ;;
      --state)    need_value "presence $sub" $# "$1"; shift; state="$1" ;;
      --pid)      need_value "presence $sub" $# "$1"; shift; pid="$1" ;;
      --force)    need_value "presence $sub" $# "$1"; shift; force="$1" ;;
      --no-heartbeat) presence_no_heartbeat=1 ;;
      --timeout-secs) need_value "presence $sub" $# "$1"; shift; presence_timeout_secs="$1" ;;
      --timeout-mark) need_value "presence $sub" $# "$1"; shift; presence_timeout_mark="$1" ;;
      --) shift; break ;;
      -?*) usage_err "presence $sub: unknown option '$(clip "$1")'" ;;
      *) break ;;
    esac
    shift
  done
  if [ "$sub" != with-beat ] && [ -n "$presence_timeout_secs$presence_timeout_mark" ]; then
    usage_err "presence $sub: --timeout-secs and --timeout-mark belong to with-beat only"
  fi
  local dir; dir="$(presence_dir)"
  case "$sub" in
    claim)
      [ -n "$name" ] || usage_err "presence claim: --name required"
      presence_validate_ids "$name" \
        || usage_err "presence claim: invalid name '$(clip "$name")'"
      case "$pid" in *[!0-9]*) usage_err "presence claim: --pid must be numeric" ;; esac
      # An explicit --pid always wins; otherwise adopt the harness's own session pid
      # so this record can ever be proven dead. See presence_self_pid.
      [ -n "$pid" ] || pid="$(presence_self_pid)"
      # Collect provably-dead records BEFORE recording this claim, so the peer rows
      # below — and this claim's EXIT STATUS, which IS the isolation decision —
      # describe the field as it actually is, not as a departed session left it.
      # `expire` is otherwise a verb nobody invokes, which is why dead records
      # survived indefinitely even once they were collectable.
      # Two-pass by construction: this call can only OBSERVE a record it has not
      # seen before, and collects only on a later claim a full TTL afterwards with
      # the record byte-identical throughout. A claim therefore cannot reap a
      # session that is merely suspended or mid-write.
      # NEVER fails the claim: a reap that cannot run leaves the records in place,
      # which is the fail-closed direction (more peers, never fewer). Its output is
      # stderr so this claim's stdout stays exactly the claimed:/peer: contract that
      # every documented caller parses.
      presence_expire "$dir" "" >&2 || true
      instance="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
      [ -n "$instance" ] || { echo "presence: could not mint an instance token — ISOLATE" >&2; return 4; }
      local pstart=""
      # Guarded: a denied/failing ps must yield a pid-less (ambiguity-leaning)
      # claim, not an errexit abort. (codex, impl r2 advisory.)
      if [ -n "$pid" ]; then pstart="$(ps -p "$pid" -o lstart= 2>/dev/null)" || pstart=""; fi
      # CLAIM THEN CHECK: record own presence FIRST, evaluate peers second — the
      # ordering that shrinks the simultaneous-start race to seconds.
      if ! presence_write "$dir/$name-$instance.json" "$name" "$instance" "$role" "${state:-working}" "$pid" "$pstart" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
        echo "presence: could not record the claim in $dir — ambiguous environment, ISOLATE" >&2
        return 4
      fi
      echo "claimed: $name  instance: $instance"
      presence_peers "$name" "$instance"
      ;;
    beat)
      [ -n "$name" ] && [ -n "$instance" ] || usage_err "presence beat: --name and --instance required"
      presence_validate_ids "$name" "$instance" || usage_err "presence beat: invalid name/instance"
      local rec="$dir/$name-$instance.json" healed=0 orole ostate opid opstart ostarted
      if [ -f "$rec" ]; then
        # Token match is implicit in the path: this file IS ours or it does not exist.
        orole="$(presence_field "$rec" role)"; ostate="$(presence_field "$rec" state)"
        opid="$(presence_field "$rec" pid)"; opstart="$(presence_field "$rec" pid_started)"
        ostarted="$(presence_field "$rec" started)"
      else
        healed=1; orole="$role"; ostate="${state:-working}"; opid="$pid"; opstart=""; ostarted="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      fi
      [ -n "$state" ] && ostate="$state"
      [ -n "$role" ] && orole="$role"
      # RE-PIN THE LIVENESS IDENTITY. A resumed session is a NEW harness process, so a
      # beat that merely preserved the recorded pid would leave a LIVE session named by
      # an exited one — which now evaluates `dead` and gets collected out from under it,
      # and then reads as a free field to the next claimer. That is strictly worse than
      # the immortality this change set out to fix, and it is reachable only because
      # records became reapable. (codex, implement r1, blocking; mechanism corroborated
      # by grok.)
      #
      # Refresh ONLY with a pid that verifies right now; otherwise keep what is recorded.
      # An explicit --pid still wins, as at claim.
      presence_resolve_handle "$pid" "$opid" "$opstart"
      opid="$PRESENCE_HANDLE_PID"; opstart="$PRESENCE_HANDLE_START"
      presence_write "$rec" "$name" "$instance" "$orole" "$ostate" "$opid" "$opstart" "$ostarted" \
        || { echo "presence beat: write failed" >&2; return 4; }
      if [ "$healed" = 1 ]; then
        echo "presence: record was GONE and has been healed — tenure is NOT restored; re-run claim-then-check before the next shared-checkout write" >&2
        return 5
      fi
      ;;
    others)
      [ -n "$name" ] && [ -n "$instance" ] || usage_err "presence others: --name and --instance required"
      presence_validate_ids "$name" "$instance" || usage_err "presence others: invalid name/instance"
      # A MISSING sessions dir cannot be direct-safe for an identity that already
      # claimed: the caller's own record is necessarily gone with it, which is the
      # lost-tenure case, not an empty field. This shortcut ran BEFORE that check and
      # answered 0. (codex, implement r4, blocking; grok named the same state.)
      if [ ! -d "$dir" ]; then
        echo "presence: the sessions dir is GONE, so this session's record is too — tenure is NOT restored; re-claim before the next shared-checkout write" >&2
        return 5
      fi
      [ -r "$dir" ] || { echo "presence: sessions dir unreadable — ISOLATE" >&2; return 4; }
      # RE-PIN ON THE CHECKPOINT. `others` is the MANDATORY post-wait, post-resume
      # re-check (PROTOCOL rule 4), and it was the one surviving path that refreshed
      # nothing. A session that resumed under a new harness process, ran only `others`,
      # and worked on was still named by the exited one — dead to every reader, and
      # collectable alive in the window before its first beat, after which the field
      # read free to the next claimer. Re-pinning here closes that window at the exact
      # point the protocol already requires a session to check in.
      # (codex, implement r1 and r2, blocking; `others` named by grok as the last
      # non-re-pinning path.)
      #
      # An EXISTING exact-self record only. A vanished record is never manufactured
      # here: healing is `beat`'s exit-5 path, which a session must reach deliberately
      # and which tells it that tenure is gone.
      #
      # AND IT MUST FAIL CLOSED. A checkpoint that finds its OWN record gone cannot report
      # direct-safe: the session is alive, holds no record, and `presence_peers` excludes
      # its own tombstone — so a reaped-then-released field reads FREE to the very session
      # that was collected. That sequence was impossible while pid-less records were
      # immortal; it is reachable only because they became collectable, so this change owns
      # it. Lost tenure is reported the way `beat` reports a heal: exit 5, re-claim before
      # writing. (codex, implement r3, blocking.)
      local orec="$dir/$name-$instance.json" obase="$name-$instance" prc=0
      # Returns 0 deliberately: a non-zero return from a bare call would trip errexit
      # before the caller could turn it into the exit-5 answer.
      presence_lost_tenure() {   # peers are still worth printing; the STATUS is the answer
        presence_peers "$name" "$instance" || true
        echo "presence: this session's record is GONE (collected, or removed by an operator) — tenure is NOT restored; re-claim before the next shared-checkout write" >&2
        return 0
      }
      # A tombstone bearing our own name is proof of collection no matter what the record
      # looks like now — including one THIS call could have recreated in the race below.
      if ls "$dir/.reap/$obase".tomb.* >/dev/null 2>&1 || [ ! -f "$orec" ]; then
        presence_lost_tenure; return 5
      fi
      presence_resolve_handle "" "$(presence_field "$orec" pid)" "$(presence_field "$orec" pid_started)"
      # NOT optional. A re-pin that silently failed would leave the dead handle in place,
      # keep this session invisible to itself, and still answer direct-safe. (codex, r3.)
      presence_write "$orec" "$name" "$instance" "$(presence_field "$orec" role)" \
        "$(presence_field "$orec" state)" "$PRESENCE_HANDLE_PID" "$PRESENCE_HANDLE_START" \
        "$(presence_field "$orec" started)" \
        || { echo "presence: could not re-pin this session's record — ambiguous environment, ISOLATE" >&2; return 4; }
      # `expire` writes its tombstone BEFORE it unlinks, so re-reading covers AFTER the
      # write catches the unlink-between-check-and-write race — in which `presence_write`
      # would otherwise RECREATE the record, silently healing what this verb promises never
      # to heal. (codex, implement r3, blocking.)
      if ls "$dir/.reap/$obase".tomb.* >/dev/null 2>&1; then
        presence_lost_tenure; return 5
      fi
      presence_peers "$name" "$instance" || prc=$?
      return $prc
      ;;
    release)
      [ -n "$name" ] && [ -n "$instance" ] || usage_err "presence release: --name and --instance required"
      presence_validate_ids "$name" "$instance" || usage_err "presence release: invalid name/instance"
      # Exact-self deletion only — the token is the path, so a same-name successor's
      # record is untouchable by construction. (Deletion invariant, plan r5.)
      rm -f "$dir/$name-$instance.json" 2>/dev/null || true
      ;;
    expire)
      presence_expire "$dir" "$force"
      ;;
    with-beat)
      # Traps FIRST — the first statements of the arm, before validation and
      # before any substitution the ARM runs. Two windows remain outside the
      # traps' reach: bash's startup parse, and cmd_presence's shared
      # dir="$(presence_dir)" resolution before the case dispatch. Both are
      # fail-safe — a signal there is default-disposition DEATH (probed: 130 on
      # every delivered INT), never a latched-then-lost success.
      local parent=$$ beater="" child="" rc=0 healmark brc latched="" no_heartbeat="${presence_no_heartbeat:-}"
      local timeout_secs="${presence_timeout_secs:-0}" timeout_mark="${presence_timeout_mark:-}" timed_out="" t_start
      trap 'latched=INT;  kill -INT  -- ${child:+-$child} ${beater:+-$beater} 2>/dev/null || true' INT
      trap 'latched=TERM; kill -TERM -- ${child:+-$child} ${beater:+-$beater} 2>/dev/null || true' TERM
      [ -n "$name" ] && [ -n "$instance" ] || usage_err "presence with-beat: --name and --instance required"
      presence_validate_ids "$name" "$instance" || usage_err "presence with-beat: invalid name/instance"
      secs_value_ok "$timeout_secs" "$SUITE_TIMEOUT_MAX_SECS" \
        || usage_err "presence with-beat: --timeout-secs must be a whole number from 0 (none) to $SUITE_TIMEOUT_MAX_SECS"
      [ $# -gt 0 ] || usage_err "presence with-beat: a command is required after --"
      # The heal marker belongs to the beater: with --no-heartbeat there is no beater, so
      # nothing to report — and the marker path is shared per identity, so initialising or
      # consuming it here could swallow a CONCURRENT wrapper's heal warning. Touch it only
      # when we actually own a beater. (codex, integrate-beat r7.)
      healmark="$(presence_dir)/.tmp/healed-$name-$instance"
      [ -n "$no_heartbeat" ] || rm -f "$healmark" 2>/dev/null || true
      # Signal contract (codex, impl r3/r4): traps live at the arm's top; each
      # job gets its OWN PROCESS GROUP via set -m so teardown reaches
      # grandchildren; identity is preserved (INT as INT, TERM as TERM); the
      # LATCH records a signal landing in any gap and each spawn re-applies it
      # to the newborn group. These traps fire while the function is live, so
      # deferred ${child:-} is safe — unlike the EXIT-trap locals lesson.
      set -m
      # EVERY command in the beater is errexit-immune: the subshell inherits
      # set -e, so a bare beat exiting 5 (heal) killed the beater before the
      # marker line — r1's "eats heal signals" survived the r2 fix as dead code,
      # and heartbeats stopped for the rest of the child. (codex + grok, impl r2;
      # grok: `( false; echo AFTER ) &` never prints AFTER.)
      # --no-heartbeat keeps everything below and skips only the beater. Supervision
      # (own process group per job, signal identity, the latch, and whole-group
      # quiescence) and heartbeating were fused in one verb, but a caller with NO record
      # to refresh still needs the supervision: without it a suite can print its
      # completion line, launch a stdio-detached descendant and exit 0, leaving that
      # descendant free to mutate the verification tree after the landing. Beating there
      # is not an option either — a beat HEALS an absent record into a pid-less one.
      # (codex, integrate-beat r6, blocking.)
      if [ -z "$no_heartbeat" ]; then
      ( while :; do
          sleep $((PRESENCE_TTL_SECS / 3))
          kill -0 "$parent" 2>/dev/null || exit 0   # orphan beater suicide (plan r5)
          brc=0
          "$SELF" presence beat --name "$name" --instance "$instance" >/dev/null 2>&1 || brc=$?
          if [ "$brc" -eq 5 ]; then
            : > "$healmark" 2>/dev/null || true
          fi
        done ) </dev/null & beater=$!
      fi
      # (beater stdin from /dev/null — the dual of the piped-client fix: under
      # set -m it inherited the wrapper's pipe and could steal input. grok, r4.)
      [ -n "$latched" ] && kill "-$latched" -- "-$beater" 2>/dev/null || true
      # The child keeps the wrapper's stdin EXPLICITLY (<&0): a background job in
      # a non-job-control shell silently rebinds stdin to /dev/null and breaks
      # piped clients — a wrapped `head -1` read nothing. (codex, impl r3;
      # verified on bash 3.2.)
      "$@" <&0 & child=$!
      [ -n "$latched" ] && kill "-$latched" -- "-$child" 2>/dev/null || true
      set +m
      # THE TIMEOUT (--timeout-secs N, 0 = none). bash 3.2's `wait` cannot time out, so a bounded
      # run polls the LEADER once a second instead: bash reaps a finished background child, so
      # `kill -0` fails as soon as it has exited. A latched signal ends the poll and takes the
      # ordinary path below. Past the deadline the whole group gets TERM — and CONT, because a
      # STOPPED process (SIGTTIN from a background read of the terminal, say) holds TERM pending
      # until it is continued — then KILL after a 5s grace, through the same pgroup_stop the
      # quiescence sweep uses. The mark is written FIRST, so a caller can tell this apart from a command that merely exited
      # 124 itself: an exit status is the one channel the command controls. (integrate
      # suite-timeout, 2026-09-27.)
      if [ "$timeout_secs" -gt 0 ]; then
        t_start=$SECONDS
        while [ -z "$latched" ] && kill -0 "$child" 2>/dev/null; do
          # STRICTLY greater: SECONDS ticks on wall-clock second boundaries, so a difference of
          # N can mean as little as N-1 real seconds (t_start read at x.99). -gt guarantees at
          # least N, at the cost of firing up to two seconds late.
          if [ $((SECONDS - t_start)) -gt "$timeout_secs" ]; then
            timed_out=1
            [ -z "$timeout_mark" ] || : > "$timeout_mark" 2>/dev/null || true
            echo "presence with-beat: the command ran past --timeout-secs $timeout_secs — terminating its process group" >&2
            break
          fi
          sleep 1 || true
        done
        # BOUNDED TEARDOWN BEFORE THE WAIT, whether the poll ended on the deadline or on a
        # latched INT/TERM. Without a timeout the trap interrupts a `wait` already in progress;
        # here the trap only ends the poll, so an unconditional `wait` on a leader that ignores
        # the signal would block forever and never reach the escalation below. (codex, suite-
        # timeout r1, blocking.) A leader that already exited needs none: the sweep handles its
        # stragglers.
        if [ -n "$timed_out$latched" ] && kill -0 "$child" 2>/dev/null; then
          pgroup_stop "$child" "${latched:-TERM}" || true
        fi
      fi
      rc=0; wait "$child" || rc=$?
      # QUIESCENCE before return (codex, impl r4): the wrapper's success must mean
      # the child's whole group is GONE — integrate trusts the tree state on
      # return, and a straggling suite descendant made a same-shaped model return
      # 0 two seconds early. Sweep with the latched identity (or TERM), then
      # bounded escalation to KILL, then FAIL CLOSED if the group still breathes.
      if ! pgroup_stop "$child" "${latched:-TERM}"; then
        echo "presence with-beat: the child's process group survived TERM and KILL — failing closed (result untrusted)" >&2
        rc=125
      fi
      # ${beater:+-$beater} matches the form the INT/TERM traps already use, so a skipped
      # beater is a real no-op rather than a swallowed usage error. (grok, r7.)
      kill -TERM -- ${beater:+-$beater} 2>/dev/null || true
      { [ -n "$beater" ] && wait "$beater" 2>/dev/null; } || true             # join-before-restore
      trap - INT TERM
      # A LATCHED CANCELLATION NEVER RETURNS SUCCESS — applied AFTER teardown and
      # trap restoration, because the traps stay live through the quiescence
      # polls and a late INT there updated the latch after an earlier coercion
      # and still returned 0 (codex reproduced it, impl r6; the fast-child probe
      # was impl r5: 225/2000 false successes). The child's own nonzero status is
      # preserved; only a clean 0 under cancellation is forced to the signal's.
      if [ -n "$latched" ] && [ "$rc" -eq 0 ]; then
        [ "$latched" = INT ] && rc=130 || rc=143
      fi
      # A TIMED-OUT command never returns its own status: whatever the killed leader exited with
      # (143, 137, or a 0 from a TERM handler that "finished cleanly") is not a result. 124 is the
      # coreutils timeout(1) convention; a group that outlived KILL keeps the stronger 125.
      if [ -n "$timed_out" ] && [ "$rc" -ne 125 ]; then
        rc=124
      fi
      if [ -z "$no_heartbeat" ] && [ -f "$healmark" ]; then
        rm -f "$healmark" 2>/dev/null || true
        echo "presence: a beat during this run HEALED a vanished record — tenure is NOT restored; re-run claim-then-check before the next shared-checkout write" >&2
      fi
      return "$rc"
      ;;
    *) usage_err "presence: expected claim|beat|others|release|expire|with-beat" ;;
  esac
}

presence_expire() {  # <dir> [force-name] — the ONLY verb that deletes OTHERS' records.
  # Two-pass byte-identical reap (plan r7) with unlink-time nonce tombstones (r9/r10):
  # pass 1 stores an observation; a LATER invocation reaps only if the record is
  # byte-identical, the observation is a full TTL old (its ORIGINAL stamp — never
  # refreshed), and confident-death still holds. The tombstone is written BEFORE the
  # unlink, carries its own clock, and GC unlinks only the exact nonce file it
  # observed — a paused GC cannot clobber a newer generation. Cover GC is
  # "old AND no record" ONLY: a cover is never deleted because a record exists.
  local dir="$1" force="$2" reap="$dir/.reap" now f base obs oepoch nonce tomb tepoch staged
  now="$(date +%s)"
  mkdir -p "$reap" 2>/dev/null || { echo "expire: cannot use $reap" >&2; return 1; }
  if [ -n "$force" ]; then
    presence_validate_ids "$force" || { echo "expire: invalid --force name" >&2; return 1; }
    # Explicit operator path for forever-ambiguous entries (foreign host, no pid).
    # EXACT name match: names may contain '-', so `alpha-*` also matched
    # `alpha-team-<instance>` and erased an unrelated live session's records and
    # covers. The instance token is the LAST '-'-segment and has a strict
    # grammar — strip it and require the remainder to equal the name exactly.
    # (codex, impl r5.)
    local ff fbase fsuffix
    for ff in "$dir/$force"-*.json "$reap/$force"-*; do
      [ -e "$ff" ] || continue
      fbase="$(basename "$ff")"
      fbase="${fbase%.json}"; fbase="${fbase%.obs}"
      case "$fbase" in *.tomb.*) fbase="${fbase%%.tomb.*}" ;; esac
      fsuffix="${fbase##*-}"
      [ "${fbase%-$fsuffix}" = "$force" ] || continue
      printf '%s' "$fsuffix" | grep -qE '^[a-z0-9]{8,64}$' || continue
      rm -f "$ff" 2>/dev/null || true
    done
    echo "expire: forced removal of every '$force' record and artifact"
    return 0
  fi
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .json)"
    obs="$reap/$base.obs"
    [ "$(presence_eval "$f")" = "dead" ] || { rm -f "$obs" 2>/dev/null; continue; }
    if [ ! -f "$obs" ]; then
      { printf '#obs %s\n' "$now"; cat "$f"; } > "$reap/.tmp.$$" 2>/dev/null \
        && command mv -f "$reap/.tmp.$$" "$obs" 2>/dev/null
      continue                                    # pass 1: observe, touch nothing
    fi
    oepoch="$({ sed -n 's/^#obs \([0-9]*\).*/\1/p' "$obs" 2>/dev/null || true; } | head -1)"
    case "$oepoch" in ''|*[!0-9]*) rm -f "$obs"; continue ;; esac
    [ $((now - oepoch)) -ge "$PRESENCE_TTL_SECS" ] || continue     # grace not served
    # CLAIM THE RECORD BY RENAME, THEN COMPARE. Comparing in place left a window
    # between the cmp and the unlink in which the record was still readable, so a
    # concurrent re-check could re-pin it, see no tombstone yet, and answer direct-safe
    # while this pass went on to delete it — two sessions authorized at once. Renaming
    # first means the whole decision happens while the record is ABSENT, and absence is
    # the state that now fails closed (exit 5, tenure lost). A rename we lose means
    # another pass got there first. (codex, implement r4, blocking; grok scoped the cure
    # to expire rather than to another re-pin.)
    staged="$reap/.staging.$$.$RANDOM"
    command mv -f "$f" "$staged" 2>/dev/null || { rm -f "$obs" 2>/dev/null; continue; }
    if ! tail -n +2 "$obs" | cmp -s - "$staged"; then
      # A beat intervened. Put it back and abort — restoring is what keeps this
      # non-destructive for a record that turned out to be alive.
      command mv -f "$staged" "$f" 2>/dev/null || true
      rm -f "$obs" 2>/dev/null; continue
    fi
    # Reap: tombstone BEFORE the staged copy goes (r9), nonce-named (r10).
    nonce="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    tomb="$reap/$base.tomb.$nonce"
    printf '#tomb %s\n' "$now" > "$reap/.tmp.$$" 2>/dev/null \
      && command mv -f "$reap/.tmp.$$" "$tomb" 2>/dev/null \
      || { command mv -f "$staged" "$f" 2>/dev/null || true; rm -f "$obs"; continue; }
    rm -f "$staged" 2>/dev/null
    rm -f "$obs" 2>/dev/null                      # observation is spent; the TOMB is the cover
    echo "reaped: $base (cover $nonce holds for $((PRESENCE_TTL_SECS * 2))s)"
  done
  # Cover GC — 1(a) only: old AND no record; age re-checked AFTER the record check
  # on the exact nonce file; a new generation is a different pathname entirely.
  for tomb in "$reap"/*.tomb.*; do
    [ -f "$tomb" ] || continue
    base="$(basename "$tomb")"; base="${base%%.tomb.*}"
    [ -f "$dir/$base.json" ] && continue          # record exists → cover stays, always
    tepoch="$({ sed -n 's/^#tomb \([0-9]*\).*/\1/p' "$tomb" 2>/dev/null || true; } | head -1)"
    case "$tepoch" in ''|*[!0-9]*) continue ;; esac
    [ $(( $(date +%s) - tepoch )) -gt $((PRESENCE_TTL_SECS * 2)) ] || continue
    [ -f "$dir/$base.json" ] && continue          # re-check after age read
    rm -f "$tomb" 2>/dev/null
  done
  # A pass killed between the rename and the tombstone parks a record under a staging
  # name. The owning session already fails closed (its record is absent, so its next
  # re-check answers exit 5), but the file must not accumulate. Only long-dead ones.
  for staged in "$reap"/.staging.*; do
    [ -f "$staged" ] || continue
    [ -n "$(find "$staged" -mmin +$(( (PRESENCE_TTL_SECS * 2) / 60 + 1 )) 2>/dev/null)" ] || continue
    rm -f "$staged" 2>/dev/null
  done
  return 0
}

config_scalar() {  # <root> <key> — the ONE way any consumer reads a config scalar.
  # Duplicate rejection has to live at the READ, not in a validator the caller
  # may never invoke: `registry_parse` refused duplicates but `integrate` never
  # calls it, so an appended `suite-attest-secs = 0` meant to DISABLE the skip
  # still lost to the earlier enabling value on the one command where safety
  # matters. Every consumer now fails the same way. (codex, ergonomics r2.)
  # A READ ERROR IS NOT AN ABSENT KEY. Both reads used to swallow errors and answer "", which
  # every caller takes to mean "not configured" — and `verify init` treats "not configured" as
  # permission to write one. A missing FILE is still "not configured". (codex, generic-verify r2.)
  local f="$1/.comms/config" key="$2" ct="" rc=0 val=""
  [ -f "$f" ] || return 0
  ct="$(grep -c "^[[:space:]]*$key[[:space:]]*=" "$f" 2>/dev/null)" || rc=$?
  [ "$rc" -le 1 ] || die "config: cannot read $f (grep exit $rc) — refusing to treat it as empty"
  [ "${ct:-0}" -le 1 ] || die "config: duplicate '$key' key in $f — refusing to guess which value is authoritative"
  val="$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$f" 2>/dev/null)" \
    || die "config: cannot read $f — refusing to treat it as empty"
  [ -z "$val" ] || printf '%s\n' "$val" | head -1
}

# SUITE TIMEOUT. integrate had no bound on the suite, so a suite that hung (live, 2026-09-27: a
# vitest run idle at 0% CPU for 45+ minutes in the verification tree) blocked the landing, and
# every driver waiting on it, forever. The default is generous for a real suite; 0 means none.
SUITE_TIMEOUT_DEFAULT_SECS=3600
SUITE_TIMEOUT_MAX_SECS=86400

secs_value_ok() {  # <value> <max> — 0 iff a plain decimal 0..max (no sign, no leading zero)
  # A leading zero is refused, not stripped: bash arithmetic reads `010` as octal, and `08`
  # is an arithmetic error that would abort under errexit.
  case "$1" in 0) return 0 ;; ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le "${#2}" ] && [ "$1" -le "$2" ]
}

suite_timeout_secs() {  # <root> — the ONE reader of suite-timeout-secs: prints the effective value
  # Absent = the default. Present = a plain integer 0..SUITE_TIMEOUT_MAX_SECS, or a refusal: a
  # typo'd bound must never silently become "no bound" or "the default". Duplicates die inside
  # config_scalar, like every suite key. Returns 1 with the reason on stderr.
  # A PRESENT-but-empty line is a typo too, not an absence (config_scalar answers "" for both).
  local v
  v="$(config_scalar "$1" suite-timeout-secs)" || return 1
  if [ -z "$v" ] && ! grep -q '^[[:space:]]*suite-timeout-secs[[:space:]]*=' "$1/.comms/config" 2>/dev/null; then
    printf '%s\n' "$SUITE_TIMEOUT_DEFAULT_SECS"; return 0
  fi
  secs_value_ok "$v" "$SUITE_TIMEOUT_MAX_SECS" || {
    echo "config: suite-timeout-secs must be a whole number of seconds from 0 (no timeout) to $SUITE_TIMEOUT_MAX_SECS — got '$(clip "$v")'" >&2
    return 1
  }
  printf '%s\n' "$v"
}

cmd_attest_green() {
  # attest-green [--passed N] — record "the suite ran green at this exact commit".
  # The record lets integrate skip its re-verification when the SAME OID was
  # verified moments ago: without it every landing costs two full suite runs — the
  # pre-flight and integrate's re-run — of which the second proves nothing new
  # (user, 2026-08-27: ~24 minutes to merge a branch). Consumption is opt-in
  # (suite-attest-secs in .comms/config) and time-bounded; the paranoid re-run
  # stays the default.
  # A value-taking flag REQUIRES its value — need_value, the one guard. (grok, r1.)
  local passed="" expect=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --passed) need_value "attest-green" $# "$1"; shift; passed="$1" ;;
      --expect) need_value "attest-green" $# "$1"; shift; expect="$1" ;;
      -?*) usage_err "attest-green: unknown option '$(clip "$1")'" ;;
      *)  usage_err "attest-green: unexpected argument '$(clip "$1")'" ;;
    esac; shift
  done
  local top oid dirty root
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "attest-green: not inside a git repository"
  oid="$(git -C "$top" rev-parse --verify HEAD 2>/dev/null)" || die "attest-green: cannot resolve HEAD"
  # --expect binds the record to the commit the CALLER actually verified: a
  # checkout or commit that lands between the caller's run and this read would
  # otherwise be attested with a green result it never earned. (codex,
  # integrate-ergonomics r1.)
  if [ -n "$expect" ]; then
    [ "$oid" = "$expect" ] || die "attest-green: HEAD is $oid but the verified commit was $expect — refusing to attest a commit the run was not about"
  fi
  # -uno: tracked changes void the attestation; untracked files do not. That is a
  # deliberate, documented residual — session logs and scratch files beside the
  # checkout are routine, and an attestation nobody can ever mint protects no one.
  # The consumer is opt-in and time-bounded; a stricter tree hash can replace this
  # if the residual ever bites.
  dirty="$(git -C "$top" status --porcelain -uno 2>/dev/null)" || die "attest-green: cannot read the tree status"
  [ -z "$dirty" ] || die "attest-green: tracked changes present — a green run here proves nothing about $oid"
  root="$(main_repo_root)"; [ -n "$root" ] || die "attest-green: no main repo root"
  mkdir -p "$root/.comms/cache" 2>/dev/null || true
  printf '%s %s %s\n' "$oid" "$(date +%s)" "${passed:-0}" >> "$root/.comms/cache/suite-attest.log" \
    || die "attest-green: cannot write the attestation log"
  echo "attest-green: recorded $oid"
}


# INTEGRATE EXIT CODES — the driver contract. An external driver (a scheduler that lands
# work unattended) must tell "retry later" from "rebase" from "fix the repo" without
# parsing prose, and a single exit 1 for every refusal made that impossible. This table is
# the ONE definition: docs/COMMANDS.md documents it, the header banner summarises it, and
# every refusal in cmd_integrate names a constant from it. 0 = landed, 2 = usage (the shared
# usage_err), 1 = anything unclassified. 10+ keeps clear of presence's 3/4/5 and of the
# shell's own 126/127/128+.
INTEGRATE_RC_CONFIG=10      # no/empty/duplicate suite-cmd, no main ref, no repo root
INTEGRATE_RC_LEASE=11       # another live session holds the integrating lease (retry later)
INTEGRATE_RC_NOT_FF=12      # the candidate is not a descendant of main (rebase first)
INTEGRATE_RC_OCCUPIED=13    # main is checked out where it cannot be healed (dirty, moved, several)
INTEGRATE_RC_SUITE_RED=14   # the suite exited non-zero at the candidate
INTEGRATE_RC_UNVERIFIED=15  # the suite result cannot be trusted (no completion proof, partial
                            # run, tree moved or dirtied, candidate not materialized)
INTEGRATE_RC_CAS_LOST=16    # main moved during the attempt; nothing landed (re-run re-verifies)
INTEGRATE_RC_ENV=17         # a precondition could not be READ (sessions dir, worktree list,
                            # occupant state, the pinned /usr/bin/env), or main could not be
                            # written although it had not moved (lock, permissions, disk)
INTEGRATE_RC_SUITE_TIMEOUT=18  # the suite ran past suite-timeout-secs; its process group was
                               # killed and nothing landed (a hang, not a red result)

integrate_fail() {  # <code> <message...> — die with a classified exit code
  local code="$1"; shift
  echo "comms.sh: $*" >&2
  exit "$code"
}

integrate_kv() {  # <string> — one whitespace-free result-line value (%XX outside a safe set)
  # The result line is key=value separated by spaces, so a value may never contain a space,
  # an '=', or a '%' unescaped. Branch arguments are revisions, and `@{1 day ago}` is one.
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._/@{}~^:+-]) out+="$c" ;;
      # A byte above 0x7F reads back NEGATIVE through printf "'c" (sign-extended char),
      # so mask to one byte or `é` prints as %FFFFFFFFFFFFFFC3.
      *) out+="$(printf '%%%02X' $(( $(printf '%d' "'$c") & 255 )))" ;;
    esac
  done
  printf '%s' "$out"
}

integrate_oneline() {  # <string> — one inert line: no byte in it can start a new line for any reader
  # stdout is reserved for integrate's own lines and the parsed `integrate-result` line. git
  # accepts a revision carrying a literal newline (`HEAD^{/.|<LF>integrate-result ...<LF>}`
  # resolves), so any caller-supplied or path value echoed there must stay on ONE line or it
  # can forge a result. (codex, driver-contract r2, blocking.)
  # Escaped, not stripped: a backslash itself (so the output is unambiguous), CR/LF and every
  # other control byte, and the Unicode separators a splitlines() reader honours (NEL, LS, PS).
  # (codex r3 advisory.) Print the result with printf '%s', NEVER echo: under xpg_echo or posix
  # mode echo expands `\n` back into a newline and undoes all of this. (codex + grok, r3.)
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      \\) out+='\\' ;;
      [[:cntrl:]]) out+="$(printf '\\x%02X' $(( $(printf '%d' "'$c") & 255 )))" ;;
      *) out+="$c" ;;
    esac
  done
  out="${out//$'\xc2\x85'/\\u0085}"; out="${out//$'\xe2\x80\xa8'/\\u2028}"; out="${out//$'\xe2\x80\xa9'/\\u2029}"
  printf '%s' "$out"
}

# inert_lines — stdin to stdout, the streaming sibling of integrate_oneline for multi-line PROSE
# that shares stdout with a parsed result line (compose). LF-delimited lines are kept; inside a
# line, CR and every other control byte but TAB become `\xNN`, and NEL, LS and PS become
# `\u0085` / ` ` / ` `, so no reviewer-authored byte can begin a line for a reader that
# splits on more than LF. Backslashes are left alone: this is prose, and the promise is only that
# it cannot forge a line. One sed pass over bytes (LC_ALL=C), not a per-character shell loop.
INERT_LINES_SED=""
inert_lines() {
  if [ -z "$INERT_LINES_SED" ]; then
    local i
    for i in 1 2 3 4 5 6 7 8 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 127; do
      INERT_LINES_SED="${INERT_LINES_SED}s/$(printf "\\$(printf '%03o' "$i")")/\\\\x$(printf '%02X' "$i")/g;"
    done
    INERT_LINES_SED="${INERT_LINES_SED}s/$(printf '\302\205')/\\\\u0085/g;s/$(printf '\342\200\250')/\\\\u2028/g;s/$(printf '\342\200\251')/\\\\u2029/g"
  fi
  LC_ALL=C sed "$INERT_LINES_SED"
}

suite_verify_candidate() {  # <who> <root> <cand> <tw> <suite_log> <suite_cmd> <name> <instance> <presence_record> <timeout_secs>
  # THE ONE VERIFICATION ROUTINE. `integrate` and `verify fresh` both call it, so the check that
  # guards a landing and the preflight that promises "this will land" can never drift apart.
  # It materializes <cand> at <tw>, runs suite-cmd there with the shell-startup scrub and the
  # same supervision integrate always used, and then demands positive proof, HEAD binding and a
  # clean tree. It RETURNS a classified status (0 ok, or an INTEGRATE_RC_* class) with the reason
  # in SUITE_VERIFY_REASON. It never exits, never installs or clears a trap, and writes nothing to
  # stdout: the caller owns its lifecycle (integrate's EXIT trap re-attaches a healed occupant and
  # restores presence) and its stdout contract. The worktree and log paths are the CALLER's, so a
  # preflight can never remove an in-flight landing's tree. (codex + grok, generic-verify plan r2/r3.)
  local who="$1" root="$2" cand="$3" tw="$4" suite_log="$5" suite_cmd="$6" name="$7" instance="$8" presence_record="$9"
  local timeout_secs="${10:-0}"
  local rc=0
  SUITE_VERIFY_REASON=""
  # Recover any prior crash's stale registration before adding: remove the entry
  # if git still knows it, prune dangling metadata, then clear the directory.
  git -C "$root" worktree remove --force "$tw" >/dev/null 2>&1 || true
  git -C "$root" worktree prune >/dev/null 2>&1 || true
  rm -rf "$tw" 2>/dev/null || true
  git -C "$root" worktree add --detach "$tw" "$cand" >/dev/null 2>&1 || { SUITE_VERIFY_REASON="$who: could not materialize $cand"; return "$INTEGRATE_RC_UNVERIFIED"; }
  # Structured argv: whitespace split only, nothing shell-interpreted. An
  # empty/whitespace-only suite-cmd expanded to zero argv and SUCCEEDED as a
  # no-op — the exact unverified landing the config gate exists to refuse.
  # (codex, impl r1.)
  set -f; set -- $suite_cmd; set +f
  [ $# -gt 0 ] || { SUITE_VERIFY_REASON="$who: suite-cmd is empty after splitting — refusing to land unverified"; return "$INTEGRATE_RC_CONFIG"; }
  # SHELL-STARTUP SCRUB. Non-interactive bash sources $BASH_ENV *before* the script
  # runs, so a suite's own guards are installed too late to matter: `BASH_ENV` naming
  # a file that says `exit 0` makes `bash tests/run.sh` return 0 with no output and no
  # assertions, and integrate would land on it. ENV/SHELLOPTS/BASHOPTS are the same
  # class. (codex, panel r4, blocking — demonstrated with BASH_ENV=/dev/stdin.)
  # `command` PREFIX, and no fallback. `BASH_ENV` is sourced by THIS helper before the
  # scrub runs, so a hook can define a function that prints a well-formed
  # `passed: N  failed: 0  skipped: 0` line and returns 0 -- tee records the forgery,
  # PIPESTATUS[0] is 0, the positive proof passes, and a candidate lands with the suite
  # never having run.
  #
  # An absolute path is NOT enough: bash 3.2 accepts `function /usr/bin/env { ...; }`
  # and dispatches it ahead of the executable (verified on this runtime -- an earlier
  # version of this comment claimed otherwise and was wrong). `command` suppresses
  # function lookup, which is what actually forces the executable to run.
  # (codex, panel r6 then r7, blocking twice.)
  #
  # The fallback that used to sit here reassigned the scrub command to a bare, lookup-
  # dispatched name whenever the absolute path was not executable -- which undid the pin
  # on every host, not just an unusual layout. It is gone: a missing /usr/bin/env now
  # REFUSES rather than silently running unpinned. (grok, panel r7.)
  # (Deliberately worded without the literal assignment, because the regression that
  # forbids it greps this file and would otherwise match its own description.)
  #
  # HONEST LIMIT, stated rather than implied: this defeats the demonstrated forgeries.
  # It is not a containment boundary. Anything that can inject BASH_ENV into this helper
  # already runs code as the user -- it could shadow `command` itself, or replace `bash`
  # or `git` on PATH. The proof is a tripwire against silent pre-emption and cheap
  # impersonation, and a shell whose function table is attacker-controlled is out of
  # scope for any in-process check.
  command test -x /usr/bin/env \
    || { SUITE_VERIFY_REASON="$who: /usr/bin/env is missing — refusing to run the suite unpinned"; return "$INTEGRATE_RC_ENV"; }
  local -a clean_env
  clean_env=(command /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD)
  # Keep the output of the run we are judging. A refusal whose evidence was discarded
  # cannot be diagnosed, which cost a full investigation earlier in this arc.
  mkdir -p "$(dirname "$suite_log")" 2>/dev/null || true
  # errexit is suspended ACROSS the pipeline: with `set -e -o pipefail` a red suite
  # terminates the helper AT the pipeline, so `rc=${PIPESTATUS[0]}` never runs and the
  # "suite FAILED ... output kept at ..." diagnostic below is unreachable on exactly the
  # path it describes. Landing stayed fail-closed, but the operator lost the message.
  # (codex, panel r5, advisory — the same errexit class as the assignment above.)
  set +e
  # SUITE OUTPUT GOES TO STDERR. stdout is reserved for integrate's own lines, above all the
  # `integrate-result` line a driver parses: a forwarded suite line of that shape would forge
  # a second result on success, or a result on a refusal. A nested integrate inside the suite
  # does exactly that without any malice. The raw output is still kept whole in $suite_log.
  # (codex, driver-contract r1, blocking.)
  # THIRD SITE, and the one no short test could reach: `with-beat`'s beater sleeps TTL/3
  # (default 900s) and then beats, which HEALS an absent record — manufacturing the same
  # pid-less, unreapable record the two explicit gates prevent, fifteen minutes in, long
  # after every fixture had finished. (codex + grok, integrate-beat r5.)
  # SUPERVISION ALWAYS; heartbeat only when there is a record to refresh. Running the
  # suite unwrapped to avoid the healing beat gave up whole-process-group quiescence,
  # and that is load-bearing: a suite can print its completion line, launch a
  # stdio-detached descendant and exit 0, leaving it alive to mutate the verification
  # tree after integrate validates and advances main. `--no-heartbeat` keeps the
  # supervision and drops only the beater. (codex, integrate-beat r6, blocking.)
  # A caller with NO identity used to run the suite bare — no process group, no quiescence,
  # and so nothing a timeout could kill without reaching the caller. It now gets the same
  # supervision under a fixed synthetic identity that only satisfies with-beat's argument
  # grammar: with --no-heartbeat nothing reads or writes a record under it (tests/dispatch.py
  # supervises its workers the same way).
  local sv_name="$name" sv_instance="$instance" hb=""
  if [ -z "$name" ] || [ -z "$instance" ]; then
    sv_name="integrate-suite" sv_instance="00000000000000000000000000000000" hb="--no-heartbeat"
  fi
  [ -f "$presence_record" ] || hb="--no-heartbeat"
  # THE TIMEOUT is with-beat's: it owns the suite's process group (its own, so a kill can never
  # reach this helper or its caller), the TERM-then-KILL teardown and the quiescence proof. The
  # mark is how a timeout is told apart from a red suite: the suite controls its exit status,
  # not a file this helper names and clears first. stdin is /dev/null: the suite runs in a
  # BACKGROUND process group, where a read of a controlling terminal STOPS it (SIGTTIN) — a
  # hang at 0% CPU of exactly the shape the timeout exists for, and a landing gate has no
  # input to give it anyway.
  # Per INVOCATION ($$), not per candidate: two integrations of one candidate without identities
  # take no lease, and a shared mark let one clear the other's timeout or hand it a false one.
  # (codex, suite-timeout r1.)
  local tmark="$suite_log.timeout.$$"
  rm -f "$tmark" 2>/dev/null || true
  # shellcheck disable=SC2086
  ( cd "$tw" && "${clean_env[@]}" "$SELF" presence with-beat $hb --name "$sv_name" --instance "$sv_instance" \
      --timeout-secs "$timeout_secs" --timeout-mark "$tmark" -- "$@" ) </dev/null 2>&1 | tee "$suite_log" >&2
  rc=${PIPESTATUS[0]}
  set -e
  if [ -e "$tmark" ]; then
    rm -f "$tmark" 2>/dev/null || true
    SUITE_VERIFY_REASON="$who: suite TIMED OUT after ${timeout_secs}s (suite-timeout-secs) at $cand — its process group was killed; main untouched; output so far kept at $suite_log
$who: note — a timeout is a hang or a slow suite, not a red result: raise suite-timeout-secs in
$who: .comms/config (0 = no timeout) if the suite is legitimately this slow."
    return "$INTEGRATE_RC_SUITE_TIMEOUT"
  fi
  # THE FRESH-CHECKOUT HINT. The verification tree is materialized by `git worktree add`,
  # so it carries TRACKED CONTENT ONLY — no untracked and no ignored files. A suite-cmd that
  # passes in the operator's checkout and fails here is usually depending on something that
  # checkout has and this one does not, and the tool's own error (a missing-module code, say)
  # gives no reason to suspect the TREE. Deliberately generic: naming any one ecosystem's
  # directory would teach this tool what `node_modules` is, and the same shape covers an
  # ignored `.npmrc`, a `.env`, or a build cache. Worded as a LIKELY cause, not a verdict —
  # most suite failures really are just failures. (codex + grok, plan r1.)
  [ "$rc" = 0 ] || { SUITE_VERIFY_REASON="$who: suite FAILED ($rc) at $cand — main untouched; full output kept at $suite_log
$who: note — the verification tree is a FRESH checkout of the candidate: untracked and
$who: ignored files are absent. If this suite passes in your working checkout, the likely
$who: cause is suite-cmd depending on something only that checkout has; suite-cmd must
$who: provision its own prerequisites. Read $suite_log for the underlying failure."; return "$INTEGRATE_RC_SUITE_RED"; }
  # POSITIVE PROOF, not merely an absence of failure. A scrub is a blocklist and the
  # next startup hook will not be on it, so require evidence the suite actually RAN:
  # its completion line, with counts matching the contract committed AT THE CANDIDATE.
  # Only enforced when the candidate carries a contract, so other projects' suite-cmds
  # are unaffected. (codex, panel r4.)
  local exp_total proof_pass proof_fail proof_skip
  # `|| exp_total=""` is load-bearing: under `set -e` + `pipefail`, a candidate with no
  # contract makes `git show` exit 128 and the ASSIGNMENT takes the whole function down
  # -- the var=$(cmd) errexit trap this repo has hit before. A project without a
  # contract must simply skip the proof, not fail its landing.
  exp_total="$(git -C "$root" show "$cand:tests/expected-counts.tsv" 2>/dev/null \
               | awk -F'\t' '$1=="total"{print $2}')" || exp_total=""
  case "$exp_total" in ''|*[!0-9]*) exp_total="" ;; esac
  if [ -n "$exp_total" ]; then
    proof_pass="$(sed -n 's/^passed: \([0-9][0-9]*\)  *failed: \([0-9][0-9]*\)  *skipped: \([0-9][0-9]*\) *$/\1/p' "$suite_log" | tail -1)" || proof_pass=""
    proof_fail="$(sed -n 's/^passed: \([0-9][0-9]*\)  *failed: \([0-9][0-9]*\)  *skipped: \([0-9][0-9]*\) *$/\2/p' "$suite_log" | tail -1)" || proof_fail=""
    proof_skip="$(sed -n 's/^passed: \([0-9][0-9]*\)  *failed: \([0-9][0-9]*\)  *skipped: \([0-9][0-9]*\) *$/\3/p' "$suite_log" | tail -1)" || proof_skip=""
    [ -n "$proof_pass" ] \
      || { SUITE_VERIFY_REASON="$who: the suite exited 0 but emitted no completion line — it did not run to the end (a shell-startup hook can pre-empt it); refusing. Output: $suite_log"; return "$INTEGRATE_RC_UNVERIFIED"; }
    [ "$proof_fail" = 0 ] \
      || { SUITE_VERIFY_REASON="$who: the suite reported $proof_fail failures despite exit 0 — refusing. Output: $suite_log"; return "$INTEGRATE_RC_UNVERIFIED"; }
    [ "$((proof_pass + proof_skip))" = "$exp_total" ] \
      || { SUITE_VERIFY_REASON="$who: the suite ran $((proof_pass + proof_skip)) of $exp_total assertions the candidate declares — refusing a partial run. Output: $suite_log"; return "$INTEGRATE_RC_UNVERIFIED"; }
  fi
  # BIND the result to the candidate: a suite that checked out another OID and
  # passed there proves nothing about $cand. Every verification below fails
  # CLOSED — a command that cannot answer refuses the landing. (codex, impl r1.)
  local tw_head tw_status
  tw_head="$(git -C "$tw" rev-parse HEAD 2>/dev/null)" || { SUITE_VERIFY_REASON="$who: cannot read the verification tree's HEAD — refusing"; return "$INTEGRATE_RC_UNVERIFIED"; }
  [ "$tw_head" = "$cand" ] || { SUITE_VERIFY_REASON="$who: the verification tree is at $tw_head, not the candidate $cand — the suite result is not about this landing; refusing"; return "$INTEGRATE_RC_UNVERIFIED"; }
  tw_status="$(git -C "$tw" status --porcelain 2>/dev/null)" || { SUITE_VERIFY_REASON="$who: cannot read the verification tree's status — refusing"; return "$INTEGRATE_RC_UNVERIFIED"; }
  # SIBLING OF THE HINT ABOVE, and the one an operator acting on that hint hits next: told to
  # provision prerequisites, they write a wrapper, and it lands here if its output is
  # git-VISIBLE. Ignored output is fine — an installed dependency tree is the intended shape.
  # Untracked-but-unignored files and modified tracked files are not, and a package manager
  # that rewrites a tracked lockfile produces exactly the latter. Print the dirt: "refusing to
  # trust the result" without saying WHAT dirtied it is a refusal nobody can act on.
  # (grok, plan r1 — worth more here than on the suite-FAILED path.)
  [ -z "$tw_status" ] || { SUITE_VERIFY_REASON="$who: the suite dirtied the verification tree — refusing to trust the result
$who: note — suite-cmd MAY create IGNORED files (an installed dependency tree is fine); it
$who: may NOT leave git-visible changes. Modified tracked files and untracked-but-unignored
$who: output both land here. Dirt:
$tw_status"; return "$INTEGRATE_RC_UNVERIFIED"; }
  return 0
}

integrate_is_docs_only() {  # <root> <base-oid> <cand-oid> — 0 iff every changed path is prose
  # Prose = README.md, LICENSE, or a top-level docs/*.md file. Nested docs
  # (docs/loopspec — the installed review bar) and AGENTS.md (the onboarding
  # contract) are load-bearing and must still pay the suite. Empty diffs are
  # not a skip: identical trees fall through to attest/suite. The skip does
  # not mint an attestation. --no-renames so a rename cannot hide its source
  # path (e.g. helpers/comms.sh -> docs/comms.md would otherwise look like
  # prose-only). --ignore-submodules=none so a config like diff.ignoreSubmodules=all
  # cannot hide a changed gitlink behind a README bump. Symlink/gitlink modes at
  # otherwise-allowed paths also refuse the skip (name alone is not enough).
  local root="$1" base="$2" cand="$3" paths p raw line mode_a mode_b
  paths="$(git -C "$root" diff --name-only --no-renames --ignore-submodules=none "$base" "$cand")" || return 1
  [ -n "$paths" ] || return 1
  raw="$(git -C "$root" diff --raw --no-renames --ignore-submodules=none "$base" "$cand")" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # :oldmode newmode ... — modes are octal; 120000 symlink, 160000 gitlink
    mode_a="${line#*:}"; mode_a="${mode_a%% *}"
    mode_b="${line#* }"; mode_b="${mode_b%% *}"
    # Concat is safe: git modes never end in 1/6, so 120000/160000 cannot span the join.
    case "$mode_a$mode_b" in
      *120000*|*160000*) return 1 ;;
    esac
  done <<EOF
$raw
EOF
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      README.md|LICENSE) continue ;;
      docs/*/*) return 1 ;;
      docs/*.md) continue ;;
      *) return 1 ;;
    esac
  done <<EOF
$paths
EOF
  return 0
}

cmd_integrate() {
  # integrate <branch> [--landing-branch <name>] — land a session branch on the landing branch
  # (default main; the comments below say "main" for it): advisory lease, ff-only,
  # suite at the CANDIDATE OID in a throwaway detached worktree, then the CAS
  # update-ref. The lease is an economizer; the CAS is the safety. main never
  # holds WORK: it moves by ref, verified first. One clean checkout may idle on
  # it as a console — that one is healed through the landing, not refused.
  # (Plan r3-r6; the idle-console exception 2026-08-27.)
  local branch="${1:-}"; shift 2>/dev/null || true
  [ -n "$branch" ] || usage_err "integrate: a branch is required"
  local name="${COMMS_PRESENCE_NAME:-}" instance="${COMMS_PRESENCE_INSTANCE:-}" lb=main
  while [ $# -gt 0 ]; do
    case "$1" in
      # A value-taking flag REQUIRES its value (need_value): an exit 1 with no message reads to a
      # driver as "unclassified" instead of usage. (codex, driver-contract r1.)
      --name) need_value "integrate" $# "$1"; shift; name="$1" ;;
      --instance) need_value "integrate" $# "$1"; shift; instance="$1" ;;
      --landing-branch) need_value "integrate" $# "$1"; shift; lb="$1" ;;
      -?*) usage_err "integrate: unknown option '$(clip "$1")'" ;;
      *) usage_err "integrate: unexpected argument '$(clip "$1")'" ;;
    esac; shift
  done
  # The landing branch is baked into the EXIT trap strings below, so its spelling is restricted to
  # a shell-inert set on top of git's own ref rules; every real branch name fits.
  case "$lb" in
    ''|-*|*[!A-Za-z0-9._/-]*) usage_err "integrate: --landing-branch '$(clip "$lb")' is not a plain branch name (A-Z a-z 0-9 . _ / -)" ;;
  esac
  git check-ref-format --branch "$lb" >/dev/null 2>&1 \
    || usage_err "integrate: --landing-branch '$(clip "$lb")' is not a valid branch name"
  local lref="refs/heads/$lb"
  # The assignment carries its own guard: `main_repo_root` is a git|sed pipeline, and outside a
  # repository (or with an unreadable .git) git exits 128, so under `set -e -o pipefail` the
  # bare assignment aborted with 128 and no message before the empty check below could run.
  # The empty check stays for a zero-status empty answer. (codex + grok, driver-contract r1.)
  local root
  root="$(main_repo_root)" || integrate_fail "$INTEGRATE_RC_CONFIG" "integrate: no main repo root (not inside a git repository, or it cannot be read)"
  [ -n "$root" ] || integrate_fail "$INTEGRATE_RC_CONFIG" "integrate: no main repo root"
  local suite_cmd
  suite_cmd="$(config_scalar "$root" suite-cmd)" \
    || integrate_fail "$INTEGRATE_RC_CONFIG" "integrate: cannot read suite-cmd from .comms/config (see above)"
  [ -n "$suite_cmd" ] || integrate_fail "$INTEGRATE_RC_CONFIG" "integrate: no 'suite-cmd = ...' in .comms/config — refusing to land unverified (explicit configuration required)"
  # Read BEFORE the lease, like suite-cmd: a bad bound refuses in a second, not after a suite run.
  local suite_timeout
  suite_timeout="$(suite_timeout_secs "$root")" \
    || integrate_fail "$INTEGRATE_RC_CONFIG" "integrate: invalid suite-timeout-secs in .comms/config (see above)"
  # Advisory lease: refuse while any OTHER live presence is integrating. The scan
  # fails CLOSED on an unenumerable dir — a silent empty glob read as lease-free
  # (CAS keeps correctness, but blind concurrent suites are waste). (codex+grok, impl r3.)
  local dir f
  dir="$(presence_dir)"
  if [ -d "$dir" ] && { [ ! -r "$dir" ] || [ ! -x "$dir" ]; }; then
    integrate_fail "$INTEGRATE_RC_ENV" "integrate: sessions dir unreadable — cannot verify the integrating lease; refusing"
  fi
  if [ -d "$dir" ]; then
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      [ "$(basename "$f" .json)" = "$name-$instance" ] && continue
      [ "$(presence_field "$f" state)" = "integrating" ] || continue
      [ "$(presence_eval "$f")" = "dead" ] && continue
      integrate_fail "$INTEGRATE_RC_LEASE" "integrate: $(presence_field "$f" name) holds a live integrating lease — serialize (advisory; re-run when it releases)"
    done
  fi
  if [ -n "$name" ] || [ -n "$instance" ]; then
    presence_validate_ids "$name" "$instance" || usage_err "integrate: invalid presence name/instance"
  fi
  # The restoration trap is installed BEFORE the first state mutation: setting the
  # lease first and trapping later leaked a live integrating lease on every early
  # exit (invalid candidate, non-ff, worktree-add failure), blocking all other
  # integrators until an operator noticed. (codex, impl r1.)
  local expected cand tw rc=0
  # tw is computable BEFORE the trap, so its LITERAL value is baked into the trap
  # string at set-time (like $root/$name): the previous deferred ${tw:-} expanded
  # EMPTY when die fired the EXIT trap after function locals were gone, so every
  # post-add failure leaked a REGISTERED worktree and the documented "fix and
  # re-run" recovery died on 'missing but already registered worktree'.
  # (grok, impl r2.)
  local presence_record=""
  [ -n "$name" ] && [ -n "$instance" ] && presence_record="$(presence_dir)/$name-$instance.json"
  tw="$root/.claude/worktrees/.integrate-${instance:-$$}"
  # shellcheck disable=SC2064
  trap "git -C '$root' worktree remove --force '$tw' >/dev/null 2>&1 || true; rm -rf '$tw' 2>/dev/null || true; if [ -n '$name' ] && [ -f '$presence_record' ]; then '$SELF' presence beat --name '$name' --instance '$instance' --state working >/dev/null 2>&1 || true; fi" EXIT
  # HISTORY, past tense on purpose: the guard is load-bearing, and its absence WAS a
  # silent-death bug. `presence beat` exits 5 when it heals a vanished record, which USED
  # TO happen on every integrate run whose
  # inherited COMMS_PRESENCE_NAME/INSTANCE has no record in THIS repo — i.e. every nested
  # integrate in the test fixtures, and any operator whose presence record lives in a
  # different checkout. Under `set -e` that aborted integrate before its first line of
  # output, so the failure had no diagnostic at all and read as "integrate did nothing".
  # This is what made an integrate-hosted suite run fail three of its own integrate tests
  # while seven direct runs of the same commit passed. The sibling call at the end of this
  # function already guarded the same way; this one did not. Both ends now check for the
  # record BEFORE beating, so the absent-identity beat no longer happens at all and the
  # guard covers only the residual race. Presence bookkeeping is advisory and must never
  # decide a landing. (grok, integrate-beat r6 — a stale present-tense comment in this
  # function becomes the next round's spec.)
  # CHECK, THEN BEAT. `presence beat` HEALS a vanished record by design, so beating an
  # identity that has no record in THIS repo manufactures one — pid-less, therefore never
  # reapable, therefore a permanent ambiguous peer for every future session. Three rounds
  # of review went into owning and releasing that record correctly across signals, nested
  # arms and repositories, and each fix opened a new hole (cross-repo identity collision, a
  # shared healmark race, a non-atomic ownership handoff). The record is not needed: this
  # beat is advisory bookkeeping on a lease that, by definition, does not exist here. So
  # do not create it. Nothing to own, nothing to authenticate, nothing to release.
  # `|| true` still guards the residual window where the record vanishes between the test
  # and the beat; that heal is `presence beat`'s ordinary behaviour everywhere else in the
  # system, not a class this function introduces. (codex, integrate-beat r1-r4.)
  if [ -n "$name" ] && [ -n "$instance" ] && [ -f "$(presence_dir)/$name-$instance.json" ]; then
    "$SELF" presence beat --name "$name" --instance "$instance" --state integrating >/dev/null 2>&1 || true
  fi
  expected="$(git -C "$root" rev-parse --verify "$lref" 2>/dev/null)" || integrate_fail "$INTEGRATE_RC_CONFIG" "integrate: no local branch '$lb' ($lref) to land on — create it or pass --landing-branch <existing branch>"
  cand="$(git -C "$root" rev-parse --verify "$branch^{commit}" 2>/dev/null)" || usage_err "integrate: cannot resolve '$(clip "$branch")'"
  printf '%s\n' "integrate: candidate $cand (from $(integrate_oneline "$branch")), expected $lb $expected"
  git -C "$root" merge-base --is-ancestor "$expected" "$cand" \
    || integrate_fail "$INTEGRATE_RC_NOT_FF" "integrate: $branch is not a descendant of $lb — rebase first (ff-only)"
  # NEVER-OCCUPY-MAIN, decided BEFORE the suite: refusing after a green
  # 10-minute run is the expensive way to learn main was occupied (user,
  # 2026-08-27 — the arc's own first landing hit exactly that). ONE clean
  # occupant parked exactly at the expected tip is SELF-HEALED — detached now,
  # re-attached to main after the CAS — because that is the root checkout idling
  # on main, the common case, and re-pointing an idle clean tree is just a
  # fast-forward. Anything else (dirty, diverged, multiple occupants) refuses:
  # re-pointing a tree someone is working in corrupts their session.
  local heal_list occ occ_n occ_head occ_status healed=""
  heal_list="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || integrate_fail "$INTEGRATE_RC_ENV" "integrate: cannot enumerate worktrees — refusing"
  occ="$(printf '%s\n' "$heal_list" | LC_ALL=C awk -v want="branch $lref" '/^worktree /{p=substr($0,10)} $0==want{print p}')"
  if [ -n "$occ" ]; then
    occ_n="$(printf '%s\n' "$occ" | grep -c .)"
    [ "$occ_n" = 1 ] || integrate_fail "$INTEGRATE_RC_OCCUPIED" "integrate: $lb is checked out in $occ_n worktrees — refusing (never-occupy-main)"
    occ_head="$(git -C "$occ" rev-parse --verify HEAD 2>/dev/null)" || integrate_fail "$INTEGRATE_RC_ENV" "integrate: cannot read main occupant's HEAD ($occ) — refusing (never-occupy-main)"
    [ "$occ_head" = "$expected" ] || integrate_fail "$INTEGRATE_RC_OCCUPIED" "integrate: $lb occupant $occ sits at $occ_head, not the $lb tip — refusing (never-occupy-main)"
    occ_status="$(git -C "$occ" status --porcelain -uno 2>/dev/null)" || integrate_fail "$INTEGRATE_RC_ENV" "integrate: cannot read main occupant's status ($occ) — refusing (never-occupy-main)"
    [ -z "$occ_status" ] || integrate_fail "$INTEGRATE_RC_OCCUPIED" "integrate: $lb occupant $occ has uncommitted changes — refusing (never-occupy-main; commit them or move it off $lb)"
    git -C "$occ" checkout --detach >/dev/null 2>&1 || integrate_fail "$INTEGRATE_RC_OCCUPIED" "integrate: could not detach main occupant $occ — refusing (never-occupy-main)"
    healed="$occ"
    # Re-arm the trap WITH the undo baked in as a literal: a die past this point
    # must put the occupant back on main, not strand it detached. The undo is
    # CONDITIONAL on main still being at the tip we detached from — another
    # writer may have advanced it, and silently attaching an idle console to a
    # tip this run never verified is not the promise "unmoved main" made.
    # (codex, r1.) Leaving it detached is the safe residual; the message says so.
    # shellcheck disable=SC2064
    trap "git -C '$root' worktree remove --force '$tw' >/dev/null 2>&1 || true; rm -rf '$tw' 2>/dev/null || true; if [ \"\$(git -C '$root' rev-parse --verify $lref 2>/dev/null)\" = '$expected' ] && [ \"\$(git -C '$healed' rev-parse HEAD 2>/dev/null)\" = '$expected' ]; then git -C '$healed' checkout $lb >/dev/null 2>&1 || true; else echo \"integrate: left $healed detached at \$(git -C '$healed' rev-parse --short HEAD 2>/dev/null || true) — $lb or the checkout moved during the attempt\" >&2 || true; fi; if [ -n '$name' ] && [ -f '$presence_record' ]; then '$SELF' presence beat --name '$name' --instance '$instance' --state working >/dev/null 2>&1 || true; fi" EXIT
    printf '%s\n' "integrate: healed — detached clean $lb occupant $(integrate_oneline "$occ") for the landing"
  fi
  # DOCS-ONLY SKIP. A tree diff that is only README.md, LICENSE, or top-level
  # docs/*.md cannot change helper/protocol behavior. Nested docs (docs/loopspec,
  # the installed review bar) and AGENTS.md are not in that set. The skip does
  # not mint an attestation — a later code change on the same OID window still
  # has to earn a real green. (operator, 2026-09-15: the suite is ~14 minutes.)
  local attest_secs attest_age="" skip_suite=""
  if integrate_is_docs_only "$root" "$expected" "$cand"; then
    skip_suite=docs
    echo "integrate: docs-only candidate — skipping the suite"
  fi
  # ATTESTED GREEN: when .comms/config opts in (suite-attest-secs = N), a fresh
  # attest-green record for EXACTLY this candidate OID stands in for the re-run —
  # the tree cannot have changed under an identical commit id, so the second run
  # proves nothing the first did not. Absent, stale, or wrong-OID attestations
  # fall through to the full suite; with no config the behavior is unchanged.
  attest_secs="$(config_scalar "$root" suite-attest-secs)" \
    || integrate_fail "$INTEGRATE_RC_CONFIG" "integrate: cannot read suite-attest-secs from .comms/config (see above)"
  case "$attest_secs" in ''|*[!0-9]*) attest_secs=0 ;; esac
  if [ -z "$skip_suite" ] && [ "$attest_secs" -gt 0 ] && [ -f "$root/.comms/cache/suite-attest.log" ]; then
    local att_epoch
    att_epoch="$(LC_ALL=C awk -v c="$cand" '$1==c && $2 ~ /^[0-9]+$/ {e=$2} END{if (e != "") print e}' "$root/.comms/cache/suite-attest.log" 2>/dev/null || true)"
    if [ -n "$att_epoch" ]; then
      attest_age=$(( $(date +%s) - att_epoch ))
      if [ "$attest_age" -ge 0 ] && [ "$attest_age" -le "$attest_secs" ]; then
        skip_suite=yes
        echo "integrate: accepting recorded green suite for $cand (${attest_age}s old, window ${attest_secs}s) — skipping the re-run"
      fi
    fi
  fi
  if [ -z "$skip_suite" ]; then
    local vrc=0 suite_log="$root/.comms/logs/integrate-${cand}.suite.log"
    suite_verify_candidate integrate "$root" "$cand" "$tw" "$suite_log" "$suite_cmd" "$name" "$instance" "$presence_record" "$suite_timeout" || vrc=$?
    # The ONE refusal that prints a result line: a driver waiting on a landing must be able to
    # tell "the suite hung and was killed" from "the suite is red" without parsing prose, and
    # the exit class alone is easy to lose through a wrapper. The EXIT trap still removes the
    # verification tree and drops the integrating lease, exactly as on a red suite.
    if [ "$vrc" = "$INTEGRATE_RC_SUITE_TIMEOUT" ]; then
      printf 'integrate-result v1 status=refused reason=suite_timeout cand=%s main_before=%s branch=%s timeout_secs=%s landing=%s\n' \
        "$cand" "$expected" "$(integrate_kv "$branch")" "$suite_timeout" "$(integrate_kv "$lb")"
    fi
    [ "$vrc" = 0 ] || integrate_fail "$vrc" "$SUITE_VERIFY_REASON"
  fi
  # Final occupancy guard — a checkout could have moved onto main DURING the
  # suite; the CAS must still never move a ref under a live working tree.
  local wt_list
  wt_list="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || integrate_fail "$INTEGRATE_RC_ENV" "integrate: cannot enumerate worktrees — refusing"
  printf '%s\n' "$wt_list" | grep -qxF "branch $lref" \
    && integrate_fail "$INTEGRATE_RC_OCCUPIED" "integrate: $lb is checked out somewhere — refusing (never-occupy-main)"
  # A refused update-ref is only a LOST COMPARE if main really moved. A lock file, a
  # permissions error or a full disk refuses it too, with main still at the expected tip, and a
  # driver that treats 16 as "re-run against the new tip" would retry a permanent fault that has
  # no new tip. (grok, driver-contract r1, advisory.)
  if ! git -C "$root" update-ref "$lref" "$cand" "$expected"; then
    local main_now
    # An UNREADABLE ref after the failure is not evidence that main moved: classify it as the
    # environment fault it is. (codex, driver-contract r2, advisory.)
    main_now="$(git -C "$root" rev-parse --verify "$lref" 2>/dev/null)" \
      || integrate_fail "$INTEGRATE_RC_ENV" "integrate: could not update $lref, and cannot read it back — nothing landed"
    [ "$main_now" = "$expected" ] \
      || integrate_fail "$INTEGRATE_RC_CAS_LOST" "integrate: $lb moved (CAS refused) — nothing landed; re-run to re-verify against the new tip"
    integrate_fail "$INTEGRATE_RC_ENV" "integrate: could not update $lref although it is still at $expected (a lock, permissions, or disk fault) — nothing landed"
  fi
  # Success path: clean up and clear the trap NOW, inside function scope, so the
  # process-exit path has nothing deferred left to evaluate.
  git -C "$root" worktree remove --force "$tw" >/dev/null 2>&1 || true
  # A healed occupant goes back ON main, which now points at the landed tip —
  # this is the fast-forward the self-heal promised. Failure to re-attach is not
  # a failed landing: report it and leave the checkout safely detached.
  if [ -n "$healed" ]; then
    # Re-attach only an occupant that is STILL the idle console we detached: if
    # someone committed there during the landing window, `checkout main` would
    # silently abandon those commits on an unreferenced HEAD. (grok, r1.)
    local heal_now
    heal_now="$(git -C "$healed" rev-parse HEAD 2>/dev/null || true)"
    if [ "$heal_now" != "$expected" ]; then
      printf '%s\n' "integrate: warning — $(integrate_oneline "$healed") moved to $heal_now during the landing; left detached (its commits are intact, re-attach by hand)"
    elif git -C "$healed" checkout "$lb" >/dev/null 2>&1; then
      printf '%s\n' "integrate: healed occupant $(integrate_oneline "$healed") fast-forwarded onto the new $lb"
    else
      printf '%s\n' "integrate: warning — could not re-attach $(integrate_oneline "$healed") to $lb; it is parked detached at $expected"
    fi
  fi
  # Same rule: only refresh a record that exists. Nothing here manufactures one.
  if [ -n "$name" ] && [ -n "$instance" ] && [ -f "$(presence_dir)/$name-$instance.json" ]; then
    "$SELF" presence beat --name "$name" --instance "$instance" --state working >/dev/null 2>&1 || true
  fi
  trap - EXIT
  local suite_kind
  if [ "$skip_suite" = docs ]; then
    suite_kind=skipped-docs
    echo "integrate: LANDED $cand as $lb (was $expected); docs-only skip, suite not run"
  elif [ -n "$skip_suite" ]; then
    suite_kind=attested
    echo "integrate: LANDED $cand as $lb (was $expected); green by attestation (${attest_age}s old)"
  else
    suite_kind=ran
    echo "integrate: LANDED $cand as $lb (was $expected); suite green at the landed OID"
  fi
  # THE RESULT LINE — exactly once, on success only, after the human line. A driver reads
  # this instead of the prose above. main_after is the value THIS landing wrote by CAS, not a
  # later read (another writer may have advanced main since). Versioned so the fields can
  # grow without breaking a parser that reads v1. Format: docs/COMMANDS.md.
  printf 'integrate-result v1 status=landed cand=%s main_before=%s main_after=%s branch=%s suite=%s landing=%s\n' \
    "$cand" "$expected" "$cand" "$(integrate_kv "$branch")" "$suite_kind" "$(integrate_kv "$lb")"
}

cmd_verify() {
  # verify init [--yes] [--force] [--update] — scaffold ci/verify.sh + ci/verify.steps and point
  #   suite-cmd at it. verify fresh [<rev>] — run suite-cmd against <rev> exactly as integrate
  #   would, in a throwaway checkout, without landing. (basis plan slice 0, generic-verify.)
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    init) verify_init "$@" ;;
    fresh) verify_fresh "$@" ;;
    status) verify_status "$@" ;;
    *) usage_err "verify: expected 'init', 'fresh' or 'status'" ;;
  esac
}

verify_is_shell_cmd() {  # <suite-cmd> — 0 when it LOOKS LIKE it needs a shell integrate does not use
  # A HINT for `verify status` and setup, never an authorization: no classifier can know an
  # executable's argument grammar (`grep -q > file` and `find … -exec test -x {} ;` are working
  # argv), so replacing an existing suite-cmd takes --replace-suite-cmd whatever this says.
  # (codex, generic-verify r1 then r2.) Judged per WORD of integrate's own whitespace split:
  # `grep -Eq OK|PASS results.txt` passes `OK|PASS` as one argument. A word that is an operator or
  # a redirection, a word with `&&`/`||` glued in (`npm test&&npm run lint`, grok r2), or a
  # leading VAR=value (argv[0] cannot be an assignment) looks like shell syntax.
  local w nm first=1 rc=1
  set -f
  for w in $1; do
    case "$w" in
      *'&&'*|*'||'*|'|'|'|&'|';'|'&'|'>'*|'<'*|[0-9]'>'*|[0-9]'<'*|'&>'*) rc=0; break ;;
    esac
    if [ "$first" = 1 ]; then
      first=0
      case "$w" in
        [A-Za-z_]*=*) nm="${w%%=*}"; case "$nm" in *[!A-Za-z0-9_]*) ;; *) rc=0; break ;; esac ;;
      esac
    fi
  done
  set +f
  return "$rc"
}

verify_set_suite_cmd() {  # <root> <replace> — point suite-cmd at ci/verify.sh, keeping every other line
  # A MISSING suite-cmd is filled in; an EXISTING one is replaced only when the operator said so
  # (--replace-suite-cmd). Whether the current command "works" is not decidable here, so no
  # heuristic may stand in for that decision. (codex, generic-verify r2, blocking.)
  local root="$1" replace="$2" cfg="$1/.comms/config" want="bash ci/verify.sh" cur tmp
  # config_scalar refuses a duplicate key and a read error, the two cases a blind rewrite would
  # turn into a lost line.
  cur="$(config_scalar "$root" suite-cmd)" || die "verify init: cannot read suite-cmd from $cfg (see above)"
  if [ "$cur" = "$want" ]; then echo "verify: suite-cmd already = $want"; return 0; fi
  if [ -n "$cur" ] && [ -z "$replace" ]; then
    if verify_is_shell_cmd "$cur"; then
      echo "verify: left suite-cmd = $cur — it looks like it needs a shell, which integrate does not use"
    else
      echo "verify: left suite-cmd = $cur"
    fi
    echo "verify: to point it at ci/verify.sh: comms.sh verify init --update --yes --replace-suite-cmd  (or edit .comms/config)"
    return 0
  fi
  mkdir -p "$root/.comms" || die "verify init: cannot create $root/.comms"
  if [ -f "$cfg" ]; then
    [ -r "$cfg" ] || die "verify init: $cfg is unreadable — refusing to rewrite it"
    tmp="$cfg.tmp.$$"
    # grep exits 1 when every line was a suite-cmd line (nothing to keep) and 2+ when it could not
    # READ the file. Only 0 and 1 may proceed: `|| true` here once published a config reduced to
    # the new suite-cmd after a read error. (codex, generic-verify impl r1, blocking.)
    local grc=0
    grep -v "^[[:space:]]*suite-cmd[[:space:]]*=" "$cfg" > "$tmp" || grc=$?
    [ "$grc" -le 1 ] || { rm -f "$tmp"; die "verify init: could not read $cfg (grep exit $grc) — left it unchanged"; }
    { printf 'suite-cmd = %s\n' "$want" >> "$tmp" && mv -f "$tmp" "$cfg"; } \
      || { rm -f "$tmp"; die "verify init: could not rewrite $cfg — left it unchanged"; }
  else
    printf 'suite-cmd = %s\n' "$want" > "$cfg" || die "verify init: could not write $cfg"
  fi
  if [ -n "$cur" ]; then echo "verify: suite-cmd: '$cur' -> '$want'"; else echo "verify: suite-cmd = $want"; fi
}

verify_status() {  # prints ok|missing|needs-shell <TAB> the current suite-cmd; setup reads this
  [ $# -eq 0 ] || usage_err "verify status: takes no arguments"
  local root cur
  root="$(main_repo_root)" || die "verify status: not inside a git repository"
  [ -n "$root" ] || die "verify status: not inside a git repository"
  cur="$(config_scalar "$root" suite-cmd)" || die "verify status: cannot read .comms/config (see above)"
  if [ -z "$cur" ]; then printf 'missing\t\n'
  elif verify_is_shell_cmd "$cur"; then printf 'needs-shell\t%s\n' "$cur"
  else printf 'ok\t%s\n' "$cur"; fi
}

verify_confirm() {  # <yes> <question> — 0 to proceed: --yes, or a y answer on a terminal
  [ -z "$1" ] || return 0
  [ -t 0 ] && [ -t 1 ] || die "verify init: no terminal to confirm on — re-run with --yes"
  local ans
  printf '%s [y/N] ' "$2"
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) return 0 ;; esac
  echo "verify: nothing written"; return 1
}

verify_init() {
  local yes="" force="" update="" replace=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1 ;; --force) force=1 ;; --update) update=1 ;; --replace-suite-cmd) replace=1 ;;
      -?*) usage_err "verify init: unknown option '$(clip "$1")'" ;;
      *) usage_err "verify init: unexpected argument '$(clip "$1")'" ;;
    esac; shift
  done
  local src top root dst steps tmp
  src="$(dirname "$SELF")/verify.sh"
  [ -f "$src" ] || die "verify init: the template is missing at $src — re-run install.sh"
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "verify init: not inside a git repository"
  root="$(main_repo_root)" || die "verify init: no main repo root"
  [ -n "$root" ] || die "verify init: no main repo root"
  dst="$top/ci/verify.sh"; steps="$top/ci/verify.steps"
  # Read the config BEFORE writing anything: a config that cannot be read must stop init with no
  # tracked file half-written. verify_set_suite_cmd re-reads it at the write.
  local cur_cmd
  cur_cmd="$(config_scalar "$root" suite-cmd)" || die "verify init: cannot read .comms/config (see above) — nothing written"
  if [ -n "$update" ]; then
    # Refresh the TEMPLATE only. The steps are the repo's own, and a hand-written ci/verify.sh
    # that happens to share the name is not ours to overwrite.
    [ -f "$dst" ] || die "verify init --update: there is no ci/verify.sh to update"
    grep -q '^# agent-comms verify v' "$dst" \
      || die "verify init --update: ci/verify.sh carries no agent-comms version header — refusing to overwrite a hand-written suite (verify init --force replaces it)"
    # Same authorization as a first write: this replaces a TRACKED file. (codex, impl r1.)
    local upd_q
    upd_q="Replace ci/verify.sh ($(sed -n 's/^# agent-comms verify //p' "$dst" | head -1)) with the $(sed -n 's/^# agent-comms verify //p' "$src" | head -1) template"
    # The question names EVERYTHING the yes authorizes: with --replace-suite-cmd that includes the
    # config line, and the operator must see which command is about to go. (grok, r3.)
    if [ -n "$replace" ] && [ "$cur_cmd" != "bash ci/verify.sh" ]; then
      if [ -n "$cur_cmd" ]; then upd_q="$upd_q, and REPLACE suite-cmd '$cur_cmd' with 'bash ci/verify.sh'"
      else upd_q="$upd_q, and set suite-cmd = bash ci/verify.sh"; fi
    fi
    verify_confirm "$yes" "$upd_q?" || return 0
    tmp="$dst.tmp.$$"
    { cp "$src" "$tmp" && chmod +x "$tmp" && mv -f "$tmp" "$dst"; } || { rm -f "$tmp"; die "verify init --update: could not write $dst"; }
    echo "verify: updated ci/verify.sh to $(sed -n 's/^# agent-comms verify //p' "$src" | head -1); ci/verify.steps unchanged"
    [ -z "$replace" ] || verify_set_suite_cmd "$root" "$replace"
    return 0
  fi
  [ -z "$force" ] && [ -e "$dst" ] \
    && die "verify init: ci/verify.sh already exists — use --update to refresh the template, or --force to replace it"
  # The PREVIEW, the generated steps and the runtime all come from the template itself: one
  # detector, so what init shows is what the suite will do.
  local plan prc=0 emitted
  plan="$( (cd "$top" && bash "$src" --plan) 2>&1)" || prc=$?
  printf '%s\n' "$plan"
  [ "$prc" = 0 ] || die "verify init: this setup cannot verify anything as it stands (see above) — fix it, or write ci/verify.steps by hand"
  emitted="$(cd "$top" && bash "$src" --emit-steps)" || die "verify init: could not derive the steps (see above)"
  local what="point suite-cmd at it"
  if [ -n "$cur_cmd" ] && [ "$cur_cmd" != "bash ci/verify.sh" ]; then
    if [ -n "$replace" ]; then what="REPLACE suite-cmd '$cur_cmd' with 'bash ci/verify.sh'"
    else what="leave suite-cmd '$cur_cmd' as it is (--replace-suite-cmd changes it)"; fi
  fi
  verify_confirm "$yes" "Write ci/verify.sh$([ -e "$steps" ] || printf ' + ci/verify.steps') and $what?" || return 0
  mkdir -p "$top/ci" || die "verify init: cannot create $top/ci"
  tmp="$dst.tmp.$$"
  { cp "$src" "$tmp" && chmod +x "$tmp" && mv -f "$tmp" "$dst"; } || { rm -f "$tmp"; die "verify init: could not write $dst"; }
  local wrote_steps=""
  # An existing steps file is the repo's own list: kept, even under --force.
  if [ ! -e "$steps" ]; then
    tmp="$steps.tmp.$$"
    { printf '%s\n' \
        '# ci/verify.steps — the checks ci/verify.sh runs, one shell command per line, in order.' \
        '# Each line runs as: bash -euo pipefail -c "<line>" with stdin closed. Keep each line one' \
        '# simple command (or a repo script): pipefail cannot see inside nested shells.' \
        '# Directive: "#@ provision: none" or "#@ provision: npm,uv" overrides lockfile detection.'
      printf '%s\n' "$emitted"; } > "$tmp" && mv -f "$tmp" "$steps" || { rm -f "$tmp"; die "verify init: could not write $steps"; }
    wrote_steps=1
  fi
  verify_set_suite_cmd "$root" "$replace"
  echo "verify: wrote ci/verify.sh${wrote_steps:+ and ci/verify.steps}"
  echo "verify: next — commit them, then prove the suite the way integrate will run it:"
  echo "verify:   git add ci/verify.sh ci/verify.steps && git commit -m 'chore: add verify suite' && comms.sh verify fresh"
  echo "verify: note — .comms/config is local; the suite-cmd line does not travel with the commit"
}

verify_fresh() {
  [ $# -le 1 ] || usage_err "verify fresh: expected at most one revision"
  local rev="${1:-HEAD}"
  case "$rev" in -?*) usage_err "verify fresh: unknown option '$(clip "$rev")'" ;; esac
  local root suite_cmd cand
  root="$(main_repo_root)" || integrate_fail "$INTEGRATE_RC_CONFIG" "verify: no main repo root (not inside a git repository, or it cannot be read)"
  [ -n "$root" ] || integrate_fail "$INTEGRATE_RC_CONFIG" "verify: no main repo root"
  suite_cmd="$(config_scalar "$root" suite-cmd)" \
    || integrate_fail "$INTEGRATE_RC_CONFIG" "verify: cannot read suite-cmd from .comms/config (see above)"
  [ -n "$suite_cmd" ] || integrate_fail "$INTEGRATE_RC_CONFIG" "verify: no 'suite-cmd = ...' in .comms/config — run: comms.sh verify init"
  local suite_timeout
  suite_timeout="$(suite_timeout_secs "$root")" \
    || integrate_fail "$INTEGRATE_RC_CONFIG" "verify: invalid suite-timeout-secs in .comms/config (see above)"
  cand="$(git rev-parse --verify "$rev^{commit}" 2>/dev/null)" || usage_err "verify fresh: cannot resolve '$(clip "$rev")'"
  if [ "$rev" = HEAD ] && [ -n "$(git status --porcelain -uno 2>/dev/null)" ]; then
    echo "verify: note — uncommitted changes are NOT verified; only the committed $cand is" >&2
  fi
  local name="${COMMS_PRESENCE_NAME:-}" instance="${COMMS_PRESENCE_INSTANCE:-}" rec=""
  if [ -n "$name" ] || [ -n "$instance" ]; then
    presence_validate_ids "$name" "$instance" || usage_err "verify fresh: invalid presence name/instance"
    rec="$(presence_dir)/$name-$instance.json"
  fi
  # Its OWN tree and log: a preflight must never share (and so never remove) a landing's
  # .integrate-* tree. (codex + grok, generic-verify plan r2.)
  # The LOG is per invocation too, not per commit: positive proof reads it, and two preflights of
  # one commit sharing a file could each take the other's completion line. (codex, impl r1.)
  local tw log vrc=0 run_id="$$-$RANDOM"
  tw="$root/.claude/worktrees/.verify-$run_id"
  log="$root/.comms/logs/verify-${cand}-${run_id}.suite.log"
  mkdir -p "$root/.claude/worktrees" 2>/dev/null || true
  # shellcheck disable=SC2064
  trap "git -C '$root' worktree remove --force '$tw' >/dev/null 2>&1 || true; rm -rf '$tw' 2>/dev/null || true" EXIT
  echo "verify: running suite-cmd against $cand in a fresh checkout (nothing will land)"
  suite_verify_candidate verify "$root" "$cand" "$tw" "$log" "$suite_cmd" "$name" "$instance" "$rec" "$suite_timeout" || vrc=$?
  git -C "$root" worktree remove --force "$tw" >/dev/null 2>&1 || true
  rm -rf "$tw" 2>/dev/null || true
  trap - EXIT
  [ "$vrc" != "$INTEGRATE_RC_SUITE_TIMEOUT" ] \
    || printf 'verify-result v1 status=refused reason=suite_timeout cand=%s timeout_secs=%s\n' "$cand" "$suite_timeout"
  [ "$vrc" = 0 ] || integrate_fail "$vrc" "$SUITE_VERIFY_REASON"
  echo "verify: suite green at $cand in a fresh checkout — integrate would accept this suite (nothing landed)"
  printf 'verify-result v1 status=verified cand=%s\n' "$cand"
}

# The runtime roots a review artifact never takes from the working tree unless the candidate
# commit TRACKS the path: the mailbox and its state (.comms), a project-local helper pin
# (.agent-comms), and in-checkout session worktrees (.claude/worktrees — a full second repo
# copy; relying on .gitignore alone let one walk into a sibling loop's artifact before 7dc08b4).
SNAPSHOT_RUNTIME_ROOTS=(.comms .agent-comms .claude/worktrees)

# snapshot_strip_runtime <repo> <temp-index> <candidate-commit-or-empty>
# Drops from the temp index every path under SNAPSHOT_RUNTIME_ROOTS that the CANDIDATE does not
# track, MECHANICALLY rather than trusting .gitignore: an artifact must never carry message bodies
# into a git object that could later be pushed. (An exclude PATHSPEC on the `add` cannot do this —
# `git add` reads it as naming an ignored path and fails the whole command.) Called ONCE with the
# whole root list as its pathspec; <repo> is the work tree being snapshotted.
# Paths the candidate DOES track stay, working-tree state and all, exactly like any other
# tracked file. Stripping the whole root used to delete a tracked `.comms/README.md` from every
# artifact, so a clean tree snapshotted as a synthetic commit whose only change was that
# deletion — its head_sha no longer named the candidate and the verdict could not cover it.
# (live, 2026-09-27.) "Untracked" is judged against the CANDIDATE, never the user's index: a
# mailbox file someone `git add`ed but never committed is still runtime state.
# `--ignore-submodules=none` on BOTH scans: diff filters gitlinks through per-submodule
# `ignore` settings, so a nested repo under .claude/worktrees mapped `ignore = all` in
# .gitmodules was staged as a gitlink yet invisible to the scan and its re-check alike.
# (codex, r1.)
# Fails CLOSED: any git error, or any untracked runtime path still present afterwards, is a
# non-zero return, and the caller refuses to mint the artifact.
snapshot_strip_runtime() {
  local repo="$1" idx="$2" cand="$3" base list left
  if [ -n "$cand" ]; then
    base="$cand"
  else
    # Unborn HEAD: nothing is tracked, so the empty tree makes every runtime path untracked.
    base="$(git -C "$repo" hash-object -t tree /dev/null 2>/dev/null)" && [ -n "$base" ] || return 1
  fi
  list="$(dirname "$idx")/strip.z"
  snapshot_untracked_runtime "$repo" "$idx" "$base" -z > "$list" || return 1
  if [ -s "$list" ]; then
    GIT_INDEX_FILE="$idx" git -C "$repo" update-index -z --force-remove --stdin < "$list" 2>/dev/null \
      || return 1
  fi
  left="$(snapshot_untracked_runtime "$repo" "$idx" "$base")" || return 1
  [ -z "$left" ]
}

# snapshot_untracked_runtime <repo> <temp-index> <base-tree-ish> [-z]
# The one query both the strip and its re-check use: runtime-root paths in the temp index that
# <base> does not have.
snapshot_untracked_runtime() {
  GIT_INDEX_FILE="$2" git -C "$1" diff-index --cached --no-renames --ignore-submodules=none \
    --diff-filter=A --name-only ${4:+"$4"} "$3" -- "${SNAPSHOT_RUNTIME_ROOTS[@]}" 2>/dev/null
}

cmd_snapshot() {
  # snapshot [create|list] — RETAIN the tree under review as a durable git object.
  #
  # A hash alone cannot resurrect the input, so this stores CONTENT: the working
  # tree (tracked edits and untracked files; untracked runtime state under
  # SNAPSHOT_RUNTIME_ROOTS excluded) is written as a real commit object without
  # touching the worktree, the index, or the stash.
  # That commit starts unreferenced and would be garbage-collected, so it is
  # anchored under refs/agent-comms/ — the anchor IS the retention, and without
  # it the artifact this prerequisite exists to keep silently evaporates.
  local sub="${1:-create}" with_base=false
  [ "${2:-}" = "--with-base" ] && with_base=true
  local root id
  # The reviewer's working directory IS the tree under review (runphase's review
  # prompt says so), and in a linked worktree that is NOT the main root — snapshotting
  # main_repo_root there would retain a tree nobody reviewed. (grok, live 2026-08-22.)
  root="$(live_tree_root)"
  [ -n "$root" ] || usage_err "snapshot: not inside a git repository"
  case "$sub" in
    list)
      git -C "$root" for-each-ref --format='%(refname:strip=3)' "$ARTIFACT_REF_NS" 2>/dev/null || true
      return 0 ;;
    create) ;;
    *) usage_err "snapshot: unknown argument '$(clip "$sub")' (create|list)" ;;
  esac
  # Build the snapshot in a THROWAWAY index, never the user's. `git stash
  # create` is the obvious tool and is wrong here: it silently drops untracked
  # files even with --include-untracked (verified on git 2.39), and a file added
  # this round is exactly what a reviewer reads. Caught by the harness.
  local idxdir idx tree parent
  idxdir="$(mktemp -d "${TMPDIR:-/tmp}/agent-comms-snap.XXXXXX")" || die "snapshot: cannot create a temp index"
  idx="$idxdir/index"
  parent="$(git -C "$root" rev-parse --verify -q HEAD 2>/dev/null || true)"
  if [ -n "$parent" ]; then
    GIT_INDEX_FILE="$idx" git -C "$root" read-tree "$parent" 2>/dev/null \
      || { rm -rf "$idxdir"; die "snapshot: cannot read HEAD into a temp index"; }
  fi
  GIT_INDEX_FILE="$idx" git -C "$root" add -A -- . 2>/dev/null \
    || { rm -rf "$idxdir"; die "snapshot: cannot stage the working tree"; }
  snapshot_strip_runtime "$root" "$idx" "$parent" \
    || { rm -rf "$idxdir"; die "snapshot: cannot exclude the mailbox from the artifact"; }
  tree="$(GIT_INDEX_FILE="$idx" git -C "$root" write-tree 2>/dev/null || true)"
  rm -rf "$idxdir"
  [ -n "$tree" ] || die "snapshot: cannot write the reviewed tree"
  # A clean tree IS HEAD. Wrapping it in a synthetic commit would mint a second
  # id for identical content and litter the ledger with synonyms, so return the
  # commit that already names it.
  if [ -n "$parent" ] && [ "$tree" = "$(git -C "$root" rev-parse -q --verify "$parent^{tree}" 2>/dev/null)" ]; then
    git -C "$root" update-ref "$ARTIFACT_REF_NS/$parent" "$parent" \
      || die "snapshot: could not anchor $(clip "$parent")"
    # A clean tree IS its own base: the artifact and the commit the (empty) diff
    # applies to are the same object.
    if [ "$with_base" = true ]; then printf '%s\t%s\n' "$parent" "$parent"; else printf '%s\n' "$parent"; fi
    return 0
  fi
  # Fixed identity and date make the id a pure content address: snapshotting an
  # unchanged tree twice returns the SAME artifact_id instead of littering the
  # ledger with synonyms for one artifact.
  id="$(
    export GIT_AUTHOR_NAME=agent-comms GIT_AUTHOR_EMAIL=agent-comms@localhost \
           GIT_COMMITTER_NAME=agent-comms GIT_COMMITTER_EMAIL=agent-comms@localhost \
           GIT_AUTHOR_DATE='1970-01-01T00:00:00Z' GIT_COMMITTER_DATE='1970-01-01T00:00:00Z'
    if [ -n "$parent" ]; then
      git -C "$root" commit-tree "$tree" -p "$parent" -m 'agent-comms reviewed artifact'
    else
      git -C "$root" commit-tree "$tree" -m 'agent-comms reviewed artifact'
    fi 2>/dev/null || true
  )"
  [ -n "$id" ] || die "snapshot: cannot record the reviewed artifact"
  git -C "$root" update-ref "$ARTIFACT_REF_NS/$id" "$id" \
    || die "snapshot: could not anchor $(clip "$id") — it would be garbage-collected"
  # The base rides out of the SAME operation that minted the artifact ($parent was
  # captured before write-tree), so a concurrent commit in a shared checkout cannot
  # desync the pair — the race that made hand-typed head_sha values lie. (field
  # report #6.)
  if [ "$with_base" = true ]; then printf '%s\t%s\n' "$id" "${parent:-}"; else printf '%s\n' "$id"; fi
}


prompt_surface_files() {
  local root="$1" p rel glob hit name
  for p in \
    ".agent-comms/runphase.sh:$HOME/.agent-comms/runphase.sh" \
    ".claude/commands/auto.md:$HOME/.claude/commands/auto.md" \
    ".claude/commands/read-from-codex.md:$HOME/.claude/commands/read-from-codex.md" \
    ".claude/commands/send-to-codex.md:$HOME/.claude/commands/send-to-codex.md"
  do
    rel="${p%%:*}"; glob="${p#*:}"
    if [ -n "$rel" ] && [ -f "$root/$rel" ]; then printf '%s\n' "$root/$rel"
    elif [ -f "$glob" ]; then printf '%s\n' "$glob"
    else printf 'MISSING %s\n' "$rel"
    fi
  done
  # THE BAR THE CHILD ACTUALLY READS. The deleted Codex skills used to carry the verdict
  # discipline, and hashing them was how `prompt-version` noticed a bar edit. After S4-3 the
  # bar lives in the loopspec fragments that `build_grok_prompt` inlines at runtime — so they
  # must be hashed HERE too, or editing the verdict discipline leaves `prompt-version`
  # unchanged and grades POOL ACROSS DIFFERENT STANDARDS. Same three-tier precedence as
  # runphase's `fragment_file`, so a project-local or global pin is what gets measured, exactly
  # like the one the reviewer resolves. (codex, S4-3 r1, blocking; grok concurred.)
  for name in verdict-discipline holistic-rereview; do
    hit=""
    for p in "$root/.agents/loopspec-fragments/$name.md" \
             "${AGENT_COMMS_HOME:-$HOME/.agent-comms}/loopspec-fragments/$name.md" \
             "$(dirname "$SELF")/../docs/loopspec/fragments/$name.md"; do
      [ -f "$p" ] && { hit="$p"; break; }
    done
    if [ -n "$hit" ]; then printf '%s\n' "$hit"; else printf 'MISSING %s.md\n' "$name"; fi
  done
}

cmd_prompt_version() {
  local list=false root f
  while [ $# -gt 0 ]; do
    case "$1" in
      --list) list=true ;;
      -?*)    usage_err "prompt-version: unknown option '$(clip "$1")'" ;;
      *)      usage_err "prompt-version: unexpected argument '$(clip "$1")'" ;;
    esac
    shift
  done
  root="$(main_repo_root)"; [ -n "$root" ] || usage_err "prompt-version: not inside a git repository"
  if [ "$list" = true ]; then prompt_surface_files "$root"; return 0; fi
  # A missing file contributes its marker line, so a surface appearing or
  # disappearing changes the version — silence there would be a false "unchanged".
  {
    while IFS= read -r f; do
      case "$f" in
        MISSING\ *) printf '%s\n' "$f" ;;
        *) printf '%s\n' "${f##*/}"; cat "$f" ;;
      esac
    done <<< "$(prompt_surface_files "$root")"
  } | hash_stdin
}

# ---------- version: which kernel and which templates are installed ----------
#
# READ, never recomputed from the installed tree: an installed copy cannot say which commit it
# came from, and a project-local pin sits inside the USER'S repository, whose HEAD is not the
# kernel's. install.sh writes `install-stamp` beside the helpers of every scope it installs, from
# the source it copied. A value that is absent, duplicated or malformed reads as `unknown`.
version_stamp_field() {  # <stamp> <key> -> the key's value when it appears exactly once
  awk -v k="$2" 'index($0, k "=") == 1 { n++; v = substr($0, length(k) + 2) } END { if (n == 1) print v }' "$1" 2>/dev/null
}
version_is_commit() {  # a full sha-1 or sha-256 object id, optionally `-dirty`
  printf '%s' "$1" | grep -Eqx '([0-9a-f]{40}|[0-9a-f]{64})(-dirty)?'
}
version_is_template() { printf '%s' "$1" | grep -Eqx 'sha256:[0-9a-f]{64}'; }

cmd_version() {
  local json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=true ;;
      -?*)    usage_err "version: unknown option '$(clip "$1")'" ;;
      *)      usage_err "version: unexpected argument '$(clip "$1")'" ;;
    esac
    shift
  done
  local dir top v kernel=unknown tmpl=unknown source=none
  dir="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd -P)" || dir=""
  if [ -n "$dir" ] && [ -f "$dir/install-stamp" ]; then
    source=install
    # A stamp that cannot be READ (permissions, removed between the test and the read) is an
    # unknown value, never an aborted command: `version` always answers. (codex, r1, blocking.)
    v="$(version_stamp_field "$dir/install-stamp" kernel_commit)" || v=""
    version_is_commit "$v" && kernel="$v"
    v="$(version_stamp_field "$dir/install-stamp" template_version)" || v=""
    version_is_template "$v" && tmpl="$v"
  elif [ -n "$dir" ] && top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
       && [ "$(cd "$top" 2>/dev/null && pwd -P)/helpers" = "$dir" ] && [ -f "$top/install.sh" ]; then
    # Run straight from an agent-comms SOURCE checkout: the kernel is that checkout's commit,
    # `-dirty` when its helpers differ from it. Nothing installs templates from here, so the
    # template version stays unknown rather than naming files no driver is reading.
    source=checkout
    v="$(git -C "$top" rev-parse --verify -q HEAD 2>/dev/null)" || v=""
    if [ -n "$v" ]; then
      local dirt; dirt="$(git -C "$top" status --porcelain --untracked-files=all -- helpers 2>/dev/null)" || dirt="?"
      [ -z "$dirt" ] || v="$v-dirty"
      version_is_commit "$v" && kernel="$v"
    fi
  fi
  # Every value is validated to a fixed alphabet above, so neither form needs escaping.
  if [ "$json" = true ]; then
    printf '{"kernel_commit":"%s","template_version":"%s","source":"%s"}\n' "$kernel" "$tmpl" "$source"
  else
    printf 'kernel_commit: %s\ntemplate_version: %s\nsource: %s\n' "$kernel" "$tmpl" "$source"
  fi
}

# reply-check <file|-> — classify a reply body, with a completion contract callers can trust.
# Exit 10 = a normal answer; 11 = a provider API ERROR envelope (its message printed on stdout,
# after a `verdict: error` sentinel line); 12 = UNDECIDABLE (python3 missing, the classifier did
# not complete, or the file is unreadable) with the cause on stderr. The exit status and the
# stdout sentinel are a PAIR: a code without its matching sentinel is undecidable, so a truncated
# or crashed classifier can never be read as a clean answer. (codex, acp-compat-gate plan r2/r3.)
#
# WHY A BODY CHECK, AND WHY IT IS STRUCTURAL. Reproduced live 2026-09-08 (codex-cli 0.153.4 with an
# unrecognised `model`): acpx exits 0 and hands back, as the whole answer,
#   Warning: Model metadata for `gpt-6-astra` not found. ...
#   {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"..."}}
# and even acpx's json stream closes the turn `stopReason: end_turn` — the only provider-native
# marker is a codex-private `threadStatus: systemError` meta event the quiet transport never
# surfaces. So the reply text IS the only signal both transports share.
#
# The test is the SHAPE of the whole body, never a substring: after dropping leading `Warning:`
# lines and a trailing `[acpx] tokens:` line, what remains must parse as ONE JSON object whose
# `error` member is an object carrying a string `message`, with no top-level keys beyond the
# envelope's own (`type`, `status`, `code`, `request_id`). An answer that QUOTES an error, or any
# prose around one, is an answer. `-` reads stdin; a stamped message (leading `---` frontmatter) is
# skipped to its body so the check reads the same file on every side of the broker.
cmd_reply_check() {
  local src="${1:-}"
  [ -n "$src" ] || die "reply-check: file argument (or -) required"
  if [ "$src" != "-" ] && [ ! -r "$src" ]; then
    echo "comms.sh: reply-check: cannot read '$src' — undecidable" >&2; return 12
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "comms.sh: reply-check: python3 unavailable — undecidable" >&2; return 12
  fi
  # `-` is MATERIALISED before python runs: the interpreter own script arrives on stdin (the
  # heredoc below), so reading the payload from sys.stdin would see EOF and call every piped body
  # "an answer" — the first cut of this verb bug. (regression-tested via the stdin positive case.)
  local tmp="" out="" rc=0
  if [ "$src" = "-" ]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/comms-reply.XXXXXX")" || { echo "comms.sh: reply-check: mktemp failed — undecidable" >&2; return 12; }
    cat > "$tmp" || { rm -f "$tmp"; echo "comms.sh: reply-check: could not buffer stdin — undecidable" >&2; return 12; }
    src="$tmp"
  fi
  out="$(python3 - "$src" <<'PYRC'
import json, re, sys
try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(3)          # unreadable -> undecidable at the bash layer
lines = text.replace("\r\n", "\n").split("\n")
# A stamped message: skip the frontmatter, the body is what the reader sees.
if lines and lines[0].strip() == "---":
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            lines = lines[i + 1:]
            break
    else:
        print("verdict: answer"); sys.exit(10)
# Codex prefixes a model-metadata warning; the acp.sh stub appends the acpx usage line.
while lines and (lines[0].strip() == "" or lines[0].startswith("Warning:")):
    lines.pop(0)
while lines and (lines[-1].strip() == "" or lines[-1].startswith("[acpx] tokens:")):
    lines.pop()
body = "\n".join(lines).strip()
def answer():
    print("verdict: answer"); sys.exit(10)
if not body:
    answer()
try:
    obj = json.loads(body)
except ValueError:
    answer()
if not isinstance(obj, dict):
    answer()
err = obj.get("error")
if not isinstance(err, dict) or not isinstance(err.get("message"), str):
    answer()
if set(obj) - {"error", "type", "status", "code", "request_id"}:
    answer()
if "type" in obj and obj["type"] != "error":
    answer()
# ONE clean line: json.loads has DECODED escapes, so the message may carry tabs, CRs or any other
# control character. The note this feeds is written into result.json and read back per line, so
# every control/whitespace run collapses to one space here as well as being escaped by the writer.
# The sentinel is emitted ONLY here, after classification is complete. (codex, r1/r3.)
msg = " ".join(re.sub(r"[\x00-\x1f\x7f]", " ", err["message"]).split())
etype = err.get("type")
print("verdict: error")
print(f"{etype}: {msg}" if isinstance(etype, str) and etype else msg)
sys.exit(11)
PYRC
)" || rc=$?
  [ -n "$tmp" ] && rm -f "$tmp"
  # The exit status and the sentinel must AGREE, or the classifier did not complete as contracted.
  # Parameter expansion, not a pipe: provider error text is unbounded, and `head -1` on it
  # exited 141 in codex's probe. (codex, sigpipe r1 advisory.)
  local first; first="${out%%$'\n'*}"
  case "$rc" in
    10) if [ "$first" = "verdict: answer" ]; then return 10; fi ;;
    11) if [ "$first" = "verdict: error" ]; then printf '%s\n' "$out"; return 11; fi ;;
  esac
  local clipped; clipped="$(clip "$first")"
  echo "comms.sh: reply-check: classifier did not complete (rc=$rc, sentinel=$clipped) — undecidable" >&2
  return 12
}

# error-envelope <file|-> — the historical predicate, now a thin adapter over reply-check so the
# two cannot drift. Exit 0 (printing the provider's message) iff the body is a provider API error;
# 1 for an answer; 2 for an unreadable file; 3 for undecidable. Kept for tests and diagnostics;
# broker/consult/canary use reply-check's 10/11/12 contract directly.
cmd_error_envelope() {
  local src="${1:-}"
  [ -n "$src" ] || die "error-envelope: file argument (or -) required"
  if [ "$src" != "-" ] && [ ! -r "$src" ]; then
    echo "comms.sh: error-envelope: cannot read '$src'" >&2; return 2
  fi
  local out rc=0
  out="$(cmd_reply_check "$src" 2>/dev/null)" || rc=$?
  case "$rc" in
    11) printf '%s\n' "$out" | tail -n +2; return 0 ;;
    10) return 1 ;;
    *)  return 3 ;;
  esac
}

cmd_validate() {
  local file="${1:-}"
  [ -n "$file" ] || die "validate: file argument required"
  [ -f "$file" ] || die "validate: no such file: $file"
  local errors=""
  if [ "$(head -1 "$file" | tr -d '\r')" != "---" ]; then
    errors="${errors}  missing opening --- frontmatter delimiter\n"
  fi
  local fm_end
  fm_end="$(awk '{sub(/\r$/, "")} NR>1 && $0=="---" {print NR; exit}' "$file")"
  if [ -z "$fm_end" ]; then
    errors="${errors}  missing closing --- frontmatter delimiter\n"
  fi
  local field val
  for field in type from timestamp; do
    val="$(frontmatter_field "$file" "$field")"
    [ -n "$val" ] || errors="${errors}  missing required field: $field\n"
  done
  local workflow from_agent msg_type
  workflow="$(frontmatter_field "$file" workflow)"
  from_agent="$(frontmatter_field "$file" from)"
  msg_type="$(frontmatter_field "$file" type)"
  # from: is an open set validated against the registry — an unregistered sender
  # could otherwise inject mail no reader/state path can attribute.
  local profile_history=0 profile_packet profile_req="" profile_error=""
  profile_packet="$(frontmatter_field "$file" agent_profile)"
  if [ -n "$profile_packet" ]; then
    if [ "$msg_type" = review-feedback ]; then
      profile_req="$(find_message_by_id "$(frontmatter_field "$file" in-reply-to)" || true)"
    fi
    if profile_error="$(profile_helper message-check "$file" ${profile_req:+"$profile_req"} 2>&1)"; then
      [ "$msg_type" != review-feedback ] || profile_history=1
    else
      errors="${errors}  invalid agent profile binding: $profile_error\n"
    fi
  elif [ -n "$(frontmatter_field "$file" agent_profile_digest)$(frontmatter_field "$file" review_family)$(frontmatter_field "$file" review_model)" ]; then
    errors="${errors}  profile metadata is missing its agent_profile binding\n"
  elif [ "$msg_type" = review-feedback ]; then
    case "$from_agent" in claude|codex|grok|gemini|claude-review|codex-review|grok-review|gemini-review) ;;
      *) errors="${errors}  custom review reply is missing its agent_profile binding\n" ;;
    esac
  fi
  if [ -n "$from_agent" ] && [ "$profile_history" != 1 ] && ! registry_has "$from_agent"; then
    errors="${errors}  from '$from_agent' is not a registered agent (registered: $(registry_agents))\n"
  fi
  # A REVIEW identity authors exactly one thing: the review-feedback its broker stamps. Every
  # writer (send, panel legs, the broker, ask, shadow) passes here, so this is the one place the
  # rule lives.
  if [ -n "$from_agent" ] && registry_is_review "$from_agent" && [ "$msg_type" != "review-feedback" ]; then
    errors="${errors}  from '$from_agent' is a review-only identity — it may author only review-feedback, not '${msg_type:-<no type>}'\n"
  fi
  # `review_provider` means different things by DIRECTION, so each direction has one rule.
  # On a reply it names the SENDER's provider — the fact compose counts — so it must agree with
  # reply_provider: required from a review identity, and a driver's is its own name,
  # unconditionally. On a request it names the RECIPIENT's provider; it is helper-stamped
  # (stamp_review_provider) and bound to the real target by send, shadow and runphase, so all
  # validate can say is that a present value is a provider.
  val="$(frontmatter_field "$file" review_provider)"
  if [ "$profile_history" = 1 ]; then
    local recorded_provider
    recorded_provider="$(profile_helper binding-field "$profile_packet" name)"
    if [ -n "$val" ] && [ "$val" != "$recorded_provider" ]; then
      errors="${errors}  review_provider disagrees with the recorded execution profile\n"
    fi
  elif [ "$msg_type" = "review-feedback" ] && [ -n "$from_agent" ] && registry_has "$from_agent"; then
    local rp_have rp_want
    rp_have="$val"
    rp_want="$(reply_provider "$file")"
    if registry_is_review "$from_agent"; then
      # A twin's provider is FIXED (claude-review runs on claude), so its stamp must name exactly
      # that provider: anything else is a forged or corrupted reply, never a history to honour.
      if ! is_provider "$rp_have"; then
        errors="${errors}  review-feedback from review identity '$from_agent' carries no valid review_provider (got '${rp_have:-<none>}')\n"
      elif [ "$rp_have" != "$(registry_provider "$from_agent")" ]; then
        errors="${errors}  review-feedback from '$from_agent' claims review_provider '$rp_have', but '$from_agent' runs on '$(registry_provider "$from_agent")'\n"
      fi
    elif [ -n "$rp_have" ] && [ "$rp_have" != "$rp_want" ]; then
      errors="${errors}  review-feedback from driver '$from_agent' claims review_provider '$rp_have' — a driver's provider is its own name\n"
    fi
  elif [ -n "$val" ]; then
    is_provider "$val" || errors="${errors}  review_provider '$val' is not a supported provider ($SUPPORTED_AGENTS)\n"
  fi
  if [ -n "$workflow" ]; then
    for field in phase round max-rounds; do
      val="$(frontmatter_field "$file" "$field")"
      [ -n "$val" ] || errors="${errors}  workflow message missing field: $field\n"
    done
    # Only the reviewer->author leg carries a verdict. LOOPSPEC binds this by
    # TYPE (review-feedback), not by sender — either agent can be the reviewer
    # (reverse-topology loops), and requests/error-lane messages are verdict-free
    # in both directions.
    if [ "$msg_type" = "review-feedback" ]; then
      val="$(frontmatter_field "$file" verdict)"
      [ -n "$val" ] || errors="${errors}  workflow review-feedback missing field: verdict\n"
    fi
    # LOOPSPEC soft rule: COMMENT never appears in autonomous rounds — warn, so
    # a reviewer sliding into non-verdicts surfaces before it stalls a loop.
    if [ "$(norm_verdict_value "$(frontmatter_field "$file" verdict)")" = "COMMENT" ]; then
      echo "warning: verdict COMMENT inside a workflow loop — COMMENT is reserved for manual exchanges; use APPROVE or REQUEST_CHANGES" >&2
    fi
    # Protocol v2 soft requirements — warn, don't reject, so in-flight loops
    # started on older templates survive a mid-loop upgrade.
    [ -n "$(frontmatter_field "$file" thread)" ] || \
      echo "warning: workflow message has no thread field — concurrent loops in this workspace can collide" >&2
    [ -n "$(frontmatter_field "$file" message_id)" ] || \
      echo "warning: workflow message has no message_id field — replies cannot be threaded via in-reply-to" >&2
  fi
  # LOOPSPEC soft rule (any message, loop or not): unrecognized verdict values
  # warn — typos surface early — but never reject; the synonym set may grow
  # backward-tolerantly.
  local any_verdict
  any_verdict="$(frontmatter_field "$file" verdict)"
  if [ -n "$any_verdict" ]; then
    case "$(norm_verdict_value "$any_verdict")" in
      APPROVE|REQUEST_CHANGES|COMMENT) ;;
      *) echo "warning: unrecognized verdict value '$any_verdict' — expected APPROVE/REQUEST_CHANGES (or the pass/fail synonyms)" >&2 ;;
    esac
  fi
  if [ -n "$fm_end" ]; then
    local body
    body="$(awk -v start="$fm_end" 'NR>start && NF {print; exit}' "$file")"
    [ -n "$body" ] || errors="${errors}  body below frontmatter is empty\n"
  fi
  if [ -n "$errors" ]; then
    echo "validate: $file is malformed:" >&2
    printf '%b' "$errors" >&2
    return 1
  fi
  echo "valid: $file"
}

cmd_archive() {
  local as="" files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) need_value "archive" $# "$1"; shift; as="$1" ;;
      *) files+=("$1") ;;
    esac
    shift
  done
  [ -n "$as" ] || die "archive: --as <agent> is required (registered: $(registry_agents))"
  [ "${#files[@]}" -gt 0 ] || die "archive: at least one file required"
  local root inbox
  root="$(cmd_root)"; inbox="$(inbox_for "$as")"
  mkdir -p "$root/archive"
  local f resolved
  for f in "${files[@]}"; do
    # Accept bare names or paths, but only ever move out of the caller's own inbox.
    resolved="$root/$inbox/$(basename "$f")"
    case "$f" in
      */*) [ "$f" -ef "$resolved" ] 2>/dev/null || [ ! -e "$f" ] || die "archive: refusing to archive $f — not in your inbox ($root/$inbox)" ;;
    esac
    if [ -f "$resolved" ]; then
      mv "$resolved" "$root/archive/"
      echo "archived: $(basename "$f")"
    else
      echo "already archived or absent (no-op): $(basename "$f")"
    fi
  done
}



# deliver_headless <target> [message-file] — spawn a detached peer turn via
# runphase.sh instead of typing into a pane. Direction-aware: replies TO the
# driving session are a designed no-op (the driver reads them when the peer
# turn exits) — runphase marks that direction in the child's env via
# COMMS_HEADLESS_PICKUP. Any other target spawns a turn for that provider.
# Contract: never hard-fails, always says what happened.
deliver_headless() {
  # <target> [msgfile] — spawn a detached turn, or run it in the FOREGROUND when
  # COMMS_WAIT=1. A detached child can be reaped the moment the managed shell command
  # that spawned it ends, which is normal inside an agent sandbox — so an agent driving
  # this helper needs a synchronous mode or its turns vanish. (Field report from a codex
  # session, 2026-08-26.)
  local target="$1" msgfile="${2:-}"
  # (pickup is resolved in cmd_deliver, BEFORE transport selection — see the note there.
  # Duplicating it here would be a second owner for one rule, and the copy that ran after
  # transport is exactly what let headless_ok die first.)
  local rp="$(dirname "$SELF")/runphase.sh"
  export COMMS_RUNPHASE_VIA="${COMMS_RUNPHASE_VIA:-}"
  if [ ! -x "$rp" ]; then
    echo "warning: this loop needs the headless runner but runphase.sh was not found next to comms.sh — message written for manual pickup (re-run install.sh)"
    return 0
  fi
  if [ -z "$msgfile" ]; then
    # Bare `deliver <target>` retry surface: newest pending message for this
    # workspace. || true: a missing inbox dir fails find under pipefail and
    # would otherwise errexit-kill the helper with zero output.
    msgfile="$(find "$(cmd_root)/$(inbox_for "$target")" -maxdepth 1 -type f -name "$(cmd_workspace)_*" 2>/dev/null | sort | tail -1 || true)"
  fi
  if [ -z "$msgfile" ] || [ ! -f "$msgfile" ]; then
    echo "warning: headless delivery found no pending message for $target — nothing spawned"
    return 0
  fi
  if [ "${COMMS_WAIT:-}" = "1" ]; then
    local fg_dir
    fg_dir="$(cmd_root)/logs/$(safe_name "$(basename "$msgfile" .md)").$(date +%s).fg$$"
    mkdir -p "$fg_dir" || die "send --wait: cannot create $fg_dir"
    echo "running $target in the foreground (no detach) — run dir: $fg_dir"
    if "$rp" run --message "$msgfile" --dir "$fg_dir" --agent "$target" >>"$fg_dir/runner.log" 2>&1; then
      echo "completed: $target finished; the reply is in the inbox"
      return 0
    fi
    echo "warning: $target's foreground turn failed — see $fg_dir/result.json"
    return 0
  fi
  local out
  if out="$("$rp" spawn --agent "$target" --message "$msgfile" 2>&1)"; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out"
    echo "warning: headless spawn FAILED — the message is safely on disk; retry with 'comms.sh send --to $target <file>'"
  fi
}


runphase_available() { [ -x "$(dirname "$SELF")/runphase.sh" ]; }

# suppression_ok <agent> — can `--no-deliver` keep its promise for this agent, and over which
# transport? Echoes the `--via` argument the caller must pass (empty = no transport flag needed)
# and returns non-zero when suppression is impossible.
#
# HONEST SCOPE: this is shadow's gate, not a shared one. `runphase` still INLINES the equivalent
# `via != acp` / `reviewer-consult-only` check at its own boundary and never calls this. They
# agree today because shadow passes the transport, not because they share a function — so they
# CAN drift, and the boundary that matters is runphase's, which fails closed. Do not read this
# comment as "one accessor for both". (grok, capability-registry r1.)
#
# Delivery is suppressible IFF the turn is PARENT-BROKERED, and that is a property of
# (agent, transport), NOT a per-agent constant — which is the bug this replaces: `shadow`
# gated on the registry string alone and so refused codex on the very path where runphase
# WOULD have honoured the flag (`[ "$via" != "acp" ]` is checked first there).
#
# Do NOT "fix" this by adding `reviewer-consult-only` to claude/codex in the registry: that
# same string is read by runphase's NON-ACP guard, so it would let `--no-deliver` through on
# the self-send path, where the child writes to an inbox itself and suppression is a lie.
suppression_ok() {  # <provider> -> echoes "acp" | "" ; rc 1 if suppression cannot be honoured
  case "$(cmd_agents --supported | awk -v a="$1" -F'\t' '$1==a {print $2}')" in
    *reviewer-consult-only*) printf ''; return 0 ;;   # brokered on every path already
  esac
  # Otherwise only ACP makes it honourable: the parent stamps and delivers, the child never sends.
  if acp_supports "$1"; then printf 'acp'; return 0; fi
  return 1
}

acp_supports() {  # <provider> — can an ACP turn actually run here for this provider?
  local acp_sh; acp_sh="$(dirname "$SELF")/acp.sh"
  [ -x "$acp_sh" ] || return 1
  "$acp_sh" supports "$1" >/dev/null 2>&1
}

# headless_ok <provider> — may this provider take the headless transport? Only a provider that is
# parent-brokered WITHOUT ACP may: headless used to route a SELF-SENDING child, and that arm is
# gone (step 4, S4-2). grok qualifies via its registry marker; claude/codex must use ACP, and
# runphase fails them closed. Gating every rung on ONE predicate is what stops `transport` handing
# out a route the runner then refuses. (codex, S4-2 plan, blocking.)
headless_ok() {
  case "$(cmd_agents --supported | awk -v a="$1" -F'\t' '$1==a {print $2}')" in
    *reviewer-consult-only*) return 0 ;;
  esac
  return 1
}

# AN UNKNOWN TRANSPORT IS REFUSED, not degraded. Warn-and-degrade was not self-consistent:
# `transport` printed `mailbox` on stdout while `COMMS_DELIVERY` stayed `cmux`, so `deliver`
# and `send` still said "NOT spawned … fix and retry" even with ACP available, and templates
# that capture stdout never saw the stderr warning. Refusing matches how headless-for-claude
# already fails, and closes the wider hole that `COMMS_DELIVERY=foo` silently took the default
# ladder. (codex + grok, S4-4 r1.)
#
# ENFORCED AT THE ROUTER TOO, not only here. `cmd_send` does `del_out="$(cmd_deliver …)"` and
# `cmd_deliver` does `route="$(cmd_transport …)"`; on bash 3.2 — the shell these helpers claim
# to support, and the macOS default — a `die` in that position is SWALLOWED. Verified: with
# only this check, `send` printed the refusal on stderr, then continued to "message written for
# manual pickup", `RESULT: manual … fix and retry`, and exited 0. A validation a second caller
# can bypass is the bug shape this codebase keeps rediscovering, so the router calls this
# BEFORE dispatching any routing verb, in the main shell where no substitution can eat it.
# (grok, S4-4 r2, advisory — a real defect, not a nit.)
require_known_transport() {
  case "${COMMS_DELIVERY:-}" in
    ""|acp|headless|mailbox) return 0 ;;
    cmux) die "transport: COMMS_DELIVERY=cmux — the cmux pane transport was REMOVED in step 4; unset it, or choose acp | headless (grok only) | mailbox" ;;
    *)    die "transport: COMMS_DELIVERY='${COMMS_DELIVERY}' is not a known transport — choose acp | headless (grok only) | mailbox" ;;
  esac
}

cmd_transport() {
  # transport <agent> [--loop] — print the transport that would actually be used:
  # headless | acp | mailbox.
  #
  # ONE place decides, so the templates never re-implement surface detection and
  # the eventual "ACP by default" flip is a reordering here rather
  # than an edit in every command. `mailbox` is the honest last resort: the file
  # is written and nobody is nudged, which is what stranded a real consult when no
  # Codex pane was running.
  local agent="" mode=consult
  while [ $# -gt 0 ]; do
    case "$1" in
      --loop)    mode=loop ;;
      --consult) mode=consult ;;
      -?*)       usage_err "transport: unknown option '$(clip "$1")'" ;;
      *)         [ -z "$agent" ] || usage_err "transport: one agent only"; agent="$1" ;;
    esac
    shift
  done
  [ -n "$agent" ] || usage_err "transport: an agent name is required (registered: $(registry_agents))"
  require_agent "$agent" "transport"
  # Routing is a property of the PROVIDER; every rung below reads it, never the identity. A
  # review identity (claude-review) routes exactly as its provider (claude) does.
  local prov
  prov="$(registry_provider "$agent")" || die "transport: cannot resolve the provider of '$agent'"

  # HEADLESS IS NO LONGER UNIVERSAL. It used to route a SELF-SENDING child, and that arm is gone
  # (step 4, S4-2), so it is valid only for a provider that is parent-brokered WITHOUT ACP. grok is
  # that provider today; claude/codex must go through ACP or fail closed in runphase. Keyed on the
  # registry marker rather than the name, so a second brokered provider needs no edit here.
  if [ "${COMMS_DELIVERY:-}" = "headless" ]; then
    headless_ok "$prov" && { printf 'headless\n'; return 0; }
    die "transport: COMMS_DELIVERY=headless is not available for '$agent' — its self-send path was removed in step 4; use ACP"
  fi
  if [ "${COMMS_DELIVERY:-}" = "acp" ]; then printf 'acp\n'; return 0; fi
  # `mailbox` was only ever an OUTPUT of this function — the honest last resort where the file is
  # written and nobody is nudged. Accepting it as an INPUT gives a caller a way to ask for exactly
  # that, which is what a test harness needs: no pane, no spawned child, no network. The suite
  # used to get that property by asking for a transport slated for deletion and stubbing its
  # binary, which made it load-bearing for every unrelated section. (contraction step 4, S4-1.)
  if [ "${COMMS_DELIVERY:-}" = "mailbox" ]; then printf 'mailbox\n'; return 0; fi

  local caps
  caps="$(cmd_agents --supported | awk -v a="$prov" -F'\t' '$1==a {print $2}')"

  # NOT gated here: both callers gate first — the router for the CLI verb, and cmd_deliver
  # at its own top. A third copy would be a rule with three owners. (grok, S4-4 r4.)

  # LOOPS ARE ACP-FIRST, then headless (grok only), then mailbox. A loop is unattended work by
  # definition, so it must not depend on an open pane — but the ordering here is
  # driven by cost, measured on one real review turn in this repo:
  #
  #   headless (cold spawn) ~115,000 fresh input tokens per turn
  #   ACP (warm session)    ~1,061
  #
  # A cold spawn rebuilds context from nothing every round. Only a named ACP session makes
  # round N pay a delta rather than re-sending a large uncached prefix per model call.
  # headless stays available and opt-in (COMMS_DELIVERY / --via), grok only.
  if [ "$mode" = "loop" ]; then
    if acp_supports "$prov"; then printf 'acp\n'; return 0; fi
    # Fall back to headless only when ACP is genuinely unavailable: flipping the default
    # must not strand every loop on an install where runphase.sh never landed. There is no
    # pane arm below this any more — cmux was deleted in step 4 (S4-4).
    if runphase_available && headless_ok "$prov"; then printf 'headless\n'; return 0; fi
    # A LOOP MUST NOT FALL BACK TO A PANE for a provider whose self-send path is gone. Deleting
    # headless for claude/codex (step 4, S4-2) made this ladder drop straight through to a pane —
    # the SAME self-send model in another costume: a nudge tells a live agent to read and reply
    # itself, with no parent stamping and no pinned artifact. cmux is gone entirely now (S4-4);
    # `mailbox` is the honest, unattended outcome and is visible to status.
    printf 'mailbox\n'; return 0
  fi
  # The live-pane arm that used to win here is gone with cmux (S4-4).
  # No pane. ACP is synchronous and needs none, which beats queueing into an inbox
  # nobody is watching — the exact case that stranded a real consult. Checked BEFORE
  # the headless fallback because a headless-only agent (grok) has no pane by
  # definition and would otherwise never reach here.
  #
  # Consults only: a loop turn must be able to EXECUTE (read files, run git) and that
  # permission policy is unbuilt, so silently re-routing a loop would change its
  # semantics rather than just its transport.
  if [ "$mode" = "consult" ] && acp_supports "$prov"; then printf 'acp\n'; return 0; fi
  case "$caps" in *interactive*) ;; *) headless_ok "$prov" && { printf 'headless\n'; return 0; } ;; esac
  printf 'mailbox\n'
}

cmd_deliver() {
  local target="${1:-}" msgfile="${2:-}"
  # Gated HERE as well as at the router: `panel dispatch` reaches delivery by calling cmd_send
  # as a FUNCTION, so an argv-only gate misses it. The right question is "does this path call
  # cmd_send/cmd_deliver?", not "is the verb in the router list". (grok + codex, S4-4 r3.)
  require_known_transport
  require_agent "$target" "deliver"
  # PICKUP IS DECIDED BEFORE TRANSPORT. A reply addressed to the session driving this turn
  # needs no nudge at all — it is read when the turn exits — so the transport question is moot.
  # Asking it first was a LIVE BUG on the grok-headless path the templates advertise: the
  # driver exports COMMS_DELIVERY=headless, the parent's broker sends to claude or codex, and
  # `cmd_transport` -> `headless_ok` DIED before deliver_headless could consult pickup.
  # broker_stamp has already copied the reply into the inbox, so the turn still looked answered
  # while the send failed — bash 3.2 swallows the die and prints a "re-run install.sh" lie,
  # 4.4+ fails the send outright. Deleting runphase's `export COMMS_DELIVERY=headless` in r1
  # only stopped it INTRODUCING the flag; it never unset an INHERITED one, so "0 live exports"
  # was true and beside the point. ONE check, before routing, so no transport can bypass it.
  # (grok, S4-2 implement r3, blocking.)
  if [ "$target" = "${COMMS_HEADLESS_PICKUP:-}" ]; then
    echo "headless mode: reply written for pickup — the driving session reads it when this peer turn ends (no nudge needed)"
    return 0
  fi
  # ONE decision point: `transport` owns the routing rules so deliver, the templates,
  # and the docs cannot drift apart. But the MODE is a property of the message, not of
  # the caller: hardcoding --loop here silently reclassified consults and one-shot
  # sends as loops, so a live-pane consult spawned headless instead of nudging the
  # pane. `workflow:` already means "autonomous loop" in the protocol, so it is the
  # authoritative signal. (codex, transport-flip round 1.)
  local route mode_flag="" classify="$msgfile"
  if [ -z "$classify" ]; then
    classify="$(find "$(cmd_root)/$(inbox_for "$target")" -maxdepth 1 -type f -name "$(cmd_workspace)_*" 2>/dev/null | sort | tail -1 || true)"
  fi
  if [ -n "$classify" ] && [ -f "$classify" ] && [ -n "$(frontmatter_field "$classify" workflow)" ]; then
    mode_flag="--loop"
  fi
  route="$(cmd_transport "$target" $mode_flag)"
  case "$route" in
    headless)
      case "$(registry_provider "$target")" in
        claude|codex) ;;
        *) echo "note: '$target' is a headless-only agent — routing delivery via runphase" ;;
      esac
      deliver_headless "$target" "$msgfile"
      return 0
      ;;
    acp)
      # The acp route was reachable from `transport` but fell through this case to
      # manual pickup, so the docs described behaviour deliver did not have.
      # (codex, transport-flip round 2.)
      COMMS_RUNPHASE_VIA=acp deliver_headless "$target" "$msgfile"
      return 0
      ;;
    *)
      if [ "${COMMS_DELIVERY:-}" = "mailbox" ]; then
        # AN ASKED-FOR MAILBOX IS A SUCCESS, NOT A BROKEN INSTALL. Manual pickup is the POINT
        # here: the file is written and nobody is nudged. (codex, S4-1 r1, blocking.)
        echo "note: COMMS_DELIVERY=mailbox — message written for manual pickup, nobody was nudged"
      else
        # cmux DELETED (S4-4). The pane nudge was self-send by another name: it typed a slash
        # command into someone else's terminal and called that delivery. What is left when no
        # runner can take the message is the honest outcome — it is on disk, nobody was nudged.
        echo "warning: no runner available for $target; message written for manual pickup"
      fi
      return 0
      ;;
  esac
}

cmd_status() {
  local root ws
  root="$(cmd_root)"; ws="$(cmd_workspace)"
  echo "workspace: $ws"
  echo "comms root: $root"
  local latest
  latest="$(sorted_message_files "$root/archive" "$ws" "" "" newest | head -1 || true)"
  if [ -n "$latest" ]; then
    echo "latest archived: $(basename "$latest")"
    local f
    for f in workflow phase round max-rounds verdict; do
      local v
      v="$(frontmatter_field "$latest" "$f")"
      [ -n "$v" ] && echo "  $f: $v"
    done
  else
    echo "latest archived: (none)"
  fi
  local dir label a reg_status
  reg_status="$(registry_agents)" || exit 2
  for a in $reg_status; do
    dir="to-$a"
    label="$(sorted_message_files "$root/$dir" "$ws" "" "" newest | head -3 | sed 's/^/    /' || true)"
    echo "pending in $dir: $(find "$root/$dir" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null | wc -l | tr -d ' ')"
    [ -n "$label" ] && echo "$label"
  done
  # Loud recovery surface: a pending message whose thread never got a real nudge
  # is a stalled loop the operator must act on — make it impossible to miss.
  local sf owes deliv st target since now age_s mid pending
  sf="$(ls -t "$root/state/${ws}_"*.json 2>/dev/null | head -1 || true)"
  if [ -n "$sf" ]; then
    st="$(json_get "$sf" status)"
    owes="$(json_get "$sf" awaiting_from)"
    deliv="$(json_get "$sf" last_delivery)"
    if registry_has "$owes"; then target="$owes"; else target="<agent>"; fi
    since="$(json_get "$sf" awaiting_since_epoch)"
    case "$since" in ''|*[!0-9]*) since="$(date +%s)" ;; esac
    now="$(date +%s)"
    age_s=$(( now - since ))
    mid="$(json_get "$sf" last_sent)"
    pending=""
    if registry_has "$owes"; then
      [ -f "$root/$(inbox_for "$owes")/$mid.md" ] && pending="$root/$(inbox_for "$owes")/$mid.md"
    fi
    # "delivered" means the keystroke sequence was accepted, not that the peer
    # consumed the file. An aged file still in the target inbox is stronger
    # evidence than the notification outcome and must remain visible.
    if ! state_settled "$st" && [ -n "$pending" ] && [ "$age_s" -gt 900 ]; then
      echo "ACTION NEEDED: $(basename "$pending") is still unread after $(( age_s / 60 ))m (last_delivery=$deliv). Nudge $target directly, or re-send with 'comms.sh send'."
    # Live headless outcomes are not operator-action cases: spawned = turn in
    # flight, completed = reply is (or was) in the inbox for the driver to read,
    # held = the operator paused deliberately, pickup = designed reply-to-driver
    # no-op. failed/timeout from a headless turn DO shout, like a failed nudge.
    elif ! state_settled "$st" && [ -n "$deliv" ] \
         && [ "$deliv" != "delivered" ] && [ "$deliv" != "spawned" ] \
         && [ "$deliv" != "completed" ] && [ "$deliv" != "held" ] && [ "$deliv" != "pickup" ]; then
      # NOT keyed on the CURRENT COMMS_DELIVERY. status reports a DURABLE fact from the state
      # file, and the env at read time says nothing about how the delivery actually happened — a
      # `manual` left by a failed nudge would be excused simply because the operator happens
      # to be in mailbox mode now. The honest fix is a distinct outcome token recorded AT DELIVERY
      # (grok: "a new outcome token, or status treating requested mailbox like `pickup`"), which
      # is a change to what deliver WRITES, not to what status READS. Filed rather than faked.
      # (grok, S4-1 r2 — explicitly not this increment's ship gate.)
      echo "ACTION NEEDED: last delivery was '$deliv' — $owes was NOT nudged. Do not retry from an unchanged sandbox; use manual pickup, or re-send with 'comms.sh send'."
    fi
  fi
}

# ---------- protocol v2: thread state (.comms/state/<ws>_<thread>.json) ----------

state_dir() { echo "$(cmd_root)/state"; }

# ---------- thread retirement: the caller's explicit "this thread is terminal" ----------
# `complete` is NOT terminal — a loop marks a round complete and resumes — and an idle thread,
# an exited queue owner or an old timestamp only say that nothing is running NOW. None of them
# may authorize deleting a thread's warm review copies. Retirement is a separate, durable record
# the caller writes when IT knows the work is over (basis: a terminal task); `clean mounts
# --thread` accepts nothing else. Keyed through a digest of the RAW thread, never safe_name alone
# (`a/b` and `a_b` share one safe_name), and the raw thread is stored inside and compared exactly.
retire_thread_ok() {  # <thread> — non-empty and one line (it is stored and compared as a line)
  case "$1" in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  return 0
}
retire_marker() {  # <raw thread> -> the marker path
  printf '%s/retired/%s-%s' "$(state_dir)" "$(safe_name "$1" | cut -c1-40)" "$(printf 'retired\0%s' "$1" | hash_stdin)"
}
retire_state() {  # <raw thread> -> 0 retired (prints retired_at) | 3 not retired | 4 present but unverifiable
  local f first at=""
  f="$(retire_marker "$1")"
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 3; fi
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 4
  { IFS= read -r first && IFS= read -r at; } < "$f" 2>/dev/null || true
  [ "$first" = "thread=$1" ] || return 4
  printf '%s' "${at#retired_at=}"
}
cmd_state_retire() {  # retire|unretire|retired <thread>
  local sub="$1" f rc=0 at=""; shift
  [ "$#" -eq 1 ] || usage_err "state $sub: exactly one thread argument is required"
  retire_thread_ok "$1" || usage_err "state $sub: the thread must be non-empty and a single line"
  f="$(retire_marker "$1")"
  at="$(retire_state "$1")" || rc=$?
  case "$sub" in
    retired)
      case "$rc" in
        0) echo "retired retired_at=$at" ;;
        3) echo "not retired" ;;
        *) echo "state retired: a marker exists at $f but does not name this thread — unverifiable" >&2 ;;
      esac
      return "$rc" ;;
    retire)
      case "$rc" in
        0) echo "already retired (retired_at=$at)"; return 0 ;;
        4) die "state retire: a marker exists at $f but does not name this thread — refusing to overwrite it" ;;
      esac
      mkdir -p "$(dirname "$f")" || die "state retire: cannot create $(dirname "$f")"
      if ! { printf 'thread=%s\nretired_at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$f.tmp.$$" \
             && command mv -f "$f.tmp.$$" "$f"; }; then
        rm -f "$f.tmp.$$" 2>/dev/null || true
        die "state retire: could not write $f"
      fi
      echo "retired: its review mounts may now be removed with 'comms.sh clean mounts --thread <thread>' (dry run; --yes applies)" ;;
    unretire)
      case "$rc" in
        3) echo "not retired"; return 0 ;;
        4) die "state unretire: a marker exists at $f but does not name this thread — refusing to remove it" ;;
      esac
      rm -f "$f" || die "state unretire: could not remove $f"
      echo "unretired" ;;
  esac
}

# (safe_name is defined above cmd_workspace — thread/message/cache values all
# become filename components, so anything outside [A-Za-z0-9._-] maps to '_'.)

# Minimal JSON string escaping so embedded quotes/backslashes can't produce
# invalid state files.
json_escape() {
  # COMPLETE string escaping for the one-key-per-line JSON our writers emit and json_get
  # reads back with a per-line regex. The old one-liner handled only backslash and quote, so
  # a value carrying a DECODED control character — a provider's error message with a `\t`
  # or `\r` escape, decoded by the envelope predicate — wrote invalid JSON into result.json
  # (codex, consult-error-envelope r1, blocking). Tab, CR and LF become their escapes; any
  # other C0 control (never legitimate in a note) is dropped rather than left to corrupt
  # the file. Lines are joined as `\n` so a value stays on ONE line for json_get.
  printf '%s' "$1" \
    | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g; s/'"$(printf '\t')"'/\\t/g; s/'"$(printf '\r')"'/\\r/g' \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'
}

json_get() {  # json_get <file> <key> — one key per line in our writer, so sed suffices
  sed -n 's/.*"'"$2"'": "\([^"]*\)".*/\1/p' "$1" | head -1
}

# state_update_from <message-file> <delivery-outcome> [run-dir] — derive thread
# state from an outbound workflow message's frontmatter. The ONLY writers of
# state are this (via send), runphase's exit mirror, and `state complete`;
# readers must treat it as advisory ground truth. run-dir (headless spawns)
# gives `stalled` a live pid to watchdog.
# state_write_expected <thread> <workflow> — the SINGLE definition of "this
# message gets thread state". state_update_from gates its write on it, and
# cmd_send tells the spawned runner the answer with it. runphase's
# update_thread_state waits for that write; if the writer's rule and the
# waiter's expectation ever drift apart, the runner stalls for its whole budget
# on a file that is never coming (measured: 6s per turn, 35% of the suite).
state_write_expected() { [ -n "$1" ] && [ -n "$2" ]; }

state_update_from() {
  local mf="$1" outcome="${2:-unknown}" run_dir="${3:-}" awaiting_override="${4:-}"
  local thread wf
  thread="$(frontmatter_field "$mf" thread)"
  wf="$(frontmatter_field "$mf" workflow)"
  state_write_expected "$thread" "$wf" || return 0   # one-shot or pre-v2 message: no state
  local ws fm_ws phase round maxr loopr from awaiting_from mid dir
  # Key on the RESOLVED workspace — the same resolver every reader uses — so a
  # divergent frontmatter workspace value can't make the state file invisible.
  ws="$(cmd_workspace)"
  fm_ws="$(frontmatter_field "$mf" workspace)"
  [ -n "$fm_ws" ] && [ "$fm_ws" != "$ws" ] && \
    echo "warning: message workspace '$fm_ws' differs from resolved workspace '$ws' — state keyed on '$ws'" >&2
  phase="$(frontmatter_field "$mf" phase)"
  round="$(frontmatter_field "$mf" round)"
  maxr="$(frontmatter_field "$mf" max-rounds)"
  # The loop's real budget rides through the capped plan phase in loop-rounds;
  # state keeps it too so a restart/compaction can restore N without the archived
  # plan message. (codex, panel r1.)
  loopr="$(frontmatter_field "$mf" loop-rounds)"
  from="$(frontmatter_field "$mf" from)"
  # The EXPLICIT send --to target is authoritative for who owes the next message. A
  # complement of the sender (claude<->codex) was a two-party assumption: wrong at three
  # agents, and wrong for a review identity, whose driver shares its provider. The one
  # caller always passes the target, so no target means "unknown", never a guess.
  awaiting_from="${awaiting_override:-unknown}"
  mid="$(frontmatter_field "$mf" message_id)"
  [ -n "$mid" ] || mid="$(basename "$mf" .md)"
  dir="$(state_dir)"
  # Every failure in here must be non-fatal — state is advisory ground truth and
  # must never abort send between delivery and the inbound archive (e.g. when
  # .comms/state exists as a FILE, or is unwritable).
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "warning: cannot create state dir $dir — skipping thread-state write" >&2
    return 0
  fi
  # Non-fatal write: a state hiccup must never abort send between delivery and
  # the inbound archive (that is the half-applied desync state exists to prevent).
  # last_run_dir precedes last_delivery so runphase's exit-time rewrite (which
  # replaces the last_delivery line and may insert a session-id field before
  # it) keeps the JSON valid with last_delivery as the final field.
  printf '{\n  "workspace": "%s",\n  "thread": "%s",\n  "workflow": "%s",\n  "phase": "%s",\n  "round": "%s",\n  "max_rounds": "%s",\n  "loop_rounds": "%s",\n  "status": "in-progress",\n  "awaiting_from": "%s",\n  "awaiting_since": "%s",\n  "awaiting_since_epoch": "%s",\n  "last_sent": "%s",\n  "last_run_dir": "%s",\n  "last_delivery": "%s"\n}\n' \
    "$(json_escape "$ws")" "$(json_escape "$thread")" "$(json_escape "$wf")" \
    "$(json_escape "$phase")" "$(json_escape "$round")" "$(json_escape "$maxr")" "$(json_escape "$loopr")" \
    "$awaiting_from" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" \
    "$(json_escape "$mid")" "$(json_escape "$run_dir")" "$outcome" \
    > "$dir/$(safe_name "$ws")_$(safe_name "$thread").json" \
    || echo "warning: could not write thread state for '$thread' — continuing" >&2
}


# ---------- idle threads: listed with evidence, marked legacy only by name ----------
# basis DESIGN "Nothing is closed by age": an idle thread is a question for the operator, never a
# verdict. `state idle` only REPORTS; `state legacy <id>...` marks exactly the ids the operator
# names, re-checking each one at marking time and writing the evidence into the state file. There
# is no path from age to a mark — no flag, no "all" — and legacy is not `complete`: it only takes
# the thread out of `stalled` and the status shout. A later send on the thread rewrites the state
# as in-progress, so a legacy mark never blocks a thread from resuming.
STATE_IDLE_DAYS_DEFAULT=14

state_settled() { [ "$1" = complete ] || [ "$1" = legacy ]; }   # <status> — the ONE "not live" test

state_idle_days() {  # <value> -> the day count, normalised (08 is eight, not a bad octal)
  case "$1" in ''|*[!0-9]*) usage_err "state: --days needs a whole number of days (got '$(clip "$1")')" ;; esac
  [ "${#1}" -le 5 ] || usage_err "state: --days $(clip "$1") is out of range (1..36500)"
  local d=$((10#$1))
  { [ "$d" -ge 1 ] && [ "$d" -le 36500 ]; } || usage_err "state: --days $d is out of range (1..36500)"
  printf '%s' "$d"
}

# <epoch> -> CCYYMMDDhhmm.SS in UTC, the portable `touch -t` form. The caller runs `touch` under the
# same TZ=UTC0: local time has an hour that happens twice at a DST fall-back, and `touch -t` would
# have to guess which one the cutoff meant.
epoch_touch_stamp() {
  TZ=UTC0 date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null
}

# state_message_threads <dir> <maxdepth> [ref-file] — the safe_name'd `thread:` of every message
# file under <dir> (only those modified after <ref-file> when one is given), one per line. FAILS
# (non-zero) when the walk or a read cannot complete: a message that could not be read is activity
# this cannot see, and an unseen reply must never make a thread look idle.
# Depth 2 from .comms covers the mailbox proper: root drafts, the to-*/ inboxes and the flat
# archive/. Deeper copies (a reply kept in a .comms/logs/<run>/ dir) are deliberately out of scope:
# every delivery of that reply also lands in an inbox, and the state file's mtime moves with it.
state_message_threads() {
  local dir="$1" depth="$2" ref="${3:-}" list f
  local -a batch=() newer=()
  [ -d "$dir" ] || return 0
  [ -n "$ref" ] && newer=(-newer "$ref")
  list="$(mktemp "${TMPDIR:-/tmp}/agent-comms-idle.XXXXXX")" || return 1
  if ! find "$dir" -maxdepth "$depth" -type f -name '*.md' ${newer[@]+"${newer[@]}"} -print0 >"$list" 2>/dev/null; then
    rm -f "$list"; return 1
  fi
  # Batched so a large archive cannot overflow one argv (an exec failure would read as a scan
  # failure). Plain "${batch[@]}", never a "${a[@]:i:n}" slice: bash 3.2 joins a quoted slice into
  # ONE word when IFS lacks a space.
  while IFS= read -r -d '' f; do
    batch+=("$f")
    [ "${#batch[@]}" -lt 200 ] && continue
    state_thread_lines "${batch[@]}" || { rm -f "$list"; return 1; }
    batch=()
  done <"$list"
  rm -f "$list"
  [ "${#batch[@]}" -eq 0 ] || state_thread_lines "${batch[@]}" || return 1
  return 0
}

state_thread_lines() {  # <file>... — the safe_name'd frontmatter thread of each; non-zero on an unreadable file
  local out f
  # The value is read by the SAME rule `send` used to name the state file (frontmatter_field),
  # so trailing whitespace or a CRLF cannot make a message miss its own thread.
  # Readability is checked first: awk implementations differ on whether an unopenable input is
  # fatal, and an unread message must fail the scan everywhere.
  for f in "$@"; do [ -r "$f" ] || return 1; done
  out="$(frontmatter_field --each thread "$@" 2>/dev/null)" || return 1
  [ -z "$out" ] || printf '%s\n' "$out" | sed '/^$/d' | safe_name_lines
  return 0
}

# state_idle_table <root> <cutoff-epoch> <id>... — "<id>\t<recent>\t<unread>" per id: whether any
# message on that thread was written after the cutoff, and how many sit unread in an inbox. A
# message's thread matches a state id when the id ENDS in "_<safe thread>": the id is
# "<safe ws>_<safe thread>" and `_` may occur in either part, so this can over-match (a thread
# looks active when it is not) but never under-match — the direction that can only withhold a
# mark. Any workspace's message counts: activity is activity. Fails when a scan fails.
state_idle_table() {
  local root="$1" cutoff="$2" ref recent unread d stamp; shift 2
  ref="$(mktemp "${TMPDIR:-/tmp}/agent-comms-idle-ref.XXXXXX")" || return 1
  recent="$ref.recent"; unread="$ref.unread"
  stamp="$(epoch_touch_stamp "$cutoff")" || stamp=""
  if [ -z "$stamp" ] || ! TZ=UTC0 touch -t "$stamp" "$ref" 2>/dev/null \
      || ! state_message_threads "$root" 2 "$ref" >"$recent"; then
    rm -f "$ref" "$recent" "$unread"; return 1
  fi
  : >"$unread"
  for d in "$root"/to-*/; do
    [ -d "$d" ] || continue
    state_message_threads "${d%/}" 1 >>"$unread" || { rm -f "$ref" "$recent" "$unread"; return 1; }
  done
  printf '%s\n' "$@" | awk -v R="$recent" -v U="$unread" '
    BEGIN { while ((getline t < R) > 0) if (t != "") r[t] = 1
            while ((getline t < U) > 0) if (t != "") u[t]++ }
    function ends(id, t) { return length(id) > length(t) + 1 && substr(id, length(id) - length(t)) == "_" t }
    $0 != "" { rec = 0; un = 0
      for (t in r) if (ends($0, t)) rec = 1
      for (t in u) if (ends($0, t)) un += u[t]
      printf "%s\t%s\t%s\n", $0, rec, un }'
  rm -f "$ref" "$recent" "$unread"
}

# state_last_activity <state-file> — the later of the recorded send time and the file's mtime (a
# runphase exit rewrite or a `complete` moves only the mtime). Non-zero when the mtime cannot be
# read: file_mtime answers 0 then, which would read as "idle since 1970".
state_last_activity() {
  local mt since
  mt="$(file_mtime "$1")"
  case "$mt" in ''|0|*[!0-9]*) return 1 ;; esac
  since="$(json_get "$1" awaiting_since_epoch)"
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  [ "${#since}" -le 12 ] && [ "$since" -gt "$mt" ] && mt="$since"
  printf '%s' "$mt"
}

# state_idle_rows <days> <id>... — the ONE idleness judgement, shared by the report and the mark.
# One tab-separated line per id: <kind> <id> <idle_days> <last_iso> <status> <awaiting> <unread>,
# kind = idle | active | settled | unknown | missing. Idle = not settled, and neither a state change
# nor a message on the thread for <days> days. A failed message scan fails the whole call: nothing
# is judged idle on partial evidence.
state_idle_rows() {
  local days="$1"; shift
  local root dir now cutoff table id f act st rec un row
  root="$(cmd_root)"; dir="$root/state"; now="$(date +%s)"; cutoff=$(( now - days * 86400 ))
  table="$(state_idle_table "$root" "$cutoff" "$@")" || return 1
  # Every field is non-empty (`?` when unknown): tab is IFS WHITESPACE, so `read` would collapse
  # an empty field and shift every later one into the wrong name.
  while IFS=$'\t' read -r id rec un; do
    [ -n "$id" ] || continue
    f="$dir/$id.json"
    [ -f "$f" ] || { printf 'missing\t%s\t?\t?\t?\t?\t?\n' "$id"; continue; }
    # A state file that cannot be read, or carries no status, is UNKNOWN: its send time and status
    # are part of the evidence, and a missing piece must never default toward idle.
    if [ ! -r "$f" ] || ! st="$(json_get "$f" status)" || [ -z "$st" ]; then
      printf 'unknown\t%s\t?\t?\t?\t?\t%s\n' "$id" "$un"; continue
    fi
    # Settled is decided by status alone and needs no clock: most state files are complete.
    if state_settled "$st"; then printf 'settled\t%s\t?\t?\t%s\t?\t%s\n' "$id" "$st" "$un"; continue; fi
    if act="$(state_last_activity "$f")"; then
      if [ "$rec" != 0 ] || [ "$act" -gt "$cutoff" ]; then row=active; else row=idle; fi
      printf '%s\t%s\t%s\t%s' "$row" "$id" "$(( (now - act) / 86400 ))" "$(mtime_iso "$act")"
    else
      printf 'unknown\t%s\t?\t?' "$id"
    fi
    act="$(json_get "$f" awaiting_from)"
    printf '\t%s\t%s\t%s\n' "${st:-?}" "${act:-?}" "$un"
  done <<<"$table"
}

state_all_ids() {  # every state id in the mailbox, across ALL workspaces (idle threads outlive branches)
  local f
  for f in "$(state_dir)"/*.json; do [ -f "$f" ] && basename "$f" .json; done
  return 0
}

state_days_arg() {  # <verb> <args...> — shared --days parsing; prints "days" then each other arg
  local verb="$1" days="$STATE_IDLE_DAYS_DEFAULT"; shift
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) need_value "state $verb" $# "$1"; shift; days="$(state_idle_days "$1")" || exit 2 ;;
      --days=*) days="$(state_idle_days "${1#--days=}")" || exit 2 ;;
      -*) usage_err "state $verb: unknown option '$(clip "$1")'" ;;
      *) rest+=("$1") ;;
    esac
    shift
  done
  printf '%s\n' "$days"
  [ "${#rest[@]}" -eq 0 ] || printf '%s\n' "${rest[@]}"
}

cmd_state_idle() {  # state idle [--days N] — report only
  local parsed days rows n=0 total kind id d iso st aw un
  parsed="$(state_days_arg idle "$@")" || exit 2
  days="${parsed%%$'\n'*}"
  [ "$parsed" = "$days" ] || usage_err "state idle: takes no ids (usage: state idle [--days N]) — it only reports"
  local -a ids=()
  while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done < <(state_all_ids)
  total="${#ids[@]}"
  if [ "$total" -gt 0 ]; then
    rows="$(state_idle_rows "$days" "${ids[@]}")" \
      || die "state idle: could not read every message file under $(cmd_root) — refusing to call anything idle on partial evidence"
    while IFS=$'\t' read -r kind id d iso st aw un; do
      case "$kind" in
        idle) n=$((n + 1))
          printf 'idle id=%s idle_days=%s last_activity=%s status=%s awaiting=%s unread=%s\n' \
            "$id" "$d" "$iso" "${st:-?}" "${aw:-?}" "$un" ;;
        unknown) echo "state idle: $id: last activity unreadable — not listed" >&2 ;;
      esac
    done <<<"$rows"
  fi
  echo "state idle: $n of $total thread(s) idle for ${days}+ days (no state change and no message on the thread since $(mtime_iso "$(( $(date +%s) - days * 86400 ))")). Nothing was changed; mark with 'comms.sh state legacy [--days $days] <id>...'"
}

# state_mark_legacy <days> <id> — judge ONE named id and mark it; prints the outcome, non-zero
# when refused. The hold (a hard link to the judged inode) is released on every path.
state_mark_legacy() {
  local days="$1" id="$2" f held tmp snap mt row kind rid d iso st aw un ev now_iso
  f="$(state_dir)/$id.json"
  [ -f "$f" ] || { echo "refused: $id: no such thread state" >&2; return 1; }
  # HOLD the inode being judged, snapshot it, judge, and swap only if nothing moved. `send`
  # rewrites a state file IN PLACE (`>`), so a send landing between the last check and the rename
  # writes the HELD inode — which the post-rename check sees, and undoes.
  held="$f.held.$$"; tmp="$f.legacy.$$"
  if ! ln "$f" "$held" 2>/dev/null || ! snap="$(cat "$held" 2>/dev/null)" || ! mt="$(file_mtime "$held")"; then
    rm -f "$held"; echo "refused: $id: cannot read or hold the thread state" >&2; return 1
  fi
  # Judged into a variable first, then split: an `IFS=... read < <(cmd)` prefix leaks the tab-only
  # IFS into the process substitution under bash 3.2.
  row="$(state_idle_rows "$days" "$id")" || row=fail
  IFS=$'\t' read -r kind rid d iso st aw un <<<"$row" || kind=fail
  case "$kind" in
    idle) ;;
    settled) rm -f "$held"; echo "refused: $id: already $st" >&2; return 1 ;;
    active) rm -f "$held"; echo "refused: $id: not idle for $days days (last state activity $iso, or a message on the thread since)" >&2; return 1 ;;
    unknown) rm -f "$held"; echo "refused: $id: state or activity unreadable — cannot show it is idle" >&2; return 1 ;;
    *) rm -f "$held"; echo "refused: $id: could not read every message file — cannot show it is idle" >&2; return 1 ;;
  esac
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ev="idle ${d}d when marked: last state activity $iso, no message on the thread in the $days days before $now_iso, $un unread in inboxes; was status=${st:-?} awaiting=${aw:-?}"
  # The evidence goes right after the status line, never at the end: runphase's exit mirror
  # rewrites the LAST field (last_delivery), so the tail must stay as send wrote it.
  # Values reach awk through ENVIRON, never `-v`: `-v` re-interprets backslash escapes, which
  # would undo json_escape. (claude-review, slice0b r1.)
  if ! printf '%s\n' "$snap" | LEG_EV="$(json_escape "$ev")" LEG_AT="$now_iso" \
        LEG_PS="$(json_escape "$st")" LEG_PA="$(json_escape "$aw")" awk '
      !done && /"status": "[^"]*"/ { sub(/"status": "[^"]*"/, "\"status\": \"legacy\""); print
        printf "  \"legacy_marked_at\": \"%s\",\n  \"legacy_prior_status\": \"%s\",\n  \"legacy_prior_awaiting\": \"%s\",\n  \"legacy_evidence\": \"%s\",\n", ENVIRON["LEG_AT"], ENVIRON["LEG_PS"], ENVIRON["LEG_PA"], ENVIRON["LEG_EV"]
        done = 1; next }
      { gsub(/"awaiting_from": "[^"]*"/, "\"awaiting_from\": \"none\""); print }' >"$tmp" 2>/dev/null \
      || ! grep -q '"status": "legacy"' "$tmp" 2>/dev/null; then
    rm -f "$held" "$tmp"; echo "refused: $id: could not write the mark" >&2; return 1
  fi
  # Keep the file's mtime: marking is not thread activity, and the evidence must stay stable.
  touch -r "$held" "$tmp" 2>/dev/null || true
  # Pre-check: the path still names the held inode, unchanged since it was judged.
  if [ ! "$f" -ef "$held" ] || [ "$(cat "$held" 2>/dev/null)" != "$snap" ] || [ "$(file_mtime "$held")" != "$mt" ]; then
    rm -f "$held" "$tmp"; echo "refused: $id: the thread state changed while it was being marked — re-run 'state idle'" >&2; return 1
  fi
  mv "$tmp" "$f" || { rm -f "$held" "$tmp"; echo "refused: $id: could not write the mark" >&2; return 1; }
  # Post-check: a send that wrote the held inode in the window between the pre-check and the rename
  # is put back — the newer state wins over the mark. The guarantee is "an IN-PLACE writer (send's
  # state_update_from) is caught", not "every writer is": a temp-file-plus-rename writer (`state
  # complete`, runphase's exit mirror) landing in the same window swaps in a new inode this check
  # never sees, and a writer that opened the old inode before the rename but writes only after this
  # check is also missed. State writers take no lock, so neither can be closed from here; both need
  # a thread that was active moments ago, which the re-judge above already refuses. (claude-review r3.)
  if [ "$(cat "$held" 2>/dev/null)" != "$snap" ] || [ "$(file_mtime "$held")" != "$mt" ]; then
    if mv "$held" "$f" 2>/dev/null; then
      echo "refused: $id: a send wrote the thread state while it was being marked — its state was kept" >&2
    else
      rm -f "$held"
      echo "refused: $id: a send wrote the thread state while it was being marked, and restoring it failed — the legacy mark is in place; check 'state get'" >&2
    fi
    return 1
  fi
  rm -f "$held"
  echo "marked legacy: $id ($ev)"
  return 0
}

cmd_state_legacy() {  # state legacy [--days N] <id>... — mark only what the operator names
  local parsed days id refused=0
  parsed="$(state_days_arg legacy "$@")" || exit 2
  days="${parsed%%$'\n'*}"
  local -a ids=()
  while IFS= read -r id; do ids+=("$id"); done < <(printf '%s\n' "$parsed" | sed 1d)
  [ "${#ids[@]}" -gt 0 ] && [ -n "${ids[0]}" ] \
    || usage_err "state legacy: name at least one id from 'comms.sh state idle' — nothing is ever marked by age alone"
  for id in "${ids[@]}"; do
    # An id is a state FILE stem: one path component, never hidden, never a traversal.
    case "$id" in ''|.*|*/*|*[!A-Za-z0-9._-]*) usage_err "state legacy: invalid id '$(clip "$id")' — use an id exactly as 'state idle' printed it" ;; esac
  done
  for id in "${ids[@]}"; do
    if state_mark_legacy "$days" "$id"; then :; else refused=1; fi
  done
  [ "$refused" = 0 ] || return 3
  return 0
}

cmd_state() {
  local sub="${1:-list}"; shift || true
  local dir ws
  dir="$(state_dir)"; ws="$(cmd_workspace)"
  case "$sub" in
    get)
      local thread="${1:-}"
      [ -n "$thread" ] || die "state get: thread argument required"
      local sfile="$dir/$(safe_name "$ws")_$(safe_name "$thread").json"
      [ -f "$sfile" ] || die "state get: no state for thread '$thread'"
      cat "$sfile"
      ;;
    list)
      local f found=false
      for f in "$dir/${ws}_"*.json; do
        [ -f "$f" ] || continue
        found=true
        printf '%s: %s/%s r%s/%s status=%s awaiting=%s delivery=%s\n' \
          "$(json_get "$f" thread)" "$(json_get "$f" workflow)" "$(json_get "$f" phase)" \
          "$(json_get "$f" round)" "$(json_get "$f" max_rounds)" "$(json_get "$f" status)" \
          "$(json_get "$f" awaiting_from)" "$(json_get "$f" last_delivery)"
      done
      [ "$found" = true ] || echo "no thread state for workspace '$ws'"
      ;;
    complete)
      local thread="${1:-}"
      [ -n "$thread" ] || die "state complete: thread argument required"
      local f="$dir/$(safe_name "$ws")_$(safe_name "$thread").json"
      [ -f "$f" ] || die "state complete: no state for thread '$thread'"
      awk '{gsub(/"status": "[^"]*"/, "\"status\": \"complete\"");
            gsub(/"awaiting_from": "[^"]*"/, "\"awaiting_from\": \"none\""); print}' "$f" > "$f.tmp" \
        && mv "$f.tmp" "$f"
      echo "thread '$thread' marked complete"
      ;;
    idle) cmd_state_idle "$@" ;;
    legacy) cmd_state_legacy "$@" ;;
    retire|unretire|retired) cmd_state_retire "$sub" "$@" ;;
    *) die "state: unknown subcommand '$sub' (get|list|complete|idle|legacy|retire|unretire|retired)" ;;
  esac
}

cmd_stalled() {
  local mins="${1:-15}" dir ws now f age_s since deliv rd note pid owes mid root
  root="$(cmd_root)"; dir="$root/state"; ws="$(cmd_workspace)"; now="$(date +%s)"
  local any=false
  for f in "$dir/${ws}_"*.json; do
    [ -f "$f" ] || continue
    [ "$(json_get "$f" awaiting_from)" = "none" ] && continue
    state_settled "$(json_get "$f" status)" && continue   # complete, or marked legacy
    since="$(json_get "$f" awaiting_since_epoch)"
    case "$since" in ''|*[!0-9]*) since=$now ;; esac  # garbage epoch must not crash
    age_s=$(( now - since ))
    if [ "$age_s" -gt $(( mins * 60 )) ]; then
      any=true
      # Headless watchdog: a spawned turn has a real pid to check, so "slow
      # reviewer" and "runner died without a result" are distinguishable.
      deliv="$(json_get "$f" last_delivery)"
      rd="$(json_get "$f" last_run_dir)"
      note=""
      owes="$(json_get "$f" awaiting_from)"
      mid="$(json_get "$f" last_sent)"
      if registry_has "$owes"; then
        [ -f "$root/$(inbox_for "$owes")/$mid.md" ] && note=" [inbox=unread]"
      fi
      if [ "$deliv" = "spawned" ] && [ -n "$rd" ] && [ -d "$rd" ]; then
        pid="$(cat "$rd/pid" 2>/dev/null || true)"
        if [ -f "$rd/result.json" ]; then
          note="$note [headless turn finished: $(json_get "$rd/result.json" status) — reply may be unread]"
        elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          note="$note [headless runner alive (pid $pid) — still working]"
        else
          note="$note [headless runner DEAD without a result — re-send to retry]"
        fi
      fi
      printf 'STALLED %sm: thread=%s %s/%s r%s awaiting=%s last_delivery=%s%s\n' \
        "$(( age_s / 60 ))" "$(json_get "$f" thread)" "$(json_get "$f" workflow)" \
        "$(json_get "$f" phase)" "$(json_get "$f" round)" \
        "$(json_get "$f" awaiting_from)" "$deliv" "$note"
    fi
  done
  if [ "$any" = false ]; then
    echo "no stalled threads (threshold: ${mins}m)"
  fi
}

# norm_verdict_value <raw> — LOOPSPEC normalization: trim, uppercase, then map
# the canonical artifact spelling onto the message spelling (permanent synonyms:
# pass<=>APPROVE, fail<=>REQUEST_CHANGES — see docs/loopspec/SPEC.md).
norm_verdict_value() {
  local v
  v="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
  case "$v" in
    PASS) v=APPROVE ;;
    FAIL) v=REQUEST_CHANGES ;;
  esac
  printf '%s' "$v"
}

cmd_verdict() {
  local file="${1:-}"
  [ -n "$file" ] || die "verdict: file argument required"
  # Fail loudly on a stale path (message archived between list and read) — a
  # silent empty verdict reads as not-approved and spins a phantom round.
  [ -f "$file" ] || die "verdict: no such file: $file"
  norm_verdict_value "$(frontmatter_field "$file" verdict)"
  echo
}

cmd_clean() {
  local as="" yes=false orphans=false mode="" targets=() thread="" thread_set=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) need_value "clean" $# "$1"; shift; as="$1" ;;
      --yes) yes=true ;;
      --orphans) orphans=true ;;
      --thread) need_value "clean" $# "$1"; shift
                [ "$thread_set" = false ] || usage_err "clean mounts: --thread names ONE thread; run it once per thread"
                thread="$1"; thread_set=true ;;
      *) [ -z "$mode" ] && mode="$1" || usage_err "clean: unexpected argument '$1'" ;;
    esac
    shift
  done
  # `clean mounts` is the external mount-store GC — a different concern from mailbox cleanup:
  # it needs no --as, and the store logic (validated base, repo-key scope, owner liveness)
  # lives in runphase.sh, so route there rather than duplicate it. (mount-relocation, r3.)
  if [ "$mode" = mounts ]; then
    local rp; rp="$(dirname "$SELF")/runphase.sh"
    [ -x "$rp" ] || die "clean: runphase.sh not found next to comms.sh — re-run install.sh"
    local -a mflags=()
    [ "$yes" = true ] && mflags+=(--yes)
    [ "$orphans" = true ] && mflags+=(--orphans)
    # Forwarded even when empty: runphase refuses an empty selector rather than reading it as
    # "no selector", which would be the whole-repo GC.
    [ "$thread_set" = true ] && mflags+=(--thread "$thread")
    "$rp" clean-mounts ${mflags[@]+"${mflags[@]}"}
    return $?
  fi
  [ "$thread_set" = false ] || usage_err "clean: --thread applies only to 'clean mounts'"
  [ -n "$as" ] || die "clean: --as <agent> is required (registered: $(registry_agents))"
  [ -n "$mode" ] || mode="workspace"
  local root ws inbox
  root="$(cmd_root)"; ws="$(cmd_workspace)"; inbox="$(inbox_for "$as")"
  case "$mode" in
    workspace)
      # Own inbox + shared archive only — never the other agent's unread mail.
      while IFS= read -r f; do [ -n "$f" ] && targets+=("$f"); done \
        < <(find "$root/$inbox" "$root/archive" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null)
      ;;
    all)
      local reg_dirs=() ra reg_all
      reg_all="$(registry_agents)" || exit 2
      for ra in $reg_all; do reg_dirs+=("$root/to-$ra"); done
      while IFS= read -r f; do [ -n "$f" ] && targets+=("$f"); done \
        < <(find "${reg_dirs[@]}" "$root/archive" -maxdepth 1 -type f 2>/dev/null)
      ;;
    archive)
      while IFS= read -r f; do [ -n "$f" ] && targets+=("$f"); done \
        < <(find "$root/archive" -maxdepth 1 -type f 2>/dev/null)
      ;;
    *)
      # Specific filename — locate by basename within the three message dirs.
      local d ra2 reg_named
      reg_named="$(registry_agents)" || exit 2
      for ra2 in $reg_named; do
        [ -f "$root/to-$ra2/$(basename "$mode")" ] && targets+=("$root/to-$ra2/$(basename "$mode")")
      done
      d="$root/archive/$(basename "$mode")"
      [ -f "$d" ] && targets+=("$d")
      [ "${#targets[@]}" -gt 0 ] || die "clean: '$mode' not found in any registered inbox or archive/"
      ;;
  esac
  if [ "${#targets[@]}" -eq 0 ]; then
    echo "nothing to clean (mode: $mode)"
    return 0
  fi
  if [ "$yes" != true ]; then
    echo "would delete ${#targets[@]} file(s) (mode: $mode) — re-run with --yes to delete:"
    printf '  %s\n' "${targets[@]}"
    return 0
  fi
  rm -f "${targets[@]}"
  echo "deleted ${#targets[@]} file(s) (mode: $mode)"
}

# delivery_run_dir <deliver output> — the run a delivery went to, or empty when it named none.
# Every shape deliver prints: a detached spawn and an "already running" re-send (`  run dir: P`),
# and a foreground `send --wait` (`running … — run dir: P`). Reading only the first shape recorded
# an empty run for every foreground turn. (codex, r3.)
delivery_run_dir() {
  printf '%s\n' "$1" | sed -n -e 's/^ *run dir: //p' -e 's/^running .* — run dir: //p' | head -1
}

cmd_send() {
  # Refuse BEFORE any durable write. `panel dispatch` calls this directly and had already
  # written its attempt marker, roster events, leg files and index rows before delivery failed —
  # and its `cmd_send … || echo` swallowed the failure into "incomplete legs". (codex, r3, blocking.)
  require_known_transport
  local to="" file="" archive_inbound="" as="" wait_arg="" bound_leg="" bound_digest=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --to) need_value "send" $# "$1"; shift; to="$1" ;;
      # INTERNAL: only `panel dispatch --bindings` passes these. The stamp is verified (digest, canonical
      # form, the leg's own agent) before it is written; a hand-typed leg_binding* key is stripped below.
      --bound-leg) need_value "send" $# "$1"; shift; bound_leg="$1" ;;
      --bound-digest) need_value "send" $# "$1"; shift; bound_digest="$1" ;;
      --wait) COMMS_WAIT=1; export COMMS_WAIT; wait_arg="--wait" ;;
      --archive-inbound) need_value "send" $# "$1"; shift; archive_inbound="$1" ;;
      *) file="$1" ;;
    esac
    shift
  done
  [ -n "$to" ] || die "send: --to <agent> is required (registered: $(registry_agents))"
  require_agent "$to" "send"
  [ -n "$file" ] || die "send: outbound file argument required"
  send_role_check "$file" "$to"
  # A review-request must name the tree this send runs in, BEFORE the snapshot and every stamp
  # below: a refusal leaves the file, the refs and the state exactly as they were. A panel leg
  # re-passes it trivially — same process, same tree its dispatch already checked.
  if [ -f "$file" ] && [ "$(frontmatter_field "$file" type)" = "review-request" ]; then
    local rerun=(send --to "$to")
    [ -z "$wait_arg" ] || rerun+=("$wait_arg")
    [ -z "$archive_inbound" ] || rerun+=(--archive-inbound "$(abs_file "$archive_inbound")")
    request_tree_check "$file" send "${rerun[@]}" "$(abs_file "$file")" || exit 1
  fi

  # RETAIN THE ARTIFACT THE REVIEWER WILL READ, before anyone reads it. Without this
  # the reviewer reads the LIVE tree, so what it reviewed is whatever the author was
  # typing at the time — and with two reviewers on one request they race each other.
  # Stamping the id here makes "these reviewers read the same artifact" a fact about
  # the dispatch rather than a hope. Loops only: a consult reviews nothing.
  # stamp_head_sha <file> <aid-or-empty> <base> — drop every head_sha line in the
  # frontmatter and insert the authoritative pair at its close. CRLF files get
  # CRLF on the INSERTED lines too (mixed endings were the previous behavior).
  stamp_head_sha() {
    local sf="$1" aid="$2" base="$3" stamped
    stamped="$(mktemp "${TMPDIR:-/tmp}/agent-comms-stamp.XXXXXX")"
    LC_ALL=C awk -v aid="$aid" -v base="$base" '
      NR == 1 { nl = ($0 ~ /\r$/) ? "\r\n" : "\n" }
      { probe = $0; sub(/\r$/, "", probe) }
      NR == 1 && probe == "---" { fm = 1; print; next }
      fm && probe == "---" {
        if (aid != "")  printf "artifact_id: %s%s", aid, nl
        if (base != "") printf "head_sha: %s%s", base, nl
        fm = 0; print; next
      }
      fm && index(probe, "head_sha:") == 1 { next }
      fm && aid != "" && index(probe, "artifact_id:") == 1 { next }
      { print }
    ' "$sf" > "$stamped" && mv -f "$stamped" "$sf"
    rm -f "$stamped" 2>/dev/null || true
  }
  # artifact_base <aid> — the commit the artifact's diff applies to, derived from
  # the OBJECT: a synthetic snapshot commit bases on its first parent; anything
  # else (a clean tree pinned as HEAD) is its own base.
  artifact_base() {
    # Synthetic detection matches the OBJECT, not just its subject line: snapshot
    # pins author email and epoch-0 dates, so an ordinary commit that happens to
    # reuse the message cannot have its parent mistaken for a base. (codex + grok,
    # stamped-authorities round 2.)
    local a="$1" meta
    meta="$(git -C "$(main_repo_root)" log -1 --format='%s|%ae|%at' "$a" 2>/dev/null || true)"
    if [ "$meta" = "agent-comms reviewed artifact|agent-comms@localhost|0" ]; then
      git -C "$(main_repo_root)" rev-parse -q --verify "${a}^" 2>/dev/null || true
    else
      printf '%s' "$a"
    fi
  }
  # bind_reply_identity <reply> <inbound-or-empty>
  # A review reply is the SAME artifact as the request it answers. broker_stamp
  # copies the pair onto the envelope; this is the coordinator door that cannot
  # be bypassed: inherit when the reply omitted them, refuse when they disagree.
  # Never snapshot a reply — minting a new artifact here is how round 2 silently
  # reviewed a newer SHA than the request. (field report, 2026-09-15.)
  bind_reply_identity() {
    local rf="$1" inbound="${2:-}" req="" irt inbound_id req_aid req_sha rep_aid rep_sha
    local aid_ct sha_ct
    irt="$(frontmatter_field "$rf" in-reply-to)"
    if [ -n "$inbound" ]; then
      # --archive-inbound may already have been moved, or be a bare filename the
      # archive preflight would still find in an inbox. (codex, identity r2.)
      req="$(resolve_inbound_path "$inbound" || true)"
      [ -n "$req" ] && [ -f "$req" ] \
        || die "send: --archive-inbound '$(clip "$inbound")' is gone and could not be re-resolved in archive or an inbox — refusing to bind a reply against a missing request"
      inbound_id="$(frontmatter_field "$req" message_id)"
      [ -n "$inbound_id" ] || inbound_id="$(basename "$req" .md)"
      if [ -n "$irt" ] && [ "$irt" != "$inbound_id" ]; then
        die "send: --archive-inbound is '$(clip "$inbound_id")' but in-reply-to is '$(clip "$irt")' — refusing to bind a reply to a different request"
      fi
    elif [ -n "$irt" ]; then
      req="$(find_message_by_id "$irt" || true)"
    fi
    # The outbound must not count as the request it answers: a self-referential
    # in-reply-to plus artifact_id: HEAD used to validate against itself.
    # Only a review-request is an eligible bind source. (codex, identity r2.)
    if [ -n "$req" ] && [ -f "$rf" ] && [ "$req" -ef "$rf" ]; then
      req=""
    fi
    if [ -n "$req" ] && [ -f "$req" ] && [ "$(frontmatter_field "$req" type)" != "review-request" ]; then
      req=""
    fi
    if [ -z "$req" ] || [ ! -f "$req" ]; then
      # No request to inherit from. An identity-FREE orphan must not mint (the
      # snapshot skip below). An identity-BEARING one is unverifiable: previously
      # the pinned-workflow path refused HEAD/phantoms; skipping resend on every
      # review-feedback reopened that. (codex, identity r1, blocking.)
      aid_ct="$(fm_field_lines "$rf" artifact_id | wc -l | tr -d ' ')"
      sha_ct="$(fm_field_lines "$rf" head_sha | wc -l | tr -d ' ')"
      if [ "${aid_ct:-0}" -gt 0 ] || [ "${sha_ct:-0}" -gt 0 ]; then
        die "send: review reply carries artifact identity but the request it answers was not found — refusing an unverifiable pin"
      fi
      return 0
    fi
    req_aid="$(frontmatter_field "$req" artifact_id)"
    req_sha="$(frontmatter_field "$req" head_sha)"
    local bind_key bind_want bind_have
    for bind_key in agent_profile agent_profile_digest review_family review_model; do
      bind_want="$(frontmatter_field "$req" "$bind_key")"
      bind_have="$(frontmatter_field "$rf" "$bind_key")"
      if [ -n "$bind_have" ] && [ "$bind_have" != "$bind_want" ]; then
        die "send: reply changed the request's $bind_key binding"
      fi
      [ -z "$bind_want" ] || stamp_fm_key "$rf" "$bind_key" "$bind_want"
    done
    IFS= read -r rep_aid < <(fm_field_lines "$rf" artifact_id) || rep_aid=""
    IFS= read -r rep_sha < <(fm_field_lines "$rf" head_sha) || rep_sha=""
    if [ -n "$req_aid" ] && [ -n "$rep_aid" ] && [ "$req_aid" != "$rep_aid" ]; then
      die "send: reply artifact_id '$(clip "$rep_aid")' does not match request '$(clip "$req_aid")' — a review reply cannot retarget the artifact"
    fi
    if [ -n "$req_sha" ] && [ -n "$rep_sha" ] && [ "$req_sha" != "$rep_sha" ]; then
      die "send: reply head_sha '$(clip "$rep_sha")' does not match request '$(clip "$req_sha")' — a review reply cannot retarget the artifact base"
    fi
    if [ -n "$req_aid" ]; then
      stamp_head_sha "$rf" "$req_aid" "${req_sha:-}"
    elif [ -n "$req_sha" ] && [ -z "$rep_sha" ]; then
      stamp_head_sha "$rf" "" "$req_sha"
    fi
  }
  local send_type
  send_type="$(frontmatter_field "$file" type)"
  if [ "$send_type" = "review-feedback" ]; then
    bind_reply_identity "$file" "$archive_inbound"
    # A reply's identity is the request's, including mount-style pairs where
    # artifact_id is the reviewed commit and head_sha is its base — that is NOT
    # the snapshot invariant (artifact_base == head_sha) that the resend path
    # enforces on review-requests. Re-validating here refused every warm-mounted
    # grok turn after persistence.
  elif [ -n "$(frontmatter_field "$file" workflow)" ]; then
    local send_aid send_base existing_aid existing_sha aid_ct
    # Fresh-vs-resend is decided by PHYSICAL artifact_id lines: a blank first
    # value made frontmatter_field return empty, sending a pinned message down
    # the fresh path — snapshotting the live tree and silently overwriting the
    # supplied pin. Presence is counted; values are judged after. (codex, round 4.)
    aid_ct="$(fm_field_lines "$file" artifact_id | wc -l | tr -d ' ')"
    # No `head` in a $() pipeline under pipefail (latent SIGPIPE kill — this
    # file already avoids that shape in cmd_list); read the first line directly.
    IFS= read -r existing_aid < <(fm_field_lines "$file" artifact_id) || existing_aid=""
    if [ "${aid_ct:-0}" -eq 0 ]; then
      # A reply must inherit, never mint. The fresh-snapshot path is for the
      # request that OPENS a loop; running it on review-feedback was the identity
      # bug (a newer SHA than the request, after the author committed).
      if [ "$send_type" = "review-request" ]; then
      # Fresh dispatch: retain the tree and stamp the WHOLE git identity from the
      # one snapshot operation — artifact_id names the content, head_sha the base
      # it applies to; same object, so they cannot desync, and any hand-typed
      # head_sha (live at WRITE time, stale by SEND time in a shared checkout) is
      # overwritten rather than trusted. Never let the driver type a SHA.
      # (field report #6.)
      local send_pair
      send_pair="$(cmd_snapshot create --with-base 2>/dev/null || true)"
  # Same synthetic-snapshot warning as panel dispatch: a fresh unpinned workflow send snapshots
  # too, so reviewers read uncommitted work here as well. Deliberately STDERR ONLY — the
  # `RESULT:` line is a parsed contract (`tail -1`) and the closed `ask` false-failure used to
  # mis-derive outcomes from captured stdout on this path. Scoped as grok put it: "do not touch
  # RESULT:", not "do not warn". (grok, staging-safety r3.)
  if [ -n "$send_pair" ]; then
    _sp_aid="${send_pair%%	*}"; _sp_base="${send_pair#*	}"
    if [ "$_sp_base" != "$send_pair" ] && [ -n "$_sp_base" ] && [ "$_sp_aid" != "$_sp_base" ]; then
      echo "warning: this send snapshots a SYNTHETIC artifact — the tree is dirty, so a reviewer reads uncommitted work" >&2
    fi
  fi
      send_aid="${send_pair%%	*}"
      send_base="${send_pair#*	}"
      [ "$send_base" = "$send_pair" ] && send_base=""
      if [ -n "$send_aid" ]; then
        stamp_head_sha "$file" "$send_aid" "$send_base"
      else
        # Fail CLOSED. Proceeding would review the live tree while the message
        # implies a pinned one — the precise failure the snapshot exists to
        # remove, and invisible afterwards. (codex, transport-flip round 4.)
        die "send: could not retain the artifact under review — refusing to dispatch a loop against an unpinned tree (is this a git repo with a commit?)"
      fi
      fi
    else
      # RESEND of an already-pinned message: the artifact is preserved, but its
      # base is still DERIVED from the object and validated — an artifact-only
      # message must never fall through to a live-HEAD stamp, and a mismatched
      # pair is a lie about what the diff applies to. Fail closed either way.
      # (codex, stamped-authorities round 1.)
      # The id must be an IMMUTABLE full object id — `HEAD`, refs, and
      # abbreviations resolve today and move tomorrow, which un-pins the pin.
      # (codex, round 2.)
      printf '%s' "$existing_aid" | grep -qE '^[0-9a-f]{40}$' \
        || die "send: artifact_id '$(clip "$existing_aid")' is not a full 40-hex object id — symbolic or abbreviated revisions are movable and cannot pin an artifact"
      git -C "$(main_repo_root)" cat-file -e "${existing_aid}^{commit}" 2>/dev/null \
        || die "send: artifact_id '$(clip "$existing_aid")' does not resolve — refusing to dispatch against a phantom artifact"
      send_base="$(artifact_base "$existing_aid")"
      # EVERY head_sha value in the frontmatter must equal the derived base —
      # frontmatter_field reads only the first, so a stale or forged duplicate
      # behind a matching first line would otherwise ride through. The message is
      # then NORMALIZED to exactly one canonical line. A pair that cannot be
      # checked (parentless synthetic artifact) refuses rather than trusts.
      # (codex + grok, round 2.)
      # PRESENCE is counted physically (field lines), never inferred from value
      # content: a blank `head_sha:` line has an empty value that command
      # substitution erases, which let it bypass both the uncheckable-pair
      # refusal and the per-value comparison. Values are checked PER LINE
      # (including empties). (codex, rounds 3-4.)
      local sha_ct one_sha
      sha_ct="$(fm_field_lines "$file" head_sha | wc -l | tr -d ' ')"
      if [ "${sha_ct:-0}" -gt 0 ] && [ -z "$send_base" ]; then
        die "send: head_sha present but artifact '$(clip "$existing_aid")' has no derivable base — refusing an uncheckable pair"
      fi
      if [ "${sha_ct:-0}" -gt 0 ]; then
        while IFS= read -r one_sha; do
          [ "$one_sha" = "$send_base" ] \
            || die "send: head_sha '$(clip "$one_sha")' does not match artifact '$(clip "$existing_aid")' base '$(clip "$send_base")' — refusing to dispatch a mismatched pair"
        done < <(fm_field_lines "$file" head_sha)
      fi
      # artifact_id gets the SAME all-values discipline — round 2 proved the
      # first-value-only shape bypassable for head_sha; the id field is not
      # different. Duplicates must all equal the validated first id, and the
      # normalize pass below collapses them to one line. (grok, round 3 —
      # declared as a criteria amendment, not a silent bar raise.)
      local one_aid
      while IFS= read -r one_aid; do
        [ "$one_aid" = "$existing_aid" ] \
          || die "send: duplicate artifact_id '$(clip "$one_aid")' disagrees with '$(clip "$existing_aid")' — refusing an ambiguous pin"
      done < <(fm_field_lines "$file" artifact_id)
      # Normalize BOTH fields to exactly one canonical line each (re-stamping the
      # id collapses duplicate artifact_id lines; base may be empty for a
      # parentless artifact-only message, which stays artifact-only).
      stamp_head_sha "$file" "$existing_aid" "$send_base"
    fi
  else
    # Consults snapshot nothing, but their context SHA is still helper-derived at
    # SEND time — including OVERWRITING a driver-typed or stale-template value;
    # "when absent" was a hole for leftover hand-typed consults. (codex + grok,
    # stamped-authorities round 1.)
    # A review-feedback without `workflow:` is still a reply: do not overwrite
    # inherited identity with live HEAD.
    if [ "$send_type" != "review-feedback" ]; then
      local live_sha
      live_sha="$(git -C "$(live_tree_root)" rev-parse -q --verify HEAD 2>/dev/null || true)"
      [ -n "$live_sha" ] && stamp_head_sha "$file" "" "$live_sha"
    fi
  fi

  # REVIEWER ROUTING — stamped by the helper, never typed by the author. Only a workflow
  # review-request is routed, and only when routing is on; every other send, and every send
  # while routing is off, has any `route_decision:` line REMOVED, so a hand-typed or stale id
  # cannot ride into a turn. A panel leg (`dispatch:` present, thread `<base>-<to>`) reuses the
  # decision its dispatch made for the base thread; it never classifies again. Deciding happens
  # here, BEFORE validation and the fail-closed request-persisted event, so a routing failure
  # refuses the send with nothing delivered.
  local route_id="" route_thr route_phase route_have
  if [ "$send_type" = "review-request" ] && [ -n "$(frontmatter_field "$file" workflow)" ] \
     && review_routing_enabled; then
    route_thr="$(frontmatter_field "$file" thread)"
    route_phase="$(frontmatter_field "$file" phase)"
    IFS= read -r route_have < <(fm_field_lines "$file" route_decision) || route_have=""
    if [ -n "$(frontmatter_field "$file" dispatch)" ]; then
      # A PANEL LEG keeps the id its dispatch stamped — verified, never re-decided, so a
      # `--replace` between two legs cannot split one review set across two decisions. Its
      # thread is `<base>-<to>`, and only THIS recipient's suffix is accepted.
      if [ -n "$route_have" ]; then
        cmd_review_route verify "$route_have" --thread "$route_thr" --phase "$route_phase" \
            --leg-dispatch "$(frontmatter_field "$file" dispatch)" --leg-agent "$to" >/dev/null \
          || die "send: the panel's routing decision '$(clip "$route_have")' does not belong to leg thread '$route_thr' phase '$route_phase'"
        route_id="$route_have"
      fi
    else
      route_id="$(route_decision_for "$file" "$route_thr" "$route_phase" \
                   "$(frontmatter_field "$file" artifact_id)" "$(frontmatter_field "$file" head_sha)")" \
        || die "send: reviewer routing failed — refusing to dispatch"
    fi
  fi
  local route_lines
  route_lines="$(fm_field_lines "$file" route_decision | wc -l | tr -d ' ')"
  if [ -n "$route_id" ] || [ "${route_lines:-0}" != 0 ]; then
    stamp_route_decision "$file" "$route_id" || die "send: could not stamp the routing decision"
  fi

  # THE LEG BINDING — helper-stamped by `panel dispatch --bindings`, never typed. Any other send, and
  # any hand-typed value, has the keys REMOVED; a stamp from the panel is verified before it is written.
  if [ -n "$bound_leg" ]; then
    [ "$send_type" = "review-request" ] || die "send: a leg binding rides only on a review-request"
    [ "$(leg_binding_py stamp-field --stamp "$bound_leg" --digest "$bound_digest" --key agent 2>/dev/null)" = "$to" ] \
      || die "send: the leg binding does not verify for '$to' — refusing to dispatch a leg whose binding cannot be trusted"
    stamp_fm_key "$file" leg_binding "$bound_leg" && stamp_fm_key "$file" leg_binding_digest "$bound_digest" \
      || die "send: could not stamp the leg binding"
  elif [ -n "$(fm_field_lines "$file" leg_binding)$(fm_field_lines "$file" leg_binding_digest)" ] \
       || grep -qE '^leg_binding(_digest)?:' "$file" 2>/dev/null; then
    stamp_fm_key "$file" leg_binding "" && stamp_fm_key "$file" leg_binding_digest "" || die "send: could not strip a hand-typed leg binding"
  fi

  # PROVIDER PROVENANCE — helper-stamped, never typed. A request to a review identity carries
  # the provider the registry maps it to NOW; runphase refuses the turn if the map has changed
  # by the time it runs, and the broker stamps the same value on the reply, which is what
  # compose counts. So "these two replies came from different providers" is a fact recorded on
  # the replies, not a reading of whatever the registry says later. A request to a driver
  # carries none (its provider is its name), and any hand-typed value is removed.
  # Every type a review identity accepts starts a review turn there — the request, and the per-leg
  # error lane that asks it to answer again — so every one of them carries the binding.
  case "$send_type" in
    review-request|error|question)
      stamp_review_provider "$file" "$to" || die "send: could not stamp the review provider for '$to'" ;;
  esac

  # Atomicity guard: never deliver or archive on a malformed outbound message.
  cmd_validate "$file" || die "send: refusing to deliver malformed message (and not archiving inbound)"
  # THE COORDINATOR LOG (contraction step 3, criterion 1). Identity is read ONCE, here,
  # while the message is still on disk and validated.
  #
  # The leg belongs to the REVIEWER, so that is what `agent` names: the target for a
  # request, the AUTHOR for a reply. Recording the send target on a reply made the driver
  # look like a second reviewer, which `events --set` renders as an extra leg. (grok, plan
  # r1.) `request_id` is what binds a reply to the attempt it answers — a panel retry
  # reuses set+thread+round, so without it a stale acceptance reads as the new leg
  # answering. (codex + grok, plan r1.)
  local ev_type ev_thread ev_round ev_set ev_dispatch ev_aid ev_mid ev_agent ev_reqid ev_verdict=""
  # THIS SEND'S attempt id, at the head of both its notes. A re-send of the same message keeps its
  # message and request ids, so nothing else in the log pairs a `request-dispatched` with the
  # persist it completes, and compose --degrade must know whether any send is still between the
  # two (it may yet spawn a runner). 64 random bits; the degrade walk also counts, so even a
  # repeated id needs one delivery row per send. (codex r3, grok r4.)
  local ev_attempt; ev_attempt="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$ev_attempt" ] || ev_attempt="$(date +%s)-$$-$RANDOM$RANDOM$RANDOM"
  ev_type="$(frontmatter_field "$file" type)"
  ev_thread="$(frontmatter_field "$file" thread)"
  ev_round="$(frontmatter_field "$file" round)"
  ev_set="$(frontmatter_field "$file" review_set)"
  ev_dispatch="$(frontmatter_field "$file" dispatch)"
  ev_aid="$(frontmatter_field "$file" artifact_id)"
  ev_mid="$(frontmatter_field "$file" message_id)"
  case "$ev_type" in
    review-feedback) ev_agent="$(frontmatter_field "$file" from)"; ev_reqid="$(frontmatter_field "$file" in-reply-to)"
                     ev_verdict="$(cmd_verdict "$file" 2>/dev/null || true)" ;;
    *)               ev_agent="$to"; ev_reqid="$ev_mid" ;;
  esac
  # FAIL-CLOSED, and only here. This is the one point where refusing changes nothing that
  # has already happened: the request is written and valid, nobody has been nudged, and the
  # whole dispatch is replayable. `die` rather than errexit on purpose — `panel dispatch`
  # calls this function as `cmd_send ... || echo warning`, which suppresses errexit inside
  # it, so an unchecked append would have been advisory exactly where it claimed to gate.
  # (codex, plan r1, blocking.) Every later event is advisory: see the outcome event below.
  if [ "$ev_type" = "review-request" ]; then
    cmd_events append --kind request-persisted --set "$ev_set" --dispatch "$ev_dispatch" --thread "$ev_thread" \
      --round "$ev_round" --agent "$ev_agent" --artifact "$ev_aid" --request-id "$ev_reqid" \
      --message-id "$ev_mid" --status persisted \
      --note "attempt=$ev_attempt phase=$(frontmatter_field "$file" phase) workflow=$(frontmatter_field "$file" workflow)${route_id:+ route=$route_id}" \
      || die "send: could not record the request in the coordinator log — refusing to dispatch a leg nothing can recover"
  fi
  local root_send
  root_send="$(cmd_root)"
  mkdir -p "$root_send/$(inbox_for "$to")" 2>/dev/null || true
  # PRE-FLIGHT the inbound-archive ownership BEFORE any delivery or state write:
  # a cross-inbox mismatch must abort with nothing half-applied — refusing after
  # the nudge would leave a spawned/nudged peer plus mutated state behind a
  # non-zero exit, and a retry would duplicate the peer turn.
  local arch_action="" arch_owner=""
  if [ -n "$archive_inbound" ]; then
    local ib_base found_dir="" d
    arch_owner="$(frontmatter_field "$file" from)"
    ib_base="$(basename "$archive_inbound")"
    if [ -z "$arch_owner" ] || ! registry_has "$arch_owner"; then
      arch_action="warn-no-owner"
    elif [ -f "$root_send/$(inbox_for "$arch_owner")/$ib_base" ]; then
      arch_action="archive"
    elif [ -f "$root_send/archive/$ib_base" ]; then
      arch_action="noop"
    else
      local reg_pf
      reg_pf="$(registry_agents)" || exit 2
      for d in $reg_pf; do
        [ "$d" = "$arch_owner" ] && continue
        [ -f "$root_send/to-$d/$ib_base" ] && found_dir="to-$d"
      done
      [ -z "$found_dir" ] || die "send: refusing --archive-inbound — $ib_base sits in $found_dir but the outbound 'from:' is '$arch_owner' (cross-inbox mismatch); nothing was delivered"
      arch_action="noop"
    fi
  fi
  # A runner spawned from here races this function's state_update_from below, so
  # it is allowed to wait for that write. A runner spawned any OTHER way — a bare
  # `comms.sh deliver`, which is a public verb — has no send behind it and no
  # state file is ever coming, so it must not wait. Declared here, by the one
  # caller that knows, instead of inferred by a timer in the child.
  # Set it EITHER WAY. An export that only ever sets is sticky: a nested send whose
  # message earns no state write would leave an inherited `1` standing and its
  # grandchild would wait for a file nobody is writing. (grok, panel r1.)
  #
  # KNOWN UNSUPPORTED: a runner already started by a bare `deliver` cannot be told
  # anything — it is already running with no declaration — so if a later `send` finds
  # it as "already running" and that runner exits before this function writes state,
  # the state stays `spawned`. The old unconditional wait papered over that narrow
  # retry race by accident. `deliver` is documented as not maintaining thread state
  # (see the `held` RESULT text below); `send` is the supported entry point for a
  # threaded turn, and mixing the two on one thread is not supported.
  # (codex, panel r1, advisory — established rather than mechanised.)
  if state_write_expected "$(frontmatter_field "$file" thread)" "$(frontmatter_field "$file" workflow)"; then
    export COMMS_RUNPHASE_EXPECT_STATE=1
  else
    unset COMMS_RUNPHASE_EXPECT_STATE
  fi
  local del_out outcome=manual rundir=""
  del_out="$(cmd_deliver "$to" "$file")"
  echo "$del_out"
  rundir="$(delivery_run_dir "$del_out")"
  # The route the turn actually went out over, read back from the spawn line rather than
  # from COMMS_DELIVERY — the two disagree (cmd_deliver's acp arm spawns a runphase turn),
  # and reporting the intent instead of the outcome is the whole of field-report #4.
  local route=""
  route="$(printf '%s\n' "$del_out" | sed -n 's/^spawned runphase .*via=\([a-z][a-z]*\).*/\1/p' | head -1)"
  case "$del_out" in
    *"delivered to"*)     outcome=delivered ;;
    # `blocked` is UNREACHABLE since S4-4: it meant "this session cannot reach the cmux
    # socket", and there is no socket. The enum keeps the value so ARCHIVED state written
    # before the removal still validates and still reads back; nothing produces it now.
    *"foreground turn failed"*) outcome=failed ;;
    *FAILED*)             outcome=failed ;;
    # --wait runs the turn in the foreground, so success is `completed:` not a spawn.
    # Missing this token left outcome=manual and printed "NOT spawned … fix and retry"
    # after a successful consult (ROADMAP 2026-09-02).
    *"completed:"*)       outcome=completed ;;
    *"spawned runphase"*) outcome=spawned ;;
    *"already running"*)  outcome=spawned ;;   # headless re-send: turn already in flight
    *"HELD:"*)            outcome=held ;;      # thread paused by a hold marker
    *"no nudge needed"*)  outcome=pickup ;;    # designed no-op: reply to the driving session
  esac
  # Record thread ground truth (workflow messages with a thread only). The
  # ||-context also suppresses errexit inside the function, so NO state failure
  # mode — mkdir, redirect, parse — can abort send before the inbound archive.
  # --wait archives the outbound during deliver; re-resolve so we never awk a
  # path whose owner has moved it.
  local file_live=""
  file_live="$(resolve_message_path "$file" || true)"
  if [ -n "$file_live" ]; then
    state_update_from "$file_live" "$outcome" "$rundir" "$to" || echo "warning: thread state not recorded" >&2
  else
    echo "warning: outbound '$(clip "$file")' is gone after delivery and could not be re-resolved in archive — thread state not recorded" >&2
  fi
  # The OUTCOME half of the pair. TWO events, not one: a `request-persisted` with no
  # `request-dispatched` after it names the turn that never got out the door — a wedged
  # acpx is a real failure mode — which a single post-delivery event could only report as
  # silence.
  #
  # ADVISORY from here on, and the reason is the asymmetry with the event above: the leg is
  # already delivered, so dying would tell the driver a live leg failed. A reply is the same
  # case one level down — `broker_stamp` copies the stamped reply into the inbox and THEN
  # calls this function, and a self-sending child calls it too, so a fail-closed append here
  # would turn an already-delivered reply into a failed turn. (grok, plan r1, blocking.)
  local ev_kind ev_status
  case "$ev_type" in
    review-request)  ev_kind=request-dispatched; ev_status="$outcome" ;;
    review-feedback) ev_kind=reply-accepted;     ev_status="$ev_verdict" ;;
    *)               ev_kind=message-dispatched; ev_status="$outcome" ;;
  esac
  if ! cmd_events append --kind "$ev_kind" --set "$ev_set" --dispatch "$ev_dispatch" --thread "$ev_thread" \
      --round "$ev_round" --agent "$ev_agent" --artifact "$ev_aid" --request-id "$ev_reqid" \
      --message-id "$ev_mid" --run-dir "$rundir" --status "${ev_status:-$outcome}" \
      --note "${ev_attempt:+attempt=$ev_attempt }type=$ev_type delivery=$outcome"; then
    # `A || { test && die; }` would abort the whole send under errexit whenever the test is
    # false — the opposite of the advisory intent — so the branch is spelled out.
    echo "warning: coordinator log not updated ($ev_kind); the $ev_type WAS $outcome" >&2
  fi
  if [ -n "$archive_inbound" ]; then
    # Archive the inbound only after the outbound was validated and delivery
    # attempted. A failed nudge still archives — the inbound WAS processed; the
    # retry surface is delivery (state last_delivery=failed + the warning above).
    # Ownership was preflighted above (owner = the OUTBOUND's sender — the agent
    # whose inbox held the inbound — never the complement of the target). Only
    # the pre-computed disposition executes here, after delivery.
    case "$arch_action" in
      archive) cmd_archive --as "$arch_owner" "$archive_inbound" ;;
      noop)    echo "already archived or absent (no-op): $(basename "$archive_inbound")" ;;
      warn-no-owner) echo "warning: outbound has no registered 'from:' — inbound NOT archived; archive it manually" >&2 ;;
    esac
  fi
  # A send is a work checkpoint: beat presence here so a driver mid-loop never
  # goes stale between rounds ("beats ride work" — user amendment, plan final
  # round; the template's claim was false until this line — codex, impl r1).
  # Advisory: a beat failure never touches the send outcome; a HEAL warning
  # passes through on stderr for the driver to act on.
  if [ -n "${COMMS_PRESENCE_NAME:-}" ] && [ -n "${COMMS_PRESENCE_INSTANCE:-}" ]; then
    "$SELF" presence beat --name "$COMMS_PRESENCE_NAME" --instance "$COMMS_PRESENCE_INSTANCE" || true
  fi
  # Loud outcome — emitted LAST so `tail -1` of send is always the RESULT line
  # on every path, including --archive-inbound (the main autonomous path).
  # `blocked` is unreachable since S4-4 (it meant "cannot reach the cmux socket"); the RECOVER
      # line went with it. Only a final
  # non-delivered result needs user attention.
  case "$outcome" in
    delivered) echo "RESULT: delivered" ;;
    # "already running" also lands here but carries no via= — an unknown route prints no
    # parenthetical at all. Naming a route we did not observe is the same defect in a new spot.
    spawned)   echo "RESULT: spawned${route:+ ($route)} — a peer turn is running detached; the reply lands in the inbox when it exits. Await it with the runphase.sh command printed above, then read the reply." ;;
    completed) echo "RESULT: completed — $to finished; the reply is in the inbox" ;;
    held)      echo "RESULT: held — the thread is paused by a hold marker; nothing was spawned. Release with 'runphase.sh release <thread>', then RE-SEND ('comms.sh send --to $to <file>') — a bare deliver would spawn the turn but leave this thread's state stuck on 'held', blinding status and the stalled watchdog." ;;
    pickup)
      # Text deliberately starts "manual —" for the peers' expectations: the
      # spawned peer is pre-briefed that its reply send reports manual.
      echo "RESULT: manual — headless mode: the reply is on disk; the driving session picks it up when this turn ends"
      ;;
    manual)
      # Recovery guidance follows the route that was actually attempted, not COMMS_DELIVERY
      # alone — that once told operators to fix a transport the run never used. (codex, advisory.)
      if [ "${COMMS_DELIVERY:-}" = "mailbox" ]; then
        # The SAME correction as in deliver: an explicitly requested mailbox got the generic
        # "NOT spawned … fix and retry" recovery text, which tells a caller their successful
        # request is a broken install. (codex, S4-1 r1, blocking.)
        echo "RESULT: manual — mailbox was requested; the message is on disk and $to was deliberately not nudged. Nothing to fix."
      else
        echo "RESULT: manual — $to was NOT spawned (see the warning above; likely runphase.sh missing or an empty inbox); fix and retry 'comms.sh send --to $to <file>'"
      fi
      ;;
    failed)    echo "RESULT: failed — nudge errored mid-sequence; retry with 'comms.sh send --to $to <file>'" ;;
  esac
}

# The routing verbs refuse an unknown transport HERE, in the main shell, so a command
# substitution deeper in the call chain cannot swallow the die on bash 3.2. Read-only verbs
# are deliberately exempt: an operator with a stale COMMS_DELIVERY must still be able to run
# `status`/`list` to see what happened. (grok, S4-4 r2.)
# ONE predicate, and each site has a DISTINCT reason — not four copies of one rule:
#   cmd_send / cmd_deliver          function entry, so a path that reaches delivery WITHOUT the
#                                   router (`panel dispatch` calls cmd_send directly) cannot skip
#                                   it. Both run in their own shell, not inside a command
#                                   substitution, so bash 3.2 cannot swallow the die.
#   router `transport`              the CLI verb's only gate now that cmd_transport does not
#                                   self-check (its other caller, cmd_deliver, gates first).
#   router `ask` / `panel dispatch` these WRITE before calling cmd_send — a question file, or a
#                                   snapshot plus attempt markers, roster events, leg files and
#                                   index rows. Gating at the function would leave that behind.
# Read-only verbs stay exempt so a stale COMMS_DELIVERY still lets `status`/`list` diagnose.
# (grok, S4-4 r2 + r4 — collapsed from five sites to four, one reason each.)
case "${1:-}" in
  transport|ask) require_known_transport ;;
  panel) case "${2:-}" in dispatch) require_known_transport ;; esac ;;
esac

case "${1:-}" in
  root)      shift; cmd_root "$@" ;;
  workspace) shift; cmd_workspace "$@" ;;
  agents)    shift; cmd_agents "$@" ;;
  launch)    shift; exec python3 "$(dirname "$SELF")/launch.py" "$@" ;;
  whoami)    shift; cmd_whoami "$@" ;;
  list)      shift; cmd_list "$@" ;;
  status)    shift; cmd_status "$@" ;;
  validate)  shift; cmd_validate "$@" ;;
  error-envelope) shift; cmd_error_envelope "$@" ;;
  reply-check) shift; cmd_reply_check "$@" ;;
  verdict)   shift; cmd_verdict "$@" ;;
  archive)   shift; cmd_archive "$@" ;;
  deliver)   shift; cmd_deliver "$@" ;;
  transport) shift; cmd_transport "$@" ;;
  send)      shift; cmd_send "$@" ;;
  state)     shift; cmd_state "$@" ;;
  presence)  shift; cmd_presence "$@" ;;
  worktree)  shift
             # The worktree verbs live in their own file, sourced so they share the presence
             # readers. An install that predates it is missing the verb, not broken silently.
             [ -f "$(dirname "$SELF")/worktree.sh" ] || die "worktree: worktree.sh not found next to comms.sh — re-run install.sh"
             . "$(dirname "$SELF")/worktree.sh"
             cmd_worktree "$@" ;;
  integrate) shift; cmd_integrate "$@" ;;
  attest-green) shift; cmd_attest_green "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  stalled)   shift; cmd_stalled "$@" ;;
  clean)     shift; cmd_clean "$@" ;;
  lessons)        shift; cmd_lessons "$@" ;;
  archive-search) shift; cmd_archive_search "$@" ;;
  findings)       shift; cmd_findings "$@" ;;
  ask)            shift; cmd_ask "$@" ;;
  route)          shift; cmd_route "$@" ;;
  route-eval)     shift; exec python3 "$(dirname "$SELF")/route_eval.py" "$@" ;;
  review-route)   shift; cmd_review_route "$@" ;;
  setup)          shift; exec bash "$(dirname "$SELF")/setup.sh" "$@" ;;
  panel)          shift; cmd_panel "$@" ;;
  compose)        shift; cmd_compose "$@" ;;
  round-note)     shift; cmd_round_note "$@" ;;
  events)         shift; cmd_events "$@" ;;
  friction)       shift; cmd_friction "$@" ;;
  shadow)         shift; cmd_shadow "$@" ;;
  snapshot)       shift; cmd_snapshot "$@" ;;
  prompt-version) shift; cmd_prompt_version "$@" ;;
  version)        shift; cmd_version "$@" ;;
  ""|help|-h|--help)
    # Print the whole header comment block rather than a hardcoded line range —
    # a fixed range silently truncates its own last entry as the block grows.
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
    ;;
  *) die "unknown subcommand '${1}' — run 'comms.sh help'" ;;
esac
