#!/bin/bash
# agent-comms shared helper — the single source of truth for shell logic that was
# previously copy-pasted across the command/skill templates (and drifted).
#
# Always executed (never sourced), always bash — the caller's shell (zsh, etc.)
# and Claude Code's slash-command $N argument substitution cannot affect it.
#
# Subcommands:
#   root                        print the main repo's .comms path (worktree-safe)
#   workspace [set <name>]      print the mailbox identity (pin > branch > repo
#                               dir); `set` pins it repo-scoped in .comms/workspace
#   agents [default|--supported|--others <agent>]
#                                  registered agents from .comms/config; --others lists
#                                  everyone EXCEPT one (the default panel for its driver).
#                                  (zero-config
#                                  default: claude codex / target codex)
#   list --as <agent> [--thread <t>]   pending inbox messages, newest first
#   status                      one-screen loop state: latest archive, verdict, pending counts
#   validate <file>             frontmatter + body checks; non-zero exit and reasons on failure
#   verdict <file>              normalized (trimmed, uppercased) verdict from frontmatter
#   archive --as <agent> <file...>   idempotent move to archive/; own inbox only
#   deliver <agent> [file]   hand the message to a runner (ACP, or headless for grok); reports delivered/
#                               manual-pickup/FAILED explicitly (never hard-fails).
#                               COMMS_DELIVERY=headless routes to runphase.sh instead
#                               (detached turn; grok only since step 4 — claude and
#                               codex review turns are ACP-only and refuse headless)
#   transport <agent> [--loop]  which transport would actually be used right now:
#                               headless | acp | mailbox. One decision point, so
#                               templates never re-implement surface detection.
#   send --to <agent> <file> [--wait] [--archive-inbound <file>]
#                               --wait runs the peer turn in the FOREGROUND instead of
#                               detaching — required inside sandboxes that reap the
#                               children of a finished shell command.
#                               validate, deliver, update thread state, then archive inbound
#   state <get|list|complete> [thread]      .comms/state/ thread ground truth (JSON)
#   stalled [minutes]           threads awaiting a reply older than N minutes (default 15)
#   presence <claim|beat|others|release|expire|with-beat>
#                               advisory multi-session coordination on .comms/sessions/
#                               (claim-then-check: 0 direct-safe / 3 peers / 4 isolate;
#                               beat exit 5 = healed, re-check before writing)
#   worktree new [<slug>]       session worktree under the MAIN root, local-tip base
#   integrate <branch>          land on main: lease + ff + suite at the candidate OID
#                               in a detached worktree + CAS update-ref (suite-cmd
#                               config required). A clean checkout idling on main at
#                               the expected tip is self-healed through the landing;
#                               suite-attest-secs = N config accepts a fresh
#                               attest-green record for the candidate OID in place
#                               of the re-run
#   attest-green [--passed N] [--expect <oid>]
#                               record "suite green at this exact HEAD" (clean
#                               tracked tree required) for integrate's opt-in skip.
#                               --expect binds the record to the commit the CALLER
#                               verified: HEAD moving mid-run refuses instead of
#                               attesting a commit the run was not about
#   clean --as <agent> [workspace|all|archive|<file>] [--yes]
#   clean mounts [--yes] [--orphans]   GC this repo's EXTERNAL mount store (dry-run default;
#                              refuses the whole repo-key on any live owner; --orphans reports
#                              moved-checkout keys without deleting). No --as; needs no mailbox.
#                               guarded delete; dry-run without --yes; own-inbox default
#   lessons [--bytes N] [--surface P] [--file F]
#                               bounded newest-first tail of docs/advisories.md (whole
#                               "## " sections, never a byte slice). Exit 3 = truncated.
#   archive-search <pattern> [--bytes N] [--limit K]
#                               bounded newest-first search of archive/ across workspaces;
#                               metadata + clipped context, not whole messages. Exit 3 = truncated.
#   findings [--out F] [--role gating|shadow] [--review-set ID] [--artifact ID]
#            [--reviewer-version V] [--prompt-version V] [--header] [<message>...]
#                               extract review findings to TSV (default: the whole archive,
#                               oldest first). --out appends, idempotent by finding_id.
#                               Observations only — no dispositions, no scores.
#   shadow --to <agent> <review-request> [--review-set ID] [--out F] [--timeout-secs N]
#                               have a SECOND reviewer read the same artifact. The reply is
#                               produced and stored but NEVER delivered and never written to
#                               thread state — a shadow verdict cannot gate the loop.
#   ask --from <agent> --to <agent> [--wait] (--file F | words...)
#                               one-off consult, driver-neutral: composes the question,
#                               validates it, sends it. Any agent can ask any other.
#   panel dispatch --to a,b <review-request> [--set ID]
#                               fan ONE artifact out to N reviewers as N parallel 2-party
#                               legs sharing a review_set. One snapshot for the whole set.
#   panel status [--set <id>]   with --set: which legs have answered, and with what
#                               verdict. Bare: every recorded review set, newest first —
#                               the recovery surface after an await dies with its session.
#   compose --set <id> [--out F]
#                               cluster every leg's findings and label them by SUPPORT:
#                               corroborated (gates), flagged-at-differing-severities (2+
#                               reviewers, mixed severity — does NOT gate), uncorroborated
#                               (cross-check first), unanchored, advisory. Support is counted
#                               per DISTINCT REVIEWER at an anchor, across severities: a
#                               blocking and an advisory report of one defect are two
#                               reviewers, not one. Drops nothing; no model arbitrates.
#   events [--set S] [--dispatch D] [--thread T] [--kind K] [--agent A] [--role R]
#          [--request-id Q] [--message-id M] [--limit N]
#           events append --kind <kind> [--set|--thread|--round|--agent|--role|--artifact|
#                                        --request-id|--message-id|--run-dir|--status|--note]
#                               the coordinator's append-only log of what IT did: roster
#                               planned -> request persisted -> dispatched -> turn started
#                               -> provider result -> reply validated/refused -> reply
#                               accepted -> turn finished -> composition completed. Not the
#                               mailbox, not ACP. The durable answer to "what happened to
#                               leg X" after an await dies with its session.
#   friction [--thread T] [--severity 1-5] "<note>"  |  friction --list
#                               --list reads the GLOBAL rollup across every project: the
#                               maintainer's inbox for what actually broke in the field.
#                               record harness friction the moment you hit it. Appends
#                               .comms/friction.tsv. Never shown to reviewers.
#   round-note <reply> --note "<text>"
#                               record how a reviewer performed on ONE round: counts are
#                               derived from the reply, the prose is your assessment.
#                               Appends .comms/grades/rounds.tsv. Never shown to reviewers.
#   snapshot [create|list] [--with-base]   retain the tree under review as a durable git
#                               object; --with-base prints "artifact_id<TAB>base_sha"
#                               (a real commit object anchored under refs/agent-comms/)
#   prompt-version [--list]     content hash of the reviewer instruction surface; grades
#                               are partitioned on it, never pooled across an edit
#
# Environment:
#   COMMS_DELIVERY              acp | headless (grok only) | mailbox. Unset picks the ladder.
#                               Any other value — including the removed `cmux` — is REFUSED.
set -euo pipefail

die() { echo "comms.sh: $*" >&2; exit 1; }

# Absolute path to this script — emitted in wrapper-retry hints so the recovery
# command carries a literal path, not a parent-shell variable the child can't see.
case "$0" in
  /*) SELF="$0" ;;
  *)  SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac

main_repo_root() {
  git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'
}





cmd_root() {
  local r
  r="$(main_repo_root)"
  [ -n "$r" ] || die "not inside a git repository"
  echo "$r/.comms"
}

# Filesystem-safe name (defined early — cache paths below need it).
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

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

cmd_workspace() {
  # `workspace set <name>` writes the explicit repo-scoped pin — the mailbox
  # identity, shared by every session and worktree of this repo. Everything
  # below it (branch, dirname) is INFERENCE, and a valid-but-wrong
  # inference (title "fwh-backup" in the fwh-platform repo) was cached as
  # authoritative forever and hid pending replies behind the filename glob.
  # a pin is a naming decision and outranks every inferred source
  # once a pin exists. (field report #3.)
  if [ "${1:-}" = "set" ]; then
    local pname="${2:-}" wroot
    [ -n "$pname" ] || usage_err "workspace set: name required"
    printf '%s' "$pname" | grep -qE '^[a-z0-9][a-z0-9._-]{0,31}$' \
      || usage_err "workspace set: invalid name '$(clip "$pname")' — must match [a-z0-9][a-z0-9._-]{0,31} (it becomes a filename prefix)"
    wroot="$(main_repo_root)" || usage_err "workspace set: not inside a git repository"
    [ -n "$wroot" ] || usage_err "workspace set: not inside a git repository"
    mkdir -p "$wroot/.comms" 2>/dev/null || usage_err "workspace set: cannot create $wroot/.comms"
    printf '%s\n' "$pname" > "$wroot/.comms/workspace" \
      || usage_err "workspace set: cannot write the pin"
    echo "workspace pinned to '$pname' — this file ($wroot/.comms/workspace) is now the mailbox identity for every session in this repo"
    return 0
  fi
  local pinf pinned
  pinf="$(main_repo_root 2>/dev/null || true)"
  if [ -n "$pinf" ] && [ -f "$pinf/.comms/workspace" ]; then
    pinned="$(head -1 "$pinf/.comms/workspace" 2>/dev/null | tr -d ' \t\r')"
    if [ -n "$pinned" ]; then
      printf '%s\n' "$pinned"
      return 0
    fi
  fi
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
SUPPORTED_AGENTS="claude codex grok"   # claude/codex: interactive+headless; grok: headless reviewer/consult
REGISTRY_DEFAULT_AGENTS="claude codex grok"
REGISTRY_DEFAULT_TARGET="codex"

registry_file() { echo "$(cmd_root)/config"; }

validate_agent_name() {  # <name> [source] — grammar: ^[a-z][a-z0-9-]{1,15}$
  printf '%s' "$1" | grep -qE '^[a-z][a-z0-9-]{1,15}$' \
    || die "config: invalid agent name '$1'${2:+ in $2} — must match [a-z][a-z0-9-]{1,15} (it becomes a directory suffix)"
}

# registry_parse — ONE full-config validation path, run by EVERY accessor. A
# config that criterion-level rules call malformed (duplicate keys, bad names,
# unsupported/duplicate agents, empty values, invalid default) is a hard error
# no matter which command touched it first; unknown keys warn everywhere.
# Prints two lines: the agent list, then the default target.
registry_parse() {
  local f agents_ct default_ct line a agents="" dflt
  f="$(registry_file)"
  if [ ! -f "$f" ]; then
    printf '%s\n%s\n' "$REGISTRY_DEFAULT_AGENTS" "$REGISTRY_DEFAULT_TARGET"
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
  fi
  grep -vE '^[[:space:]]*(#|$|agents[[:space:]]*=|default-target[[:space:]]*=|suite-cmd[[:space:]]*=|suite-attest-secs[[:space:]]*=)' "$f" \
    | head -3 | sed 's/^/warning: config: unknown line: /' >&2 || true
  if [ "${agents_ct:-0}" -eq 1 ]; then
    line="$(sed -n 's/^[[:space:]]*agents[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
    [ -n "$line" ] || die "config: 'agents' key present but empty in $f (delete the line for zero-config defaults)"
    for a in $line; do
      validate_agent_name "$a" "$f"
      case " $SUPPORTED_AGENTS " in
        *" $a "*) ;;
        *) die "config: unsupported agent '$a' in $f — supported: $SUPPORTED_AGENTS" ;;
      esac
      case " $agents " in
        *" $a "*) die "config: duplicate agent '$a' in $f" ;;
      esac
      agents="$agents $a"
    done
    agents="${agents# }"
  else
    agents="$REGISTRY_DEFAULT_AGENTS"
  fi
  if [ "${default_ct:-0}" -eq 1 ]; then
    line="$(sed -n 's/^[[:space:]]*default-target[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
    [ -n "$line" ] || die "config: 'default-target' key present but empty in $f"
    set -- $line
    [ "$#" -eq 1 ] || die "config: default-target must be exactly one agent (got: $line)"
    dflt="$1"
  else
    dflt="$REGISTRY_DEFAULT_TARGET"
  fi
  case " $agents " in
    *" $dflt "*) ;;
    *) die "config: default-target '$dflt' is not a registered agent (registered: $agents)" ;;
  esac
  printf '%s\n%s\n' "$agents" "$dflt"
}

registry_agents() { registry_parse | sed -n 1p; }

registry_default() { registry_parse | sed -n 2p; }

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

cmd_agents() {
  case "${1:-}" in
    "")          registry_agents ;;
    default)     registry_default ;;
    --others)
      # Every registered agent EXCEPT the named one — the default panel for a loop that
      # agent is driving. Derived from the registry so adding an agent changes the panel
      # without editing a template, and so nothing has to hardcode "codex,grok".
      shift
      [ -n "${1:-}" ] || usage_err "agents --others <agent>: an agent name is required"
      require_agent "$1" "agents --others"
      registry_agents | tr ' ' '\n' | grep -vx "$1" | paste -sd, - | sed 's/,$//'
      ;;
    --supported)
      # NOT 'headless': headless_ok refuses both, and runphase requires --via acp. A caller
      # reading the registry instead of cmd_transport would infer a route that fails.
      # (codex, S4-2 r3, blocking.) Do NOT add reviewer-consult-only here — see below.
      printf '%s\tinteractive,acp\n' claude
      printf '%s\tinteractive,acp\n' codex
      printf '%s\theadless,reviewer-consult-only\n' grok
      ;;
    *) die "agents: unknown argument '$1' (expected: default | --supported)" ;;
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
      --as) shift; as="${1:-}" ;;
      --thread) shift; thread="${1:-}" ;;
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
      # and the fwh-backup incident sat invisible behind exactly that. Frontmatter
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

frontmatter_field() {
  # frontmatter_field <file> <field> — prints the value or nothing (CRLF-tolerant)
  awk -v f="$2" '{sub(/\r$/, "")}
    NR==1 && $0=="---" {inFM=1; next}
    inFM && $0=="---" {exit}
    inFM && index($0, f ":")==1 {sub("^" f ":[[:space:]]*", ""); print; exit}' "$1"
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
      --bytes)   shift; bytes="${1:-}" ;;
      --surface) shift; surface="${1:-}"; surface_set=true ;;
      --file)    shift; file="${1:-}" ;;
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
        --bytes) shift; bytes="${1:-}"; shift; continue ;;
        --limit) shift; limit="${1:-}"; shift; continue ;;
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
      --out)              shift; out="${1:-}" ;;
      --role)             shift; role="${1:-}" ;;
      --review-set)       shift; rsid="${1:-}" ;;
      --artifact)         shift; aid="${1:-}" ;;
      --reviewer-version) shift; rver="${1:-}" ;;
      --prompt-version)   shift; pver="${1:-}" ;;
      --base-sha)         shift; bsha="${1:-}" ;;
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
      --from) shift; from="${1:-}" ;;
      --to)   shift; to="${1:-}" ;;
      --file) shift; qfile="${1:-}" ;;
      --wait) wait_flag="--wait" ;;
      -?*)    usage_err "ask: unknown option '$(clip "$1")'" ;;
      *)      words="${words:+$words }$1" ;;
    esac
    shift
  done
  [ -n "$from" ] || usage_err "ask: --from <agent> is required (who is asking)"
  [ -n "$to" ]   || usage_err "ask: --to <agent> is required"
  require_agent "$from" "ask"; require_agent "$to" "ask"
  [ "$from" != "$to" ] || usage_err "ask: '$from' cannot consult itself"
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
      case "$1" in --set) shift; set_id="${1:-}" ;; -?*) usage_err "panel status: unknown option '$(clip "$1")'" ;; esac
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
      if [ -n "$reply" ]; then answered=yes; verdict="$(cmd_verdict "$reply" 2>/dev/null || true)"; fi
      printf '%s\t%s\t%s\t%s\n' "$ag" "$th" "$answered" "$verdict"
    done; }
    return 0
  fi

  # ---- dispatch ----
  local to="" req="" set_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)  shift; to="${1:-}" ;;
      --set) shift; set_id="${1:-}" ;;
      -?*)   usage_err "panel dispatch: unknown option '$(clip "$1")'" ;;
      *)     [ -z "$req" ] || usage_err "panel dispatch: one review-request only"; req="$1" ;;
    esac
    shift
  done
  [ -n "$to" ] || usage_err "panel dispatch: --to a,b is required"
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
  local ag roster=""
  for ag in $(printf '%s' "$to" | tr ',' ' '); do
    require_agent "$ag" "panel dispatch"
    [ "$ag" != "$author" ] || usage_err "panel dispatch: '$ag' authored this request — it cannot review it"
    case " $roster " in *" $ag "*) usage_err "panel dispatch: '$ag' listed twice" ;; esac
    roster="$roster $ag"
  done
  roster="${roster# }"

  local aid pver dispatch_pair dispatch_base synthetic_note=""
  dispatch_pair="$(cmd_snapshot create --with-base)" || die "panel dispatch: could not retain the artifact"
  aid="${dispatch_pair%%	*}"
  dispatch_base="${dispatch_pair#*	}"
  [ "$dispatch_base" = "$dispatch_pair" ] && dispatch_base=""
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
    # Mirror cmd_snapshot's OWN resolution, including its fallback — re-querying blind is how the
    # r2 wrong-tree bug happened. (codex + grok, r3, advisory.)
    dirty_root="$(git rev-parse --show-toplevel 2>/dev/null || main_repo_root 2>/dev/null || true)"
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
  local plan_ag
  for plan_ag in $roster; do
    cmd_events append --kind panel-planned --set "$set_id" --dispatch "$dispatch_id" \
      --thread "${base_thread:-panel}" \
      --round "$round" --agent "$plan_ag" --artifact "$aid" \
      --request-id "$(frontmatter_field "$req" message_id)" --status planned \
      --note "roster=$(printf '%s' "$roster" | tr ' ' ',') legs=$(printf '%s' "$roster" | wc -w | tr -d ' ') phase=${phase:-} gating=$gating" \
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
    LC_ALL=C awk -v th="$leg_thread" -v mid="$leg_mid" -v setid="$set_id" -v aid="$aid" -v base="$dispatch_base" -v disp="$dispatch_id" '
      NR == 1 { nl = ($0 ~ /\r$/) ? "\r\n" : "\n" }
      { probe = $0; sub(/\r$/, "", probe) }
      NR == 1 && probe == "---" { fm = 1; print; next }
      fm && probe == "---" {
        printf "review_set: %s%s", setid, nl
        printf "dispatch: %s%s", disp, nl
        printf "artifact_id: %s%s", aid, nl
        if (base != "") printf "head_sha: %s%s", base, nl
        fm = 0; print; next
      }
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
    cmd_send --to "$ag" "$leg_file" || echo "  warning: leg for '$ag' did not deliver — the set is incomplete"
    n=$((n + 1))
  done
  echo "panel: $set_id dispatched to $n reviewer(s)$synthetic_note; compose with 'comms.sh panel status --set $set_id'"
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
  local set_id="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --set) shift; set_id="${1:-}" ;;
      --out) shift; out="${1:-}" ;;
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

  local rows="" ag th rnd req_mid reply cand n_legs=0 n_answered=0 pending="" unread="" blind=""
  while IFS=$'\t' read -r ag th rnd req_mid; do
    [ -n "$ag" ] || continue
    n_legs=$((n_legs + 1))
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
    n_answered=$((n_answered + 1))
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
    echo "compose: INCOMPLETE — no reply yet from:$pending ($n_answered of $n_legs legs answered)"
    echo "compose: refusing to gate on a partial panel; re-run when the set is complete"
    cmd_events append --kind composition-refused --set "$set_id" --dispatch "$compose_dispatch" --status partial \
      --note "$n_answered of $n_legs legs answered; no reply yet from:$pending" \
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
  # recurred 2026-09-03 (fwh-platform), confirmed here.
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
    printf '%s legs, all answered. %s findings (%s blocking).\n' "$n_legs" "${total:-0}" "${blocking:-0}"
    # Printed WITH the counts, not above them: the warning qualifies these numbers, and a
    # reader who takes the count without the caveat is the failure being prevented.
    [ -n "$unread" ] && printf '%s\n' "${unread# }"
    printf 'Anchored blocking findings supported by MORE THAN ONE reviewer: %s\n' "${corroborated:-0}"
    printf 'Anchors flagged by 2+ reviewers with differing severity: %s\n\n' "${mixed:-0}"
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
  } | {
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
  cmd_events append --kind composition-completed --set "$set_id" --dispatch "$compose_dispatch" --status composed \
    --note "legs=$n_legs findings=${total:-0} blocking=${blocking:-0} corroborated=${corroborated:-0} mixed=${mixed:-0}" \
    || echo "warning: coordinator log not updated (composition-completed)" >&2
  [ -z "$out" ] || echo "compose: wrote ${out#"$root"/}"
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
EVENT_KINDS=" panel-planned request-persisted request-dispatched message-dispatched turn-started provider-result turn-finished reply-validated reply-refused reply-accepted composition-completed composition-refused "
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
      --kind)       shift; kind="${1:-}" ;;
      --set)        shift; set_id="${1:-}" ;;
      --dispatch)   shift; dispatch="${1:-}" ;;
      --thread)     shift; thread="${1:-}" ;;
      --round)      shift; round="${1:-}" ;;
      --agent)      shift; agent="${1:-}" ;;
      --role)       shift; role="${1:-}" ;;
      --artifact)   shift; artifact="${1:-}" ;;
      --request-id) shift; reqid="${1:-}" ;;
      --message-id) shift; mid="${1:-}" ;;
      --run-dir)    shift; run_dir="${1:-}" ;;
      --status)     shift; status="${1:-}" ;;
      --note)       shift; note="${1:-}" ;;
      --limit)      shift; limit="${1:-}" ;;
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
    "$(event_identity "$mid" "$EVENT_W_MID")" "$(event_field "$run_dir" "$EVENT_W_RUNDIR")" \
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
      --thread)   shift; thread="${1:-}" ;;
      --severity) shift; sev="${1:-}" ;;
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
      --note) shift; note="${1:-}" ;;
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
  mkdir -p "$(dirname "$out")" 2>/dev/null || die "round-note: cannot create $(clip "$(dirname "$out")")"
  [ -s "$out" ] || printf 'timestamp\tthread\tphase\tround\treviewer\tverdict\tblocking\tadvisory\tprompt_version\tnote\n' > "$out"
  local clean_note; clean_note="$(printf '%s' "$note" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(frontmatter_field "$f" thread)" "$(frontmatter_field "$f" phase)" \
    "$(frontmatter_field "$f" round)" "$(frontmatter_field "$f" from)" \
    "$(cmd_verdict "$f" 2>/dev/null || true)" "${blocking:-0}" "${advisory:-0}" \
    "$(cmd_prompt_version 2>/dev/null || true)" "$clean_note" >> "$out"
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
      --to)           shift; to="${1:-}" ;;
      --review-set)   shift; rsid="${1:-}" ;;
      --out)          shift; out="${1:-}" ;;
      --timeout-secs) shift; timeout="${1:-}" ;;
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
  local shadow_via=""
  shadow_via="$(suppression_ok "$to")" \
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
  cmd_validate "$child_msg" >/dev/null || { shadow_cleanup; die "shadow: the mounted-artifact copy did not validate"; }

  local rver_now; rver_now="$(agent_version "$to")"
  local run_dir="$tmpdir/run"
  mkdir -p "$run_dir"
  echo "shadow: $to reviewing artifact ${aid} (set $rsid) in an isolated checkout — not delivered, cannot gate"
  local rc=0
  # The transport is the thing that MAKES suppression honourable for a self-sending agent, so it
  # is passed, not assumed: without it runphase refuses the flag at its own boundary — correctly.
  ( cd "$tree" && RUNPHASE_NO_DELIVER=1 "$rp" run --message "$child_msg" --dir "$run_dir" \
      --provider "$to" --no-deliver ${shadow_via:+--via "$shadow_via"} \
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
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)     shift; name="${1:-}" ;;
      --instance) shift; instance="${1:-}" ;;
      --role)     shift; role="${1:-}" ;;
      --state)    shift; state="${1:-}" ;;
      --pid)      shift; pid="${1:-}" ;;
      --force)    shift; force="${1:-}" ;;
      --no-heartbeat) presence_no_heartbeat=1 ;;
      --) shift; break ;;
      -?*) usage_err "presence $sub: unknown option '$(clip "$1")'" ;;
      *) break ;;
    esac
    shift
  done
  local dir; dir="$(presence_dir)"
  case "$sub" in
    claim)
      [ -n "$name" ] || usage_err "presence claim: --name required"
      presence_validate_ids "$name" \
        || usage_err "presence claim: invalid name '$(clip "$name")'"
      case "$pid" in *[!0-9]*) usage_err "presence claim: --pid must be numeric" ;; esac
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
      [ -d "$dir" ] || return 0
      [ -r "$dir" ] || { echo "presence: sessions dir unreadable — ISOLATE" >&2; return 4; }
      presence_peers "$name" "$instance"
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
      trap 'latched=INT;  kill -INT  -- ${child:+-$child} ${beater:+-$beater} 2>/dev/null || true' INT
      trap 'latched=TERM; kill -TERM -- ${child:+-$child} ${beater:+-$beater} 2>/dev/null || true' TERM
      [ -n "$name" ] && [ -n "$instance" ] || usage_err "presence with-beat: --name and --instance required"
      presence_validate_ids "$name" "$instance" || usage_err "presence with-beat: invalid name/instance"
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
          "$0" presence beat --name "$name" --instance "$instance" >/dev/null 2>&1 || brc=$?
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
      rc=0; wait "$child" || rc=$?
      # QUIESCENCE before return (codex, impl r4): the wrapper's success must mean
      # the child's whole group is GONE — integrate trusts the tree state on
      # return, and a straggling suite descendant made a same-shaped model return
      # 0 two seconds early. Sweep with the latched identity (or TERM), then
      # bounded escalation to KILL, then FAIL CLOSED if the group still breathes.
      local sweep_sig="${latched:-TERM}" qn=0
      kill -"$sweep_sig" -- "-$child" 2>/dev/null || true
      while kill -0 -- "-$child" 2>/dev/null; do
        qn=$((qn + 1)); [ "$qn" -ge 50 ] && break; sleep 0.1 || true
      done
      if kill -0 -- "-$child" 2>/dev/null; then
        kill -KILL -- "-$child" 2>/dev/null || true
        qn=0
        while kill -0 -- "-$child" 2>/dev/null; do
          qn=$((qn + 1)); [ "$qn" -ge 20 ] && break; sleep 0.1 || true
        done
      fi
      # (sleep || true — a group-INT during the poll aborted the wrapper before
      # KILL escalation; could not land, could leak a descendant. grok, impl r5.)
      if kill -0 -- "-$child" 2>/dev/null; then
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
  local dir="$1" force="$2" reap="$dir/.reap" now f base obs oepoch nonce tomb tepoch
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
    if ! tail -n +2 "$obs" | cmp -s - "$f"; then
      rm -f "$obs" 2>/dev/null; continue          # a beat intervened — abort in-progress reap
    fi
    # Reap: tombstone BEFORE unlink (r9), nonce-named (r10), then the record.
    nonce="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    tomb="$reap/$base.tomb.$nonce"
    printf '#tomb %s\n' "$now" > "$reap/.tmp.$$" 2>/dev/null \
      && command mv -f "$reap/.tmp.$$" "$tomb" 2>/dev/null || { rm -f "$obs"; continue; }
    rm -f "$f" 2>/dev/null
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
  return 0
}

cmd_worktree() {
  # worktree new [<slug>] — a session worktree under the MAIN root (never nested,
  # never cwd-relative: the two-resolver rule, third appearance — grok, plan r7),
  # branched from the LOCAL default-branch tip (origin can lag a full unpushed day).
  local sub="${1:-new}"; shift 2>/dev/null || true
  [ "$sub" = "new" ] || usage_err "worktree: expected 'new'"
  local slug="${1:-session-$$-$RANDOM}"
  # Whole-scalar check before grep, same rule as presence_validate_ids: grep
  # validates LINES, and the slug becomes a path and a branch name. Git happens
  # to refuse newline-bearing refs today, but the validator must not lean on it.
  # (codex, impl r8 advisory.)
  case "$slug" in *$'\n'*|*$'\r'*) usage_err "worktree new: invalid slug '$(clip "$slug")'" ;; esac
  printf '%s' "$slug" | grep -qE '^[a-z0-9][a-z0-9._-]{0,40}$' \
    || usage_err "worktree new: invalid slug '$(clip "$slug")'"
  local root tip path branch
  root="$(main_repo_root)"; [ -n "$root" ] || die "worktree new: cannot resolve the main repo root"
  tip="$(git -C "$root" rev-parse --verify refs/heads/main 2>/dev/null \
      || git -C "$root" rev-parse --verify refs/heads/master 2>/dev/null)" \
    || die "worktree new: no local main/master tip to branch from"
  path="$root/.claude/worktrees/$slug"; branch="worktree-$slug"
  [ -e "$path" ] && die "worktree new: $path already exists"
  git -C "$root" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1 \
    && die "worktree new: branch $branch already exists"
  # The ignore coverage is load-bearing: an unignored in-checkout worktree walks a
  # full second repo copy into every review artifact. Verified, not assumed.
  mkdir -p "$root/.claude/worktrees" 2>/dev/null || true
  git -C "$root" check-ignore -q ".claude/worktrees/$slug" \
    || die "worktree new: .claude/worktrees/ is not ignore-covered — refusing (re-run install.sh or restore the .gitignore entry)"
  git -C "$root" worktree add -b "$branch" "$path" "$tip" >/dev/null 2>&1 \
    || die "worktree new: git worktree add failed"
  echo "worktree: $path"
  echo "branch:   $branch (from $(git -C "$root" rev-parse --short "$tip"))"
}

config_scalar() {  # <root> <key> — the ONE way any consumer reads a config scalar.
  # Duplicate rejection has to live at the READ, not in a validator the caller
  # may never invoke: `registry_parse` refused duplicates but `integrate` never
  # calls it, so an appended `suite-attest-secs = 0` meant to DISABLE the skip
  # still lost to the earlier enabling value on the one command where safety
  # matters. Every consumer now fails the same way. (codex, ergonomics r2.)
  local f="$1/.comms/config" key="$2" ct
  [ -f "$f" ] || return 0
  ct="$(grep -c "^[[:space:]]*$key[[:space:]]*=" "$f" 2>/dev/null || true)"
  [ "${ct:-0}" -le 1 ] || die "config: duplicate '$key' key in $f — refusing to guess which value is authoritative"
  { sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$f" 2>/dev/null || true; } | head -1
}

cmd_attest_green() {
  # attest-green [--passed N] — record "the suite ran green at this exact commit".
  # The record lets integrate skip its re-verification when the SAME OID was
  # verified moments ago: without it every landing costs two full suite runs — the
  # pre-flight and integrate's re-run — of which the second proves nothing new
  # (user, 2026-08-27: ~24 minutes to merge a branch). Consumption is opt-in
  # (suite-attest-secs in .comms/config) and time-bounded; the paranoid re-run
  # stays the default.
  # A value-taking flag REQUIRES its value: the bare `shift; var="${1:-}"` shape
  # leaves $# at 0 and the loop's trailing shift then exits 1 under errexit with
  # no diagnostic — a usage error that reads as a crash. (grok, r1.)
  local passed="" expect=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --passed) [ $# -ge 2 ] || usage_err "attest-green: --passed needs a value"; shift; passed="$1" ;;
      --expect) [ $# -ge 2 ] || usage_err "attest-green: --expect needs a value"; shift; expect="$1" ;;
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

cmd_integrate() {
  # integrate <branch> — land a session branch on main: advisory lease, ff-only,
  # suite at the CANDIDATE OID in a throwaway detached worktree, then the CAS
  # update-ref. The lease is an economizer; the CAS is the safety. main never
  # holds WORK: it moves by ref, verified first. One clean checkout may idle on
  # it as a console — that one is healed through the landing, not refused.
  # (Plan r3-r6; the idle-console exception 2026-08-27.)
  local branch="${1:-}"; shift 2>/dev/null || true
  [ -n "$branch" ] || usage_err "integrate: a branch is required"
  local name="${COMMS_PRESENCE_NAME:-}" instance="${COMMS_PRESENCE_INSTANCE:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) shift; name="${1:-}" ;;
      --instance) shift; instance="${1:-}" ;;
      -?*) usage_err "integrate: unknown option '$(clip "$1")'" ;;
    esac; shift
  done
  local root; root="$(main_repo_root)"; [ -n "$root" ] || die "integrate: no main repo root"
  local suite_cmd
  suite_cmd="$(config_scalar "$root" suite-cmd)"
  [ -n "$suite_cmd" ] || die "integrate: no 'suite-cmd = ...' in .comms/config — refusing to land unverified (explicit configuration required)"
  # Advisory lease: refuse while any OTHER live presence is integrating. The scan
  # fails CLOSED on an unenumerable dir — a silent empty glob read as lease-free
  # (CAS keeps correctness, but blind concurrent suites are waste). (codex+grok, impl r3.)
  local dir f
  dir="$(presence_dir)"
  if [ -d "$dir" ] && { [ ! -r "$dir" ] || [ ! -x "$dir" ]; }; then
    die "integrate: sessions dir unreadable — cannot verify the integrating lease; refusing"
  fi
  if [ -d "$dir" ]; then
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      [ "$(basename "$f" .json)" = "$name-$instance" ] && continue
      [ "$(presence_field "$f" state)" = "integrating" ] || continue
      [ "$(presence_eval "$f")" = "dead" ] && continue
      die "integrate: $(presence_field "$f" name) holds a live integrating lease — serialize (advisory; re-run when it releases)"
    done
  fi
  if [ -n "$name" ] || [ -n "$instance" ]; then
    presence_validate_ids "$name" "$instance" || die "integrate: invalid presence name/instance"
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
  trap "git -C '$root' worktree remove --force '$tw' >/dev/null 2>&1 || true; rm -rf '$tw' 2>/dev/null || true; if [ -n '$name' ] && [ -f '$presence_record' ]; then '$0' presence beat --name '$name' --instance '$instance' --state working >/dev/null 2>&1 || true; fi" EXIT
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
    "$0" presence beat --name "$name" --instance "$instance" --state integrating >/dev/null 2>&1 || true
  fi
  expected="$(git -C "$root" rev-parse --verify refs/heads/main 2>/dev/null)" || die "integrate: no refs/heads/main"
  cand="$(git -C "$root" rev-parse --verify "$branch^{commit}" 2>/dev/null)" || die "integrate: cannot resolve '$branch'"
  echo "integrate: candidate $cand (from $branch), expected main $expected"
  git -C "$root" merge-base --is-ancestor "$expected" "$cand" \
    || die "integrate: $branch is not a descendant of main — rebase first (ff-only)"
  # NEVER-OCCUPY-MAIN, decided BEFORE the suite: refusing after a green
  # 10-minute run is the expensive way to learn main was occupied (user,
  # 2026-08-27 — the arc's own first landing hit exactly that). ONE clean
  # occupant parked exactly at the expected tip is SELF-HEALED — detached now,
  # re-attached to main after the CAS — because that is the root checkout idling
  # on main, the common case, and re-pointing an idle clean tree is just a
  # fast-forward. Anything else (dirty, diverged, multiple occupants) refuses:
  # re-pointing a tree someone is working in corrupts their session.
  local heal_list occ occ_n occ_head occ_status healed=""
  heal_list="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || die "integrate: cannot enumerate worktrees — refusing"
  occ="$(printf '%s\n' "$heal_list" | LC_ALL=C awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/main$/{print p}')"
  if [ -n "$occ" ]; then
    occ_n="$(printf '%s\n' "$occ" | grep -c .)"
    [ "$occ_n" = 1 ] || die "integrate: main is checked out in $occ_n worktrees — refusing (never-occupy-main)"
    occ_head="$(git -C "$occ" rev-parse --verify HEAD 2>/dev/null)" || die "integrate: cannot read main occupant's HEAD ($occ) — refusing (never-occupy-main)"
    [ "$occ_head" = "$expected" ] || die "integrate: main occupant $occ sits at $occ_head, not the main tip — refusing (never-occupy-main)"
    occ_status="$(git -C "$occ" status --porcelain -uno 2>/dev/null)" || die "integrate: cannot read main occupant's status ($occ) — refusing (never-occupy-main)"
    [ -z "$occ_status" ] || die "integrate: main occupant $occ has uncommitted changes — refusing (never-occupy-main; commit them or move it off main)"
    git -C "$occ" checkout --detach >/dev/null 2>&1 || die "integrate: could not detach main occupant $occ — refusing (never-occupy-main)"
    healed="$occ"
    # Re-arm the trap WITH the undo baked in as a literal: a die past this point
    # must put the occupant back on main, not strand it detached. The undo is
    # CONDITIONAL on main still being at the tip we detached from — another
    # writer may have advanced it, and silently attaching an idle console to a
    # tip this run never verified is not the promise "unmoved main" made.
    # (codex, r1.) Leaving it detached is the safe residual; the message says so.
    # shellcheck disable=SC2064
    trap "git -C '$root' worktree remove --force '$tw' >/dev/null 2>&1 || true; rm -rf '$tw' 2>/dev/null || true; if [ \"\$(git -C '$root' rev-parse --verify refs/heads/main 2>/dev/null)\" = '$expected' ] && [ \"\$(git -C '$healed' rev-parse HEAD 2>/dev/null)\" = '$expected' ]; then git -C '$healed' checkout main >/dev/null 2>&1 || true; else echo \"integrate: left $healed detached at \$(git -C '$healed' rev-parse --short HEAD 2>/dev/null || true) — main or the checkout moved during the attempt\" >&2 || true; fi; if [ -n '$name' ] && [ -f '$presence_record' ]; then '$0' presence beat --name '$name' --instance '$instance' --state working >/dev/null 2>&1 || true; fi" EXIT
    echo "integrate: healed — detached clean main occupant $occ for the landing"
  fi
  # ATTESTED GREEN: when .comms/config opts in (suite-attest-secs = N), a fresh
  # attest-green record for EXACTLY this candidate OID stands in for the re-run —
  # the tree cannot have changed under an identical commit id, so the second run
  # proves nothing the first did not. Absent, stale, or wrong-OID attestations
  # fall through to the full suite; with no config the behavior is unchanged.
  local attest_secs attest_age="" skip_suite=""
  attest_secs="$(config_scalar "$root" suite-attest-secs)"
  case "$attest_secs" in ''|*[!0-9]*) attest_secs=0 ;; esac
  if [ "$attest_secs" -gt 0 ] && [ -f "$root/.comms/cache/suite-attest.log" ]; then
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
    # Recover any prior crash's stale registration before adding: remove the entry
    # if git still knows it, prune dangling metadata, then clear the directory.
    git -C "$root" worktree remove --force "$tw" >/dev/null 2>&1 || true
    git -C "$root" worktree prune >/dev/null 2>&1 || true
    rm -rf "$tw" 2>/dev/null || true
    git -C "$root" worktree add --detach "$tw" "$cand" >/dev/null 2>&1 || die "integrate: could not materialize $cand"
    # Structured argv: whitespace split only, nothing shell-interpreted. An
    # empty/whitespace-only suite-cmd expanded to zero argv and SUCCEEDED as a
    # no-op — the exact unverified landing the config gate exists to refuse.
    # (codex, impl r1.)
    set -f; set -- $suite_cmd; set +f
    [ $# -gt 0 ] || die "integrate: suite-cmd is empty after splitting — refusing to land unverified"
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
      || die "integrate: /usr/bin/env is missing — refusing to run the suite unpinned"
    local -a clean_env
    clean_env=(command /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD)
    # Keep the output of the run we are judging. A refusal whose evidence was discarded
    # cannot be diagnosed, which cost a full investigation earlier in this arc.
    local suite_log; suite_log="$root/.comms/logs/integrate-${cand}.suite.log"
    mkdir -p "$root/.comms/logs" 2>/dev/null || true
    # errexit is suspended ACROSS the pipeline: with `set -e -o pipefail` a red suite
    # terminates the helper AT the pipeline, so `rc=${PIPESTATUS[0]}` never runs and the
    # "suite FAILED ... output kept at ..." diagnostic below is unreachable on exactly the
    # path it describes. Landing stayed fail-closed, but the operator lost the message.
    # (codex, panel r5, advisory — the same errexit class as the assignment above.)
    set +e
    # THIRD SITE, and the one no short test could reach: `with-beat`'s beater sleeps TTL/3
    # (default 900s) and then beats, which HEALS an absent record — manufacturing the same
    # pid-less, unreapable record the two explicit gates prevent, fifteen minutes in, long
    # after every fixture had finished. (codex + grok, integrate-beat r5.)
    if [ -n "$name" ] && [ -n "$instance" ]; then
      # SUPERVISION ALWAYS; heartbeat only when there is a record to refresh. Running the
      # suite unwrapped to avoid the healing beat gave up whole-process-group quiescence,
      # and that is load-bearing: a suite can print its completion line, launch a
      # stdio-detached descendant and exit 0, leaving it alive to mutate the verification
      # tree after integrate validates and advances main. `--no-heartbeat` keeps the
      # supervision and drops only the beater. (codex, integrate-beat r6, blocking.)
      local hb=""
      [ -f "$presence_record" ] || hb="--no-heartbeat"
      # shellcheck disable=SC2086
      ( cd "$tw" && "${clean_env[@]}" "$0" presence with-beat $hb --name "$name" --instance "$instance" -- "$@" ) 2>&1 | tee "$suite_log"
      rc=${PIPESTATUS[0]}
    else
      ( cd "$tw" && "${clean_env[@]}" "$@" ) 2>&1 | tee "$suite_log"
      rc=${PIPESTATUS[0]}
    fi
    set -e
    # THE FRESH-CHECKOUT HINT. The verification tree is materialized by `git worktree add`,
    # so it carries TRACKED CONTENT ONLY — no untracked and no ignored files. A suite-cmd that
    # passes in the operator's checkout and fails here is usually depending on something that
    # checkout has and this one does not, and the tool's own error (a missing-module code, say)
    # gives no reason to suspect the TREE. Deliberately generic: naming any one ecosystem's
    # directory would teach this tool what `node_modules` is, and the same shape covers an
    # ignored `.npmrc`, a `.env`, or a build cache. Worded as a LIKELY cause, not a verdict —
    # most suite failures really are just failures. (codex + grok, plan r1.)
    [ "$rc" = 0 ] || die "integrate: suite FAILED ($rc) at $cand — main untouched; full output kept at $suite_log
integrate: note — the verification tree is a FRESH checkout of the candidate: untracked and
integrate: ignored files are absent. If this suite passes in your working checkout, the likely
integrate: cause is suite-cmd depending on something only that checkout has; suite-cmd must
integrate: provision its own prerequisites. Read $suite_log for the underlying failure."
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
        || die "integrate: the suite exited 0 but emitted no completion line — it did not run to the end (a shell-startup hook can pre-empt it); refusing. Output: $suite_log"
      [ "$proof_fail" = 0 ] \
        || die "integrate: the suite reported $proof_fail failures despite exit 0 — refusing. Output: $suite_log"
      [ "$((proof_pass + proof_skip))" = "$exp_total" ] \
        || die "integrate: the suite ran $((proof_pass + proof_skip)) of $exp_total assertions the candidate declares — refusing a partial run. Output: $suite_log"
    fi
    # BIND the result to the candidate: a suite that checked out another OID and
    # passed there proves nothing about $cand. Every verification below fails
    # CLOSED — a command that cannot answer refuses the landing. (codex, impl r1.)
    local tw_head tw_status
    tw_head="$(git -C "$tw" rev-parse HEAD 2>/dev/null)" || die "integrate: cannot read the verification tree's HEAD — refusing"
    [ "$tw_head" = "$cand" ] || die "integrate: the verification tree is at $tw_head, not the candidate $cand — the suite result is not about this landing; refusing"
    tw_status="$(git -C "$tw" status --porcelain 2>/dev/null)" || die "integrate: cannot read the verification tree's status — refusing"
    # SIBLING OF THE HINT ABOVE, and the one an operator acting on that hint hits next: told to
    # provision prerequisites, they write a wrapper, and it lands here if its output is
    # git-VISIBLE. Ignored output is fine — an installed dependency tree is the intended shape.
    # Untracked-but-unignored files and modified tracked files are not, and a package manager
    # that rewrites a tracked lockfile produces exactly the latter. Print the dirt: "refusing to
    # trust the result" without saying WHAT dirtied it is a refusal nobody can act on.
    # (grok, plan r1 — worth more here than on the suite-FAILED path.)
    [ -z "$tw_status" ] || die "integrate: the suite dirtied the verification tree — refusing to trust the result
integrate: note — suite-cmd MAY create IGNORED files (an installed dependency tree is fine); it
integrate: may NOT leave git-visible changes. Modified tracked files and untracked-but-unignored
integrate: output both land here. Dirt:
$tw_status"
  fi
  # Final occupancy guard — a checkout could have moved onto main DURING the
  # suite; the CAS must still never move a ref under a live working tree.
  local wt_list
  wt_list="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || die "integrate: cannot enumerate worktrees — refusing"
  printf '%s\n' "$wt_list" | grep -qx 'branch refs/heads/main' \
    && die "integrate: main is checked out somewhere — refusing (never-occupy-main)"
  git -C "$root" update-ref refs/heads/main "$cand" "$expected" \
    || die "integrate: main moved (CAS refused) — nothing landed; re-run to re-verify against the new tip"
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
      echo "integrate: warning — $healed moved to $heal_now during the landing; left detached (its commits are intact, re-attach by hand)"
    elif git -C "$healed" checkout main >/dev/null 2>&1; then
      echo "integrate: healed occupant $healed fast-forwarded onto the new main"
    else
      echo "integrate: warning — could not re-attach $healed to main; it is parked detached at $expected"
    fi
  fi
  # Same rule: only refresh a record that exists. Nothing here manufactures one.
  if [ -n "$name" ] && [ -n "$instance" ] && [ -f "$(presence_dir)/$name-$instance.json" ]; then
    "$0" presence beat --name "$name" --instance "$instance" --state working >/dev/null 2>&1 || true
  fi
  trap - EXIT
  if [ -n "$skip_suite" ]; then
    echo "integrate: LANDED $cand as main (was $expected); green by attestation (${attest_age}s old)"
  else
    echo "integrate: LANDED $cand as main (was $expected); suite green at the landed OID"
  fi
}

cmd_snapshot() {
  # snapshot [create|list] — RETAIN the tree under review as a durable git object.
  #
  # A hash alone cannot resurrect the input, so this stores CONTENT: the working
  # tree (tracked edits and untracked files, mailbox excluded) is written as a
  # real commit object without touching the worktree, the index, or the stash.
  # That commit starts unreferenced and would be garbage-collected, so it is
  # anchored under refs/agent-comms/ — the anchor IS the retention, and without
  # it the artifact this prerequisite exists to keep silently evaporates.
  local sub="${1:-create}" with_base=false
  [ "${2:-}" = "--with-base" ] && with_base=true
  local root id
  # The reviewer's working directory IS the tree under review (runphase's review
  # prompt says so), and in a linked worktree that is NOT the main root — snapshotting
  # main_repo_root there would retain a tree nobody reviewed. (grok, live 2026-08-22.)
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || root="$(main_repo_root)"
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
  # Then drop the mailbox MECHANICALLY rather than trusting .gitignore: a grades
  # artifact must never carry message bodies into a git object that could later
  # be pushed. Same boundary rule as the archive-search scope fix. (An exclude
  # PATHSPEC cannot do this — `git add` reads it as naming an ignored path and
  # fails the whole command.)
  GIT_INDEX_FILE="$idx" git -C "$root" rm --cached -r -q --ignore-unmatch -- .comms .agent-comms .claude/worktrees 2>/dev/null \
    || { rm -rf "$idxdir"; die "snapshot: cannot exclude the mailbox from the artifact"; }
  # .claude/worktrees joins the mechanical strip: an in-checkout session worktree is
  # a full second repo copy, and relying on .gitignore alone let one walk into a
  # sibling loop's review artifact before 7dc08b4. Mechanical, like the mailbox.
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
  if [ -n "$from_agent" ] && ! registry_has "$from_agent"; then
    errors="${errors}  from '$from_agent' is not a registered agent (registered: $(registry_agents))\n"
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
      --as) shift; as="${1:-}" ;;
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
    if "$rp" run --message "$msgfile" --dir "$fg_dir" --provider "$target" >>"$fg_dir/runner.log" 2>&1; then
      echo "completed: $target finished; the reply is in the inbox"
      return 0
    fi
    echo "warning: $target's foreground turn failed — see $fg_dir/result.json"
    return 0
  fi
  local out
  if out="$("$rp" spawn --provider "$target" --message "$msgfile" 2>&1)"; then
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
suppression_ok() {  # <agent> -> echoes "acp" | "" ; rc 1 if suppression cannot be honoured
  case "$(cmd_agents --supported | awk -v a="$1" -F'\t' '$1==a {print $2}')" in
    *reviewer-consult-only*) printf ''; return 0 ;;   # brokered on every path already
  esac
  # Otherwise only ACP makes it honourable: the parent stamps and delivers, the child never sends.
  if acp_supports "$1"; then printf 'acp'; return 0; fi
  return 1
}

acp_supports() {  # <agent> — can an ACP turn actually run here for this agent?
  local acp_sh; acp_sh="$(dirname "$SELF")/acp.sh"
  [ -x "$acp_sh" ] || return 1
  "$acp_sh" supports "$1" >/dev/null 2>&1
}

# headless_ok <agent> — may this agent take the headless transport? Only a provider that is
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

  # HEADLESS IS NO LONGER UNIVERSAL. It used to route a SELF-SENDING child, and that arm is gone
  # (step 4, S4-2), so it is valid only for a provider that is parent-brokered WITHOUT ACP. grok is
  # that provider today; claude/codex must go through ACP or fail closed in runphase. Keyed on the
  # registry marker rather than the name, so a second brokered provider needs no edit here.
  if [ "${COMMS_DELIVERY:-}" = "headless" ]; then
    headless_ok "$agent" && { printf 'headless\n'; return 0; }
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
  caps="$(cmd_agents --supported | awk -v a="$agent" -F'\t' '$1==a {print $2}')"

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
    if acp_supports "$agent"; then printf 'acp\n'; return 0; fi
    # Fall back to headless only when ACP is genuinely unavailable: flipping the default
    # must not strand every loop on an install where runphase.sh never landed. There is no
    # pane arm below this any more — cmux was deleted in step 4 (S4-4).
    if runphase_available && headless_ok "$agent"; then printf 'headless\n'; return 0; fi
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
  if [ "$mode" = "consult" ] && acp_supports "$agent"; then printf 'acp\n'; return 0; fi
  case "$caps" in *interactive*) ;; *) headless_ok "$agent" && { printf 'headless\n'; return 0; } ;; esac
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
      case "$target" in
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
    if [ "$st" != "complete" ] && [ -n "$pending" ] && [ "$age_s" -gt 900 ]; then
      echo "ACTION NEEDED: $(basename "$pending") is still unread after $(( age_s / 60 ))m (last_delivery=$deliv). Nudge $target directly, or re-send with 'comms.sh send'."
    # Live headless outcomes are not operator-action cases: spawned = turn in
    # flight, completed = reply is (or was) in the inbox for the driver to read,
    # held = the operator paused deliberately, pickup = designed reply-to-driver
    # no-op. failed/timeout from a headless turn DO shout, like a failed nudge.
    elif [ "$st" != "complete" ] && [ -n "$deliv" ] \
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

# (safe_name is defined above cmd_workspace — thread/message/cache values all
# become filename components, so anything outside [A-Za-z0-9._-] maps to '_'.)

# Minimal JSON string escaping so embedded quotes/backslashes can't produce
# invalid state files.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

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
  # The EXPLICIT send --to target is authoritative for who owes the next message
  # — a complement of the sender is only a two-party assumption and breaks at
  # three agents. The complement remains solely as a fallback for callers that
  # cannot supply a target.
  if [ -n "$awaiting_override" ]; then
    awaiting_from="$awaiting_override"
  else
    case "$from" in
      claude) awaiting_from=codex ;;
      codex)  awaiting_from=claude ;;
      *)      awaiting_from=unknown ;;
    esac
  fi
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
    *) die "state: unknown subcommand '$sub' (get|list|complete)" ;;
  esac
}

cmd_stalled() {
  local mins="${1:-15}" dir ws now f age_s since deliv rd note pid owes mid root
  root="$(cmd_root)"; dir="$root/state"; ws="$(cmd_workspace)"; now="$(date +%s)"
  local any=false
  for f in "$dir/${ws}_"*.json; do
    [ -f "$f" ] || continue
    [ "$(json_get "$f" awaiting_from)" = "none" ] && continue
    [ "$(json_get "$f" status)" = "complete" ] && continue
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
  local as="" yes=false orphans=false mode="" targets=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) shift; as="${1:-}" ;;
      --yes) yes=true ;;
      --orphans) orphans=true ;;
      *) [ -z "$mode" ] && mode="$1" || die "clean: unexpected argument '$1'" ;;
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
    "$rp" clean-mounts ${mflags[@]+"${mflags[@]}"}
    return $?
  fi
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

cmd_send() {
  # Refuse BEFORE any durable write. `panel dispatch` calls this directly and had already
  # written its attempt marker, roster events, leg files and index rows before delivery failed —
  # and its `cmd_send … || echo` swallowed the failure into "incomplete legs". (codex, r3, blocking.)
  require_known_transport
  local to="" file="" archive_inbound="" as=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --to) shift; to="${1:-}" ;;
      --wait) COMMS_WAIT=1; export COMMS_WAIT ;;
      --archive-inbound) shift; archive_inbound="${1:-}" ;;
      *) file="$1" ;;
    esac
    shift
  done
  [ -n "$to" ] || die "send: --to <agent> is required (registered: $(registry_agents))"
  require_agent "$to" "send"
  [ -n "$file" ] || die "send: outbound file argument required"

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
  # fm_field_lines <file> <field> — every value line of <field> in the frontmatter,
  # blank values preserved as empty lines. Consumers must read this via PROCESS
  # SUBSTITUTION, never $() into a heredoc: command substitution strips trailing
  # newlines, which made a trailing blank duplicate line invisible to the
  # validation loops. (codex, stamped-authorities round 4.)
  fm_field_lines() {
    LC_ALL=C awk -v f="$2" '{sub(/\r$/,"")} NR==1 && $0=="---"{fm=1;next} fm && $0=="---"{exit} fm && index($0, f ":")==1 {sub("^" f ":[[:space:]]*", ""); print}' "$1"
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
  if [ -n "$(frontmatter_field "$file" workflow)" ]; then
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
  # `RESULT:` line is a parsed contract (`tail -1`) and the open `ask` false-failure already
  # mis-derives outcomes from captured stdout on this path. Scoped as grok put it: "do not touch
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
    local live_sha
    live_sha="$(git -C "$(git rev-parse --show-toplevel 2>/dev/null || main_repo_root)" rev-parse -q --verify HEAD 2>/dev/null || true)"
    [ -n "$live_sha" ] && stamp_head_sha "$file" "" "$live_sha"
  fi

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
  local ev_type ev_thread ev_round ev_set ev_dispatch ev_aid ev_mid ev_agent ev_reqid
  ev_type="$(frontmatter_field "$file" type)"
  ev_thread="$(frontmatter_field "$file" thread)"
  ev_round="$(frontmatter_field "$file" round)"
  ev_set="$(frontmatter_field "$file" review_set)"
  ev_dispatch="$(frontmatter_field "$file" dispatch)"
  ev_aid="$(frontmatter_field "$file" artifact_id)"
  ev_mid="$(frontmatter_field "$file" message_id)"
  case "$ev_type" in
    review-feedback) ev_agent="$(frontmatter_field "$file" from)"; ev_reqid="$(frontmatter_field "$file" in-reply-to)" ;;
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
      --note "phase=$(frontmatter_field "$file" phase) workflow=$(frontmatter_field "$file" workflow)" \
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
  rundir="$(printf '%s\n' "$del_out" | sed -n 's/^ *run dir: //p' | head -1)"
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
    *FAILED*)             outcome=failed ;;
    *"spawned runphase"*) outcome=spawned ;;
    *"already running"*)  outcome=spawned ;;   # headless re-send: turn already in flight
    *"HELD:"*)            outcome=held ;;      # thread paused by a hold marker
    *"no nudge needed"*)  outcome=pickup ;;    # designed no-op: reply to the driving session
  esac
  # Record thread ground truth (workflow messages with a thread only). The
  # ||-context also suppresses errexit inside the function, so NO state failure
  # mode — mkdir, redirect, parse — can abort send before the inbound archive.
  state_update_from "$file" "$outcome" "$rundir" "$to" || echo "warning: thread state not recorded" >&2
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
    review-feedback) ev_kind=reply-accepted;     ev_status="$(cmd_verdict "$file" 2>/dev/null || true)" ;;
    *)               ev_kind=message-dispatched; ev_status="$outcome" ;;
  esac
  if ! cmd_events append --kind "$ev_kind" --set "$ev_set" --dispatch "$ev_dispatch" --thread "$ev_thread" \
      --round "$ev_round" --agent "$ev_agent" --artifact "$ev_aid" --request-id "$ev_reqid" \
      --message-id "$ev_mid" --run-dir "$rundir" --status "${ev_status:-$outcome}" \
      --note "type=$ev_type delivery=$outcome"; then
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
    "$0" presence beat --name "$COMMS_PRESENCE_NAME" --instance "$COMMS_PRESENCE_INSTANCE" || true
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
  list)      shift; cmd_list "$@" ;;
  status)    shift; cmd_status "$@" ;;
  validate)  shift; cmd_validate "$@" ;;
  verdict)   shift; cmd_verdict "$@" ;;
  archive)   shift; cmd_archive "$@" ;;
  deliver)   shift; cmd_deliver "$@" ;;
  transport) shift; cmd_transport "$@" ;;
  send)      shift; cmd_send "$@" ;;
  state)     shift; cmd_state "$@" ;;
  presence)  shift; cmd_presence "$@" ;;
  worktree)  shift; cmd_worktree "$@" ;;
  integrate) shift; cmd_integrate "$@" ;;
  attest-green) shift; cmd_attest_green "$@" ;;
  stalled)   shift; cmd_stalled "$@" ;;
  clean)     shift; cmd_clean "$@" ;;
  lessons)        shift; cmd_lessons "$@" ;;
  archive-search) shift; cmd_archive_search "$@" ;;
  findings)       shift; cmd_findings "$@" ;;
  ask)            shift; cmd_ask "$@" ;;
  panel)          shift; cmd_panel "$@" ;;
  compose)        shift; cmd_compose "$@" ;;
  round-note)     shift; cmd_round_note "$@" ;;
  events)         shift; cmd_events "$@" ;;
  friction)       shift; cmd_friction "$@" ;;
  shadow)         shift; cmd_shadow "$@" ;;
  snapshot)       shift; cmd_snapshot "$@" ;;
  prompt-version) shift; cmd_prompt_version "$@" ;;
  ""|help|-h|--help)
    # Print the whole header comment block rather than a hardcoded line range —
    # a fixed range silently truncates its own last entry as the block grows.
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
    ;;
  *) die "unknown subcommand '${1}' — run 'comms.sh help'" ;;
esac
