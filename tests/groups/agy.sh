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
  && printf '%s\n' "$AG_OUT" | awk -F'\t' '$1=="baseline" && $2=="gemini-3.1-pro" && $3=="baseline" && $5=="ok" {f=1} END{exit !f}' \
  && printf '%s\n' "$AG_OUT" | awk -F'\t' '$1=="ceiling" && $2=="gemini-3.1-pro" && $3=="max" && $5=="ok" {f=1} END{exit !f}'; } \
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
  && printf '%s\n' "$AG_OUT" | grep -qF "default gemini review: gemini-3.1-pro (baseline) — runs on this runtime" \
  && printf '%s\n' "$AG_OUT" | grep -qF "use-max gemini review (COMMS_REVIEW_MAX=1): gemini-3.1-pro (max) — runs on this runtime" \
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
  && ok "capabilities reports agy's version, headless eligible, no ACP capability, and the 3.1-pro and 3.8-flash pairs" \
  || fail "capabilities lacks the gemini rows: $(printf '%s' "$AG_OUT" | grep -i gemini | head -6 | tr '\n' ' ')"
AG_OUT="$(env PATH="$AG_ABSENT_PATH" "$AP" capabilities 2>&1)"
printf '%s\n' "$AG_OUT" | grep -qF "reviewer gemini runtime: none (version unknown) — REFUSED: the Antigravity CLI (agy) was not found on PATH" \
  && ok "capabilities says so when no agy is installed" || fail "capabilities with no agy"

# ---- resolve: model and effort, from the policy ----
AG_R="$(gacp "$AP" resolve gemini)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && [ "$(gv "$AG_R" model)" = gemini-3.1-pro ] && [ "$(gv "$AG_R" effort)" = high ] && [ "$(gv "$AG_R" transport)" = headless ] \
  && [ "$(gv "$AG_R" capability)" = eligible ] && [ "$(gv "$AG_R" verify)" = "model,effort" ] && [ "$(gv "$AG_R" pair)" = validated ] \
  && [ "$(gv "$AG_R" runtime)" = "$AGB/agy" ] && [ "$(gv "$AG_R" runtime_version)" = 1.3.1 ] \
  && [ "$(gv "$AG_R" map_version)" = "$AG_MAPV" ] && [ "$(gv "$AG_R" effective_tier)" = strong ]; } \
  && ok "resolve gemini: the baseline gemini-3.1-pro at high, transport headless, with the runtime and map version recorded" \
  || fail "resolve gemini baseline (rc=$AG_RC): $AG_R"
AG_OK=1
for AG_C in "fast low gemini-3.8-flash low" "balanced high gemini-3.8-flash high" "strong high gemini-3.1-pro high" "fast medium gemini-3.8-flash medium"; do
  set -- $AG_C
  AG_R="$(gacp "$AP" resolve gemini --routing on --decision rd-0 --tier "$1" --effort "$2" --phase implement --candidate-source explicit 2>&1)"
  { [ "$(gv "$AG_R" model)" = "$3" ] && [ "$(gv "$AG_R" effort)" = "$4" ] && [ "$(gv "$AG_R" model_source)" = route ]; } || { AG_OK=0; echo "  route $AG_C: $AG_R" | head -3; }
done
[ "$AG_OK" = 1 ] && ok "a routed candidate picks the pair: fast/low and balanced/high are gemini-3.8-flash, strong/high is gemini-3.1-pro" \
  || fail "routed gemini candidates"
AG_OUT="$(gacp "$AP" resolve gemini --routing on --decision rd-0 --tier strong --effort medium --phase implement --candidate-source explicit 2>&1 >/dev/null)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_OUT" | grep -qF "model 'gemini-3.1-pro' does not accept effort 'medium'"; } \
  && ok "an explicit candidate the model cannot honour (3.1-pro has no medium) is refused, never substituted" || fail "pro/medium (rc=$AG_RC $AG_OUT)"
AG_R="$(gacp "$AP" resolve gemini --routing on --decision rd-0 --tier fast --effort xhigh --phase implement --candidate-source auto 2>&1)"
{ [ "$(gv "$AG_R" model)" = gemini-3.1-pro ] && printf '%s\n' "$AG_R" | grep -qF "unmapped-effort"; } \
  && ok "an unmapped routed effort (xhigh) falls back to the baseline, recorded" || fail "xhigh routed: $AG_R"
AG_R="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.8-flash COMMS_ACP_GEMINI_EFFORT=low "$AP" resolve gemini)"
{ [ "$(gv "$AG_R" model)" = gemini-3.8-flash ] && [ "$(gv "$AG_R" effort)" = low ] && [ "$(gv "$AG_R" model_source)" = pin ] \
  && [ "$(gv "$AG_R" effective_tier)" = fast ]; } \
  && ok "the operator's pins (COMMS_ACP_GEMINI_MODEL / _EFFORT) bind the leg and are labelled as pins" || fail "gemini pins: $AG_R"
AG_OUT="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.1-pro COMMS_ACP_GEMINI_EFFORT=medium "$AP" resolve gemini 2>&1 >/dev/null)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_OUT" | grep -qF "does not accept effort 'medium'"; } \
  && ok "a pinned pair agy would refuse (3.1-pro at medium) is refused before launch" || fail "pro/medium pin (rc=$AG_RC $AG_OUT)"
AG_R="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.7-flash "$AP" resolve gemini --routing off 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 1 ] && printf '%s' "$AG_R" | grep -qF "does not accept effort 'high'" || [ "$(gv "$AG_R" pair)" = unverified-pin ]; } \
  && ok "a model the map does not know is only ever honoured as a labelled pin" || fail "unknown pin: rc=$AG_RC $AG_R"
AG_R="$(gacp COMMS_REVIEW_MAX=1 "$AP" resolve gemini)"
{ [ "$(gv "$AG_R" model)" = gemini-3.1-pro ] && [ "$(gv "$AG_R" effort)" = high ] && [ "$(gv "$AG_R" model_source)" = max ]; } \
  && ok "COMMS_REVIEW_MAX=1 runs the ceiling (gemini-3.1-pro/high, the strongest agy serves)" || fail "max: $AG_R"
AG_R="$(gacp "$AP" resolve gemini --transport acp-mounted --tier fast --effort low --routing on --decision rd-0 --phase implement --candidate-source explicit 2>&1)"
{ [ "$(gv "$AG_R" capability)" = unsupported ] && [ "$(gv "$AG_R" model)" = "n/a" ]; } \
  && ok "gemini over ACP applies and claims no policy (there is no gemini ACP session)" || fail "gemini/acp-mounted claims a policy: $AG_R"
AG_OUT="$(gacp "$AP" resolve gemini --transport acp-mounted --bound-model gemini-3.1-pro --bound-effort high --route-id r1 --access-digest "$(printf 'x%.0s' $(seq 64) | tr x 0)" 2>&1)"; AG_RC=$?
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
AG_OUT="$(gacp "$AP" policy-attest gemini high gemini-3.1-pro --policy-file "$WORK/ag-policy.tsv" 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 0 ] && [ "$AG_OUT" = "effort=high model=gemini-3.1-pro" ]; } \
  && ok "policy-attest accepts the declared pair" || fail "attest match (rc=$AG_RC $AG_OUT)"
AG_OUT="$(gacp "$AP" policy-attest gemini low gemini-3.1-pro --policy-file "$WORK/ag-policy.tsv" 2>&1)"; AG_RC=$?
{ [ "$AG_RC" = 20 ] && printf '%s' "$AG_OUT" | grep -qF "want effort=high model=gemini-3.1-pro; got effort=low"; } \
  && ok "policy-attest names a wrong effort (exit 20)" || fail "attest wrong effort (rc=$AG_RC $AG_OUT)"
AG_OUT="$(gacp "$AP" policy-attest gemini "" gemini-3.1-pro --policy-file "$WORK/ag-policy.tsv" 2>&1)"; AG_RC=$?
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
