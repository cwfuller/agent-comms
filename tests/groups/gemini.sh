# Run through tests/run.sh; each group gets fresh fixtures.
fixture_ma_archive
fixture_gemini
section "gemini: the ACP profile, runtime, doctor and policy map (PATH-stubbed gemini)"
# `gemini` here is a real process on PATH (tests/fixtures/gemini/gemini_stub.py), so every verdict below
# is about a binary acp.sh actually ran, not about a string it matched. Nothing in this group reaches the
# real Gemini CLI, the network, or ~/.gemini. The stub answers `--version` from GM_VERSION.
AP="$REPO/helpers/acp.sh"
GM_ABSENT_PATH="$AXB:/usr/bin:/bin"          # node stub and system tools, no gemini anywhere
gacp() { env PATH="$GMB:$AXB:$PATH" "$@"; } # the stub gemini first
gv() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k {print $2; exit}'; }
GM_MAPV="$(awk -F'\t' '$1=="version"{print $2; exit}' "$REPO/helpers/policy-map.tsv")"

[ "$(gacp "$AP" profile gemini)" = gemini ] \
  && ok "gemini maps to acpx's own gemini profile (gemini --acp)" || fail "gemini has no acpx profile"
gacp "$AP" supports gemini && ok "supports gemini: exit 0 with a current gemini on PATH" || fail "supports gemini refused a current gemini"
GM_OUT="$(gacp GM_VERSION=0.32.9 "$AP" supports gemini 2>&1)"; GM_RC=$?
[ "$GM_RC" = 1 ] && ok "supports gemini: exit 1 for a gemini older than the first --acp release (0.32.9)" \
  || fail "supports accepted a gemini with no --acp (rc=$GM_RC)"
env PATH="$GM_ABSENT_PATH" "$AP" supports gemini >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 1 ] && ok "supports gemini: exit 1 when no gemini is installed" || fail "supports gemini passed with no gemini (rc=$GM_RC)"
gacp GM_VERSION=0.33.0 "$AP" supports gemini && ok "supports gemini: the first --acp release (0.33.0) is accepted" || fail "0.33.0 refused"

# ---- runtime-check: the version, machine-readably; a refusal still names the version it judged ----
GM_OUT="$(gacp "$AP" runtime-check gemini 2>/dev/null)"; GM_RC=$?
{ [ "$GM_RC" = 0 ] && [ "$(gv "$GM_OUT" runtime_version)" = 0.62.0 ] && [ "$(gv "$GM_OUT" runtime)" = "$GMB/gemini" ] \
  && printf '%s\n' "$GM_OUT" | awk -F'\t' '$1=="baseline" && $2=="gemini-3.1-pro-preview" && $3=="baseline" && $5=="ok" {f=1} END{exit !f}' \
  && printf '%s\n' "$GM_OUT" | awk -F'\t' '$1=="ceiling" && $2=="gemini-3.1-pro-preview" && $3=="max" && $5=="ok" {f=1} END{exit !f}'; } \
  && ok "runtime-check gemini reports the path, the version and both rows" || fail "runtime-check gemini (rc=$GM_RC out=$GM_OUT)"
GM_OUT="$(gacp GM_VERSION=0.32.9 "$AP" runtime-check gemini 2>"$WORK/gm-rc.err")"; GM_RC=$?
{ [ "$GM_RC" = 1 ] && [ "$(gv "$GM_OUT" runtime_version)" = 0.32.9 ] && grep -qF "gemini 0.32.9 has no --acp flag" "$WORK/gm-rc.err" \
  && grep -qF "first shipped in 0.33.0" "$WORK/gm-rc.err"; } \
  && ok "runtime-check gemini refuses a gemini without --acp (exit 1) yet still reports its version" \
  || fail "runtime-check on an old gemini (rc=$GM_RC out=$GM_OUT err=$(cat "$WORK/gm-rc.err"))"
env PATH="$GM_ABSENT_PATH" "$AP" runtime-check gemini >/dev/null 2>"$WORK/gm-rc.err"; GM_RC=$?
{ [ "$GM_RC" = 1 ] && grep -qF "the gemini CLI was not found on PATH" "$WORK/gm-rc.err"; } \
  && ok "runtime-check gemini with no gemini installed: exit 1, named" || fail "runtime-check with no gemini (rc=$GM_RC)"
gacp "$AP" runtime-check claude >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 2 ] && ok "runtime-check still refuses a provider with no runtime (exit 2)" || fail "runtime-check claude (rc=$GM_RC)"

# ---- doctor: reports the Gemini CLI; absent is informational, present-but-old is a failure ----
GM_OUT="$(gacp "$AP" doctor 2>&1)"; GM_RC=$?
{ [ "$GM_RC" = 0 ] && printf '%s\n' "$GM_OUT" | grep -qF "reviewer gemini runtime: $GMB/gemini (version 0.62.0) — supports --acp" \
  && printf '%s\n' "$GM_OUT" | grep -qF "default gemini review: gemini-3.1-pro-preview (baseline) — runs on this runtime" \
  && printf '%s\n' "$GM_OUT" | grep -qF "use-max gemini review (COMMS_REVIEW_MAX=1): gemini-3.1-pro-preview (max) — runs on this runtime" \
  && printf '%s\n' "$GM_OUT" | grep -qF "gemini=gemini"; } \
  && ok "doctor reports the Gemini CLI version, that it supports --acp, and its default and use-max reviews" \
  || fail "doctor with a current gemini (rc=$GM_RC): $(printf '%s' "$GM_OUT" | grep -i gemini | tr '\n' ' ')"
GM_OUT="$(gacp GM_VERSION=0.32.9 "$AP" doctor 2>&1)"; GM_RC=$?
{ [ "$GM_RC" = 4 ] && printf '%s\n' "$GM_OUT" | grep -qF "reviewer gemini runtime: $GMB/gemini (version 0.32.9) — REFUSED: gemini 0.32.9 has no --acp flag" \
  && printf '%s\n' "$GM_OUT" | grep -q '^result: FAIL'; } \
  && ok "doctor fails (exit 4) on a Gemini CLI without --acp, naming the version" \
  || fail "doctor with an old gemini (rc=$GM_RC): $(printf '%s' "$GM_OUT" | grep -iE 'gemini|result' | tr '\n' ' ')"
GM_OUT="$(env PATH="$GM_ABSENT_PATH" "$AP" doctor 2>&1)"; GM_RC=$?
{ [ "$GM_RC" = 0 ] && printf '%s\n' "$GM_OUT" | grep -qF "reviewer gemini runtime: not installed"; } \
  && ok "doctor treats an absent Gemini CLI as informational (opt-in reviewer), not a failure" \
  || fail "doctor with no gemini (rc=$GM_RC): $(printf '%s' "$GM_OUT" | grep -i gemini | tr '\n' ' ')"

# ---- capabilities ----
GM_OUT="$(gacp "$AP" capabilities 2>&1)"
{ printf '%s\n' "$GM_OUT" | grep -qF "reviewer gemini runtime: $GMB/gemini (version 0.62.0)" \
  && printf '%s\n' "$GM_OUT" | grep -qx "gemini/acp-mounted: fixed" \
  && printf '%s\n' "$GM_OUT" | grep -qF "gemini/acp-mounted gemini-4-pro is DISABLED: not-released-2026-09-30"; } \
  && ok "capabilities reports the Gemini CLI version, the fixed capability and the disabled Gemini 4 row" \
  || fail "capabilities lacks the gemini rows: $(printf '%s' "$GM_OUT" | grep -i gemini | head -5 | tr '\n' ' ')"
GM_OUT="$(env PATH="$GM_ABSENT_PATH" "$AP" capabilities 2>&1)"
printf '%s\n' "$GM_OUT" | grep -qF "reviewer gemini runtime: none (version unknown) — REFUSED: the gemini CLI was not found on PATH" \
  && ok "capabilities says so when no Gemini CLI is installed" || fail "capabilities with no gemini"

# ---- resolve: model and thinking level bound per leg ----
GM_R="$(gacp "$AP" resolve gemini)"; GM_RC=$?
{ [ "$GM_RC" = 0 ] && [ "$(gv "$GM_R" model)" = gemini-3.1-pro-preview ] && [ "$(gv "$GM_R" effort)" = high ] \
  && [ "$(gv "$GM_R" capability)" = fixed ] && [ "$(gv "$GM_R" verify)" = "model,effort" ] && [ "$(gv "$GM_R" pair)" = validated ] \
  && [ "$(gv "$GM_R" runtime)" = "$GMB/gemini" ] && [ "$(gv "$GM_R" runtime_version)" = 0.62.0 ] \
  && [ "$(gv "$GM_R" map_version)" = "$GM_MAPV" ] && [ "$(gv "$GM_R" effective_tier)" = strong ]; } \
  && ok "resolve gemini: the baseline (gemini-3.1-pro-preview/high) with the runtime and map version recorded" \
  || fail "resolve gemini baseline (rc=$GM_RC): $GM_R"
GM_R="$(gacp "$AP" resolve gemini --transport acp --tier fast --effort low --routing on --decision rd-0 --phase implement --candidate-source explicit 2>&1)"; GM_RC=$?
{ [ "$GM_RC" = 0 ] && [ "$(gv "$GM_R" capability)" = unsupported ] && [ "$(gv "$GM_R" model)" = "n/a" ]; } \
  && ok "an unmounted gemini turn applies and claims no policy (the operator's own ~/.gemini runs)" || fail "gemini/acp claims a policy: $GM_R"
GM_R="$(gacp "$AP" resolve gemini --routing on --decision rd-0 --tier fast --effort low --phase implement --candidate-source auto 2>&1)"
{ [ "$(gv "$GM_R" model)" = gemini-3.1-pro-preview ] && [ "$(gv "$GM_R" effort)" = high ] \
  && printf '%s\n' "$GM_R" | grep -qF "capability-fixed"; } \
  && ok "a routed fast/low candidate is IGNORED while the capability is fixed: the baseline runs, the fallback is recorded" \
  || fail "routing changed a fixed gemini: $GM_R"
GM_R="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.5-flash COMMS_ACP_GEMINI_EFFORT=low "$AP" resolve gemini)"
{ [ "$(gv "$GM_R" model)" = gemini-3.5-flash ] && [ "$(gv "$GM_R" effort)" = low ] && [ "$(gv "$GM_R" model_source)" = pin ] \
  && [ "$(gv "$GM_R" effective_tier)" = balanced ]; } \
  && ok "the operator's pins (COMMS_ACP_GEMINI_MODEL / _EFFORT) bind the leg and are labelled as pins" || fail "gemini pins: $GM_R"
GM_OUT="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.5-flash-lite "$AP" resolve gemini 2>&1 >/dev/null)"; GM_RC=$?
{ [ "$GM_RC" = 1 ] && printf '%s' "$GM_OUT" | grep -qF "model 'gemini-3.5-flash-lite' does not accept effort 'high'"; } \
  && ok "a model with no thinking control refuses the baseline's level instead of being sent it" || fail "flash-lite accepted high (rc=$GM_RC $GM_OUT)"
GM_R="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.5-flash-lite COMMS_ACP_GEMINI_EFFORT=default "$AP" resolve gemini)"
[ "$(gv "$GM_R" model)" = gemini-3.5-flash-lite ] && [ "$(gv "$GM_R" effort)" = default ] \
  && ok "...and accepts the explicit no-override effort (default)" || fail "flash-lite/default: $GM_R"
GM_OUT="$(gacp GM_VERSION=0.32.9 "$AP" resolve gemini 2>&1 >/dev/null)"; GM_RC=$?
{ [ "$GM_RC" = 1 ] && printf '%s' "$GM_OUT" | grep -qF "gemini 0.32.9 has no --acp flag"; } \
  && ok "resolve refuses a gemini without --acp rather than launching a flag it lacks" || fail "resolve on an old gemini (rc=$GM_RC $GM_OUT)"

# ---- the Gemini 4 row: clearly marked, in the map, and inert until it exists ----
{ awk -F'\t' '$1=="disabled" && $2=="gemini" && $3=="acp-mounted" && $4=="gemini-4-pro" && $5=="not-released-2026-09-30" {f=1} END{exit !f}' "$REPO/helpers/policy-map.tsv" \
  && grep -q '^# GEMINI 4 — DISABLED until it exists' "$REPO/helpers/policy-map.tsv"; } \
  && ok "the map carries a clearly marked, disabled Gemini 4 row" || fail "no marked disabled Gemini 4 row"
GM_OUT="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-4-pro "$AP" resolve gemini 2>&1 >/dev/null)"; GM_RC=$?
{ [ "$GM_RC" = 1 ] && printf '%s' "$GM_OUT" | grep -qF "model 'gemini-4-pro' (pin) is disabled in the policy map (not-released-2026-09-30"; } \
  && ok "pinning the disabled Gemini 4 id is refused, naming why" || fail "gemini-4-pro pin not refused (rc=$GM_RC $GM_OUT)"
# A routed tier skips it; removing the ONE disabled row is the whole act of enabling it. A crafted map
# stands in for "capability eligible", which is the only state where a tier is consulted.
GM_PM="$WORK/gm-map"; rm -rf "$GM_PM"; mkdir -p "$GM_PM"; cp "$AP" "$GM_PM/acp.sh"; chmod +x "$GM_PM/acp.sh"
sed 's/^\(capability\tgemini\tacp-mounted\t\)fixed\t/\1eligible\t/' "$REPO/helpers/policy-map.tsv" > "$GM_PM/policy-map.tsv"
GM_RT="$(gacp "$GM_PM/acp.sh" resolve gemini --routing on --decision rd-0 --tier strong --effort high --phase implement --candidate-source auto 2>&1)"
{ [ "$(gv "$GM_RT" capability)" = eligible ] && [ "$(gv "$GM_RT" model)" = gemini-3.1-pro-preview ] && [ "$(gv "$GM_RT" model_source)" = route ] \
  && printf '%s\n' "$GM_RT" | grep -qF "disabled:gemini-4-pro"; } \
  && ok "a routed strong tier skips the disabled Gemini 4 model to the next preference, and records that it did" || fail "strong tier did not skip gemini-4-pro: $GM_RT"
grep -v '^disabled	gemini	acp-mounted	gemini-4-pro	' "$GM_PM/policy-map.tsv" > "$GM_PM/enabled.tsv" && mv "$GM_PM/enabled.tsv" "$GM_PM/policy-map.tsv"
GM_RT="$(gacp "$GM_PM/acp.sh" resolve gemini --routing on --decision rd-0 --tier strong --effort high --phase implement --candidate-source auto 2>&1)"
[ "$(gv "$GM_RT" model)" = gemini-4-pro ] && ok "deleting the one disabled row enables Gemini 4 (its tier and pair rows were already written)" \
  || fail "removing the disabled row did not enable gemini-4-pro: $GM_RT"
# A malformed disabled row refuses the WHOLE map, like every other row kind.
printf 'disabled\tgemini\tacp-mounted\tgemini-x\n' >> "$GM_PM/policy-map.tsv"
gacp "$GM_PM/acp.sh" capabilities >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 1 ] && ok "a malformed disabled row refuses the whole policy map" || fail "a malformed disabled row was tolerated (rc=$GM_RC)"

# ---- provider-config: the isolated settings.json, and nothing the allowlist does not admit ----
GM_REC="$WORK/gm-policy.tsv"; gacp "$AP" resolve gemini > "$GM_REC"
GM_CFG="$(gacp "$AP" provider-config gemini --policy-file "$GM_REC" --auth-type gemini-api-key)"
GM_CHK="$(printf '%s' "$GM_CFG" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ov=d["modelConfigs"]["customOverrides"][0]
print(d["model"]["name"], ov["match"]["model"], ov["modelConfig"]["generateContentConfig"]["thinkingConfig"]["thinkingLevel"],
      d["general"]["plan"]["modelRouting"], d["general"]["enableAutoUpdate"], d["security"]["auth"]["selectedType"])' 2>&1)"
[ "$GM_CHK" = "gemini-3.1-pro-preview gemini-3.1-pro-preview HIGH False False gemini-api-key" ] \
  && ok "provider-config gemini is valid JSON binding the model, its thinking level, plan routing off and the carried auth type" \
  || fail "gemini settings.json (got: $GM_CHK)"
GM_CFG="$(gacp "$AP" provider-config gemini --policy-file "$GM_REC")"
printf '%s' "$GM_CFG" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(1 if "security" in d else 0)' \
  && ok "without an operator auth type the isolated settings carry no auth selection at all" || fail "an auth selection appeared from nowhere"
gacp "$AP" provider-config gemini --policy-file "$GM_REC" --auth-type 'x","mcpServers":{"a":1},"y":"' >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 1 ] && ok "an auth type that is not a bare identifier is refused, never interpolated" || fail "auth type injection not refused (rc=$GM_RC)"
gacp COMMS_ACP_GEMINI_MODEL='gemini-3.1-pro-preview","x":"' "$AP" provider-config gemini >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 1 ] && ok "a model carrying a quote is refused at the accessor before any settings text exists" || fail "model injection not refused (rc=$GM_RC)"
GM_R="$(gacp COMMS_ACP_GEMINI_MODEL=gemini-3.5-flash-lite COMMS_ACP_GEMINI_EFFORT=default "$AP" resolve gemini)"; printf '%s\n' "$GM_R" > "$WORK/gm-policy2.tsv"
GM_CFG="$(gacp "$AP" provider-config gemini --policy-file "$WORK/gm-policy2.tsv")"
printf '%s' "$GM_CFG" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(1 if "modelConfigs" in d else 0)' \
  && ok "effort default writes NO thinking override (a model with no thinking control is left alone)" || fail "default effort still wrote an override"
printf '%s\n' "$GM_CFG" > "$WORK/gm-cfg-default.json"; printf '%s\n' "$(gacp "$AP" provider-config gemini --policy-file "$GM_REC")" > "$WORK/gm-cfg-high.json"
{ [ "$(gacp "$AP" gemini-effort "$WORK/gm-cfg-high.json")" = high ] && [ "$(gacp "$AP" gemini-effort "$WORK/gm-cfg-default.json")" = default ]; } \
  && ok "gemini-effort reads the thinking level back from a settings.json in the policy's own vocabulary" || fail "gemini-effort round trip"
printf '{"model":{"name":"m"},"modelConfigs":{"customOverrides":[{"match":{"model":"m"},"modelConfig":{"generateContentConfig":{"thinkingConfig":{"thinkingLevel":"MAX"}}}}]}}' > "$WORK/gm-cfg-bad.json"
gacp "$AP" gemini-effort "$WORK/gm-cfg-bad.json" >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 1 ] && ok "a thinking level outside the vocabulary reads back as undecidable, never as a match" || fail "an unknown level read back (rc=$GM_RC)"
[ "$(gacp "$AP" gemini-auth "$HOME/.gemini/settings.json" 2>/dev/null)" = "" ] && ok "gemini-auth of a missing settings file is empty" || fail "gemini-auth invented a value"

# ---- the preflight and the attestation compare the same policy ----
gacp "$AP" policy-attest gemini high gemini-3.1-pro-preview --policy-file "$GM_REC" >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 0 ] && ok "policy-attest gemini: the configured pair matches" || fail "policy-attest match (rc=$GM_RC)"
gacp "$AP" policy-attest gemini high gemini-2.5-pro --policy-file "$GM_REC" >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 20 ] && ok "policy-attest gemini: a model the record did not ask for is a mismatch (exit 20)" || fail "policy-attest mismatch (rc=$GM_RC)"
gacp "$AP" policy-attest gemini low gemini-3.1-pro-preview --policy-file "$GM_REC" >/dev/null 2>&1; GM_RC=$?
[ "$GM_RC" = 20 ] && ok "policy-attest gemini: a different thinking level is a mismatch too" || fail "policy-attest level mismatch (rc=$GM_RC)"
gpc() { printf '%s' "$1" | gacp "$AP" policy-check gemini - --policy-file "$GM_REC" >/dev/null 2>&1; printf '%s' "$?"; }
[ "$(gpc '{"acpx":{"current_model_id":"gemini-3.1-pro-preview"}}')" = 0 ] \
  && ok "policy-check gemini: the session's confirmed current_model_id matches" || fail "policy-check match"
[ "$(gpc '{"acpx":{"current_model_id":"gemini-2.5-pro"}}')" = 20 ] \
  && ok "policy-check gemini: a session on another model is a mismatch (exit 20)" || fail "policy-check mismatch"
[ "$(gpc '{"acpx":{"current_model_id":"gemini-3.1-pro-preview","session_options":{"model":"gemini-2.5-pro"}}}')" = 20 ] \
  && ok "policy-check gemini: a saved model preference acpx would replay is a mismatch" || fail "policy-check saved preference"
[ "$(gpc '{}')" = 21 ] && [ "$(gpc 'not json')" = 21 ] \
  && ok "policy-check gemini: no reported model, or an unreadable record, is undecidable (21), never a match" || fail "policy-check undecidable"

# ---- the classification of a refusal (stderr only) ----
GM_E="$WORK/gm-stderr"
gfr() { printf '%s\n' "$1" > "$GM_E"; "$AP" failure-reason "${2:-gemini}" "$GM_E"; }
[ "$(gfr '[error] [429] You have exhausted your capacity on this model.')" = rate-limited ] \
  && [ "$(gfr 'Error: RESOURCE_EXHAUSTED: Quota exceeded for metric')" = rate-limited ] \
  && ok "a 429 / RESOURCE_EXHAUSTED refusal classifies as rate-limited" || fail "rate-limit classification"
[ "$(gfr '[error] Authentication required.')" = auth-failed ] && [ "$(gfr 'UNAUTHENTICATED: API key not valid. Please pass a valid API key.')" = auth-failed ] \
  && ok "an authentication refusal classifies as auth-failed" || fail "auth classification"
[ "$(gfr '[error] 429 unauthorized credentials')" = rate-limited ] \
  && ok "when both match the rate limit wins (a 429 body can mention credentials)" || fail "rate/auth precedence"
[ -z "$(gfr 'Error: Internal error')" ] && [ -z "$(gfr 'timed out after 4290 ms')" ] \
  && ok "an unclassifiable refusal, and a number that merely contains 429, classify as nothing" || fail "over-classified"
[ -z "$(gfr '[error] [429] quota' codex)" ] && ok "only gemini's refusal wording is known: another provider classifies as nothing" || fail "classified a non-gemini provider"
