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
# lu_is <collect-output> <usage|rate_limits> <value> — exact match on one line, read to EOF. Never
# `printf | grep -q` here: grep -q exits on its first match, printf takes SIGPIPE, and pipefail
# turns a correct answer into a failure.
lu_is() { [ "$(printf '%s\n' "$1" | sed -n "s/^$2	//p")" = "$3" ]; }
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
# A BASELINE IS PROVEN, NEVER ASSUMED. Earlier billed work with no running total to subtract
# must not become a zero baseline that bills it to this leg (it would read 5,600 here). Nor may a
# malformed earlier record be skipped: the total behind it could be the true baseline.
CX6="$LUW/codex-home-6"; mkdir -p "$CX6/sessions"
grep -v '"token_count"' "$LUF/codex-prewindow.jsonl" > "$CX6/sessions/rollout-f.jsonl"
python3 "$LU" snapshot codex "$CX6" /unused "$LUW/cx6.snap"
grep -v token_usage_record "$LUF/codex-tokencount-window.jsonl" >> "$CX6/sessions/rollout-f.jsonl"
lu_is "$(lu_run codex "$CX6" /unused "$LUW/cx6.snap")" usage null \
  && ok "earlier billed work with no running total makes the fallback null, not a zero baseline" || fail "unproven codex baseline was assumed zero"
CX7="$LUW/codex-home-7"; mkdir -p "$CX7/sessions"
{ printf '{"type":"event_msg" BROKEN\n'; cat "$LUF/codex-prewindow.jsonl"; } > "$CX7/sessions/rollout-g.jsonl"
python3 "$LU" snapshot codex "$CX7" /unused "$LUW/cx7.snap"
grep -v token_usage_record "$LUF/codex-tokencount-window.jsonl" >> "$CX7/sessions/rollout-g.jsonl"
lu_is "$(lu_run codex "$CX7" /unused "$LUW/cx7.snap")" usage null \
  && ok "a malformed record before the window makes the fallback null rather than skipped" || fail "malformed baseline record was skipped"
# A STALE BASELINE: a total, then spend reported WITHOUT a total (last_token_usage only). The last
# total no longer describes the start of the window; subtracting it would bill the earlier 50 to
# this leg (codex, implement r2, blocking: read 70 where the leg spent 20). Same rule at the END:
# spend recorded after the window's last total means that total is not where the leg ended.
lu_tc() { printf '%s\n' '{"timestamp":"2026-09-25T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":'"$1"',"rate_limits":null}}'; }
lu_tot() { printf '{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":%s}}' "$1" "$1"; }
lu_last() { printf '{"last_token_usage":{"input_tokens":%s,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":%s}}' "$1" "$1"; }
CX9="$LUW/codex-home-9"; mkdir -p "$CX9/sessions"
{ lu_tc "$(lu_tot 100)"; lu_tc "$(lu_last 50)"; } > "$CX9/sessions/rollout-i.jsonl"
python3 "$LU" snapshot codex "$CX9" /unused "$LUW/cx9.snap"
lu_tc "$(lu_tot 170)" >> "$CX9/sessions/rollout-i.jsonl"
lu_is "$(lu_run codex "$CX9" /unused "$LUW/cx9.snap")" usage null \
  && ok "spend recorded after the last pre-window total makes the fallback null, not a stale baseline" || fail "stale codex baseline was subtracted"
CX10="$LUW/codex-home-10"; mkdir -p "$CX10/sessions"
lu_tc "$(lu_tot 100)" > "$CX10/sessions/rollout-j.jsonl"
python3 "$LU" snapshot codex "$CX10" /unused "$LUW/cx10.snap"
{ lu_tc "$(lu_tot 150)"; lu_tc "$(lu_last 20)"; } >> "$CX10/sessions/rollout-j.jsonl"
lu_is "$(lu_run codex "$CX10" /unused "$LUW/cx10.snap")" usage null \
  && ok "spend recorded after the window's last total makes the fallback null, not an early endpoint" || fail "early codex endpoint was used"
# CONTROL for both: a rate-limit-only token_count (info null) after a total is not spend.
CX11="$LUW/codex-home-11"; mkdir -p "$CX11/sessions"
{ lu_tc "$(lu_tot 100)"; lu_tc null; } > "$CX11/sessions/rollout-k.jsonl"
python3 "$LU" snapshot codex "$CX11" /unused "$LUW/cx11.snap"
{ lu_tc "$(lu_tot 170)"; lu_tc null; } >> "$CX11/sessions/rollout-k.jsonl"
[ "$(lu_field "$(lu_run codex "$CX11" /unused "$LUW/cx11.snap")" usage total_tokens)" = 70 ] \
  && ok "a rate-limit-only token_count does not unseat a total (control: 170 - 100 = 70)" || fail "info-null token_count treated as spend"
# Proven zero: the leg created the file itself (nothing before the window) — its first total is its own.
CX8="$LUW/codex-home-8"; mkdir -p "$CX8/sessions"
python3 "$LU" snapshot codex "$CX8" /unused "$LUW/cx8.snap"
grep -v token_usage_record "$LUF/codex-tokencount-window.jsonl" > "$CX8/sessions/rollout-h.jsonl"
[ "$(lu_field "$(lu_run codex "$CX8" /unused "$LUW/cx8.snap")" usage total_tokens)" = 6160 ] \
  && ok "a rollout the leg created itself has a proven zero baseline" || fail "fresh-file fallback"
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
lu_is "$CX4O" usage null && lu_is "$CX4O" rate_limits null \
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
lu_is "$(lu_run codex "$CX5" /unused "$LUW/cx5b.snap")" usage null \
  && ok "a record file replaced or truncated mid-turn makes usage null rather than a guess" || fail "unbounded window was summed"
# No snapshot at all (the runner could not take one) is null, and collect still exits 0.
LU_NS="$(python3 "$LU" collect codex "$CX" /unused "$LUW/absent.snap" 2>/dev/null)"; LU_NSR=$?
[ "$LU_NSR" = 0 ] && lu_is "$LU_NS" usage null \
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
  && ok "claude reports reasoning null when its transcript does not record thinking tokens, and turns null — not 0" \
  || fail "claude null fields (got: $CLO)"
# A runtime that DOES record thinking tokens (output_tokens_details.thinking_tokens) is summed.
CLT="$LUW/mounts/thinking-claude/view/tree"; mkdir -p "$CLT"
CLTD="$CLR/$(printf '%s' "$CLT" | sed 's/[^a-zA-Z0-9]/-/g')"; mkdir -p "$CLTD"
python3 "$LU" snapshot claude "$CLR" "$CLT" "$LUW/clt.snap"
sed -e "s|@CWD@|$CLT|g" -e 's/"output_tokens":\([0-9]*\)}/"output_tokens":\1,"output_tokens_details":{"thinking_tokens":4}}/' \
  "$LUF/claude-window.jsonl" > "$CLTD/sess-3.jsonl"
[ "$(lu_field "$(lu_run claude "$CLR" "$CLT" "$LUW/clt.snap")" usage reasoning_output_tokens)" = 8 ] \
  && ok "claude thinking tokens are the reasoning count when every response reports them" || fail "claude thinking tokens not summed"
[ "$(lu_field "$CLO" rate_limits x)" = "<none>" ] \
  && ok "a claude leg carries no rate_limits snapshot" || fail "claude rate_limits (got: $CLO)"
# A RESPONSE WITH NO USAGE is unknown spend, not no spend: every field goes null for the leg
# (codex, implement r2, blocking: 110 tokens over 1 response was reported as the total). Claude
# Code's own "<synthetic>" messages made no API call and are not responses.
CLM="$LUW/mounts/missing-usage-claude/view/tree"; mkdir -p "$CLM"
CLMD="$CLR/$(printf '%s' "$CLM" | sed 's/[^a-zA-Z0-9]/-/g')"; mkdir -p "$CLMD"
python3 "$LU" snapshot claude "$CLR" "$CLM" "$LUW/clm.snap"
{ sed "s|@CWD@|$CLM|g" "$LUF/claude-window.jsonl"
  printf '%s\n' '{"type":"assistant","cwd":"'"$CLM"'","requestId":"req_S","message":{"id":"msg_S","model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}'
} > "$CLMD/sess-4.jsonl"
CLMO="$(lu_run claude "$CLR" "$CLM" "$LUW/clm.snap")"
[ "$(lu_field "$CLMO" usage output_tokens)" = 160 ] && [ "$(lu_field "$CLMO" usage responses)" = 2 ] \
  && ok "a <synthetic> claude message is not counted as a response" || fail "synthetic message counted (got: $CLMO)"
printf '%s\n' '{"type":"assistant","cwd":"'"$CLM"'","requestId":"req_C","message":{"id":"msg_C","model":"m"}}' >> "$CLMD/sess-4.jsonl"
CLMO="$(lu_run claude "$CLR" "$CLM" "$LUW/clm.snap")"
[ "$(lu_field "$CLMO" usage output_tokens)" = null ] && [ "$(lu_field "$CLMO" usage total_tokens)" = null ] \
  && [ "$(lu_field "$CLMO" usage responses)" = 3 ] \
  && ok "a claude response with no usage makes the leg's token fields null rather than a partial sum" || fail "missing claude usage dropped (got: $CLMO)"
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
CL2O="$(lu_run claude "$CLR" "$CLC" "$LUW/cl2.snap")"
lu_is "$CL2O" usage null \
  && ok "a claude window with no new records is usage null" || fail "claude empty window not null (got: $CL2O)"

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
lu_is "$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")" usage null \
  && ok "a grok leg that added no turn is usage null" || fail "grok no-turn window not null"
# A REWRITTEN HISTORY cannot be split into "before" and "this leg". grok rewrites usage.json, so
# the file surviving by name proves nothing: turn 1 replaced by different content (a reset that
# reuses turn numbers), or turn 1 dropped, must read null — not turns 2 and 3 as this leg's.
# (codex, implement r1, blocking.)
sed 's/"outputTokens":41,/"outputTokens":42,/' "$LUF/grok-usage-after.json" > "$GRD/usage.json"
lu_is "$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")" usage null \
  && ok "a grok history whose earlier turn changed content is usage null (reset, not growth)" || fail "rewritten grok turn was trusted"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["turns"]=d["turns"][1:]; json.dump(d,open(sys.argv[2],"w"))' \
  "$LUF/grok-usage-after.json" "$GRD/usage.json"
lu_is "$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")" usage null \
  && ok "a grok history that lost an earlier turn is usage null" || fail "dropped grok turn was trusted"
sed 's/"sessionId":"g-1"/"sessionId":"g-other"/' "$LUF/grok-usage-after.json" > "$GRD/usage.json"
lu_is "$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")" usage null \
  && ok "a grok usage.json that now names a different session is usage null" || fail "session swap was trusted"
printf 'not json' > "$GRD/usage.json"
lu_is "$(lu_run grok "$GRR" "$GRC" "$LUW/gr.snap")" usage null \
  && ok "an unparseable grok usage.json is usage null" || fail "grok garbage not null"


# ---- an ABSENT records root is empty; an UNREADABLE one is not evidence of anything ----
# A leg's first turn on a machine (or in a fresh HOME) has no ~/.grok/sessions yet; the records
# the turn creates must count. A root that exists but cannot be listed must refuse instead.
GRA="$LUW/grok-absent/sessions"
python3 "$LU" snapshot grok "$GRA" "$GRC" "$LUW/gra.snap" \
  && ok "a snapshot over a records root that does not exist yet succeeds (empty)" || fail "absent root refused"
GRAD="$GRA/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$GRC")/g-2"; mkdir -p "$GRAD"
cp "$LUF/grok-usage-before.json" "$GRAD/usage.json"
[ "$(lu_field "$(lu_run grok "$GRA" "$GRC" "$LUW/gra.snap")" usage total_tokens)" = 24231 ] \
  && ok "records created under a root that was absent at snapshot time are counted" || fail "absent-root turn not counted"
LU_UNR="$LUW/unreadable-projects"; mkdir -p "$LU_UNR/x"; chmod 000 "$LU_UNR"
python3 "$LU" snapshot claude "$LU_UNR" "$CLC" "$LUW/unr.snap" 2>/dev/null \
  && fail "an unreadable records root was snapshotted as empty" || ok "an unreadable records root refuses the snapshot rather than reading as empty"
chmod 755 "$LU_UNR"
