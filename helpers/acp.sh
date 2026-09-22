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
#   resolve <agent> [--transport acp-mounted|acp|headless] [--tier fast|balanced|strong|none]
#           [--effort low|medium|high|xhigh|none] [--decision <id>|none] [--routing on|off]
#       resolve an ABSTRACT routing candidate to the concrete reviewer policy
#       for one turn, through the versioned policy-map.tsv beside this file.
#       Prints the policy record (key<TAB>value lines) the caller persists and
#       hands back via --policy-file. Precedence per dimension: operator pin
#       (COMMS_ACP_CODEX_MODEL / COMMS_ACP_CODEX_EFFORT) > the operator's "use max"
#       ceiling (COMMS_REVIEW_MAX=1) > an eligible, enabled routed candidate > the
#       map's baseline. Exit 0 resolved (including an
#       `unsupported` provider/transport), 1 refused (invalid pair, bad map),
#       2 usage.
#   capabilities
#       the map version and every provider/transport capability row, with the
#       concrete controls of each routing-eligible combination.
#   runtime <agent> --policy-file <record>
#       the codex binary the record resolved (`bundled`, or an absolute path) —
#       see policy_runtime_codex for COMMS_ACP_CODEX_PATH and auto-detection.
#   policy <agent> [--policy-file <record>]
#       the reviewer model+effort policy for an agent, tab-separated
#       (<model>\t<effort>); empty + exit 1 where no policy applies.
#   provider-config <agent> [--policy-file <record>]
#       the COMPLETE isolated provider config file text for a mounted review
#       turn. runphase asks for this rather than holding a literal, so the
#       policy is spelled exactly once.
#   policy-check <agent> - [--policy-file <record>]
#   policy-attest <agent> <effort> [model] [--policy-file <record>]
#       compare an `acpx sessions show --format json` record on stdin, or an
#       observed effort/model pair, against the policy. Exit 0 match,
#       20 mismatch, 21 undecidable. Undecidable is never "it matched".
#   With --policy-file every accessor reads the PERSISTED per-turn record and
#   never re-resolves, so a pin, map or install changed mid-turn cannot make the
#   config, the preflight and the attestation describe different policies.
#   Without it they resolve the baseline plus pins (routing off), as before.
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

# THE REVIEWER MODEL+EFFORT POLICY. Declared HERE, never inherited: the isolated CODEX_HOME
# exists precisely so the operator's ~/.codex/config.toml does NOT reach a review turn, and a
# reviewer whose depth silently tracks the provider's default is not a reviewable gate. Measured
# 2026-09-19: mounted turns ran the model DEFAULT effort (sol->low, astra->medium) from isolation
# commit 21cb780 (2026-08-29) onward, while unmounted /ask turns kept the operator's xhigh — 280
# acpx session records, boundary exact to the day.
#
# EFFORT is the contract. The MODEL is an env-overridable default: a retired id must surface as a
# refused turn, not a silent float to whatever the account now serves. (grok, plan r1/r3.)
#
# THE CONCRETE VALUES LIVE IN policy-map.tsv beside this file, and nowhere else: the baseline
# (gpt-6-astra/xhigh as of map 2026-09-22.1), the tier->model and effort->value rows a routed
# decision may select, and the efforts each model accepts. The operator's pins stay environment
# variables (COMMS_ACP_CODEX_MODEL / COMMS_ACP_CODEX_EFFORT) and still win over everything. The
# map is read ONLY from the sibling file, never from an environment override, so a second table
# cannot appear beside the one the ledger names.
ACP_POLICY_MAP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/policy-map.tsv"
ACP_POLICY_RECORD_VERSION=1

# Values reach a TOML file that governs the reviewer's sandbox, so they are ALLOWLISTED, never
# scrubbed of known-bad characters: docs/advisories.md:363 records that neutralising by
# enumeration "is the shape that has failed" in this codebase. A value carrying a quote or a
# newline could otherwise append `sandbox_mode = "danger-full-access"` to a reviewer's config.
ACP_POLICY_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

die() { echo "acp.sh: $*" >&2; exit 1; }
# The comms.sh installed beside this script — the home of the reply-body predicates this
# helper shares with runphase. Absent means undecidable (exit 3), reported by the caller.
comms_sibling() {
  local c; c="$(dirname "${BASH_SOURCE[0]}")/comms.sh"
  [ -x "$c" ] || { echo "acp.sh: no comms.sh beside $(basename "${BASH_SOURCE[0]}")" >&2; return 3; }
  "$c" "$@"
}
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

# ---------------------------------------------------------------------------------------------
# THE POLICY MAP. Validated WHOLE before any value is used: a malformed row anywhere refuses every
# lookup, rather than letting the rows a particular question happens to touch decide whether a
# broken table is noticed. Bash 3.2 has no associative arrays, so the table stays in the file and
# each lookup is one awk pass over it (a few dozen rows).
policy_map_check() {  # -> the map version on stdout; exit 1 with a diagnostic on any defect
  [ -f "$ACP_POLICY_MAP" ] && [ -r "$ACP_POLICY_MAP" ] \
    || { echo "acp.sh: the policy map is missing or unreadable ($ACP_POLICY_MAP) — re-run install.sh" >&2; return 1; }
  awk -F'\t' -v re="$ACP_POLICY_RE" '
    function bad(msg) { printf "acp.sh: policy map line %d: %s\n", NR, msg > "/dev/stderr"; err = 1 }
    function tok(v) { return v ~ /^[a-z][a-z0-9-]*$/ }
    function once(k) { if (k in seen) bad("duplicate row"); seen[k] = 1 }
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    $1 == "version" { if (NF != 2 || $2 !~ re) bad("malformed version"); nv++; ver = $2; next }
    $1 == "capability" {
      if (NF != 8 || !tok($2) || !tok($3) || $4 !~ /^(eligible|fixed|unsupported)$/) bad("malformed capability")
      once("c" SUBSEP $2 SUBSEP $3); next }
    $1 == "baseline" || $1 == "ceiling" {
      if (NF != 5 || !tok($2) || !tok($3) || $4 !~ re || $5 !~ re) bad("malformed " $1)
      once($1 SUBSEP $2 SUBSEP $3); next }
    $1 == "tier" {
      if (NF != 5 || !tok($2) || !tok($3) || $4 !~ /^(fast|balanced|strong)$/ || $5 == "") bad("malformed tier")
      n = split($5, a, ","); for (i = 1; i <= n; i++) if (a[i] !~ re) bad("malformed tier model")
      once("t" SUBSEP $2 SUBSEP $3 SUBSEP $4); next }
    $1 == "effort" {
      if (NF != 5 || !tok($2) || !tok($3) || $4 !~ /^(low|medium|high|xhigh)$/ || $5 !~ re) bad("malformed effort")
      once("e" SUBSEP $2 SUBSEP $3 SUBSEP $4); next }
    $1 == "pair" {
      if ((NF != 5 && NF != 6) || !tok($2) || !tok($3) || $4 !~ re || $5 == "") bad("malformed pair")
      if (NF == 6 && $6 !~ /^[0-9]+(\.[0-9]+)*$/) bad("malformed pair minimum runtime")
      n = split($5, a, ","); for (i = 1; i <= n; i++) if (a[i] !~ re) bad("malformed pair effort")
      once("p" SUBSEP $2 SUBSEP $3 SUBSEP $4); next }
    { bad("unknown row kind \"" $1 "\"") }
    END {
      if (nv != 1) { printf "acp.sh: policy map: expected exactly one version row, found %d\n", nv > "/dev/stderr"; err = 1 }
      if (err) exit 1
      print ver
    }' "$ACP_POLICY_MAP"
}
# policy_map_get <kind> <provider> <transport> [key] — the value column(s) of ONE row, or nothing.
#   capability -> <eligible|fixed|unsupported>   baseline -> <model>\t<effort>
#   tier <t> -> <model>   effort <e> -> <provider-effort>   pair <model> -> <comma list>
#   ceiling -> <model>\t<effort>
# Only ever called after policy_map_check has passed for this invocation.
policy_map_get() {
  awk -F'\t' -v k="$1" -v p="$2" -v t="$3" -v key="${4:-}" '
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    ($1 != k && !(k == "pairmin" && $1 == "pair")) || $2 != p || $3 != t { next }
    k == "capability" { print $4; exit }
    k == "baseline" || k == "ceiling" { print $4 "\t" $5; exit }
    k == "pairmin" && $4 == key { print (NF == 6 ? $6 : ""); exit }
    $4 == key         { print $5; exit }' "$ACP_POLICY_MAP"
}
# policy_map_reverse <kind> <provider> <transport> <value> — the abstract label whose row maps to
# <value> (tier: model -> fast|balanced|strong; effort: provider value -> low..xhigh), or `unmapped`.
policy_map_reverse() {
  local r
  r="$(awk -F'\t' -v k="$1" -v p="$2" -v t="$3" -v v="$4" '
    { sub(/\r$/, "") }
    $1 == k && $2 == p && $3 == t { n = split($5, a, ","); for (i = 1; i <= n; i++) if (a[i] == v) { print $4; exit } }' "$ACP_POLICY_MAP")"
  printf '%s\n' "${r:-unmapped}"
}

# THE COMBINATIONS WITH AN APPLY-AND-ATTEST PATH IN CODE. The map may only mark these `eligible` or
# `fixed`; any other row claiming either is downgraded to `unsupported` (fallback
# capability-unimplemented), so a map edit alone can never make the ledger claim a policy that no
# code applies or checks. Adding a provider here requires its runphase arm to write the config,
# preflight it and attest it. (code review r1.)
policy_applied_combo() { case "$1/$2" in codex/acp-mounted) return 0 ;; esac; return 1; }

# ver_ge <a> <b> — dotted numeric version a >= b. A non-numeric side is "not known to be >=".
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    if (a !~ /^[0-9]+(\.[0-9]+)*$/ || b !~ /^[0-9]+(\.[0-9]+)*$/) exit 1
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) { xi = (i <= na ? x[i] + 0 : 0); yi = (i <= nb ? y[i] + 0 : 0)
      if (xi > yi) exit 0; if (xi < yi) exit 1 }
    exit 0 }'
}

# THE CODEX RUNTIME a mounted reviewer will run. The ACP adapter ships its OWN codex and uses it
# unless CODEX_PATH names another; that bundled copy can lag the operator's installed CLI by
# releases, and new models are served only to new enough clients (measured 2026-09-22: bundled
# 0.154.0 is refused gpt-6-luna for a ChatGPT-auth account; the installed 0.155.1 serves it).
#   COMMS_ACP_CODEX_PATH=bundled   use the adapter's bundled codex (version unknown to us)
#   COMMS_ACP_CODEX_PATH=<path>    use that binary
#   unset                          the operator's installed codex, found on PATH (skipping
#                                  per-session wrapper shims), else the bundled one
# Sets RT_PATH (absolute path, or `bundled`) and RT_VERSION (x.y.z, or `unknown`). Never fails:
# an unusable explicit path is REFUSED by resolve, not silently swapped for another runtime.
ACP_RUNTIME_PATH_RE='^/[A-Za-z0-9._/+@-]+$'
policy_runtime_codex() {
  local want="${COMMS_ACP_CODEX_PATH:-}" d cand="" v
  RT_PATH=bundled; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""
  if [ "$want" = bundled ]; then return 0; fi
  if [ -n "$want" ]; then
    if ! [[ "$want" =~ $ACP_RUNTIME_PATH_RE ]] || [ ! -x "$want" ] || [ -d "$want" ]; then
      RT_ERR="COMMS_ACP_CODEX_PATH '$want' is not an executable absolute path"; return 0
    fi
    cand="$want"
  else
    local IFS=:
    for d in ${PATH:-}; do
      case "$d" in ""|*cmux-cli-shims*|*/.asdf/shims|*/node_modules/.bin) continue ;; esac
      if [ -x "$d/codex" ] && [ ! -d "$d/codex" ] && [[ "$d/codex" =~ $ACP_RUNTIME_PATH_RE ]]; then cand="$d/codex"; break; fi
    done
    [ -n "$cand" ] || return 0
  fi
  # BOUNDED. This runs on EVERY codex resolution — baseline turns included — before the canary and
  # before the turn budget starts, while the runner holds its mount claim, so a CLI or wrapper that
  # hangs on --version would stall reviews with nothing to stop it. The probe runs in its own
  # process group and the whole group is killed at the deadline. (codex, implement r1.)
  v="$(runtime_version_probe "$cand")" || v=""
  if [ -z "$v" ]; then
    if [ -n "$want" ]; then RT_ERR="COMMS_ACP_CODEX_PATH '$want' did not report a version within ${ACP_RUNTIME_PROBE_SECS}s"; return 0; fi
    RT_NOTE="runtime-probe-failed"   # an auto-found binary that will not say what it is: stay bundled
    return 0
  fi
  RT_PATH="$cand"; RT_VERSION="$v"
}

# runtime_version_probe <binary> — its dotted version from `--version`, within
# COMMS_ACP_RUNTIME_PROBE_SECS (default 5), or nothing. python3 owns the deadline because it can
# kill the probe's whole process group; without python3 the probe is not attempted (auto-detection
# then stays bundled, and an explicit path is refused as unverifiable).
ACP_RUNTIME_PROBE_SECS="${COMMS_ACP_RUNTIME_PROBE_SECS:-5}"
case "$ACP_RUNTIME_PROBE_SECS" in ''|*[!0-9]*|0) ACP_RUNTIME_PROBE_SECS=5 ;; esac
[ "${#ACP_RUNTIME_PROBE_SECS}" -le 3 ] || ACP_RUNTIME_PROBE_SECS=5
runtime_version_probe() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$ACP_RUNTIME_PROBE_SECS" <<'RTPY' 2>/dev/null
import os,re,signal,subprocess,sys
exe,secs=sys.argv[1],int(sys.argv[2])
try:
    p=subprocess.Popen([exe,"--version"],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                       stdin=subprocess.DEVNULL,start_new_session=True)
except OSError:
    sys.exit(1)
try:
    out,_=p.communicate(timeout=secs)
except subprocess.TimeoutExpired:
    try: os.killpg(p.pid,signal.SIGKILL)
    except OSError: pass
    try: p.communicate(timeout=2)
    except Exception: pass
    sys.exit(1)
m=re.search(rb"(?<![0-9.])([0-9]+\.[0-9]+(?:\.[0-9]+)*)", out or b"")
if p.returncode!=0 or not m: sys.exit(1)
print(m.group(1).decode())
RTPY
}

# policy_model_available <agent> <transport> <model> — 0 iff the model's declared minimum runtime
# (optional 6th column of its `pair` row) is met by RT_VERSION. No minimum = available everywhere.
policy_model_available() {
  local min; min="$(policy_map_get pairmin "$1" "$2" "$3")"
  [ -z "$min" ] && return 0
  ver_ge "$RT_VERSION" "$min"
}

# The operator's pins, per provider. Only codex has an applied policy, so only codex has pins; a
# provider added here must also gain an `eligible` capability row with its own evidence.
policy_pin_model()  { case "$1" in codex) printf '%s' "${COMMS_ACP_CODEX_MODEL:-}" ;; esac; }
policy_pin_effort() { case "$1" in codex) printf '%s' "${COMMS_ACP_CODEX_EFFORT:-}" ;; esac; }
# THE OPERATOR'S "use max": every reviewer turn that applies a policy runs the map's `ceiling` pair.
# Provider-neutral on purpose — it names no model, the map does. It only ever RAISES depth, so it is
# not an author-steering channel the way a cheaper route would be.
policy_max_on() { case "${COMMS_REVIEW_MAX:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; esac; return 1; }

# resolve_policy <agent> <transport> <tier> <effort> <decision> <routing> <phase> <candidate-source>
# Sets the R_* globals describing the resolved policy. Returns 0 resolved, 1 refused (a message is
# on stderr). NEVER prints the record — emit_policy_record does that — so every caller shares one
# resolution and cannot drift into its own copy of the precedence rules.
#   capability eligible     pin > enabled route > baseline, then the pair is validated
#   capability fixed        the baseline (+ pins) is applied and attested; routing is ignored
#   capability unsupported  nothing is applied, so nothing is claimed (verify none)
# Only phase `implement` is routed: an approach review keeps the baseline, so changing reviewer
# depth can never change what the plan phase is judged by.
resolve_policy() {
  local agent="$1" transport="$2" tier="$3" effort="$4" decision="$5" routing="$6"
  local phase="${7:--}" csrc="${8:-none}"
  local base bm be pm pe accepted fb="" route_ok=0
  R_AGENT="$agent"; R_TRANSPORT="$transport"; R_TIER="$tier"; R_EFFORT_IN="$effort"
  R_DECISION="$decision"; R_ROUTING="$routing"; R_PHASE="$phase"; R_CSRC="$csrc"; R_DIGEST=none
  R_MAPV="$(policy_map_check)" || return 1
  R_CAP="$(policy_map_get capability "$agent" "$transport")"; R_CAP="${R_CAP:-unsupported}"
  if [ "$R_CAP" != unsupported ] && ! policy_applied_combo "$agent" "$transport"; then
    R_CAP=unsupported; fb="${fb:+$fb;}capability-unimplemented"
  fi
  R_RUNTIME=n/a; R_RUNTIME_VERSION=n/a
  if [ "$routing" = on ] && [ "$decision" = none ]; then fb="${fb:+$fb;}no-decision"; fi
  if [ "$routing" = off ] && [ "$decision" != none ]; then fb="${fb:+$fb;}routing-disabled"; fi
  if [ "$R_CAP" = unsupported ]; then
    # NOTHING IS APPLIED, so nothing may be claimed. The record says so in every field that would
    # otherwise look like a policy: no model, no effort, no verification requirement.
    R_MODEL=n/a; R_EFFORT=n/a; R_MSRC=unsupported; R_ESRC=unsupported
    R_ETIER=n/a; R_EEFF=n/a; R_PAIR=n/a; R_VERIFY=none
    policy_max_on && fb="${fb:+$fb;}max-unsupported"
    R_FALLBACK="${fb:+$fb;}capability-unsupported"
    return 0
  fi
  # THE RUNTIME, resolved before any model is chosen: which models exist depends on it.
  RT_PATH=bundled; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""
  if [ "$agent" = codex ]; then policy_runtime_codex; fi
  [ -z "$RT_ERR" ] || { echo "acp.sh: resolve: $RT_ERR — refusing rather than running another runtime" >&2; return 1; }
  [ -z "$RT_NOTE" ] || fb="${fb:+$fb;}$RT_NOTE"
  R_RUNTIME="$RT_PATH"; R_RUNTIME_VERSION="$RT_VERSION"
  base="$(policy_map_get baseline "$agent" "$transport")"
  [ -n "$base" ] || { echo "acp.sh: resolve: the map has no baseline for $agent/$transport — refusing" >&2; return 1; }
  bm="${base%%$'\t'*}"; be="${base#*$'\t'}"
  pm="$(policy_pin_model "$agent")"; pe="$(policy_pin_effort "$agent")"
  # VALIDATE AT THE ACCESSOR. Every consumer goes through here, so a second caller cannot reach
  # the interpolation with an unvalidated value.
  if [ -n "$pm" ] && ! [[ "$pm" =~ $ACP_POLICY_RE ]]; then
    echo "acp.sh: policy: model '$pm' is not a bare identifier — refusing to interpolate it into the reviewer's isolated config" >&2; return 1
  fi
  if [ -n "$pe" ] && ! [[ "$pe" =~ $ACP_POLICY_RE ]]; then
    echo "acp.sh: policy: effort '$pe' is not a bare identifier — refusing to interpolate it into the reviewer's isolated config" >&2; return 1
  fi
  if [ "$routing" = on ] && [ "$decision" != none ]; then
    if [ "$R_CAP" != eligible ]; then fb="${fb:+$fb;}capability-$R_CAP"
    elif [ "$phase" != implement ]; then fb="${fb:+$fb;}phase-excluded"
    else route_ok=1; fi
  fi
  # "use max" outranks routing, the baseline and the phase exclusion; only an explicit per-
  # dimension pin outranks it. It is strict like an explicit decision: an invalid pair refuses.
  local cm="" ce="" max_on=0
  if policy_max_on; then
    local ceil; ceil="$(policy_map_get ceiling "$agent" "$transport")"
    [ -n "$ceil" ] || { echo "acp.sh: resolve: COMMS_REVIEW_MAX is set but the map has no ceiling for $agent/$transport — refusing" >&2; return 1; }
    cm="${ceil%%$'\t'*}"; ce="${ceil#*$'\t'}"; max_on=1
    if [ "$route_ok" = 1 ]; then fb="${fb:+$fb;}max-override"; fi
    route_ok=0; csrc=explicit
  fi
  # EXPLICIT IS STRICT. An operator who named a tier or effort asked for THAT; a candidate the map
  # cannot honour is refused and named, never quietly replaced by the baseline. (handoff item 7.)
  explicit_refuse() {
    echo "acp.sh: resolve: the explicit decision $decision asks for $1 — refusing rather than substituting (map $R_MAPV)" >&2
  }
  # PRECEDENCE, PER DIMENSION: pin > eligible+enabled route > baseline. A missing or `none`
  # candidate keeps the concrete baseline; it is never passed on as an abstract default.
  local re=""
  if [ -n "$pm" ]; then R_MODEL="$pm"; R_MSRC=pin
  elif [ "$max_on" = 1 ]; then R_MODEL="$cm"; R_MSRC=max
  elif [ "$route_ok" = 1 ] && [ "$tier" != none ]; then
    # A tier is an ORDERED preference list: the first model this runtime can serve. A skipped
    # preference is recorded, so "fast ran gpt-5.6-luna because the runtime lacks gpt-6-luna" is
    # legible from the ledger. An empty result falls back like an unmapped tier.
    local tl m1 _om rm=""
    tl="$(policy_map_get tier "$agent" "$transport" "$tier")"
    local IFS_SAVE="$IFS"; IFS=,
    for m1 in $tl; do
      if policy_model_available "$agent" "$transport" "$m1"; then rm="$m1"; break; fi
      fb="${fb:+$fb;}runtime-lacks:$m1"
    done
    IFS="$IFS_SAVE"
    if [ -n "$rm" ]; then R_MODEL="$rm"; R_MSRC=route
    elif [ "$csrc" = explicit ]; then explicit_refuse "tier '$tier', which the map does not define for $agent/$transport"; return 1
    else R_MODEL="$bm"; R_MSRC=baseline; fb="${fb:+$fb;}unmapped-tier"; fi
  else
    R_MODEL="$bm"; R_MSRC=baseline
    if [ "$route_ok" = 1 ]; then fb="${fb:+$fb;}no-candidate-tier"; fi
  fi
  if [ -n "$pe" ]; then R_EFFORT="$pe"; R_ESRC=pin
  elif [ "$max_on" = 1 ]; then R_EFFORT="$ce"; R_ESRC=max
  elif [ "$route_ok" = 1 ] && [ "$effort" != none ]; then
    re="$(policy_map_get effort "$agent" "$transport" "$effort")"
    if [ -n "$re" ]; then R_EFFORT="$re"; R_ESRC=route
    elif [ "$csrc" = explicit ]; then explicit_refuse "effort '$effort', which the map does not define for $agent/$transport"; return 1
    else R_EFFORT="$be"; R_ESRC=baseline; fb="${fb:+$fb;}unmapped-effort"; fi
  else
    R_EFFORT="$be"; R_ESRC=baseline
    if [ "$route_ok" = 1 ]; then fb="${fb:+$fb;}no-candidate-effort"; fi
  fi
  # THE PAIR IS VALIDATED, not each value alone: a model and an effort that are each fine can still
  # be a combination the provider rejects or silently rewrites. A routed dimension that produces an
  # invalid (or unverifiable) pair falls back to the baseline ONCE, recorded; a pin that does is
  # REFUSED, never substituted — the operator asked for that value, and running something else is
  # the silent float this policy exists to prevent.
  local attempt bad=""
  for attempt in 1 2; do
    accepted="$(policy_map_get pair "$agent" "$transport" "$R_MODEL")"
    bad=""
    if [ -z "$accepted" ]; then
      if [ "$R_MSRC" = pin ] && [ "$R_ESRC" = max ]; then
        echo "acp.sh: resolve: COMMS_REVIEW_MAX cannot validate effort '$R_EFFORT' for the pinned, unmapped model '$R_MODEL' — refusing" >&2; return 1
      fi
      if [ "$R_MSRC" = pin ]; then
        # A pinned model the map does not know: honoured, labelled unverified. A ROUTED effort on
        # top of it would be an unvalidated combination the map never approved, so it is dropped.
        if [ "$R_ESRC" = route ]; then bad=unverified-pin; else R_PAIR=unverified-pin; break; fi
      else
        bad=unsupported-pair
      fi
    elif case ",$accepted," in *",$R_EFFORT,"*) true ;; *) false ;; esac; then
      R_PAIR=validated; break
    else
      bad=unsupported-pair
    fi
    if [ "$attempt" = 1 ] && { [ "$R_MSRC" = route ] || [ "$R_ESRC" = route ]; }; then
      if [ "$csrc" = explicit ]; then explicit_refuse "model '$R_MODEL' with effort '$R_EFFORT' ($bad)"; return 1; fi
      [ "$R_MSRC" = route ] && { R_MODEL="$bm"; R_MSRC=baseline; }
      [ "$R_ESRC" = route ] && { R_EFFORT="$be"; R_ESRC=baseline; }
      fb="${fb:+$fb;}$bad"
      continue
    fi
    echo "acp.sh: resolve: model '$R_MODEL' does not accept effort '$R_EFFORT' (model from $R_MSRC, effort from $R_ESRC; map $R_MAPV) — refusing rather than substituting" >&2
    return 1
  done
  # The chosen model must exist on the runtime that will run it. A pinned, baseline or ceiling
  # model that needs a newer runtime is REFUSED here with the remedy, never swapped: the canary
  # would only discover it after a session was spent on it.
  if ! policy_model_available "$agent" "$transport" "$R_MODEL"; then
    echo "acp.sh: resolve: model '$R_MODEL' ($R_MSRC) needs codex >= $(policy_map_get pairmin "$agent" "$transport" "$R_MODEL"), but the reviewer runtime is $R_RUNTIME ($R_RUNTIME_VERSION) — install a newer codex or set COMMS_ACP_CODEX_PATH" >&2
    return 1
  fi
  R_ETIER="$(policy_map_reverse tier "$agent" "$transport" "$R_MODEL")"
  R_EEFF="$(policy_map_reverse effort "$agent" "$transport" "$R_EFFORT")"
  R_VERIFY="model,effort"
  R_FALLBACK="${fb:-none}"
  # THE CONCRETE POLICY'S IDENTITY. runphase names a mounted session after it, so any change to
  # the pair — a new decision, a pin, a map bump, routing switched off — is a FRESH session under
  # the new config instead of a warm one holding the old preference, and an unchanged pair keeps
  # its warm session.
  R_DIGEST="$(policy_digest "$R_MODEL" "$R_EFFORT" "$R_RUNTIME" "$R_RUNTIME_VERSION")" || { echo "acp.sh: resolve: no sha256 utility to identify the policy" >&2; return 1; }
  return 0
}

policy_digest() {  # <model> <effort> <runtime> <runtime-version> -> 12 hex
  # The RUNTIME is part of the identity: codex fixes a session's runtime when it is created, so a
  # runtime upgrade must be a fresh session too, never a resume under a different binary.
  local d
  if command -v shasum >/dev/null 2>&1; then d="$(printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | shasum -a 256)"
  elif command -v sha256sum >/dev/null 2>&1; then d="$(printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | sha256sum)"
  else return 1; fi
  d="${d%% *}"; d="${d:0:12}"
  [[ "$d" =~ ^[0-9a-f]{12}$ ]] || return 1
  printf '%s' "$d"
}

emit_policy_record() {  # the persisted per-turn expectation; key<TAB>value, fixed order
  printf 'policy_record\t%s\n'    "$ACP_POLICY_RECORD_VERSION"
  printf 'map_version\t%s\n'      "$R_MAPV"
  printf 'provider\t%s\n'         "$R_AGENT"
  printf 'transport\t%s\n'        "$R_TRANSPORT"
  printf 'capability\t%s\n'       "$R_CAP"
  printf 'routing\t%s\n'          "$R_ROUTING"
  printf 'decision\t%s\n'         "$R_DECISION"
  printf 'candidate_source\t%s\n' "$R_CSRC"
  printf 'phase\t%s\n'            "$R_PHASE"
  printf 'candidate_tier\t%s\n'   "$R_TIER"
  printf 'candidate_effort\t%s\n' "$R_EFFORT_IN"
  printf 'model\t%s\n'            "$R_MODEL"
  printf 'effort\t%s\n'           "$R_EFFORT"
  printf 'model_source\t%s\n'     "$R_MSRC"
  printf 'effort_source\t%s\n'    "$R_ESRC"
  printf 'effective_tier\t%s\n'   "$R_ETIER"
  printf 'effective_effort\t%s\n' "$R_EEFF"
  printf 'pair\t%s\n'             "$R_PAIR"
  printf 'runtime\t%s\n'          "$R_RUNTIME"
  printf 'runtime_version\t%s\n'  "$R_RUNTIME_VERSION"
  printf 'fallback\t%s\n'         "${R_FALLBACK:-none}"
  printf 'verify\t%s\n'           "$R_VERIFY"
  printf 'policy_digest\t%s\n'    "$R_DIGEST"
}

# policy_from_record <agent> <file> — "<model>\t<effort>" from a PERSISTED record, or exit 1.
# The record is runner-owned, but it is still re-validated here: this is the value that reaches the
# TOML file, and "we wrote it ourselves" is not an allowlist. Every key must appear EXACTLY once —
# a first-match reader and a last-match reader would otherwise disagree about a doubled key.
policy_from_record() {
  local agent="$1" f="$2" out
  [ -f "$f" ] && [ -r "$f" ] || { echo "acp.sh: policy record '$f' is missing or unreadable" >&2; return 1; }
  out="$(awk -F'\t' -v want="$ACP_POLICY_RECORD_VERSION" '
    { sub(/\r$/, "") }
    NF != 2 || $1 == "" || $2 == "" { bad = 1; next }
    { n[$1]++; v[$1] = $2 }
    END {
      split("policy_record provider capability verify model effort", ks, " ")
      for (i in ks) if (n[ks[i]] != 1) bad = 1
      for (k in n) if (n[k] != 1) bad = 1
      if (bad || v["policy_record"] != want) exit 1
      print v["provider"] "\t" v["capability"] "\t" v["verify"] "\t" v["model"] "\t" v["effort"]
    }' "$f")" || { echo "acp.sh: policy record '$f' is malformed" >&2; return 1; }
  # cut, not `IFS=$'\t' read`: tab is IFS whitespace, so an empty field would collapse and shift
  # every later one left. (The same defect runphase's attestation split was fixed for.)
  local p c vf m e
  p="$(printf '%s' "$out" | cut -f1)"; c="$(printf '%s' "$out" | cut -f2)"
  vf="$(printf '%s' "$out" | cut -f3)"; m="$(printf '%s' "$out" | cut -f4)"; e="$(printf '%s' "$out" | cut -f5)"
  [ "$p" = "$agent" ] || { echo "acp.sh: policy record is for '$p', not '$agent'" >&2; return 1; }
  # Gate on WHAT IS VERIFIED, not on whether routing was eligible: a `fixed` combination still
  # applies and attests its baseline; an `unsupported` one claims nothing and is refused here.
  [ "$vf" = "model,effort" ] || { echo "acp.sh: policy record for '$p' ($c) applies no policy" >&2; return 1; }
  [[ "$m" =~ $ACP_POLICY_RE ]] || { echo "acp.sh: policy record model '$m' is not a bare identifier" >&2; return 1; }
  [[ "$e" =~ $ACP_POLICY_RE ]] || { echo "acp.sh: policy record effort '$e' is not a bare identifier" >&2; return 1; }
  printf '%s\t%s\n' "$m" "$e"
}

policy_for() {  # <agent> [record] -> "<model>\t<effort>"; empty + 1 where no policy applies
  # With a record: the persisted per-turn expectation, never re-resolved. Without: the baseline
  # plus pins for a mounted turn, with routing off — the pre-routing contract, unchanged.
  if [ -n "${2:-}" ]; then policy_from_record "$1" "$2"; return; fi
  resolve_policy "$1" acp-mounted none none none off || exit 1
  # claude/grok have no isolated provider config, so nothing carries a policy for them.
  # The policy exists exactly where the isolated home exists. (plan r1.)
  [ "$R_VERIFY" = "model,effort" ] || return 1
  printf '%s\t%s\n' "$R_MODEL" "$R_EFFORT"
}

provider_config_for() {  # <agent> [record] -> the COMPLETE isolated config text
  local pol m e
  pol="$(policy_for "$1" "${2:-}")" || return 1
  m="${pol%%$'\t'*}"; e="${pol#*$'\t'}"
  # approval_policy and sandbox_mode are LITERALS, never concatenated from the environment —
  # only the two policy values are interpolated, and both are allowlisted above. (grok, plan r2.)
  printf 'approval_policy = "on-request"\nsandbox_mode = "read-only"\nmodel = "%s"\nmodel_reasoning_effort = "%s"\n' "$m" "$e"
}

# policy_verdict <agent> <observed-effort> <observed-model> [record] — the ONE comparison, used by
# both the pre-canary preference check and the post-turn attestation so they cannot drift.
#   0 match | 20 mismatch | 21 undecidable
# Undecidable is NEVER "it matched": an absent reading is exactly the case that hid this bug.
# With a record, the expectation is the persisted one: an attestation that reloaded a changed
# default would relabel the expectation to fit the turn, which is the one thing it may never do.
policy_verdict() {
  local agent="$1" oe="$2" om="${3:-}" rec="${4:-}" pol m e
  pol="$(policy_for "$agent" "$rec")" || return 21
  m="${pol%%$'\t'*}"; e="${pol#*$'\t'}"
  [ -n "$oe" ] && [ "$oe" != null ] || { printf 'undecidable: no observed effort\n'; return 21; }
  # BOTH keys are policy, so BOTH must be evidenced. provider-config writes the model into the
  # isolated toml, so an observation that cannot show the model is missing evidence for half the
  # contract — and "absent" must never read as "fine". (codex, implement r1 B3.)
  [ -n "$om" ] && [ "$om" != null ] || { printf 'undecidable: no observed model\n'; return 21; }
  if [ "$oe" != "$e" ] || [ "$om" != "$m" ]; then
    printf 'want effort=%s model=%s; got effort=%s model=%s\n' "$e" "$m" "$oe" "$om"; return 20
  fi
  printf 'effort=%s model=%s\n' "$oe" "$om"; return 0
}

# policy_args <args...> — split the accessors' arguments into positionals (PA_POS, empty values
# PRESERVED: the attestation passes an empty observation on purpose) and --policy-file (PA_FILE).
policy_args() {
  PA_POS=(); PA_FILE=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --policy-file ]; then
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "--policy-file needs a path"
      PA_FILE="$2"; shift 2; continue
    fi
    PA_POS+=("$1"); shift
  done
}

cmd_resolve() {
  local agent="${1:-}"; [ -n "$agent" ] || { echo "acp.sh: resolve: an agent name is required" >&2; exit 2; }
  shift
  [ -n "$(profile_for "$agent")" ] || { echo "acp.sh: resolve: unknown agent '$agent'" >&2; exit 2; }
  local transport=acp-mounted tier=none effort=none decision=none routing=off phase=- csrc=none
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || { echo "acp.sh: resolve: $1 needs a value" >&2; exit 2; }
    case "$1" in
      --transport) transport="$2" ;;
      --tier)      tier="$2" ;;
      --effort)    effort="$2" ;;
      --decision)  decision="$2" ;;
      --routing)   routing="$2" ;;
      --phase)     phase="$2" ;;
      --candidate-source) csrc="$2" ;;
      *) echo "acp.sh: resolve: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift 2
  done
  # Closed vocabularies. A value outside them is a CALLER defect, reported as usage — never
  # quietly read as `none`, which would turn a typo into a baseline turn nobody asked for.
  case "$transport" in acp-mounted|acp|headless) ;; *) echo "acp.sh: resolve: unknown transport '$transport'" >&2; exit 2 ;; esac
  case "$tier"      in fast|balanced|strong|none) ;; *) echo "acp.sh: resolve: unknown tier '$tier'" >&2; exit 2 ;; esac
  case "$effort"    in low|medium|high|xhigh|none) ;; *) echo "acp.sh: resolve: unknown effort '$effort'" >&2; exit 2 ;; esac
  case "$routing"   in on|off) ;; *) echo "acp.sh: resolve: --routing must be on or off" >&2; exit 2 ;; esac
  [ "$decision" = none ] || [[ "$decision" =~ $ACP_POLICY_RE ]] \
    || { echo "acp.sh: resolve: decision '$decision' is not a bare token" >&2; exit 2; }
  [ "$phase" = - ] || [[ "$phase" =~ $ACP_POLICY_RE ]] \
    || { echo "acp.sh: resolve: phase '$phase' is not a bare token" >&2; exit 2; }
  [[ "$csrc" =~ $ACP_POLICY_RE ]] || { echo "acp.sh: resolve: candidate source '$csrc' is not a bare token" >&2; exit 2; }
  resolve_policy "$agent" "$transport" "$tier" "$effort" "$decision" "$routing" "$phase" "$csrc" || exit 1
  emit_policy_record
}

cmd_capabilities() {
  local ver; ver="$(policy_map_check)" || exit 1
  printf 'map_version: %s (%s)\n' "$ver" "$ACP_POLICY_MAP"
  RT_PATH=bundled; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""; policy_runtime_codex
  printf 'reviewer codex runtime: %s (version %s)%s\n' "$RT_PATH" "$RT_VERSION" "${RT_ERR:+ — REFUSED: $RT_ERR}"
  # Two passes, so a routing-eligible combination's rows print whatever order the map lists them in.
  awk -F'\t' '
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    FNR == NR { if ($1 == "capability") cap[$2 SUBSEP $3] = $4; next }
    # the concrete rows print for every combination that APPLIES a policy (eligible or fixed)
    $1 == "capability" { printf "%s/%s: %s\n  mechanism: %s\n  evidence: %s\n  versions tested: %s\n  notes: %s\n", $2, $3, $4, $5, $6, $7, $8; next }
    $1 == "baseline" && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s baseline: model=%s effort=%s\n", $2, $3, $4, $5; next }
    $1 == "ceiling"  && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s ceiling (use max): model=%s effort=%s\n", $2, $3, $4, $5; next }
    $1 == "tier"     && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s tier %s -> first servable of %s\n", $2, $3, $4, $5; next }
    $1 == "effort"   && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s effort %s -> %s\n", $2, $3, $4, $5; next }
    $1 == "pair"     && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s %s accepts: %s%s\n", $2, $3, $4, $5, (NF == 6 ? " (needs codex >= " $6 ")" : ""); next }' "$ACP_POLICY_MAP" "$ACP_POLICY_MAP"
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
  # Which codex a MOUNTED reviewer will run, and so which mapped models it can serve.
  RT_PATH=bundled; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""; policy_runtime_codex
  if [ -n "$RT_ERR" ]; then echo "reviewer codex runtime: REFUSED — $RT_ERR"
  else echo "reviewer codex runtime: $RT_PATH (version $RT_VERSION)$( [ "$RT_PATH" = bundled ] && printf ' — the ACP adapter'"'"'s own copy; models that need a newer codex fall back per policy-map.tsv')"; fi
  # Reply verification needs python3 (comms.sh reply-check). Without it every reply is UNDECIDABLE
  # and refused rather than trusted, so name it here rather than leaving the operator to discover it
  # mid-consult. (codex, acp-compat-gate plan r2.)
  if command -v python3 >/dev/null 2>&1; then
    echo "reply-check: python3 present ($(python3 --version 2>&1)) — replies are verified"
  else
    echo "reply-check: python3 MISSING — every reply is undecidable and will be refused; install python3"
  fi
  echo "guarantee: every consult reply (warm or --oneshot) is verified by comms.sh reply-check and"
  echo "           refused when it is a provider API error or cannot be verified — the consult's own"
  echo "           reply IS its compatibility probe. (The in-session PONG canary that pre-qualifies a"
  echo "           session before an expensive REVIEW prompt runs in runphase, not on this path.)"
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
         # SAME DECODER, ONE DOOR: reply-check classifies the body 10 (answer) / 11 (provider API
         # error) / 12 (UNDECIDABLE — python3 missing or the classifier did not complete). It lives
         # in comms.sh so this path, runphase's broker, and the compatibility canary cannot drift.
         # Undecidable now REFUSES with the mailbox fallback rather than passing an unverified
         # answer through: "cannot decide" is never "this is a clean answer". (codex, plan r2 A1.)
         # The diagnostic temp file is BEST-EFFORT: its allocation must not abort the consult before the
         # refusal + fallback fire (mktemp can fail on an unwritable/full TMPDIR). Guard it; a missing
         # file just means the specific cause is unavailable, not that classification is skipped.
         # (codex, impl r2, blocking.)
         local env_out="" env_err="" env_cause="" env_rc=0
         env_err="$(mktemp "${TMPDIR:-/tmp}/consult-rc.XXXXXX" 2>/dev/null || true)"
         env_out="$(printf '%s\n' "$out" | comms_sibling reply-check - 2>"${env_err:-/dev/null}")" || env_rc=$?
         if [ -n "$env_err" ] && [ -f "$env_err" ]; then
           env_cause="$(tr '\n' ' ' <"$env_err" 2>/dev/null | sed 's/  */ /g; s/ *$//' || true)"; rm -f "$env_err" 2>/dev/null || true
         fi
         case "$env_rc" in
           10) ;;
           11) die_fb "consult: acpx exited 0 but the answer is a provider API error ($(printf '%s\n' "$env_out" | tail -n +2)) — fix the agent's model/CLI configuration" ;;
           *)  die_fb "consult: could not verify the reply is not a provider API error (reply-check ${env_cause:-did not complete: status $env_rc})" ;;
         esac
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
  resolve) shift; cmd_resolve "$@" ;;
  runtime)
    # runtime <agent> --policy-file <record> — the codex binary the persisted record resolved
    # (`bundled`, or a validated absolute path). runphase hands it to the adapter as CODEX_PATH, so
    # the runtime that runs is the one the policy was resolved (and its models checked) against.
    shift; policy_args "$@"
    [ -n "${PA_POS[0]:-}" ] && [ -n "$PA_FILE" ] || die "runtime: usage: runtime <agent> --policy-file <record>"
    [ -f "$PA_FILE" ] || die "runtime: no such record"
    _rt="$(awk -F'\t' '$1=="runtime"{n++; v=$2} END{if(n==1) print v}' "$PA_FILE")"
    _rp="$(awk -F'\t' '$1=="provider"{n++; v=$2} END{if(n==1) print v}' "$PA_FILE")"
    [ "$_rp" = "${PA_POS[0]}" ] || die "runtime: the record is for '${_rp:-?}', not '${PA_POS[0]}'"
    if [ "$_rt" = bundled ] || [ "$_rt" = n/a ]; then printf '%s\n' "$_rt"; exit 0; fi
    [[ "$_rt" =~ $ACP_RUNTIME_PATH_RE ]] && [ -x "$_rt" ] && [ ! -d "$_rt" ] || die "runtime: the record's runtime '${_rt:-}' is not an executable absolute path"
    printf '%s\n' "$_rt"
    ;;
  capabilities) shift; cmd_capabilities ;;
  policy)
    shift; policy_args "$@"
    [ -n "${PA_POS[0]:-}" ] || die "policy: an agent name is required"
    policy_for "${PA_POS[0]}" "$PA_FILE" || exit 1
    ;;
  provider-config)
    shift; policy_args "$@"
    [ -n "${PA_POS[0]:-}" ] || die "provider-config: an agent name is required"
    provider_config_for "${PA_POS[0]}" "$PA_FILE" || exit 1
    ;;
  policy-check)
    # policy-check <agent> - [--policy-file <record>]   (session record JSON on stdin)
    # Reads an `acpx sessions show --format json` record and compares its CURRENT
    # config_options against the policy. This is the PREFLIGHT reading: necessary, and
    # explicitly NOT sufficient — a replacement session can replay a stale preference after
    # it passes (codex, plan r1 B1). The post-turn attestation is the control that gates.
    shift; policy_args "$@"
    [ -n "${PA_POS[0]:-}" ] || die "policy-check: an agent name is required"
    _pc_agent="${PA_POS[0]}"
    [ "${PA_POS[1]:-}" = "-" ] || die "policy-check: the record is read from stdin — pass '-'"
    command -v python3 >/dev/null 2>&1 || { echo "undecidable: python3 is unavailable" >&2; exit 21; }
    # THE SAVED PREFERENCES ARE READ TOO, and this is the point of the check. acpx replays
    # `desired_config_options` (effort) and `session_options.model` (a model set with `acpx set
    # model` or `--model`) when it creates a REPLACEMENT session, so a leftover preference that
    # conflicts with the policy can be reinstated after the current options look clean. Reading
    # only `config_options` would leave the approved refuse-and-retire control unimplemented.
    # (codex, implement r1 B4; the saved MODEL matters once a routed turn may run a model other
    # than the baseline.)
    _pc_out="$(python3 -c '
import json,sys
try: r=json.load(sys.stdin)
except Exception: print("\t\tBAD\t"); sys.exit(0)
ax=r.get("acpx") or {}
opts=ax.get("config_options")
if not isinstance(opts,list): print("\t\t\t"); sys.exit(0)
d={}
for o in opts:
    if isinstance(o,dict) and o.get("id") is not None:
        d[str(o["id"])]=o.get("currentValue")
def g(k):
    v=d.get(k)
    return "" if v is None else str(v)
des=ax.get("desired_config_options")
dv=""
if des is None:
    dv=""                      # absent is fine: nothing will be replayed
elif isinstance(des,dict):
    v=des.get("reasoning_effort")
    dv="" if v is None else str(v)
elif isinstance(des,list):
    for o in des:
        if isinstance(o,dict) and str(o.get("id"))=="reasoning_effort":
            v=o.get("currentValue", o.get("value"))
            dv="" if v is None else str(v)
else:
    dv="BAD"                   # a shape we do not understand is not a shape we may ignore
so=ax.get("session_options")
dm=""
if so is None:
    dm=""
elif isinstance(so,dict):
    v=so.get("model")
    dm="" if v is None else str(v)
else:
    dm="BAD"
print("%s\t%s\t%s\t%s" % (g("reasoning_effort"), g("model"), dv, dm))
' 2>/dev/null)" || { echo "undecidable: could not parse the session record" >&2; exit 21; }
    _pc_eff="$(printf '%s' "$_pc_out" | cut -f1)"; _pc_mod="$(printf '%s' "$_pc_out" | cut -f2)"
    _pc_des="$(printf '%s' "$_pc_out" | cut -f3)"; _pc_dmod="$(printf '%s' "$_pc_out" | cut -f4)"
    if [ "$_pc_des" = BAD ] || [ "$_pc_dmod" = BAD ]; then
      echo "undecidable: the session record's saved preferences are unreadable" >&2; exit 21
    fi
    if [ -n "$_pc_des" ] || [ -n "$_pc_dmod" ]; then
      _pc_pol="$(policy_for "$_pc_agent" "$PA_FILE")" || exit 21
      if [ -n "$_pc_des" ] && [ "$_pc_des" != "${_pc_pol#*$'\t'}" ]; then
        printf 'a saved effort preference (%s) conflicts with the policy and would be replayed onto a replacement session\n' "$_pc_des"
        exit 20
      fi
      if [ -n "$_pc_dmod" ] && [ "$_pc_dmod" != "${_pc_pol%%$'\t'*}" ]; then
        printf 'a saved model preference (%s) conflicts with the policy and would be replayed onto a replacement session\n' "$_pc_dmod"
        exit 20
      fi
    fi
    # A model the adapter does not list (hidden, retired, or not yet served to this account) comes
    # back with NO reasoning_effort option at all (codex-acp createModelId). Say so specifically:
    # the remedy is the map or the routing decision, not the session.
    if [ -z "$_pc_eff" ] && [ -n "$_pc_mod" ]; then
      printf 'undecidable: the session exposes no reasoning_effort option for model %s — an unlisted or retired model? fix policy-map.tsv, or replace the routing decision\n' "$_pc_mod"
      exit 21
    fi
    # A missing list, a missing key, or unparseable JSON all land here as an empty effort and
    # are UNDECIDABLE — never "model matched, effort optional". (grok, plan r2.)
    policy_verdict "$_pc_agent" "$_pc_eff" "$_pc_mod" "$PA_FILE"; exit $?
    ;;
  policy-attest)
    # policy-attest <agent> <observed-effort> [observed-model] [--policy-file <record>] — the
    # post-turn comparison, fed from the provider's OWN rollout record. Same verdict function as
    # policy-check so the two gates cannot drift apart.
    shift; policy_args "$@"
    [ -n "${PA_POS[0]:-}" ] || die "policy-attest: an agent name is required"
    [ -n "${PA_POS[1]:-}" ] || { echo "undecidable: no observed effort was supplied" >&2; exit 21; }
    policy_verdict "${PA_POS[0]}" "${PA_POS[1]}" "${PA_POS[2]:-}" "$PA_FILE"; exit $?
    ;;
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
