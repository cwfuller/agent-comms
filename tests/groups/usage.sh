# Run through tests/run.sh; each group gets fresh fixtures.
section "leg_usage.py: a leg's tokens come from the provider's own records"
# The reader is exercised against SYNTHETIC records shaped like each provider's real ones
# (tests/fixtures/leg-usage/), through the same snapshot -> append -> collect sequence the runner
# performs around a billable prompt. Every expected number below is chosen so that the failure
# it guards against — a double-counted duplicate, a first-copy-wins dedupe, a pre-window record
# counted, a zero where evidence is missing — produces a DIFFERENT number, not the same one.
LU="$REPO/helpers/leg_usage.py"
LUF="$REPO/tests/fixtures/leg-usage"
LUW="$WORK/leg-usage"; mkdir -p "$LUW"; LUW="$(cd "$LUW" && pwd -P)"
# lu_run <provider> <root> <cwd> <snapshot> -> prints collect's two lines
lu_run() { python3 "$LU" collect "$1" "$2" "$3" "$4" 2>/dev/null; }
# lu_field <collect-output> <usage|rate_limits> <key> -> the value, `null` for JSON null, `<none>`
# when the whole object is null
lu_field() {
  printf '%s\n' "$1" | sed -n "s/^$2	//p" | python3 -c '
import json,sys
v=json.loads(sys.stdin.read() or "null")
if v is None: print("<none>")
else:
    x=v.get(sys.argv[1], "<absent>")
    print("null" if x is None else x)' "$3"
}

# ---- codex: token_usage_record summed by turn_id, a duplicated response counted once ----
CX="$LUW/codex-home"; CXD="$CX/sessions/2026/09/25"; mkdir -p "$CXD"
cp "$LUF/codex-prewindow.jsonl" "$CXD/rollout-a.jsonl"
python3 "$LU" snapshot codex "$CX" /unused "$LUW/cx.snap" \
  && ok "a codex snapshot is taken over the isolated home" || fail "codex snapshot failed"
cat "$LUF/codex-window.jsonl" >> "$CXD/rollout-a.jsonl"
CXO="$(lu_run codex "$CX" /unused "$LUW/cx.snap")"
# deduped: 100+200+300 input. Counting resp_r2 twice gives 800; counting the pre-window turn 5600.
[ "$(lu_field "$CXO" usage input_tokens)" = 600 ] && [ "$(lu_field "$CXO" usage total_tokens)" = 660 ] \
  && ok "codex usage sums the window's token_usage_records (input 600, total 660)" \
  || fail "codex window sum (got: $CXO)"
[ "$(lu_field "$CXO" usage responses)" = 3 ] && [ "$(lu_field "$CXO" usage turns)" = 2 ] \
  && ok "a response recorded twice is counted once, and records group into two turns" \
  || fail "codex dedupe/turns (got: $CXO)"
[ "$(lu_field "$CXO" usage cached_input_tokens)" = 440 ] && [ "$(lu_field "$CXO" usage cache_write_input_tokens)" = 5 ] \
  && [ "$(lu_field "$CXO" usage output_tokens)" = 60 ] && [ "$(lu_field "$CXO" usage reasoning_output_tokens)" = 12 ] \
  && ok "codex cached, cache-write, output and reasoning tokens are summed field by field" \
  || fail "codex per-field sums (got: $CXO)"
[ "$(lu_field "$CXO" usage source)" = codex-token-usage-record ] \
  && ok "codex usage names the record it was read from" || fail "codex source (got: $CXO)"
# The LATEST snapshot in the window (31.5), not the first (30.0) and never the pre-window one (99).
[ "$(lu_field "$CXO" rate_limits used_percent)" = 31.5 ] && [ "$(lu_field "$CXO" rate_limits limit_id)" = codex ] \
  && [ "$(lu_field "$CXO" rate_limits window_minutes)" = 10080 ] && [ "$(lu_field "$CXO" rate_limits resets_at)" = 1790000100 ] \
  && ok "codex rate_limits is the window's latest snapshot (limit_id, window_minutes, used_percent, resets_at)" \
  || fail "codex rate_limits (got: $CXO)"

# ---- codex fallback: token_count.info running total, immune to a repeated event ----
CX2="$LUW/codex-home-2"; mkdir -p "$CX2/sessions/x"
cp "$LUF/codex-prewindow.jsonl" "$CX2/sessions/x/rollout-b.jsonl"
python3 "$LU" snapshot codex "$CX2" /unused "$LUW/cx2.snap"
grep -v token_usage_record "$LUF/codex-tokencount-window.jsonl" >> "$CX2/sessions/x/rollout-b.jsonl"
CX2O="$(lu_run codex "$CX2" /unused "$LUW/cx2.snap")"
# 5600 - 5000 (the pre-window running total). Summing the repeated event's increments reads 800.
[ "$(lu_field "$CX2O" usage input_tokens)" = 600 ] && [ "$(lu_field "$CX2O" usage total_tokens)" = 660 ] \
  && [ "$(lu_field "$CX2O" usage source)" = codex-token-count ] \
  && ok "with no token_usage_record, codex falls back to the token_count running total's delta" \
  || fail "codex token_count fallback (got: $CX2O)"
[ "$(lu_field "$CX2O" rate_limits x)" = "<none>" ] \
  && ok "a window whose token_count carries no rate_limits reports rate_limits null" || fail "rate_limits not null (got: $CX2O)"

# A file that APPEARS after the snapshot (a replacement session) is read whole.
CX3="$LUW/codex-home-3"; mkdir -p "$CX3/sessions"
python3 "$LU" snapshot codex "$CX3" /unused "$LUW/cx3.snap"
mkdir -p "$CX3/sessions/2026"; cp "$LUF/codex-window.jsonl" "$CX3/sessions/2026/rollout-new.jsonl"
[ "$(lu_field "$(lu_run codex "$CX3" /unused "$LUW/cx3.snap")" usage total_tokens)" = 660 ] \
  && ok "a rollout created during the turn is read whole" || fail "new rollout file not counted"

# ---- MISSING IS null, NEVER 0 ----
CX4="$LUW/codex-home-4"; mkdir -p "$CX4/sessions/y"
cp "$LUF/codex-prewindow.jsonl" "$CX4/sessions/y/rollout-c.jsonl"
python3 "$LU" snapshot codex "$CX4" /unused "$LUW/cx4.snap"
printf '%s\n' '{"type":"turn_context","payload":{"turn_id":"t-x","root_turn_id":"t-x"}}' >> "$CX4/sessions/y/rollout-c.jsonl"
CX4O="$(lu_run codex "$CX4" /unused "$LUW/cx4.snap")"
printf '%s\n' "$CX4O" | grep -qx 'usage	null' && printf '%s\n' "$CX4O" | grep -qx 'rate_limits	null' \
  && ok "a window with records but no token data is usage null and rate_limits null, not zero" \
  || fail "no-token window (got: $CX4O)"
[ "$(lu_field "$(lu_run codex "$CX4" /unused "$LUW/cx4.snap")" usage x)" = "<none>" ] \
  && ok "collecting the same window twice still reports null (the reader has no zero default)" || fail "second collect not null"
# A field one record omits is null for the leg, never a partial sum passed off as complete.
CX5="$LUW/codex-home-5"; mkdir -p "$CX5/sessions"
python3 "$LU" snapshot codex "$CX5" /unused "$LUW/cx5.snap"
{ grep resp_r1 "$LUF/codex-window.jsonl"
  grep resp_r3 "$LUF/codex-window.jsonl" | sed 's/,"reasoning_output_tokens":0//'
} > "$CX5/sessions/rollout-d.jsonl"
CX5O="$(lu_run codex "$CX5" /unused "$LUW/cx5.snap")"
[ "$(lu_field "$CX5O" usage reasoning_output_tokens)" = null ] && [ "$(lu_field "$CX5O" usage input_tokens)" = 400 ] \
  && ok "a field one record lacks is null for the leg while the fields every record carries still sum" \
  || fail "partial field (got: $CX5O)"
# An unbounded window is null: a snapshotted file truncated during the turn.
cp "$LUF/codex-prewindow.jsonl" "$CX5/sessions/rollout-e.jsonl"
python3 "$LU" snapshot codex "$CX5" /unused "$LUW/cx5b.snap"
head -1 "$LUF/codex-prewindow.jsonl" > "$CX5/sessions/rollout-e.jsonl.tmp" && mv "$CX5/sessions/rollout-e.jsonl.tmp" "$CX5/sessions/rollout-e.jsonl"
printf '%s\n' "$(lu_run codex "$CX5" /unused "$LUW/cx5b.snap")" | grep -qx 'usage	null' \
  && ok "a record file replaced or truncated mid-turn makes usage null rather than a guess" || fail "unbounded window was summed"
# No snapshot at all (the runner could not take one) is null, and collect still exits 0.
LU_NS="$(python3 "$LU" collect codex "$CX" /unused "$LUW/absent.snap" 2>/dev/null)"; LU_NSR=$?
[ "$LU_NSR" = 0 ] && printf '%s\n' "$LU_NS" | grep -qx 'usage	null' \
  && ok "a missing snapshot answers usage null with exit 0" || fail "missing snapshot (rc=$LU_NSR: $LU_NS)"

# ---- claude: the transcript deduplicated by (message.id, requestId), last copy wins ----
CLC="$LUW/mounts/some-thread-claude/view/tree"; mkdir -p "$CLC"
CLR="$LUW/claude-projects"; CLD="$CLR/$(printf '%s' "$CLC" | sed 's/[^a-zA-Z0-9]/-/g')"; mkdir -p "$CLD"
printf '%s\n' '{"type":"assistant","cwd":"'"$CLC"'","requestId":"req_OLD","message":{"id":"msg_OLD","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":7}}}' > "$CLD/sess-1.jsonl"
python3 "$LU" snapshot claude "$CLR" "$CLC" "$LUW/cl.snap"
sed "s|@CWD@|$CLC|g" "$LUF/claude-window.jsonl" >> "$CLD/sess-1.jsonl"
CLO="$(lu_run claude "$CLR" "$CLC" "$LUW/cl.snap")"
# final copy of msg_A (120) + msg_B (40). A naive sum reads 165, first-copy-wins reads 45.
[ "$(lu_field "$CLO" usage output_tokens)" = 160 ] && [ "$(lu_field "$CLO" usage responses)" = 2 ] \
  && ok "claude records repeated per content block count once, from their final copy" \
  || fail "claude dedupe (got: $CLO)"
# input = input + cache writes + cache reads, codex's convention: (3+1000+0) + (2+100+1000).
[ "$(lu_field "$CLO" usage input_tokens)" = 2105 ] && [ "$(lu_field "$CLO" usage cached_input_tokens)" = 1000 ] \
  && [ "$(lu_field "$CLO" usage cache_write_input_tokens)" = 1100 ] && [ "$(lu_field "$CLO" usage total_tokens)" = 2265 ] \
  && ok "claude input normalises to include cache reads and writes (input 2105, total 2265)" \
  || fail "claude normalisation (got: $CLO)"
[ "$(lu_field "$CLO" usage reasoning_output_tokens)" = null ] && [ "$(lu_field "$CLO" usage turns)" = null ] \
  && ok "claude reports reasoning and turns null — it records neither — rather than 0" || fail "claude null fields (got: $CLO)"
[ "$(lu_field "$CLO" rate_limits x)" = "<none>" ] \
  && ok "a claude leg carries no rate_limits snapshot" || fail "claude rate_limits (got: $CLO)"
# A LONG cwd is truncated in the directory name; the neighbour sharing that prefix contributes nothing.
CLL="$LUW/mounts/$(printf 'x%.0s' $(seq 1 200))-claude/view/tree"; mkdir -p "$CLL"
CLS="$(printf '%s' "$CLL" | sed 's/[^a-zA-Z0-9]/-/g')"
CLLD="$CLR/$(printf '%s' "$CLS" | cut -c1-200)-h4sh"; mkdir -p "$CLLD"
python3 "$LU" snapshot claude "$CLR" "$CLL" "$LUW/cll.snap"
sed "s|@CWD@|$CLL|g" "$LUF/claude-window.jsonl" > "$CLLD/sess-2.jsonl"
CLLO="$(lu_run claude "$CLR" "$CLL" "$LUW/cll.snap")"
[ "$(lu_field "$CLLO" usage output_tokens)" = 160 ] \
  && ok "a truncated project directory is found by prefix and its foreign-cwd record is excluded" \
  || fail "claude long-cwd (got: $CLLO)"
# No growth -> null.
python3 "$LU" snapshot claude "$CLR" "$CLC" "$LUW/cl2.snap"
printf '%s\n' "$(lu_run claude "$CLR" "$CLC" "$LUW/cl2.snap")" | grep -qx 'usage	null' \
  && ok "a claude window with no new records is usage null" || fail "claude empty window not null"

# ---- grok: usage.json turns[] added during the leg ----
GRC="$LUW/mounts/some-thread-grok/view/tree"; mkdir -p "$GRC"
GRR="$LUW/grok-sessions"
GRD="$GRR/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$GRC")/g-1"; mkdir -p "$GRD"
cp "$LUF/grok-usage-before.json" "$GRD/usage.json"
python3 "$LU" snapshot grok "$GRR" "$GRC" "$LUW/gr.snap"
cp "$LUF/grok-usage-after.json" "$GRD/usage.json"
GRO="$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")"
# turns 2 and 3 only; counting the pre-existing turn 1 would read 51421.
[ "$(lu_field "$GRO" usage total_tokens)" = 3060 ] && [ "$(lu_field "$GRO" usage turns)" = 2 ] \
  && [ "$(lu_field "$GRO" usage responses)" = 4 ] \
  && ok "grok usage sums only the turns[] this leg added (total 3060 over 2 turns, 4 model calls)" \
  || fail "grok window (got: $GRO)"
[ "$(lu_field "$GRO" usage cached_input_tokens)" = 2700 ] && [ "$(lu_field "$GRO" usage reasoning_output_tokens)" = 35 ] \
  && [ "$(lu_field "$GRO" usage source)" = grok-usage-json ] \
  && ok "grok cached and reasoning tokens map onto the shared fields" || fail "grok field map (got: $GRO)"
cp "$LUF/grok-usage-after-partial.json" "$GRD/usage.json"
GRP="$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")"
[ "$(lu_field "$GRP" usage reasoning_output_tokens)" = null ] && [ "$(lu_field "$GRP" usage total_tokens)" = 3060 ] \
  && ok "a grok turn missing a field makes that field null, not a partial sum" || fail "grok partial field (got: $GRP)"
cp "$LUF/grok-usage-before.json" "$GRD/usage.json"
printf '%s\n' "$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")" | grep -qx 'usage	null' \
  && ok "a grok leg that added no turn is usage null" || fail "grok no-turn window not null"
printf 'not json' > "$GRD/usage.json"
printf '%s\n' "$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")" | grep -qx 'usage	null' \
  && ok "an unparseable grok usage.json is usage null" || fail "grok garbage not null"

