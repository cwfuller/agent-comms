# Run through tests/run.sh; each group gets fresh fixtures.
# The suite must never call TypeSafe. Every live-shaped path is a stub or a
# fail-open (no key, disabled, missing helper, bad body).

rt() {
  # Always seed one assignment so bash 3.2 + set -u never sees an empty array.
  local envvars=("COMMS_DELIVERY=mailbox")
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) envvars+=("$1"); shift ;;
      *) break ;;
    esac
  done
  (cd "$REPO_FIX" && env -u TYPESAFE_API_KEY -u COMMS_ROUTE -u COMMS_ROUTE_STUB \
    -u COMMS_ROUTE_URL -u COMMS_ROUTE_MODEL -u COMMS_ROUTE_TIMEOUT_SECS \
    -u COMMS_ROUTE_BACKEND -u COMMS_ROUTE_CURRENT_TIER -u COMMS_ROUTE_CONTEXT_TOKENS \
    "${envvars[@]}" "$COMMS" route "$@")
}

rt_kv() { printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1; }

rt_stub() { # write a canned System One body: noul level cconf effort econf
  local noul="$1" level="$2" cconf="$3" effort="$4" econf="$5" dest="$6"
  python3 - "$noul" "$level" "$cconf" "$effort" "$econf" "$dest" <<'PY'
import json, sys
noul, level, cconf, effort, econf, dest = sys.argv[1:7]
probs = {"0": 0.0, "1": 0.0, "2": 0.0, "3": 0.0}
probs[level] = 1.0
eprobs = {"low": 0.0, "medium": 0.0, "high": 0.0, "xhigh": 0.0}
eprobs[effort] = 1.0
body = {
    "model": "jev-latest",
    "answers": {
        "needs_plan": {"type": "noul", "noul": float(noul)},
        "complexity": {
            "type": "score",
            "score": float(level),
            "legend": {"0": "m", "1": "s", "2": "h", "3": "a"},
            "probabilities": probs,
            "confidence": float(cconf),
        },
        "effort": {
            "type": "choice",
            "choice": effort,
            "probabilities": eprobs,
            "confidence": float(econf),
        },
    },
    "usage": {"input_tokens": 1, "output_tokens": 1},
}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(body, fh)
PY
}

ST="$WORK/route-stubs"; mkdir -p "$ST"

section "comms.sh: route fail-open"
OUT="$(rt -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && [ "$(rt_kv "$OUT" effort)" = "medium" ] && [ "$(rt_kv "$OUT" tier)" = "balanced" ] \
  && ok "no key fail-opens to plan=no effort=medium" || fail "no key fail-open (rc=$rc out=$OUT)"

rt_stub 0.99 3 0.99 xhigh 0.99 "$ST/would-plan.json"
OUT="$(rt COMMS_ROUTE=0 COMMS_ROUTE_STUB="$ST/would-plan.json" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "disabled" ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && ok "COMMS_ROUTE=0 disables even when a stub would request plan" || fail "COMMS_ROUTE=0 (rc=$rc out=$OUT)"

rt -- >/dev/null 2>&1 </dev/null && rc=0 || rc=$?
[ "$rc" -eq 2 ] && ok "empty task is a usage error" || fail "empty task rc=$rc (want 2)"

rt --current-tier high -- "rename a typo" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 2 ] && ok "invalid --current-tier is a usage error" || fail "invalid CLI tier rc=$rc (want 2)"

NPY="$WORK/nopython"; mkdir -p "$NPY"
# Keep the shell utilities cmd_route / fail_open need, and provide a stub so we
# pass the key check — otherwise PATH=empty fail-opens as missing-sibling or
# missing-key and never exercises command -v python3.
for _t in dirname tr cat bash awk sed; do
  _src="$(command -v "$_t" 2>/dev/null)" || continue
  ln -s "$_src" "$NPY/$_t"
done
rt_stub 0.91 3 0.92 high 0.81 "$ST/py-mask.json"
OUT="$(rt PATH="$NPY" COMMS_ROUTE_STUB="$ST/py-mask.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && printf '%s\n' "$OUT" | grep -q 'python3' \
  && ok "missing python3 fail-opens" || fail "missing python3 (rc=$rc out=$OUT)"

BARE="$WORK/bare-comms"; mkdir -p "$BARE"
cp "$COMMS" "$BARE/comms.sh"; chmod +x "$BARE/comms.sh"
OUT="$(env -u TYPESAFE_API_KEY COMMS_DELIVERY=mailbox "$BARE/comms.sh" route -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
keys="$(printf '%s\n' "$OUT" | awk -F': ' '{print $1}' | paste -sd, -)"
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && [ "$keys" = "plan,effort,complexity,tier,gate,plan_p,effort_p,complexity_confidence,source,reason" ] \
  && ok "comms.sh without sibling route.sh fail-opens" || fail "missing sibling (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/missing.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && ok "missing stub file fail-opens" || fail "missing stub (rc=$rc out=$OUT)"

OUT="$(rt -- "rename a typo" 2>/dev/null)"
keys="$(printf '%s\n' "$OUT" | awk -F': ' '{print $1}' | paste -sd, -)"
[ "$keys" = "plan,effort,complexity,tier,gate,plan_p,effort_p,complexity_confidence,source,reason" ] \
  && ok "fail-open emits the stable key set" || fail "key set ($keys)"

OUT="$(rt TYPESAFE_API_KEY=fake COMMS_ROUTE_URL="http://127.0.0.1:1" \
  COMMS_ROUTE_TIMEOUT_SECS=1 -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && printf '%s\n' "$OUT" | grep -q 'no decision backend enabled' \
  && ok "a TypeSafe key does not enable the backend by itself" || fail "key-not-enable (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_BACKEND=nope COMMS_ROUTE_STUB="$ST/would-plan.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && printf '%s\n' "$OUT" | grep -q 'unknown decision backend' \
  && ok "unknown COMMS_ROUTE_BACKEND fail-opens" || fail "unknown backend (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_BACKEND=typesafe -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && printf '%s\n' "$OUT" | grep -q 'TYPESAFE_API_KEY' \
  && ok "typesafe backend without a key fail-opens" || fail "typesafe no-key (rc=$rc out=$OUT)"

section "comms.sh: route policy"
rt_stub 0.91 3 0.92 high 0.81 "$ST/arch.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" COMMS_ROUTE_URL="http://127.0.0.1:1" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "yes" ] && [ "$(rt_kv "$OUT" complexity)" = "architectural" ] \
  && [ "$(rt_kv "$OUT" source)" = "stub" ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] \
  && ok "high noul + architectural => plan yes (source=stub)" || fail "arch plan (rc=$rc out=$OUT)"
keys="$(printf '%s\n' "$OUT" | awk -F': ' '{print $1}' | paste -sd, -)"
[ "$keys" = "plan,effort,complexity,tier,gate,plan_p,effort_p,complexity_confidence,source,reason" ] \
  && ok "stub success emits the stable key set" || fail "success key set ($keys)"

rt_stub 0.91 0 0.92 high 0.81 "$ST/mech.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] && [ "$(rt_kv "$OUT" complexity)" = "mechanical" ] \
  && [ "$(rt_kv "$OUT" tier)" = "balanced" ] \
  && ok "high noul + mechanical => plan no, tier balanced (one-step up)" || fail "mech plan (rc=$rc out=$OUT)"

rt_stub 0.20 3 0.92 high 0.81 "$ST/lownoul.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/lownoul.json" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && ok "low noul + architectural => plan no" || fail "low noul (rc=$rc out=$OUT)"

rt_stub 0.91 2 0.92 high 0.81 "$ST/hard.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/hard.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "yes" ] && [ "$(rt_kv "$OUT" complexity)" = "hard" ] \
  && [ "$(rt_kv "$OUT" tier)" = "strong" ] \
  && ok "high noul + hard => plan yes, tier strong" || fail "hard plan (rc=$rc out=$OUT)"

rt_stub 0.91 1 0.92 high 0.81 "$ST/std.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/std.json" -- "add a well-specified endpoint" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] && [ "$(rt_kv "$OUT" complexity)" = "standard" ] \
  && [ "$(rt_kv "$OUT" tier)" = "strong" ] \
  && ok "high noul + standard => plan no, tier strong (one-step up)" || fail "std plan (rc=$rc out=$OUT)"

rt_stub 0.50 2 0.92 xhigh 0.90 "$ST/xhi.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/xhi.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "xhigh" ] \
  && ok "confident xhigh effort is kept" || fail "xhigh (rc=$rc out=$OUT)"

rt_stub 0.50 2 0.92 xhigh 0.20 "$ST/xhi-low.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/xhi-low.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "high" ] && [ "$(rt_kv "$OUT" effort_p)" = "-" ] \
  && ok "low-confidence effort clamps to medium then rises to high" || fail "effort clamp (rc=$rc out=$OUT)"

rt_stub 0.50 2 0.92 high 0.70 "$ST/high.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/high.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "xhigh" ] \
  && ok "confident high effort is raised to xhigh" || fail "high effort (rc=$rc out=$OUT)"

rt_stub 0.91 3 0.20 high 0.81 "$ST/lowc.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/lowc.json" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && ok "low complexity confidence refuses plan" || fail "low cconf (rc=$rc out=$OUT)"

printf 'not-json\n' > "$ST/bad.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/bad.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && ok "malformed stub fail-opens" || fail "malformed stub (rc=$rc out=$OUT)"

printf '{"answers":{"needs_plan":{"type":"noul","noul":0.9}}}\n' > "$ST/partial.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/partial.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && ok "partial answers fail-open" || fail "partial answers (rc=$rc out=$OUT)"

echo "add a well-specified endpoint" > "$ST/task.txt"
OUT="$(rt COMMS_ROUTE_STUB="$ST/std.json" --file "$ST/task.txt" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" complexity)" = "standard" ] \
  && ok "--file reads the task" || fail "--file (rc=$rc out=$OUT)"

OUT="$(printf 'add a well-specified endpoint\n' | rt COMMS_ROUTE_STUB="$ST/std.json" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" complexity)" = "standard" ] \
  && ok "stdin reads the task" || fail "stdin (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/std.json" --task "add a well-specified endpoint" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" complexity)" = "standard" ] \
  && ok "--task reads the task" || fail "--task (rc=$rc out=$OUT)"

# A stub must win over a URL that would fail if contacted.
OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" COMMS_ROUTE_URL="http://127.0.0.1:1" \
  TYPESAFE_API_KEY="not-a-real-key" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "yes" ] && [ "$(rt_kv "$OUT" source)" = "stub" ] \
  && ok "stub is used even when a key and a dead URL are set" || fail "stub vs URL (rc=$rc out=$OUT)"

# Malformed probabilities must fail-open, not win argmax and enable plan.
python3 - "$ST/badprob.json" <<'PY'
import json, sys
body = {
    "model": "jev-latest",
    "answers": {
        "needs_plan": {"type": "noul", "noul": 0.9},
        "complexity": {
            "type": "score",
            "score": 2.0,
            "legend": {"0": "m", "1": "s", "2": "h", "3": "a"},
            "probabilities": {"0": 0.9, "1": 0.1, "2": 2, "3": 0},
            "confidence": 0.9,
        },
        "effort": {
            "type": "choice",
            "choice": "high",
            "probabilities": {"low": 0, "medium": 0, "high": 1, "xhigh": 0},
            "confidence": 0.9,
        },
    },
}
json.dump(body, open(sys.argv[1], "w"))
PY
OUT="$(rt COMMS_ROUTE_STUB="$ST/badprob.json" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && ok "out-of-range complexity probability fail-opens" || fail "badprob (rc=$rc out=$OUT)"

python3 - "$ST/infprob.json" <<'PY'
import json, sys
body = {
    "model": "jev-latest",
    "answers": {
        "needs_plan": {"type": "noul", "noul": 0.9},
        "complexity": {
            "type": "score",
            "score": 2.0,
            "legend": {"0": "m", "1": "s", "2": "h", "3": "a"},
            "probabilities": {"0": 0.9, "1": 0.1, "2": "Infinity", "3": 0},
            "confidence": 0.9,
        },
        "effort": {
            "type": "choice",
            "choice": "high",
            "probabilities": {"low": 0, "medium": 0, "high": 1, "xhigh": 0},
            "confidence": 0.9,
        },
    },
}
json.dump(body, open(sys.argv[1], "w"))
PY
OUT="$(rt COMMS_ROUTE_STUB="$ST/infprob.json" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && ok "non-finite complexity probability fail-opens" || fail "infprob (rc=$rc out=$OUT)"

# OSS-router policy: compose tier in code; low confidence → middle; prompt override;
# cache-sticky no-downgrade; optional JSONL log.
rt_stub 0.20 0 0.20 low 0.90 "$ST/mech-lowc.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/mech-lowc.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] \
  && [ "$(rt_kv "$OUT" gate)" = "low-confidence-middle" ] \
  && ok "low complexity confidence lands on strong (middle, then one-step up)" || fail "lowc middle (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" -- "use strong to rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] && [ "$(rt_kv "$OUT" gate)" = "override" ] \
  && ok "prompt 'use strong' overrides a mechanical stub" || fail "override strong (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" -- "skip plan and redesign auth" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] && [ "$(rt_kv "$OUT" gate)" = "override" ] \
  && ok "prompt 'skip plan' overrides an architectural stub" || fail "override no-plan (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" --current-tier strong --context-tokens 50000 \
  -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] && [ "$(rt_kv "$OUT" gate)" = "cache-sticky" ] \
  && ok "large-context downgrade is refused (cache-sticky)" || fail "cache sticky (rc=$rc out=$OUT)"

OUT="$(rt -- "use fast to rename this" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "override" ] && [ "$(rt_kv "$OUT" tier)" = "fast" ] \
  && ok "prompt override works with no TypeSafe key" || fail "override no-key (rc=$rc out=$OUT)"

LOG="$ST/route.jsonl"
OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" COMMS_ROUTE_LOG="$LOG" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ -s "$LOG" ] && grep -q '"tier": "balanced"' "$LOG" \
  && ok "COMMS_ROUTE_LOG records the decision" || fail "route log (rc=$rc log=$(cat "$LOG" 2>/dev/null))"

OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" -- "format the table on fast disk" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "balanced" ] && [ "$(rt_kv "$OUT" gate)" = "classify" ] \
  && ok "ordinary prose 'on fast disk' is not a tier override" || fail "false override tier (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/mech-lowc.json" -- "rename with high confidence" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "medium" ] && [ "$(rt_kv "$OUT" gate)" = "low-confidence-middle" ] \
  && ok "ordinary prose 'with high confidence' is not an effort override" || fail "false override effort (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" --current-tier fast --context-tokens 50000 \
  -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] && [ "$(rt_kv "$OUT" gate)" != "cache-sticky" ] \
  && ok "large context does not block an upgrade" || fail "cache sticky upgrade (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" -- "Redesign the cryptographic subsystem to use fast algorithms" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] && [ "$(rt_kv "$OUT" gate)" = "classify" ] \
  && ok "ordinary prose 'use fast algorithms' is not a tier override" || fail "false override fast algorithms (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" -- "Redesign the payment system to use low latency networking" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "xhigh" ] && [ "$(rt_kv "$OUT" gate)" = "classify" ] \
  && ok "ordinary prose 'use low latency' is not an effort override" || fail "false override low latency (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_BACKEND=typesafe -- "use plan first and use strong" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "yes" ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] \
  && [ "$(rt_kv "$OUT" source)" = "override" ] && [ "$(rt_kv "$OUT" gate)" = "override" ] \
  && ok "prompt override survives an enabled backend error" || fail "override on backend error (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" COMMS_ROUTE_CURRENT_TIER=strong COMMS_ROUTE_CONTEXT_TOKENS=50000 \
  -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] && [ "$(rt_kv "$OUT" gate)" = "cache-sticky" ] \
  && ok "env-only current-tier + context-tokens is cache-sticky" || fail "env cache sticky (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" COMMS_ROUTE_CURRENT_TIER=high -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "balanced" ] && [ "$(rt_kv "$OUT" gate)" = "classify" ] \
  && ok "invalid ambient COMMS_ROUTE_CURRENT_TIER is ignored, not usage-error" || fail "invalid env tier (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" -- "refactor to use fast, in-memory caching" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] && [ "$(rt_kv "$OUT" gate)" = "classify" ] \
  && ok "ordinary prose 'use fast, in-memory' is not a tier override" || fail "false override comma (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/partial.json" -- "use plan first and use strong" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "yes" ] && [ "$(rt_kv "$OUT" tier)" = "strong" ] \
  && [ "$(rt_kv "$OUT" source)" = "override" ] \
  && ok "prompt override survives malformed backend answers" || fail "override on malformed answers (rc=$rc out=$OUT)"

section "route.sh: the shadow collector cannot reach /auto"
# THE COLLECTOR EXISTS TO OBSERVE, NEVER TO DECIDE. Every assertion here RUNS the real code:
# this arc shipped five reimplementation bugs, the last of which sent `questions` as a list and
# drew HTTP 422 from the live API on the first real call. Asserting source shape would have
# caught none of them.
RS_SH="$REPO/helpers/route.sh"
RS_ALLOW="$WORK/shadow-allow"; : > "$RS_ALLOW"
# EXTRACT the production key function rather than recomputing it. A hand-rolled version of
# this produced a different hash and left the permit never matching — the same reimplementation
# mistake that sent `questions` as a list.
RS_KEYFN="$(sed -n '/^shadow_repo_key() {/,/^}/p' "$RS_SH")"
RS_KEY="$( cd "$REPO" && eval "$RS_KEYFN"; shadow_repo_key )"

# 1. THE COUPLING THIS SLICE EXISTS TO AVOID. resolve() treats COMMS_ROUTE_BACKEND /
# COMMS_ROUTE / COMMS_ROUTE_STUB as the on-switch, so a collector implemented by exporting one
# of them would silently arm the live classify path while every other assertion stayed green.
# NO LIVE ROUTING SETTINGS may reach these calls: the suite must never contact TypeSafe, and
# the harness does not clear the developer's environment. (codex P1, implement r1/r2.)
RS_CLEAN="env -u COMMS_ROUTE_BACKEND -u COMMS_ROUTE -u COMMS_ROUTE_STUB -u TYPESAFE_API_KEY -u COMMS_ROUTE_URL -u COMMS_ROUTE_MODEL"
RS_BASE="$(cd "$REPO" && $RS_CLEAN "$RS_SH" -- 'add a null check' 2>/dev/null)"
RS_WITH="$(cd "$REPO" && $RS_CLEAN COMMS_ROUTE_SHADOW_ALLOW="$RS_ALLOW" COMMS_ROUTE_SHADOW_ID=x \
             COMMS_ROUTE_SHADOW_DIR="$WORK" COMMS_ROUTE_SHADOW_KEY=k COMMS_ROUTE_SHADOW_BACKEND=stub \
             "$RS_SH" -- 'add a null check' 2>/dev/null)"
[ -n "$RS_BASE" ] && [ "$RS_BASE" = "$RS_WITH" ] \
  && ok "every collector variable exported leaves the classify path byte-identical" || fail "collector env changed the classify path"
printf '%s\n' "$RS_BASE" | grep -qx 'source: fail-open' \
  && ok "the classify path is still fail-open with no backend enabled" || fail "classify path is not fail-open"

# 2. STDOUT ISOLATION, observed rather than asserted about. /auto seds plan/effort/tier/source
# out of `route` output; the shadow path must emit none of them, ever.
RS_OUT="$(cd "$REPO" && $RS_CLEAN COMMS_ROUTE_SHADOW_ALLOW=/nonexistent-allow "$RS_SH" --shadow -- 'x' 2>/dev/null)"; RS_RC=$?
[ "$(printf '%s' "$RS_OUT" | grep -cE '^(plan|effort|complexity|tier|gate|source|reason|plan_p|effort_p|complexity_confidence):')" = 0 ] \
  && ok "the shadow path emits no classify key on stdout, so /auto has nothing to read" || fail "shadow stdout carried a classify key"

# 3. PERMISSION FAILS CLOSED, BEFORE ANY SOCKET. Task text must not leave the machine from a
# project the operator has not permitted; client work is in scope.
[ "$RS_RC" -ne 0 ] \
  && ok "an unpermitted project refuses the shadow run" || fail "unpermitted project was allowed to run"
RS_ERR="$(cd "$REPO" && $RS_CLEAN COMMS_ROUTE_SHADOW_ALLOW=/nonexistent-allow COMMS_ROUTE_URL=http://127.0.0.1:1 \
            "$RS_SH" --shadow -- 'x' 2>&1 >/dev/null)"
printf '%s' "$RS_ERR" | grep -q 'not permitted' \
  && ok "the refusal names permission, and happens before any request is attempted" || fail "refusal did not cite permission"

# 4. A MISSING HELPER MUST NOT ANSWER A SHADOW ARGV WITH THE CLASSIFY KEYS.
RS_TMP="$WORK/route-missing"; mkdir -p "$RS_TMP"; cp "$REPO/helpers/comms.sh" "$RS_TMP/comms.sh"; chmod +x "$RS_TMP/comms.sh"
RS_MISS="$("$RS_TMP/comms.sh" route --shadow -- 'x' 2>/dev/null)"; RS_MRC=$?
[ "$RS_MRC" -ne 0 ] && [ "$(printf '%s' "$RS_MISS" | grep -cE '^(plan|source):')" = 0 ] \
  && ok "a missing route.sh refuses --shadow instead of inventing a decision" || fail "missing helper answered --shadow with classify keys"
"$RS_TMP/comms.sh" route -- 'x' 2>/dev/null | grep -qx 'source: fail-open' \
  && ok "...while a plain classify argv still fails open unchanged" || fail "missing-helper fail-open regressed"

# 5. THE RECORD. Run the collector for real against a stub and read what it wrote.
RS_STUB="$WORK/shadow-stub.json"
printf '%s' '{"answers":{"needs_plan":{"noul":0.9},"complexity":{"probabilities":{"0":0,"1":0,"2":1,"3":0},"confidence":0.8},"effort":{"choice":"high","confidence":0.9}}}' > "$RS_STUB"
printf '%s\n' "$RS_KEY" > "$RS_ALLOW"
RS_DIR="$WORK/shadow-out"; mkdir -p "$RS_DIR"
# RECORD INTO THE WORK DIR. Without this every suite run wrote real task text into the live
# .comms/ mailbox of whatever checkout ran it. (grok, implement r1.)
RS_SOUT="$(cd "$REPO" && env COMMS_ROUTE_SHADOW_ALLOW="$RS_ALLOW" COMMS_ROUTE_SHADOW_BACKEND=stub \
           COMMS_ROUTE_SHADOW_RECORD_DIR="$RS_DIR" \
           COMMS_ROUTE_STUB="$RS_STUB" "$RS_SH" --shadow --thread t-1 --current-tier strong --context-tokens 900 \
           -- 'refactor the scheduler' 2>/dev/null)"
RS_ID="$(printf '%s' "$RS_SOUT" | sed -n 's/^shadow-decision //p')"
[ "$(printf '%s' "$RS_SOUT" | grep -cE '^(plan|effort|complexity|tier|gate|source|reason):')" = 0 ] \
  && ok "the SUCCESS path emits no classify key either, not just the refusal path" || fail "success path leaked a classify key"
[ -n "$RS_ID" ] && ok "a permitted shadow run prints a decision id and nothing else" || fail "no decision id on stdout"
RS_REC="$RS_DIR/$RS_ID.json"
[ -f "$RS_REC" ] && ok "the decision is recorded under the main repo's gitignored .comms/" || fail "no record at $RS_REC"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
need=["record_version","at","decision_id","project_key","thread","sent","sent_sha256","policy_inputs","raw_response","status","backend","questions_sha256"]
missing=[k for k in need if k not in d]
sys.exit(1 if missing else 0)' "$RS_REC" \
  && ok "the record carries every field a replay needs" || fail "record is missing required fields"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d["at"].endswith("Z") and d["policy_inputs"]["current_tier"]=="strong" and d["policy_inputs"]["context_tokens"]=="900" else 1)' "$RS_REC" \
  && ok "the timestamp is UTC-Z and the cache-sticky inputs a replay needs are retained" || fail "UTC-Z or policy inputs wrong"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d["raw_response"] and "Bearer" not in json.dumps(d) and "Authorization" not in json.dumps(d) else 1)' "$RS_REC" \
  && ok "the raw response is retained verbatim and no credential is written" || fail "raw response missing or credential leaked"

# 6. THE DRY GUARD that would have caught the HTTP 422: the collector must send the PRODUCTION
# question set, not a copy of it.
python3 -c '
import sys,json,hashlib
sys.path.insert(0,sys.argv[1])
import route_backend, route_shadow
sys.exit(0 if route_shadow.QUESTIONS is route_backend.QUESTIONS else 1)' "$REPO/helpers" \
  && ok "the collector sends the production question set, not a reimplementation" || fail "collector reimplements QUESTIONS"

# 6b. THE OUTBOUND STATE MUST BE PRODUCTION'S. A collector that sent {"task":...} without
# `kind` recorded decisions made under a different prompt — both reviewers caught it.
python3 -c '
import sys
sys.path.insert(0,sys.argv[1])
import route_backend as rb, route_shadow as rs
st=rb.build_state("t")
sys.exit(0 if set(st)=={"task","kind"} and st["kind"]==rb.STATE_KIND and rs.route_backend.build_state is rb.build_state else 1)' "$REPO/helpers" \
  && ok "both callers build the outbound state from one shared builder including kind" || fail "state builder diverged"
grep -q 'route_backend.build_state(task)' "$RS_SH" \
  && ok "the live classify path uses the shared state builder too" || fail "classify path hand-builds state"

# 7. A DECISION THAT CANNOT BE RECORDED IS A FAILURE, never a silent success.
python3 -c '
import os,subprocess,sys
helpers=sys.argv[1]
env=dict(os.environ, COMMS_ROUTE_SHADOW_ID="probe", COMMS_ROUTE_SHADOW_DIR="/proc/nonexistent-dir",
         COMMS_ROUTE_TASK="x", COMMS_ROUTE_BACKEND="stub", COMMS_ROUTE_STUB=sys.argv[2])
r=subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], env=env,
                 capture_output=True, text=True)
sys.exit(0 if r.returncode!=0 else 1)' "$REPO/helpers" "$RS_STUB" \
  && ok "an unwritable record directory fails loudly instead of losing a paid decision" || fail "write failure was swallowed"

# 7b. PERMISSION IS ENFORCED AT THE COLLECTOR BOUNDARY, not only in the shell. route_shadow.py
# is installed executable with its own __main__, so a direct invocation bypassed the gate and
# could reach HTTP with an empty project key. (codex P1, implement r1.)
python3 -c '
import os,subprocess,sys
helpers=sys.argv[1]
env=dict(os.environ, COMMS_ROUTE_SHADOW_ID="probe", COMMS_ROUTE_SHADOW_DIR=sys.argv[3],
         COMMS_ROUTE_TASK="x", COMMS_ROUTE_BACKEND="stub", COMMS_ROUTE_STUB=sys.argv[2],
         COMMS_ROUTE_SHADOW_ALLOW="/nonexistent-allow")
env.pop("COMMS_ROUTE_SHADOW_KEY", None)
r=subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], env=env,
                 capture_output=True, text=True)
sys.exit(0 if r.returncode!=0 and not os.path.exists(os.path.join(sys.argv[3],"probe.json")) else 1)'   "$REPO/helpers" "$RS_STUB" "$RS_DIR" \
  && ok "invoking the collector directly without permission refuses and writes nothing" || fail "direct invocation bypassed the permission gate"

# 8. The live smoke path stays OUT of the corpus: this suite must never call TypeSafe.
grep -q 'COMMS_ROUTE_SHADOW_BACKEND' "$RS_SH" \
  && ok "the collector's backend is overridable so the suite never needs TypeSafe" || fail "collector backend is not overridable"

# THE CRITERION ITSELF, executed: with live routing settings inherited and a dummy credential,
# the classify path must still make no request. Point the URL at a closed port so a real
# attempt would be visible as a connection error rather than silently succeeding.
RS_NOHTTP="$(cd "$REPO" && env COMMS_ROUTE_BACKEND=typesafe TYPESAFE_API_KEY=dummy \
   COMMS_ROUTE_URL=http://127.0.0.1:1/never $RS_CLEAN "$RS_SH" -- 'add a null check' 2>&1)"
printf '%s' "$RS_NOHTTP" | grep -qx 'source: fail-open' \
  && ok "inherited live routing settings are stripped, so the suite cannot reach TypeSafe" || fail "suite reached a backend with inherited settings"
