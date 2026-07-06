#!/bin/bash
# agent-comms headless peer-turn runner (v0: Codex only).
#
# Replaces the cmux keystroke nudge with a detached `codex exec` subprocess: the
# peer turn is spawned, observed (JSONL event log), resumed-or-failed (session id
# recorded), and recorded (result.json + thread state) — without typing into
# another terminal. Opt-in per call via COMMS_DELIVERY=headless (comms.sh
# deliver/send route here); cmux stays the default delivery path.
#
# Subcommands:
#   spawn --message <file> [--sandbox <mode>] [--timeout-secs N]
#         detach a `run` and return immediately; prints pid + run dir
#   run --message <file> --dir <run-dir> [--sandbox <mode>] [--timeout-secs N]
#         foreground runner (spawn's child): build the prompt, drive codex exec,
#         tee events, write result.json on every exit path, update thread state
#   await <run-dir> [--timeout-secs N]
#         block until result.json exists (or the runner dies); print it;
#         exit 0 only for status=completed
#   result <run-dir>
#         print result.json if present
#
# Env knobs: COMMS_RUNPHASE_SANDBOX (default workspace-write),
#            COMMS_RUNPHASE_TIMEOUT_SECS (default 1800),
#            COMMS_RUNPHASE_SPAWN_DELAY_SECS (default 1 — see run()).
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
json_get() { sed -n 's/.*"'"$2"'": "\([^"]*\)".*/\1/p' "$1" | head -1; }

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

# ---------- result.json (written on EVERY runner exit path) ----------

RESULT_WRITTEN=false
write_result() {  # write_result <run-dir> <status> <exit-code> <session-id> <message-file> <note>
  local dir="$1" status="$2" rc="$3" sid="$4" mf="$5" note="$6"
  [ "$RESULT_WRITTEN" = true ] && return 0
  printf '{\n  "provider": "codex",\n  "status": "%s",\n  "exit_code": "%s",\n  "session_id": "%s",\n  "message_file": "%s",\n  "run_dir": "%s",\n  "started_at": "%s",\n  "ended_at": "%s",\n  "note": "%s"\n}\n' \
    "$(json_escape "$status")" "$(json_escape "$rc")" "$(json_escape "$sid")" \
    "$(json_escape "$mf")" "$(json_escape "$dir")" \
    "$(json_escape "${STARTED_AT:-}")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(json_escape "$note")" \
    > "$dir/result.json.tmp" && mv "$dir/result.json.tmp" "$dir/result.json" \
    || echo "warning: could not write result.json in $dir" >&2
  RESULT_WRITTEN=true
}

# update_thread_state <thread> <status> <session-id> — mirror the turn outcome
# into .comms/state/<ws>_<thread>.json so `state list`/`stalled`/fleet see
# headless ground truth. Takes the thread VALUE, not the message file: the
# child archives (moves) the message before we exit, so re-reading it here
# would fail exactly on the success path. Advisory like all state writes:
# never fatal.
update_thread_state() {
  local thread="$1" status="$2" sid="$3"
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
  awk -v st="$status" -v sid="$sid" '
    /"codex_thread_id":/ { next }   # re-emitted next to last_delivery below
    /"last_delivery":/ {
      printf "  \"last_delivery\": \"%s\"", st
      if (sid != "") printf ",\n  \"codex_thread_id\": \"%s\"", sid
      printf "\n"
      next
    }
    { print }
  ' "$sf" > "$sf.tmp" 2>/dev/null && mv "$sf.tmp" "$sf" \
    || echo "warning: could not update thread state $sf" >&2
}

# ---------- spawn ----------

cmd_spawn() {
  local msg="" sandbox="" timeout=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) shift; msg="${1:-}" ;;
      --sandbox) shift; sandbox="${1:-}" ;;
      --timeout-secs) shift; timeout="${1:-}" ;;
      *) die "spawn: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$msg" ] || die "spawn: --message <file> is required"
  [ -f "$msg" ] || die "spawn: no such message file: $msg"
  msg="$(abs_path "$msg")"
  local root mid run_dir
  root="$("$COMMS" root)"
  mid="$(basename "$msg" .md)"
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
  nohup "$SELF" run --message "$msg" --dir "$run_dir" \
    ${sandbox:+--sandbox "$sandbox"} ${timeout:+--timeout-secs "$timeout"} \
    </dev/null >>"$run_dir/runner.log" 2>&1 &
  local pid=$!
  printf '%s' "$pid" > "$run_dir/pid"
  echo "spawned runphase pid=$pid provider=codex"
  echo "  run dir: $run_dir"
  echo "  events:  $run_dir/events.ndjson"
  echo "  await:   \"$SELF\" await \"$run_dir\""
}

# ---------- run (spawn's detached child) ----------

cmd_run() {
  local msg="" run_dir="" sandbox="${COMMS_RUNPHASE_SANDBOX:-workspace-write}"
  local timeout="${COMMS_RUNPHASE_TIMEOUT_SECS:-1800}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) shift; msg="${1:-}" ;;
      --dir) shift; run_dir="${1:-}" ;;
      --sandbox) shift; sandbox="${1:-}" ;;
      --timeout-secs) shift; timeout="${1:-}" ;;
      *) die "run: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$msg" ] && [ -f "$msg" ] || die "run: --message <file> required and must exist"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "run: --dir <run-dir> required and must exist"
  msg="$(abs_path "$msg")"
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Capture the thread NOW: the child archives (moves) the message file as part
  # of its reply, so exit-time re-reads of $msg fail on the success path.
  local msg_thread
  msg_thread="$(frontmatter_field "$msg" thread || true)"

  # If anything below aborts unexpectedly (set -e, TERM/INT), reap the codex
  # child and still leave a result on disk so `await` reports a diagnosable
  # failure instead of hanging on a silent death.
  # State first, result.json last — everywhere. result.json is the signal
  # `await` unblocks on, so every other record must already be in place.
  codex_pid=""
  trap 'kill_codex; update_thread_state "$msg_thread" failed "" || true; write_result "$run_dir" failed "?" "" "$msg" "runner aborted unexpectedly — see runner.log"' EXIT
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
  local read_skill send_skill skill_note
  read_skill="$(skill_file read-from-claude "$main_root" || true)"
  send_skill="$(skill_file send-to-claude "$main_root" || true)"
  if [ -n "$read_skill" ] && [ -n "$send_skill" ]; then
    skill_note="Read BOTH skill files first and follow them for this message:
  $read_skill
  $send_skill"
  else
    skill_note="(skill files not found — protocol summary: read the message, act on it per its type,
then reply with a frontmatter markdown message in .comms/to-claude/ — copy thread/workflow/phase/
round/max-rounds from the incoming message, add verdict: APPROVE or REQUEST_CHANGES for workflow
reviews, use type: response with no verdict for questions.)"
  fi
  # Shell-quote the paths that appear inside the command the peer is told to
  # run — a message path is data, not code, even though our own send flow only
  # generates safe names.
  local msg_q comms_q
  msg_q="$(printf '%q' "$msg")"
  comms_q="$(printf '%q' "$COMMS")"
  cat > "$run_dir/prompt.md" <<PROMPT
You are Codex, operating HEADLESS in an agent-comms exchange. No human is watching this
session and no cmux panes are involved.

A message from Claude Code is waiting for you at:
  $msg_q

$skill_note

Headless-mode adjustments (these OVERRIDE anything the skills say about cmux, panes,
surfaces, or shell wrappers):
- Skip inbox listing; the target message file is the one given above.
- If the message frontmatter has a cwd: field, cd there before reading or changing files.
- Send your reply with:
    $comms_q send --to claude "<your reply file>" --archive-inbound $msg_q
- The send will report RESULT: manual — that is EXPECTED in headless mode. The driving
  session picks your reply up when this turn ends. Do not retry delivery, do not look
  for cmux, and do not request escalation.
- Do not ask the user anything. Complete the task, send the reply, then stop.
PROMPT

  # ----- codex exec -----
  local -a extra_dirs=()
  if [ "$workdir" != "$main_root" ]; then
    # Worktree turn: the mailbox and the worktree's git metadata live under the
    # main root, outside a workspace-write sandbox rooted at the worktree.
    extra_dirs=(--add-dir "$root" --add-dir "$main_root/.git")
  fi
  export COMMS_DELIVERY=headless   # child's send --to claude must not touch cmux

  local rc=0 deadline now
  # set -m: give codex its own process group so a timeout/abort can reap the
  # WHOLE tree (codex + the shell commands it spawns) with one group signal.
  set -m
  ( cd "$workdir" && exec codex exec --json -s "$sandbox" -C "$workdir" \
      ${extra_dirs[@]+"${extra_dirs[@]}"} \
      -o "$run_dir/last-message.txt" - ) \
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
      sid_t="$(session_id_from_events "$run_dir")"
      update_thread_state "$msg_thread" timeout "$sid_t" || true
      write_result "$run_dir" timeout 124 "$sid_t" "$msg" "killed after ${timeout}s — raise COMMS_RUNPHASE_TIMEOUT_SECS or investigate events.ndjson"
      trap - EXIT
      exit 1
    fi
    sleep 1
  done
  wait "$codex_pid" || rc=$?

  local sid status note=""
  sid="$(session_id_from_events "$run_dir")"
  if [ "$rc" -eq 0 ]; then
    status=completed
  else
    status=failed
    note="codex exec exited $rc — see events.ndjson and runner.log"
  fi
  update_thread_state "$msg_thread" "$status" "$sid" || true
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

session_id_from_events() {  # best-effort thread id from the JSONL event log
  sed -n 's/.*"thread_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$1/events.ndjson" 2>/dev/null | head -1
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
  spawn)  shift; cmd_spawn "$@" ;;
  run)    shift; cmd_run "$@" ;;
  await)  shift; cmd_await "$@" ;;
  result) shift; cmd_result "$@" ;;
  ""|help|-h|--help)
    # Print the header comment block, robust to future header edits.
    awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"
    ;;
  *) die "unknown subcommand '${1}' — run 'runphase.sh help'" ;;
esac
