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
#   list --as <claude|codex>    list pending inbox messages for this workspace, newest first
#   status                      one-screen loop state: latest archive, verdict, pending counts
#   validate <file>             frontmatter + body checks; non-zero exit and reasons on failure
#   archive --as <claude|codex> <file...>   idempotent move to archive/; own inbox only
#   deliver <claude|codex>      nudge the other agent's pane via cmux (no-op warning without cmux)
#   send --to <claude|codex> <file> [--archive-inbound <file>]
#                               validate, deliver, then (only after both) archive the inbound
set -euo pipefail

die() { echo "comms.sh: $*" >&2; exit 1; }

main_repo_root() {
  git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'
}

cmd_root() {
  local r
  r="$(main_repo_root)"
  [ -n "$r" ] || die "not inside a git repository"
  echo "$r/.comms"
}

cmd_workspace() {
  local ws=""
  if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    ws=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null \
      | grep -E 'workspace workspace:[0-9]+ "' \
      | head -1 \
      | sed 's/.*"\([^"]*\)".*/\1/' \
      | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
  fi
  [ -n "$ws" ] || ws=$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
  [ -n "$ws" ] || ws=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
  # Sanity check: under cmux the workspace should not be a generic branch name.
  if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then
    case "$ws" in
      main|master|trunk|develop)
        echo "warning: cmux is active but workspace resolved to '$ws' — the cmux tree parse may have drifted" >&2
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
  local as=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as) shift; as="${1:-}" ;;
      *) die "list: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$as" ] || die "list: --as <claude|codex> is required"
  local root ws inbox
  root="$(cmd_root)"; ws="$(cmd_workspace)"; inbox="$(inbox_for "$as")"
  local files
  files="$(find "$root/$inbox" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null | sort -r)"
  if [ -n "$files" ]; then
    echo "$files"
  else
    # Late delivery nudges for already-processed replies are common — surface that.
    local latest
    latest="$(find "$root/archive" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null | sort | tail -1)"
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
  local workflow from_agent
  workflow="$(frontmatter_field "$file" workflow)"
  from_agent="$(frontmatter_field "$file" from)"
  if [ -n "$workflow" ]; then
    for field in phase round max-rounds; do
      val="$(frontmatter_field "$file" "$field")"
      [ -n "$val" ] || errors="${errors}  workflow message missing field: $field\n"
    done
    # Only reviewer->author legs carry a verdict; claude->codex requests do not.
    if [ "$from_agent" = "codex" ]; then
      val="$(frontmatter_field "$file" verdict)"
      [ -n "$val" ] || errors="${errors}  workflow reply from codex missing field: verdict\n"
    fi
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

pick_other_surface() {
  # Pane-aware picker: prefer a [terminal] surface in a pane OTHER than the one
  # marked "◀ here"; fall back to any other terminal surface (single-pane
  # multi-tab layouts). This is a real script — awk $0 is safe here.
  cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null | awk '
    /pane:/ { for (i=1;i<=NF;i++) if ($i ~ /^pane:/) cur_pane=$i }
    /surface:.*\[terminal\]/ {
      if (match($0, /surface:[0-9]+/)) {
        n++; surf[n]=substr($0,RSTART,RLENGTH); pane[n]=cur_pane
        here[n] = ($0 ~ /◀ here/) ? 1 : 0
        if (here[n]) here_pane=cur_pane
      }
    }
    END {
      for (i=1;i<=n;i++) if (!here[i] && pane[i]!=here_pane) { print surf[i]; exit }
      for (i=1;i<=n;i++) if (!here[i]) { print surf[i]; exit }
    }'
}

cmd_deliver() {
  local target="${1:-}"
  case "$target" in claude|codex) ;; *) die "deliver: target must be claude or codex" ;; esac
  if ! command -v cmux >/dev/null 2>&1 || [ -z "${CMUX_WORKSPACE_ID:-}" ]; then
    echo "warning: cmux not available; message written for manual pickup"
    return 0
  fi
  local surface
  surface="$(pick_other_surface)"
  if [ -z "$surface" ]; then
    echo "warning: could not find a $target surface; message written for manual pickup"
    return 0
  fi
  case "$target" in
    codex)
      cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5
      cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3
      cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" enter
      ;;
    claude)
      # Claude Code in vim mode: ensure insert mode before typing, then submit.
      cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.2
      cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" 'i' && sleep 0.2
      cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" '/read-from-codex' && sleep 0.5
      cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3
      cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" enter
      ;;
  esac
  echo "delivered to $surface"
}

cmd_status() {
  local root ws
  root="$(cmd_root)"; ws="$(cmd_workspace)"
  echo "workspace: $ws"
  echo "comms root: $root"
  local latest
  latest="$(find "$root/archive" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null | sort | tail -1)"
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
    label="$(find "$root/$dir" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null | sort -r | head -3 | sed 's/^/    /')"
    echo "pending in $dir: $(find "$root/$dir" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null | wc -l | tr -d ' ')"
    [ -n "$label" ] && echo "$label"
  done
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
  cmd_deliver "$to"
  if [ -n "$archive_inbound" ]; then
    # Archive the inbound only after the outbound was validated and delivery attempted.
    case "$to" in
      codex) cmd_archive --as claude "$archive_inbound" ;;
      claude) cmd_archive --as codex "$archive_inbound" ;;
    esac
  fi
}

case "${1:-}" in
  root)      shift; cmd_root "$@" ;;
  workspace) shift; cmd_workspace "$@" ;;
  list)      shift; cmd_list "$@" ;;
  status)    shift; cmd_status "$@" ;;
  validate)  shift; cmd_validate "$@" ;;
  archive)   shift; cmd_archive "$@" ;;
  deliver)   shift; cmd_deliver "$@" ;;
  send)      shift; cmd_send "$@" ;;
  ""|help|-h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand '${1}' — run 'comms.sh help'" ;;
esac
