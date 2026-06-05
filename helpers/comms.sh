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
#   list --as <claude|codex> [--thread <t>]   pending inbox messages, newest first
#   status                      one-screen loop state: latest archive, verdict, pending counts
#   validate <file>             frontmatter + body checks; non-zero exit and reasons on failure
#   verdict <file>              normalized (trimmed, uppercased) verdict from frontmatter
#   archive --as <claude|codex> <file...>   idempotent move to archive/; own inbox only
#   deliver <claude|codex>      nudge the other agent's pane via cmux; reports delivered/
#                               manual-pickup/FAILED explicitly (never hard-fails)
#   send --to <claude|codex> <file> [--archive-inbound <file>]
#                               validate, deliver, update thread state, then archive inbound
#   state <get|list|complete> [thread]      .comms/state/ thread ground truth (JSON)
#   stalled [minutes]           threads awaiting a reply older than N minutes (default 15)
#   bind <claude|codex> [surface:N]   pin which surface delivery targets (show with no arg)
#   clean --as <claude|codex> [workspace|all|archive|<file>] [--yes]
#                               guarded delete; dry-run without --yes; own-inbox default
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

# Filesystem-safe name (defined early — cache paths below need it).
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

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
      | grep -E 'workspace workspace:[0-9]+ "' \
      | head -1 \
      | sed 's/.*"\([^"]*\)".*/\1/' \
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
        echo "warning: cmux tree parse failed — using cached workspace '$ws'" >&2
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
  files="$(find "$root/$inbox" -maxdepth 1 -type f -name "${ws}_*" 2>/dev/null | sort -r)"
  if [ -n "$thread" ] && [ -n "$files" ]; then
    # Thread-scoped read: only messages whose frontmatter thread matches.
    # Prevents one loop from consuming another loop's replies in a shared workspace.
    local f matched=""
    while IFS= read -r f; do
      [ "$(frontmatter_field "$f" thread)" = "$thread" ] && matched="${matched}${matched:+
}$f"
    done <<< "$files"
    files="$matched"
  fi
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
  local workflow from_agent msg_type
  workflow="$(frontmatter_field "$file" workflow)"
  from_agent="$(frontmatter_field "$file" from)"
  msg_type="$(frontmatter_field "$file" type)"
  if [ -n "$workflow" ]; then
    for field in phase round max-rounds; do
      val="$(frontmatter_field "$file" "$field")"
      [ -n "$val" ] || errors="${errors}  workflow message missing field: $field\n"
    done
    # Only reviewer->author legs carry a verdict; claude->codex requests do not,
    # and the error lane (type: error) is verdict-free in both directions.
    if [ "$from_agent" = "codex" ] && [ "$msg_type" != "error" ]; then
      val="$(frontmatter_field "$file" verdict)"
      [ -n "$val" ] || errors="${errors}  workflow reply from codex missing field: verdict\n"
    fi
    # Protocol v2 soft requirements — warn, don't reject, so in-flight loops
    # started on older templates survive a mid-loop upgrade.
    [ -n "$(frontmatter_field "$file" thread)" ] || \
      echo "warning: workflow message has no thread field — concurrent loops in this workspace can collide" >&2
    [ -n "$(frontmatter_field "$file" message_id)" ] || \
      echo "warning: workflow message has no message_id field — replies cannot be threaded via in-reply-to" >&2
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

cmd_deliver() {
  local target="${1:-}"
  case "$target" in claude|codex) ;; *) die "deliver: target must be claude or codex" ;; esac
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
  # Capture mid-sequence cmux failures explicitly: a half-typed nudge must not
  # surface as a terse aborted command — report it so the caller/state can record it.
  local seq_ok=true
  case "$target" in
    codex)
      { cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" enter; } || seq_ok=false
      ;;
    claude)
      # Claude Code in vim mode: ensure insert mode before typing, then submit.
      { cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.2 \
        && cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" 'i' && sleep 0.2 \
        && cmux send --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" '/read-from-codex' && sleep 0.5 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 \
        && cmux send-key --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" enter; } || seq_ok=false
      ;;
  esac
  if [ "$seq_ok" = true ]; then
    # Remember the working surface for this target so the next delivery doesn't
    # have to guess among multiple terminals.
    local cachef
    cachef="$(cache_path "surface-$target" || true)"
    [ -n "$cachef" ] && { mkdir -p "$(dirname "$cachef")" && printf '%s' "$surface" > "$cachef"; } 2>/dev/null || true
    echo "delivered to $surface ($how)"
  else
    echo "warning: delivery FAILED mid-sequence to $surface — the message is safely on disk; retry with 'comms.sh send --to $target <file>' (refreshes delivery state) or nudge the pane manually"
  fi
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
  # Loud recovery surface: a pending message whose thread never got a real nudge
  # is a stalled loop the operator must act on — make it impossible to miss.
  local sf owes deliv st target
  sf="$(ls -t "$root/state/${ws}_"*.json 2>/dev/null | head -1 || true)"
  if [ -n "$sf" ]; then
    st="$(json_get "$sf" status)"
    owes="$(json_get "$sf" awaiting_from)"
    deliv="$(json_get "$sf" last_delivery)"
    if [ "$st" != "complete" ] && [ -n "$deliv" ] && [ "$deliv" != "delivered" ]; then
      case "$owes" in claude|codex) target="$owes" ;; *) target="<agent>" ;; esac
      echo "ACTION NEEDED: last delivery was '$deliv' — $owes was NOT nudged. Run 'comms.sh deliver $target' (or trigger the pane by hand)."
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

# state_update_from <message-file> <delivery-outcome> — derive thread state from
# an outbound workflow message's frontmatter. The ONLY writers of state are this
# (via send) and `state complete`; readers must treat it as advisory ground truth.
state_update_from() {
  local mf="$1" outcome="${2:-unknown}"
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
  printf '{\n  "workspace": "%s",\n  "thread": "%s",\n  "workflow": "%s",\n  "phase": "%s",\n  "round": "%s",\n  "max_rounds": "%s",\n  "status": "in-progress",\n  "awaiting_from": "%s",\n  "awaiting_since": "%s",\n  "awaiting_since_epoch": "%s",\n  "last_sent": "%s",\n  "last_delivery": "%s"\n}\n' \
    "$(json_escape "$ws")" "$(json_escape "$thread")" "$(json_escape "$wf")" \
    "$(json_escape "$phase")" "$(json_escape "$round")" "$(json_escape "$maxr")" \
    "$awaiting_from" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" \
    "$(json_escape "$mid")" "$outcome" \
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
  local mins="${1:-15}" dir ws now f age_s since
  dir="$(state_dir)"; ws="$(cmd_workspace)"; now="$(date +%s)"
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
      printf 'STALLED %sm: thread=%s %s/%s r%s awaiting=%s last_delivery=%s\n' \
        "$(( age_s / 60 ))" "$(json_get "$f" thread)" "$(json_get "$f" workflow)" \
        "$(json_get "$f" phase)" "$(json_get "$f" round)" \
        "$(json_get "$f" awaiting_from)" "$(json_get "$f" last_delivery)"
    fi
  done
  if [ "$any" = false ]; then
    echo "no stalled threads (threshold: ${mins}m)"
  fi
}

cmd_verdict() {
  local file="${1:-}"
  [ -n "$file" ] || die "verdict: file argument required"
  frontmatter_field "$file" verdict | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]'
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
  local del_out outcome=manual
  del_out="$(cmd_deliver "$to")"
  echo "$del_out"
  case "$del_out" in
    *"delivered to"*) outcome=delivered ;;
    *FAILED*)         outcome=failed ;;
  esac
  # Record thread ground truth (workflow messages with a thread only). The
  # ||-context also suppresses errexit inside the function, so NO state failure
  # mode — mkdir, redirect, parse — can abort send before the inbound archive.
  state_update_from "$file" "$outcome" || echo "warning: thread state not recorded" >&2
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
  # Calling agents MUST relay anything other than `delivered` to the user — a
  # manual outcome means the other agent was NOT woken and the loop sits idle.
  case "$outcome" in
    delivered) echo "RESULT: delivered" ;;
    manual)    echo "RESULT: manual — the other agent was NOT nudged; trigger it by hand or fix cmux and re-run 'comms.sh deliver $to'" ;;
    failed)    echo "RESULT: failed — nudge errored mid-sequence; retry with 'comms.sh send --to $to <file>'" ;;
  esac
}

case "${1:-}" in
  root)      shift; cmd_root "$@" ;;
  workspace) shift; cmd_workspace "$@" ;;
  list)      shift; cmd_list "$@" ;;
  status)    shift; cmd_status "$@" ;;
  validate)  shift; cmd_validate "$@" ;;
  verdict)   shift; cmd_verdict "$@" ;;
  archive)   shift; cmd_archive "$@" ;;
  deliver)   shift; cmd_deliver "$@" ;;
  send)      shift; cmd_send "$@" ;;
  state)     shift; cmd_state "$@" ;;
  stalled)   shift; cmd_stalled "$@" ;;
  bind)      shift; cmd_bind "$@" ;;
  clean)     shift; cmd_clean "$@" ;;
  ""|help|-h|--help)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand '${1}' — run 'comms.sh help'" ;;
esac
