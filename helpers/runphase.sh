#!/bin/bash
# agent-comms headless peer-turn runner (codex and claude backends).
#
# Replaces the cmux keystroke nudge with a detached subprocess (`codex exec` or
# `claude -p`): the peer turn is spawned, observed (JSONL event log),
# resumed-or-failed (session id recorded), and recorded (result.json + thread
# state) — without typing into another terminal. Opt-in per call via
# COMMS_DELIVERY=headless (comms.sh deliver/send route here); cmux stays the
# default delivery path.
#
# Subcommands:
#   spawn --message <file> [--provider codex|claude] [--sandbox <mode>] [--timeout-secs N]
#         detach a `run` and return immediately; prints pid + run dir.
#         Refuses (HELD) while the thread — or everything — is held; see hold.
#   run --message <file> --dir <run-dir> [--provider ...] [--sandbox <mode>] [--timeout-secs N]
#         foreground runner (spawn's child): build the prompt, drive the
#         provider CLI, tee events, write result.json on every exit path,
#         update thread state
#   await <run-dir> [--timeout-secs N]
#         block until result.json exists (or the runner dies); print it;
#         exit 0 only for status=completed
#   result <run-dir>       print result.json if present
#   hold [thread]          pause: block new spawns for the thread (all threads
#                          with no arg); prints attach commands from state
#   release [thread]       lift a hold
#
# Env knobs: COMMS_RUNPHASE_SANDBOX (codex sandbox, default workspace-write),
#            COMMS_RUNPHASE_TIMEOUT_SECS (default 1800),
#            COMMS_RUNPHASE_SPAWN_DELAY_SECS (default 1 — see run()),
#            COMMS_RUNPHASE_CLAUDE_PERMISSION_MODE (default acceptEdits),
#            COMMS_RUNPHASE_CLAUDE_ALLOWED_TOOLS (default Bash),
#            COMMS_RUNPHASE_CLAUDE_ARGS (extra claude flags; bypass flags refused).
set -euo pipefail

die() { echo "runphase.sh: $*" >&2; exit 1; }

case "$0" in
  /*) SELF="$0" ;;
  *)  SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac
HELPER_DIR="$(dirname "$SELF")"
# Sibling comms.sh is the single source of truth for root/workspace resolution —
# runphase must derive the SAME names the driver derived, or reply prefixes and
# state keys split mid-loop (a known field-incident class).
COMMS="$HELPER_DIR/comms.sh"
[ -x "$COMMS" ] || die "comms.sh not found next to runphase.sh ($HELPER_DIR) — re-run install.sh"

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# || true: head exiting early can SIGPIPE sed under pipefail — a lookup must
# yield empty, never a non-zero status that set -e turns into a dead runner.
json_get() { { sed -n 's/.*"'"$2"'": "\([^"]*\)".*/\1/p' "$1" | head -1; } 2>/dev/null || true; }

# Duplicated from comms.sh (same precedent as fleet.sh): helpers are installed
# as standalone copies and must not depend on sourcing each other.
frontmatter_field() {
  awk -v f="$2" '{sub(/\r$/, "")}
    NR==1 && $0=="---" {inFM=1; next}
    inFM && $0=="---" {exit}
    inFM && index($0, f ":")==1 {sub("^" f ":[[:space:]]*", ""); print; exit}' "$1"
}

abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}

peer_of() { case "$1" in claude) echo codex ;; codex) echo claude ;; esac; }
session_field_of() { case "$1" in claude) echo claude_session_id ;; codex) echo codex_thread_id ;; esac; }

# skill_file <name> — resolve the Codex skill text the headless peer should
# follow. Project-local pin wins (matches the install-shadowing convention),
# then the global install, then the repo checkout's templates.
skill_file() {
  local name="$1" main_root="$2" p
  for p in \
    "$main_root/.agents/skills/$name/SKILL.md" \
    "${CODEX_SKILLS_DIR:-$HOME/.codex/skills}/$name/SKILL.md" \
    "$HELPER_DIR/../templates/codex-skills/$name/SKILL.md"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# command_file <name.md> — the Claude-side equivalent of skill_file: resolve
# the command template a headless Claude turn should follow.
command_file() {
  local name="$1" main_root="$2" p
  for p in \
    "$main_root/.claude/commands/$name" \
    "${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}/$name" \
    "$HELPER_DIR/../templates/claude-commands/$name"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# ---------- hold / release (pause at the next turn boundary) ----------

hold_dir() { echo "$("$COMMS" root)/hold"; }

hold_active() {  # hold_active <thread> — prints the marker path if held
  local t="$1" hd
  hd="$(hold_dir)"
  if [ -f "$hd/ALL" ]; then printf '%s' "$hd/ALL"; return 0; fi
  if [ -n "$t" ] && [ -f "$hd/$(safe_name "$t")" ]; then printf '%s' "$hd/$(safe_name "$t")"; return 0; fi
  return 1
}

print_attach() {  # print_attach <thread> — exact resume commands from thread state
  local thread="$1" ws root sf sid tid
  [ -n "$thread" ] || return 0
  ws="$("$COMMS" workspace 2>/dev/null)" || return 0
  root="$("$COMMS" root 2>/dev/null)" || return 0
  sf="$root/state/$(safe_name "$ws")_$(safe_name "$thread").json"
  [ -f "$sf" ] || return 0
  sid="$(json_get "$sf" claude_session_id)"
  tid="$(json_get "$sf" codex_thread_id)"
  # --resume by id searches the current project dir — run from the loop's tree.
  # Plain ifs, not `[ ] && echo`: an empty id must not leak a non-zero status
  # into set -e callers (spawn would misreport HELD as a failed spawn).
  if [ -n "$sid" ]; then
    echo "  attach claude: (cd to the loop's cwd, then) claude --resume $sid"
  fi
  if [ -n "$tid" ]; then
    echo "  attach codex:  codex resume $tid   (headless: codex exec resume $tid \"<prompt>\")"
  fi
  return 0
}

cmd_hold() {
  local thread="${1:-}" hd f
  hd="$(hold_dir)"
  mkdir -p "$hd" || die "hold: cannot create $hd"
  if [ -n "$thread" ]; then f="$hd/$(safe_name "$thread")"; else f="$hd/ALL"; fi
  date -u +%Y-%m-%dT%H:%M:%SZ > "$f"
  echo "held: ${thread:-ALL threads} — new headless turns are blocked at the next turn boundary (in-flight turns finish)"
  echo "  release with: \"$SELF\" release${thread:+ $thread}"
  print_attach "$thread"
}

cmd_release() {
  local thread="${1:-}" hd f
  hd="$(hold_dir)"
  if [ -n "$thread" ]; then f="$hd/$(safe_name "$thread")"; else f="$hd/ALL"; fi
  if [ -f "$f" ]; then
    rm -f "$f"
    echo "released: ${thread:-ALL}"
  else
    echo "no hold set for ${thread:-ALL}"
  fi
}

# ---------- result.json (written on EVERY runner exit path) ----------

RESULT_WRITTEN=false
RUN_PROVIDER=codex
write_result() {  # write_result <run-dir> <status> <exit-code> <session-id> <message-file> <note>
  local dir="$1" status="$2" rc="$3" sid="$4" mf="$5" note="$6"
  [ "$RESULT_WRITTEN" = true ] && return 0
  printf '{\n  "provider": "'"$RUN_PROVIDER"'",\n  "status": "%s",\n  "exit_code": "%s",\n  "session_id": "%s",\n  "message_file": "%s",\n  "run_dir": "%s",\n  "started_at": "%s",\n  "ended_at": "%s",\n  "note": "%s"\n}\n' \
    "$(json_escape "$status")" "$(json_escape "$rc")" "$(json_escape "$sid")" \
    "$(json_escape "$mf")" "$(json_escape "$dir")" \
    "$(json_escape "${STARTED_AT:-}")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(json_escape "$note")" \
    > "$dir/result.json.tmp" && mv "$dir/result.json.tmp" "$dir/result.json" \
    || echo "warning: could not write result.json in $dir" >&2
  RESULT_WRITTEN=true
}

# update_thread_state <thread> <status> <session-id> <session-field> — mirror
# the turn outcome into .comms/state/<ws>_<thread>.json so `state list`/
# `stalled`/fleet see headless ground truth. Takes the thread VALUE, not the
# message file: the child archives (moves) the message before we exit, so
# re-reading it here would fail exactly on the success path. Advisory like all
# state writes: never fatal.
update_thread_state() {
  local thread="$1" status="$2" sid="$3" field="${4:-codex_thread_id}"
  local ws sf root
  [ -n "$thread" ] || return 0   # one-shot message (e.g. /ask-codex): no state
  ws="$("$COMMS" workspace 2>/dev/null)" || return 0
  root="$("$COMMS" root 2>/dev/null)" || return 0
  sf="$root/state/$(safe_name "$ws")_$(safe_name "$thread").json"
  # send writes this file moments AFTER deliver spawns us — tolerate the window.
  local i
  for i in 1 2 3; do
    [ -f "$sf" ] && break
    sleep 2
  done
  if [ ! -f "$sf" ]; then
    echo "note: no thread state file to update ($sf)" >&2
    return 0
  fi
  # Replace this provider's session field; the OTHER provider's field (set by a
  # reverse-direction round on the same thread) is passed through untouched.
  # Session fields are inserted BEFORE last_delivery, which stays the final
  # field, so repeated updates keep the JSON valid.
  awk -v st="$status" -v sid="$sid" -v fld="$field" '
    index($0, "\"" fld "\":") { next }   # re-emitted next to last_delivery below
    /"last_delivery":/ {
      if (sid != "") printf "  \"%s\": \"%s\",\n", fld, sid
      printf "  \"last_delivery\": \"%s\"\n", st
      next
    }
    { print }
  ' "$sf" > "$sf.tmp" 2>/dev/null && mv "$sf.tmp" "$sf" \
    || echo "warning: could not update thread state $sf" >&2
}

# ---------- spawn ----------

cmd_spawn() {
  local msg="" sandbox="" timeout="" provider="codex"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) shift; msg="${1:-}" ;;
      --provider) shift; provider="${1:-}" ;;
      --sandbox) shift; sandbox="${1:-}" ;;
      --timeout-secs) shift; timeout="${1:-}" ;;
      *) die "spawn: unknown argument '$1'" ;;
    esac
    shift
  done
  case "$provider" in claude|codex) ;; *) die "spawn: provider must be claude or codex" ;; esac
  [ -n "$msg" ] || die "spawn: --message <file> is required"
  [ -f "$msg" ] || die "spawn: no such message file: $msg"
  msg="$(abs_path "$msg")"
  local root mid run_dir
  root="$("$COMMS" root)"
  mid="$(basename "$msg" .md)"
  # Pause contract: a hold marker blocks NEW turns at this boundary (in-flight
  # turns finish). The caller's send maps HELD to its own outcome.
  local msg_thread marker
  msg_thread="$(frontmatter_field "$msg" thread || true)"
  if marker="$(hold_active "$msg_thread")"; then
    echo "HELD: thread '${msg_thread:-<none>}' is paused ($marker) — no turn spawned"
    echo "  release with: \"$SELF\" release${msg_thread:+ $msg_thread}"
    print_attach "$msg_thread"
    return 0
  fi
  # Re-delivery guard: a bare `deliver codex` retry must not double-spawn a
  # concurrent turn for a message whose runner is still alive. (A dead runner
  # without a result is fair game — that is exactly what a retry is for.)
  local prior prior_pid
  for prior in "$root/logs/$(safe_name "$mid")".*; do
    [ -d "$prior" ] || continue
    [ -f "$prior/result.json" ] && continue
    prior_pid="$(cat "$prior/pid" 2>/dev/null || true)"
    if [ -n "$prior_pid" ] && kill -0 "$prior_pid" 2>/dev/null; then
      echo "already running: runphase pid=$prior_pid for this message"
      echo "  run dir: $prior"
      echo "  await:   \"$SELF\" await \"$prior\""
      return 0
    fi
  done
  # $$ suffix: same-second re-spawns must not clobber each other's records.
  run_dir="$root/logs/$(safe_name "$mid").$(date +%s).$$"
  mkdir -p "$run_dir" || die "spawn: cannot create run dir $run_dir"
  nohup "$SELF" run --message "$msg" --dir "$run_dir" --provider "$provider" \
    ${sandbox:+--sandbox "$sandbox"} ${timeout:+--timeout-secs "$timeout"} \
    </dev/null >>"$run_dir/runner.log" 2>&1 &
  local pid=$!
  printf '%s' "$pid" > "$run_dir/pid"
  echo "spawned runphase pid=$pid provider=$provider"
  echo "  run dir: $run_dir"
  echo "  events:  $run_dir/events.ndjson"
  echo "  await:   \"$SELF\" await \"$run_dir\""
}

# ---------- run (spawn's detached child) ----------

cmd_run() {
  local msg="" run_dir="" provider="codex" sandbox="${COMMS_RUNPHASE_SANDBOX:-workspace-write}"
  local timeout="${COMMS_RUNPHASE_TIMEOUT_SECS:-1800}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) shift; msg="${1:-}" ;;
      --dir) shift; run_dir="${1:-}" ;;
      --provider) shift; provider="${1:-}" ;;
      --sandbox) shift; sandbox="${1:-}" ;;
      --timeout-secs) shift; timeout="${1:-}" ;;
      *) die "run: unknown argument '$1'" ;;
    esac
    shift
  done
  case "$provider" in claude|codex) ;; *) die "run: provider must be claude or codex" ;; esac
  [ -n "$msg" ] && [ -f "$msg" ] || die "run: --message <file> required and must exist"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "run: --dir <run-dir> required and must exist"
  msg="$(abs_path "$msg")"
  RUN_PROVIDER="$provider"
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local sfield
  sfield="$(session_field_of "$provider")"

  # Capture the thread NOW: the child archives (moves) the message file as part
  # of its reply, so exit-time re-reads of $msg fail on the success path.
  local msg_thread
  msg_thread="$(frontmatter_field "$msg" thread || true)"

  # If anything below aborts unexpectedly (set -e, TERM/INT), reap the provider
  # child and still leave a result on disk so `await` reports a diagnosable
  # failure instead of hanging on a silent death.
  # State first, result.json last — everywhere. result.json is the signal
  # `await` unblocks on, so every other record must already be in place.
  codex_pid=""
  trap 'kill_codex; update_thread_state "$msg_thread" failed "" "$sfield" || true; write_result "$run_dir" failed "?" "" "$msg" "runner aborted unexpectedly — see runner.log"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  # The driver's `send` writes thread state moments after `deliver` spawns us;
  # an instantly-completing turn (stubs, trivial errors) would otherwise update
  # state BEFORE send's write and get clobbered back to "spawned".
  sleep "${COMMS_RUNPHASE_SPAWN_DELAY_SECS:-1}"

  local root main_root workdir msg_cwd
  root="$("$COMMS" root)"
  main_root="${root%/.comms}"
  msg_cwd="$(frontmatter_field "$msg" cwd)"
  if [ -n "$msg_cwd" ] && [ -d "$msg_cwd" ]; then
    workdir="$msg_cwd"
  else
    workdir="$main_root"
  fi

  # ----- prompt -----
  # Which discipline text the peer follows and where its reply goes, per provider.
  local peer instr_a instr_b instr_note self_desc peer_desc
  peer="$(peer_of "$provider")"
  if [ "$provider" = "codex" ]; then
    self_desc="Codex"; peer_desc="Claude Code"
    instr_a="$(skill_file read-from-claude "$main_root" || true)"
    instr_b="$(skill_file send-to-claude "$main_root" || true)"
  else
    self_desc="Claude Code"; peer_desc="Codex"
    instr_a="$(command_file read-from-codex.md "$main_root" || true)"
    instr_b="$(command_file send-to-codex.md "$main_root" || true)"
  fi
  # Instruction files usually live OUTSIDE the workspace (~/.claude/commands,
  # ~/.codex/skills) — grant the claude child Read access to their dirs, or the
  # boot prompt's "read these first" costs a permission-denial round-trip
  # (observed in the first live claude turn).
  local -a instr_dirs=()
  local d prev_d=""
  for d in "${instr_a:+$(dirname "$instr_a")}" "${instr_b:+$(dirname "$instr_b")}"; do
    # Plain if, not a `&&` chain: a false condition in the loop body must not
    # leak a non-zero status into set -e (the print_attach bug class).
    if [ -n "$d" ] && [ "$d" != "$prev_d" ]; then
      instr_dirs+=(--add-dir "$d")
      prev_d="$d"
    fi
  done
  if [ -n "$instr_a" ] && [ -n "$instr_b" ]; then
    instr_note="Read BOTH instruction files first and follow them for this message:
  $instr_a
  $instr_b"
  else
    instr_note="(instruction files not found — protocol summary: read the message, act on it per its
type, then reply with a frontmatter markdown message in the peer's .comms inbox — copy thread/
workflow/phase/round/max-rounds from the incoming message, add verdict: APPROVE or REQUEST_CHANGES
for workflow reviews from the reviewer side, use type: response with no verdict for questions.)"
  fi
  # Shell-quote the paths that appear inside the command the peer is told to
  # run — a message path is data, not code, even though our own send flow only
  # generates safe names.
  local msg_q comms_q
  msg_q="$(printf '%q' "$msg")"
  comms_q="$(printf '%q' "$COMMS")"
  cat > "$run_dir/prompt.md" <<PROMPT
You are $self_desc, operating HEADLESS in an agent-comms exchange. No human is watching
this session and no cmux panes are involved.

A message from $peer_desc is waiting for you at:
  $msg_q

$instr_note

Headless-mode adjustments (these OVERRIDE anything the instructions say about cmux,
panes, surfaces, or shell wrappers):
- Skip inbox listing; the target message file is the one given above.
- If the message frontmatter has a cwd: field, cd there before reading or changing files.
- Send your reply with:
    $comms_q send --to $peer "<your reply file>" --archive-inbound $msg_q
- The send will report RESULT: manual — that is EXPECTED in headless mode. The driving
  session picks your reply up when this turn ends. Do not retry delivery, do not look
  for cmux, and do not request escalation.
- If you rewrite your reply, delete the superseded draft file — exactly ONE reply may
  be left in the peer's inbox when you stop.
- Do not ask the user anything. Complete the task, send the reply, then stop.
PROMPT

  # ----- provider invocation -----
  local -a extra_dirs=()
  if [ "$workdir" != "$main_root" ]; then
    # Worktree turn: the mailbox and the worktree's git metadata live under the
    # main root, outside a write sandbox rooted at the worktree.
    extra_dirs=(--add-dir "$root" --add-dir "$main_root/.git")
  fi
  export COMMS_DELIVERY=headless          # the child's own sends stay headless
  # Replies TO the driver are picked up when this turn exits — the child's
  # deliver must no-op for that direction instead of spawning a counter-turn.
  export COMMS_HEADLESS_PICKUP="$peer"

  local -a cmd=() child_env=()
  case "$provider" in
    codex)
      cmd=(codex exec --json -s "$sandbox" -C "$workdir"
           ${extra_dirs[@]+"${extra_dirs[@]}"}
           -o "$run_dir/last-message.txt" -)
      ;;
    claude)
      # Loop-turn policy: no bypass/danger flags, ever (novel permission needs
      # surface as failed turns and get scoped policy additions instead).
      case " ${COMMS_RUNPHASE_CLAUDE_ARGS:-} ${COMMS_RUNPHASE_CLAUDE_PERMISSION_MODE:-} " in
        *dangerously-skip-permissions*|*bypassPermissions*)
          die "run: bypass/danger permission flags are refused in headless loop turns" ;;
      esac
      # stream-json requires --verbose in print mode. CLAUDECODE is unset so the
      # child doesn't detect itself as nested inside the driving session.
      child_env=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT)
      cmd=(claude -p --verbose --output-format stream-json
           --permission-mode "${COMMS_RUNPHASE_CLAUDE_PERMISSION_MODE:-acceptEdits}"
           --allowedTools "${COMMS_RUNPHASE_CLAUDE_ALLOWED_TOOLS:-Bash}"
           ${extra_dirs[@]+"${extra_dirs[@]}"}
           ${instr_dirs[@]+"${instr_dirs[@]}"})
      # Deliberate word-splitting of extra args (documented limitation: values
      # with embedded spaces are not supported). noglob so a stray * in the
      # args can't expand against the cwd.
      if [ -n "${COMMS_RUNPHASE_CLAUDE_ARGS:-}" ]; then
        set -f
        # shellcheck disable=SC2206
        cmd+=(${COMMS_RUNPHASE_CLAUDE_ARGS})
        set +f
      fi
      ;;
  esac

  local rc=0 deadline now
  # set -m: give the provider its own process group so a timeout/abort can reap
  # the WHOLE tree (CLI + the shell commands it spawns) with one group signal.
  set -m
  ( cd "$workdir" && exec ${child_env[@]+"${child_env[@]}"} "${cmd[@]}" ) \
    < "$run_dir/prompt.md" > "$run_dir/events.ndjson" 2>> "$run_dir/runner.log" &
  codex_pid=$!
  set +m
  deadline=$(( $(date +%s) + timeout ))
  while kill -0 "$codex_pid" 2>/dev/null; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      kill_codex
      wait "$codex_pid" 2>/dev/null || true
      local sid_t
      sid_t="$(session_id_from_events "$run_dir" "$provider")"
      update_thread_state "$msg_thread" timeout "$sid_t" "$sfield" || true
      write_result "$run_dir" timeout 124 "$sid_t" "$msg" "killed after ${timeout}s — raise COMMS_RUNPHASE_TIMEOUT_SECS or investigate events.ndjson"
      trap - EXIT
      exit 1
    fi
    sleep 1
  done
  wait "$codex_pid" || rc=$?

  local sid status note=""
  sid="$(session_id_from_events "$run_dir" "$provider")"
  if [ "$rc" -eq 0 ]; then
    status=completed
  else
    status=failed
    note="$provider CLI exited $rc — see events.ndjson and runner.log"
  fi
  update_thread_state "$msg_thread" "$status" "$sid" "$sfield" || true
  write_result "$run_dir" "$status" "$rc" "$sid" "$msg" "$note"
  trap - EXIT
  [ "$status" = completed ]
}

# kill_codex — reap the codex child and its whole process group (TERM, then
# KILL). Safe to call when nothing was spawned or it already exited.
kill_codex() {
  [ -n "${codex_pid:-}" ] || return 0
  kill -0 "$codex_pid" 2>/dev/null || return 0
  kill -TERM -- "-$codex_pid" 2>/dev/null || kill -TERM "$codex_pid" 2>/dev/null || true
  sleep 2
  kill -KILL -- "-$codex_pid" 2>/dev/null || kill -KILL "$codex_pid" 2>/dev/null || true
}

session_id_from_events() {  # session_id_from_events <run-dir> <provider>
  # codex emits thread.started with "thread_id"; claude's init event carries
  # "session_id". Keyed by provider so an incidental mention of the other key
  # in some event payload can't hijack the capture. || true: on a large event
  # log, head exiting after the first match can SIGPIPE sed under pipefail —
  # that must yield an empty id, not a set -e abort that records a successful
  # turn as failed.
  local key
  case "${2:-codex}" in claude) key=session_id ;; *) key=thread_id ;; esac
  { sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$1/events.ndjson" | head -1; } 2>/dev/null || true
}

# ---------- await / result ----------

cmd_await() {
  local run_dir="" timeout=7200
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout-secs) shift; timeout="${1:-}" ;;
      *) [ -z "$run_dir" ] && run_dir="$1" || die "await: unexpected argument '$1'" ;;
    esac
    shift
  done
  [ -n "$run_dir" ] || die "await: run-dir argument required"
  [ -d "$run_dir" ] || die "await: no such run dir: $run_dir"
  local deadline pid
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if [ -f "$run_dir/result.json" ]; then
      cat "$run_dir/result.json"
      [ "$(json_get "$run_dir/result.json" status)" = "completed" ] && return 0 || return 1
    fi
    if [ -f "$run_dir/pid" ]; then
      pid="$(cat "$run_dir/pid" 2>/dev/null || true)"
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        sleep 2   # grace: the EXIT trap may still be writing result.json
        [ -f "$run_dir/result.json" ] && continue
        echo "await: runner (pid $pid) died without writing result.json — see $run_dir/runner.log" >&2
        return 1
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "await: timed out after ${timeout}s — the turn may still be running (run dir: $run_dir)" >&2
      return 1
    fi
    sleep 2
  done
}

cmd_result() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] || die "result: run-dir argument required"
  [ -f "$run_dir/result.json" ] || die "result: no result.json in $run_dir (turn still running?)"
  cat "$run_dir/result.json"
}

case "${1:-}" in
  spawn)   shift; cmd_spawn "$@" ;;
  run)     shift; cmd_run "$@" ;;
  await)   shift; cmd_await "$@" ;;
  result)  shift; cmd_result "$@" ;;
  hold)    shift; cmd_hold "$@" ;;
  release) shift; cmd_release "$@" ;;
  ""|help|-h|--help)
    # Print the header comment block, robust to future header edits.
    awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"
    ;;
  *) die "unknown subcommand '${1}' — run 'runphase.sh help'" ;;
esac
