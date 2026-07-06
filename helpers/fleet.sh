#!/bin/bash
# agent-comms fleet helper — orchestrate execution workspaces (<prefix>-N) from a
# control workspace. Extracted from the /fleet command template so the logic is
# testable, shell-portable, and immune to slash-command argument substitution.
#
# Subcommands:
#   status                                   table: pane states + latest archive per workspace
#   dispatch <ws> <brief> [--plan-first] [--force]   clear panes + fire /auto-implement (or /auto-full)
#   dispatch-all <brief...> [--plan-first] [--force] [--yes]   map briefs to free workspaces; fire with --yes
#   harvest                                  list workspaces idle + approved (ready for next brief)
#   clear <ws>                               /new both panes
#   help                                     this usage
#
# Env: FLEET_PREFIX (default ws), FLEET_MAX (default 3)
set -euo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMS_SH="$HELPER_DIR/comms.sh"

die() { echo "fleet.sh: $*" >&2; exit 1; }

FLEET_PREFIX="${FLEET_PREFIX:-ws}"
FLEET_MAX="${FLEET_MAX:-3}"
REPO_ROOT="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')"
[ -n "$REPO_ROOT" ] || die "not inside a git repository"
COMMS_ROOT="$REPO_ROOT/.comms"
REPO_NAME="$(basename "$REPO_ROOT")"

command -v cmux >/dev/null 2>&1 || die "cmux is required for /fleet"
command -v python3 >/dev/null 2>&1 || die "python3 is required for /fleet (pane-title classification)"

# Workspace-name -> workspace:ref map, natural-sorted so ws-2 precedes ws-10.
fleet_list() {
  cmux list-workspaces 2>/dev/null \
    | sed 's/^\* //' \
    | awk -v pfx="$FLEET_PREFIX" '$0 ~ "workspace:[0-9]+[[:space:]]+" pfx "-[0-9]+" {print $2, $1}' \
    | sort -V
}

pane_surface() {  # pane_surface <ref> <pane-index>
  cmux tree --workspace "$1" 2>/dev/null \
    | awk -v want="$2" '/├── pane|└── pane/{n++} n==want && /surface surface:/{match($0, /surface:[0-9]+/); print substr($0, RSTART, RLENGTH); exit}'
}

pane_title() {  # pane_title <ref> <pane-index>
  cmux tree --workspace "$1" 2>/dev/null \
    | awk -v want="$2" '/├── pane|└── pane/{n++} n==want && /surface surface:/{print; exit}' \
    | sed -n 's/.*\[terminal\] "\([^"]*\)".*/\1/p'
}

# Spinner-only classifier: braille prefix = active, anything else = idle.
spin_state() {  # spin_state <title>
  python3 -c 'import sys
s = sys.argv[1].lstrip()
print("active" if s and 0x2800 <= ord(s[0]) <= 0x28FF else "idle")' "$1" 2>/dev/null
}

# Three-way classifier for status: spin | bare | task (see status legend).
classify_title() {  # classify_title <title>
  python3 -c 'import sys, re
s = sys.argv[1].lstrip()
repo = sys.argv[2]
if not s:
    print("bare"); sys.exit()
if 0x2800 <= ord(s[0]) <= 0x28FF:
    print("spin"); sys.exit()
s = re.sub(r"^[^\w\s]+\s+", "", s)
print("bare" if s in ("", "Claude Code", repo) else "task")' "$1" "$REPO_NAME" 2>/dev/null
}

latest_archive() {  # latest_archive <ws-name>
  find "$COMMS_ROOT/archive" -maxdepth 1 -type f -name "${1}_*.md" 2>/dev/null | sort | tail -1
}

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Frontmatter-bounded field read (CRLF-tolerant) — matching anywhere in the file
# would let a body line like "verdict: APPROVE" (quoted prose) fake a completion.
fm() {
  awk -v f="$2" '{sub(/\r$/, "")}
    NR==1 && $0=="---" {inFM=1; next}
    inFM && $0=="---" {exit}
    inFM && index($0, f ":")==1 {sub("^" f ":[[:space:]]*", ""); print; exit}' "$1"
}

# Normalized verdict (trimmed, uppercased, loopspec synonyms mapped) so " approve"
# and the canonical `pass`/`fail` spellings gate identically to comms.sh — fleet's
# completion gates must agree with the kernel or a pass-terminated loop wedges
# dispatch-all/harvest.
norm_verdict() {
  local v
  v="$(fm "$1" verdict | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
  case "$v" in
    PASS) v=APPROVE ;;
    FAIL) v=REQUEST_CHANGES ;;
  esac
  printf '%s' "$v"
}

cmd_status() {
  local now name ref tree ctitle xtitle ctype xtype latest latest_mt
  now="$(date +%s)"
  fleet_list | while read -r name ref; do
    [ -z "$name" ] && continue
    ctitle="$(pane_title "$ref" 1)"
    xtitle="$(pane_title "$ref" 2)"
    ctype="$(classify_title "$ctitle")"
    xtype="$(classify_title "$xtitle")"

    latest="$(latest_archive "$name")"
    local summary="(no archive yet)" latest_mt=0
    if [ -n "$latest" ]; then
      local round maxr wflow phase verdict
      round="$(fm "$latest" round)"; maxr="$(fm "$latest" max-rounds)"
      wflow="$(fm "$latest" workflow)"; phase="$(fm "$latest" phase)"
      verdict="$(norm_verdict "$latest")"
      summary="$wflow/$phase r${round}/${maxr} ${verdict:-in-progress}"
      latest_mt="$(mtime_of "$latest")"
    fi

    # Protocol v2 ground truth: newest thread-state file for this workspace.
    local state_note="" sf st_status owes since_epoch
    sf="$(ls -t "$COMMS_ROOT/state/${name}_"*.json 2>/dev/null | head -1 || true)"
    if [ -n "$sf" ]; then
      st_status="$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$sf" | head -1)"
      owes="$(sed -n 's/.*"awaiting_from": "\([^"]*\)".*/\1/p' "$sf" | head -1)"
      since_epoch="$(sed -n 's/.*"awaiting_since_epoch": "\([^"]*\)".*/\1/p' "$sf" | head -1)"
      if [ "$st_status" != complete ] && [ -n "$owes" ] && [ "$owes" != none ]; then
        case "$since_epoch" in ''|*[!0-9]*) since_epoch=$now ;; esac  # garbage epoch must not crash status
        state_note=" owes=${owes} $(( ( now - since_epoch ) / 60 ))m"
      fi
    fi

    # Composite state: ✳+task counts as active only if corroborated by braille
    # on the other pane OR an archive mtime within the last 10 min; else stale.
    resolve() {
      local t="$1" other="$2"
      case "$t" in
        spin) echo active ;;
        bare) echo idle ;;
        task)
          if [ "$other" = spin ] || [ $(( now - latest_mt )) -lt 600 ]; then echo active; else echo stale; fi ;;
        *) echo unknown ;;  # classifier failure — surface it, don't render blank
      esac
    }
    local cstate xstate
    cstate="$(resolve "$ctype" "$xtype")"
    xstate="$(resolve "$xtype" "$ctype")"

    # Pending counts only meaningful when Claude is not actively running.
    local pin="-" pout="-"
    if [ "$cstate" != active ]; then
      pin=0; pout=0
      local f m
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        m="$(mtime_of "$f")"
        [ "${m:-0}" -gt "$latest_mt" ] && pin=$((pin+1))
      done < <(find "$COMMS_ROOT/to-claude" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null)
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        m="$(mtime_of "$f")"
        [ "${m:-0}" -gt "$latest_mt" ] && pout=$((pout+1))
      done < <(find "$COMMS_ROOT/to-codex" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null)
    fi

    printf "%-8s  claude=%-6s  codex=%-6s  %-45s  in=%s out=%s%s\n" \
      "$name" "$cstate" "$xstate" "$summary" "$pin" "$pout" "$state_note"
  done
}

fleet_preflight() {  # fleet_preflight <force-bool>
  local force="$1" reject="" active_count=0 active_names="" name ref title state
  while read -r name ref; do
    [ -z "$name" ] && continue
    title="$(pane_title "$ref" 1)"
    state="$(spin_state "$title")"
    if [ "$state" = active ]; then
      active_count=$((active_count+1))
      active_names="$active_names$name "
    fi
  done <<< "$(fleet_list)"

  if [ "$active_count" -ge "$FLEET_MAX" ]; then
    reject="concurrency cap: $active_count/$FLEET_MAX active (${active_names}) — wait, bump FLEET_MAX, or pass --force"
  fi
  if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
    echo "WARNING: staged files exist in this worktree — inspect 'git diff --cached --stat' before any commits." >&2
  fi
  if [ -e "$REPO_ROOT/.git/index.lock" ]; then
    echo "WARNING: .git/index.lock exists — another commit is in flight." >&2
  fi
  if [ -n "$reject" ]; then
    if [ "$force" = true ]; then
      echo "preflight WARNING (forced): $reject" >&2
    else
      echo "preflight REJECTED: $reject" >&2
      echo "(pass --force to override)" >&2
      return 1
    fi
  fi
  return 0
}

send_line() {  # send_line <surface> <ref> <text> — type text, escape, enter
  cmux send --surface "$1" --workspace "$2" "$3" && sleep 0.5
  cmux send-key --surface "$1" --workspace "$2" escape && sleep 0.3
  cmux send-key --surface "$1" --workspace "$2" enter
}

clear_pane() {  # clear_pane <surface> <ref> <settle-seconds>
  cmux send --surface "$1" --workspace "$2" '/new' && sleep 0.4
  cmux send-key --surface "$1" --workspace "$2" escape && sleep 0.2
  cmux send-key --surface "$1" --workspace "$2" enter && sleep "$3"
}

cmd_dispatch() {
  local mode="auto-implement" force=false target="" brief=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      --plan-first) mode="auto-full" ;;
      --force) force=true ;;
      *)
        if [ -z "$target" ]; then target="$arg"
        else brief="${brief:+$brief }$arg"
        fi
        ;;
    esac
  done
  [ -n "$target" ] || die "usage: fleet.sh dispatch <workspace> <brief-path> [--plan-first] [--force]"
  [ -n "$brief" ] || die "missing brief path — usage: fleet.sh dispatch <workspace> <brief-path> [--plan-first]"

  local ref
  ref="$(fleet_list | awk -v n="$target" '$1==n {print $2}')"
  [ -n "$ref" ] || die "unknown workspace: $target — known: $(fleet_list | awk '{print $1}' | tr '\n' ' ')"

  local abs_brief
  case "$brief" in
    /*) abs_brief="$brief" ;;
    *)  abs_brief="$REPO_ROOT/$brief" ;;
  esac
  [ -f "$abs_brief" ] || die "brief not found at: $abs_brief"

  local csurf xsurf
  csurf="$(pane_surface "$ref" 1)"
  xsurf="$(pane_surface "$ref" 2)"
  [ -n "$csurf" ] && [ -n "$xsurf" ] || die "could not resolve both panes in $target (claude=$csurf, codex=$xsurf)"

  # Target busy-check: never /new a workspace whose Claude pane is actively
  # running — that destroys an in-flight loop. Fleet-wide preflight does not
  # check the specific target; this does.
  local title state
  title="$(pane_title "$ref" 1)"
  state="$(spin_state "$title")"
  if [ "$state" = active ] && [ "$force" != true ]; then
    die "REJECTED: $target's Claude pane is actively running — dispatching would clobber the in-flight loop. Wait, run 'fleet.sh clear $target' deliberately, or pass --force."
  fi

  fleet_preflight "$force" || exit 1

  echo "dispatching: $target ($ref)  claude=$csurf  codex=$xsurf  mode=/$mode"
  echo "brief: $brief"

  clear_pane "$csurf" "$ref" 0.6
  clear_pane "$xsurf" "$ref" 0.8
  send_line "$csurf" "$ref" "/$mode $brief"

  echo "dispatched — watch $target for progress, or run 'fleet.sh status' later."
}

cmd_dispatch_all() {
  local mode_flag="" force_flag="" yes=false briefs=() arg
  for arg in "$@"; do
    case "$arg" in
      --plan-first) mode_flag="--plan-first" ;;
      --force) force_flag="--force" ;;
      --yes) yes=true ;;
      *) briefs+=("$arg") ;;
    esac
  done
  [ "${#briefs[@]}" -gt 0 ] || die "usage: fleet.sh dispatch-all <brief1> [brief2 ...] [--plan-first] [--force] [--yes]"

  # Free = Claude pane idle (no spinner) AND latest archive missing or APPROVE
  # AND no unread message newer than the archive (same pending rule as harvest —
  # firing over unread mail would orphan an in-flight exchange).
  # A normalized APPROVE (or its canonical synonym pass) is the protocol's only completion signal.
  local free=() name ref title state latest verdict latest_mt pending f m
  while read -r name ref; do
    [ -z "$name" ] && continue
    title="$(pane_title "$ref" 1)"
    state="$(spin_state "$title")"
    [ "$state" = idle ] || continue
    latest="$(latest_archive "$name")"
    if [ -n "$latest" ]; then
      verdict="$(norm_verdict "$latest")"
      [ "$verdict" = APPROVE ] || continue
      latest_mt="$(mtime_of "$latest")"
    else
      # First-handoff state: no archive yet does NOT mean free — a pending
      # message (e.g. to-codex/ws-N_* awaiting Codex's first read) is an
      # active round. Run the pending scan below with everything "newer".
      latest_mt=0
    fi
    pending=""
    for dir in "$COMMS_ROOT/to-claude" "$COMMS_ROOT/to-codex"; do
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        m="$(mtime_of "$f")"
        if [ "${m:-0}" -gt "$latest_mt" ]; then
          pending="$(basename "$f")"
          break 2
        fi
      done < <(find "$dir" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null)
    done
    if [ -n "$pending" ]; then
      echo "excluding $name — unread message newer than archive: $pending" >&2
      continue
    fi
    free+=("$name")
  done <<< "$(fleet_list)"

  echo "free workspaces: ${#free[@]} / briefs to dispatch: ${#briefs[@]}"
  if [ "${#briefs[@]}" -gt "${#free[@]}" ]; then
    printf '%s\n' "${free[@]}"
    die "not enough free workspaces — clear some with 'fleet.sh clear <ws>' or check 'fleet.sh status'"
  fi

  local i
  echo "assignment:"
  for i in "${!briefs[@]}"; do
    printf '  %s -> %s\n' "${briefs[$i]}" "${free[$i]}"
  done

  if [ "$yes" != true ]; then
    echo "(dry run — re-run with --yes to fire, or dispatch individually)"
    return 0
  fi

  # Fire each pair; cmd_dispatch re-validates the target at fire time, so a
  # workspace that went busy since the scan is skipped, not clobbered.
  # Subshell is load-bearing: cmd_dispatch fails via die/exit, which would
  # otherwise abort the whole batch instead of skipping one target.
  # force_flag is forwarded so `dispatch-all --yes --force` overrides the
  # concurrency cap and busy-check exactly like single dispatch --force.
  for i in "${!briefs[@]}"; do
    if ! ( cmd_dispatch "${free[$i]}" "${briefs[$i]}" $mode_flag $force_flag ); then
      echo "skipped ${free[$i]} (no longer dispatchable) — brief NOT fired: ${briefs[$i]}" >&2
    fi
    sleep 2
  done
}

cmd_harvest() {
  local name ref title state latest verdict phase wflow round latest_mt pending f m
  fleet_list | while read -r name ref; do
    [ -z "$name" ] && continue
    title="$(pane_title "$ref" 1)"
    state="$(spin_state "$title")"
    [ "$state" = idle ] || continue
    latest="$(latest_archive "$name")"
    if [ -z "$latest" ]; then
      echo "$name: idle, no archive (never dispatched or freshly cleared)"
      continue
    fi
    verdict="$(norm_verdict "$latest")"
    phase="$(fm "$latest" phase)"
    wflow="$(fm "$latest" workflow)"
    round="$(fm "$latest" round)"
    latest_mt="$(mtime_of "$latest")"

    pending=""
    for dir in "$COMMS_ROOT/to-claude" "$COMMS_ROOT/to-codex"; do
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        m="$(mtime_of "$f")"
        if [ "${m:-0}" -gt "$latest_mt" ]; then
          pending="$(basename "$f")"
          break 2
        fi
      done < <(find "$dir" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null)
    done
    if [ -n "$pending" ]; then
      echo "$name: idle but PENDING — unread message $pending (run /read-from-codex or /clean-comms)"
      continue
    fi

    if [ "$verdict" = APPROVE ]; then
      echo "$name: READY — $wflow/$phase approved at round $round (archive: $(basename "$latest"))"
    else
      echo "$name: idle but not approved — last archive: $wflow/$phase r$round verdict=${verdict:-none}"
    fi
  done
}

cmd_clear() {
  local target="${1:-}"
  [ -n "$target" ] || die "usage: fleet.sh clear <workspace>"
  local ref
  ref="$(fleet_list | awk -v n="$target" '$1==n {print $2}')"
  [ -n "$ref" ] || die "unknown workspace: $target"
  local csurf xsurf surf
  csurf="$(pane_surface "$ref" 1)"
  xsurf="$(pane_surface "$ref" 2)"
  for surf in "$csurf" "$xsurf"; do
    [ -z "$surf" ] && continue
    clear_pane "$surf" "$ref" 0.5
  done
  echo "cleared $target (claude=$csurf, codex=$xsurf)"
}

cmd_help() {
  cat <<'USAGE'
fleet.sh status                                      — table of what every <prefix>-N is doing
fleet.sh dispatch <ws> <brief-path>                  — clear + fire /auto-implement
fleet.sh dispatch <ws> <brief-path> --plan-first     — clear + fire /auto-full instead
fleet.sh dispatch-all <brief...> [--plan-first]      — print brief->workspace mapping (dry run)
fleet.sh dispatch-all <brief...> --yes [--force]     — fire the mapping (--force overrides cap/busy-check)
fleet.sh harvest                                     — list workspaces idle + approved
fleet.sh clear <ws>                                  — /new both panes
fleet.sh help                                        — this

Env:
  FLEET_PREFIX  workspace name prefix to scan for (default: ws)
  FLEET_MAX     concurrency cap (default: 3) — bypass with --force
USAGE
}

case "${1:-status}" in
  status)       shift || true; cmd_status "$@" ;;
  dispatch)     shift; cmd_dispatch "$@" ;;
  dispatch-all) shift; cmd_dispatch_all "$@" ;;
  harvest)      shift || true; cmd_harvest "$@" ;;
  clear)        shift; cmd_clear "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown subcommand '${1}' — run 'fleet.sh help'" ;;
esac
