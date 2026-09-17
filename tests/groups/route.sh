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
  && [ "$(rt_kv "$OUT" effort)" = "medium" ] \
  && ok "no key fail-opens to plan=no effort=medium" || fail "no key fail-open (rc=$rc out=$OUT)"

rt_stub 0.99 3 0.99 xhigh 0.99 "$ST/would-plan.json"
OUT="$(rt COMMS_ROUTE=0 COMMS_ROUTE_STUB="$ST/would-plan.json" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "disabled" ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && ok "COMMS_ROUTE=0 disables even when a stub would request plan" || fail "COMMS_ROUTE=0 (rc=$rc out=$OUT)"

rt -- >/dev/null 2>&1 </dev/null && rc=0 || rc=$?
[ "$rc" -eq 2 ] && ok "empty task is a usage error" || fail "empty task rc=$rc (want 2)"

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
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && ok "comms.sh without sibling route.sh fail-opens" || fail "missing sibling (rc=$rc out=$OUT)"

OUT="$(rt COMMS_ROUTE_STUB="$ST/missing.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" source)" = "fail-open" ] \
  && ok "missing stub file fail-opens" || fail "missing stub (rc=$rc out=$OUT)"

OUT="$(rt -- "rename a typo" 2>/dev/null)"
keys="$(printf '%s\n' "$OUT" | awk -F': ' '{print $1}' | paste -sd, -)"
[ "$keys" = "plan,effort,complexity,plan_p,effort_p,complexity_confidence,source,reason" ] \
  && ok "fail-open emits the stable key set" || fail "key set ($keys)"

section "comms.sh: route policy"
rt_stub 0.91 3 0.92 high 0.81 "$ST/arch.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/arch.json" COMMS_ROUTE_URL="http://127.0.0.1:1" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "yes" ] && [ "$(rt_kv "$OUT" complexity)" = "architectural" ] \
  && [ "$(rt_kv "$OUT" source)" = "stub" ] \
  && ok "high noul + architectural => plan yes (source=stub)" || fail "arch plan (rc=$rc out=$OUT)"
keys="$(printf '%s\n' "$OUT" | awk -F': ' '{print $1}' | paste -sd, -)"
[ "$keys" = "plan,effort,complexity,plan_p,effort_p,complexity_confidence,source,reason" ] \
  && ok "stub success emits the stable key set" || fail "success key set ($keys)"

rt_stub 0.91 0 0.92 high 0.81 "$ST/mech.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/mech.json" -- "rename a typo" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] && [ "$(rt_kv "$OUT" complexity)" = "mechanical" ] \
  && ok "high noul + mechanical => plan no" || fail "mech plan (rc=$rc out=$OUT)"

rt_stub 0.20 3 0.92 high 0.81 "$ST/lownoul.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/lownoul.json" -- "redesign the auth stack" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] \
  && ok "low noul + architectural => plan no" || fail "low noul (rc=$rc out=$OUT)"

rt_stub 0.91 2 0.92 high 0.81 "$ST/hard.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/hard.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "yes" ] && [ "$(rt_kv "$OUT" complexity)" = "hard" ] \
  && ok "high noul + hard => plan yes" || fail "hard plan (rc=$rc out=$OUT)"

rt_stub 0.91 1 0.92 high 0.81 "$ST/std.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/std.json" -- "add a well-specified endpoint" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" plan)" = "no" ] && [ "$(rt_kv "$OUT" complexity)" = "standard" ] \
  && ok "high noul + standard => plan no" || fail "std plan (rc=$rc out=$OUT)"

rt_stub 0.50 2 0.92 xhigh 0.90 "$ST/xhi.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/xhi.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "xhigh" ] \
  && ok "confident xhigh effort is kept" || fail "xhigh (rc=$rc out=$OUT)"

rt_stub 0.50 2 0.92 xhigh 0.20 "$ST/xhi-low.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/xhi-low.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "medium" ] && [ "$(rt_kv "$OUT" effort_p)" = "-" ] \
  && ok "low-confidence effort clamps to medium" || fail "effort clamp (rc=$rc out=$OUT)"

rt_stub 0.50 2 0.92 high 0.70 "$ST/high.json"
OUT="$(rt COMMS_ROUTE_STUB="$ST/high.json" -- "debug a race" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$(rt_kv "$OUT" effort)" = "high" ] \
  && ok "confident high effort is kept" || fail "high effort (rc=$rc out=$OUT)"

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
