# Run through tests/run.sh; each group gets fresh fixtures.
fixture_ma_archive
fixture_agy
section "agy: runtime, doctor, the policy map and the stream reader (PATH-stubbed agy)"
# `agy` here is a real process on PATH (tests/fixtures/agy/agy_stub.py), so every verdict below is about a
# binary acp.sh actually ran, not about a string it matched. Nothing in this section reaches the real
# Antigravity CLI, the network, or ~/.gemini. The stub answers `--version` from AGY_VERSION.
AP="$REPO/helpers/acp.sh"
AS="$REPO/helpers/agy_stream.py"
AG_ABSENT_PATH="$AXB:/usr/bin:/bin"          # node stub and system tools, no agy anywhere
gacp() { env PATH="$AGB:$AXB:$PATH" "$@"; } # the stub agy first
gv() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k {print $2; exit}'; }
AG_MAPV="$(awk -F'\t' '$1=="version"{print $2; exit}' "$REPO/helpers/policy-map.tsv")"

[ -z "$(gacp "$AP" profile gemini)" ] && ! gacp "$AP" supports gemini \
  && ok "gemini has no acpx profile and supports reports no ACP session (agy has no ACP mode)" || fail "gemini still maps to an acpx profile"

# ---- runtime-check: the version, machine-readably; a refusal still names the version it judged ----
AG_OUT="$(gacp "$AP" runtime-check gemini 2>/dev/null)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && [ "$(gv "$AG_OUT" runtime_version)" = 1.3.1 ] && [ "$(gv "$AG_OUT" runtime)" = "$AGB/agy" ] \
  && printf '%s\n' "$AG_OUT" | awk -F'\t' '$1=="baseline" && $2=="gemini-3.8-flash" && $3=="baseline" && $5=="ok" {f=1} END{exit !f}' \
  && printf '%s\n' "$AG_OUT" | awk -F'\t' '$1=="ceiling" && $2=="gemini-3.8-flash" && $3=="max" && $5=="ok" {f=1} END{exit !f}'; } \
  && ok "runtime-check gemini reports the agy path, its version and both rows" || fail "runtime-check gemini (rc=$AG_RC out=$AG_OUT)"
AG_OUT="$(gacp AGY_VERSION=1.2.16 "$AP" runtime-check gemini 2>"$WORK/ag-rc.err")"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && [ "$(gv "$AG_OUT" runtime_version)" = 1.2.16 ] && grep -qF "agy 1.2.16 is older than 1.3.1" "$WORK/ag-rc.err" \
  && grep -qF "agy update" "$WORK/ag-rc.err"; } \
  && ok "runtime-check refuses an agy older than the exercised build (exit 1), names it, and still reports its version" \
  || fail "runtime-check on an old agy (rc=$AG_RC out=$AG_OUT err=$(cat "$WORK/ag-rc.err"))"
env PATH="$AG_ABSENT_PATH" "$AP" runtime-check gemini >/dev/null 2>"$WORK/ag-rc.err"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && grep -qF "the Antigravity CLI (agy) was not found on PATH" "$WORK/ag-rc.err"; } \
  && ok "runtime-check gemini with no agy installed: exit 1, named" || fail "runtime-check with no agy (rc=$AG_RC)"
gacp "$AP" runtime-check claude >/dev/null 2>&1; AG_RC=$?
[ "$AG_RC" = 2 ] && ok "runtime-check still refuses a provider with no runtime (exit 2)" || fail "runtime-check claude (rc=$AG_RC)"
gacp AGY_VERSION=1.3.1 "$AP" runtime-check gemini >/dev/null 2>&1 && gacp AGY_VERSION=1.10.0 "$AP" runtime-check gemini >/dev/null 2>&1 \
  && ok "the version floor compares numerically (1.3.1 and 1.10.0 are accepted)" || fail "version comparison"

# ---- doctor: reports agy; absent is informational, present-but-old is a failure ----
AG_OUT="$(gacp "$AP" doctor 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && printf '%s\n' "$AG_OUT" | grep -qF "reviewer gemini runtime: $AGB/agy (version 1.3.1) — runs agy directly (no ACP)" \
  && printf '%s\n' "$AG_OUT" | grep -qF "default gemini review: gemini-3.8-flash (baseline) — runs on this runtime" \
  && printf '%s\n' "$AG_OUT" | grep -qF "use-max gemini review (COMMS_REVIEW_MAX=1): gemini-3.8-flash (max) — runs on this runtime" \
  && printf '%s\n' "$AG_OUT" | grep -qF "gemini=agy" \
  && printf '%s\n' "$AG_OUT" | grep -qF "reviewer gemini containment: agy-plan"; } \
  && ok "doctor reports agy's version, that it runs directly, its default and use-max reviews, and its containment" \
  || fail "doctor with a current agy (rc=$AG_RC): $(printf '%s' "$AG_OUT" | grep -i gemini | tr '\n' ' ')"
AG_OUT="$(gacp AGY_VERSION=1.2.16 "$AP" doctor 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 4 ] && printf '%s\n' "$AG_OUT" | grep -qF "reviewer gemini runtime: $AGB/agy (version 1.2.16) — REFUSED: agy 1.2.16 is older than 1.3.1" \
  && printf '%s\n' "$AG_OUT" | grep -q '^result: FAIL'; } \
  && ok "doctor fails (exit 4) on an agy below the floor, naming the version" \
  || fail "doctor with an old agy (rc=$AG_RC): $(printf '%s' "$AG_OUT" | grep -iE 'gemini|result' | tr '\n' ' ')"
AG_OUT="$(env PATH="$AG_ABSENT_PATH" "$AP" doctor 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && printf '%s\n' "$AG_OUT" | grep -qF "reviewer gemini runtime: not installed"; } \
  && ok "doctor treats an absent agy as informational (opt-in reviewer), not a failure" \
  || fail "doctor with no agy (rc=$AG_RC): $(printf '%s' "$AG_OUT" | grep -i gemini | tr '\n' ' ')"

# ---- consult over ACP is gone: the mailbox/headless route is the consult path ----
AG_OUT="$(gacp "$AP" consult gemini hello 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_OUT" | grep -qF "has no ACP profile" && printf '%s' "$AG_OUT" | grep -qF "mailbox path"; } \
  && ok "acp.sh consult gemini is refused with the mailbox fallback (the consult is a direct agy turn instead)" || fail "acp consult gemini (rc=$AG_RC out=$AG_OUT)"

# ---- capabilities ----
AG_OUT="$(gacp "$AP" capabilities 2>&1)"
{ printf '%s\n' "$AG_OUT" | grep -qF "reviewer gemini runtime: $AGB/agy (version 1.3.1)" \
  && printf '%s\n' "$AG_OUT" | grep -qx "gemini/headless: eligible" \
  && printf '%s\n' "$AG_OUT" | grep -qx "gemini/acp: unsupported" \
  && printf '%s\n' "$AG_OUT" | grep -qx "gemini/acp-mounted: unsupported" \
  && printf '%s\n' "$AG_OUT" | grep -qF "gemini/headless gemini-3.8-flash accepts: low,medium,high" \
  && ! printf '%s\n' "$AG_OUT" | grep -qi 'DISABLED: not-released'; } \
  && ok "capabilities reports agy's version, headless eligible, no ACP capability, and the 3.8-flash pairs" \
  || fail "capabilities lacks the gemini rows: $(printf '%s' "$AG_OUT" | grep -i gemini | head -6 | tr '\n' ' ')"
AG_OUT="$(env PATH="$AG_ABSENT_PATH" "$AP" capabilities 2>&1)"
printf '%s\n' "$AG_OUT" | grep -qF "reviewer gemini runtime: none (version unknown) — REFUSED: the Antigravity CLI (agy) was not found on PATH" \
  && ok "capabilities says so when no agy is installed" || fail "capabilities with no agy"

# ---- resolve: model and effort, from the policy ----
AG_R="$(gacp "$AP" resolve gemini)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && [ "$(gv "$AG_R" model)" = gemini-3.8-flash ] && [ "$(gv "$AG_R" effort)" = high ] && [ "$(gv "$AG_R" transport)" = headless ] \
  && [ "$(gv "$AG_R" capability)" = eligible ] && [ "$(gv "$AG_R" verify)" = "model,effort" ] && [ "$(gv "$AG_R" pair)" = validated ] \
  && [ "$(gv "$AG_R" runtime)" = "$AGB/agy" ] && [ "$(gv "$AG_R" runtime_version)" = 1.3.1 ] \
  && [ "$(gv "$AG_R" map_version)" = "$AG_MAPV" ] && [ "$(gv "$AG_R" effective_tier)" = strong ]; } \
  && ok "resolve gemini: the baseline gemini-3.8-flash at high, transport headless, with the runtime and map version recorded" \
  || fail "resolve gemini baseline (rc=$AG_RC): $AG_R"
AG_OK=1
for AG_C in "fast low gemini-3.8-flash low" "balanced medium gemini-3.8-flash medium" "strong high gemini-3.8-flash high" "fast medium gemini-3.8-flash medium"; do
  set -- $AG_C
  AG_R="$(gacp "$AP" resolve gemini --routing on --decision rd-0 --tier "$1" --effort "$2" --phase implement --candidate-source explicit 2>&1)"
  { [ "$(gv "$AG_R" model)" = "$3" ] && [ "$(gv "$AG_R" effort)" = "$4" ] && [ "$(gv "$AG_R" model_source)" = route ]; } || { AG_OK=0; echo "  route $AG_C: $AG_R" | head -3; }
done
[ "$AG_OK" = 1 ] && ok "a routed candidate picks the pair: fast/low, balanced/medium and strong/high are all gemini-3.8-flash at the candidate's own effort" \
  || fail "routed gemini candidates"
AG_OUT="$(gacp "$AP" resolve gemini --routing on --decision rd-0 --tier strong --effort xhigh --phase implement --candidate-source explicit 2>&1 >/dev/null)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_OUT" | grep -qF "asks for effort 'xhigh', which the map does not define for gemini/headless"; } \
  && ok "an explicit candidate at an effort the map does not define (xhigh) is refused, never substituted" || fail "strong/xhigh (rc=$AG_RC $AG_OUT)"
AG_R="$(gacp "$AP" resolve gemini --routing on --decision rd-0 --tier fast --effort xhigh --phase implement --candidate-source auto 2>&1)"
{ [ "$(gv "$AG_R" model)" = gemini-3.8-flash ] && [ "$(gv "$AG_R" effort)" = high ] && [ "$(gv "$AG_R" effort_source)" = baseline ] \
  && printf '%s\n' "$AG_R" | grep -qF "unmapped-effort"; } \
  && ok "an unmapped routed effort (xhigh) falls back to the baseline effort while the routed model stands, recorded" || fail "xhigh routed: $AG_R"
AG_R="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.8-flash COMMS_ACP_GEMINI_EFFORT=low "$AP" resolve gemini)"
{ [ "$(gv "$AG_R" model)" = gemini-3.8-flash ] && [ "$(gv "$AG_R" effort)" = low ] && [ "$(gv "$AG_R" model_source)" = pin ] \
  && [ "$(gv "$AG_R" effective_tier)" = strong ]; } \
  && ok "the operator's pins (COMMS_ACP_GEMINI_MODEL / _EFFORT) bind the leg and are labelled as pins" || fail "gemini pins: $AG_R"
AG_OUT="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.1-pro COMMS_ACP_GEMINI_EFFORT=medium "$AP" resolve gemini 2>&1 >/dev/null)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_OUT" | grep -qF "does not accept effort 'medium'"; } \
  && ok "a pinned pair agy would refuse (3.1-pro at medium) is refused before launch" || fail "pro/medium pin (rc=$AG_RC $AG_OUT)"
AG_R="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.7-flash "$AP" resolve gemini --routing off 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_R" | grep -qF "does not accept effort 'high'" || [ "$(gv "$AG_R" pair)" = unverified-pin ]; } \
  && ok "a model the map does not know is only ever honoured as a labelled pin" || fail "unknown pin: rc=$AG_RC $AG_R"
AG_R="$(gacp COMMS_REVIEW_MAX=1 "$AP" resolve gemini)"
{ [ "$(gv "$AG_R" model)" = gemini-3.8-flash ] && [ "$(gv "$AG_R" effort)" = high ] && [ "$(gv "$AG_R" model_source)" = max ]; } \
  && ok "COMMS_REVIEW_MAX=1 runs the ceiling (gemini-3.8-flash/high, the strongest agy serves)" || fail "max: $AG_R"
AG_R="$(gacp "$AP" resolve gemini --transport acp-mounted --tier fast --effort low --routing on --decision rd-0 --phase implement --candidate-source explicit 2>&1)"
{ [ "$(gv "$AG_R" capability)" = unsupported ] && [ "$(gv "$AG_R" model)" = "n/a" ]; } \
  && ok "gemini over ACP applies and claims no policy (there is no gemini ACP session)" || fail "gemini/acp-mounted claims a policy: $AG_R"
AG_OUT="$(gacp "$AP" resolve gemini --transport acp-mounted --bound-model gemini-3.8-flash --bound-effort high --route-id r1 --access-digest "$(printf 'x%.0s' $(seq 64) | tr x 0)" 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_OUT" | grep -qF "code=capability-unsupported"; } \
  && ok "a bound resolution for gemini is refused capability-unsupported (a bound leg runs over ACP only)" || fail "bound gemini (rc=$AG_RC $AG_OUT)"
AG_OUT="$(gacp AGY_VERSION=1.2.16 "$AP" resolve gemini 2>&1 >/dev/null)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_OUT" | grep -qF "agy 1.2.16 is older than 1.3.1"; } \
  && ok "resolve refuses an agy below the floor rather than launching flags it was never exercised with" || fail "resolve on an old agy (rc=$AG_RC $AG_OUT)"
AG_OUT="$(gacp "$AP" containment gemini 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && printf '%s' "$AG_OUT" | grep -qF "backend	agy-plan"; } \
  && ok "containment gemini names the agy plan-mode backend" || fail "containment gemini (rc=$AG_RC $AG_OUT)"

# ---- the attestation verdict: the pair the init event names is judged against the persisted record ----
printf 'x' > /dev/null
gacp "$AP" resolve gemini > "$WORK/ag-policy.tsv"
AG_OUT="$(gacp "$AP" policy-attest gemini high gemini-3.8-flash --policy-file "$WORK/ag-policy.tsv" 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && [ "$AG_OUT" = "effort=high model=gemini-3.8-flash" ]; } \
  && ok "policy-attest accepts the declared pair" || fail "attest match (rc=$AG_RC $AG_OUT)"
AG_OUT="$(gacp "$AP" policy-attest gemini low gemini-3.8-flash --policy-file "$WORK/ag-policy.tsv" 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 20 ] && printf '%s' "$AG_OUT" | grep -qF "want effort=high model=gemini-3.8-flash; got effort=low"; } \
  && ok "policy-attest names a wrong effort (exit 20)" || fail "attest wrong effort (rc=$AG_RC $AG_OUT)"
AG_OUT="$(gacp "$AP" policy-attest gemini "" gemini-3.8-flash --policy-file "$WORK/ag-policy.tsv" 2>&1)"; AG_RC=$?
[ "$AG_RC" = 21 ] && ok "policy-attest with no observed effort is undecidable (exit 21), never a match" || fail "attest empty effort (rc=$AG_RC $AG_OUT)"

# ---- agy_stream.py: the reader of agy's own output ----
AG_EV="$WORK/ag-ev.ndjson"
cat > "$AG_EV" <<'AGEV'
{"event":"init","conversation_id":"c1","init":{"model":"gemini-3.8-flash-low","permission_mode":"request-review"}}
{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ERROR","step_type":"tool","tool_name":"write_to_file","tool_info":{"name":"write_to_file","error":{"type":"TOOL_ERROR","message":"permission check failed for write_file"}}}}
not json at all: a diagnostic line
{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"VERDICT: APPROVE\n\nThe 429 handling is fine; quota is discussed here.\n","usage":{"input_tokens":1000,"output_tokens":100,"thinking_tokens":40,"cache_read_tokens":500,"total_tokens":1100},"denied_actions":[{"action":"command","display_name":"RunCommand"}]}}
AGEV
{ [ "$(python3 "$AS" model "$AG_EV")" = gemini-3.8-flash-low ] && [ "$(python3 "$AS" attest "$AG_EV")" = "$(printf 'low\tgemini-3.8-flash')" ] \
  && [ "$(python3 "$AS" reply "$AG_EV" | head -1)" = "VERDICT: APPROVE" ]; } \
  && ok "agy_stream reads the init model, splits it into effort and model, and returns the answer text verbatim" || fail "agy_stream model/attest/reply"
AG_F="$(python3 "$AS" facts "$AG_EV")"
{ [ "$(gv "$AG_F" status)" = SUCCESS ] && [ "$(gv "$AG_F" denied)" = command ] && [ "$(gv "$AG_F" refused)" = write_to_file ] \
  && [ "$(gv "$AG_F" failure)" = "-" ]; } \
  && ok "facts records what agy refused (a denied command, a write that failed its permission check) and never classifies the ANSWER (a review that discusses a 429 is not a rate limit)" \
  || fail "agy_stream facts: $AG_F"
AG_U="$(python3 "$AS" usage "$AG_EV")"
[ "$AG_U" = '{"input_tokens":1500,"cached_input_tokens":500,"cache_write_input_tokens":null,"output_tokens":100,"reasoning_output_tokens":40,"total_tokens":1600,"turns":1,"responses":null}' ] \
  && ok "usage follows the codex convention: input includes the cached reads, total is input plus output, unknowns are null" || fail "agy_stream usage: $AG_U"
AG_OK=1
for AG_C in "RESOURCE_EXHAUSTED: 429 Too Many Requests|rate-limited" "you have exhausted your capacity|rate-limited" "Quota exceeded for this model|rate-limited" \
            "rpc error: PermissionDenied: SUBSCRIPTION_REQUIRED: needs a subscription|model-unavailable" "Please sign in to continue|auth-failed" \
            "UNAUTHENTICATED|auth-failed" "some unrelated diagnostic|"; do
  printf '%s\n' "${AG_C%|*}" > "$WORK/ag-diag.txt"
  [ "$(python3 "$AS" classify "$WORK/ag-diag.txt")" = "${AG_C##*|}" ] || { AG_OK=0; echo "  classify '${AG_C%|*}' -> '$(python3 "$AS" classify "$WORK/ag-diag.txt")'"; }
done
[ "$AG_OK" = 1 ] && ok "refusals are classified from diagnostics: rate-limited, model-unavailable (checked first), auth-failed, or nothing" || fail "agy_stream classify"
printf '%s' "an unterminated" > "$WORK/ag-bad.ndjson"
python3 "$AS" reply "$WORK/ag-bad.ndjson" >/dev/null 2>&1; AG_RC=$?
{ [ "$AG_RC" = 1 ] && [ "$(python3 "$AS" usage "$WORK/ag-bad.ndjson")" = null ]; } \
  && ok "a stream with no result event yields no reply (exit 1) and null usage, never an invented one" || fail "agy_stream on a headless stream (rc=$AG_RC)"

section "agy: a direct review and consult turn (stub agy over the real stream-json framing)"
# A real `runphase.sh run --provider gemini` turn (no --via: agy has no ACP mode) through the mount, the
# policy record, the canary, the stream reader and the broker. The stub agy parses the runner's actual stdin
# framing and prints the actual stream-json, so a refusal reaches runphase as agy's own result event would.
AGT="$WORK/ag-turn"; mkdir -p "$AGT"
AG_MBASE="$AGT/mbase"; mkdir -p "$AG_MBASE"; AG_MBASE="$(cd "$AG_MBASE" && pwd -P)"
AG_STORE="$AG_MBASE/agent-comms/mounts"
mkdir -p "$AGT/home/.gemini"
printf 'agents = claude codex grok gemini\ndefault-target = codex\n' > "$MA_FIX/.comms/config"
printf '.comms/\n' > "$MA_FIX/.gitignore"
mkdir -p "$MA_FIX/.comms/to-gemini" "$MA_FIX/.comms/to-claude"
# The operator's own agy state: it must be left exactly as found.
printf '{"trustedWorkspaces":["/"]}\n' > "$AGT/home/.gemini/settings.json"
AG_OP_SUM="$(cat "$AGT/home/.gemini/settings.json" | shasum | cut -d' ' -f1)"
# A dangling commit: HEAD's tree plus a marker, plus any extra tracked paths (built in a private index).
ag_artifact() { # <marker> [extra tracked path...] -> commit sha
  local marker="$1" idx="$AGT/idx.$1" blob t extra; shift
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$MA_FIX" read-tree HEAD
  blob="$(printf '%s\n' "$marker" | git -C "$MA_FIX" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$MA_FIX" update-index --add --cacheinfo "100644,$blob,ag-marker.txt"
  for extra in "$@"; do GIT_INDEX_FILE="$idx" git -C "$MA_FIX" update-index --add --cacheinfo "100644,$blob,$extra"; done
  t="$(GIT_INDEX_FILE="$idx" git -C "$MA_FIX" write-tree)"
  git -C "$MA_FIX" -c user.email=t@t -c user.name=t commit-tree "$t" -p HEAD -m "artifact $marker"
}
AG_HEAD="$(git -C "$MA_FIX" rev-parse HEAD)"
AG_A1="$(ag_artifact ag-round-1)"
ag_run() { # <msgfile> <dir> [env assignments...] -> runs the turn
  local msg="$1" dir="$2"; shift 2
  ( cd "$MA_FIX" && env PATH="$AGB:$AXB:$PATH" HOME="$AGT/home" COMMS_MOUNT_BASE="$AG_STORE" \
      AGY_LOG="$dir/stub.log" AGY_COUNT="$dir/count" AGY_ENV_VARS="COMMS_SELF CLAUDECODE GEMINI_CLI COMMS_PRESENCE_NAME" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_SELF=claude CLAUDECODE=1 GEMINI_CLI=1 COMMS_PRESENCE_NAME=drv \
      "$@" "$RP" run --message "$msg" --dir "$dir" --provider gemini --timeout-secs 30 ) >"$dir/stdout.log" 2>"$dir/stderr.log"
}
ag_turn() { # <thread> <tag> <artifact> [env assignments...] -> the run dir of a review-request turn
  local thread="$1" tag="$2" art="$3"; shift 3
  local msg dir
  msg="$MA_FIX/.comms/to-gemini/${MA_WS}_2026-10-07T10-00-00_ag-$tag.md"
  { head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
    printf 'artifact_id: %s\nhead_sha: %s\n' "$art" "$AG_HEAD"
    tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" | sed -e "s|^thread: ma-arc-1\$|thread: $thread|"
  } > "$msg"
  dir="$AGT/run-$tag"; mkdir -p "$dir"
  ag_run "$msg" "$dir" "$@"
  printf '%s' "$dir"
}
ag_ask_turn() { # <tag> [env assignments...] -> the run dir of a consult (type: question) turn
  local tag="$1"; shift
  local msg dir
  msg="$MA_FIX/.comms/to-gemini/${MA_WS}_2026-10-07T10-00-01_ag-$tag.md"
  { printf -- '---\ntype: question\nfrom: claude\ntimestamp: 2026-10-07T10:00:01Z\nworkspace: %s\nmessage_id: %s\n---\n\n## Question\n\nIs the policy map sound?\n' \
      "$MA_WS" "${MA_WS}_2026-10-07T10-00-01_ag-$tag"; } > "$msg"
  dir="$AGT/run-$tag"; mkdir -p "$dir"
  ag_run "$msg" "$dir" "$@"
  printf '%s' "$dir"
}
ag_res() { python3 -c '
import json,sys
d=json.load(open(sys.argv[1]+"/result.json"))
for k in sys.argv[2:]: d=d.get(k) if isinstance(d,dict) else None
print("<null>" if d is None else d)' "$@" 2>/dev/null; }
ag_log() { sed -n "s/^$2	//p" "$AGT/run-$1/stub.log" 2>/dev/null | head -1; }      # first value of a stub observation
ag_all() { sed -n "s/^$2	//p" "$AGT/run-$1/stub.log" 2>/dev/null; }                 # every value (one per agy invocation)
ag_tsv() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/turn.tsv" 2>/dev/null; }
ag_events() { (cd "$MA_FIX" && env "$COMMS" events --all --agent gemini --thread "$1" 2>/dev/null); }
ag_replies() { ls "$MA_FIX/.comms/to-claude/"*gemini-reply*.md 2>/dev/null | wc -l | tr -d ' '; }

# ---- a mounted review: canary, then the review, attested and published ----
AG_D1="$(ag_turn ag-thread t1 "$AG_A1")"
{ [ "$(ag_res "$AG_D1" status)" = completed ] && [ "$(ag_res "$AG_D1" provider)" = gemini ] && [ -z "$(ag_res "$AG_D1" reason)" ]; } \
  && ok "a mounted gemini review turn completes through agy (provider gemini, status completed)" \
  || fail "agy review did not complete: $(tr '\n' ' ' < "$AG_D1/result.json" 2>/dev/null | cut -c1-400) | $(tail -5 "$AG_D1/runner.log" 2>/dev/null | tr '\n' ' ')"
AG_REPLY="$(ls "$MA_FIX/.comms/to-claude/"*gemini-reply*.md 2>/dev/null | head -1)"
{ [ -n "$AG_REPLY" ] && grep -q '^from: gemini$' "$AG_REPLY" && grep -q '^verdict: APPROVE$' "$AG_REPLY"; } \
  && ok "the parent stamps and delivers the review as gemini's, with the verdict the reply carried" || fail "no stamped gemini reply (got: ${AG_REPLY:-none})"
AG_ARGV="$(ag_all t1 argv | tail -1)"
{ [ "$AG_ARGV" = "-p= --input-format stream-json --output-format stream-json --mode plan --model gemini-3.8-flash-high" ] \
  && ! printf '%s' "$AG_ARGV" | grep -qE 'dangerously|accept-edits|--sandbox'; } \
  && ok "agy is launched read-only on exactly one vector: plan mode, stream-json in and out, the policy's pair as <model>-<effort>" || fail "agy argv: $AG_ARGV"
{ [ "$(ag_all t1 turn_number | tr '\n' ' ')" = "1 2 " ] && [ "$(ag_all t1 prompt_head | head -1)" = "Reply with exactly the single word PONG and nothing else." ] \
  && [ "$(ag_all t1 prompt_has_runtime_note | tr '\n' ' ')" = "False True " ]; } \
  && ok "a canary turn runs first on the same vector; the review prompt follows on stdin and carries the plan-mode runtime note" \
  || fail "turn sequence: $(ag_all t1 turn_number | tr '\n' ' ') / $(ag_all t1 prompt_has_runtime_note | tr '\n' ' ')"
{ [ "$(ag_tsv "$AG_D1" requested_model)" = gemini-3.8-flash ] && [ "$(ag_tsv "$AG_D1" requested_effort)" = high ] \
  && [ "$(ag_tsv "$AG_D1" observed_model)" = gemini-3.8-flash ] && [ "$(ag_tsv "$AG_D1" observed_effort)" = high ] \
  && [ "$(ag_tsv "$AG_D1" evidence_source)" = agy-init-event ] && [ "$(ag_tsv "$AG_D1" agy_model)" = gemini-3.8-flash-high ] \
  && [ "$(ag_tsv "$AG_D1" canary_budget)" = 60 ]; } \
  && ok "turn.tsv records the requested pair, the pair agy's init event attested, the evidence source and the canary budget" \
  || fail "turn.tsv: $(grep -E '^(requested|observed|evidence_source|agy_model|canary)' "$AG_D1/turn.tsv" | tr '\t\n' '= ')"
{ [ "$(ag_res "$AG_D1" route model)" = gemini-3.8-flash ] && [ "$(ag_res "$AG_D1" route effort)" = high ] \
  && [ "$(ag_res "$AG_D1" route capability)" = eligible ] && [ "$(ag_res "$AG_D1" route transport)" = headless ]; } \
  && ok "result.json's route names what the leg was bound to: gemini-3.8-flash / high, eligible, transport headless" \
  || fail "route: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]+"/result.json"))["route"])' "$AG_D1")"
AG_USAGE="$(python3 -c 'import json,sys;u=json.load(open(sys.argv[1]+"/result.json"))["usage"];print(u["input_tokens"],u["cached_input_tokens"],u["output_tokens"],u["total_tokens"],u["turns"],u["cache_write_input_tokens"])' "$AG_D1" 2>&1)"
[ "$AG_USAGE" = "3000 1000 200 3200 2 None" ] \
  && ok "usage lands in result.json from agy's own result events, canary and review together (input 3000 incl. 1000 cached, output 200, 2 turns); what agy does not record is null" \
  || fail "usage: $AG_USAGE"
AG_CWD="$(ag_all t1 cwd | tail -1)"
{ case "$AG_CWD" in "$AG_STORE"/*) true ;; *) false ;; esac; } \
  && ok "agy ran inside the mount under the external store, never in the live repo" || fail "agy cwd '$AG_CWD' is not under $AG_STORE"
{ [ "$(ag_all t1 envvar_COMMS_SELF | tail -1)" = '<unset>' ] && [ "$(ag_all t1 envvar_CLAUDECODE | tail -1)" = '<unset>' ] \
  && [ "$(ag_all t1 envvar_GEMINI_CLI | tail -1)" = '<unset>' ] && [ "$(ag_all t1 envvar_COMMS_PRESENCE_NAME | tail -1)" = '<unset>' ]; } \
  && ok "the driver's identity (COMMS_SELF, presence, CLAUDECODE, GEMINI_CLI) never reaches agy" || fail "driver identity reached agy"
[ "$(cat "$AGT/home/.gemini/settings.json" | shasum | cut -d' ' -f1)" = "$AG_OP_SUM" ] \
  && ok "the operator's own agy settings are untouched by the turn" || fail "the operator's settings changed"
[ "$(ag_tsv "$AG_D1" agy_denied_actions)" = "-" ] && [ "$(ag_tsv "$AG_D1" agy_status)" = SUCCESS ] \
  && ok "a clean turn records no refused action and the result status agy reported" || fail "agy facts: $(grep '^agy_' "$AG_D1/turn.tsv" | tr '\t\n' '= ')"

# ---- the policy comes from the map and the pins, never from the runner ----
AG_D2="$(ag_turn ag-pin tpin "$AG_A1" COMMS_ACP_GEMINI_MODEL=gemini-3.8-flash COMMS_ACP_GEMINI_EFFORT=low)"
{ [ "$(ag_res "$AG_D2" status)" = completed ] && [ "$(ag_all tpin argv | tail -1 | sed 's/.*--model //')" = gemini-3.8-flash-low ] \
  && [ "$(ag_tsv "$AG_D2" observed_model)" = gemini-3.8-flash ] && [ "$(ag_tsv "$AG_D2" observed_effort)" = low ]; } \
  && ok "a pinned pair reaches agy as gemini-3.8-flash-low and is attested as that pair" || fail "pinned turn: argv=$(ag_all tpin argv | tail -1)"
AG_D3="$(ag_turn ag-drift tdrift "$AG_A1" AGY_INIT_MODEL=gemini-3.8-flash-low AGY_INIT_FROM=2)"
{ [ "$(ag_res "$AG_D3" status)" = failed ] && [ "$(ag_res "$AG_D3" reason)" = policy-unapplied ] && [ "$(ag_tsv "$AG_D3" observed_effort)" = low ]; } \
  && ok "a review whose init event names the right model at the wrong effort is withheld (policy-unapplied), with what ran recorded" \
  || fail "effort drift: $(tr '\n' ' ' < "$AG_D3/result.json" | cut -c1-300)"
AG_D4="$(ag_turn ag-nomodel tnomodel "$AG_A1" AGY_NO_MODEL=1 AGY_INIT_FROM=2)"
{ [ "$(ag_res "$AG_D4" reason)" = policy-unapplied ] && [ "$(ag_res "$AG_D4" status)" = failed ] && [ "$(ag_all tnomodel turn_number | tr '\n' ' ')" = "1 2 " ]; } \
  && ok "a REVIEW whose init event names no model is withheld (policy-unapplied): absent evidence is not a match" || fail "no-model: $(tr '\n' ' ' < "$AG_D4/result.json" | cut -c1-300)"
AG_D5="$(ag_turn ag-wrongmodel twrong "$AG_A1" AGY_INIT_MODEL=gemini-3.1-pro-high)"
{ [ "$(ag_res "$AG_D5" status)" = failed ] && [ "$(ag_res "$AG_D5" reason)" = runtime-incompatible ] && [ "$(ag_all twrong turn_number | tr '\n' ' ')" = "1 " ]; } \
  && ok "a canary served by another model than the declared one refuses the leg before the review prompt is spent" \
  || fail "wrong model: $(tr '\n' ' ' < "$AG_D5/result.json" | cut -c1-300)"

# ---- capacity: a refusal is classified from agy's own diagnostics, not reported as a generic failure ----
AG_D6="$(ag_turn ag-rl trl "$AG_A1" AGY_MODE=ratelimit)"
{ [ "$(ag_res "$AG_D6" status)" = failed ] && [ "$(ag_res "$AG_D6" reason)" = rate-limited ] && [ "$(ag_all trl turn_number | tr '\n' ' ')" = "1 " ] \
  && grep -q 'rate limit or quota is exhausted' "$AG_D6/result.json"; } \
  && ok "a rate limit at the canary is a FAILED turn with reason rate-limited and a note that says what to do (the review prompt is never spent)" \
  || fail "rate limit at the canary: $(tr '\n' ' ' < "$AG_D6/result.json" | cut -c1-400)"
{ [ "$(ag_res "$AG_D6" quota state)" = refused ] && [ "$(ag_res "$AG_D6" quota refusal kind)" = rate-limited ] \
  && [ "$(ag_res "$AG_D6" quota refusal reset_state)" = not_provided ] && [ "$(ag_res "$AG_D6" quota provider)" = gemini ]; } \
  && ok "the capacity refusal is also reported as quota state refused (kind rate-limited, no reset manufactured), for an unbound leg" \
  || fail "quota: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]+"/result.json"))["quota"])' "$AG_D6")"
AG_D7="$(ag_turn ag-rlr trlr "$AG_A1" AGY_MODE=ratelimit-review)"
{ [ "$(ag_res "$AG_D7" status)" = failed ] && [ "$(ag_res "$AG_D7" reason)" = rate-limited ] && [ "$(ag_all trlr turn_number | tr '\n' ' ')" = "1 2 " ]; } \
  && ok "a rate limit on the REVIEW prompt (the canary passed) is recorded rate-limited too" || fail "rate limit on the review: $(tr '\n' ' ' < "$AG_D7/result.json" | cut -c1-300)"
AG_EV_ROWS="$(ag_events ag-rlr)"
grep -q 'provider-result.*reason=rate-limited' <<<"$AG_EV_ROWS" \
  && ok "the provider-result event carries reason=rate-limited" || fail "no reason on the provider-result event"
AG_D8="$(ag_turn ag-sub tsub "$AG_A1" AGY_MODE=subscription)"
{ [ "$(ag_res "$AG_D8" status)" = failed ] && [ "$(ag_res "$AG_D8" reason)" = model-unavailable ] \
  && grep -q 'not available to this account' "$AG_D8/result.json" && [ "$(ag_res "$AG_D8" quota)" = '<null>' ]; } \
  && ok "SUBSCRIPTION_REQUIRED is the model being unavailable to this account (reason model-unavailable, said so in the note), not a crash and not a quota refusal" \
  || fail "subscription: $(tr '\n' ' ' < "$AG_D8/result.json" | cut -c1-400)"
AG_D9="$(ag_turn ag-auth tauth "$AG_A1" AGY_MODE=auth)"
{ [ "$(ag_res "$AG_D9" reason)" = auth-failed ] && grep -q 'log in again' "$AG_D9/result.json" && [ "$(ag_res "$AG_D9" quota state)" = refused ]; } \
  && ok "a login failure is reason auth-failed, with a note that says what to do" || fail "auth: $(tr '\n' ' ' < "$AG_D9/result.json" | cut -c1-300)"
AG_D10="$(ag_turn ag-silent tsilent "$AG_A1" AGY_MODE=silent)"
{ [ "$(ag_res "$AG_D10" status)" = failed ] && [ "$(ag_res "$AG_D10" reason)" = canary-exit-3 ]; } \
  && ok "an agy that exits non-zero with nothing at all is a refused canary (canary-exit-3), not an empty review" || fail "silent: $(tr '\n' ' ' < "$AG_D10/result.json" | cut -c1-300)"

# ---- read-only: a write attempt is refused by agy and detected by the mount's identity check ----
AG_D11="$(ag_turn ag-write twrite "$AG_A1" AGY_MODE=write)"
{ [ "$(ag_res "$AG_D11" status)" = failed ] && grep -q 'mount stopped matching' "$AG_D11/result.json" && [ -z "$(ag_res "$AG_D11" reason | tr -d '<null>')" ]; } \
  && ok "a file written into the mount during the turn fails the tree-identity check: the review is not published" \
  || fail "write breach: $(tr '\n' ' ' < "$AG_D11/result.json" | cut -c1-400)"
AG_D12="$(ag_turn ag-denied tdenied "$AG_A1" AGY_MODE=denied)"
{ [ "$(ag_res "$AG_D12" status)" = completed ] && [ "$(ag_tsv "$AG_D12" agy_denied_actions)" = command ] && [ "$(ag_tsv "$AG_D12" agy_refused_tools)" = write_to_file ] \
  && grep -q 'agy refused: denied_actions=command refused_tools=write_to_file' "$AG_D12/runner.log"; } \
  && ok "a refused command and a refused write are recorded (turn.tsv, runner.log) while the review still completes on an untouched tree" \
  || fail "denied: $(grep '^agy_' "$AG_D12/turn.tsv" | tr '\t\n' '= ')"
AG_NOBREACH="$(ls "$AG_STORE"/*/*/view/tree/pwn.txt 2>/dev/null | wc -l | tr -d ' ')"
[ "$AG_NOBREACH" = 0 ] && ok "no mount outlives its turn carrying the written file" || fail "a breach file survived in $AG_STORE"

# ---- hostile trees and a non-answer ----
AG_OK=1
for AG_CFG in .gemini .env .agents/hooks.json .agent .agy .antigravity .jetski mcp_config.json; do
  AG_SAFE="$(printf '%s' "$AG_CFG" | tr '/.' '__')"
  AG_AX="$(ag_artifact "ag-cfg-$AG_SAFE" "$AG_CFG")"
  AG_DX="$(ag_turn "ag-cfg-$AG_SAFE" "cfg$AG_SAFE" "$AG_AX")"
  { [ "$(ag_res "$AG_DX" status)" = failed ] && grep -q 'which agy reads from the workspace' "$AG_DX/result.json" && [ ! -f "$AGT/run-cfg$AG_SAFE/stub.log" ]; } \
    || { AG_OK=0; echo "  $AG_CFG not refused: $(tr '\n' ' ' < "$AG_DX/result.json" | cut -c1-200)"; }
done
[ "$AG_OK" = 1 ] && ok "a tree carrying agy's workspace config (.gemini, .env, .agents, .agent, .agy, .antigravity, .jetski, mcp_config.json) is refused before agy is started" \
  || fail "a hostile tree reached agy"
AG_D13="$(ag_turn ag-plan tplan "$AG_A1" AGY_PLANNY=1)"
{ [ "$(ag_res "$AG_D13" status)" = failed ] && [ "$(ag_replies)" = 3 ]; } \
  && ok "plan mode's non-answer (a plan and a request for approval) carries no verdict and is refused by the broker, never published" \
  || fail "planny: status=$(ag_res "$AG_D13" status) replies=$(ag_replies)"
AG_D14="$(ag_turn ag-nsuccess tnsuccess "$AG_A1" AGY_MODE=notsuccess)"
{ [ "$(ag_res "$AG_D14" status)" = failed ] && [ "$(ag_res "$AG_D14" reason)" = runtime-incompatible ]; } \
  && ok "a canary that ends with result status ERROR at exit 0 is refused: the status, not the exit code, decides" || fail "notsuccess: $(tr '\n' ' ' < "$AG_D14/result.json" | cut -c1-300)"
AG_D15="$(ag_turn ag-hang thang "$AG_A1" AGY_MODE=hang COMMS_RUNPHASE_TIMEOUT_SECS=2)"
sleep 0; AG_D15="$AGT/run-thang"
{ [ "$(ag_res "$AG_D15" status)" = timeout ] && [ "$(ag_res "$AG_D15" exit_code)" = 124 ]; } \
  && ok "a review that never ends is killed at the budget and recorded as timeout (exit 124)" || fail "hang: $(tr '\n' ' ' < "$AG_D15/result.json" | cut -c1-300)"
AG_D16="$(ag_turn ag-old told "$AG_A1" AGY_VERSION=1.2.16)"
{ [ "$(ag_res "$AG_D16" status)" = failed ] && [ "$(ag_res "$AG_D16" reason)" = policy-unapplied ] && [ ! -f "$AGT/run-told/count" ]; } \
  && ok "a turn on an agy below the floor is refused at policy resolution, before anything is launched" || fail "old agy: $(tr '\n' ' ' < "$AG_D16/result.json" | cut -c1-300)"

# ---- no ACP, one more way ----
( cd "$MA_FIX" && env PATH="$AGB:$AXB:$PATH" HOME="$AGT/home" "$RP" run --message "$MA_FIX/.comms/to-gemini/${MA_WS}_2026-10-07T10-00-00_ag-t1.md" --dir "$AGT/run-acp" --provider gemini --via acp ) >"$AGT/acp.out" 2>&1; AG_RC=$?
{ [ "$AG_RC" != 0 ] && grep -qF "has no ACP session" "$AGT/acp.out"; } \
  && ok "run --via acp for gemini is refused, naming why (agy has no ACP mode)" || fail "--via acp for gemini (rc=$AG_RC): $(cat "$AGT/acp.out")"

# ---- a consult: a cold agy turn, no canary, the same policy ----
AG_C1="$(ag_ask_turn c1)"
{ [ "$(ag_res "$AG_C1" status)" = completed ] && [ "$(ag_all c1 turn_number | tr '\n' ' ')" = "1 " ] && [ "$(ag_tsv "$AG_C1" observed_model)" = gemini-3.8-flash ]; } \
  && ok "a consult (type: question) completes as one cold agy turn: no canary, the policy's pair applied and attested" \
  || fail "consult: $(tr '\n' ' ' < "$AG_C1/result.json" | cut -c1-300) | $(tail -4 "$AG_C1/runner.log" | tr '\n' ' ')"
AG_CR="$(ls "$MA_FIX/.comms/to-claude/"*gemini-reply*.md 2>/dev/null | tail -1)"
{ grep -q '^type: response$' "$AG_CR" && ! grep -q '^verdict:' "$AG_CR"; } \
  && ok "the consult's reply is a response, not a verdict-bearing review" || fail "consult reply: $(head -8 "$AG_CR" | tr '\n' ' ')"
# `comms.sh ask` over the real routing: gemini is a headless reviewer/consult provider like grok.
AG_ASK="$( cd "$MA_FIX" && env -u COMMS_DELIVERY PATH="$AGB:$AXB:$PATH" HOME="$AGT/home" COMMS_MOUNT_BASE="$AG_STORE" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_SELF=claude \
            "$COMMS" ask --from claude --to gemini --wait "Is the policy map sound?" 2>&1 )"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && printf '%s\n' "$AG_ASK" | grep -qF "running gemini in the foreground" && printf '%s\n' "$AG_ASK" | grep -qF "completed: gemini finished"; } \
  && ok "comms.sh ask --to gemini --wait completes a consult through agy" || fail "ask --to gemini (rc=$AG_RC): $AG_ASK"
[ "$(cd "$MA_FIX" && env -u COMMS_DELIVERY PATH="$AGB:$AXB:$PATH" "$COMMS" transport gemini --loop)" = headless ] && [ "$(cd "$MA_FIX" && env -u COMMS_DELIVERY PATH="$AGB:$AXB:$PATH" "$COMMS" transport gemini)" = headless ] \
  && ok "gemini routes headless for a loop and for a consult (there is no ACP route)" || fail "transport gemini"

# ---- the opt-in live smoke: the real agy, only when COMMS_TEST_AGY_LIVE=1 ----
if [ "${COMMS_TEST_AGY_LIVE:-}" = 1 ]; then
  # The real agy, found on the operator's own PATH (the stub directory is left out) and run in their real home.
  AG_LMSG="$MA_FIX/.comms/to-gemini/${MA_WS}_2026-10-07T10-00-02_ag-live.md"
  { head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
    printf 'artifact_id: %s\nhead_sha: %s\n' "$AG_A1" "$AG_HEAD"
    tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" | sed -e 's|^thread: ma-arc-1$|thread: ag-live|'
  } > "$AG_LMSG"
  AG_LV="$AGT/run-live"; mkdir -p "$AG_LV"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" COMMS_MOUNT_BASE="$AG_STORE" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      "$RP" run --message "$AG_LMSG" --dir "$AG_LV" --provider gemini --timeout-secs 900 ) >"$AGT/live.out" 2>&1
  { [ "$(ag_res "$AG_LV" status)" = completed ] && [ "$(ag_tsv "$AG_LV" observed_model)" = gemini-3.8-flash ] && [ "$(ag_tsv "$AG_LV" observed_effort)" = high ]; } \
    && ok "LIVE: a mounted review through the real agy completes, canary included, on the attested pair" \
    || fail "LIVE agy review: $(tr '\n' ' ' < "$AG_LV/result.json" 2>/dev/null | cut -c1-400) | $(tail -5 "$AGT/live.out")"
else
  skip agy-live-off "LIVE agy review (set COMMS_TEST_AGY_LIVE=1 from a logged-in session to run it)"
fi

AG_WANT_REPLIES=5; [ "${COMMS_TEST_AGY_LIVE:-}" != 1 ] || AG_WANT_REPLIES=6   # the live review publishes one more
[ "$(ag_replies)" = "$AG_WANT_REPLIES" ] \
  && ok "only the completed turns published a reply (three reviews and two consults each replied once; every refused turn replied nothing)" \
  || fail "published replies: $(ag_replies), wanted $AG_WANT_REPLIES"
