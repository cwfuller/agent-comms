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
printf '{"security":{"auth":{"selectedType":"oauth-personal"}},"mcpServers":{"x":{}}}' > "$WORK/gm-operator-settings.json"
printf '{"security":{"auth":{"selectedType":"x\\"y"}}}' > "$WORK/gm-operator-bad.json"
{ [ "$(gacp "$AP" gemini-auth "$WORK/gm-operator-settings.json")" = oauth-personal ] \
  && [ -z "$(gacp "$AP" gemini-auth "$WORK/gm-no-such-settings.json")" ] && [ -z "$(gacp "$AP" gemini-auth "$WORK/gm-operator-bad.json")" ]; } \
  && ok "gemini-auth carries ONE allowlisted token: the selected type; a missing file or a value outside the allowlist gives nothing" \
  || fail "gemini-auth"

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

section "gemini: a mounted review turn (stub acpx driving a stub gemini over real ACP)"
# A real `runphase.sh run --via acp` turn for agent `gemini`, through the mount, the isolated home, the
# compatibility canary and the broker. acpx is the shared stub; the prompt is a genuine ACP exchange with
# the stub gemini, so a refusal reaches runphase as acpx's own stderr and exit status would.
GM="$WORK/gm-turn"; mkdir -p "$GM"
GM_MBASE="$GM/mbase"; mkdir -p "$GM_MBASE"; GM_MBASE="$(cd "$GM_MBASE" && pwd -P)"
GM_STORE="$GM_MBASE/agent-comms/mounts"
mkdir -p "$GM/home/.acpx/sessions" "$GM/home/.acpx/queues" "$GM/home/.gemini"; : > "$GM/home/.acpx-test-store"
# The operator's own Gemini state: an API-key login, a file-backed OAuth token, and settings that carry
# things a review turn must NOT inherit (a different model, an MCP server).
printf '{"security":{"auth":{"selectedType":"gemini-api-key"}},"model":{"name":"operator-model"},"mcpServers":{"operator-server":{"command":"x"}}}\n' > "$GM/home/.gemini/settings.json"
printf '{"refresh_token":"operator-oauth-token"}\n' > "$GM/home/.gemini/oauth_creds.json"
printf '{"active":"operator@example.test"}\n' > "$GM/home/.gemini/google_accounts.json"
GM_OP_SUM="$(cat "$GM/home/.gemini/settings.json" "$GM/home/.gemini/oauth_creds.json" | shasum | cut -d' ' -f1)"
printf 'agents = claude codex grok gemini\ndefault-target = codex\n' > "$MA_FIX/.comms/config"
printf '.comms/\n' > "$MA_FIX/.gitignore"
mkdir -p "$MA_FIX/.comms/to-gemini" "$MA_FIX/.comms/to-claude"
# A dangling commit: HEAD's tree plus a marker, plus any extra tracked paths. Built in a private index
# from blobs, so the live checkout is never written to.
gm_artifact() { # <marker> [extra tracked path...] -> commit sha
  local marker="$1" idx="$GM/idx.$1" blob t extra; shift
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$MA_FIX" read-tree HEAD
  blob="$(printf '%s\n' "$marker" | git -C "$MA_FIX" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$MA_FIX" update-index --add --cacheinfo "100644,$blob,gm-marker.txt"
  for extra in "$@"; do GIT_INDEX_FILE="$idx" git -C "$MA_FIX" update-index --add --cacheinfo "100644,$blob,$extra"; done
  t="$(GIT_INDEX_FILE="$idx" git -C "$MA_FIX" write-tree)"
  git -C "$MA_FIX" -c user.email=t@t -c user.name=t commit-tree "$t" -p HEAD -m "artifact $marker"
}
GM_HEAD="$(git -C "$MA_FIX" rev-parse HEAD)"
GM_A1="$(gm_artifact gm-round-1)"
gm_turn() { # <thread> <tag> <artifact> [env assignments...] -> the run dir
  local thread="$1" tag="$2" art="$3"; shift 3
  local msg dir
  msg="$MA_FIX/.comms/to-gemini/${MA_WS}_2026-09-30T10-00-00_gm-$tag.md"
  { head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
    printf 'artifact_id: %s\nhead_sha: %s\n' "$art" "$GM_HEAD"
    tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" | sed -e "s|^thread: ma-arc-1\$|thread: $thread|"
  } > "$msg"
  dir="$GM/run-$tag"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$GMB:$AXB:$PATH" HOME="$GM/home" COMMS_MOUNT_BASE="$GM_STORE" \
      GM_LOG="$GM/stub-$tag.log" GM_ACPX_LOG="$GM/acpx-$tag.log" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_RUNPHASE_OWNER_WAIT_SECS=3 \
      GEMINI_MODEL=operator-model GEMINI_SANDBOX=true GEMINI_CLI=1 \
      "$@" "$RP" run --message "$msg" --dir "$dir" --provider gemini --via acp --timeout-secs 30 ) >"$dir/stdout.log" 2>"$dir/stderr.log"
  printf '%s' "$dir"
}
gm_res() { python3 -c '
import json,sys
d=json.load(open(sys.argv[1]+"/result.json"))
for k in sys.argv[2:]: d=d.get(k) if isinstance(d,dict) else None
print("<null>" if d is None else d)' "$@" 2>/dev/null; }
gm_log() { sed -n "s/^$2	//p" "$GM/stub-$1.log" 2>/dev/null | head -1; }      # first value of a stub observation
gm_events() { (cd "$MA_FIX" && env "$COMMS" events --all --agent gemini --thread "$1" 2>/dev/null); }

GM_D1="$(gm_turn gm-thread t1 "$GM_A1")"
{ [ "$(gm_res "$GM_D1" status)" = completed ] && [ "$(gm_res "$GM_D1" provider)" = gemini ] && [ -z "$(gm_res "$GM_D1" reason)" ]; } \
  && ok "a mounted gemini review turn completes and records its result (provider gemini, status completed)" \
  || fail "gemini turn did not complete: $(tr '\n' ' ' < "$GM_D1/result.json" 2>/dev/null | cut -c1-400) | $(tail -5 "$GM_D1/runner.log" 2>/dev/null | tr '\n' ' ')"
GM_REPLY="$(ls "$MA_FIX/.comms/to-claude/"*gemini-reply*.md 2>/dev/null | head -1)"
{ [ -n "$GM_REPLY" ] && grep -q '^from: gemini$' "$GM_REPLY" && grep -q '^verdict: APPROVE$' "$GM_REPLY"; } \
  && ok "the parent stamps and delivers the review as gemini's, with the verdict the reply carried" \
  || fail "no stamped gemini reply (got: ${GM_REPLY:-none})"
{ [ "$(gm_res "$GM_D1" route model)" = gemini-3.1-pro-preview ] && [ "$(gm_res "$GM_D1" route effort)" = high ] \
  && [ "$(gm_res "$GM_D1" route capability)" = fixed ] && [ "$(gm_res "$GM_D1" route transport)" = acp-mounted ]; } \
  && ok "result.json's route names what the leg was bound to: gemini-3.1-pro-preview / high, capability fixed" \
  || fail "result route: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["route"])' "$GM_D1/result.json" 2>&1)"

# ---- usage, read from the CLI's own chat records ----
# Two answered messages (the canary and the review), each recorded twice by the stub — once without and
# once with its tokens — so a first-copy-wins or a double count gives a different number: input 100+0
# per response, cached 40, output 20, thoughts 10.
{ [ "$(gm_res "$GM_D1" usage source)" = gemini-chat-record ] && [ "$(gm_res "$GM_D1" usage responses)" = 2 ] \
  && [ "$(gm_res "$GM_D1" usage input_tokens)" = 200 ] && [ "$(gm_res "$GM_D1" usage cached_input_tokens)" = 80 ] \
  && [ "$(gm_res "$GM_D1" usage output_tokens)" = 60 ] && [ "$(gm_res "$GM_D1" usage reasoning_output_tokens)" = 20 ] \
  && [ "$(gm_res "$GM_D1" usage total_tokens)" = 260 ]; } \
  && ok "usage lands in result.json from the gemini chat record, each response counted once (input 200, output 60, total 260)" \
  || fail "gemini usage: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["usage"])' "$GM_D1/result.json" 2>&1)"
{ [ "$(gm_res "$GM_D1" usage cache_write_input_tokens)" = "<null>" ] && [ "$(gm_res "$GM_D1" rate_limits)" = "<null>" ]; } \
  && ok "what gemini does not record is null (cache writes, rate limits), never 0" || fail "missing gemini fields were not null"

# ---- the isolation the CLI actually saw ----
GM_HOME_SEEN="$(gm_log t1 gemini_cli_home)"
{ [ -n "$GM_HOME_SEEN" ] && [ "$GM_HOME_SEEN" != "$GM/home" ] && case "$GM_HOME_SEEN" in "$GM_STORE"/*/home) true ;; *) false ;; esac; } \
  && ok "the CLI ran with GEMINI_CLI_HOME at a parent-owned home beside the mount, not the operator's" || fail "GEMINI_CLI_HOME was '$GM_HOME_SEEN'"
GM_SET="$(gm_log t1 settings)"
GM_SETCHK="$(printf '%s' "$GM_SET" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ov=d["modelConfigs"]["customOverrides"][0]
print(d["model"]["name"], ov["modelConfig"]["generateContentConfig"]["thinkingConfig"]["thinkingLevel"],
      d["security"]["auth"]["selectedType"], "mcpServers" in d, d["general"]["plan"]["modelRouting"])' 2>&1)"
[ "$GM_SETCHK" = "gemini-3.1-pro-preview HIGH gemini-api-key False False" ] \
  && ok "the settings the CLI read bind the leg's model and thinking level, carry only the auth TYPE, and drop the operator's model and MCP server" \
  || fail "isolated settings as the CLI saw them: $GM_SETCHK ($GM_SET)"
{ [ "$(gm_log t1 env_GEMINI_MODEL)" = '<unset>' ] && [ "$(gm_log t1 env_GEMINI_SANDBOX)" = '<unset>' ] && [ "$(gm_log t1 env_GEMINI_CLI)" = '<unset>' ]; } \
  && ok "the precedence traps are scrubbed: GEMINI_MODEL, GEMINI_SANDBOX and the driver's GEMINI_CLI marker never reach the CLI" \
  || fail "inherited Gemini env reached the CLI (model=$(gm_log t1 env_GEMINI_MODEL) sandbox=$(gm_log t1 env_GEMINI_SANDBOX) cli=$(gm_log t1 env_GEMINI_CLI))"
{ [ "$(gm_log t1 cred_oauth_creds.json)" = '{"refresh_token":"operator-oauth-token"} mode=600' ] \
  && [ "$(gm_log t1 cred_google_accounts.json)" = '{"active":"operator@example.test"} mode=600' ]; } \
  && ok "the operator's file-backed login keeps working: the OAuth files are copied into the isolated home at mode 600" \
  || fail "credentials as the CLI saw them: $(gm_log t1 cred_oauth_creds.json) / $(gm_log t1 cred_google_accounts.json)"
[ "$(cat "$GM/home/.gemini/settings.json" "$GM/home/.gemini/oauth_creds.json" | shasum | cut -d' ' -f1)" = "$GM_OP_SUM" ] \
  && ok "the operator's own ~/.gemini is untouched by the turn" || fail "the operator's Gemini files changed"
[ "$(gm_log t1 argv)" = "--acp" ] \
  && ok "gemini is launched as plain 'gemini --acp' (no deprecated flag, no model flag: the settings bind it)" || fail "gemini argv was '$(gm_log t1 argv)'"
{ grep -qF -- "--model gemini-3.1-pro-preview" "$GM/acpx-t1.log" && [ "$(gm_log t1 set_model)" = gemini-3.1-pro-preview ]; } \
  && ok "acpx is handed the leg's model on its calls and sets it on the session" \
  || fail "the model was not bound through acpx (acpx log: $(head -2 "$GM/acpx-t1.log" | tr '\t\n' '  '))"
{ grep -qF -- "--approve-reads" "$GM/acpx-t1.log" && ! grep -qF -- "--approve-all" "$GM/acpx-t1.log"; } \
  && ok "the plan-mode backend narrows permissions (--approve-reads, never --approve-all): the pin is part of the boundary" \
  || fail "gemini ran under the wide permission shape"
grep -q 'set-mode plan' "$GM_D1/runner.log" \
  && ok "the session is pinned to plan mode before the canary" || fail "no plan-mode pin: $(grep -i 'set-mode' "$GM_D1/runner.log" | head -2)"
grep -q '^isolation: provider=gemini backend=gemini-plan' "$GM_D1/runner.log" \
  && ok "the run records its isolation backend (gemini-plan)" || fail "no isolation record: $(grep -i isolation "$GM_D1/runner.log" | head -2)"

# ---- attestation evidence ----
GM_TSV="$(cat "$GM_D1/turn.tsv" 2>/dev/null)"
{ [ "$(gv "$GM_TSV" observed_model)" = gemini-3.1-pro-preview ] && [ "$(gv "$GM_TSV" observed_effort)" = high ] \
  && [ "$(gv "$GM_TSV" evidence_source)" = gemini-chat-record+settings-readback ] && [ "$(gv "$GM_TSV" adapter_check)" = match ]; } \
  && ok "turn.tsv records the preflight match and the attested pair, and names its evidence: the chat record plus the settings read-back" \
  || fail "turn.tsv: $(printf '%s' "$GM_TSV" | tr '\t\n' '= ' | cut -c1-500)"

# ---- a stale credential does not outlive its source (same thread: the home is reused) ----
rm -f "$GM/home/.gemini/oauth_creds.json"
GM_D2="$(gm_turn gm-thread t2 "$GM_A1")"
{ [ "$(gm_res "$GM_D2" status)" = completed ] && [ "$(gm_log t2 cred_oauth_creds.json)" = '<absent>' ]; } \
  && ok "a credential the operator removed is cleared from the reused isolated home, not run on" \
  || fail "the stale OAuth file survived (status=$(gm_res "$GM_D2" status), saw: $(gm_log t2 cred_oauth_creds.json))"
printf '{"refresh_token":"operator-oauth-token"}\n' > "$GM/home/.gemini/oauth_creds.json"

# ---- failures are recorded, with their reasons ----
GM_D3="$(gm_turn gm-auth t3 "$GM_A1" GM_MODE=auth)"
{ [ "$(gm_res "$GM_D3" status)" = failed ] && [ "$(gm_res "$GM_D3" reason)" = auth-failed ] \
  && gm_res "$GM_D3" note | grep -qF "gemini refused the turn: authentication failed"; } \
  && ok "an authentication failure is a FAILED turn with reason auth-failed and a note that says what to do" \
  || fail "auth failure: $(tr '\n' ' ' < "$GM_D3/result.json" | cut -c1-500)"
GM_D4="$(gm_turn gm-rate t4 "$GM_A1" GM_MODE=ratelimit)"
{ [ "$(gm_res "$GM_D4" status)" = failed ] && [ "$(gm_res "$GM_D4" reason)" = rate-limited ] \
  && gm_res "$GM_D4" note | grep -qF "a rate limit or quota is exhausted"; } \
  && ok "a rate limit at the canary is a FAILED turn with reason rate-limited (the review prompt is never spent)" \
  || fail "canary rate limit: $(tr '\n' ' ' < "$GM_D4/result.json" | cut -c1-500)"
GM_D5="$(gm_turn gm-rate2 t5 "$GM_A1" GM_MODE=ratelimit-real)"
{ [ "$(gm_res "$GM_D5" status)" = failed ] && [ "$(gm_res "$GM_D5" reason)" = rate-limited ] \
  && gm_res "$GM_D5" note | grep -qF "a rate limit or quota is exhausted" && gm_events gm-rate2 | grep -q 'provider-result.*reason=rate-limited'; } \
  && ok "a rate limit on the REVIEW prompt (the canary passed) is a failed turn with reason rate-limited, on the provider-result event too" \
  || fail "real-prompt rate limit: $(tr '\n' ' ' < "$GM_D5/result.json" | cut -c1-400); events: $(gm_events gm-rate2 | cut -c1-200 | tr '\n' '|')"
GM_NREP="$(ls "$MA_FIX/.comms/to-claude/" 2>/dev/null | grep -c 'gemini-reply' || true)"
[ "$GM_NREP" = 2 ] && ok "no review was published for any refused turn (only the two completed turns reply)" || fail "a refused turn published a reply ($GM_NREP gemini replies)"
