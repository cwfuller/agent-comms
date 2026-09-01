#!/bin/bash
# agent-comms ACP consult helper — synchronous /ask transport over acpx.
#
# A consult is synchronous by nature: the whole mailbox apparatus (write file,
# nudge, wait, read command) exists because pane delivery is asynchronous. This
# helper collapses `/ask --via acp` to one blocking call whose answer lands on
# stdout — no message file, no nudge, no late-nudge class. The mailbox path
# remains the default and the fallback; this transport is OPT-IN per call.
#
# Subcommands:
#   consult <agent> [--oneshot] [--file <path>] [question words...]
#       run the consult; prints the answer followed by acpx's token-usage
#       line. Warm by default: a named per-repo session (agent-comms-ask) so
#       follow-ups pay only the delta (measured 2026-08-20: cold one-shot
#       18,562 fresh input tokens vs warm round-2 146 — ~127x). --oneshot uses
#       a stateless exec.
#   doctor
#       report node/acpx availability and the supported agent map; exit 0 iff
#       consults can run here.
#   supports <agent>
#       exit 0 iff a consult can run here for that agent (machine-readable —
#       never parse doctor's prose).
#   launcher
#       the argv prefix that runs acpx here (honours ACPX_BIN; falls back to a
#       workspace npm cache when ~/.npm is unwritable). Other helpers ask, never guess.
#   profile <agent> | version
#       the acpx launch profile for an agent, and the pinned acpx version. Other
#       helpers ask for these instead of keeping a second copy of the map.
#
# Pinned: acpx is pre-1.0 with an evolving CLI — every invocation goes through
# npx -y acpx@$ACPX_VERSION (cached by npm after first use; no global install).
# Requires Node >= 22.13 (acpx's floor). Enabled agents: codex, claude. acpx
# 0.13.1 ships builtins for all three registered agents; grok maps to the
# `grok-build` profile (verified against `acpx --help`, 2026-08-25). Unsupported agents fail closed naming the fallback.
set -euo pipefail

ACPX_VERSION="0.13.1"
ACP_SESSION_NAME="agent-comms-ask"
NODE_MIN_MAJOR=22
NODE_MIN_MINOR=13

die() { echo "acp.sh: $*" >&2; exit 1; }
# Every failure names the fallback, uniformly — the template's contract is
# "do NOT retry the ACP path on the same failure; the mailbox always works".
FALLBACK="The mailbox path (/ask without --via acp) always works — switch to it; do not re-run the ACP call."
die_fb() { echo "acp.sh: $*" >&2; echo "acp.sh: $FALLBACK" >&2; exit 1; }

# HOW acpx is launched, in ONE place. Two escapes from `npx -y acpx@PIN`:
#   ACPX_BIN      — an already-installed binary (no npm at all)
#   npm_config_cache — npx failed with EPERM under ~/.npm/_cacache in a sandbox that
#                      denies the home cache, i.e. exactly the agent sandboxes we target.
#                      Fall back to a gitignored workspace cache instead of dying.
# (Field report from a codex session, 2026-08-26.)
acpx_prepare_cache() {
  [ -n "${npm_config_cache:-}" ] && return 0
  local home_cache="${HOME:-/nonexistent}/.npm"
  if [ -d "$home_cache" ] && [ -w "$home_cache" ]; then return 0; fi
  if [ ! -e "$home_cache" ] && [ -w "${HOME:-/nonexistent}" ]; then return 0; fi
  local root fallback
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fallback="$root/.comms/cache/npm"
  mkdir -p "$fallback" 2>/dev/null || return 0
  export npm_config_cache="$fallback"
  echo "note: ~/.npm is not writable — using $fallback for the acpx download cache" >&2
}

acpx_launcher() {  # prints the argv prefix that runs acpx
  if [ -n "${ACPX_BIN:-}" ]; then printf '%s' "$ACPX_BIN"; else printf 'npx -y acpx@%s' "$ACPX_VERSION"; fi
}

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v major minor
  v="$(node --version 2>/dev/null)"; v="${v#v}"
  major="${v%%.*}"
  minor="${v#*.}"; minor="${minor%%.*}"
  # REJECT EMPTY EXPLICITLY. `*[!0-9]*` does not match the empty string, so a node that prints
  # nothing (absent, broken, or a harness stub) fell through to `[ "" -gt N ]`, which returns
  # nonzero only by way of an "integer expression expected" diagnostic. The verdict was right and
  # the noise was suppressed by the caller, but relying on a numeric-comparison ERROR to mean
  # "unsupported" is not a predicate. (codex, capability-registry r1, advisory.)
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  case "$major$minor" in *[!0-9]*) return 1 ;; esac
  [ "$major" -gt "$NODE_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$NODE_MIN_MAJOR" ] && [ "$minor" -ge "$NODE_MIN_MINOR" ]
}

require_node() {
  node_ok || die_fb "ACP consults need Node >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR} (found: $(node --version 2>/dev/null || echo none))."
}

profile_for() {  # acpx built-in launch profile per agent; empty = unsupported
  case "$1" in
    codex)  echo codex ;;
    claude) echo claude ;;
    grok)   echo grok-build ;;
    *)      echo "" ;;
  esac
}

cmd_doctor() {
  local a p
  if node_ok; then
    echo "node: $(node --version) (>= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR})"
  else
    echo "node: MISSING or too old ($(node --version 2>/dev/null || echo none)) — consults unavailable"
    exit 3
  fi
  echo "acpx: pinned @$ACPX_VERSION via npx (cached after first use)"
  echo "agents: codex claude grok enabled ($(for a in codex claude grok; do printf '%s=%s ' "$a" "$(profile_for "$a")"; done))"
}

cmd_consult() {
  local agent="${1:-}"; shift || true
  [ -n "$agent" ] || die_fb "consult: agent argument required (codex or claude)"
  local oneshot=false qfile="" words=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --oneshot) oneshot=true ;;
      --file)
        # Guard BEFORE shifting: a trailing --file must die with a diagnostic,
        # not let set -e kill the parse silently on an over-shift.
        [ "$#" -ge 2 ] || die_fb "consult: --file requires a path"
        shift; qfile="$1"
        [ -n "$qfile" ] || die_fb "consult: --file requires a non-empty path"
        ;;
      *) words+=("$1") ;;
    esac
    shift
  done
  local profile
  profile="$(profile_for "$agent")"
  [ -n "$profile" ] || die_fb "consult: '$agent' has no ACP profile — use the mailbox path"
  require_node
  [ -n "$qfile" ] && [ ! -f "$qfile" ] && die_fb "consult: no such file: $qfile"
  [ -n "$qfile" ] || [ "${#words[@]}" -gt 0 ] || die_fb "consult: a question is required (words or --file)"
  # Warm by default: ensure the named per-repo session once, then prompt it.
  # Session identity is (agent, cwd, name) on acpx's side — nothing to store here.
  # A consult that cannot READ is useless: the whole value is that the agent grounds
  # its answer in the tree instead of recalling. Without these, acpx denies the
  # permission request and the turn dies mid-answer — observed live during a
  # reciprocal-adjudication run. Writes stay denied; prompting is impossible here.
  acpx_prepare_cache
  # shellcheck disable=SC2206
  local -a launcher=($(acpx_launcher))
  # A consult that HANGS must not block forever, and a consult that returns rc=0 with ZERO bytes
  # must not read as a successful answer — the same rc-0-empty misdiagnosis the runphase path
  # already refuses (a dropped turn, an empty model reply). Pin an acpx `--timeout` (its exit 3 is
  # caught below) and CAPTURE the answer so it can be inspected before it is trusted. A malformed
  # budget falls back to the default rather than taking the turn down, matching the runphase rule.
  # (docs/ROADMAP.md, "Found in the field, not yet fixed".)
  local consult_timeout="${COMMS_ACP_CONSULT_TIMEOUT_SECS:-300}"
  # Sanitize like runphase's sane_secs, WITHOUT arithmetic: bash math WRAPS oversized integers, so
  # `$((10#$v))` would turn a huge digit string into an unrelated positive timeout and 2^64 into 0.
  # Reject non-digits, strip leading zeros as TEXT (so `08` -> `8`, `000` -> `0`), then reject zero
  # or an excessive digit count. The value handed to acpx is thus a bounded positive integer. (codex, r2.)
  case "$consult_timeout" in
    ''|*[!0-9]*) consult_timeout=300 ;;
    *) consult_timeout="${consult_timeout#"${consult_timeout%%[!0]*}"}"; consult_timeout="${consult_timeout:-0}"
       if [ "${#consult_timeout}" -gt 6 ] || [ "$consult_timeout" = 0 ]; then consult_timeout=300; fi ;;
  esac
  local -a base=("${launcher[@]}" --format quiet --timeout "$consult_timeout"
                 --approve-reads --non-interactive-permissions deny "$profile")
  local rc=0 out=""
  if [ "$oneshot" = true ]; then
    if [ -n "$qfile" ]; then
      out="$("${base[@]}" exec --file "$qfile" ${words[@]+"${words[@]}"})" || rc=$?
    else
      out="$("${base[@]}" exec "${words[@]}")" || rc=$?
    fi
  else
    # The ensure runs FIRST on every warm consult, so it needs the same --timeout: a stalled
    # ensure would otherwise hang /ask --via acp forever, the very failure this fix closes.
    # (codex, r1, blocking.) Only its STDOUT is captured — stderr stays live, so npx/acpx warnings
    # on a SUCCESSFUL ensure are not swallowed — and on a FAILING ensure a non-whitespace stdout
    # diagnostic is surfaced rather than dropped (a success prints only the session id, which stays
    # hidden). The `if` (not `A || { B; }`) avoids a set -e footgun when the diagnostic is empty.
    # (codex + grok, r2/r3, advisory.)
    local ens_out=""
    ens_out="$("${launcher[@]}" --timeout "$consult_timeout" "$profile" sessions ensure --name "$ACP_SESSION_NAME")" || rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$(printf '%s' "$ens_out" | tr -d '[:space:]')" ]; then printf '%s\n' "$ens_out"; fi
    if [ "$rc" -eq 0 ]; then
      if [ -n "$qfile" ]; then
        out="$("${base[@]}" -s "$ACP_SESSION_NAME" --file "$qfile" ${words[@]+"${words[@]}"})" || rc=$?
      else
        out="$("${base[@]}" -s "$ACP_SESSION_NAME" "${words[@]}")" || rc=$?
      fi
    fi
  fi
  # Emit whatever acpx produced, so a NON-ZERO exit's diagnostics are actually visible — the error
  # branches below say "see output above", which was false while stdout was captured and dropped.
  # On success this re-emits the answer (buffered, as the runphase path buffers its reply). Only a
  # non-whitespace body is emitted, so a whitespace-only reply is not printed before the rc-0 guard
  # refuses it. (both, r1; whitespace refinement codex, r2.)
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] && printf '%s\n' "$out"
  # acpx's exit codes are a stable scripting contract — translate, don't mask.
  # Every nonzero path carries the same fallback line and NO retry advice.
  case "$rc" in
    0)   # SILENT-SUCCESS GUARD: rc 0 with a blank body is not an answer — refuse it with the
         # fallback rather than hand the caller zero bytes as success (nothing was emitted above
         # when $out is blank).
         if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
           die_fb "consult: acpx exited 0 but returned no answer (a dropped or empty turn)"
         fi
         return 0 ;;
    2)   die_fb "consult: acpx usage error (exit 2) — likely an acp.sh bug; report it" ;;
    3)   die_fb "consult: timed out (exit 3)" ;;
    4)   die_fb "consult: no session (exit 4) despite 'sessions ensure'" ;;
    5)   die_fb "consult: every permission request was denied (exit 5) — the agent could not read what it needed" ;;
    130) die_fb "consult: interrupted (exit 130)" ;;
    *)   die_fb "consult: acpx failed (exit $rc) — see output above" ;;
  esac
}

case "${1:-}" in
  consult) shift; cmd_consult "$@" ;;
  doctor)  shift; cmd_doctor "$@" ;;
  profile)
    # profile <agent> — the acpx launch profile, or empty. Single source of truth:
    # runphase asks rather than keeping a second copy of the map.
    shift
    [ -n "${1:-}" ] || die "profile: an agent name is required"
    printf '%s\n' "$(profile_for "$1")"
    ;;
  version) printf '%s\n' "$ACPX_VERSION" ;;
  launcher) acpx_prepare_cache; acpx_launcher; printf '\n' ;;
  supports)
    # supports <agent> — exit 0 iff a consult can actually run here for that
    # agent. Machine-readable on purpose: callers must never parse doctor's prose.
    shift
    [ -n "${1:-}" ] || die "supports: an agent name is required"
    [ -n "$(profile_for "$1")" ] || exit 1
    node_ok || exit 1
    ;;
  ""|help|-h|--help)
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
    ;;
  *) die "unknown subcommand '${1}' — run 'acp.sh help'" ;;
esac
