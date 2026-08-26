#!/bin/bash
# agent-comms shared helper — the single source of truth for shell logic that was
# previously copy-pasted across the command/skill templates (and drifted).
#
# Always executed (never sourced), always bash — the caller's shell (zsh, etc.)
# and Claude Code's slash-command $N argument substitution cannot affect it.
#
# Subcommands:
#   root                        print the main repo's .comms path (worktree-safe)
#   workspace                   print the workspace name (cmux > branch > repo dir)
#   doctor                      verify this session can reach the cmux socket
#   codex-permissions [socket]  print least-privilege Codex config for cmux delivery
#   agents [default|--supported]   registered agents from .comms/config (zero-config
#                                  default: claude codex / target codex)
#   list --as <agent> [--thread <t>]   pending inbox messages, newest first
#   status                      one-screen loop state: latest archive, verdict, pending counts
#   validate <file>             frontmatter + body checks; non-zero exit and reasons on failure
#   verdict <file>              normalized (trimmed, uppercased) verdict from frontmatter
#   archive --as <agent> <file...>   idempotent move to archive/; own inbox only
#   deliver <agent> [file]   nudge the target (cmux pane for claude/codex; headless-only agents route via runphase); reports delivered/
#                               manual-pickup/FAILED explicitly (never hard-fails).
#                               COMMS_DELIVERY=headless routes to runphase.sh instead
#                               (detached codex exec / claude -p turn for the target)
#   transport <agent> [--loop]  which transport would actually be used right now:
#                               headless | cmux | acp | mailbox. One decision point, so
#                               templates never re-implement surface detection.
#   send --to <agent> <file> [--wait] [--archive-inbound <file>]
#                               --wait runs the peer turn in the FOREGROUND instead of
#                               detaching — required inside sandboxes that reap the
#                               children of a finished shell command.
#                               validate, deliver, update thread state, then archive inbound
#   reconcile <message-file|message-id>   record a successful external/direct nudge
#   state <get|list|complete> [thread]      .comms/state/ thread ground truth (JSON)
#   stalled [minutes]           threads awaiting a reply older than N minutes (default 15)
#   bind <claude|codex> [surface:N]   pin which surface delivery targets (show with no arg)
#   clean --as <agent> [workspace|all|archive|<file>] [--yes]
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
#   panel status --set <id>     which legs have answered, and with what verdict
#   compose --set <id> [--out F]
#                               cluster every leg's findings and label them by SUPPORT:
#                               corroborated (gates), uncorroborated (cross-check first),
#                               unanchored, advisory. Drops nothing; no model arbitrates.
#   round-note <reply> --note "<text>"
#                               record how a reviewer performed on ONE round: counts are
#                               derived from the reply, the prose is your assessment.
#                               Appends .comms/grades/rounds.tsv. Never shown to reviewers.
#   snapshot [create|list]      retain the tree under review as a durable git object
#                               (stash-create commit anchored under refs/agent-comms/)
#   prompt-version [--list]     content hash of the reviewer instruction surface; grades
#                               are partitioned on it, never pooled across an edit
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

cmux_default_socket_path() {
  local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
  printf '%s/cmux/cmux.sock\n' "$state_home"
}

cmux_socket_path() {
  if [ -n "${CMUX_SOCKET_PATH:-}" ]; then
    printf '%s\n' "$CMUX_SOCKET_PATH"
  else
    local fallback last_file remembered
    fallback="$(cmux_default_socket_path)"
    last_file="$(dirname "$fallback")/last-socket-path"
    remembered="$(head -1 "$last_file" 2>/dev/null || true)"
    case "$remembered" in /*) printf '%s\n' "$remembered" ;; *) printf '%s\n' "$fallback" ;; esac
  fi
}

cmd_codex_permissions() {
  local socket="${1:-$(cmux_socket_path)}" fallback
  fallback="$(cmux_default_socket_path)"
  case "$socket" in /*) ;; *) die "codex-permissions: socket path must be absolute" ;; esac
  cat <<EOF
Codex cmux permission profile (applies to new sessions):

1. In ~/.codex/config.toml, remove any sandbox_mode line and
   [sandbox_workspace_write] table. Permission profiles do not compose with them.
2. Add:

default_permissions = "workspace-cmux"

[permissions.workspace-cmux]
description = "Workspace editing plus agent-comms cmux delivery"
extends = ":workspace"

[permissions.workspace-cmux.network]
enabled = true

[permissions.workspace-cmux.network.unix_sockets]
"$socket" = "allow"
EOF
  if [ "$socket" != "$fallback" ]; then
    printf '"%s" = "allow"\n' "$fallback"
  fi
  cat <<'EOF'

3. Restart Codex. Do not launch it with --sandbox, which overrides the profile.
EOF
}

cmd_doctor() {
  command -v cmux >/dev/null 2>&1 || {
    echo "cmux socket: unavailable (cmux is not installed or not on PATH)"
    return 1
  }
  local errf first
  errf="$(mktemp 2>/dev/null || echo /tmp/comms-doctor.$$)"
  if cmux list-workspaces >/dev/null 2>"$errf"; then
    rm -f "$errf" 2>/dev/null || true
    echo "cmux socket: reachable"
    return 0
  fi
  first="$(head -1 "$errf" 2>/dev/null || true)"
  rm -f "$errf" 2>/dev/null || true
  if printf '%s' "$first" | grep -qiE 'operation not permitted|not permitted|permission denied|sandbox|\.sock'; then
    echo "cmux socket: blocked ($(cmux_socket_path))"
    echo "fix: run '$SELF codex-permissions', apply the profile, then restart Codex"
    return 3
  fi
  echo "cmux socket: failed${first:+ — $first}"
  return 1
}

cmd_root() {
  local r
  r="$(main_repo_root)"
  [ -n "$r" ] || die "not inside a git repository"
  echo "$r/.comms"
}

# Filesystem-safe name (defined early — cache paths below need it).
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Single-quote one shell argument for copy/paste recovery commands.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Retried cmux tree fetch. A single un-retried call was the root cause of a
# field incident: under load it intermittently returns empty, which broke
# workspace resolution AND surface picking in the same session.
cmux_tree() {
  # Backoff matters: a fixed 3x0.3s burst sits inside a single cmux contention
  # window (observed in the field while a background terminal was attaching);
  # spreading attempts over ~2.5s survives it.
  local out delay
  # No identity means there is nothing to query — return immediately instead of
  # dereferencing an unset var under `set -u`, which printed "unbound variable"
  # twice and swallowed the caller's specific diagnostic. Fixed here rather than at
  # the call site so every caller is covered. (codex, transport-flip round 2.)
  [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 1
  command -v cmux >/dev/null 2>&1 || return 1
  for delay in 0.3 0.7 1.2 0; do
    out="$(cmux tree --workspace "${CMUX_WORKSPACE_ID}" 2>/dev/null)" || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
    [ "$delay" = 0 ] || sleep "$delay"
  done
  return 1
}

cache_path() {  # cache_path <kind> — per-cmux-workspace cache file; fails outside repo/cmux
  local root
  root="$(main_repo_root)"
  [ -n "$root" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 1
  echo "$root/.comms/.cache/${1}-$(safe_name "$CMUX_WORKSPACE_ID")"
}

stable_workspace_name() {
  # cmux auto-titles busy workspaces from the active surface, including a
  # rotating leading status glyph. Only undecorated names may seed identity.
  case "$1" in [[:alnum:]]*) return 0 ;; *) return 1 ;; esac
}

repo_workspace_name() {
  local ws root_name
  ws="$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')"
  root_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')"
  # An auto-titled cmux workspace on a generic default branch should inherit
  # the stable repository name, not the UI title currently shown by cmux.
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    case "$ws" in main|master|trunk|develop|"") ws="$root_name" ;; esac
  fi
  printf '%s\n' "${ws:-$root_name}"
}

cmd_workspace() {
  local ws="" cached="" cachef="" repair_cache=false
  if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    cachef="$(cache_path ws || true)"
    if [ -n "$cachef" ] && [ -f "$cachef" ]; then
      cached="$(cat "$cachef" 2>/dev/null || true)"
      if stable_workspace_name "$cached"; then
        # CMUX_WORKSPACE_ID is the stable identity; its first valid name is an
        # authoritative mapping. A changing display title must never overwrite it.
        echo "$cached"
        return 0
      fi
      if [ -n "$cached" ]; then
        echo "warning: ignoring decorated cached workspace '$cached'" >&2
        repair_cache=true
      fi
    fi
    # Failure-tolerant parse: an empty or unmatched tree must fall through —
    # without the || true, pipefail+set -e silently kills the whole helper.
    ws="$(cmux_tree \
      | sed -nE 's/.*workspace workspace:[^[:space:]]+[[:space:]]+"([^"]*)".*/\1/p' \
      | head -1 \
      | tr ' ' '-' | tr '[:upper:]' '[:lower:]' || true)"
    if stable_workspace_name "$ws"; then
      if [ -n "$cachef" ]; then
        { mkdir -p "$(dirname "$cachef")" && printf '%s' "$ws" > "$cachef"; } 2>/dev/null || true
      fi
      echo "$ws"
      return 0
    fi
    if [ -n "$ws" ]; then
      echo "warning: ignoring decorated cmux workspace title '$ws'" >&2
      repair_cache=true
    fi
  fi
  ws="$(repo_workspace_name)"
  if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then
    echo "warning: cmux title unavailable, unparseable, or decorated — using repo-derived workspace '$ws'" >&2
    if [ "$repair_cache" = true ] && [ -n "$cachef" ]; then
      { mkdir -p "$(dirname "$cachef")" && printf '%s' "$ws" > "$cachef"; } 2>/dev/null || true
    fi
  fi
  echo "$ws"
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
  grep -vE '^[[:space:]]*(#|$|agents[[:space:]]*=|default-target[[:space:]]*=)' "$f" \
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
    --supported)
      printf '%s\tinteractive,headless\n' claude
      printf '%s\tinteractive,headless\n' codex
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
      echo "warning: inbox contains $unmatched_count pending message(s) that do not match resolved workspace '$ws' — possible workspace identity mismatch" >&2
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

hash_stdin() {  # short content hash; whichever digest this box actually has
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-12
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-12
  else cksum | tr -d ' ' | cut -c1-12
  fi
}

findings_extract() {  # <file> <role> <set> <artifact> <reviewer_version> <prompt_version> [base_sha]
  local f="$1" role="$2" rsid="$3" aid="$4" rver="$5" pver="$6" bsha="${7:-}" mid
  [ "$(frontmatter_field "$f" type)" = "review-feedback" ] || return 0
  mid="$(frontmatter_field "$f" message_id)"
  [ -n "$mid" ] || mid="$(basename "$f" .md)"
  # The GATING reviewer's reply arrives later through the normal loop and knows
  # nothing about the shadow run, so its artifact/set identity is joined here
  # from the set index rather than asked of a message that cannot carry it.
  # Explicit flags always win; a miss leaves the fields empty, never guessed.
  if [ -z "$rsid" ] && [ -z "$aid" ]; then
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
  awk -v schema="$FINDINGS_SCHEMA_VERSION" \
      -v mid="$mid" \
      -v thread="$(frontmatter_field "$f" thread)" \
      -v phase="$(frontmatter_field "$f" phase)" \
      -v round="$(frontmatter_field "$f" round)" \
      -v reviewer="$(frontmatter_field "$f" from)" \
      -v base="${bsha:-$(frontmatter_field "$f" head_sha)}" \
      -v verdict="$(frontmatter_field "$f" verdict)" \
      -v role="$role" -v rsid="$rsid" -v aid="$aid" -v rver="$rver" -v pver="$pver" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    # Emit the buffered bullet. Anchors are best-effort BY DESIGN: 35% of real
    # findings are prose or cross-file and carry none, and dropping those would
    # discard exactly the findings a line-anchored schema is worst at seeing.
    function flush(   claim, anchor, fid) {
      if (buf == "") return
      claim = trim(buf); buf = ""
      if (claim ~ /^[Nn]one\.?$/) return
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
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        schema, fid, rsid, aid, base, thread, phase, round, reviewer, rver, pver, \
        role, blane, anchor, claim, verdict, mid
    }
    { sub(/\r$/, "") }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm { next }
    /^### Blocking/ { flush(); lane = "blocking"; next }
    /^### Advisory/ { flush(); lane = "advisory"; next }
    # Any other heading closes the lane — `### Process` never gates a verdict and
    # is not a code finding, so it is not a graded observation either.
    /^#/ { flush(); lane = ""; next }
    lane == "" { next }
    /^[-*] / { flush(); blane = lane; buf = substr($0, 3); next }
    buf != "" && /^[[:space:]]+[^[:space:]]/ { buf = buf " " trim($0); next }
    buf != "" && /^[[:space:]]*$/ { flush(); next }
    END { flush() }
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
  printf '%s-%s' "$out" "$h"
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
  local n
  n="$(awk -F'\t' -v t="$2" -v r="$3" -v ph="${4:-}" 'NR>1 && $3==t && $4==r && $5==ph' "$idx" | grep -c . || true)"
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
    printf 'head_sha: %s\n' "$(git rev-parse HEAD 2>/dev/null || true)"
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
    [ -n "$set_id" ] || usage_err "panel status: --set <id> is required"
    local idx; idx="$(findings_set_index "$root")"
    [ -f "$idx" ] || { emit_diagnostic "panel: no review sets recorded yet"; return 0; }
    printf 'reviewer\tthread\tanswered\tverdict\n'
    awk -F'\t' -v s="$set_id" 'NR>1 && $1==s {print $10 "\t" $3}' "$idx" | while IFS=$'\t' read -r ag th; do
      [ -n "$ag" ] || continue
      local reply verdict="" answered=no
      reply="$(sorted_message_files "$root/.comms/archive" "$(cmd_workspace)" "$ag" "$th" newest | head -1 || true)"
      [ -n "$reply" ] || reply="$(sorted_message_files "$root/.comms/to-claude" "$(cmd_workspace)" "$ag" "$th" newest | head -1 || true)"
      if [ -n "$reply" ]; then answered=yes; verdict="$(cmd_verdict "$reply" 2>/dev/null || true)"; fi
      printf '%s\t%s\t%s\t%s\n' "$ag" "$th" "$answered" "$verdict"
    done
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

  local aid pver
  aid="$(cmd_snapshot create)" || die "panel dispatch: could not retain the artifact"
  pver="$(cmd_prompt_version 2>/dev/null || true)"
  [ -n "$set_id" ] || set_id="$(printf '%s-%s-r%s-%s' "${base_thread:-panel}" "${phase:-nophase}" "${round:-1}" "$(printf '%s' "$aid" | cut -c1-7)")"
  set_id="$(safe_set_id "$set_id")"

  local idx; idx="$(findings_set_index "$root")"
  mkdir -p "$(dirname "$idx")" 2>/dev/null || true
  [ -s "$idx" ] || printf 'review_set_id\trequest_message_id\tthread\tround\tphase\tartifact_id\tprompt_version\tbase_sha\tgating_agent\tshadow_agent\tdrift_status\tdrift_artifact_id\tcreated\n' > "$idx"

  local gating="${roster%% *}" leg_thread leg_file leg_mid ts n=0
  echo "panel: dispatching artifact ${aid} to [$roster] as review set $set_id (gating: $gating)"
  for ag in $roster; do
    ts="$(date -u +%Y-%m-%dT%H-%M-%S)"
    leg_thread="${base_thread:-panel}-${ag}"
    leg_mid="$(safe_name "$(cmd_workspace)")_${ts}_panel-${ag}-$$-${n}"
    leg_file="$root/.comms/$(inbox_for "$ag")/${leg_mid}.md"
    mkdir -p "$(dirname "$leg_file")" 2>/dev/null || true
    # Same body, same artifact, same round — only identity and routing differ. Anything
    # else here would make the legs incomparable, which is the point of fanning out.
    LC_ALL=C awk -v th="$leg_thread" -v mid="$leg_mid" -v setid="$set_id" -v aid="$aid" '
      { probe = $0; sub(/\r$/, "", probe) }
      NR == 1 && probe == "---" { fm = 1; print; next }
      fm && probe == "---" {
        printf "review_set: %s\n", setid
        printf "artifact_id: %s\n", aid
        fm = 0; print; next
      }
      fm && index(probe, "thread:") == 1 { printf "thread: %s\n", th; next }
      fm && index(probe, "message_id:") == 1 { printf "message_id: %s\n", mid; next }
      fm && index(probe, "artifact_id:") == 1 { next }
      { print }
    ' "$req" > "$leg_file"
    cmd_validate "$leg_file" >/dev/null || die "panel dispatch: leg for '$ag' did not validate"
    if ! cut -f1 "$idx" | grep -qxF -- "$set_id" || ! awk -F'\t' -v s="$set_id" -v a="$ag" 'NR>1 && $1==s && $10==a' "$idx" | grep -q .; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$set_id" "$leg_mid" "$leg_thread" "$round" "$phase" "$aid" "$pver" \
        "$(frontmatter_field "$req" head_sha)" "$gating" "$ag" "dispatched" "" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$idx"
    fi
    echo "  leg: $ag  thread=$leg_thread"
    cmd_send --to "$ag" "$leg_file" || echo "  warning: leg for '$ag' did not deliver — the set is incomplete"
    n=$((n + 1))
  done
  echo "panel: $set_id dispatched to $n reviewer(s); compose with 'comms.sh panel status --set $set_id'"
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
  # The ROUND is part of a leg's identity. Finding replies by reviewer+thread alone
  # makes round 2 compose round 1's replies and report "all answered" — the panel would
  # gate on findings about an artifact it is no longer reviewing. (grok, panel r1.)
  local legs; legs="$(awk -F'\t' -v s="$set_id" 'NR>1 && $1==s {print $10 "\t" $3 "\t" $4}' "$idx")"
  [ -n "$legs" ] || usage_err "compose: review set '$(clip "$set_id")' has no legs"

  local rows="" ag th rnd reply cand n_legs=0 n_answered=0 pending=""
  while IFS=$'\t' read -r ag th rnd; do
    [ -n "$ag" ] || continue
    n_legs=$((n_legs + 1))
    reply=""
    for cand in $(sorted_message_files "$root/.comms/archive" "$ws" "$ag" "$th" newest) \
                $(sorted_message_files "$root/.comms/to-claude" "$ws" "$ag" "$th" newest); do
      [ -f "$cand" ] || continue
      # Same round, or nothing. A reply from an earlier round answers an earlier
      # question.
      [ -z "$rnd" ] || [ "$(frontmatter_field "$cand" round)" = "$rnd" ] || continue
      reply="$cand"; break
    done
    # A leg is answered only by a VALID review-feedback. Counting any message in the
    # thread lets a stray note complete a panel and unblock the gate. (codex, panel r1.)
    if [ -n "$reply" ] && { [ "$(frontmatter_field "$reply" type)" != "review-feedback" ] \
       || ! cmd_validate "$reply" >/dev/null 2>&1; }; then
      emit_diagnostic "compose: ignoring a non-review message on $ag's leg"
      reply=""
    fi
    if [ -z "$reply" ]; then pending="$pending $ag"; continue; fi
    n_answered=$((n_answered + 1))
    rows="$rows
$(findings_extract "$reply" gating "$set_id" "" "" "" "")"
  done <<< "$legs"

  # An unanswered leg is NOT an approval. A panel that quietly composes over a missing
  # voice is worse than one reviewer, because it looks like more.
  if [ -n "$pending" ]; then
    echo "compose: INCOMPLETE — no reply yet from:$pending ($n_answered of $n_legs legs answered)"
    echo "compose: refusing to gate on a partial panel; re-run when the set is complete"
    return 3
  fi

  # Cluster on the anchor ONLY, and only exact matches. Two findings on one anchor may
  # still assert different things, so every source line is retained and printed.
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/agent-comms-compose.XXXXXX")"
  printf '%s\n' "$rows" | awk -F'\t' 'NF>5 && $15 != ""' > "$tmp"
  local total blocking corroborated unique
  total="$(grep -c . "$tmp" || true)"
  blocking="$(awk -F'\t' '$13=="blocking"' "$tmp" | grep -c . || true)"
  corroborated="$(awk -F'\t' '$13=="blocking" && $14!=""{k[$14]=k[$14] " " $9} END{n=0; for (a in k){c=split(k[a],p," "); u=""; for(i=1;i<=c;i++){if (index(u," " p[i] " ")==0) u=u " " p[i] " "}; m=split(u,q," "); if (m>1) n++} print n+0}' "$tmp")"
  unique=$(( ${blocking:-0} - 0 ))

  {
    printf '# Panel composition — review set %s\n\n' "$set_id"
    printf '%s legs, all answered. %s findings (%s blocking).\n' "$n_legs" "${total:-0}" "${blocking:-0}"
    printf 'Anchored blocking findings supported by MORE THAN ONE reviewer: %s\n\n' "${corroborated:-0}"
    printf '## Gates (corroborated — an anchor two reviewers independently flagged)\n\n'
    awk -F'\t' '$13=="blocking" && $14!=""{k[$14]=k[$14] "\n- [" $9 "] " $15; who[$14]=who[$14] " " $9}
      END{for (a in k){c=split(who[a],p," "); u=""; for(i=1;i<=c;i++){if (index(u," " p[i] " ")==0) u=u " " p[i] " "}; m=split(u,q," ");
        if (m>1) printf "### %s\n%s\n\n", a, k[a]}}' "$tmp"
    printf '## Uncorroborated blocking findings (cross-check before spending a round)\n\n'
    awk -F'\t' '$13=="blocking" && $14!=""{k[$14]=k[$14] "\n- [" $9 "] " $15; who[$14]=who[$14] " " $9}
      END{for (a in k){c=split(who[a],p," "); u=""; for(i=1;i<=c;i++){if (index(u," " p[i] " ")==0) u=u " " p[i] " "}; m=split(u,q," ");
        if (m==1) printf "### %s\n%s\n\n", a, k[a]}}' "$tmp"
    printf '## Unanchored blocking findings (no anchor — cannot be clustered)\n\n'
    awk -F'\t' '$13=="blocking" && $14==""{printf "- [%s] %s\n", $9, $15}' "$tmp"
    printf '\n## Advisory (never gates)\n\n'
    awk -F'\t' '$13=="advisory"{printf "- [%s] %s%s\n", $9, ($14!="" ? "`" $14 "` — " : ""), $15}' "$tmp"
  } > "${out:-/dev/stdout}"
  rm -f "$tmp"
  [ -z "$out" ] || echo "compose: wrote ${out#"$root"/}"
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
  # --no-deliver suppresses the TRUSTED-PARENT broker. An agent that authors and
  # sends its own reply (claude, codex) would still write into an inbox and still
  # record thread state, so for those the "cannot gate" guarantee would be a
  # convention rather than a mechanism — and this command's whole value is that it
  # is a mechanism. Refuse rather than silently downgrade. (grok, live 2026-08-22.)
  case "$(cmd_agents --supported | awk -v a="$to" -F'\t' '$1==a {print $2}')" in
    *reviewer-consult-only*) ;;
    *) usage_err "shadow: '$to' authors and sends its own replies, so a shadow run could not be prevented from reaching an inbox — only parent-brokered reviewers (reviewer-consult-only) can be shadowed" ;;
  esac
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
  ( cd "$tree" && RUNPHASE_NO_DELIVER=1 "$rp" run --message "$child_msg" --dir "$run_dir" \
      --provider "$to" --no-deliver ${timeout:+--timeout-secs "$timeout"} ) >/dev/null 2>&1 || rc=$?
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
  [ -s "$idx" ] || printf 'review_set_id\trequest_message_id\tthread\tround\tphase\tartifact_id\tprompt_version\tbase_sha\tgating_agent\tshadow_agent\tdrift_status\tdrift_artifact_id\tcreated\n' > "$idx"
  if ! cut -f1 "$idx" | grep -qxF -- "$rsid"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rsid" "$reqid" "$thread" "$round" "$phase" "$aid" "$pver" "$base" "$gating" "$to" \
      "$drift_status" "$drift" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$idx"
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

cmd_snapshot() {
  # snapshot [create|list] — RETAIN the tree under review as a durable git object.
  #
  # A hash alone cannot resurrect the input, so this stores CONTENT: the working
  # tree (tracked edits and untracked files, mailbox excluded) is written as a
  # real commit object without touching the worktree, the index, or the stash.
  # That commit starts unreferenced and would be garbage-collected, so it is
  # anchored under refs/agent-comms/ — the anchor IS the retention, and without
  # it the artifact this prerequisite exists to keep silently evaporates.
  local sub="${1:-create}"
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
  GIT_INDEX_FILE="$idx" git -C "$root" rm --cached -r -q --ignore-unmatch -- .comms .agent-comms 2>/dev/null \
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
    printf '%s\n' "$parent"
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
  printf '%s\n' "$id"
}

# The reviewer-facing instruction surface, in a fixed order. A grade does not
# carry across an edit to any of these, so rows are PARTITIONED on this hash,
# never pooled across it. Local pin wins over global, matching every other
# resolver in this tool.
prompt_surface_skill() {  # same precedence as runphase's skill_file — a pin edit
  # that moved the review bar MUST move this hash, so the search order has to be
  # identical to the one that actually feeds the reviewer. (grok, live 2026-08-22.)
  local name="$1" root="$2" p
  for p in \
    "$root/.agents/skills/$name/SKILL.md" \
    "${CODEX_SKILLS_DIR:-$HOME/.codex/skills}/$name/SKILL.md" \
    "$(dirname "$SELF")/../templates/codex-skills/$name/SKILL.md"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
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
  # The reviewer skills carry the verdict discipline itself — the actual bar.
  for name in read-from-claude send-to-claude; do
    hit="$(prompt_surface_skill "$name" "$root" || true)"
    if [ -n "$hit" ]; then printf '%s\n' "$hit"; else printf 'MISSING %s/SKILL.md\n' "$name"; fi
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

pick_surface() {  # pick_surface <target> — prints "<surface>\t<how>"
  # Order of preference:
  #   1. a bound/remembered surface for this target (set via `bind`, or cached
  #      from the last successful delivery) — IF it still exists in the tree.
  #      With several terminal surfaces in a workspace, "some other terminal"
  #      is a coin toss; agent identity has to come from a binding.
  #   2. pane-aware pick: the FIRST [terminal] surface (tree order = tab order)
  #      in a pane OTHER than the one marked "◀ here"; fall back to the first
  #      other terminal anywhere. Convention: keep the live Claude/Codex as the
  #      FIRST tab in its pane, or set an explicit binding.
  local target="$1" tree bound="" cachef
  cachef="$(cache_path "surface-$target" || true)"
  [ -n "$cachef" ] && [ -f "$cachef" ] && bound="$(cat "$cachef" 2>/dev/null || true)"
  tree="$(cmux_tree || true)"
  if [ -z "$tree" ]; then
    # Tree unavailable. A known binding must NOT be discarded because of a
    # flaky tree read — use it optimistically; a dead surface makes the send
    # sequence fail loudly (RESULT: failed), which is accurate and retryable.
    if [ -n "$bound" ]; then
      printf '%s\tbound (tree unavailable — optimistic)\n' "$bound"
      return 0
    fi
    echo "pick_surface: cmux tree unavailable after retries (target=$target, workspace=${CMUX_WORKSPACE_ID:-unset}, no binding cached at ${cachef:-n/a})" >&2
    return 0   # caller reports not-found
  fi
  if [ -n "$bound" ]; then
    if printf '%s\n' "$tree" | grep -qE "${bound}([^0-9]|\$)"; then
      printf '%s\tbound\n' "$bound"
      return 0
    fi
    echo "pick_surface: bound $target surface '$bound' not present in current tree — falling back to picker" >&2
  fi
  # This is a real script — awk $0 is safe here.
  local picked
  picked="$(printf '%s\n' "$tree" | awk '
    /pane:/ { for (i=1;i<=NF;i++) if ($i ~ /^pane:/) cur_pane=$i }
    /surface:.*\[terminal\]/ {
      if (match($0, /surface:[0-9]+/)) {
        n++; surf[n]=substr($0,RSTART,RLENGTH); pane[n]=cur_pane
        here[n] = ($0 ~ /◀ here/) ? 1 : 0
        if (here[n]) here_pane=cur_pane
      }
    }
    END {
      for (i=1;i<=n;i++) if (!here[i] && pane[i]!=here_pane) { printf "%s\tfirst other-pane terminal\n", surf[i]; exit }
      for (i=1;i<=n;i++) if (!here[i]) { printf "%s\tfirst other terminal\n", surf[i]; exit }
    }')"
  if [ -n "$picked" ]; then
    printf '%s\n' "$picked"
    return 0
  fi
  # Nothing eligible — say exactly why so a manual outcome is diagnosable.
  echo "pick_surface: no eligible surface (target=$target, workspace=${CMUX_WORKSPACE_ID:-unset}, [terminal] surfaces in tree: $(printf '%s\n' "$tree" | grep -c '\[terminal\]' || true), binding: ${bound:-none})" >&2
}

cmd_bind() {  # bind <claude|codex> [surface:N] — set or show the target's surface binding
  local target="${1:-}" surface="${2:-}"
  case "$target" in claude|codex) ;; *) die "bind: target must be a cmux-pane agent (claude or codex) — headless-only agents have no surface" ;; esac
  local f
  f="$(cache_path "surface-$target")" || die "bind: requires a git repo and CMUX_WORKSPACE_ID"
  if [ -z "$surface" ]; then
    if [ -f "$f" ]; then
      echo "$target bound to $(cat "$f")"
    else
      echo "$target not bound (pane-aware picker will choose)"
    fi
    return 0
  fi
  case "$surface" in
    surface:[0-9]*) ;;
    *) die "bind: surface must look like surface:<n> (see 'cmux tree')" ;;
  esac
  mkdir -p "$(dirname "$f")"
  printf '%s' "$surface" > "$f"
  echo "bound $target -> $surface (ignored automatically if it disappears from the tree)"
}

# deliver_headless <target> [message-file] — spawn a detached peer turn via
# runphase.sh instead of typing into a pane. Direction-aware: replies TO the
# driving session are a designed no-op (the driver reads them when the peer
# turn exits) — runphase marks that direction in the child's env via
# COMMS_HEADLESS_PICKUP. Any other target spawns a turn for that provider.
# Same contract as the cmux path: never hard-fails, always says what happened.
deliver_headless() {
  # <target> [msgfile] — spawn a detached turn, or run it in the FOREGROUND when
  # COMMS_WAIT=1. A detached child can be reaped the moment the managed shell command
  # that spawned it ends, which is normal inside an agent sandbox — so an agent driving
  # this helper needs a synchronous mode or its turns vanish. (Field report from a codex
  # session, 2026-08-26.)
  local target="$1" msgfile="${2:-}"
  if [ "$target" = "${COMMS_HEADLESS_PICKUP:-}" ]; then
    echo "headless mode: reply written for pickup — the driving session reads it when this peer turn ends (no nudge needed)"
    return 0
  fi
  local rp="$(dirname "$SELF")/runphase.sh"
  export COMMS_RUNPHASE_VIA="${COMMS_RUNPHASE_VIA:-}"
  if [ ! -x "$rp" ]; then
    echo "warning: this loop needs the headless runner but runphase.sh was not found next to comms.sh — message written for manual pickup (re-run install.sh, or use --via cmux / COMMS_DELIVERY=cmux)"
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

print_direct_recovery() {
  local target="$1" surface="$2" msgfile="${3:-}"
  local qs qw qself qmsg
  qs="$(shell_quote "$surface")"
  qw="$(shell_quote "$CMUX_WORKSPACE_ID")"
  qself="$(shell_quote "$SELF")"
  qmsg="$(shell_quote "$msgfile")"
  printf 'RECOVER: '
  case "$target" in
    codex)
      printf 'cmux send --surface %s --workspace %s %s && sleep 0.5 && cmux send-key --surface %s --workspace %s escape && sleep 0.3 && cmux send-key --surface %s --workspace %s enter' \
        "$qs" "$qw" "$(shell_quote '$read-from-claude')" "$qs" "$qw" "$qs" "$qw"
      ;;
    claude)
      printf 'cmux send-key --surface %s --workspace %s escape && sleep 0.2 && cmux send --surface %s --workspace %s i && sleep 0.2 && cmux send --surface %s --workspace %s %s && sleep 0.5 && cmux send-key --surface %s --workspace %s escape && sleep 0.3 && cmux send-key --surface %s --workspace %s enter' \
        "$qs" "$qw" "$qs" "$qw" "$qs" "$qw" "$(shell_quote '/read-from-codex')" "$qs" "$qw" "$qs" "$qw"
      ;;
  esac
  # The final segment runs only if every direct cmux step succeeded. It repairs
  # advisory state without re-sending or re-archiving the message.
  [ -n "$msgfile" ] && printf ' && %s reconcile %s' "$qself" "$qmsg"
  printf '\n'
}

runphase_available() { [ -x "$(dirname "$SELF")/runphase.sh" ]; }

acp_supports() {  # <agent> — can an ACP turn actually run here for this agent?
  local acp_sh; acp_sh="$(dirname "$SELF")/acp.sh"
  [ -x "$acp_sh" ] || return 1
  "$acp_sh" supports "$1" >/dev/null 2>&1
}

cmd_transport() {
  # transport <agent> [--loop] — print the transport that would actually be used:
  # headless | cmux | acp | mailbox.
  #
  # ONE place decides, so the templates never re-implement surface detection and
  # the eventual "ACP by default, cmux optional" flip is a reordering here rather
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

  if [ "${COMMS_DELIVERY:-}" = "headless" ]; then printf 'headless\n'; return 0; fi
  if [ "${COMMS_DELIVERY:-}" = "acp" ]; then printf 'acp\n'; return 0; fi

  local caps picked
  caps="$(cmd_agents --supported | awk -v a="$agent" -F'\t' '$1==a {print $2}')"

  # An EXPLICIT request binds in EVERY mode. Honouring it only for loops meant a
  # consult silently ignored COMMS_DELIVERY=cmux and went to ACP instead — the
  # caller asked for one transport and quietly got another.
  if [ "${COMMS_DELIVERY:-}" = "cmux" ]; then
    case "$caps" in
      *interactive*)
        picked="$(pick_surface "$agent" 2>/dev/null | cut -f1)"
        [ -z "$picked" ] || { printf 'cmux\n'; return 0; }
        ;;
    esac
    # cmux was asked for and there is none — say mailbox rather than silently
    # substituting a transport the caller explicitly did not choose.
    printf 'mailbox\n'; return 0
  fi

  # LOOPS ARE ACP-FIRST, then headless, then a pane. A loop is unattended work by
  # definition, so it must not depend on an open pane — but the ordering here is
  # driven by cost, measured on one real review turn in this repo:
  #
  #   cmux (live pane)      ~43,000-85,000 fresh input tokens per turn
  #   headless (cold spawn) ~115,000
  #   ACP (warm session)    ~1,061
  #
  # A cold spawn rebuilds context from nothing every round; a live pane keeps the
  # conversation but still re-sends a large uncached prefix per model call. Only a
  # named ACP session makes round N pay a delta. cmux and headless stay available
  # and opt-in (COMMS_DELIVERY / --via).
  if [ "$mode" = "loop" ]; then
    if acp_supports "$agent"; then printf 'acp\n'; return 0; fi
    # Fall back to a pane only when the headless runner is genuinely missing:
    # flipping the default must not strand every loop on an install where
    # runphase.sh never landed.
    if runphase_available; then printf 'headless\n'; return 0; fi
    case "$caps" in
      *interactive*)
        picked="$(pick_surface "$agent" 2>/dev/null | cut -f1)"
        [ -z "$picked" ] || { printf 'cmux\n'; return 0; }
        ;;
    esac
    printf 'mailbox\n'; return 0
  fi
  # A live pane still wins: it is the watchable surface, and switching a visible
  # workflow out from under someone is not a fallback, it is a surprise.
  case "$caps" in
    *interactive*)
      picked="$(pick_surface "$agent" 2>/dev/null | cut -f1)"
      [ -z "$picked" ] || { printf 'cmux\n'; return 0; }
      ;;
  esac
  # No pane. ACP is synchronous and needs none, which beats queueing into an inbox
  # nobody is watching — the exact case that stranded a real consult. Checked BEFORE
  # the headless fallback because a headless-only agent (grok) has no pane by
  # definition and would otherwise never reach here.
  #
  # Consults only: a loop turn must be able to EXECUTE (read files, run git) and that
  # permission policy is unbuilt, so silently re-routing a loop would change its
  # semantics rather than just its transport.
  if [ "$mode" = "consult" ] && acp_supports "$agent"; then printf 'acp\n'; return 0; fi
  case "$caps" in *interactive*) ;; *) printf 'headless\n'; return 0 ;; esac
  printf 'mailbox\n'
}

cmd_deliver() {
  local target="${1:-}" msgfile="${2:-}"
  require_agent "$target" "deliver"
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
    cmux) ;;
    *)
      if [ "${COMMS_DELIVERY:-}" = "cmux" ]; then
        # Re-run the picker purely for its stderr: it distinguishes "tree
        # unavailable" from "no matching surface", and routing on the summary
        # alone would throw that away. ONE call — an earlier version ran it twice
        # and discarded the first. (grok, transport-flip round 1.)
        pick_surface "$target" 2>&1 >/dev/null | head -2 >&2 || true
        echo "warning: COMMS_DELIVERY=cmux but no $target surface is live; message written for manual pickup"
      else
        echo "warning: no headless runner and no $target surface; message written for manual pickup (re-run install.sh)"
      fi
      return 0
      ;;
  esac
  if ! command -v cmux >/dev/null 2>&1 || [ -z "${CMUX_WORKSPACE_ID:-}" ]; then
    echo "warning: cmux not available; message written for manual pickup"
    return 0
  fi
  local picked surface how
  picked="$(pick_surface "$target")"
  surface="${picked%%	*}"
  how="${picked#*	}"
  if [ -z "$surface" ]; then
    echo "warning: could not find a $target surface; message written for manual pickup"
    return 0
  fi
  # Capture mid-sequence cmux failures explicitly (and their stderr) so a
  # half-typed nudge surfaces as a diagnosable result, not a terse abort.
  local seq_ok=true errf
  errf="$(mktemp 2>/dev/null || echo /tmp/comms-deliver.$$)"
  case "$target" in
    codex)
      { cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" enter; } 2>"$errf" || seq_ok=false
      ;;
    claude)
      # Claude Code in vim mode: ensure insert mode before typing, then submit.
      { cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.2 \
        && cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" 'i' && sleep 0.2 \
        && cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" '/read-from-codex' && sleep 0.5 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" enter; } 2>"$errf" || seq_ok=false
      ;;
  esac
  if [ "$seq_ok" = true ]; then
    rm -f "$errf" 2>/dev/null || true
    # Remember the working surface for this target so the next delivery doesn't
    # have to guess among multiple terminals.
    local cachef
    cachef="$(cache_path "surface-$target" || true)"
    [ -n "$cachef" ] && { mkdir -p "$(dirname "$cachef")" && printf '%s' "$surface" > "$cachef"; } 2>/dev/null || true
    echo "delivered to $surface ($how)"
  else
    # A nested helper can be sandboxed even when direct cmux commands are
    # allowlisted by the host. Emit one executable recovery line; its final
    # segment reconciles state only after every direct nudge step succeeds.
    if grep -qiE 'operation not permitted|not permitted|permission denied|sandbox|\.sock' "$errf" 2>/dev/null; then
      echo "warning: delivery blocked — nested helper cannot access cmux; message is safely on disk"
      echo "  setup: run '$SELF codex-permissions' and restart Codex; retries from this unchanged sandbox will also block"
      print_direct_recovery "$target" "$surface" "$msgfile"
    else
      echo "warning: delivery FAILED mid-sequence to $surface — the message is safely on disk; retry with 'comms.sh send --to $target <file>' (refreshes delivery state) or nudge the pane manually"
    fi
    [ -s "$errf" ] && echo "  cmux said: $(head -1 "$errf")"
    rm -f "$errf" 2>/dev/null || true
  fi
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
      echo "ACTION NEEDED: $(basename "$pending") is still unread after $(( age_s / 60 ))m (last_delivery=$deliv). Nudge $target directly; if socket-blocked, configure 'comms.sh codex-permissions' for a new Codex session."
    # Live headless outcomes are not operator-action cases: spawned = turn in
    # flight, completed = reply is (or was) in the inbox for the driver to read,
    # held = the operator paused deliberately, pickup = designed reply-to-driver
    # no-op. failed/timeout from a headless turn DO shout, like a failed nudge.
    elif [ "$st" != "complete" ] && [ -n "$deliv" ] \
         && [ "$deliv" != "delivered" ] && [ "$deliv" != "spawned" ] \
         && [ "$deliv" != "completed" ] && [ "$deliv" != "held" ] && [ "$deliv" != "pickup" ]; then
      echo "ACTION NEEDED: last delivery was '$deliv' — $owes was NOT nudged. Do not retry from an unchanged sandbox; use manual pickup or configure 'comms.sh codex-permissions' and restart Codex."
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
state_update_from() {
  local mf="$1" outcome="${2:-unknown}" run_dir="${3:-}" awaiting_override="${4:-}"
  local thread wf
  thread="$(frontmatter_field "$mf" thread)"
  wf="$(frontmatter_field "$mf" workflow)"
  [ -n "$thread" ] && [ -n "$wf" ] || return 0   # one-shot or pre-v2 message: no state
  local ws fm_ws phase round maxr from awaiting_from mid dir
  # Key on the RESOLVED workspace — the same resolver every reader uses — so a
  # divergent frontmatter workspace value can't make the state file invisible.
  ws="$(cmd_workspace)"
  fm_ws="$(frontmatter_field "$mf" workspace)"
  [ -n "$fm_ws" ] && [ "$fm_ws" != "$ws" ] && \
    echo "warning: message workspace '$fm_ws' differs from resolved workspace '$ws' — state keyed on '$ws'" >&2
  phase="$(frontmatter_field "$mf" phase)"
  round="$(frontmatter_field "$mf" round)"
  maxr="$(frontmatter_field "$mf" max-rounds)"
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
  printf '{\n  "workspace": "%s",\n  "thread": "%s",\n  "workflow": "%s",\n  "phase": "%s",\n  "round": "%s",\n  "max_rounds": "%s",\n  "status": "in-progress",\n  "awaiting_from": "%s",\n  "awaiting_since": "%s",\n  "awaiting_since_epoch": "%s",\n  "last_sent": "%s",\n  "last_run_dir": "%s",\n  "last_delivery": "%s"\n}\n' \
    "$(json_escape "$ws")" "$(json_escape "$thread")" "$(json_escape "$wf")" \
    "$(json_escape "$phase")" "$(json_escape "$round")" "$(json_escape "$maxr")" \
    "$awaiting_from" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" \
    "$(json_escape "$mid")" "$(json_escape "$run_dir")" "$outcome" \
    > "$dir/$(safe_name "$ws")_$(safe_name "$thread").json" \
    || echo "warning: could not write thread state for '$thread' — continuing" >&2
}

cmd_reconcile() {
  local ref="${1:-}" mid root dir f tmp now found=false
  [ -n "$ref" ] || die "reconcile: message file or message_id required"
  if [ -f "$ref" ]; then
    mid="$(frontmatter_field "$ref" message_id)"
    [ -n "$mid" ] || mid="$(basename "$ref" .md)"
  else
    mid="$(basename "$ref" .md)"
  fi
  root="$(cmd_root)"
  dir="$root/state"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for f in "$dir/"*.json; do
    [ -f "$f" ] || continue
    [ "$(json_get "$f" last_sent)" = "$mid" ] || continue
    found=true
    tmp="$f.reconcile.$$"
    awk -v now="$now" '
      /"last_notified_at":/ {
        printf "  \"last_notified_at\": \"%s\",\n", now
        seen=1
        next
      }
      /"last_delivery":/ {
        if (!seen) printf "  \"last_notified_at\": \"%s\",\n", now
        sub(/"last_delivery": "[^"]*"/, "\"last_delivery\": \"delivered\"")
      }
      { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f" \
      || { rm -f "$tmp" 2>/dev/null || true; die "reconcile: could not update $f"; }
  done
  if [ "$found" = true ]; then
    echo "RESULT: delivered — external nudge recorded; peer pickup is still asynchronous"
  else
    # One-shot messages intentionally have no thread state. The RECOVER chain
    # still proves every direct cmux command before this segment succeeded.
    echo "RESULT: delivered — external nudge completed; no workflow state matched '$mid'"
  fi
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
  local as="" yes=false mode="" targets=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) shift; as="${1:-}" ;;
      --yes) yes=true ;;
      *) [ -z "$mode" ] && mode="$1" || die "clean: unexpected argument '$1'" ;;
    esac
    shift
  done
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
  if [ -n "$(frontmatter_field "$file" workflow)" ] && [ -z "$(frontmatter_field "$file" artifact_id)" ]; then
    local send_aid
    send_aid="$(cmd_snapshot create 2>/dev/null || true)"
    if [ -n "$send_aid" ]; then
      local stamped; stamped="$(mktemp "${TMPDIR:-/tmp}/agent-comms-stamp.XXXXXX")"
      # Byte-preserving insert at the close of frontmatter — an awk rewrite of every
      # line normalizes CRLF and is not what "send this message" should mean.
      # CRLF-tolerant on the DELIMITER test only — the line itself is reprinted
      # unmodified, so a CRLF file stays CRLF. (codex, transport-flip round 4.)
      LC_ALL=C awk -v aid="$send_aid" '
        { probe = $0; sub(/\r$/, "", probe) }
        NR == 1 && probe == "---" { fm = 1; print; next }
        fm && probe == "---" { printf "artifact_id: %s\n", aid; fm = 0; print; next }
        { print }
      ' "$file" > "$stamped" && mv -f "$stamped" "$file"
      rm -f "$stamped" 2>/dev/null || true
    else
      # Fail CLOSED. Proceeding would review the live tree while the message implies a
      # pinned one — the precise failure the snapshot exists to remove, and invisible
      # afterwards. (codex, transport-flip round 4.)
      die "send: could not retain the artifact under review — refusing to dispatch a loop against an unpinned tree (is this a git repo with a commit?)"
    fi
  fi

  # Atomicity guard: never deliver or archive on a malformed outbound message.
  cmd_validate "$file" || die "send: refusing to deliver malformed message (and not archiving inbound)"
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
  local del_out outcome=manual rundir=""
  del_out="$(cmd_deliver "$to" "$file")"
  echo "$del_out"
  rundir="$(printf '%s\n' "$del_out" | sed -n 's/^ *run dir: //p' | head -1)"
  case "$del_out" in
    *"delivered to"*)     outcome=delivered ;;
    *"delivery blocked"*) outcome=blocked ;;
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
  # Loud outcome — emitted LAST so `tail -1` of send is always the RESULT line
  # on every path, including --archive-inbound (the main autonomous path).
  # On `blocked`, callers execute the emitted RECOVER line once; only a final
  # non-delivered result needs user attention.
  case "$outcome" in
    delivered) echo "RESULT: delivered" ;;
    spawned)   echo "RESULT: spawned — headless peer turn running detached; the reply lands in the inbox when it exits. Await it with the runphase.sh command printed above, then read the reply." ;;
    held)      echo "RESULT: held — the thread is paused by a hold marker; nothing was spawned. Release with 'runphase.sh release <thread>', then RE-SEND ('comms.sh send --to $to <file>') — a bare deliver would spawn the turn but leave this thread's state stuck on 'held', blinding status and the stalled watchdog." ;;
    blocked)   echo "RESULT: blocked — message saved, peer not nudged; use host/manual pickup or restart with cmux socket permission" ;;
    pickup)
      # Text deliberately starts "manual —" for the peers' expectations: the
      # spawned peer is pre-briefed that its reply send reports manual.
      echo "RESULT: manual — headless mode: the reply is on disk; the driving session picks it up when this turn ends"
      ;;
    manual)
      # Recovery guidance follows the route that was actually attempted. Deriving it
      # from COMMS_DELIVERY alone told operators to "fix cmux" right after a headless
      # runner warning, on a default that no longer prefers cmux. (codex, advisory.)
      if [ "${COMMS_DELIVERY:-}" = "cmux" ]; then
        echo "RESULT: manual — cmux was requested but $to was NOT nudged; trigger it by hand or fix cmux and re-run 'comms.sh deliver $to'"
      else
        echo "RESULT: manual — $to was NOT spawned (see the warning above; likely runphase.sh missing or an empty inbox); fix and retry 'comms.sh send --to $to <file>'"
      fi
      ;;
    failed)    echo "RESULT: failed — nudge errored mid-sequence; retry with 'comms.sh send --to $to <file>'" ;;
  esac
}

case "${1:-}" in
  root)      shift; cmd_root "$@" ;;
  workspace) shift; cmd_workspace "$@" ;;
  agents)    shift; cmd_agents "$@" ;;
  doctor)    shift; cmd_doctor "$@" ;;
  codex-permissions) shift; cmd_codex_permissions "$@" ;;
  list)      shift; cmd_list "$@" ;;
  status)    shift; cmd_status "$@" ;;
  validate)  shift; cmd_validate "$@" ;;
  verdict)   shift; cmd_verdict "$@" ;;
  archive)   shift; cmd_archive "$@" ;;
  deliver)   shift; cmd_deliver "$@" ;;
  transport) shift; cmd_transport "$@" ;;
  send)      shift; cmd_send "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  state)     shift; cmd_state "$@" ;;
  stalled)   shift; cmd_stalled "$@" ;;
  bind)      shift; cmd_bind "$@" ;;
  clean)     shift; cmd_clean "$@" ;;
  lessons)        shift; cmd_lessons "$@" ;;
  archive-search) shift; cmd_archive_search "$@" ;;
  findings)       shift; cmd_findings "$@" ;;
  ask)            shift; cmd_ask "$@" ;;
  panel)          shift; cmd_panel "$@" ;;
  compose)        shift; cmd_compose "$@" ;;
  round-note)     shift; cmd_round_note "$@" ;;
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
