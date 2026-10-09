# Run through tests/run.sh; each group gets fresh fixtures. The running half of the exact-per-leg-binding
# contract: real mounted turns through stub providers (end to end), the credential scrub, authentication-route
# selection and the run-time re-check.
. "$REPO/tests/lib/binding.sh"
fixture_binding

section "binding: exact model, effort and access reach the provider (end to end, stub providers)"
# A real bound dispatch, run in the foreground: codex on its subscription (gate). The provider stub records what it was
# actually handed. (gemini is not bindable any more: it runs agy directly, and a bound leg runs mounted over ACP only.)
BD_CAN="MY_INFERENCE_KEY=canary-plain-0006 API_KEY=canary-api-key-0010 VENICE_API_KEY=canary-venice-pattern-0011 ZZ_UNCONFIGURED_API_KEY=$BD_KEY_OTHER SOME_SERVICE_TOKEN=canary-svc-token-0012 MY_SECRET_THING=canary-secret-0013 GOOGLE_APPLICATION_CREDENTIALS=canary-gac-0014 OPENAI_BASE_URL=canary-base-url-0015 AWS_PROFILE=canary-aws-0016 GEMINI_API_KEY=canary-ambient-gemini-0017 CODEX_API_KEY=canary-codex-api-0018 BD_HARMLESS_SETTING=harmless-visible"
BD_VARS="BD_VENICE_KEY MY_INFERENCE_KEY API_KEY VENICE_API_KEY ZZ_UNCONFIGURED_API_KEY SOME_SERVICE_TOKEN MY_SECRET_THING GOOGLE_APPLICATION_CREDENTIALS OPENAI_BASE_URL AWS_PROFILE GEMINI_API_KEY CODEX_API_KEY BD_HARMLESS_SETTING"
BD_PAY="$BD/payload.md"
printf 'VERDICT: APPROVE\n\n## Summary\nbound stub review\n\n## Findings\n### Blocking\n- None.\n\n### Advisory\n- None.\n' > "$BD_PAY"
BD_CFG="$BD/e2e.cfg"; BD_ENVL="$BD/e2e.env"
rm -f "$BD_CFG" "$BD_ENVL"
BD_REQ="$(bd_req bd-e2e)"
bd_wb "$BD/e2e.json" "$BD_L_CODEX"
OUT="$(bd $BD_CAN COMMS_WAIT=1 ACP_PARITY_PAYLOAD="$BD_PAY" AX_CFG_LOG="$BD_CFG" AX_ENVDUMP_LOG="$BD_ENVL" AX_ENVDUMP_VARS="$BD_VARS" "$COMMS" panel dispatch --bindings "$BD/e2e.json" --set bd-e2e-set "$BD_REQ" 2>&1)"; A=$?
[ "$A" = 0 ] && grep -q 'dispatching artifact' <<<"$OUT" && ok "a bound dispatch runs" || fail "bound dispatch (rc=$A): $OUT"
[ "$(bd_res codex status)" = completed ] \
  && ok "the bound leg completes" || fail "leg status: codex=$(bd_res codex status) / $(bd_res codex note)"
grep -q '^model = "gpt-6-luna"$' "$BD_CFG" && grep -q '^model_reasoning_effort = "low"$' "$BD_CFG" \
  && ok "the codex config the provider actually read carries EXACTLY the bound pair (gpt-6-luna / low), not the baseline (gpt-6.1-sol / xhigh)" || fail "codex config: $(cat "$BD_CFG" 2>/dev/null | tr '\n' ' ')"
BD_LEGF="$(grep -l '^leg_binding:' "$BD_REPO/.comms/to-codex/"*panel-codex* "$BD_REPO/.comms/archive/"*panel-codex* 2>/dev/null | head -1)"
{ [ -n "$BD_LEGF" ] && grep -q '^leg_binding_digest: [0-9a-f]\{64\}$' "$BD_LEGF" && ! grep -q '^route_decision:' "$BD_LEGF"; } \
  && ok "the leg's request carries the helper-stamped binding and its digest, and no routing decision" || fail "leg frontmatter (${BD_LEGF:-no leg file})"
BD_STAMP="$(sed -n 's/^leg_binding: //p' "$BD_LEGF" | head -1)"
[ "$(python3 -c '
import base64,json,sys
d=json.loads(base64.urlsafe_b64decode(sys.argv[1])); print(d["ref"], d["role"], d["requirement"], d["model"], d["effort"], d["access"]["account"], d["access_digest"] == sys.argv[2])' "$BD_STAMP" "$BD_DG_CODEX")" = "res-codex gate required gpt-6-luna low primary True" ] \
  && ok "the stamp carries ref, role, requirement, the exact pair and the configured access digest" || fail "stamp content: $BD_STAMP"
BD_EV="$(bd "$COMMS" events --all --kind panel-planned --thread bd-e2e 2>&1)"
grep -q 'panel-planned.*bound=1 ref=res-codex role=gate requirement=required route_id=codex-subscription' <<<"$BD_EV" \
  && ok "each planned leg's event row echoes the caller's ref, role, requirement and route id verbatim" || fail "event rows: $(printf '%s' "$BD_EV" | cut -c1-700)"
[ -z "$(find "$BD_REPO/.comms" -name 'route-decisions' -maxdepth 1)" ] && ok "no routing decision was made or stamped: a bound dispatch never classifies" || fail "a routing decision exists"

section "binding: result.json carries binding, route and quota (and the leg's environment held only its own credential)"
# Captured NOW, before any later turn becomes the newest result for these agents.
BD_R_CB="$(bd_res codex binding)"; BD_R_CQ="$(bd_res codex quota)"
BD_R_CR="$(bd_res codex route)"; BD_R_CJ="$(f=$(grep -l '"agent": "codex"' $(find "$BD_REPO/.comms/logs" -name result.json) | head -1); cat "$f")"
[ "$BD_R_CB" = '{"access_digest":"'"$BD_DG_CODEX"'","account":"primary","auth_evidence":"observed","billing":"subscription","capability_version":1,"credential_ref":null,"expected":{"effort":"low","model":"gpt-6-luna"},"mismatches":[],"observed":{"effort":"low","model":"gpt-6-luna"},"provider":"openai","ref":"res-codex","requirement":"required","role":"gate","route_id":"codex-subscription","schema":1,"status":"ran","transport":"acp"}' ] \
  && ok "the codex leg's binding states its route id, access digest, ref/role/requirement, expected and OBSERVED pair (from the provider's own rollout), auth evidence observed, status ran" || fail "codex binding: $BD_R_CB"
[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["route_id"], d["access_digest"] == sys.argv[2], d["model"], d["effort"], d["model_source"], d["effort_source"], d["capability"])' "$BD_R_CR" "$BD_DG_CODEX")" = "codex-subscription True gpt-6-luna low bound bound eligible" ] \
  && ok "result.json route (route-view v2) adds the route id and the access digest, and says the pair is bound" || fail "codex route: $BD_R_CR"
[ "$BD_R_CQ" = '{"limit_id":null,"provider":"openai","refusal":null,"resets_at":null,"schema":1,"source":"codex-rollout","state":"unavailable","used_percent":null,"window_minutes":null}' ] \
  && ok "a codex leg whose rollout holds no rate-limit snapshot has quota state UNAVAILABLE (a source exists; nothing was recorded)" || fail "codex quota: $BD_R_CQ"
[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(list(d)[-4:])' "$BD_R_CJ")" = "['profile', 'binding', 'quota', 'guidance']" ] \
  && [ "$(for k in provider agent status reason exit_code session_id message_file run_dir started_at ended_at note; do printf '%s' "$BD_R_CJ" | sed -n 's/.*"'"$k"'": "\([^"]*\)".*/\1/p' | wc -l | tr -d ' '; done | sort -u | tr '\n' ' ')" = "1 " ] \
  && ok "binding, quota and guidance are appended after the existing keys, and every string field json_get reads still matches exactly one line" || fail "result.json shape: $BD_R_CJ"
# no secret reached a durable record: result.json, runner.log, turn.tsv, the leg files, the coordinator log, the inbox.
{ ! grep -rl 'canary-' "$BD_REPO/.comms" >/dev/null 2>&1; } && ok "no credential value appears anywhere under .comms (results, logs, events, legs, replies)" || fail "a canary leaked into: $(grep -rl 'canary-' "$BD_REPO/.comms" | head -3 | tr '\n' ' ')"

# THE SCRUB, by kind of name: every canary planted in the dispatching environment, and exactly which reached a provider.
bd_seen() {  # <acpx-env-log> <NAME> -> the distinct values the CODEX leg's acpx calls recorded for NAME
  sed -n "s/^codex:$2=//p" "$1" | LC_ALL=C sort -u | tr '\n' ' '
}
bd_all_unset() {  # <seen function> <log> <NAME...> -> ok when every name was <unset> at every observation
  local fn="$1" log="$2" n got; shift 2
  for n in "$@"; do got="$($fn "$log" "$n")"; [ "$got" = "<unset> " ] || { echo "$n=$got"; return 1; }; done
}
[ "$(grep -c '^codex:BD_HARMLESS_SETTING=' "$BD_ENVL")" -ge 1 ] && ok "the codex acpx stub recorded the environment it was handed (the observation exists)" || fail "no codex environment observation"
bd_all_unset bd_seen "$BD_ENVL" BD_VENICE_KEY MY_INFERENCE_KEY API_KEY && ok "codex leg: credential names that only CONFIGURATION knows (another leg's reference, a plain API_KEY) never arrive" || fail "configured arbitrary names reached the codex leg: $(bd_all_unset bd_seen "$BD_ENVL" BD_VENICE_KEY MY_INFERENCE_KEY API_KEY)"
bd_all_unset bd_seen "$BD_ENVL" VENICE_API_KEY && ok "codex leg: a configured credential whose name also matches a pattern never arrives" || fail "VENICE_API_KEY reached the codex leg"
bd_all_unset bd_seen "$BD_ENVL" ZZ_UNCONFIGURED_API_KEY SOME_SERVICE_TOKEN MY_SECRET_THING && ok "codex leg: an unconfigured pattern-shaped credential (*_API_KEY, *_TOKEN, *_SECRET*) never arrives" || fail "pattern-shaped canary reached the codex leg"
bd_all_unset bd_seen "$BD_ENVL" GOOGLE_APPLICATION_CREDENTIALS OPENAI_BASE_URL AWS_PROFILE GEMINI_API_KEY CODEX_API_KEY && ok "codex leg: the table-listed selectors (cloud credentials, base URLs, AWS_*, the other adapters' keys) never arrive" || fail "table-listed canary reached the codex leg"
[ "$(bd_seen "$BD_ENVL" BD_HARMLESS_SETTING)" = "harmless-visible " ] && ok "the scrub is not a wipe: an ordinary variable still arrives" || fail "BD_HARMLESS_SETTING was '$(bd_seen "$BD_ENVL" BD_HARMLESS_SETTING)'"

section "binding: authentication-route selection, a stale login, and conflicting saved state (codex)"
# The gemini rounds that lived here (an isolated login staged, cleared and forced per billing route) went with the
# `gemini --acp` arm: agy runs in the operator's own home, so there is no staged login to bind. The saved codex
# login's own conflicts are exercised below, as run-time re-checks.
# THE PLAN AND THE LAUNCHER AGREE ON CONFLICTS (dispatch-time refusals are in the validation section): here, the
# operator's state changes AFTER dispatch, and the leg refuses itself.
bd_leg_pickup() {  # <agent> <thread> <legs-json> -> dispatches with delivery suppressed; sets BD_LEGFILE to the stamped leg
  bd_wb "$BD/pk.json" "$3"
  BD_OUT="$(bd COMMS_HEADLESS_PICKUP="$1" "$COMMS" panel dispatch --bindings "$BD/pk.json" "$(bd_req "$2")" 2>&1)"; BD_RC=$?
  BD_LEGFILE="$(ls -t "$BD_REPO/.comms/to-$1/"*"panel-$1-"* 2>/dev/null | head -1)"
}
bd_leg_run() {  # <agent> <leg-file> <run-dir> [env...] — the runner, started by hand, as a detached delivery would
  local ag="$1" f="$2" d="$3"; shift 3; mkdir -p "$d"
  bd ACP_PARITY_PAYLOAD="$BD_PAY" AX_CWD_LOG="$d.stub" "$@" "$RP" run --message "$f" --dir "$d" --agent "$ag" --via acp --timeout-secs 30 >"$d.out" 2>&1
}
bd_dir_res() { python3 -c '
import json,sys
d=json.load(open(sys.argv[1]+"/result.json"))
for k in sys.argv[2:]: d=d.get(k) if isinstance(d,dict) else None
print("<null>" if d is None else (json.dumps(d,sort_keys=True,separators=(",",":")) if isinstance(d,(dict,list)) else d))' "$@" 2>/dev/null || echo "<unreadable>"; }
bd_leg_pickup codex bd-rt-auth "$BD_L_CODEX"
{ [ "$BD_RC" = 0 ] && [ -n "$BD_LEGFILE" ] && grep -q '^leg_binding:' "$BD_LEGFILE"; } && ok "a suppressed delivery leaves the stamped leg in the inbox without starting a runner" || fail "pickup dispatch (rc=$BD_RC): $BD_OUT"
bd_reset

section "binding: a configuration change after dispatch makes the leg refuse itself before any provider launch"
# Each case dispatches a bound leg with delivery suppressed, changes ONE thing in the operator's configuration, then starts
# the runner by hand. The stub providers record any launch; a refused leg must leave no trace of one.
bd_changed() {  # <label> <expected mismatch codes JSON> <agent> <leg-json> <mutation shell> [env...]
  local label="$1" want="$2" ag="$3" leg="$4" mutate="$5"; shift 5
  bd_reset
  bd_leg_pickup "$ag" "bd-rt-$BD_REQ_N" "$leg"
  local lf="$BD_LEGFILE" d="$BD/rt-$BD_REQ_N"
  eval "$mutate"
  bd_leg_run "$ag" "$lf" "$d" "$@"
  { [ "$(bd_dir_res "$d" status)" = failed ] && [ "$(bd_dir_res "$d" reason)" = binding-mismatch ] && [ "$(bd_dir_res "$d" binding mismatches)" = "$want" ] \
    && [ "$(bd_dir_res "$d" binding status)" = refused ] && [ ! -e "$d.stub" ]; } \
    && ok "changed after dispatch, the leg refuses itself without launching anything: $label" \
    || fail "run-time recheck ($label): $(tr '\n' ' ' < "$d/result.json" 2>/dev/null | cut -c1-420) stub=$(ls "$d.stub" 2>/dev/null | tr '\n' ' ')"
  bd_reset
}
bd_changed "the account in access.json" '["account-mismatch"]' codex "$BD_L_CODEX" "bd_mut access \"d['agents']['codex']['account']='secondary'\""
# glm and glm2 share one route and account, so the route only validates when both profiles change together.
bd_changed "the credential reference in access.json" '["credential-mismatch"]' glm2 "$BD_L_GLM2" "bd_mut agents \"[d['agents'][a]['credentials']['VENICE_API_KEY'].update(env='BD_VENICE_OTHER_KEY') for a in ('glm', 'glm2')]\"; bd_mut access \"[d['agents'][a].update(credential='env:BD_VENICE_OTHER_KEY') for a in ('glm', 'glm2')]\""
bd_changed "the billing class in access.json" '["billing-mismatch"]' codex "$BD_L_CODEX" "bd_mut access \"d['agents']['codex'].update(billing='free')\""
bd_changed "access.json removed" '["no-access-profile"]' codex "$BD_L_CODEX" "rm -f \"\$BD_AH/access.json\""
bd_changed "the credential removed from the environment" '["credential-unavailable"]' glm2 "$BD_L_GLM2" ":" BD_VENICE_KEY=
bd_changed "an environment model pin appearing" '["pin-conflict"]' codex "$BD_L_CODEX" ":" COMMS_ACP_CODEX_MODEL=gpt-6.1-sol
cp "$BD_HOME/.codex/auth.json" "$BD/codex-auth.chatgpt"
bd_changed "the saved codex login switched to API-key mode" '["auth-selected-type-conflict"]' codex "$BD_L_CODEX" "printf '{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"canary-codex-apikey-0009\"}\n' > \"\$BD_HOME/.codex/auth.json\""
cp "$BD/codex-auth.chatgpt" "$BD_HOME/.codex/auth.json"
bd_changed "the saved codex login removed" '["auth-login-missing"]' codex "$BD_L_CODEX" "rm -f \"\$BD_HOME/.codex/auth.json\""
cp "$BD/codex-auth.chatgpt" "$BD_HOME/.codex/auth.json"
bd_changed "the operator profile's pinned model (a custom OpenCode agent)" '["model-mismatch"]' glm "$BD_L_GLM" "bd_mut agents \"d['agents']['glm']['model']='venice/glm-model-z'\""
bd_changed "the access digest alone (a twin whose entry was edited with its driver)" '["account-mismatch"]' codex "$BD_L_CODEX" "bd_mut access \"d['agents']['codex']['account']='primary2'\""
# A stamp that no longer verifies — hand-edited, truncated, its digest dropped — is refused the same way.
bd_reset; bd_leg_pickup codex bd-rt-forged "$BD_L_CODEX"; BD_FORGED="$BD/forged-leg.md"
sed 's/^leg_binding_digest: .*/leg_binding_digest: 0000000000000000000000000000000000000000000000000000000000000000/' "$BD_LEGFILE" > "$BD_FORGED"
bd_leg_run codex "$BD_FORGED" "$BD/rt-forged"
{ [ "$(bd_dir_res "$BD/rt-forged" status)" = failed ] && [ "$(bd_dir_res "$BD/rt-forged" reason)" = binding-mismatch ] && [ ! -e "$BD/rt-forged.stub" ]; } \
  && ok "a leg whose stamp does not match its digest is refused as a binding-mismatch, nothing launched" || fail "forged stamp: $(cat "$BD/rt-forged/result.json" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
# CONTROL: the unchanged configuration runs the stamped leg, so every refusal above is the change, not the harness.
bd_reset; bd_leg_pickup codex bd-rt-ctl "$BD_L_CODEX"; bd_leg_run codex "$BD_LEGFILE" "$BD/rt-ctl"
{ [ "$(bd_dir_res "$BD/rt-ctl" status)" = completed ] && [ "$(bd_dir_res "$BD/rt-ctl" binding status)" = ran ] && [ -e "$BD/rt-ctl.stub" ]; } \
  && ok "control: an unchanged configuration runs the stamped leg (binding status ran)" || fail "control run: $(cat "$BD/rt-ctl/result.json" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
# THE CREDENTIAL FOLLOWS THE STAMP, NOT THE FILE: the runner re-checks, then sleeps and mounts, and only then prepares the
# environment. An access entry that changed in between must not substitute another credential (nor another account's route).
bd_reset; bd_leg_pickup glm2 bd-rt-cred "$BD_L_GLM2"
BD_CS="$(sed -n 's/^leg_binding: //p' "$BD_LEGFILE" | head -1)"; BD_CD="$(sed -n 's/^leg_binding_digest: //p' "$BD_LEGFILE" | head -1)"
BD_HELP="$(dirname "$RP")"
bd_cred() { bd python3 "$BD_HELP/access_profiles.py" credential-value glm2 --stamp "$BD_CS" --digest "$BD_CD" 2>"$BD/cred.err"; }
bd_cls() { bd python3 "$BD_HELP/leg_binding.py" env-class --stamp "$BD_CS" --digest "$BD_CD" --provider glm2 2>>"$BD/cred.err"; }
[ "$(bd_cred)" = "$BD_KEY_VENICE" ] && [ "$(bd_cls)" = "$(printf 'opencode\tapi')" ] \
  && ok "control: an unchanged access entry prepares exactly the credential the stamp bound" || fail "unchanged preparation: $(cat "$BD/cred.err")"
bd_mut access "d['agents']['glm2'].update(account='other', credential='env:BD_VENICE_OTHER_KEY')"
BD_GOT="$(bd_cred)"; A=$?
{ [ "$A" != 0 ] && [ -z "$BD_GOT" ] && [ "$(bd_cls)" = "" ]; } \
  && ok "the access entry changed after the re-check: credential preparation and the environment class refuse, no other account's credential is read" || fail "drifted preparation (rc=$A): $BD_GOT"
bd_reset

# A RUNNER THAT DIES WITHOUT A RESULT keeps the bound contract: await synthesizes the result from the persisted turn record,
# which carries the stamp, so binding and quota are present and unknown observations stay unknown.
bd_crash() {  # <name> <extra turn.tsv lines...> -> a run dir as a killed bound runner leaves it, awaited
  local d="$BD/$1" p; shift; mkdir -p "$d"
  sh -c 'exit 0' & p=$!; wait "$p" 2>/dev/null || true
  printf '%s\n' "$p" > "$d/pid"
  { printf 'thread\tbd-crash\nprovider\tcodex\nagent\tcodex\n'; printf 'leg_binding\t%s\nleg_binding_digest\t%s\n' "$BD_CRS" "$BD_CRD"; printf '%b' "$@"; } > "$d/turn.tsv"
  bd "$RP" await "$d" --timeout-secs 30 >"$d.out" 2>"$d.err" || true
}
bd_reset; bd_leg_pickup codex bd-crash "$BD_L_CODEX"
BD_CRS="$(sed -n 's/^leg_binding: //p' "$BD_LEGFILE" | head -1)"; BD_CRD="$(sed -n 's/^leg_binding_digest: //p' "$BD_LEGFILE" | head -1)"
bd_crash crash-early ''
{ [ "$(bd_dir_res "$BD/crash-early" status)" = failed ] && [ "$(bd_dir_res "$BD/crash-early" binding ref)" = res-codex ] \
  && [ "$(bd_dir_res "$BD/crash-early" binding status)" = refused ] && [ "$(bd_dir_res "$BD/crash-early" binding observed)" = '{"effort":null,"model":null}' ] \
  && [ "$(bd_dir_res "$BD/crash-early" quota provider)" = openai ] && [ "$(bd_dir_res "$BD/crash-early" quota state)" = unavailable ]; } \
  && ok "a bound runner killed before launch: the synthesized result keeps binding (refused, nothing observed) and a quota object" || fail "early crash: $(tr '\n' ' ' < "$BD/crash-early/result.json" | cut -c1-600)"
bd_crash crash-ran 'bind_state\tran\nbind_auth\tobserved\nobserved_effort\tlow\nobserved_model\tgpt-6-luna\n'
{ [ "$(bd_dir_res "$BD/crash-ran" binding status)" = ran ] && [ "$(bd_dir_res "$BD/crash-ran" binding auth_evidence)" = observed ] \
  && [ "$(bd_dir_res "$BD/crash-ran" binding observed model)" = gpt-6-luna ] && [ "$(bd_dir_res "$BD/crash-ran" binding observed effort)" = low ]; } \
  && ok "a bound runner killed after launch: the synthesized result keeps what the run had established (ran, observed pair, auth evidence)" || fail "late crash: $(tr '\n' ' ' < "$BD/crash-ran/result.json" | cut -c1-600)"
bd_crash crash-guide 'guidance\tstaged\t0123456789abcdef0123456789abcdef01234567\t'"$(printf 'a%.0s' $(seq 64))"'\n'
{ [ "$(bd_dir_res "$BD/crash-guide" guidance status)" = staged ] && [ "$(bd_dir_res "$BD/crash-guide" guidance revision)" = 0123456789abcdef0123456789abcdef01234567 ] \
  && [ "$(bd_dir_res "$BD/crash-guide" guidance sha256)" = "$(printf 'a%.0s' $(seq 64))" ] && [ "$(bd_dir_res "$BD/crash-early" guidance)" = "<null>" ]; } \
  && ok "a runner killed after staging guidance: the synthesized result keeps the staged status, revision and digest (null when nothing was recorded)" || fail "guidance crash: $(tr '\n' ' ' < "$BD/crash-guide/result.json" | cut -c1-600)"
bd_reset
# NO FALLBACK AND NO DROP: a refused bound leg is recorded as a failed turn with its own reason, which compose --degrade does
# not treat as droppable (its evidence is no-output | policy-unapplied only), so the leg stays an unanswered leg for the
# caller to see, never silently removed from the roster.
BD_EVT="$(bd "$COMMS" events --all --kind turn-finished 2>&1)"
{ [ "$(grep -c 'exit=1 reason=binding-mismatch' <<<"$BD_EVT")" -ge 3 ] && ! grep -Eq 'reason=(no-output|policy-unapplied)' <<<"$(grep 'reason=binding-mismatch' <<<"$BD_EVT")"; } \
  && ok "each refusal is a terminal turn-finished event with reason=binding-mismatch: not a degradable reason, so the leg is never dropped" || fail "refusal events: $(grep 'binding-mismatch' <<<"$BD_EVT" | cut -c1-160 | head -3)"

section "binding: helper-stamped, never typed (leg_binding), env pins, and no classifier in bound mode"
# A hand-typed binding rides nowhere: send and an unbound dispatch STRIP the keys, exactly as they strip route_decision.
BD_FREQ="$(bd_req bd-forged-thread)"
python3 - "$BD_FREQ" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("workflow: auto\n","workflow: auto\nleg_binding: forged-value\nleg_binding_digest: forged-digest\n",1)
open(p,'w').write(s)
PY
OUT="$(bd COMMS_DELIVERY=mailbox "$COMMS" panel dispatch --to codex,grok "$BD_FREQ" 2>&1)"; A=$?
BD_FLEG="$(ls -t "$BD_REPO/.comms/to-codex/"*panel-codex-* 2>/dev/null | head -1)"
{ [ "$A" = 0 ] && [ -n "$BD_FLEG" ] && ! grep -q '^leg_binding' "$BD_FLEG"; } \
  && ok "an unbound dispatch strips a hand-typed leg_binding and its digest from every leg" || fail "forged binding survived (rc=$A): $(grep '^leg_binding' "$BD_FLEG" 2>/dev/null)"
cp "$BD_FREQ" "$BD/forged-send.md"; mkdir -p "$BD_REPO/.comms/to-codex"
OUT="$(bd COMMS_DELIVERY=mailbox "$COMMS" send --to codex "$BD/forged-send.md" 2>&1)"
{ ! grep -q '^leg_binding' "$BD/forged-send.md"; } && ok "a plain send strips them too" || fail "plain send kept a forged binding"
cp "$BD_FREQ" "$BD/forged-send2.md"
OUT="$(bd COMMS_DELIVERY=mailbox "$COMMS" send --to codex --bound-leg forged --bound-digest forged "$BD/forged-send2.md" 2>&1)"; A=$?
[ "$A" != 0 ] && ok "send --bound-leg refuses a stamp that does not verify (its digest, canonical form and agent)" || fail "send accepted an unverified bound leg"

# THE PIN RULE: an environment pin EQUAL to the binding is accepted; any other is a conflict; the binding never overrides it.
OUT="$(bd COMMS_ACP_CODEX_MODEL=gpt-6-luna COMMS_ACP_CODEX_EFFORT=low "$COMMS" review-route plan --bindings "$BD/e2e.json" 2>&1)"; A=$?
[ "$A" = 0 ] && ok "an operator pin equal to the binding is accepted" || fail "equal pin refused (rc=$A): $OUT"
bd_wb "$BD/pin2.json" "$BD_L_CODEX" "$BD_L_GLM2"
OUT="$(bd COMMS_ACP_CODEX_EFFORT=high "$COMMS" review-route plan --bindings "$BD/pin2.json" 2>&1)"; A=$?
{ [ "$A" = 1 ] && grep -q 'agent=codex .*status=refused code=pin-conflict' <<<"$OUT" && grep -q 'agent=glm2 .*status=ok' <<<"$OUT"; } && ok "a differing pin on ONE leg refuses only that leg's verdict, by name" || fail "differing codex pin (rc=$A): $OUT"

# NO CLASSIFIER: with reviewer routing switched on a legacy dispatch decides and stamps a route_decision; a bound one never does.
BD_CLS="$BD/classifier.log"; rm -f "$BD_CLS"
bd_wb "$BD/pk.json" "$BD_L_CODEX"
OUT="$(bd COMMS_REVIEW_ROUTE=1 COMMS_ROUTE=1 COMMS_ROUTE_LOG="$BD_CLS" COMMS_HEADLESS_PICKUP=codex "$COMMS" panel dispatch --bindings "$BD/pk.json" "$(bd_req bd-noclass2)" 2>&1)"; A=$?
BD_NLEG="$(ls -t "$BD_REPO/.comms/to-codex/"*panel-codex-* 2>/dev/null | head -1)"
{ [ "$A" = 0 ] && ! grep -q '^route_decision:' "$BD_NLEG" && [ ! -e "$BD_CLS" ] && [ -z "$(find "$BD_REPO/.comms" -maxdepth 1 -name 'route-decisions')" ]; } \
  && ok "with reviewer routing ON a bound dispatch classifies nothing, records no decision and stamps no route_decision" || fail "classifier in bound mode (rc=$A): $OUT"
bd_leg_run codex "$BD_NLEG" "$BD/rt-noclass" COMMS_REVIEW_ROUTE=1 COMMS_ROUTE=1
{ [ "$(bd_dir_res "$BD/rt-noclass" status)" = completed ] && [ "$(bd_dir_res "$BD/rt-noclass" route model_source)" = bound ] && [ "$(bd_dir_res "$BD/rt-noclass" route routing)" = off ] && [ "$(bd_dir_res "$BD/rt-noclass" route decision)" = none ]; } \
  && ok "and the runner resolves it bound with routing off even when routing is on in ITS environment" || fail "bound turn under routing: $(bd_dir_res "$BD/rt-noclass" route)"

section "binding: quota states from real turns (observed, unavailable, refused with no manufactured reset)"
# A codex leg whose rollout carries a rate-limit snapshot: the leg's quota is OBSERVED, with the provider's own numbers.
BD_LUREC="$BD/lu-codex-records.jsonl"
grep -v '"type":"turn_context"' "$REPO/tests/fixtures/leg-usage/codex-window.jsonl" > "$BD_LUREC"
bd_wb "$BD/q-codex.json" "$BD_L_CODEX"
OUT="$(bd COMMS_WAIT=1 ACP_PARITY_PAYLOAD="$BD_PAY" AX_ROLLOUT_APPEND="$BD_LUREC" "$COMMS" panel dispatch --bindings "$BD/q-codex.json" --set bd-q-codex "$(bd_req bd-q-codex)" 2>&1)"; A=$?
[ "$(bd_res codex quota)" = '{"limit_id":"codex","provider":"openai","refusal":null,"resets_at":1790000100,"schema":1,"source":"codex-rollout","state":"observed","used_percent":31.5,"window_minutes":10080}' ] \
  && ok "a codex leg with a rate-limit snapshot in its rollout has quota state OBSERVED, with limit id, window, used percent and the provider's own reset" || fail "observed quota (rc=$A): $(bd_res codex quota) $OUT"
[ "$(bd_res codex rate_limits used_percent)" = 31.5 ] && ok "the existing rate_limits key is retained unchanged beside the new quota object" || fail "rate_limits: $(bd_res codex rate_limits)"

section "binding: an unbound dispatch is unchanged, and its result.json marks a legacy leg"
# An UNBOUND dispatch, run end to end: same behaviour as before, with binding and quota null (a legacy leg).
BD_UREQ="$(bd_req bd-unbound)"
OUT="$(bd COMMS_WAIT=1 ACP_PARITY_PAYLOAD="$BD_PAY" AX_CFG_LOG="$BD/unbound.cfg" "$COMMS" panel dispatch --to codex "$BD_UREQ" 2>&1)"; A=$?
{ [ "$A" = 0 ] && [ "$(bd_res codex status)" = completed ] && grep -q '^model = "gpt-6.1-sol"$' "$BD/unbound.cfg" && grep -q '^model_reasoning_effort = "xhigh"$' "$BD/unbound.cfg"; } \
  && ok "an unbound dispatch still runs the map's baseline pair (gpt-6.1-sol / xhigh): nothing about it changed" || fail "unbound dispatch (rc=$A status=$(bd_res codex status)): $OUT"
{ [ "$(bd_res codex binding)" = "<null>" ] && [ "$(bd_res codex quota)" = "<null>" ] && [ "$(bd_res codex route model_source)" = baseline ] && [ "$(bd_res codex route route_id)" = "<null>" ]; } \
  && ok "its result.json has binding null, quota null and a route with no route id: a legacy leg is recognisable" || fail "legacy result: binding=$(bd_res codex binding) route=$(bd_res codex route)"
{ ! grep -q '^leg_binding' "$(ls -t "$BD_REPO/.comms/to-codex/"*panel-codex-* "$BD_REPO/.comms/archive/"*panel-codex-* 2>/dev/null | head -1)"; } && ok "its leg request carries no binding stamp" || fail "an unbound leg carried a binding"


section "binding: a bound claude-review leg on codex-authored work (pinned adapter, ACP set before the canary, transcript attestation)"
# Codex-written work reviewed by a bound Claude leg, end to end through stub providers. The leg runs on the login of its
# own config directory; its model and effort are set over ACP before the canary and proved from Claude's transcript.
# A claude leg's mount base is short: Claude names a project directory after the cwd and truncates a name over 200
# characters, which attestation refuses (the long-base case is below), and $WORK alone is ~70 characters on macOS.
BD_REQ_FROM=codex
BD_CMB="$WORK/m"; mkdir -p "$BD_CMB"; BD_CMB="$(cd "$BD_CMB" && pwd -P)"
bd_cl() { bd COMMS_MOUNT_BASE="$BD_CMB" "$@"; }
bd_order() { [ ! -f "$1" ] || tr '\n' "$2" < "$1"; }   # <stub order log> <separator> -> the recorded calls, joined
bd_claude_on
BD_DG_CLAUDE="$(bd_dig claude-review)"
BD_CL_VARS="$BD_VARS CLAUDE_CONFIG_DIR CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_CLIENT_KEY_PASSPHRASE ANTHROPIC_DEFAULT_OPUS_MODEL"
BD_CL_CAN="ANTHROPIC_CUSTOM_HEADERS=Authorization:Bearer-canary-hdr-0031 CLAUDE_CODE_CLIENT_KEY_PASSPHRASE=canary-mtls-0032 ANTHROPIC_DEFAULT_OPUS_MODEL=canary-alias-0036 CLAUDE_CODE_EFFORT_LEVEL=max"
BD_CLO="$BD/cl-order.log"; BD_CLE="$BD/cl-env.log"; BD_CLL="$BD/cl-cli.log"; rm -f "$BD_CLO" "$BD_CLE" "$BD_CLL"
bd_wb "$BD/cl.json" "$BD_L_CLAUDE"
OUT="$(bd_cl $BD_CAN $BD_CL_CAN COMMS_WAIT=1 ACP_PARITY_PAYLOAD="$BD_PAY" AX_ORDER_LOG="$BD_CLO" AX_ENVDUMP_LOG="$BD_CLE" AX_ENVDUMP_VARS="$BD_CL_VARS" \
        CL_LOG="$BD_CLL" CL_VARS="$BD_CL_VARS" "$COMMS" panel dispatch --bindings "$BD/cl.json" --set bd-cl-set "$(bd_req c1)" 2>&1)"; A=$?
{ [ "$A" = 0 ] && [ "$(bd_res claude-review status)" = completed ]; } \
  && ok "a codex-authored request dispatched with --bindings to one claude-review leg completes" || fail "claude bound dispatch (rc=$A, $(bd_res claude-review status): $(bd_res claude-review note)): $OUT"
[ "$(bd_order "$BD_CLO" '|')" = "set model claude-opus-5-5|set effort low|set-mode plan|canary|review|" ] \
  && ok "the leg sets the model, then the effort, then the plan mode, before the canary and then the review prompt" || fail "claude order: $(bd_order "$BD_CLO" '|')"
[ "$(bd_res claude-review binding)" = '{"access_digest":"'"$BD_DG_CLAUDE"'","account":"main","auth_evidence":"observed","billing":"subscription","capability_version":1,"credential_ref":null,"expected":{"effort":"low","model":"claude-opus-5-5"},"mismatches":[],"observed":{"effort":"low","model":"claude-opus-5-5"},"provider":"anthropic","ref":"res-claude","requirement":"required","role":"gate","route_id":"kernel-claude","schema":1,"status":"ran","transport":"acp"}' ] \
  && ok "result.json binding: the OBSERVED pair is what Claude's transcript recorded, auth evidence observed (the login read back), status ran" || fail "claude binding: $(bd_res claude-review binding)"
BD_CLRD="$(bd_res claude-review run_dir)"
{ [ "$(bd_res claude-review route capability) $(bd_res claude-review route model_source) $(bd_res claude-review route effort_source)" = "bound bound bound" ] \
  && grep -qx 'acp_adapter	npx -y @agentclientprotocol/claude-agent-acp@0.88.0' "$BD_CLRD/turn.tsv" && grep -qx 'evidence_source	claude-transcript' "$BD_CLRD/turn.tsv" \
  && grep -qx 'observed_runtime	2.1.293' "$BD_CLRD/turn.tsv" && grep -qx 'adapter_check	match' "$BD_CLRD/turn.tsv"; } \
  && ok "it ran on the pinned claude adapter, its preflight matched, and turn.tsv names the transcript as its evidence with the CLI version the records carry" || fail "claude turn record: $(grep -E 'adapter|evidence|observed' "$BD_CLRD/turn.tsv" 2>/dev/null | tr '\t\n' '= ')"
bd_cl_seen() { sed -n "s/^claude:$2=//p" "$1" | LC_ALL=C sort -u | tr '\n' ' '; }
{ [ "$(bd_cl_seen "$BD_CLE" CLAUDE_CODE_EFFORT_LEVEL)" = "low " ] && [ "$(grep -c '^claude:CLAUDE_CODE_EFFORT_LEVEL=' "$BD_CLE")" -ge 6 ]; } \
  && ok "the runner's own effort reaches every acpx call of the leg: an inherited CLAUDE_CODE_EFFORT_LEVEL=max is replaced by the bound low" || fail "claude effort env: $(bd_cl_seen "$BD_CLE" CLAUDE_CODE_EFFORT_LEVEL)"
bd_all_unset bd_cl_seen "$BD_CLE" ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_CLIENT_KEY_PASSPHRASE ANTHROPIC_DEFAULT_OPUS_MODEL BD_VENICE_KEY MY_INFERENCE_KEY API_KEY VENICE_API_KEY ZZ_UNCONFIGURED_API_KEY SOME_SERVICE_TOKEN MY_SECRET_THING GOOGLE_APPLICATION_CREDENTIALS OPENAI_BASE_URL AWS_PROFILE GEMINI_API_KEY CODEX_API_KEY \
  && [ "$(bd_cl_seen "$BD_CLE" BD_HARMLESS_SETTING)" = "harmless-visible " ] \
  && ok "claude leg: a header credential, an mTLS passphrase, an alias redefinition and every BD_CAN canary are unset at every acpx call; an ordinary variable still arrives" || fail "claude leg env: $(bd_all_unset bd_cl_seen "$BD_CLE" ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_CLIENT_KEY_PASSPHRASE ANTHROPIC_DEFAULT_OPUS_MODEL BD_VENICE_KEY MY_INFERENCE_KEY API_KEY VENICE_API_KEY ZZ_UNCONFIGURED_API_KEY SOME_SERVICE_TOKEN MY_SECRET_THING GOOGLE_APPLICATION_CREDENTIALS OPENAI_BASE_URL AWS_PROFILE GEMINI_API_KEY CODEX_API_KEY)"
{ [ "$(grep -c '^cfg=' "$BD_CLL")" -ge 2 ] && [ -z "$(grep -E '^(ANTHROPIC_CUSTOM_HEADERS|CLAUDE_CODE_CLIENT_KEY_PASSPHRASE|ANTHROPIC_DEFAULT_OPUS_MODEL|MY_INFERENCE_KEY|ZZ_UNCONFIGURED_API_KEY|SOME_SERVICE_TOKEN)=' "$BD_CLL" | grep -v '=<unset>$')" ]; } \
  && ok "the claude CLI that read the login back (at dispatch and at launch) saw none of those credentials either" || fail "claude CLI env: $(grep -v '=<unset>$' "$BD_CLL" | tr '\n' ' ')"
{ ! grep -rl 'canary-' "$BD_REPO/.comms" "$BD_CMB" >/dev/null 2>&1; } \
  && ok "no credential, email, organisation or account canary appears under .comms (results, turn.tsv, runner.log, events, replies) or the mount base" || fail "a canary leaked into: $(grep -rl 'canary-' "$BD_REPO/.comms" "$BD_CMB" | head -3 | tr '\n' ' ')"

section "binding: a bound claude leg uses the dispatch's CLAUDE_CONFIG_DIR, set or unset, for its launch, login read-back and transcript window"
# UNSET (the run above): every acpx call and the CLI saw no CLAUDE_CONFIG_DIR, and the window it attested is HOME's.
{ [ "$(bd_cl_seen "$BD_CLE" CLAUDE_CONFIG_DIR)" = "<unset> " ] && [ "$(grep '^cfg=' "$BD_CLL" | LC_ALL=C sort -u)" = "cfg=<unset>" ] \
  && [ -n "$(find "$BD_HOME/.claude/projects" -path "*$(printf '%s' "$BD_CMB" | sed 's/[^a-zA-Z0-9]/-/g')*" -name '*.jsonl' 2>/dev/null)" ]; } \
  && ok "CLAUDE_CONFIG_DIR unset: the leg launched without it, the read-back read HOME's login and the attested records are under HOME/.claude/projects" || fail "unset config dir: $(bd_cl_seen "$BD_CLE" CLAUDE_CONFIG_DIR) $(grep '^cfg=' "$BD_CLL" | sort -u | tr '\n' ' ')"
# SET to a temporary directory whose login is the subscription, while HOME's says otherwise: a leg that read HOME's
# login or HOME's records would be refused, so completing is the proof, beside what every call recorded.
BD_CCD="$BD/ccd"; bd_claude_login "$BD_CCD" subscription; bd_claude_login "$BD_HOME/.claude" console
rm -f "$BD/ccd-env.log" "$BD/ccd-cli.log"
OUT="$(bd_cl CLAUDE_CONFIG_DIR="$BD_CCD" COMMS_WAIT=1 ACP_PARITY_PAYLOAD="$BD_PAY" AX_ENVDUMP_LOG="$BD/ccd-env.log" AX_ENVDUMP_VARS=CLAUDE_CONFIG_DIR \
        CL_LOG="$BD/ccd-cli.log" "$COMMS" panel dispatch --bindings "$BD/cl.json" --set bd-ccd-set "$(bd_req c2)" 2>&1)"; A=$?
{ [ "$A" = 0 ] && [ "$(bd_res claude-review status)" = completed ] && [ "$(bd_cl_seen "$BD/ccd-env.log" CLAUDE_CONFIG_DIR)" = "$BD_CCD " ] \
  && [ "$(grep '^cfg=' "$BD/ccd-cli.log" | LC_ALL=C sort -u)" = "cfg=$BD_CCD" ] && [ -n "$(find "$BD_CCD/projects" -name '*.jsonl' 2>/dev/null)" ]; } \
  && ok "CLAUDE_CONFIG_DIR set: every acpx call and the read-back used it unchanged, and the attested records are under it" || fail "set config dir (rc=$A, $(bd_res claude-review status): $(bd_res claude-review note)): $(bd_cl_seen "$BD/ccd-env.log" CLAUDE_CONFIG_DIR)"
bd_claude_login "$BD_HOME/.claude" subscription

section "binding: a bound claude leg refuses before any prompt, before the review, or unpublished"
# Each case stamps one claude-review leg (delivery suppressed), may change ONE thing, then runs the runner by hand. The
# stub records the order of every set and prompt it saw; no case may deliver a review to the author.
bd_cl_pickup() {  # <thread> [leg-json] -> sets BD_LEGFILE, the stamped leg left in the inbox
  bd_wb "$BD/clpk.json" "${2:-$BD_L_CLAUDE}"
  bd_cl COMMS_HEADLESS_PICKUP=claude-review "$COMMS" panel dispatch --bindings "$BD/clpk.json" "$(bd_req "$1")" >"$BD/clpk.out" 2>&1
  BD_LEGFILE="$(ls -t "$BD_REPO/.comms/to-claude-review/"*panel-claude-review-* 2>/dev/null | head -1)"
}
bd_cl_run() {  # <thread> [env...] -> runs the stamped leg; sets BD_CD (its run dir) and BD_REPLIED (replies it added)
  local thr="$1" n0; shift
  BD_CD="$BD/clr-$thr"; mkdir -p "$BD_CD"; n0="$(ls "$BD_REPO/.comms/to-codex" 2>/dev/null | wc -l | tr -d ' ')"
  bd_cl ACP_PARITY_PAYLOAD="$BD_PAY" AX_ORDER_LOG="$BD_CD.order" AX_CWD_LOG="$BD_CD.stub" "$@" \
    "$RP" run --message "$BD_LEGFILE" --dir "$BD_CD" --agent claude-review --via acp --timeout-secs 30 >"$BD_CD.out" 2>&1
  BD_REPLIED=$(( $(ls "$BD_REPO/.comms/to-codex" 2>/dev/null | wc -l | tr -d ' ') - n0 ))
}
bd_cl_case() { local thr="$1"; shift; bd_cl_pickup "$thr"; bd_cl_run "$thr" "$@"; }
bd_cl_got() { printf '%s|%s|%s|%s|%s' "$(bd_dir_res "$BD_CD" status)" "$(bd_dir_res "$BD_CD" reason)" "$(bd_dir_res "$BD_CD" binding status)" "$(bd_order "$BD_CD.order" ,)" "$BD_REPLIED"; }
BD_CL_PRE="set model claude-opus-5-5,set effort low,set-mode plan,"
bd_cl_expect() {  # <label> <status|reason|binding status|order|replies> [text the result's note must carry: the cause]
  [ "$(bd_cl_got)" = "$2" ] && case "$(bd_dir_res "$BD_CD" note)" in *"${3:-}"*) true ;; *) false ;; esac \
    && ok "claude leg: $1" || fail "claude leg: $1 — got $(bd_cl_got); $(bd_dir_res "$BD_CD" note | cut -c1-300)"
}
bd_cl_case t01 AX_SET_FAIL=effort
bd_cl_expect "a set the adapter rejects refuses policy-unapplied before any prompt" "failed|policy-unapplied|refused|set model claude-opus-5-5,set effort low,|0" "did not confirm the bound effort 'low'"
bd_cl_case t02 AX_CLAUDE_SHOW_EFFORT=high
bd_cl_expect "a session reporting another effort fails the preflight before any prompt" "failed|policy-unapplied|refused|$BD_CL_PRE|0" "will not run the declared model/effort policy"
bd_cl_case t03 AX_CLAUDE_NO_EFFORT_OPT=1
{ bd_cl_expect "a session with no effort option for a model the map gives efforts refuses effort-mismatch before any prompt" "failed|effort-mismatch|refused|$BD_CL_PRE|0" "effort option disagrees with the policy map" ; } 
[ "$(bd_dir_res "$BD_CD" binding mismatches)" = '["effort-mismatch"]' ] && ok "and binding.mismatches names effort-mismatch" || fail "effort-mismatch binding: $(bd_dir_res "$BD_CD" binding)"
bd_cl_pickup t04; bd_claude_login "$BD_HOME/.claude" console; bd_cl_run t04
{ bd_cl_expect "a login that is no longer a subscription refuses binding-mismatch, nothing launched" "failed|binding-mismatch|refused||0" "authMethod=console"; }
[ ! -e "$BD_CD.stub" ] && ok "and no acpx call was made for it" || fail "the console-login leg called acpx: $(head -2 "$BD_CD.stub")"
bd_cl_pickup t05; bd_claude_login "$BD_HOME/.claude" none; bd_cl_run t05
bd_cl_expect "a login that has gone refuses binding-mismatch, nothing launched" "failed|binding-mismatch|refused||0" "not logged in"
bd_claude_login "$BD_HOME/.claude" subscription
bd_cl_pickup t06; printf '{"env":{"ANTHROPIC_CUSTOM_HEADERS":"Authorization: Bearer canary-hdr-0037"}}\n' > "$BD_HOME/.claude/settings.json"; bd_cl_run t06; rm -f "$BD_HOME/.claude/settings.json"
bd_cl_expect "user settings whose env block names ANTHROPIC_CUSTOM_HEADERS refuse binding-mismatch, nothing launched" "failed|binding-mismatch|refused||0" "settings.json env sets ANTHROPIC_CUSTOM_HEADERS"
bd_cl_case t07 AX_CLAUDE_CANARY_MODEL=claude-sonnet-5-5
{ bd_cl_expect "a canary that ran another model refuses before the review prompt is sent" "failed|policy-unapplied|ran|${BD_CL_PRE}canary,|0" "the canary turn did not run the bound model/effort"; }
[ "$(bd_dir_res "$BD_CD" binding observed)" = '{"effort":"low","model":"claude-sonnet-5-5"}' ] && ok "and binding.observed is what the canary's transcript said, not the expectation" || fail "canary observed: $(bd_dir_res "$BD_CD" binding observed)"
bd_claude_login "$BD_CCD" subscription
bd_cl_case t08 CLAUDE_CONFIG_DIR="$BD_CCD" AX_CLAUDE_TX_ROOT="$BD_HOME/.claude/projects"
{ bd_cl_expect "records written to ANOTHER config directory leave the leg's window empty: undecidable, refused before the review" "failed|policy-unapplied|ran|${BD_CL_PRE}canary,|0" "could not attest the model/effort the canary turn ran"; }
[ "$(bd_dir_res "$BD_CD" binding observed)" = '{"effort":null,"model":null}' ] && ok "and an undecidable reading observes nothing (null), never the expected pair" || fail "undecidable observed: $(bd_dir_res "$BD_CD" binding observed)"
BD_CL_ALL="${BD_CL_PRE}canary,review,"
bd_cl_case t09 AX_CLAUDE_REVIEW_EFFORT=high
{ bd_cl_expect "a review that ran another effort is refused unpublished" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "the review turn did not run the bound model/effort"; }
[ "$(bd_dir_res "$BD_CD" binding observed)" = '{"effort":"high","model":"claude-opus-5-5"}' ] && ok "and binding.observed reports the review's own effort" || fail "review observed: $(bd_dir_res "$BD_CD" binding observed)"
bd_cl_case t10 AX_CLAUDE_REVIEW_EXTRA=second:claude-sonnet-5-5
bd_cl_expect "a review window holding records of two models is refused unpublished" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "could not attest the model/effort the review turn ran"
bd_cl_case t11 AX_CLAUDE_REVIEW_EXTRA=subagent:claude-sonnet-5-5
bd_cl_expect "a subagent on another model is refused unpublished (subagent files are in the window)" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "could not attest the model/effort the review turn ran"
bd_cl_case t12 AX_CLAUDE_REVIEW_EXTRA=synthetic-billed
bd_cl_expect "a synthetic record that carries tokens makes the window undecidable: refused unpublished" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "could not attest the model/effort the review turn ran"
bd_cl_case t13 AX_CLAUDE_REVIEW_EXTRA=replace
bd_cl_expect "a transcript file replaced during the review (an unbounded window) is refused unpublished" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "could not attest the model/effort the review turn ran"
bd_cl_case t14 AX_CLAUDE_REVIEW_MODEL=skip
bd_cl_expect "a review that left no record (an absent window) is refused unpublished" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "could not attest the model/effort the review turn ran"
# A RUNNER THAT DIES after that failed review attestation (code review r1, B2): await rebuilds the result from the run's
# own turn.tsv, where the canary's passing pair was appended BEFORE the review's unknown one. The latest observation is
# authoritative, so the rebuilt result observes nothing rather than the canary's pair.
BD_CK="$BD/clr-t14-crash"; mkdir -p "$BD_CK"; cp "$BD_CD/turn.tsv" "$BD_CK/turn.tsv"
sh -c 'exit 0' & BD_P=$!; wait "$BD_P" 2>/dev/null || true; printf '%s\n' "$BD_P" > "$BD_CK/pid"
bd "$RP" await "$BD_CK" --timeout-secs 30 >/dev/null 2>&1 || true
{ [ "$(sed -n 's/^observed_model	//p' "$BD_CK/turn.tsv" | tr '\n' ' ')" = "claude-opus-5-5 unknown " ] && [ "$(bd_dir_res "$BD_CK" binding status)" = ran ] \
  && [ "$(bd_dir_res "$BD_CK" binding observed)" = '{"effort":null,"model":null}' ]; } \
  && ok "a runner killed after that review: the rebuilt result observes nothing, never the canary's earlier pair" || fail "crash after a failed review attestation: $(sed -n 's/^observed_model	//p' "$BD_CK/turn.tsv" | tr '\n' ' ') $(bd_dir_res "$BD_CK" binding)"
# SNAPSHOT FAILURES at each boundary: a stale snapshot file at the path never stands in for a fresh one.
bd_cl_pickup t15; BD_CD="$BD/clr-t15"; mkdir -p "$BD_CD"; printf '{"files": {}}' > "$BD_CD/transcript-canary-snapshot.json"
chmod 000 "$BD_HOME/.claude/projects"; bd_cl_run t15; chmod 755 "$BD_HOME/.claude/projects"
bd_cl_expect "a transcript that cannot be snapshotted before the canary refuses with no prompt sent, though a stale snapshot file sat at the path" "failed|policy-unapplied|refused|$BD_CL_PRE|0" "could not snapshot Claude's transcript for the mount before the canary"
bd_cl_case t16 AX_CLAUDE_CANARY_BLOCK="$BD/clr-t16/transcript-snapshot.json"
bd_cl_expect "a review-window snapshot that cannot be made after a passing canary refuses with no review prompt sent" "failed|policy-unapplied|ran|${BD_CL_PRE}canary,|0" "could not snapshot Claude's transcript before the review prompt"

section "binding: a bound claude leg's transcript window is attributed by directory (subagents, a cd, a subdirectory's project, a truncated mount)"
bd_cl_case t17 AX_CLAUDE_REVIEW_EXTRA=synthetic-zero,cd:,subagent:claude-opus-5-5
{ bd_cl_expect "a zero-usage synthetic record, a record whose cwd moved into a subdirectory and a subagent on the bound pair all pass" "completed||ran|$BD_CL_ALL|1"; }
[ "$(bd_dir_res "$BD_CD" binding observed)" = '{"effort":"low","model":"claude-opus-5-5"}' ] && ok "and the passing window observed the bound pair" || fail "passing window observed: $(bd_dir_res "$BD_CD" binding observed)"
bd_cl_case t18 AX_CLAUDE_REVIEW_EXTRA=cd:claude-sonnet-5-5
bd_cl_expect "the same cd with the second record on another model is refused as two models (no record is filtered by its cwd)" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "could not attest the model/effort the review turn ran"
bd_cl_case t19 AX_CLAUDE_REVIEW_EXTRA=subproject:claude-sonnet-5-5
bd_cl_expect "another model's record in the project directory named for a SUBDIRECTORY of the mount is refused, not missed" "failed|policy-unapplied|ran|$BD_CL_ALL|0" "could not attest the model/effort the review turn ran"
# A MOUNT BASE long enough that Claude would truncate the project directory: refused before the canary, though every
# record the stub would have written matches, so no filtering path exists for a truncated directory.
BD_CMB_LONG="$BD_CMB/$(printf 'l%.0s' $(seq 1 100))"; mkdir -p "$BD_CMB_LONG"
bd_cl_case t20 COMMS_MOUNT_BASE="$BD_CMB_LONG"
bd_cl_expect "a mount whose transcript directory name Claude would truncate is refused before the canary, nothing prompted" "failed|policy-unapplied|refused|$BD_CL_PRE|0" "could not snapshot Claude's transcript for the mount before the canary"
BD_TXP="$BD/tx-prefix"; BD_TXC="$BD_CMB_LONG/$(printf 'x%.0s' $(seq 1 100))/view/tree"; BD_TXS="$(printf '%s' "$BD_TXC" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$BD_TXP/${BD_TXS:0:200}-0a1b2c"; printf '{"type":"assistant","effort":"low","message":{"model":"claude-opus-5-5"}}\n' > "$BD_TXP/${BD_TXS:0:200}-0a1b2c/s.jsonl"
printf '{"files": {}}' > "$BD/tx-prefix.json"
python3 -I "$REPO/helpers/claude_transcript.py" observe "$BD_TXP" "$BD_TXC" "$BD/tx-prefix.json" >/dev/null 2>&1; A=$?
[ "$A" = 21 ] && ok "claude_transcript.py observe given only a prefix-matched (truncated) directory is undecidable (21)" || fail "prefix-matched observe returned $A"
# AN ACCESS ERROR IS NOT ABSENCE (code review r1, B1). With the config directory ABOVE the records root unsearchable, the
# root cannot be shown absent: an empty snapshot then would let a historical matching record, read again once the
# directory is searchable, stand in for the next prompt's. The snapshot refuses and writes nothing.
BD_TXA="$BD/tx-anc"; BD_TXAC="$BD_CMB/anc/view/tree"; BD_TXAS="$(printf '%s' "$BD_TXAC" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$BD_TXAC" "$BD_TXA/cfg/projects/$BD_TXAS"; printf '{"type":"assistant","effort":"low","message":{"model":"claude-opus-5-5"}}\n' > "$BD_TXA/cfg/projects/$BD_TXAS/old.jsonl"
chmod 000 "$BD_TXA/cfg"; python3 -I "$REPO/helpers/claude_transcript.py" snapshot "$BD_TXA/cfg/projects" "$BD_TXAC" "$BD_TXA/snap.json" >/dev/null 2>&1; A=$?; chmod 755 "$BD_TXA/cfg"
[ "$A" = 21 ] && [ ! -e "$BD_TXA/snap.json" ] \
  && ok "claude_transcript.py snapshot below a directory that cannot be searched refuses (21) and writes no snapshot" || fail "snapshot under an unsearchable ancestor returned $A ($(cat "$BD_TXA/snap.json" 2>/dev/null))"

section "binding: a bound claude model with no effort scale binds with a null effort and is attested on the model alone"
# The shipped map declares no such model yet (no transcript evidence for one), so a copy of the helpers carries a map that
# does: `pair ... none` and the id its transcript records. It sits beside a link to the checkout's docs/, where the
# runner finds the review bar (loopspec fragments) for a helpers directory that is not installed.
BD_HC="$BD/hc/helpers"; mkdir -p "$BD_HC"; cp -R "$REPO/helpers/." "$BD_HC/"; ln -s "$REPO/docs" "$BD/hc/docs"
printf 'pair\tclaude\tacp-mounted\ttest-haiku\tnone\nrecorded\tclaude\tacp-mounted\ttest-haiku\tclaude-test-haiku\n' >> "$BD_HC/policy-map.tsv"
bd_wb "$BD/cl0.json" "$(bj "$BD_L_CLAUDE" "d.update(model='test-haiku', effort=None)")"
rm -f "$BD/cl0-order.log" "$BD/cl0-env.log"
OUT="$(bd_cl COMMS_WAIT=1 CLAUDE_CODE_EFFORT_LEVEL=max ACP_PARITY_PAYLOAD="$BD_PAY" AX_ORDER_LOG="$BD/cl0-order.log" AX_CLAUDE_NO_EFFORT_OPT=1 \
        AX_CLAUDE_CANARY_MODEL=claude-test-haiku AX_CLAUDE_REVIEW_MODEL=claude-test-haiku AX_ENVDUMP_LOG="$BD/cl0-env.log" AX_ENVDUMP_VARS=CLAUDE_CODE_EFFORT_LEVEL \
        "$BD_HC/comms.sh" panel dispatch --bindings "$BD/cl0.json" --set bd-cl0-set "$(bd_req c3)" 2>&1)"; A=$?
{ [ "$A" = 0 ] && [ "$(bd_res claude-review status)" = completed ] && [ "$(bd_order "$BD/cl0-order.log" '|')" = "set model test-haiku|set-mode plan|canary|review|" ] \
  && [ "$(bd_res claude-review binding expected)" = '{"effort":null,"model":"test-haiku"}' ] && [ "$(bd_res claude-review binding observed)" = '{"effort":null,"model":"claude-test-haiku"}' ] \
  && [ "$(bd_cl_seen "$BD/cl0-env.log" CLAUDE_CODE_EFFORT_LEVEL)" = "<unset> " ]; } \
  && ok "an effortless model: no effort is set or injected (an inherited one is scrubbed), and the transcript's model id is attested against the recorded row" || fail "effortless leg (rc=$A, $(bd_res claude-review status): $(bd_res claude-review note)): $(bd_order "$BD/cl0-order.log" '|') $(bd_res claude-review binding)"
bd_reset; BD_REQ_FROM=claude
