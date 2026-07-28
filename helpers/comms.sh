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
#   list --as <claude|codex> [--thread <t>]   pending inbox messages, newest first
#   status                      one-screen loop state: latest archive, verdict, pending counts
#   validate <file>             frontmatter + body checks; non-zero exit and reasons on failure
#   verdict <file>              normalized (trimmed, uppercased) verdict from frontmatter
#   archive --as <claude|codex> <file...>   idempotent move to archive/; own inbox only
#   deliver <claude|codex> [file]   nudge the other agent's pane via cmux; reports delivered/
#                               manual-pickup/FAILED explicitly (never hard-fails).
#                               COMMS_DELIVERY=headless routes to runphase.sh instead
#                               (detached codex exec / claude -p turn for the target)
#   send --to <claude|codex> <file> [--archive-inbound <file>]
#                               validate, deliver, update thread state, then archive inbound
#   reconcile <message-file|message-id>   record a successful external/direct nudge
#   state <get|list|complete> [thread]      .comms/state/ thread ground truth (JSON)
#   stalled [minutes]           threads awaiting a reply older than N minutes (default 15)
#   bind <claude|codex> [surface:N]   pin which surface delivery targets (show with no arg)
#   clean --as <claude|codex> [workspace|all|archive|<file>] [--yes]
#                               guarded delete; dry-run without --yes; own-inbox default
#   lessons [--bytes N] [--surface P] [--file F]
#                               bounded newest-first tail of docs/advisories.md (whole
#                               "## " sections, never a byte slice). Exit 3 = truncated.
#   archive-search <pattern> [--bytes N] [--limit K]
#                               bounded newest-first search of archive/ across workspaces;
#                               metadata + clipped context, not whole messages. Exit 3 = truncated.
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
  for delay in 0.3 0.7 1.2 0; do
    out="$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null)" || out=""
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

cmd_workspace() {
  local ws="" cachef=""
  if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    # Failure-tolerant parse: an empty or unmatched tree must fall through —
    # without the || true, pipefail+set -e silently kills the whole helper.
    ws="$(cmux_tree \
      | sed -nE 's/.*workspace workspace:[^[:space:]]+[[:space:]]+"([^"]*)".*/\1/p' \
      | head -1 \
      | tr ' ' '-' | tr '[:upper:]' '[:lower:]' || true)"
    cachef="$(cache_path ws || true)"
    if [ -n "$ws" ]; then
      # Cache the identity per cmux workspace: one good resolution sticks, so a
      # later flaky tree read can't flap the name mid-loop (and split state files).
      if [ -n "$cachef" ]; then
        { mkdir -p "$(dirname "$cachef")" && printf '%s' "$ws" > "$cachef"; } 2>/dev/null || true
      fi
      echo "$ws"
      return 0
    fi
    if [ -n "$cachef" ] && [ -f "$cachef" ]; then
      ws="$(cat "$cachef" 2>/dev/null || true)"
      if [ -n "$ws" ]; then
        echo "warning: cmux tree unavailable or unparseable — using cached workspace '$ws'" >&2
        echo "$ws"
        return 0
      fi
    fi
  fi
  ws=$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
  [ -n "$ws" ] || ws=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
  # Sanity check: under cmux the workspace should not be a generic branch name.
  if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then
    case "$ws" in
      main|master|trunk|develop)
        echo "warning: cmux is active but workspace resolved to '$ws' — cmux tree was unavailable or unparseable" >&2
        ;;
    esac
  fi
  echo "$ws"
}

inbox_for() {
  case "$1" in
    claude) echo "to-claude" ;;
    codex)  echo "to-codex" ;;
    *) die "unknown agent '$1' (expected claude or codex)" ;;
  esac
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
  [ -n "$as" ] || die "list: --as <claude|codex> is required"
  local root ws inbox
  root="$(cmd_root)"; ws="$(cmd_workspace)"; inbox="$(inbox_for "$as")"
  local files
  files="$(sorted_message_files "$root/$inbox" "$ws" "" "$thread" newest)"
  if [ -n "$files" ]; then
    echo "$files"
  else
    # Late delivery nudges for already-processed replies are common. Scope the
    # hint to messages that actually came TO this reader and, when supplied, to
    # this thread; otherwise an unrelated archive can masquerade as the reply.
    local latest sender
    case "$as" in claude) sender=codex ;; codex) sender=claude ;; esac
    latest="$(sorted_message_files "$root/archive" "$ws" "$sender" "$thread" newest | head -1 || true)"
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
  local order="${1:-oldest}" sender="${2:-}" thread="${3:-}"
  local f ts mt rows
  rows="$(
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -z "$sender" ] || [ "$(frontmatter_field "$f" from)" = "$sender" ] || continue
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
  [ -n "$as" ] || die "archive: --as <claude|codex> is required"
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
  case "$target" in claude|codex) ;; *) die "bind: target must be claude or codex" ;; esac
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
  local target="$1" msgfile="${2:-}"
  if [ "$target" = "${COMMS_HEADLESS_PICKUP:-}" ]; then
    echo "headless mode: reply written for pickup — the driving session reads it when this peer turn ends (no nudge needed)"
    return 0
  fi
  local rp="$(dirname "$SELF")/runphase.sh"
  if [ ! -x "$rp" ]; then
    echo "warning: COMMS_DELIVERY=headless but runphase.sh not found next to comms.sh — message written for manual pickup (re-run install.sh)"
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

cmd_deliver() {
  local target="${1:-}" msgfile="${2:-}"
  case "$target" in claude|codex) ;; *) die "deliver: target must be claude or codex" ;; esac
  if [ "${COMMS_DELIVERY:-cmux}" = "headless" ]; then
    deliver_headless "$target" "$msgfile"
    return 0
  fi
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
  local dir label
  for dir in to-claude to-codex; do
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
    case "$owes" in claude|codex) target="$owes" ;; *) target="<agent>" ;; esac
    since="$(json_get "$sf" awaiting_since_epoch)"
    case "$since" in ''|*[!0-9]*) since="$(date +%s)" ;; esac
    now="$(date +%s)"
    age_s=$(( now - since ))
    mid="$(json_get "$sf" last_sent)"
    pending=""
    case "$owes" in
      claude|codex) [ -f "$root/$(inbox_for "$owes")/$mid.md" ] && pending="$root/$(inbox_for "$owes")/$mid.md" ;;
    esac
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
  local mf="$1" outcome="${2:-unknown}" run_dir="${3:-}"
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
  case "$from" in
    claude) awaiting_from=codex ;;
    codex)  awaiting_from=claude ;;
    *)      awaiting_from=unknown ;;
  esac
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
      case "$owes" in
        claude|codex)
          [ -f "$root/$(inbox_for "$owes")/$mid.md" ] && note=" [inbox=unread]"
          ;;
      esac
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
  [ -n "$as" ] || die "clean: --as <claude|codex> is required"
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
      while IFS= read -r f; do [ -n "$f" ] && targets+=("$f"); done \
        < <(find "$root/to-claude" "$root/to-codex" "$root/archive" -maxdepth 1 -type f 2>/dev/null)
      ;;
    archive)
      while IFS= read -r f; do [ -n "$f" ] && targets+=("$f"); done \
        < <(find "$root/archive" -maxdepth 1 -type f 2>/dev/null)
      ;;
    *)
      # Specific filename — locate by basename within the three message dirs.
      local d
      for d in to-claude to-codex archive; do
        [ -f "$root/$d/$(basename "$mode")" ] && targets+=("$root/$d/$(basename "$mode")")
      done
      [ "${#targets[@]}" -gt 0 ] || die "clean: '$mode' not found in to-claude/, to-codex/, or archive/"
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
      --archive-inbound) shift; archive_inbound="${1:-}" ;;
      *) file="$1" ;;
    esac
    shift
  done
  [ -n "$to" ] || die "send: --to <claude|codex> is required"
  [ -n "$file" ] || die "send: outbound file argument required"
  # Atomicity guard: never deliver or archive on a malformed outbound message.
  cmd_validate "$file" || die "send: refusing to deliver malformed message (and not archiving inbound)"
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
  state_update_from "$file" "$outcome" "$rundir" || echo "warning: thread state not recorded" >&2
  if [ -n "$archive_inbound" ]; then
    # Archive the inbound only after the outbound was validated and delivery
    # attempted. A failed nudge still archives — the inbound WAS processed; the
    # retry surface is delivery (state last_delivery=failed + the warning above).
    case "$to" in
      codex) cmd_archive --as claude "$archive_inbound" ;;
      claude) cmd_archive --as codex "$archive_inbound" ;;
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
      if [ "${COMMS_DELIVERY:-cmux}" = "headless" ]; then
        echo "RESULT: manual — headless mode but $to was NOT spawned (see the warning above; likely runphase.sh missing or empty inbox); fix and retry 'comms.sh send --to $to <file>'"
      else
        echo "RESULT: manual — the other agent was NOT nudged; trigger it by hand or fix cmux and re-run 'comms.sh deliver $to'"
      fi
      ;;
    failed)    echo "RESULT: failed — nudge errored mid-sequence; retry with 'comms.sh send --to $to <file>'" ;;
  esac
}

case "${1:-}" in
  root)      shift; cmd_root "$@" ;;
  workspace) shift; cmd_workspace "$@" ;;
  doctor)    shift; cmd_doctor "$@" ;;
  codex-permissions) shift; cmd_codex_permissions "$@" ;;
  list)      shift; cmd_list "$@" ;;
  status)    shift; cmd_status "$@" ;;
  validate)  shift; cmd_validate "$@" ;;
  verdict)   shift; cmd_verdict "$@" ;;
  archive)   shift; cmd_archive "$@" ;;
  deliver)   shift; cmd_deliver "$@" ;;
  send)      shift; cmd_send "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  state)     shift; cmd_state "$@" ;;
  stalled)   shift; cmd_stalled "$@" ;;
  bind)      shift; cmd_bind "$@" ;;
  clean)     shift; cmd_clean "$@" ;;
  lessons)        shift; cmd_lessons "$@" ;;
  archive-search) shift; cmd_archive_search "$@" ;;
  ""|help|-h|--help)
    # Print the whole header comment block rather than a hardcoded line range —
    # a fixed range silently truncates its own last entry as the block grows.
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
    ;;
  *) die "unknown subcommand '${1}' — run 'comms.sh help'" ;;
esac
