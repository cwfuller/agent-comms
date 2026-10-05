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
#       report node/acpx availability, the supported agent map, the reviewer codex
#       runtime and the Gemini CLI; exit 0 iff consults can run here AND that runtime can
#       run the default (baseline) and use-max (ceiling) codex review AND any installed
#       Gemini CLI can run `--acp`; 3 no usable node; 4 a codex review cannot run on the
#       runtime (or the runtime is refused), or the Gemini CLI is too old for `--acp`,
#       reason printed. A Gemini CLI that is simply absent is reported, not a failure:
#       gemini is an opt-in reviewer.
#   runtime-check codex|gemini
#       machine-readable form of doctor's runtime verdict: `runtime` and
#       `runtime_version` lines, then per row <baseline|ceiling> <model>
#       <baseline|max|pin> <minimum|-> <ok|refused> <reason|-> (TAB-separated).
#       Exit 0 all ok, 4 a row refused, 1 runtime refused (for gemini: absent, or older than
#       the first release with `--acp`; the version lines still print) or map defect, 2 usage.
#   supports <agent>
#       exit 0 iff a consult can run here for that agent (machine-readable —
#       never parse doctor's prose).
#   launcher [agent]
#       the argv prefix that runs acpx here (honours ACPX_BIN; falls back to a
#       workspace npm cache when ~/.npm is unwritable). Other helpers ask, never guess.
#       With an agent whose mounted review relies on acpx REFUSING fs/terminal requests (grok), the
#       pin is the first release that does (ACPX_VERSION_ENFORCING), not the baseline pin.
#   profile <agent> | version [agent]
#       the acpx launch profile for an agent, and the pinned acpx version (the same per-agent pin
#       as `launcher`). Other helpers ask for these instead of keeping a second copy of the map.
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
#       The record carries `limit_id`: the usage limit the chosen model spends when the
#       map gives it one of its own (a `limit` row), `-` for the provider's shared limit,
#       `n/a` where no model is applied. --transport mailbox (a leg nobody drives)
#       resolves to that `unsupported` answer.
#   resolve <agent> --bound-model <m> --bound-effort <e|-> --route-id <id> --access-digest <sha256>
#           [--custom-profile] [--transport acp-mounted] [--phase <p>]
#       BOUND resolution (panel dispatch --bindings): the caller's EXACT model and native effort,
#       validated and never substituted. No tier, routed candidate, baseline, pin or "use max":
#       an operator pin or COMMS_REVIEW_MAX that differs from the binding is a CONFLICT (a
#       refusal), an equal pin is accepted. Built-in agents must be `eligible` or `fixed`
#       (applied and attested); `--custom-profile` binds an operator profile (OpenCode) to its
#       pinned model with a null effort, read through agent_profiles.py, never the map. Writes a
#       version-2 record (route_id, access_digest, bound). A refusal's message starts
#       `code=<token>` (capability-unsupported, pin-conflict, model-unservable, effort-refused,
#       effort-mismatch, model-mismatch, agent-unbindable).
#   route-view <agent> <record-file|-> [--format line|json]
#       the spend-planning view of a resolved record: transport, capability, model,
#       effort, limit_id, model_source, effort_source, routing, decision, phase,
#       map_version — as `key=value` words or a one-line JSON object. The ONE field list
#       behind `comms.sh review-route plan` and result.json's "route".
#   capabilities
#       the map version, the reviewer codex runtime and Gemini CLI, and every
#       provider/transport capability row, with the concrete controls of each combination
#       that applies a policy (and every model the map marks disabled).
#   runtime <agent> --policy-file <record>
#       the codex binary the record resolved (`bundled`, or an absolute path) —
#       see policy_runtime_codex for COMMS_ACP_CODEX_PATH and auto-detection.
#   gemini-auth <settings.json> | gemini-effort <settings.json> | failure-reason <provider> <stderr-file>
#       gemini's helpers for runphase: the operator's selected auth type (one allowlisted token), the
#       thinking level an isolated settings.json carries (as a policy effort token), and the
#       classification of a provider refusal (`rate-limited` | `auth-failed` | nothing) from the
#       diagnostics acpx relayed.
#   containment <agent>
#       whether a MOUNTED review of that agent can be contained on this host, and by what: one
#       `backend<TAB><name>` line (exit 0), or the reason it cannot be, on stderr (exit 1 no backend
#       exists for this agent/OS, 3 a backend exists but a prerequisite is missing). The same answer
#       the runner acts on, so `doctor` and a refused leg cannot disagree. grok's comes from box.sh.
#   grok-auth <auth.json> [refresh]
#       the grok login a mounted turn is staged with: the operator's auth.json minus its refresh token,
#       on stdout. Exit 4 when its access token is expired or about to be (`refresh` first runs the
#       operator's own `grok models` once to renew it), 1 when unreadable.
#   grok-config <config.toml>
#       the isolated grok home's config.toml text: the operator's default model and reasoning effort
#       (two allowlisted keys of `[models]`) and nothing else of theirs.
#   policy <agent> [--policy-file <record>]
#       the reviewer model+effort policy for an agent, tab-separated
#       (<model>\t<effort>); empty + exit 1 where no policy applies.
#   provider-config <agent> [--policy-file <record>] [--auth-type <type>]
#       the COMPLETE isolated provider config file text for a mounted review
#       turn (codex: config.toml; gemini: settings.json, where --auth-type carries the
#       operator's selected auth type forward). runphase asks for this rather than holding
#       a literal, so the policy is spelled exactly once.
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
# `grok-build` profile (verified against `acpx --help`, 2026-08-25); gemini maps to acpx's `gemini`
# builtin, which launches `gemini --acp` (or the deprecated `--experimental-acp` below gemini 0.33.0,
# which this helper refuses instead). Unsupported agents fail closed naming the fallback.
set -euo pipefail

# User/project SETTINGS (helpers/settings.sh): fills unset variables from the settings files, so
# a setting works in every shell — including agent tool shells that never read the shell rc.
# Absent next to this script (an old install, a bare copy) it is simply skipped: env still works.
[ -f "$(dirname "${BASH_SOURCE[0]}")/settings.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/settings.sh"

ACPX_VERSION="0.13.1"
# The first acpx whose --no-fs / --no-terminal REFUSE the requests rather than only withholding the
# advertisement: 0.13.1 registered the handlers regardless, so a contained agent that sent a terminal
# request anyway had it run by the unsandboxed owner. grok's mounted containment (helpers/box.sh) depends
# on the refusal, and `box.sh client-check` proves it for whatever launcher is actually in use.
ACPX_VERSION_ENFORCING="0.17.1"
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
# (gpt-6.1-sol/xhigh as of map 2026-09-29.2), the tier->model and effort->value rows a routed
# decision may select, and the efforts each model accepts. The operator's pins stay environment
# variables (COMMS_ACP_CODEX_MODEL / COMMS_ACP_CODEX_EFFORT) and still win over everything. The
# map is read ONLY from the sibling file, never from an environment override, so a second table
# cannot appear beside the one the ledger names.
ACP_POLICY_MAP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/policy-map.tsv"
ACP_POLICY_RECORD_VERSION=1
# A BOUND resolution (`resolve --bound-model`, the caller's exact pair) writes version 2, adding route_id,
# access_digest and bound; unbound resolutions keep writing version 1, byte for byte. Readers accept both
# and hold each version to its own field set, so a record persisted before an upgrade still reads after it.
ACP_POLICY_RECORD_VERSION_BOUND=2

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
# box.sh sits beside this script like every helper; a missing one is "no backend", never a silent pass.
comms_box() {
  local b; b="$(dirname "${BASH_SOURCE[0]}")/box.sh"
  [ -x "$b" ] || { echo "acp.sh: no box.sh beside $(basename "${BASH_SOURCE[0]}") — grok's containment backend is not installed" >&2; return 3; }
  "$b" "$@"
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

acpx_version_for() {  # <agent|""> -> the acpx version pinned for it
  case "${1:-}" in grok) printf '%s' "$ACPX_VERSION_ENFORCING" ;; *) printf '%s' "$ACPX_VERSION" ;; esac
}

acpx_launcher() {  # [agent] — prints the argv prefix that runs acpx
  if [ -n "${ACPX_BIN:-}" ]; then printf '%s' "$ACPX_BIN"; else printf 'npx -y acpx@%s' "$(acpx_version_for "${1:-}")"; fi
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
    gemini) echo gemini ;;
    *)      if comms_sibling agents --profile "$1" >/dev/null 2>&1; then echo agent-comms-custom; else echo ""; fi ;;
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
    $1 == "limit" {
      if (NF != 5 || !tok($2) || !tok($3) || $4 !~ re || $5 !~ re) bad("malformed limit")
      once("l" SUBSEP $2 SUBSEP $3 SUBSEP $4); next }
    $1 == "disabled" {
      if (NF != 5 || !tok($2) || !tok($3) || $4 !~ re || $5 !~ re) bad("malformed disabled")
      once("d" SUBSEP $2 SUBSEP $3 SUBSEP $4); next }
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
#   ceiling -> <model>\t<effort>   limit <model> -> <limit_id>   disabled <model> -> <reason>
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
policy_applied_combo() { case "$1/$2" in codex/acp-mounted|gemini/acp-mounted) return 0 ;; esac; return 1; }

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

# THE GEMINI RUNTIME a review turn will run: the `gemini` acpx launches BY NAME, so the one found on
# PATH. Unlike codex there is no bundled copy and no path override — acpx's `gemini` profile is
# `gemini --acp`, and a runtime other than the one named here would be a second, unreported one.
# `--acp` replaced the deprecated `--experimental-acp` in gemini 0.33.0 (acpx's own
# GEMINI_ACP_FLAG_VERSION): below it the flag this helper launches does not exist, so it is refused
# here, with the same wording on every surface, rather than discovered as a dead turn.
# Sets RT_PATH (absolute path, or empty when absent), RT_VERSION (x.y.z, or `unknown`) and RT_ERR.
ACP_GEMINI_ACP_VERSION=0.33.0
# A MOUNTED REVIEW needs more than the flag: it is published only on the model evidence read back from
# the CLI's own chat record, and gemini writes that record as append-only `.jsonl` from 0.39.0 (0.33–0.38
# wrote one rewritten `.json` per session, which helpers/leg_usage.py does not read). Below this a turn
# would pass every gate before the prompt and then fail attestation after the review was paid for, so the
# review surfaces refuse it up front. A consult needs no evidence and keeps the lower ACP floor.
ACP_GEMINI_MIN_VERSION=0.39.0
policy_runtime_gemini() {
  local cand v
  RT_PATH=""; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""
  cand="$(command -v gemini 2>/dev/null)" || cand=""
  if [ -z "$cand" ] || [ -d "$cand" ] || [ ! -x "$cand" ]; then RT_ERR="the gemini CLI was not found on PATH"; return 0; fi
  if ! [[ "$cand" =~ $ACP_RUNTIME_PATH_RE ]]; then RT_ERR="the gemini CLI at '$cand' is not a plain absolute path"; return 0; fi
  RT_PATH="$cand"
  v="$(runtime_version_probe "$cand")" || v=""
  if [ -z "$v" ]; then RT_ERR="the gemini CLI at $cand did not report a version within ${ACP_RUNTIME_PROBE_SECS}s"; return 0; fi
  RT_VERSION="$v"
  ver_ge "$v" "$ACP_GEMINI_ACP_VERSION" \
    || RT_ERR="gemini $v has no --acp flag (first shipped in $ACP_GEMINI_ACP_VERSION; older builds only have the deprecated --experimental-acp) — upgrade the Gemini CLI"
}

# policy_runtime_gemini_review — policy_runtime_gemini plus the mounted-review floor (see
# ACP_GEMINI_MIN_VERSION). Every reviewer surface (resolve, runtime-check, doctor, capabilities) calls
# this one; only consult and `supports`, which publish no review, use the bare probe.
policy_runtime_gemini_review() {
  policy_runtime_gemini
  [ -z "$RT_ERR" ] || return 0
  ver_ge "$RT_VERSION" "$ACP_GEMINI_MIN_VERSION" \
    || RT_ERR="gemini $RT_VERSION cannot back a mounted review: its chat records are not the .jsonl the review attestation reads (first written by $ACP_GEMINI_MIN_VERSION) — upgrade the Gemini CLI"
}

# policy_runtime_for <agent> — the ONE dispatch from an agent to its runtime probe; sets RT_*.
# Only codex and gemini have a runtime a policy is resolved against.
policy_runtime_for() {
  RT_PATH=bundled; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""
  case "$1" in codex) policy_runtime_codex ;; gemini) policy_runtime_gemini_review ;; esac
}

# policy_model_disabled <agent> <transport> <model> — the reason a model is DISABLED (a `disabled` row),
# or nothing. A disabled model is one the provider has announced but nothing can serve yet: its tier
# and pair rows may already be written, and removing the row is the whole act of enabling it.
policy_model_disabled() { policy_map_get disabled "$1" "$2" "$3"; }

# policy_model_available <agent> <transport> <model> — 0 iff the model's declared minimum runtime
# (optional 6th column of its `pair` row) is met by RT_VERSION. No minimum = available everywhere.
policy_model_available() {
  local min; min="$(policy_map_get pairmin "$1" "$2" "$3")"
  [ -z "$min" ] && return 0
  ver_ge "$RT_VERSION" "$min"
}
# policy_unservable_reason <agent> <transport> <model> <source> — nothing (exit 0) when the runtime
# in RT_PATH/RT_VERSION serves the model; else the one-line reason it cannot (exit 1). The ONE
# wording, with the minimum read from the map's pair row, behind resolve's refusal, `runtime-check`
# and `doctor`, so no surface restates a version. A DISABLED model is unservable on any runtime, so the
# diagnostics agree with resolve instead of reporting a row runnable that every mounted turn refuses.
policy_unservable_reason() {
  local dis; dis="$(policy_model_disabled "$1" "$2" "$3")"
  if [ -n "$dis" ]; then
    printf "model '%s' (%s) is disabled in the policy map (%s)\n" "$3" "$4" "$dis"
    return 1
  fi
  policy_model_available "$1" "$2" "$3" && return 0
  printf "model '%s' (%s) needs %s >= %s, but the reviewer runtime is %s (%s) — install a newer %s%s\n" \
    "$3" "$4" "$1" "$(policy_map_get pairmin "$1" "$2" "$3")" "$RT_PATH" "$RT_VERSION" "$1" \
    "$( [ "$1" = codex ] && printf ' or set COMMS_ACP_CODEX_PATH')"
  return 1
}

# The operator's pins, per provider. Only providers with an applied policy (codex, gemini) have pins; a
# provider added here must also gain a capability row with its own evidence.
policy_pin_model()  { case "$1" in codex) printf '%s' "${COMMS_ACP_CODEX_MODEL:-}" ;; gemini) printf '%s' "${COMMS_ACP_GEMINI_MODEL:-}" ;; esac; }
policy_pin_effort() { case "$1" in codex) printf '%s' "${COMMS_ACP_CODEX_EFFORT:-}" ;; gemini) printf '%s' "${COMMS_ACP_GEMINI_EFFORT:-}" ;; esac; }
# THE OPERATOR'S "use max": every reviewer turn that applies a policy runs the map's `ceiling` pair.
# Provider-neutral on purpose — it names no model, the map does. It only ever RAISES depth, so it is
# not an author-steering channel the way a cheaper route would be.
policy_max_on() { case "${COMMS_REVIEW_MAX:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; esac; return 1; }

# THE PAIR RULE, defined once: `resolve` and `runtime-check`/`doctor` (policy_runtime_standing) both
# judge a (model, effort) pair through this, so no surface can report a review runnable that
# resolve would refuse.
# policy_pair_verdict <agent> <transport> <model> <model-source> <effort> <effort-source> — prints
# the verdict token; exit 0 when the pair may run (`validated`, or `unverified-pin`: a pinned model
# the map does not know, honoured and labelled), exit 1 with the reason token when it may not
# (`unsupported-pair`; `unverified-pin` when a ROUTED effort rides on an unmapped pin;
# `max-unmapped-pin` when "use max" cannot be validated on a pinned, unmapped model).
policy_pair_verdict() {
  local accepted; accepted="$(policy_map_get pair "$1" "$2" "$3")"
  if [ -z "$accepted" ]; then
    if [ "$4" != pin ]; then echo unsupported-pair; return 1; fi
    if [ "$6" = max ]; then echo max-unmapped-pin; return 1; fi
    echo unverified-pin
    [ "$6" != route ]; return
  fi
  case ",$accepted," in *",$5,"*) echo validated; return 0 ;; esac
  echo unsupported-pair; return 1
}
# policy_pair_refusal <token> <model> <model-source> <effort> <effort-source> <map-version> — the one
# wording of a pair refusal (resolve's stderr, runtime-check's reason column, doctor's line).
policy_pair_refusal() {
  case "$1" in
    max-unmapped-pin) printf "COMMS_REVIEW_MAX cannot validate effort '%s' for the pinned, unmapped model '%s'\n" "$4" "$2" ;;
    *) printf "model '%s' does not accept effort '%s' (model from %s, effort from %s; map %s)\n" "$2" "$4" "$3" "$5" "$6" ;;
  esac
}

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
  local base bm be pm pe fb="" route_ok=0
  R_AGENT="$agent"; R_TRANSPORT="$transport"; R_TIER="$tier"; R_EFFORT_IN="$effort"
  R_DECISION="$decision"; R_ROUTING="$routing"; R_PHASE="$phase"; R_CSRC="$csrc"; R_DIGEST=none; R_BOUND=0
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
    R_ETIER=n/a; R_EEFF=n/a; R_PAIR=n/a; R_VERIFY=none; R_LIMIT=n/a
    policy_max_on && fb="${fb:+$fb;}max-unsupported"
    R_FALLBACK="${fb:+$fb;}capability-unsupported"
    return 0
  fi
  # THE RUNTIME, resolved before any model is chosen: which models exist depends on it.
  policy_runtime_for "$agent"
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
      if [ -n "$(policy_model_disabled "$agent" "$transport" "$m1")" ]; then fb="${fb:+$fb;}disabled:$m1"; continue; fi
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
    if bad="$(policy_pair_verdict "$agent" "$transport" "$R_MODEL" "$R_MSRC" "$R_EFFORT" "$R_ESRC")"; then
      R_PAIR="$bad"; break
    fi
    if [ "$bad" = max-unmapped-pin ]; then
      echo "acp.sh: resolve: $(policy_pair_refusal "$bad" "$R_MODEL" "$R_MSRC" "$R_EFFORT" "$R_ESRC" "$R_MAPV") — refusing" >&2; return 1
    fi
    if [ "$attempt" = 1 ] && { [ "$R_MSRC" = route ] || [ "$R_ESRC" = route ]; }; then
      if [ "$csrc" = explicit ]; then explicit_refuse "model '$R_MODEL' with effort '$R_EFFORT' ($bad)"; return 1; fi
      [ "$R_MSRC" = route ] && { R_MODEL="$bm"; R_MSRC=baseline; }
      [ "$R_ESRC" = route ] && { R_EFFORT="$be"; R_ESRC=baseline; }
      fb="${fb:+$fb;}$bad"
      continue
    fi
    echo "acp.sh: resolve: $(policy_pair_refusal "$bad" "$R_MODEL" "$R_MSRC" "$R_EFFORT" "$R_ESRC" "$R_MAPV") — refusing rather than substituting" >&2
    return 1
  done
  # The chosen model must exist on the runtime that will run it. A pinned, baseline or ceiling
  # model that needs a newer runtime is REFUSED here with the remedy, never swapped: the canary
  # would only discover it after a session was spent on it.
  local why
  why="$(policy_model_disabled "$agent" "$transport" "$R_MODEL")"
  if [ -n "$why" ]; then
    echo "acp.sh: resolve: model '$R_MODEL' ($R_MSRC) is disabled in the policy map ($why; map $R_MAPV) — refusing rather than substituting" >&2
    return 1
  fi
  if ! why="$(policy_unservable_reason "$agent" "$transport" "$R_MODEL" "$R_MSRC")"; then
    echo "acp.sh: resolve: $why" >&2
    return 1
  fi
  # THE USAGE LIMIT the chosen model spends, when the provider meters it apart from the rest (a
  # `limit` row, keyed by the limit_id the provider's own rate-limit records report). `-` = no limit
  # of its own: the provider's shared one. A pin names a model, so a pinned model gets its row too.
  R_LIMIT="$(policy_map_get limit "$agent" "$transport" "$R_MODEL")"; R_LIMIT="${R_LIMIT:--}"
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

# BOUND RESOLUTION — the caller's EXACT model and native effort, validated and never substituted.
# `panel dispatch --bindings` names, per leg, the pair it wants; this either resolves that pair or
# refuses it. There is no tier, no routed candidate, no baseline, no pin and no "use max" here: an
# environment pin or COMMS_REVIEW_MAX that differs from the binding is a CONFLICT (a refusal), never an
# override in either direction, and nothing is ever swapped for a pair that would run. A refusal's
# message starts `code=<token>`: callers map it to the refusal code they print, so the wording can change
# without changing the contract.
#   resolve_bound <agent> <transport> <model> <effort|-> <route-id> <access-digest> <phase>
bound_refuse() {  # <code> <detail> — one refusal line on stderr, then return 1 from the caller
  echo "acp.sh: resolve: code=$1 $2" >&2
}
bound_prelude() {  # <agent> <transport> <model> <effort|-> <route-id> <access-digest> <phase>
  R_AGENT="$1"; R_TRANSPORT="$2"; R_TIER=none; R_EFFORT_IN=none; R_DECISION=none; R_ROUTING=off
  R_PHASE="${7:--}"; R_CSRC=bound; R_DIGEST=none; R_BOUND=1; R_ROUTE_ID="$5"; R_ACCESS="$6"
  R_MAPV="$(policy_map_check)" || return 1
  R_RUNTIME=n/a; R_RUNTIME_VERSION=n/a; R_FALLBACK=none
  # THE PIN RULE. An operator pin or "use max" in the dispatching environment is a second source of the
  # pair. Equal to the binding it is harmless and accepted; anything else refuses, so nothing silently
  # overrides the binding and the binding never silently overrides an operator's standing choice.
  local pm pe
  if policy_max_on; then
    bound_refuse pin-conflict "COMMS_REVIEW_MAX is set: a bound leg runs the caller's model and effort, never the map's ceiling"; return 1
  fi
  pm="$(policy_pin_model "$1")"; pe="$(policy_pin_effort "$1")"
  if [ -n "$pm" ] && [ "$pm" != "$3" ]; then
    bound_refuse pin-conflict "the operator's model pin '$pm' differs from the bound model '$3'"; return 1
  fi
  if [ -n "$pe" ] && [ "$pe" != "$4" ]; then
    bound_refuse pin-conflict "the operator's effort pin '$pe' differs from the bound effort '$4'"; return 1
  fi
  return 0
}
resolve_bound() {
  local agent="$1" transport="$2" bm="$3" be="$4" bad why
  bound_prelude "$@" || return 1
  [[ "$bm" =~ $ACP_POLICY_RE ]] || { bound_refuse model-unservable "model '$bm' is not a bare identifier"; return 1; }
  [ "$be" = - ] || [[ "$be" =~ $ACP_POLICY_RE ]] || { bound_refuse effort-refused "effort '$be' is not a bare identifier"; return 1; }
  R_CAP="$(policy_map_get capability "$agent" "$transport")"; R_CAP="${R_CAP:-unsupported}"
  if { [ "$R_CAP" != eligible ] && [ "$R_CAP" != fixed ]; } || ! policy_applied_combo "$agent" "$transport"; then
    bound_refuse capability-unsupported "$agent/$transport applies and attests no model or effort policy (capability $R_CAP), so nothing can be bound"; return 1
  fi
  policy_runtime_for "$agent"
  [ -z "$RT_ERR" ] || { bound_refuse model-unservable "$RT_ERR"; return 1; }
  R_RUNTIME="$RT_PATH"; R_RUNTIME_VERSION="$RT_VERSION"
  # Every codex and gemini model has a native effort scale, so a null effort cannot bind one.
  [ "$be" != - ] || { bound_refuse effort-mismatch "a bound effort of null cannot bind model '$bm': it has a native effort scale"; return 1; }
  R_MODEL="$bm"; R_EFFORT="$be"; R_MSRC=bound; R_ESRC=bound
  # The SAME pair rule the pins go through: a model the map knows must accept the effort; one it does not
  # know is honoured and labelled (unverified-pin), and the post-turn attestation is what gates it.
  if ! bad="$(policy_pair_verdict "$agent" "$transport" "$R_MODEL" pin "$R_EFFORT" bound)"; then
    bound_refuse effort-refused "$(policy_pair_refusal "$bad" "$R_MODEL" bound "$R_EFFORT" bound "$R_MAPV")"; return 1
  fi
  R_PAIR="$bad"
  why="$(policy_model_disabled "$agent" "$transport" "$R_MODEL")"
  if [ -n "$why" ]; then
    bound_refuse model-unservable "model '$R_MODEL' is disabled in the policy map ($why; map $R_MAPV)"; return 1
  fi
  if ! why="$(policy_unservable_reason "$agent" "$transport" "$R_MODEL" bound)"; then
    bound_refuse model-unservable "$why"; return 1
  fi
  R_LIMIT="$(policy_map_get limit "$agent" "$transport" "$R_MODEL")"; R_LIMIT="${R_LIMIT:--}"
  R_ETIER="$(policy_map_reverse tier "$agent" "$transport" "$R_MODEL")"
  R_EEFF="$(policy_map_reverse effort "$agent" "$transport" "$R_EFFORT")"
  R_VERIFY="model,effort"
  R_DIGEST="$(policy_digest "$R_MODEL" "$R_EFFORT" "$R_RUNTIME" "$R_RUNTIME_VERSION" "$R_ACCESS")" \
    || { echo "acp.sh: resolve: no sha256 utility to identify the policy" >&2; return 1; }
  return 0
}
# resolve_bound_custom — an operator profile (an OpenCode adapter today) is an exact model PIN with no
# effort scale, so it binds its pinned model and a null effort and nothing else. The profile is read
# through agent_profiles.py, never the policy map: no row is added there for a custom agent.
resolve_bound_custom() {
  local agent="$1" transport="$2" bm="$3" be="$4" pm adapter helper
  helper="$(dirname "${BASH_SOURCE[0]}")/agent_profiles.py"
  bound_prelude "$@" || return 1
  adapter="$(python3 "$helper" field "$agent" adapter 2>/dev/null)" \
    || { bound_refuse agent-unbindable "no operator profile for '$agent'"; return 1; }
  [ "$adapter" = opencode ] \
    || { bound_refuse agent-unbindable "consult-only: the '$adapter' adapter has no mounted review runner, so nothing can be bound"; return 1; }
  pm="$(python3 "$helper" field "$agent" model 2>/dev/null)" || { bound_refuse agent-unbindable "no pinned model for '$agent'"; return 1; }
  [ "$pm" = "$bm" ] || { bound_refuse model-mismatch "the profile pins model '$pm', not the bound '$bm'"; return 1; }
  [ "$be" = - ] || { bound_refuse effort-mismatch "profile '$agent' pins a model and has no native effort scale; the bound effort '$be' cannot be applied"; return 1; }
  R_CAP=profile; R_MODEL="$pm"; R_EFFORT=n/a; R_MSRC=bound; R_ESRC=bound
  R_ETIER=n/a; R_EEFF=n/a; R_PAIR=profile-pin; R_VERIFY=model; R_LIMIT=n/a
  R_DIGEST="$(policy_digest "$R_MODEL" "$R_EFFORT" n/a n/a "$R_ACCESS")" \
    || { echo "acp.sh: resolve: no sha256 utility to identify the policy" >&2; return 1; }
  return 0
}

policy_digest() {  # <model> <effort> <runtime> <runtime-version> [<access-digest>] -> 12 hex
  # The RUNTIME is part of the identity: codex fixes a session's runtime when it is created, so a
  # runtime upgrade must be a fresh session too, never a resume under a different binary. A BOUND
  # resolution adds the access digest, so two accounts or billing routes never share a warm session;
  # an unbound one hashes exactly what it always did.
  local d
  policy_digest_payload() { printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4"; [ -z "${5:-}" ] || printf '\0%s' "$5"; }
  if command -v shasum >/dev/null 2>&1; then d="$(policy_digest_payload "$@" | shasum -a 256)"
  elif command -v sha256sum >/dev/null 2>&1; then d="$(policy_digest_payload "$@" | sha256sum)"
  else return 1; fi
  d="${d%% *}"; d="${d:0:12}"
  [[ "$d" =~ ^[0-9a-f]{12}$ ]] || return 1
  printf '%s' "$d"
}

emit_policy_record() {  # the persisted per-turn expectation; key<TAB>value, fixed order
  printf 'policy_record\t%s\n'    "$([ "${R_BOUND:-0}" = 1 ] && echo "$ACP_POLICY_RECORD_VERSION_BOUND" || echo "$ACP_POLICY_RECORD_VERSION")"
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
  printf 'limit_id\t%s\n'         "$R_LIMIT"
  printf 'effective_tier\t%s\n'   "$R_ETIER"
  printf 'effective_effort\t%s\n' "$R_EEFF"
  printf 'pair\t%s\n'             "$R_PAIR"
  printf 'runtime\t%s\n'          "$R_RUNTIME"
  printf 'runtime_version\t%s\n'  "$R_RUNTIME_VERSION"
  printf 'fallback\t%s\n'         "${R_FALLBACK:-none}"
  printf 'verify\t%s\n'           "$R_VERIFY"
  printf 'policy_digest\t%s\n'    "$R_DIGEST"
  if [ "${R_BOUND:-0}" = 1 ]; then
    printf 'route_id\t%s\n'         "$R_ROUTE_ID"
    printf 'access_digest\t%s\n'    "$R_ACCESS"
    printf 'bound\t1\n'
  fi
}

# policy_from_record <agent> <file> — "<model>\t<effort>" from a PERSISTED record, or exit 1.
# The record is runner-owned, but it is still re-validated here: this is the value that reaches the
# TOML file, and "we wrote it ourselves" is not an allowlist. Every key must appear EXACTLY once —
# a first-match reader and a last-match reader would otherwise disagree about a doubled key.
policy_from_record() {
  local agent="$1" f="$2" out
  [ -f "$f" ] && [ -r "$f" ] || { echo "acp.sh: policy record '$f' is missing or unreadable" >&2; return 1; }
  out="$(awk -F'\t' -v want="$ACP_POLICY_RECORD_VERSION" -v wantb="$ACP_POLICY_RECORD_VERSION_BOUND" '
    { sub(/\r$/, "") }
    NF != 2 || $1 == "" || $2 == "" { bad = 1; next }
    { n[$1]++; v[$1] = $2 }
    END {
      split("policy_record provider capability verify model effort", ks, " ")
      for (i in ks) if (n[ks[i]] != 1) bad = 1
      for (k in n) if (n[k] != 1) bad = 1
      # Each version is held to its OWN field set: a retained version-1 record still reads, and a
      # version-2 (bound) record must carry the three keys only it has.
      hasb = (("route_id" in n) && ("access_digest" in n) && ("bound" in n))
      anyb = (("route_id" in n) || ("access_digest" in n) || ("bound" in n))
      if (v["policy_record"] == want && anyb) bad = 1
      if (v["policy_record"] == wantb && !hasb) bad = 1
      if (bad || (v["policy_record"] != want && v["policy_record"] != wantb)) exit 1
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

# gemini_config_for <model> <effort> <auth-type|-> -> the COMPLETE isolated `.gemini/settings.json`.
# Everything but the three values is a LITERAL; the values are allowlisted tokens (ACP_POLICY_RE), so
# nothing can close a string and add a key — the same rule as the codex TOML above. What it pins:
#   model.name                       the leg's model (acpx also sets it on the session with --model)
#   modelConfigs.customOverrides     the thinking level for that model. The CLI has no ACP control for
#                                    it, so the settings file is the only way to bind it per leg. An
#                                    effort of `default` writes NO override (a model with no thinking
#                                    control is left alone rather than sent a parameter it may reject).
#   general.plan.modelRouting=false  plan mode otherwise SWITCHES model (Pro to plan, Flash to implement),
#                                    which would make the pinned model a suggestion.
#   general.enableAutoUpdate=false   a review turn never upgrades the CLI under a running session.
#   privacy.usageStatisticsEnabled=false
#   security.auth.selectedType       only when the operator has one (an allowlisted token): it is the
#                                    one piece of the operator's settings that keeps the login working.
gemini_config_for() {
  local m="$1" e="$2" auth="${3:--}" level="" ov="" au=""
  case "$e" in
    low) level=LOW ;; medium) level=MEDIUM ;; high) level=HIGH ;; default) level="" ;;
    *) echo "acp.sh: provider-config: gemini has no thinking level for effort '$e'" >&2; return 1 ;;
  esac
  [ "$auth" = - ] || [[ "$auth" =~ $ACP_POLICY_RE ]] \
    || { echo "acp.sh: provider-config: auth type '$auth' is not a bare identifier" >&2; return 1; }
  [ -z "$level" ] || ov="$(printf ',\n  "modelConfigs": {"customOverrides": [{"match": {"model": "%s"}, "modelConfig": {"generateContentConfig": {"thinkingConfig": {"thinkingLevel": "%s"}}}}]}' "$m" "$level")"
  [ "$auth" = - ] || au="$(printf ',\n  "security": {"auth": {"selectedType": "%s"}}' "$auth")"
  printf '{\n  "model": {"name": "%s"},\n  "general": {"plan": {"modelRouting": false}, "enableAutoUpdate": false},\n  "privacy": {"usageStatisticsEnabled": false}%s%s\n}\n' "$m" "$ov" "$au"
}

provider_config_for() {  # <agent> [record] [auth-type] -> the COMPLETE isolated config text
  local pol m e
  pol="$(policy_for "$1" "${2:-}")" || return 1
  m="${pol%%$'\t'*}"; e="${pol#*$'\t'}"
  if [ "$1" = gemini ]; then gemini_config_for "$m" "$e" "${3:--}"; return; fi
  # COMPACT INSIDE THE REVIEW, not before the next prompt. Once a turn ends at or above this percent of
  # the model's context window, codex compacts before the turn completes, under the review's long
  # budget; without it the compaction waits for the next turn's pre-turn check, which is the 60s canary
  # (docs/ROADMAP.md, 2026-10-05). Probed on codex 0.160.0: a 14,400-token turn in a 258,400 window
  # compacted at 2 and did not at 10; 0.156.1 (the adapter's bundled codex) accepts the key; codex
  # refuses a value above 100. COMMS_ACP_CODEX_COMPACT_PERCENT=0 omits the key (codex's own default).
  local cp="${COMMS_ACP_CODEX_COMPACT_PERCENT:-80}"
  [[ "$cp" =~ ^(0|[1-9][0-9]?|100)$ ]] \
    || { echo "acp.sh: provider-config: COMMS_ACP_CODEX_COMPACT_PERCENT must be 0-100, got '$cp'" >&2; return 1; }
  # approval_policy and sandbox_mode are LITERALS, never concatenated from the environment —
  # only the two policy values are interpolated, and both are allowlisted above. (grok, plan r2.)
  printf 'approval_policy = "on-request"\nsandbox_mode = "read-only"\nmodel = "%s"\nmodel_reasoning_effort = "%s"\n' "$m" "$e"
  [ "$cp" = 0 ] || printf 'model_post_turn_compact_threshold_percent = %s\n' "$cp"
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
# PRESERVED: the attestation passes an empty observation on purpose), --policy-file (PA_FILE) and
# --auth-type (PA_AUTH, read by provider-config only).
policy_args() {
  PA_POS=(); PA_FILE=""; PA_AUTH=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --policy-file ]; then
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "--policy-file needs a path"
      PA_FILE="$2"; shift 2; continue
    fi
    if [ "$1" = --auth-type ]; then
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "--auth-type needs a value"
      PA_AUTH="$2"; shift 2; continue
    fi
    PA_POS+=("$1"); shift
  done
}

# gemini_policy_check <record> — the PREFLIGHT reading for gemini, from an `acpx sessions show --format
# json` record on stdin: the model the session reports (acpx `current_model_id`, or a `model` config
# option) and any SAVED model preference acpx would replay onto a replacement session must be the
# policy's model. The thinking level is NOT observable here — gemini's ACP surface has no control for
# it, it is bound by the isolated settings.json, and that is read back by `settings-effort` after the
# turn — so this check says so instead of pretending to match it. Like the codex reading it is
# necessary and NOT sufficient: the post-turn attestation is what gates.
# Exit 0 match | 20 mismatch | 21 undecidable (no model reported is never "it matched").
gemini_policy_check() {
  local pol m obs cur des
  pol="$(policy_for gemini "$1")" || return 21
  m="${pol%%$'\t'*}"
  obs="$(python3 -c '
import json,sys
try: r=json.load(sys.stdin)
except Exception: print("BAD\t"); sys.exit(0)
ax=r.get("acpx") if isinstance(r,dict) else None
ax=ax if isinstance(ax,dict) else {}
cur=ax.get("current_model_id")
for o in ax.get("config_options") or []:
    if isinstance(o,dict) and str(o.get("id"))=="model" and cur is None: cur=o.get("currentValue")
so=ax.get("session_options")
des=so.get("model") if isinstance(so,dict) else None
print("%s\t%s" % ("" if cur is None else cur, "" if des is None else des))
' 2>/dev/null)" || { echo "undecidable: could not parse the session record" >&2; return 21; }
  cur="$(printf '%s' "$obs" | cut -f1)"; des="$(printf '%s' "$obs" | cut -f2)"
  if [ "$cur" = BAD ]; then echo "undecidable: could not parse the session record" >&2; return 21; fi
  if [ -n "$des" ] && [ "$des" != "$m" ]; then
    printf 'a saved model preference (%s) conflicts with the policy and would be replayed onto a replacement session\n' "$des"; return 20
  fi
  [ -n "$cur" ] || { printf 'undecidable: the session reports no current model\n'; return 21; }
  if [ "$cur" != "$m" ]; then printf 'want model=%s; the session reports model=%s\n' "$m" "$cur"; return 20; fi
  printf 'model=%s (thinking level is bound by the isolated settings, read back after the turn)\n' "$cur"
}

# gemini_settings_effort <settings.json> — the thinking level the isolated settings.json will make the
# CLI send, as the policy's effort token: `low|medium|high`, or `default` when it carries no override.
# Read back with the same vocabulary gemini_config_for writes, so the post-turn attestation compares
# like with like. Anything it cannot read or does not recognise prints nothing and fails.
gemini_settings_effort() {
  python3 - "$1" <<'GSE' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    name=d["model"]["name"]
    ovs=(d.get("modelConfigs") or {}).get("customOverrides") or []
    lv=[]
    for o in ovs:
        if isinstance(o,dict) and (o.get("match") or {}).get("model")==name:
            t=o["modelConfig"]["generateContentConfig"]["thinkingConfig"]["thinkingLevel"]
            lv.append(t)
    if len(lv)>1: sys.exit(1)
    if not lv: print("default")
    else:
        v={"LOW":"low","MEDIUM":"medium","HIGH":"high"}.get(lv[0])
        if v is None: sys.exit(1)
        print(v)
except Exception:
    sys.exit(1)
GSE
}

# grok_isolated_config <operator config.toml> — the config a mounted grok turn runs on. The operator's
# own config.toml is NOT copied: it can carry `permission_mode = "always-approve"`, custom model entries
# with API keys, hooks and MCP servers — exactly what isolation excludes. Only the review's depth crosses
# (the default model and reasoning effort), each as ONE allowlisted token, so a mounted review runs the
# model the operator chose rather than whatever the CLI now defaults to.
grok_isolated_config() {
  local src="$1" model="" effort=""
  if [ -f "$src" ] && [ ! -L "$src" ]; then
    model="$(awk '/^[[:space:]]*\[/ { t = $0; gsub(/[[:space:]]/, "", t); in_m = (t == "[models]"); next }
      in_m && /^[[:space:]]*default[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/^"|"[[:space:]]*(#.*)?$/, "", v); print v; exit }' "$src" 2>/dev/null)"
    effort="$(awk '/^[[:space:]]*\[/ { t = $0; gsub(/[[:space:]]/, "", t); in_m = (t == "[models]"); next }
      in_m && /^[[:space:]]*default_reasoning_effort[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/^"|"[[:space:]]*(#.*)?$/, "", v); print v; exit }' "$src" 2>/dev/null)"
  fi
  case "$model" in ""|*[!A-Za-z0-9._:/-]*) model="" ;; esac
  case "$effort" in ""|*[!A-Za-z0-9._-]*) effort="" ;; esac
  printf '# agent-comms isolated grok home: the operator config is not read here\n[cli]\nuse_leader = false\n'
  if [ -n "$model" ] || [ -n "$effort" ]; then
    printf '\n[models]\n'
    [ -z "$model" ] || printf 'default = "%s"\n' "$model"
    [ -z "$effort" ] || printf 'default_reasoning_effort = "%s"\n' "$effort"
  fi
}

# containment_for <agent> — what contains a MOUNTED review of that agent on this host, as prose, with
# the exit status the `containment` subcommand returns: 0 contained, 1 no backend exists, 3 a backend
# exists but cannot run here. The runner and `doctor` both read this, so they cannot disagree.
containment_for() {
  local out rc=0
  case "$1" in
    codex)  echo "codex-home+read-only (the adapter's own kernel sandbox)"; return 0 ;;
    claude) echo "claude-plan (in-process mode pin; network open)"; return 0 ;;
    gemini) echo "gemini-plan (in-process mode pin; network open)"; return 0 ;;
    grok)
      out="$(comms_box supports grok 2>&1)" || rc=$?
      if [ "$rc" = 0 ]; then echo "grok-seatbelt (kernel sandbox around the CLI; acpx terminal and fs disabled)"; return 0; fi
      printf '%s\n' "$out" | tail -1; return "$rc" ;;
  esac
  echo "no containment backend is implemented for '$1'"; return 1
}

# grok_stage_auth <auth.json> [refresh] — the login a mounted grok turn runs on, printed to stdout.
# TWO things change on the way in, both on purpose:
#   * the REFRESH TOKEN is dropped. The staged copy lives in a home the reviewer can read, and a refresh
#     done there would ROTATE the token and strand the operator's own login (the source is never written
#     back). Without it the copy can only be used until its access token expires, and cannot mint more.
#   * an access token that is expired or within 10 minutes of expiry is refused (exit 4) rather than
#     staged: the turn would die mid-review on a login nobody can renew from inside the box. With the
#     `refresh` argument the operator's OWN grok is first run once, outside any reviewer (`grok models`,
#     which renews a login as a side effect), and the file is re-read.
# Exit 0 staged, 1 unreadable or not JSON, 4 expired. Reads nothing but the one file.
grok_stage_auth() {
  python3 - "$1" "${2:-}" <<'GSA'
import datetime, json, os, shutil, subprocess, sys

path, refresh = sys.argv[1], sys.argv[2] == "refresh"

def load():
    with open(path) as f:
        return json.load(f)

def soonest(doc):
    best = None
    for v in doc.values():
        if not isinstance(v, dict) or "expires_at" not in v:
            continue
        try:
            t = datetime.datetime.fromisoformat(str(v["expires_at"]).replace("Z", "+00:00"))
        except ValueError:
            continue
        if t.tzinfo is None:
            t = t.replace(tzinfo=datetime.timezone.utc)
        best = t if best is None or t < best else best
    return best

def stale(doc):
    t = soonest(doc)
    return t is not None and t < datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10)

try:
    doc = load()
    if not isinstance(doc, dict):
        raise ValueError("not an object")
    if stale(doc) and refresh and shutil.which("grok"):
        try:
            subprocess.run(["grok", "models"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=45)
        except (subprocess.TimeoutExpired, OSError):
            pass
        doc = load()
except (OSError, ValueError):
    sys.exit(1)

if stale(doc):
    sys.exit(4)

def strip(x):
    if isinstance(x, dict):
        return {k: strip(v) for k, v in x.items() if k != "refresh_token"}
    return x

json.dump(strip(doc), sys.stdout)
GSA
}

# gemini_settings_auth <settings.json> — the operator's selected auth type (`security.auth.selectedType`)
# as ONE bare token, or nothing. The only part of their settings that crosses into a review home.
gemini_settings_auth() {
  python3 - "$1" <<'GSA' 2>/dev/null
import json,re,sys

def strip_comments(t):
    """Drop // and /* */ comments outside strings: the dialect the CLI's own settings loader accepts."""
    out, i, n, q = [], 0, len(t), False
    while i < n:
        c = t[i]
        if q:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(t[i + 1]); i += 1
            elif c == '"':
                q = False
        elif c == '"':
            q = True; out.append(c)
        elif t.startswith("//", i):
            while i < n and t[i] not in "\r\n": i += 1
            continue
        elif t.startswith("/*", i):
            j = t.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)

try:
    with open(sys.argv[1], encoding="utf-8-sig") as fh:
        v = json.loads(strip_comments(fh.read()))["security"]["auth"]["selectedType"]
    if isinstance(v, str) and re.fullmatch(r"[a-z][a-z0-9-]*", v): print(v)
except Exception:
    pass
GSA
}

# failure_reason <provider> <stderr-file> — classify a provider's REFUSAL of a turn from the diagnostics
# acpx relayed, for providers whose refusals have a stable wording. Prints `rate-limited` or
# `auth-failed` (the former wins when both match: a 429 body can mention credentials), else nothing.
# Matched case-insensitively against the STDERR file only — never a reply, which may legitimately
# discuss a 429 — and only the gemini wording is known (its ACP agent surfaces the API's own status
# and gRPC code names: 429 / RESOURCE_EXHAUSTED; 401 / UNAUTHENTICATED; "Authentication required").
ACP_GEMINI_RATE_RE='rate[ _-]?limit|resource_exhausted|too many requests|quota (has been )?(exceeded|exhausted)|exhausted your capacity|(^|[^0-9])429([^0-9]|$)'
ACP_GEMINI_AUTH_RE='unauthenticated|api key is (missing|not configured)|authentication (is )?(required|failed)|not (logged|signed) in|log ?in (is )?required|invalid (api )?key|api key not valid|api_key_invalid|unauthori[sz]ed|(^|[^0-9])401([^0-9]|$)|please set an auth|no auth method|oauth.*(expired|invalid|revoked)|credentials? (expired|invalid|not found)'
failure_reason() {
  [ "$1" = gemini ] && [ -f "$2" ] || return 0
  if grep -Eiq "$ACP_GEMINI_RATE_RE" "$2"; then printf 'rate-limited\n'
  elif grep -Eiq "$ACP_GEMINI_AUTH_RE" "$2"; then printf 'auth-failed\n'; fi
  return 0
}

cmd_resolve() {
  local agent="${1:-}"; [ -n "$agent" ] || { echo "acp.sh: resolve: an agent name is required" >&2; exit 2; }
  shift
  [ -n "$(profile_for "$agent")" ] || { echo "acp.sh: resolve: unknown agent '$agent'" >&2; exit 2; }
  local transport=acp-mounted tier=none effort=none decision=none routing=off phase=- csrc=none
  local bmodel="" beffort="" broute="" bdigest="" bcustom=0 routed_given=0
  while [ "$#" -gt 0 ]; do
    [ "$1" != --custom-profile ] || { bcustom=1; shift; continue; }
    [ "$#" -ge 2 ] || { echo "acp.sh: resolve: $1 needs a value" >&2; exit 2; }
    case "$1" in
      --transport) transport="$2" ;;
      --tier)      tier="$2"; routed_given=1 ;;
      --effort)    effort="$2"; routed_given=1 ;;
      --decision)  decision="$2"; routed_given=1 ;;
      --routing)   routing="$2"; routed_given=1 ;;
      --phase)     phase="$2" ;;
      --candidate-source) csrc="$2"; routed_given=1 ;;
      --bound-model)  bmodel="$2" ;;
      --bound-effort) beffort="$2" ;;
      --route-id)     broute="$2" ;;
      --access-digest) bdigest="$2" ;;
      *) echo "acp.sh: resolve: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift 2
  done
  if [ -n "$bmodel$beffort$broute$bdigest" ] || [ "$bcustom" = 1 ]; then
    # BOUND MODE: the caller's exact pair. A routing candidate beside it would be a second source of the
    # pair, so the combination is a usage error rather than something to rank.
    [ -n "$bmodel" ] && [ -n "$beffort" ] && [ -n "$broute" ] && [ -n "$bdigest" ] \
      || { echo "acp.sh: resolve: --bound-model, --bound-effort, --route-id and --access-digest go together" >&2; exit 2; }
    [ "$routed_given" = 0 ] || { echo "acp.sh: resolve: a bound resolution takes no tier, effort, decision, routing or candidate source" >&2; exit 2; }
    [ "$transport" = acp-mounted ] || { echo "acp.sh: resolve: a bound resolution is for a mounted ACP turn" >&2; exit 2; }
    [[ "$bmodel" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,255}$ ]] || { echo "acp.sh: resolve: bound model '$bmodel' is not a bare token" >&2; exit 2; }
    [ "$beffort" = - ] || [[ "$beffort" =~ $ACP_POLICY_RE ]] || { echo "acp.sh: resolve: bound effort '$beffort' is not a bare token" >&2; exit 2; }
    [[ "$broute" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "acp.sh: resolve: route id '$broute' is not a bare token" >&2; exit 2; }
    [[ "$bdigest" =~ ^[0-9a-f]{64}$ ]] || { echo "acp.sh: resolve: access digest is not a sha256" >&2; exit 2; }
    [ "$phase" = - ] || [[ "$phase" =~ $ACP_POLICY_RE ]] || { echo "acp.sh: resolve: phase '$phase' is not a bare token" >&2; exit 2; }
    case "$agent" in
      codex|gemini) [ "$bcustom" = 0 ] || { echo "acp.sh: resolve: --custom-profile is for an operator profile, not '$agent'" >&2; exit 2; }
                    resolve_bound "$agent" "$transport" "$bmodel" "$beffort" "$broute" "$bdigest" "$phase" || exit 1 ;;
      claude|grok)  bound_refuse capability-unsupported "'$agent' applies and attests no model or effort policy, so nothing can be bound"; exit 1 ;;
      *) [ "$bcustom" = 1 ] || { echo "acp.sh: resolve: a custom profile binds through --custom-profile" >&2; exit 2; }
         resolve_bound_custom "$agent" "$transport" "$bmodel" "$beffort" "$broute" "$bdigest" "$phase" || exit 1 ;;
    esac
    emit_policy_record
    return 0
  fi
  # Closed vocabularies. A value outside them is a CALLER defect, reported as usage — never
  # quietly read as `none`, which would turn a typo into a baseline turn nobody asked for.
  # `mailbox` is a leg nobody drives: no turn runs, so nothing is applied (no capability row can
  # exist for it). It is accepted so a PLANNED mailbox leg resolves to that honest answer.
  case "$transport" in acp-mounted|acp|headless|mailbox) ;; *) echo "acp.sh: resolve: unknown transport '$transport'" >&2; exit 2 ;; esac
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

# THE ROUTE VIEW — what a spend planner needs from a resolved policy record, as ONE field list
# shared by `comms.sh review-route plan` (one line per planned leg) and runphase (result.json
# "route"), so the plan and the turn cannot describe a leg in different words. `provider` is not a
# field: both consumers carry it (with the agent) beside the view, and result.json already has it.
ACP_ROUTE_FIELDS="transport capability model effort limit_id model_source effort_source routing decision phase map_version"
# Every value is a bare token (or `-`, `n/a`): it is printed unquoted in a key=value line and
# embedded in JSON, so anything else refuses the view rather than being escaped into it.
ACP_ROUTE_VALUE_RE='^([A-Za-z0-9][A-Za-z0-9._/:@+-]*|-)$'
cmd_route_view() {  # route-view <agent> <record-file|-> [--format line|json]
  local agent="${1:-}" src="${2:-}" fmt=line
  [ -n "$agent" ] && [ -n "$src" ] || { echo "acp.sh: route-view: usage: route-view <agent> <record-file|-> [--format line|json]" >&2; exit 2; }
  shift 2
  if [ "$#" -gt 0 ]; then
    [ "$#" = 2 ] && [ "$1" = --format ] || { echo "acp.sh: route-view: unknown option '$1'" >&2; exit 2; }
    case "$2" in line|json) fmt="$2" ;; *) echo "acp.sh: route-view: --format must be line or json" >&2; exit 2 ;; esac
  fi
  [ "$src" = - ] || [ -f "$src" ] || { echo "acp.sh: route-view: no such record '$src'" >&2; exit 1; }
  # Same reading rule as policy_from_record: every key exactly once, or the record is refused.
  awk -F'\t' -v fields="$ACP_ROUTE_FIELDS" -v agent="$agent" -v fmt="$fmt" -v vre="$ACP_ROUTE_VALUE_RE" \
      -v want="$ACP_POLICY_RECORD_VERSION" -v wantb="$ACP_POLICY_RECORD_VERSION_BOUND" '
    { sub(/\r$/, "") }
    NF != 2 || $1 == "" || $2 == "" { bad = 1; next }
    { n[$1]++; v[$1] = $2 }
    END {
      for (k in n) if (n[k] != 1) bad = 1
      hasb = (("route_id" in n) && ("access_digest" in n) && ("bound" in n))
      anyb = (("route_id" in n) || ("access_digest" in n) || ("bound" in n))
      if (v["policy_record"] == want && anyb) bad = 1
      if (v["policy_record"] == wantb && !hasb) bad = 1
      if (bad || (v["policy_record"] != want && v["policy_record"] != wantb) || v["provider"] != agent) exit 1
      nf = split(fields, F, " ")
      # Route-view fields version 2: a bound record also names its route and the digest of its access profile.
      if (v["policy_record"] == wantb) { F[++nf] = "route_id"; F[++nf] = "access_digest" }
      for (i = 1; i <= nf; i++) if (n[F[i]] != 1 || v[F[i]] !~ vre) exit 1
      if (fmt == "json") printf "{"
      for (i = 1; i <= nf; i++) {
        if (fmt == "json") printf "%s\"%s\": \"%s\"", (i > 1 ? ", " : ""), F[i], v[F[i]]
        else printf "%s%s=%s", (i > 1 ? " " : ""), F[i], v[F[i]]
      }
      printf (fmt == "json" ? "}\n" : "\n")
    }' "$src" \
    || { echo "acp.sh: route-view: the policy record is malformed or is not for '$agent'" >&2; exit 1; }
}

cmd_capabilities() {
  local ver; ver="$(policy_map_check)" || exit 1
  printf 'map_version: %s (%s)\n' "$ver" "$ACP_POLICY_MAP"
  RT_PATH=bundled; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""; policy_runtime_codex
  printf 'reviewer codex runtime: %s (version %s)%s\n' "$RT_PATH" "$RT_VERSION" "${RT_ERR:+ — REFUSED: $RT_ERR}"
  policy_runtime_gemini_review
  printf 'reviewer gemini runtime: %s (version %s)%s\n' "${RT_PATH:-none}" "$RT_VERSION" "${RT_ERR:+ — REFUSED: $RT_ERR}"
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
    $1 == "pair"     && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s %s accepts: %s%s\n", $2, $3, $4, $5, (NF == 6 ? " (needs " $2 " >= " $6 ")" : ""); next }
    $1 == "limit"    && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s %s spends its own usage limit: %s\n", $2, $3, $4, $5; next }
    $1 == "disabled" && cap[$2 SUBSEP $3] != "unsupported" { printf "  %s/%s %s is DISABLED: %s\n", $2, $3, $4, $5; next }' "$ACP_POLICY_MAP" "$ACP_POLICY_MAP"
}

# THE RUNTIME'S STANDING: can the codex runtime already probed into RT_PATH/RT_VERSION run the review
# a turn gets with no route — the map's baseline, and the "use max" ceiling — each with the
# operator's model pin applied, as resolve would? No version literal: each minimum is the model's
# `pair` row. Prints one line per row to stdout:
#   <baseline|ceiling>\t<model>\t<baseline|max|pin>\t<minimum|->\t<ok|refused>\t<reason|->
# and returns 0 when every row is ok, 4 when any is refused, 1 on a map defect. A map with no
# ceiling row prints no ceiling line. Shared by `runtime-check` (machine-readable) and `doctor`.
policy_runtime_standing() {  # <agent> <transport>
  local agent="$1" transport="$2" row kind m e src esrc min why rc=0 pm pe mapv pv
  mapv="$(policy_map_check)" || return 1
  pm="$(policy_pin_model "$agent")"; pe="$(policy_pin_effort "$agent")"
  for kind in baseline ceiling; do
    row="$(policy_map_get "$kind" "$agent" "$transport")"
    if [ -z "$row" ]; then
      [ "$kind" = ceiling ] && continue
      echo "acp.sh: the map has no baseline for $agent/$transport" >&2; return 1
    fi
    m="${row%%$'\t'*}"; e="${row#*$'\t'}"; src="$( [ "$kind" = baseline ] && echo baseline || echo max )"; esrc="$src"
    if [ -n "$pm" ]; then m="$pm"; src=pin; fi
    if [ -n "$pe" ]; then e="$pe"; esrc=pin; fi
    min="$(policy_map_get pairmin "$agent" "$transport" "$m")"
    # The same two judgements resolve makes, in its order: the (model, effort) pair, then the runtime.
    if ! pv="$(policy_pair_verdict "$agent" "$transport" "$m" "$src" "$e" "$esrc")"; then
      printf '%s\t%s\t%s\t%s\trefused\t%s\n' "$kind" "$m" "$src" "${min:--}" \
        "$(policy_pair_refusal "$pv" "$m" "$src" "$e" "$esrc" "$mapv")"; rc=4
    elif why="$(policy_unservable_reason "$agent" "$transport" "$m" "$src")"; then
      printf '%s\t%s\t%s\t%s\tok\t-\n' "$kind" "$m" "$src" "${min:--}"
    else
      printf '%s\t%s\t%s\t%s\trefused\t%s\n' "$kind" "$m" "$src" "${min:--}" "$why"; rc=4
    fi
  done
  return "$rc"
}

cmd_runtime_check() {  # runtime-check <agent>
  local agent="${1:-}"
  { [ "$#" = 1 ] && { [ "$agent" = codex ] || [ "$agent" = gemini ]; }; } \
    || { echo "acp.sh: runtime-check: usage: runtime-check codex|gemini (only codex and gemini reviewers have a runtime)" >&2; exit 2; }
  policy_runtime_for "$agent"
  # A gemini that is found but too old still REPORTS what it is before it is refused: the version is
  # the evidence for the refusal. (An absent one has nothing to report.)
  if [ "$agent" = gemini ] && [ -n "$RT_PATH" ]; then printf 'runtime\t%s\nruntime_version\t%s\n' "$RT_PATH" "$RT_VERSION"; fi
  [ -z "$RT_ERR" ] || { echo "acp.sh: runtime-check: $RT_ERR" >&2; exit 1; }
  [ "$agent" = gemini ] || printf 'runtime\t%s\nruntime_version\t%s\n' "$RT_PATH" "$RT_VERSION"
  local rc=0; policy_runtime_standing "$agent" acp-mounted || rc=$?
  exit "$rc"
}

# doctor_standing <agent> — one line per baseline/ceiling row of the reviewer policy on the runtime
# already probed into RT_PATH/RT_VERSION, setting the caller's `fail` when a row cannot run. The ONE
# loop behind doctor's codex and gemini lines, so neither can report a runtime the other's rule refuses.
doctor_standing() {
  local st srs=0 k m src min ok why label noun="$1"
  st="$(policy_runtime_standing "$1" acp-mounted)" || srs=$?
  [ "$srs" = 0 ] || [ "$srs" = 4 ] || { echo "reviewer policy: the map is unreadable — no $noun review can resolve"; fail=1; }
  while IFS=$'\t' read -r k m src min ok why; do
    [ -n "$k" ] || continue
    label="default $noun review"; [ "$k" = ceiling ] && label="use-max $noun review (COMMS_REVIEW_MAX=1)"
    if [ "$ok" = ok ]; then echo "$label: $m ($src) — runs on this runtime"
    else echo "$label: $m ($src) — CANNOT RUN: $why"; fail=1; fi
  done <<< "$st"
}

cmd_doctor() {
  local a p fail=0
  if node_ok; then
    echo "node: $(node --version) (>= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR})"
  else
    echo "node: MISSING or too old ($(node --version 2>/dev/null || echo none)) — consults unavailable"
    exit 3
  fi
  echo "acpx: pinned @$ACPX_VERSION via npx (cached after first use)"
  echo "agents: codex claude grok gemini supported ($(for a in codex claude grok gemini; do printf '%s=%s ' "$a" "$(profile_for "$a")"; done))"
  # Which codex a MOUNTED reviewer will run, and so which mapped models it can serve.
  RT_PATH=bundled; RT_VERSION=unknown; RT_ERR=""; RT_NOTE=""; policy_runtime_codex
  # And whether it can run the review a turn gets by default (and under "use max"): a baseline or
  # ceiling model that needs a newer codex is REFUSED by resolve, never downgraded, so doctor fails
  # (exit 4) rather than report a runtime every default codex review would be refused on.
  if [ -n "$RT_ERR" ]; then echo "reviewer codex runtime: REFUSED — $RT_ERR"; fail=1
  else
    echo "reviewer codex runtime: $RT_PATH (version $RT_VERSION)$( [ "$RT_PATH" = bundled ] && printf ' — the ACP adapter'"'"'s own copy: a mapped model with a minimum runtime cannot run on it (a routed tier falls to its next model)')"
    doctor_standing codex
  fi
  # The Gemini CLI is an OPT-IN reviewer: absent is a report, not a failure (most installs have none),
  # but one that is present and cannot run `--acp` fails like a codex runtime that cannot run its review.
  policy_runtime_gemini_review
  if [ -n "$RT_ERR" ] && [ "$RT_ERR" = "the gemini CLI was not found on PATH" ]; then echo "reviewer gemini runtime: not installed — gemini reviews unavailable (optional; install the Gemini CLI >= $ACP_GEMINI_MIN_VERSION to use gemini)"
  elif [ -n "$RT_ERR" ]; then echo "reviewer gemini runtime: ${RT_PATH:-none} (version $RT_VERSION) — REFUSED: $RT_ERR"; fail=1
  else
    echo "reviewer gemini runtime: $RT_PATH (version $RT_VERSION) — supports --acp"
    doctor_standing gemini
  fi
  # Containment of a MOUNTED review, per reviewer. A report, not a failure: an agent you do not use
  # being uncontainable here costs nothing, and the refusal at send time names the same reason.
  local c_out c_rc
  for a in codex claude gemini grok; do
    c_rc=0; c_out="$(containment_for "$a" 2>&1)" || c_rc=$?
    if [ "$c_rc" = 0 ]; then echo "reviewer $a containment: $c_out"
    else echo "reviewer $a containment: UNAVAILABLE — $c_out; mounted $a reviews are refused here"; fi
  done
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
  if [ "$fail" = 1 ]; then
    echo "result: FAIL — a review above cannot run on its reviewer runtime (exit 4)"
    exit 4
  fi
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
  # gemini has no bundled copy: a consult needs a Gemini CLI that has `--acp`, and says so otherwise.
  if [ "$agent" = gemini ]; then policy_runtime_gemini; [ -z "$RT_ERR" ] || die_fb "consult: $RT_ERR"; fi
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
  local custom_binding="" custom_home="" profile_py="$(dirname "${BASH_SOURCE[0]}")/agent_profiles.py"
  if [ "$profile" = agent-comms-custom ]; then
    custom_binding="$(comms_sibling agents --profile "$agent")" || die_fb "custom agent profile is unavailable"
    custom_home="$(python3 "$profile_py" state-home "$custom_binding")" || die_fb "custom agent state is unavailable"
    ACP_SESSION_NAME="$ACP_SESSION_NAME+as+$agent+p$(python3 "$profile_py" binding-field "$custom_binding" digest)"
    launcher=(python3 "$profile_py" acpx "$custom_binding" "$custom_home" "${launcher[@]}" --)
    # A pinned profile needs a named record so we can inspect the applied model before and after.
    if [ "$oneshot" = true ]; then ACP_SESSION_NAME="$ACP_SESSION_NAME+oneoff+$$-$RANDOM"; oneshot=false; fi
  fi
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
      if [ -n "$custom_binding" ]; then
        "${launcher[@]}" --format json --timeout "$consult_timeout" "$profile" sessions show "$ACP_SESSION_NAME" \
          | python3 "$profile_py" model-check "$custom_binding" >/dev/null \
          || die_fb "consult: ACP did not confirm the configured model"
      fi
      if [ -n "$qfile" ]; then
        out="$("${base[@]}" -s "$ACP_SESSION_NAME" --file "$qfile" ${words[@]+"${words[@]}"})" || rc=$?
      else
        out="$("${base[@]}" -s "$ACP_SESSION_NAME" "${words[@]}")" || rc=$?
      fi
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -n "$custom_binding" ]; then
    "${launcher[@]}" --format json --timeout "$consult_timeout" "$profile" sessions show "$ACP_SESSION_NAME" \
      | python3 "$profile_py" model-check "$custom_binding" >/dev/null \
      || die_fb "consult: ACP model changed or could not be confirmed after the turn"
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
  version) acpx_version_for "${2:-}"; printf '\n' ;;
  resolve) shift; cmd_resolve "$@" ;;
  runtime-check) shift; cmd_runtime_check "$@" ;;
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
  failure-reason)
    # failure-reason <provider> <stderr-file> — `rate-limited` | `auth-failed` | nothing (exit 0 always).
    shift; [ "$#" = 2 ] || die "failure-reason: usage: failure-reason <provider> <stderr-file>"
    failure_reason "$1" "$2"
    ;;
  gemini-auth)
    # gemini-auth <settings.json> — the operator's selected auth type, allowlisted; empty when none.
    shift; [ -n "${1:-}" ] || die "gemini-auth: a settings.json path is required"
    gemini_settings_auth "$1"
    ;;
  grok-auth)
    shift; [ -n "${1:-}" ] || die "grok-auth: an auth.json path is required"
    grok_stage_auth "$1" "${2:-}"
    ;;
  grok-config)
    shift; [ -n "${1:-}" ] || die "grok-config: a config.toml path is required"
    grok_isolated_config "$1"
    ;;
  containment)
    shift; [ -n "${1:-}" ] || die "containment: an agent name is required"
    _ct_rc=0; _ct_out="$(containment_for "$1" 2>&1)" || _ct_rc=$?
    if [ "$_ct_rc" = 0 ]; then printf 'backend\t%s\n' "$_ct_out"; else printf '%s\n' "$_ct_out" >&2; exit "$_ct_rc"; fi
    ;;
  gemini-effort)
    # gemini-effort <settings.json> — the thinking level a mounted gemini turn's isolated settings
    # carry, as a policy effort token. runphase attests with it after the turn.
    shift; [ -n "${1:-}" ] || die "gemini-effort: a settings.json path is required"
    gemini_settings_effort "$1" || exit 1
    ;;
  route-view) shift; cmd_route_view "$@" ;;
  policy)
    shift; policy_args "$@"
    [ -n "${PA_POS[0]:-}" ] || die "policy: an agent name is required"
    policy_for "${PA_POS[0]}" "$PA_FILE" || exit 1
    ;;
  provider-config)
    shift; policy_args "$@"
    [ -n "${PA_POS[0]:-}" ] || die "provider-config: an agent name is required"
    provider_config_for "${PA_POS[0]}" "$PA_FILE" "${PA_AUTH:--}" || exit 1
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
    if [ "$_pc_agent" = gemini ]; then gemini_policy_check "$PA_FILE"; exit $?; fi
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
  launcher) acpx_prepare_cache; acpx_launcher "${2:-}"; printf '\n' ;;
  supports)
    # supports <agent> — exit 0 iff a consult can actually run here for that
    # agent. Machine-readable on purpose: callers must never parse doctor's prose.
    shift
    [ -n "${1:-}" ] || die "supports: an agent name is required"
    [ -n "$(profile_for "$1")" ] || exit 1
    node_ok || exit 1
    # gemini has no bundled copy: it runs only where a Gemini CLI with `--acp` is on PATH.
    if [ "$1" = gemini ]; then policy_runtime_gemini; [ -z "$RT_ERR" ] || exit 1; fi
    ;;
  ""|help|-h|--help)
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
    ;;
  *) die "unknown subcommand '${1}' — run 'acp.sh help'" ;;
esac
