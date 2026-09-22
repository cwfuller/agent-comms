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
  # COMMS_ROUTE_LOG is stripped too: an inherited log path let the real classifier APPEND a
  # live record during the suite, even on a fail-open. A fixture that wants a log supplies its
  # own path as an explicit assignment above. (codex, implement r6.)
  (cd "$REPO_FIX" && env -u TYPESAFE_API_KEY -u COMMS_ROUTE -u COMMS_ROUTE_STUB \
    -u COMMS_ROUTE_URL -u COMMS_ROUTE_MODEL -u COMMS_ROUTE_TIMEOUT_SECS -u COMMS_ROUTE_LOG \
    -u COMMS_ROUTE_SHADOW_ALLOW -u COMMS_ROUTE_SHADOW_KEY \
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
RS_REPO="$WORK/shadow-repo"; mkdir -p "$RS_REPO"; RS_REPO="$(cd "$RS_REPO" && pwd -P)"
git -C "$RS_REPO" init -q 2>/dev/null
git -C "$RS_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
RS_KEYFN="$(sed -n '/^shadow_repo_key() {/,/^}/p' "$RS_SH")"
RS_KEY="$( cd "$RS_REPO" && eval "$RS_KEYFN"; shadow_repo_key )"

# 1. THE COUPLING THIS SLICE EXISTS TO AVOID. resolve() treats COMMS_ROUTE_BACKEND /
# COMMS_ROUTE / COMMS_ROUTE_STUB as the on-switch, so a collector implemented by exporting one
# of them would silently arm the live classify path while every other assertion stayed green.
# NO LIVE ROUTING SETTINGS may reach these calls: the suite must never contact TypeSafe, and
# the harness does not clear the developer's environment. (codex P1, implement r1/r2.)
RS_CLEAN="env -u COMMS_ROUTE_BACKEND -u COMMS_ROUTE -u COMMS_ROUTE_STUB -u TYPESAFE_API_KEY -u COMMS_ROUTE_URL -u COMMS_ROUTE_MODEL -u COMMS_ROUTE_LOG -u COMMS_ROUTE_SHADOW_ALLOW -u COMMS_ROUTE_SHADOW_KEY"
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
RS_SOUT="$(cd "$RS_REPO" && $RS_CLEAN COMMS_ROUTE_SHADOW_ALLOW="$RS_ALLOW" COMMS_ROUTE_SHADOW_BACKEND=stub \
           COMMS_ROUTE_STUB="$RS_STUB" "$RS_SH" --shadow --thread t-1 --current-tier strong --context-tokens 900 \
           -- 'refactor the scheduler' 2>/dev/null)"
RS_ID="$(printf '%s' "$RS_SOUT" | sed -n 's/^shadow-decision //p')"
[ "$(printf '%s' "$RS_SOUT" | grep -cE '^(plan|effort|complexity|tier|gate|source|reason):')" = 0 ] \
  && ok "the SUCCESS path emits no classify key either, not just the refusal path" || fail "success path leaked a classify key"
[ -n "$RS_ID" ] && ok "a permitted shadow run prints a decision id and nothing else" || fail "no decision id on stdout"
RS_REC="$RS_REPO/.comms/route-shadow/$RS_ID.json"
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

# 7. A DECISION THAT CANNOT BE RECORDED IS A FAILURE, never a silent success. Induced at the
# DERIVED destination inside the temp repo: a supplied directory is ignored now, so the old
# probe published into the live mailbox instead of failing. (codex, implement r5.)
python3 -c '
import os,subprocess,sys,stat
helpers,stub,repo,allow=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
dest=os.path.join(repo,".comms","route-shadow")
os.makedirs(os.path.dirname(dest), exist_ok=True)
# Make the derived destination unusable: a FILE where the directory must be.
if os.path.isdir(dest):
    import shutil; shutil.rmtree(dest)
open(dest,"w").close()
env=dict(os.environ, COMMS_ROUTE_SHADOW_ID="writefail", COMMS_ROUTE_TASK="x",
         COMMS_ROUTE_BACKEND="stub", COMMS_ROUTE_STUB=stub, COMMS_ROUTE_SHADOW_ALLOW=allow)
env.pop("COMMS_ROUTE_SHADOW_KEY", None)
r=subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], cwd=repo, env=env,
                 capture_output=True, text=True)
os.unlink(dest)
sys.exit(0 if r.returncode!=0 else 1)' "$REPO/helpers" "$RS_STUB" "$RS_REPO" "$RS_ALLOW" \
  && ok "an unusable derived record destination fails loudly instead of losing a paid decision" || fail "write failure was swallowed"

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
sys.exit(0 if r.returncode!=0 and not os.path.exists(os.path.join(sys.argv[3],"probe.json")) else 1)'   "$REPO/helpers" "$RS_STUB" "$RS_REPO" \
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

# A BORROWED PERMIT MUST NOT WORK. Supplying another project's allowlisted key from a different
# tree transmits that tree's task text under the wrong identity. (codex P1, implement r3.)
RS_OTHER="$WORK/shadow-other"; mkdir -p "$RS_OTHER"; RS_OTHER="$(cd "$RS_OTHER" && pwd -P)"
git -C "$RS_OTHER" init -q 2>/dev/null
git -C "$RS_OTHER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
python3 -c '
import os,subprocess,sys
helpers,stub,other,key=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
env=dict(os.environ, COMMS_ROUTE_SHADOW_ID="borrow", COMMS_ROUTE_SHADOW_DIR=other,
         COMMS_ROUTE_SHADOW_KEY=key, COMMS_ROUTE_TASK="client text", COMMS_ROUTE_BACKEND="stub",
         COMMS_ROUTE_STUB=stub, COMMS_ROUTE_SHADOW_ALLOW=sys.argv[5])
r=subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], cwd=other,
                 env=env, capture_output=True, text=True)
sys.exit(0 if r.returncode!=0 else 1)' "$REPO/helpers" "$RS_STUB" "$RS_OTHER" "$RS_KEY" "$RS_ALLOW" \
  && ok "another project's permitted key cannot authorise this tree's task text" || fail "a borrowed permit was accepted"
# GIT_DIR AND FRIENDS CAN SELECT ANOTHER REPOSITORY. From an unpermitted tree, pointing GIT_DIR
# at a permitted repo made the collector authorise and record THAT repo's identity for this
# tree's task text. Identity derivation must ignore repo-selection variables. (codex P1, r4.)
python3 -c '
import os,subprocess,sys
helpers,stub,other,allow,realgit=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5]
env=dict(os.environ, GIT_DIR=realgit, COMMS_ROUTE_SHADOW_ID="gitdir",
         COMMS_ROUTE_TASK="client text", COMMS_ROUTE_BACKEND="stub", COMMS_ROUTE_STUB=stub,
         COMMS_ROUTE_SHADOW_ALLOW=allow)
env.pop("COMMS_ROUTE_SHADOW_KEY", None)
r=subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], cwd=other,
                 env=env, capture_output=True, text=True)
sys.exit(0 if r.returncode!=0 else 1)' \
  "$REPO/helpers" "$RS_STUB" "$RS_OTHER" "$RS_ALLOW" "$RS_REPO/.git" \
  && ok "a GIT_DIR pointing at a permitted repo cannot authorise another tree" || fail "GIT_DIR selected another project"
# RUN the shell derivation under redirected git settings and require the SAME key as a clean
# environment. A grep for the variable name passes if either scrub site is deleted.
RS_ROOTFN="$(sed -n '/^shadow_main_root() {/,/^}/p' "$RS_SH")"
# BOTH derivations, each under redirected git settings, each compared to its clean result.
# Executing only one left the other scrub removable without failing anything. (codex r6.)
rs_derive() { # <fn> [hijack]
  if [ "${2:-}" = hijack ]; then
    ( cd "$RS_REPO" && export GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO"; eval "$RS_KEYFN"; eval "$RS_ROOTFN"; "$1" )
  else
    ( cd "$RS_REPO" && eval "$RS_KEYFN"; eval "$RS_ROOTFN"; "$1" )
  fi
}
for _fn in shadow_repo_key shadow_main_root; do
  _c="$(rs_derive "$_fn")"; _h="$(rs_derive "$_fn" hijack)"
  [ -n "$_c" ] && [ "$_c" = "$_h" ] \
    && ok "$_fn ignores a redirected GIT_DIR/GIT_WORK_TREE" || fail "$_fn changed under redirected git settings (clean=$_c hijacked=$_h)"
done

# A DECISION ID NAMES A FILE, so anything but a bare token can traverse out of the record root.
python3 -c '
import os,subprocess,sys
helpers,stub,repo,allow=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
env=dict(os.environ, COMMS_ROUTE_SHADOW_ID="../../escaped", COMMS_ROUTE_TASK="x",
         COMMS_ROUTE_BACKEND="stub", COMMS_ROUTE_STUB=stub, COMMS_ROUTE_SHADOW_ALLOW=allow)
env.pop("COMMS_ROUTE_SHADOW_KEY", None)
r=subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], cwd=repo,
                 env=env, capture_output=True, text=True)
escaped=os.path.exists(os.path.join(os.path.dirname(repo),"escaped.json"))
sys.exit(0 if r.returncode!=0 and not escaped else 1)' \
  "$REPO/helpers" "$RS_STUB" "$RS_REPO" "$RS_ALLOW" \
  && ok "a traversing decision id is refused and writes nothing outside the record root" || fail "decision id escaped the record root"

# THE DESTINATION IS DERIVED, not supplied: removing the shell override was not enough while
# the collector still honoured COMMS_ROUTE_SHADOW_DIR on its own entry path.
python3 -c '
import os,subprocess,sys,glob
helpers,stub,repo,allow,bad=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5]
env=dict(os.environ, COMMS_ROUTE_SHADOW_ID="dirprobe", COMMS_ROUTE_TASK="x",
         COMMS_ROUTE_BACKEND="stub", COMMS_ROUTE_STUB=stub, COMMS_ROUTE_SHADOW_ALLOW=allow,
         COMMS_ROUTE_SHADOW_DIR=bad)
env.pop("COMMS_ROUTE_SHADOW_KEY", None)
subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], cwd=repo, env=env,
               capture_output=True, text=True)
here=os.path.exists(os.path.join(repo,".comms","route-shadow","dirprobe.json"))
there=glob.glob(os.path.join(bad,"dirprobe*"))
sys.exit(0 if here and not there else 1)' \
  "$REPO/helpers" "$RS_STUB" "$RS_REPO" "$RS_ALLOW" "$WORK/not-the-record-root" \
  && ok "the record lands in the derived .comms/, never where COMMS_ROUTE_SHADOW_DIR points" || fail "a supplied directory redirected the record"

# Lossless raw retention: distinct invalid bytes must not collapse to the same stored text.
python3 -c '
import sys
sys.path.insert(0,sys.argv[1])
import route_backend as rb
rb._reset_raw(); rb._observe(b"{}\xff", 200); a=rb.LAST_RAW["body_b64"]
rb._reset_raw(); rb._observe(b"{}\xfe", 200); b=rb.LAST_RAW["body_b64"]
sys.exit(0 if a and b and a!=b else 1)' "$REPO/helpers" \
  && ok "distinct invalid bytes are retained distinctly, not collapsed by a lossy decode" || fail "raw retention is lossy"

# A PAID DECISION LOST AT PUBLISH TIME. The earlier probe fails during directory preparation,
# which is before the backend is called — so it does not actually cover "we paid for a decision
# and could not record it". Make the destination directory exist but be unwritable, so the
# backend answers and the WRITE is what fails. (codex advisory, implement r6.)
python3 -c '
import os,subprocess,sys,stat,shutil
helpers,stub,repo,allow=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
dest=os.path.join(repo,".comms","route-shadow")
if os.path.isfile(dest): os.unlink(dest)
os.makedirs(dest, exist_ok=True)
os.chmod(dest, 0o500)                      # exists, not writable
env=dict(os.environ, COMMS_ROUTE_SHADOW_ID="postresp", COMMS_ROUTE_TASK="x",
         COMMS_ROUTE_BACKEND="stub", COMMS_ROUTE_STUB=stub, COMMS_ROUTE_SHADOW_ALLOW=allow)
env.pop("COMMS_ROUTE_SHADOW_KEY", None)
r=subprocess.run([sys.executable, os.path.join(helpers,"route_shadow.py")], cwd=repo, env=env,
                 capture_output=True, text=True)
os.chmod(dest, 0o700)
wrote=os.path.exists(os.path.join(dest,"postresp.json"))
sys.exit(0 if r.returncode!=0 and not wrote and "could not write" in r.stderr else 1)' \
  "$REPO/helpers" "$RS_STUB" "$RS_REPO" "$RS_ALLOW" \
  && ok "a decision that answers but cannot be published fails loudly at the write" || fail "a post-response write failure was not reported"

# THE HARNESS SCRUB, EXERCISED UNDER A HOSTILE ENVIRONMENT. Inspecting the clean suite proves
# nothing: removing the whole scrub still passes if nothing hostile was seeded, and checking
# four names misses the rest. Seed every selector in a CHILD that sources the harness prefix,
# and require each to be gone. (codex, implement r8.)
RS_GITVARS="GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_PREFIX GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE"
RS_SEED=""; for _v in $RS_GITVARS; do RS_SEED="$RS_SEED $_v=/hostile"; done
# EXTRACT THE SHIPPED SCRUB and run THAT in the seeded child. A copied `unset` block tests a
# copy: codex replaced the harness's unset with `:` and both checks stayed green while all ten
# selectors survived. Extraction makes that mutation fail here. (codex, implement r9.)
RS_SCRUB="$(awk '/^unset GIT_DIR/{f=1} f{print} f&&!/\\$/{exit}' "$REPO/tests/lib/harness.sh")"
[ -n "$RS_SCRUB" ] && ok "the harness git scrub can be extracted for execution" || fail "no git scrub block found in harness.sh"
RS_SURV="$(env $RS_SEED bash -c '
  '"$RS_SCRUB"'
  for v in '"$RS_GITVARS"'; do eval "val=\${$v:-}"; [ -n "$val" ] && printf "%s " "$v"; done' 2>/dev/null)"
[ -z "$RS_SURV" ] && ok "running the SHIPPED scrub against a hostile environment removes every selector" || fail "survived the shipped scrub: $RS_SURV"

# Behavioural backstop: in this suite, a non-repo directory must not resolve a toplevel.
RS_NOREPO="$WORK/not-a-repo"; mkdir -p "$RS_NOREPO"
( cd "$RS_NOREPO" && git rev-parse --show-toplevel ) >/dev/null 2>&1 \
  && fail "a git selector survived into the suite: a non-repo directory resolved a toplevel" \
  || ok "a non-repo directory resolves no toplevel inside the suite"

section "comms.sh: reviewer routing decisions"
# THE REVIEWER DECISION IS A RECORDED, STICKY, ABSTRACT CANDIDATE. Explicit decisions and the
# stub backend drive every case: the suite never contacts TypeSafe. Classification additionally
# needs the per-project transmission permit, supplied per call.
RR_REPO="$WORK/rr-repo"; mkdir -p "$RR_REPO"; RR_REPO="$(cd "$RR_REPO" && pwd -P)"
git -C "$RR_REPO" init -q -b feature/rr
git -C "$RR_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
RR_BASE="$(git -C "$RR_REPO" rev-parse HEAD)"
printf 'a\nb\nc\n' > "$RR_REPO/one.txt"; mkdir -p "$RR_REPO/helpers"; printf 'x\n' > "$RR_REPO/helpers/two.sh"
git -C "$RR_REPO" add one.txt helpers/two.sh
git -C "$RR_REPO" -c user.email=t@t -c user.name=t commit -q -m change
RR_AID="$(git -C "$RR_REPO" rev-parse HEAD)"
mkdir -p "$RR_REPO/.comms/to-codex" "$RR_REPO/.comms/to-grok" "$RR_REPO/.comms/to-claude" "$RR_REPO/.comms/archive"
printf 'agents = claude codex grok\n' > "$RR_REPO/.comms/config"
RR_CLEAN="env -u COMMS_REVIEW_ROUTE -u COMMS_ROUTE -u COMMS_ROUTE_BACKEND -u COMMS_ROUTE_STUB -u TYPESAFE_API_KEY -u COMMS_ROUTE_URL -u COMMS_ROUTE_SHADOW_ALLOW COMMS_DELIVERY=mailbox COMMS_SELF=claude"
rrc() { ( cd "$RR_REPO" && $RR_CLEAN "$@" ); }
rrv() { printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1; }
RR_REC() { printf '%s' "$RR_REPO/.comms/route-decisions/$1.json"; }
rrj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$(RR_REC "$1")" "$2" 2>/dev/null; }
rr_req() {  # <file> <thread> <phase> [extra frontmatter line]
  cat > "$1" <<RQ
---
type: review-request
from: claude
timestamp: 2026-09-22T10:00:00Z
workspace: rr
message_id: $(basename "$1" .md)
thread: $2
workflow: auto
phase: $3
round: 1
max-rounds: 10
${4:-}
---

## Intent / approach
Rename a helper.

## What was done
$(python3 -c 'print("did a thing. " * 400)')

## Acceptance criteria
- it works

## Files changed
 99 files changed, 9999 insertions(+), 1 deletion(-)
RQ
}

rrc "$COMMS" review-route enabled; A=$?
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" review-route enabled; B=$?
rrc COMMS_REVIEW_ROUTE=1 COMMS_ROUTE=0 "$COMMS" review-route enabled; C=$?
[ "$A$B$C" = 101 ] && ok "reviewer routing is off by default, on with COMMS_REVIEW_ROUTE=1, and COMMS_ROUTE=0 is the master off" || fail "enabled accessor ($A$B$C)"

OUT="$(rrc "$COMMS" review-route decide --thread t-exp --phase implement --tier fast --effort low 2>/dev/null)"
RX="$(rrv "$OUT" decision)"
printf '%s' "$RX" | grep -qE '^rd-[0-9a-f]{32}$' && [ "$(rrv "$OUT" source)" = explicit ] \
  && [ "$(rrv "$OUT" tier)" = fast ] && [ "$(rrv "$OUT" effort)" = low ] && [ "$(rrj "$RX" 'd["decided_by"]')" = claude ] \
  && ok "an explicit decision is recorded with its id, candidate, source and who made it" || fail "explicit decide ($OUT)"
rrc "$COMMS" review-route decide --thread t-exp --phase implement --tier strong --effort high >/dev/null 2>&1; A=$?
OUT2="$(rrc "$COMMS" review-route lookup --thread t-exp --phase implement 2>/dev/null)"
[ "$A" = 1 ] && [ "$(rrv "$OUT2" decision)" = "$RX" ] && [ "$(rrv "$OUT2" tier)" = fast ] \
  && ok "an explicit request against an existing decision is refused, never silently answered with the old one" || fail "explicit vs existing (rc=$A)"
OUT3="$(rrc "$COMMS" review-route decide --thread t-exp --phase implement --tier balanced --effort medium --replace 2>/dev/null)"
RX2="$(rrv "$OUT3" decision)"
[ -n "$RX2" ] && [ "$RX2" != "$RX" ] && [ "$(rrj "$RX2" 'd["replaces"]')" = "$RX" ] \
  && [ "$(rrv "$(rrc "$COMMS" review-route lookup --thread t-exp --phase implement 2>/dev/null)" decision)" = "$RX2" ] \
  && ok "--replace mints a NEW decision id, records what it replaces, and becomes the one in force" || fail "replace ($OUT3)"
OUT4="$(rrc "$COMMS" review-route decide --thread t-exp --phase plan --tier fast --effort low 2>/dev/null)"
[ -n "$(rrv "$OUT4" decision)" ] && [ "$(rrv "$OUT4" decision)" != "$RX2" ] \
  && ok "decisions are keyed per PHASE: the plan phase never inherits the implement decision" || fail "phase keying"
rrc "$COMMS" review-route show "$RX2" --thread t-exp-codex --phase implement >/dev/null 2>&1; A=$?
rrc "$COMMS" review-route show "$RX2" --thread t-exp --phase plan >/dev/null 2>&1; B=$?
rrc "$COMMS" review-route show '../../etc/x' >/dev/null 2>&1; C=$?
rrc "$COMMS" review-route lookup --thread t-none --phase implement >/dev/null 2>&1; D=$?
[ "$A" != 0 ] && [ "$B" != 0 ] && [ "$C" != 0 ] && [ "$D" != 0 ] \
  && ok "show refuses a foreign thread, a wrong phase and a path-shaped id; lookup refuses an absent decision" || fail "show/lookup refusals ($A$B$C$D)"
# A routed panel's own record of its legs (what `panel dispatch` writes before any leg is sent).
rr_panel_record() {  # <dispatch> <decision> <raw base thread> <agents...>
  local d="$1" r="$2" b="$3" f; shift 3
  f="$RR_REPO/.comms/route-decisions/legs/$(printf '%s' "$d" | shasum -a 256 | cut -c1-12)"
  mkdir -p "$(dirname "$f")"
  { printf 'dispatch	%s
decision	%s
base	%s
' "$d" "$r" "$b"; for a in "$@"; do printf 'agent	%s
' "$a"; done; } > "$f"
}
rr_panel_record d-rr-v "$RX2" t-exp codex grok
rrc "$COMMS" review-route verify "$RX2" --thread t-exp-codex --phase implement --leg-dispatch d-rr-v >/dev/null 2>&1; A=$?
rrc "$COMMS" review-route verify "$RX2" --thread t-exp-codex --phase implement >/dev/null 2>&1; B=$?
rrc "$COMMS" review-route verify "$RX2" --thread t-exp-codex --phase implement --leg-dispatch d-typed >/dev/null 2>&1; E=$?
rrc "$COMMS" review-route verify "$RX" --thread t-exp --phase implement >/dev/null 2>&1; C=$?
rrc "$COMMS" review-route verify "-h" --thread t-exp --phase implement >/dev/null 2>&1; D=$?
[ "$A" = 0 ] && [ "$B" != 0 ] && [ "$E" != 0 ] && [ "$C" != 0 ] && [ "$D" != 0 ] \
  && ok "verify: a leg its panel recorded may carry its base decision; a bare or typed-dispatch lookalike may not; a replaced id is stale; an option-shaped id is refused" || fail "verify ($A$B$E$C$D)"
# THE SHORTENED-IDENTITY ALIAS (codex, implement r2): a long base thread and a thread literally named
# after its shortened log identity must not share a panel's leg exception. Authorization is the
# panel's RAW record, and it names the one decision it stamped.
RR_LONG="t-$(python3 -c 'print("x" * 100)')"
# The shortened form the coordinator log would store (event_identity at the thread width: the
# first 67 bytes, `~`, and 12 hex of the value's sha256).
RR_SHORT="$(python3 -c 'import hashlib,sys; v=sys.argv[1]; print(v[:67] + "~" + hashlib.sha256(v.encode()).hexdigest()[:12])' "$RR_LONG")"
rrc "$COMMS" review-route decide --thread "$RR_LONG" --phase implement --tier strong --effort xhigh >/dev/null 2>&1
rrc "$COMMS" review-route decide --thread "$RR_SHORT" --phase implement --tier fast --effort low >/dev/null 2>&1
RL_ID="$(rrv "$(rrc "$COMMS" review-route lookup --thread "$RR_LONG" --phase implement 2>/dev/null)" decision)"
RS_ID="$(rrv "$(rrc "$COMMS" review-route lookup --thread "$RR_SHORT" --phase implement 2>/dev/null)" decision)"
rr_panel_record d-rr-long "$RL_ID" "$RR_LONG" codex
rrc "$COMMS" review-route verify "$RL_ID" --thread "$RR_LONG-codex" --phase implement --leg-dispatch d-rr-long >/dev/null 2>&1; A=$?
rrc "$COMMS" review-route verify "$RS_ID" --thread "$RR_SHORT-codex" --phase implement --leg-dispatch d-rr-long >/dev/null 2>&1; B=$?
[ -n "$RR_SHORT" ] && [ "$RR_SHORT" != "$RR_LONG" ] && [ "$A" = 0 ] && [ "$B" != 0 ] \
  && ok "a thread named after a long thread's shortened identity cannot pass as a leg of that thread's panel" || fail "identity alias ($A$B short=$RR_SHORT)"
# A LEG IS JUDGED ONLY BY ITS PANEL'S RECORD (codex, implement r3): a thread literally named
# `<base>-codex` with its own current cheaper decision cannot substitute it into the panel's leg.
rrc "$COMMS" review-route decide --thread t-top --phase implement --tier strong --effort xhigh >/dev/null 2>&1
rrc "$COMMS" review-route decide --thread t-top-codex --phase implement --tier fast --effort low >/dev/null 2>&1
RT_ID="$(rrv "$(rrc "$COMMS" review-route lookup --thread t-top --phase implement 2>/dev/null)" decision)"
RTC_ID="$(rrv "$(rrc "$COMMS" review-route lookup --thread t-top-codex --phase implement 2>/dev/null)" decision)"
rr_panel_record d-top "$RT_ID" t-top codex
rrc "$COMMS" review-route verify "$RTC_ID" --thread t-top-codex --phase implement --leg-dispatch d-top >/dev/null 2>&1; A=$?
rrc "$COMMS" review-route verify "$RT_ID" --thread t-top-codex --phase implement --leg-dispatch d-top >/dev/null 2>&1; B=$?
rrc "$COMMS" review-route verify "$RTC_ID" --thread t-top-codex --phase implement >/dev/null 2>&1; C=$?
[ "$A" != 0 ] && [ "$B" = 0 ] && [ "$C" = 0 ] \
  && ok "a leg carrying anything but its panel's stamped decision is refused, with no fallback to the standalone rule" || fail "leg substitution ($A$B$C)"

# THE reviewer-v1 MAPPING, run directly: cheap outputs are reachable, and nothing malformed,
# tied or split can land on the cheapest reviewer. No bump anywhere.
rrmap() { python3 -c '
import sys,json; sys.path.insert(0,sys.argv[1])
import route_review as r
try: t,e,g,_=r.map_answers(json.loads(sys.argv[2])); print(t,e,g)
except ValueError: print("malformed")' "$REPO/helpers" "$1"; }
[ "$(rrmap '{"review_depth":{"probabilities":{"0":0.9,"1":0.1,"2":0,"3":0},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.9}}')" = "fast low classify" ] \
  && ok "a confident mechanical review maps to fast/low (reachable; no bump)" || fail "mechanical mapping"
[ "$(rrmap '{"review_depth":{"probabilities":{"0":0.5,"1":0,"2":0,"3":0.5},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.9}}' | cut -d' ' -f1)" = strong ] \
  && [ "$(rrmap '{"review_depth":{"probabilities":{"0":0.34,"1":0.33,"2":0.33,"3":0},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.9}}' | cut -d' ' -f1)" = strong ] \
  && ok "a tie or a split distribution goes DEEPER, never to the cheapest tier" || fail "tie/split mapping"
[ "$(rrmap '{"review_depth":{"probabilities":{"0":1.0},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.9}}')" = malformed ] \
  && [ "$(rrmap '{"review_depth":{"probabilities":{"0":0.9,"1":0.9,"2":0,"3":0},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.9}}')" = malformed ] \
  && ok "a partial or non-normalized distribution is malformed (baseline), not read as mechanical" || fail "partial distribution"
[ "$(rrmap '{"review_depth":{"probabilities":{"0":1,"1":0,"2":0,"3":0},"confidence":0.2},"review_effort":{"choice":"low","confidence":0.2}}')" = "none none low-depth-confidence+low-effort-confidence" ] \
  && [ "$(rrmap '{"review_depth":{"probabilities":{"0":1,"1":0,"2":0,"3":0},"confidence":0.2},"review_effort":{"choice":"low","confidence":0.9}}')" = "none none low-depth-confidence" ] \
  && [ "$(rrmap '{"review_depth":{"probabilities":{"0":1,"1":0,"2":0,"3":0},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.2}}')" = "none none low-effort-confidence" ] \
  && ok "low confidence on EITHER dimension keeps the whole baseline (none/none), recorded as a gate" || fail "low confidence mapping"
[ "$(rrmap '{"review_depth":{"probabilities":{"0":1,"1":0,"2":0,"3":0},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.9,"probabilities":{"low":0.5,"medium":0.5,"high":0,"xhigh":0}}}' | cut -d' ' -f2)" = medium ] \
  && ok "a supplied effort distribution can only deepen the chosen effort" || fail "effort distribution"

# CLASSIFICATION: permit first, measured signals, bounded recorded input, stub never routes.
RR_ALLOW="$WORK/rr-allow"; RR_KEY="$(cd "$RR_REPO" && python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import route_backend as b; print(b.canonical_project()[0])' "$REPO/helpers")"
printf '%s\n' "$RR_KEY" > "$RR_ALLOW"
RR_STUB="$WORK/rr-stub.json"
printf '%s' '{"answers":{"review_depth":{"probabilities":{"0":0.9,"1":0.1,"2":0,"3":0},"confidence":0.9},"review_effort":{"choice":"low","confidence":0.9}}}' > "$RR_STUB"
rr_req "$WORK/rr-q1.md" t-cls implement
OUT="$(rrc COMMS_ROUTE_STUB="$RR_STUB" "$COMMS" review-route decide --request "$WORK/rr-q1.md" --artifact "$RR_AID" --base "$RR_BASE" 2>/dev/null)"
RC1="$(rrv "$OUT" decision)"
[ "$(rrv "$OUT" source)" = not-permitted ] && [ "$(rrv "$OUT" tier)" = none ] \
  && [ "$(rrj "$RC1" '"sent" in d')" = False ] \
  && ok "without the project permit nothing is sent or retained, and the candidate is the baseline" || fail "not permitted ($OUT)"
rr_req "$WORK/rr-q2.md" t-cls2 implement
OUT="$(rrc COMMS_ROUTE_STUB="$RR_STUB" COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" "$COMMS" review-route decide --request "$WORK/rr-q2.md" 2>/dev/null)"
[ "$(rrv "$OUT" source)" = fail-open ] && [ "$(rrv "$OUT" tier)" = none ] \
  && ok "with no measurable artifact nothing is classified (an id alone conveys no content)" || fail "no artifact ($OUT)"
rr_req "$WORK/rr-q3.md" t-cls3 implement
OUT="$(rrc COMMS_ROUTE_STUB="$RR_STUB" COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" "$COMMS" review-route decide --request "$WORK/rr-q3.md" --artifact "$RR_AID" --base "$RR_BASE" 2>/dev/null)"
RC3="$(rrv "$OUT" decision)"
[ "$(rrv "$OUT" source)" = stub ] && [ "$(rrv "$OUT" gate)" = stub-source ] && [ "$(rrv "$OUT" tier)" = none ] \
  && [ "$(rrj "$RC3" 'd["classified"]["tier"]+"/"+d["classified"]["effort"]')" = fast/low ] \
  && ok "the stub test seam records what it WOULD choose but never routes a live turn" || fail "stub source ($OUT)"
[ "$(rrj "$RC3" 'd["sent"]["risk_signals"]["files_changed"]')" = 2 ] && [ "$(rrj "$RC3" 'd["sent"]["risk_signals"]["insertions"]')" = 4 ] \
  && [ "$(rrj "$RC3" 'd["sent"]["risk_signals"]["top_level"]["helpers"]')" = 1 ] \
  && ok "risk signals are MEASURED from the artifact diff, not the author's claimed stat (99 files)" || fail "risk signals not measured"
[ "$(rrj "$RC3" 'd["input"]["sections"]["done"]["truncated"]')" = True ] && [ "$(rrj "$RC3" '"prior" in d["input"]["omitted"]')" = True ] \
  && [ "$(rrj "$RC3" 'd["input"]["sent_chars"] <= d["input"]["total_limit"]')" = True ] \
  && [ "$(rrj "$RC3" 'd["rubric_version"]')" = reviewer-v1 ] && [ "$(rrj "$RC3" 'bool(d["raw_response"])')" = True ] \
  && ok "the exact bounded input, its truncation and omissions, the rubric version and the raw answer are recorded" || fail "bounded input record"
printf '%s' '{"answers":{"review_depth":{"probabilities":{"0":1}}}}' > "$WORK/rr-bad.json"
rr_req "$WORK/rr-q4.md" t-cls4 implement
OUT="$(rrc COMMS_ROUTE_STUB="$WORK/rr-bad.json" COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" "$COMMS" review-route decide --request "$WORK/rr-q4.md" --artifact "$RR_AID" --base "$RR_BASE" 2>/dev/null)"
OUT5="$(rrc COMMS_ROUTE=0 COMMS_ROUTE_STUB="$RR_STUB" COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" "$COMMS" review-route decide --thread t-cls5 --phase implement --tier none --effort none 2>/dev/null)"
rr_req "$WORK/rr-q6.md" t-cls6 implement
OUT6="$(rrc COMMS_ROUTE=0 COMMS_ROUTE_STUB="$RR_STUB" COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" "$COMMS" review-route decide --request "$WORK/rr-q6.md" --artifact "$RR_AID" --base "$RR_BASE" 2>/dev/null)"
[ "$(rrv "$OUT" source)" = fail-open ] && [ "$(rrv "$OUT" tier)" = none ] && [ "$(rrv "$OUT6" source)" = disabled ] \
  && ok "a malformed answer fails open to the baseline and COMMS_ROUTE=0 disables classification" || fail "malformed/disabled ($OUT / $OUT6)"

# SEND AND PANEL STAMP THE DECISION; NOTHING ELSE MAY.
rr_req "$RR_REPO/.comms/rr-s1.md" t-send implement "route_decision: forged"
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" review-route decide --thread t-send --phase implement --tier fast --effort low >/dev/null 2>&1
RS1="$(rrv "$(rrc "$COMMS" review-route lookup --thread t-send --phase implement 2>/dev/null)" decision)"
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" send --to codex "$RR_REPO/.comms/rr-s1.md" >/dev/null 2>&1
RS1F="$(grep -l '^thread: t-send$' "$RR_REPO/.comms/to-codex"/*.md "$RR_REPO/.comms/rr-s1.md" 2>/dev/null | head -1)"
[ -n "$RS1" ] && [ "$(grep -c '^route_decision:' "$RS1F")" = 1 ] && grep -qx "route_decision: $RS1" "$RS1F" \
  && ok "send stamps the thread's decision as ONE line and replaces a hand-typed value" || fail "send stamping ($RS1 in $RS1F)"
rr_req "$RR_REPO/.comms/rr-s2.md" t-send2 implement "route_decision: rd-0123456789abcdef0123456789abcdef"
rrc "$COMMS" send --to codex "$RR_REPO/.comms/rr-s2.md" >/dev/null 2>&1
RS2F="$(grep -l '^thread: t-send2$' "$RR_REPO/.comms/to-codex"/*.md "$RR_REPO/.comms/rr-s2.md" 2>/dev/null | head -1)"
rr_req "$RR_REPO/.comms/rr-s3.md" t-send3 plan "route_decision: rd-0123456789abcdef0123456789abcdef"
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" send --to codex "$RR_REPO/.comms/rr-s3.md" >/dev/null 2>&1
RS3F="$(grep -l '^thread: t-send3$' "$RR_REPO/.comms/to-codex"/*.md "$RR_REPO/.comms/rr-s3.md" 2>/dev/null | head -1)"
[ -n "$RS2F" ] && ! grep -q '^route_decision:' "$RS2F" && [ -n "$RS3F" ] && ! grep -q '^route_decision:' "$RS3F" \
  && ok "with routing off, or on a plan-phase request, any route_decision line is stripped" || fail "stripping ($RS2F / $RS3F)"
rr_req "$RR_REPO/.comms/rr-p1.md" t-pan implement
RR_NREC0="$(ls "$RR_REPO/.comms/route-decisions"/*.json 2>/dev/null | wc -l | tr -d ' ')"
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" panel dispatch --to codex,grok "$RR_REPO/.comms/rr-p1.md" >/dev/null 2>&1
RR_NREC1="$(ls "$RR_REPO/.comms/route-decisions"/*.json 2>/dev/null | wc -l | tr -d ' ')"
RP_C="$(grep -h '^route_decision:' $(grep -l '^thread: t-pan-codex$' "$RR_REPO/.comms/to-codex"/*.md 2>/dev/null) 2>/dev/null)"
RP_G="$(grep -h '^route_decision:' $(grep -l '^thread: t-pan-grok$' "$RR_REPO/.comms/to-grok"/*.md 2>/dev/null) 2>/dev/null)"
[ -n "$RP_C" ] && [ "$RP_C" = "$RP_G" ] && [ "$((RR_NREC1 - RR_NREC0))" = 1 ] \
  && ok "a panel records ONE decision for its base thread and every leg carries the same id" || fail "panel stamping ($RP_C / $RP_G / $RR_NREC0->$RR_NREC1)"

# THE SHADOW OBSERVES THE REVIEWER RUBRIC AND CANNOT ACTIVATE IT.
rr_req "$WORK/rr-sh.md" t-shadow implement "artifact_id: $RR_AID"
RR_ND0="$(ls "$RR_REPO/.comms/route-decisions" "$RR_REPO/.comms/route-decisions/threads" 2>/dev/null | wc -l | tr -d ' ')"
RSH="$(rrc COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" COMMS_ROUTE_SHADOW_BACKEND=stub COMMS_ROUTE_STUB="$RR_STUB" \
        "$REPO/helpers/route.sh" --shadow --reviewer --file "$WORK/rr-sh.md" 2>/dev/null)"
RSH_ID="$(printf '%s' "$RSH" | sed -n 's/^shadow-decision //p')"
RR_ND1="$(ls "$RR_REPO/.comms/route-decisions" "$RR_REPO/.comms/route-decisions/threads" 2>/dev/null | wc -l | tr -d ' ')"
[ -n "$RSH_ID" ] && [ "$(printf '%s\n' "$RSH" | grep -c .)" = 1 ] && [ "$RR_ND0" = "$RR_ND1" ] \
  && python3 -c '
import json,sys,hashlib; sys.path.insert(0,sys.argv[2]); import route_backend as b
d=json.load(open(sys.argv[1]))
q=hashlib.sha256(json.dumps(b.REVIEW_QUESTIONS,sort_keys=True).encode()).hexdigest()
sys.exit(0 if d["role"]=="reviewer" and d["rubric_version"]=="reviewer-v1" and d["questions_sha256"]==q and "input" in d else 1)' \
     "$RR_REPO/.comms/route-shadow/$RSH_ID.json" "$REPO/helpers" \
  && ok "a reviewer shadow uses the live rubric and builder, prints only its id, and writes no decision" || fail "reviewer shadow ($RSH)"
rrc "$REPO/helpers/route.sh" --reviewer -- x >/dev/null 2>&1; A=$?
[ "$A" = 2 ] && ok "--reviewer outside --shadow is a usage error (live decisions come from review-route)" || fail "--reviewer without --shadow rc=$A"
# The implementer policy is NAMED, and the name is the shared constant.
RR_IMP="$(rt COMMS_ROUTE_STUB="$ST/mech.json" -- "rename a typo" 2>/dev/null)"
python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import route_backend as b; sys.exit(0 if ("policy="+b.IMPLEMENTER_POLICY_VARIANT) in sys.argv[2] else 1)' \
  "$REPO/helpers" "$(rt_kv "$RR_IMP" reason)" \
  && ok "the implementer classifier names its bumped policy variant in reason:" || fail "implementer variant not named ($RR_IMP)"
# THE CHANGE UNDER REVIEW is measured against the integration branch, never as artifact..artifact:
# a committed (clean) tree stamps artifact == head_sha, and diffing that measures "0 files" — a
# false "trivially small" that would steer toward the cheapest reviewer.
git -C "$RR_REPO" branch -f main "$RR_BASE" >/dev/null 2>&1
rr_req "$WORK/rr-q7.md" t-clean implement
OUT="$(rrc COMMS_ROUTE_STUB="$RR_STUB" COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" "$COMMS" review-route decide --request "$WORK/rr-q7.md" --artifact "$RR_AID" --base "$RR_AID" 2>/dev/null)"
RC7="$(rrv "$OUT" decision)"
rr_req "$WORK/rr-q8.md" t-onmain implement
OUT8="$(rrc COMMS_ROUTE_STUB="$RR_STUB" COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" "$COMMS" review-route decide --request "$WORK/rr-q8.md" --artifact "$RR_BASE" --base "$RR_BASE" 2>/dev/null)"
RC8="$(rrv "$OUT8" decision)"
[ "$(rrj "$RC7" 'd["sent"]["risk_signals"]["files_changed"]')" = 2 ] && [ "$(rrj "$RC7" 'd["input"]["measured_ref"]')" = refs/heads/main ] \
  && [ "$(rrv "$OUT8" source)" = fail-open ] && [ "$(rrj "$RC8" '"sent" in d')" = False ] \
  && ok "a clean committed artifact is measured from its merge-base with main; an unmeasurable one is never a measured zero" || fail "measurement ($OUT / $OUT8)"
# A BASE THREAD ENDING IN -<agent> is keyed as written: the panel completes and every leg verifies.
rr_req "$RR_REPO/.comms/rr-p2.md" t-acp-grok implement
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" panel dispatch --to codex,grok "$RR_REPO/.comms/rr-p2.md" >/dev/null 2>&1; A=$?
RP2_C="$(grep -h '^route_decision:' $(grep -l '^thread: t-acp-grok-codex$' "$RR_REPO/.comms/to-codex"/*.md 2>/dev/null) 2>/dev/null)"
RP2_G="$(grep -h '^route_decision:' $(grep -l '^thread: t-acp-grok-grok$' "$RR_REPO/.comms/to-grok"/*.md 2>/dev/null) 2>/dev/null)"
[ "$A" = 0 ] && [ -n "$RP2_C" ] && [ "$RP2_C" = "$RP2_G" ] \
  && [ "$(rrj "${RP2_C#route_decision: }" 'd["thread"]')" = t-acp-grok ] \
  && ok "a panel whose base thread ends in -grok keys its decision on the thread as written and fans out whole" || fail "panel on -grok thread (rc=$A $RP2_C / $RP2_G)"
# A THREAD MERELY NAMED like a leg never borrows the other thread's decision.
rrc "$COMMS" review-route decide --thread t-iso --phase implement --tier fast --effort low >/dev/null 2>&1
RISO="$(rrv "$(rrc "$COMMS" review-route lookup --thread t-iso --phase implement 2>/dev/null)" decision)"
rr_req "$RR_REPO/.comms/rr-s4.md" t-iso-grok implement
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" send --to codex "$RR_REPO/.comms/rr-s4.md" >/dev/null 2>&1
RS4F="$(grep -l '^thread: t-iso-grok$' "$RR_REPO/.comms/to-codex"/*.md "$RR_REPO/.comms/rr-s4.md" 2>/dev/null | head -1)"
RS4="$(sed -n 's/^route_decision: //p' "$RS4F" 2>/dev/null | head -1)"
[ -n "$RISO" ] && [ -n "$RS4" ] && [ "$RS4" != "$RISO" ] && [ "$(rrj "$RS4" 'd["thread"]')" = t-iso-grok ] \
  && ok "thread x-grok gets its own decision, never thread x's" || fail "lookalike thread borrowed a decision ($RS4 vs $RISO)"
# THE SHADOW never observes an input production would not send.
rr_req "$WORK/rr-sh2.md" t-shadow2 implement
RSH2="$(rrc COMMS_ROUTE_SHADOW_ALLOW="$RR_ALLOW" COMMS_ROUTE_SHADOW_BACKEND=stub COMMS_ROUTE_STUB="$RR_STUB" \
        "$REPO/helpers/route.sh" --shadow --reviewer --file "$WORK/rr-sh2.md" 2>/dev/null | sed -n 's/^shadow-decision //p')"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); st=json.loads(d["sent"]); sys.exit(0 if d["status"]=="unsendable" and not d.get("answers") and "risk_signals" in st and "artifact" in st and "phase" in st else 1)' \
    "$RR_REPO/.comms/route-shadow/$RSH2.json" 2>/dev/null \
  && ok "a reviewer shadow of an unmeasurable request is recorded as unsendable, with no call made, and keeps the whole state" || fail "shadow unsendable ($RSH2)"
# A TYPED dispatch does not make a lookalike thread a panel leg at send time either.
rr_req "$RR_REPO/.comms/rr-s5.md" t-iso-codex implement "dispatch: d-typed
route_decision: $RISO"
rrc COMMS_REVIEW_ROUTE=1 "$COMMS" send --to codex "$RR_REPO/.comms/rr-s5.md" >/dev/null 2>&1; A=$?
[ "$A" != 0 ] && ok "send refuses a lookalike leg whose dispatch the coordinator log does not corroborate" || fail "typed dispatch accepted at send"
# "use max" is the implementer override too.
OUT="$(rt -- "use max to fix the parser" 2>/dev/null)"
[ "$(rt_kv "$OUT" tier)" = strong ] && [ "$(rt_kv "$OUT" effort)" = xhigh ] && [ "$(rt_kv "$OUT" source)" = override ] \
  && ok "'use max' overrides the implementer hint to strong / xhigh" || fail "use max override ($OUT)"
