# Run through tests/run.sh; each group gets fresh fixtures. The static half of the exact-per-leg-binding
# contract: access profiles, the capability line, plan and dispatch refusals, record compatibility, the installed copy.
. "$REPO/tests/lib/binding.sh"
fixture_binding

section "binding: access profiles (access.json), agents --access and the capability line"
BD_D_CODEX="$(python3 -c 'import hashlib,json; e={"route_id":"codex-subscription","transport":"acp","provider":"openai","account":"primary","billing":"subscription","credential":None}; print(hashlib.sha256(json.dumps(e,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
OUT="$(bd "$COMMS" agents --access codex 2>&1)"
[ "$OUT" = "access v1 agent=codex route_id=codex-subscription transport=acp provider=openai account=primary billing=subscription credential=- access_digest=$BD_D_CODEX" ] \
  && ok "agents --access prints the agent's one access entry and the sha256 of its canonical form" || fail "agents --access codex: $OUT"
OUT="$(bd "$COMMS" agents --access gemini 2>&1)"
case "$OUT" in *"credential=env:BD_GEMINI_KEY "*) ok "an api entry names its credential REFERENCE" ;; *) fail "agents --access gemini: $OUT" ;; esac
case "$OUT" in *"$BD_KEY_GEMINI"*) fail "agents --access printed a credential VALUE" ;; *) ok "agents --access never prints, and never needs, the credential value" ;; esac
OUT="$(bd "$COMMS" agents --access codex-review 2>&1)"
[ "$OUT" = "$(bd "$COMMS" agents --access codex | sed 's/agent=codex /agent=codex-review /')" ] \
  && ok "a review twin with no entry of its own runs under its driver's entry" || fail "twin entry: $OUT"
OUT="$(bd "$COMMS" agents --access claude 2>&1)"; A=$?
{ [ "$A" = 1 ] && grep -q 'no access profile for claude' <<<"$OUT"; } && ok "an agent with no entry has no access profile (exit 1)" || fail "claude access (rc=$A): $OUT"
OUT="$(bd "$COMMS" agents --access nobody 2>&1)"; A=$?
[ "$A" = 1 ] && ok "agents --access on an unregistered agent is refused" || fail "unknown agent access (rc=$A)"
[ "$(bd "$COMMS" agents --access codex --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["billing"], d["access_digest"] == sys.argv[1])' "$BD_D_CODEX")" = "subscription True" ] \
  && ok "agents --access --json prints the same entry as an object" || fail "agents --access --json"

# THE STRICT READER. Every defect below must fail the whole file, never skip the entry.
bd_bad() {  # <label> <python statements> <expected words> -> ok when agents --access fails closed, for that reason
  bd_mut access "$2"
  OUT="$(bd "$COMMS" agents --access codex 2>&1)"; A=$?
  { [ "$A" != 0 ] && grep -q -- "$3" <<<"$OUT"; } && ok "access.json refuses: $1" || fail "access.json accepted, or refused for another reason: $1 (rc=$A: $OUT)"
}
bd_bad "an unknown field" "d['agents']['codex']['seat']='x'" "unknown fields"
bd_bad "a missing field" "del d['agents']['codex']['account']" "missing fields"
bd_bad "a value-shaped credential" "d['agents']['gemini']['credential']='sk-live-0123456789abcdef'" "never a value"
bd_bad "an api route with no credential reference" "d['agents']['gemini']['credential']=None" "exactly one credential"
bd_bad "a subscription route that names a credential" "d['agents']['codex']['credential']='env:SOMETHING'" "exactly one credential"
bd_bad "an unknown billing class" "d['agents']['codex']['billing']='prepaid'" "billing must be"
bd_bad "a transport other than acp or cli" "d['agents']['codex']['transport']='mailbox'" "transport must be"
bd_bad "a route id with a space" "d['agents']['codex']['route_id']='a b'" "bare token"
bd_bad "an entry for an agent nobody configured" "d['agents']['ghost']=d['agents']['codex']" "unknown agent"
bd_bad "a twin whose entry differs from its driver's" "d['agents']['codex-review']=dict(d['agents']['codex'], account='other')" "differs from"
bd_bad "two agents on one route that differ in another field" "d['agents']['glm2']['account']='second'" "share route_id"
bd_bad "a provider that is not the profile's api_provider" "d['agents']['glm']['provider']='elsewhere'" "api_provider"
bd_bad "a credential that is not the profile's declared reference" "d['agents']['glm']['credential']='env:SOME_OTHER_KEY'" "declared credential"
bd_bad "a subscription entry on a profile that declares a credential" "d['agents']['glm'].update(billing='subscription', credential=None)" "declares a credential"
printf '{"version":1,"version":1,"agents":{}}' > "$BD_AH/access.json"
OUT="$(bd "$COMMS" agents --access codex 2>&1)"; [ $? != 0 ] && ok "access.json refuses: a duplicate key" || fail "duplicate key accepted"
bd_reset; chmod 666 "$BD_AH/access.json"
OUT="$(bd "$COMMS" agents --access codex 2>&1)"; [ $? != 0 ] && ok "access.json refuses: a file writable by group or others" || fail "writable access.json accepted"
rm -f "$BD_AH/access.json"; ln -s "$BD/access.base.json" "$BD_AH/access.json"
OUT="$(bd "$COMMS" agents --access codex 2>&1)"; [ $? != 0 ] && ok "access.json refuses: a symlink" || fail "symlinked access.json accepted"
rm -f "$BD_AH/access.json"; bd_reset
bd_mut agents "d['agents']['glm']['credentials']={}; d['agents']['glm']['connection']['api_key_env']='VENICE_API_KEY'"
OUT="$(bd "$COMMS" agents --access glm 2>&1)"; [ $? != 0 ] && ok "access.json refuses: an api entry on a profile that declares no credential" || fail "api entry without profile credential accepted"
bd_reset
# A twin with an identical entry is accepted: the same entry, not a second account.
bd_mut access "d['agents']['codex-review']=dict(d['agents']['codex'])"
[ "$(bd "$COMMS" agents --access codex-review 2>&1 | cut -c1-30)" = "access v1 agent=codex-review r" ] \
  && ok "a twin may carry the same entry as its driver" || fail "identical twin entry refused"
bd_reset
# Unbound callers never read the file: a malformed access.json cannot disturb them.
printf 'not json' > "$BD_AH/access.json"; chmod 600 "$BD_AH/access.json"
[ "$(bd "$COMMS" agents --family codex 2>&1)" = codex ] && [ "$(bd "$COMMS" agents --drivers 2>&1 | wc -w | tr -d ' ')" -ge 4 ] \
  && ok "an unbound caller never reads access.json (a broken file disturbs nothing else)" || fail "broken access.json disturbed the registry"
bd_reset

# THE CAPABILITY LINE Basis negotiates on, and the per-agent statement of what is bindable.
OUT="$(bd "$COMMS" review-route capability 2>&1)"; A=$?
[ "$(sed -n 1p <<<"$OUT")" = "leg-binding-capability v1 leg-bindings=1 route-view=2 leg-metadata=1" ] && [ "$A" = 0 ] \
  && ok "review-route capability prints the pinned negotiation line and exits 0" || fail "capability (rc=$A): $(sed -n 1p <<<"$OUT")"
cap_line() { grep "^agent=$1 " <<<"$OUT"; }
[ "$(cap_line codex)" = "agent=codex class=bindable harness=codex reason=- billing=subscription" ] \
  && [ "$(cap_line gemini)" = "agent=gemini class=bindable harness=gemini reason=- billing=api" ] \
  && [ "$(cap_line glm)" = "agent=glm class=bindable-model-only harness=glm reason=- billing=api" ] \
  && ok "codex and gemini are bindable (model and effort); an OpenCode profile is bindable-model-only" || fail "capability classes: $(grep '^agent=' <<<"$OUT" | tr '\n' '|')"
[ "$(cap_line claude)" = "agent=claude class=unbindable harness=claude reason=claude-unsupported billing=-" ] \
  && [ "$(cap_line grok)" = "agent=grok class=unbindable harness=grok reason=grok-unsupported billing=-" ] \
  && [ "$(cap_line gacp)" = "agent=gacp class=unbindable harness=gacp reason=consult-only billing=-" ] \
  && ok "claude and grok (no applied, attested policy) and a generic ACP profile (consult-only) are unbindable, with the reason" || fail "capability unbindables: $(grep '^agent=' <<<"$OUT" | tr '\n' '|')"
[ "$(cap_line codex-review)" = "agent=codex-review class=bindable harness=codex reason=- billing=subscription" ] \
  && ok "a review twin reports its driver's class and billing" || fail "twin capability: $(cap_line codex-review)"
OUT2="$(bd COMMS_DELIVERY=mailbox "$COMMS" review-route capability 2>&1)"
[ "$(grep -c 'class=unbindable harness=[a-z0-9]* reason=mailbox' <<<"$OUT2")" -ge 4 ] && grep -q '^leg-binding-capability v1' <<<"$OUT2" \
  && ok "under a mailbox delivery every agent is unbindable (nobody drives a mailbox leg)" || fail "mailbox capability: $OUT2"
bd_mut access "d['agents']['codex']['billing']='api'; d['agents']['codex']['credential']='env:BD_KEY_CODEXM_REF'"
OUT3="$(bd "$COMMS" review-route capability 2>&1)"
[ "$(grep '^agent=codex ' <<<"$OUT3")" = "agent=codex class=unbindable-billing harness=codex reason=api billing=api" ] \
  && ok "a (codex, api) pair, whose API selection cannot be made explicit and read back, is unbindable-billing" || fail "unbindable-billing: $(grep '^agent=codex ' <<<"$OUT3")"
bd_reset
OUT4="$(bd "$COMMS" review-route capability --json 2>&1)"
[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["capability_version"], d["leg_bindings"], d["route_view"], d["leg_metadata"], sorted(a["agent"] for a in d["agents"])[:2])' "$OUT4")" = "1 1 2 1 ['claude', 'claude-review']" ] \
  && ok "review-route capability --json carries the same versions and every agent" || fail "capability --json: $OUT4"
printf 'not json' > "$BD_AH/access.json"; chmod 600 "$BD_AH/access.json"
OUT5="$(bd "$COMMS" review-route capability 2>&1)"; A=$?
{ [ "$A" = 1 ] && grep -q '^leg-binding-capability v1' <<<"$OUT5" && grep -q 'access profiles are unusable' <<<"$OUT5"; } \
  && ok "an unusable access file still prints the version line, says so, and exits 1" || fail "capability with broken access (rc=$A): $OUT5"
bd_reset

section "binding: review-route plan --bindings (read-only, every leg's verdict, configured access values)"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" 2>"$BD/plan.err")"; A=$?
[ "$A" = 0 ] && [ "$OUT" = "$BD_PL_CODEX
$BD_PL_GEMINI
$BD_PL_GLM" ] \
  && ok "plan prints one route-plan v2 line per leg: codex (gpt-6-luna/low), gemini and an OpenCode/Venice profile (its pinned model, no effort), in file order" \
  || fail "bound plan (rc=$A): $OUT $(cat "$BD/plan.err")"
OUT2="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" 2>&1)"
[ "$OUT2" = "$OUT" ] && ok "a repeated plan is byte-identical" || fail "plan output drifted between runs"
[ "$(bd_tree)" = "$BD_T0" ] && ok "a bound plan writes nothing: no file, event, decision, index row or snapshot ref" || fail "plan wrote to the repository"
case "$OUT$(cat "$BD/plan.err")" in *"$BD_KEY_GEMINI"*|*"$BD_KEY_VENICE"*|*canary-*) fail "plan output carries a credential value" ;; *) ok "plan output carries credential REFERENCES only, never a value" ;; esac
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" --to codex,gemini,glm 2>&1)"; A=$?
[ "$A" = 0 ] && ok "--to is accepted when it names exactly the bindings file's agents, in order" || fail "plan with equal --to (rc=$A)"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" --to gemini,codex,glm 2>&1)"; A=$?
[ "$A" = 2 ] && ok "--to in a different order is a usage error: the file decides the roster" || fail "reordered --to accepted (rc=$A)"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" --phase implement 2>&1)"; A=$?
[ "$A" = 2 ] && ok "a bound plan takes no routed-plan flags (--phase, --thread)" || fail "bound plan accepted --phase (rc=$A)"

# THE LEGACY PLAN IS UNCHANGED, byte for byte: all-or-nothing, route-plan v1, no access fields.
OUT="$(bd "$COMMS" review-route plan --to codex,grok 2>&1)"; A=$?
case "$OUT" in "route-plan v1 agent=codex provider=codex transport=acp-mounted capability=eligible model=gpt-6.1-sol effort=xhigh limit_id=- model_source=baseline effort_source=baseline routing=off decision=none phase=implement map_version=$BD_MAPV
route-plan v1 agent=grok provider=grok "*) [ "$A" = 0 ] && ok "the legacy plan still prints route-plan v1 lines with no access fields" || fail "legacy plan rc=$A" ;; *) fail "legacy plan changed: $OUT" ;; esac

# EVERY LEG'S VERDICT IS PRINTED, and a refusal is exit 1: Basis needs each candidate's answer to choose among them.
bd_wb "$BD/bmix.json" "$BD_L_CODEX" "$(bj "$BD_L_GEMINI" "d['access']['account']='someone-else'")" "$BD_L_GLM"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/bmix.json" 2>"$BD/mix.err")"; A=$?
{ [ "$A" = 1 ] && [ "$(sed -n 1p <<<"$OUT")" = "$BD_PL_CODEX" ] && [ "$(sed -n 3p <<<"$OUT")" = "$BD_PL_GLM" ] \
  && [ "$(sed -n 2p <<<"$OUT" | sed 's/ access_digest=[0-9a-f]* / access_digest=D /')" = "route-plan v2 ref=res-gemini agent=gemini harness=gemini status=refused code=account-mismatch route_id=gemini-api transport=acp provider=google account=metered billing=api credential=env:BD_GEMINI_KEY access_digest=D model=gemini-3.1-pro-preview effort=high model_source=bound effort_source=bound capability=fixed limit_id=- routing=off decision=none phase=- map_version=$BD_MAPV capability_version=1" ]; } \
  && ok "a plan with one refusing leg still prints all three verdicts (the refused leg shows the CONFIGURED account) and exits 1" || fail "mixed plan (rc=$A): $OUT"
grep -q '^refused gemini account-mismatch expected someone-else, configured metered' "$BD/mix.err" \
  && ok "the refusal names both sides: what was expected and what is configured" || fail "refusal detail: $(cat "$BD/mix.err")"
[ "$(bd_tree)" = "$BD_T0" ] && ok "a refusing plan writes nothing either" || fail "refusing plan wrote to the repository"

section "binding: all-or-nothing validation before the first durable write (panel dispatch --bindings)"
# ONE LEG, ONE DEFECT, each through the real dispatch: the whole dispatch is refused with the leg's stable code, and the
# repository — mailbox, coordinator log, index, snapshot refs, working tree — is byte-identical afterwards.
bd_refuse() {  # <label> <expected codes, sorted, space-terminated> <leg-json> [env assignments...]
  local label="$1" want="$2" leg="$3"; shift 3
  bd_wb "$BD/one.json" "$leg"
  local req err="$BD/one.err"; req="$(bd_req)"
  OUT="$(bd AX_CWD_LOG="$BD_TL" GM_LOG="$BD_TL" "$@" "$COMMS" panel dispatch --bindings "$BD/one.json" "$req" 2>"$err")"; A=$?
  { [ "$A" = 1 ] && [ "$(bd_codes "$(cat "$err")")" = "$want" ] && [ -z "$OUT" ] && [ "$(bd_tree | grep -v 'bd-request-')" = "$(grep -v 'bd-request-' <<<"$BD_T0")" ]; } \
    && ok "refused: $label ($want)" || fail "refusal: $label (rc=$A, codes '$(bd_codes "$(cat "$err")")', want '$want'; out: $OUT; $(head -c 300 "$err"))"
}
bd_refuse "a wrong route id" "route-mismatch " "$(bj "$BD_L_CODEX" "d['route_id']='codex-metered'")"
bd_refuse "a wrong transport" "transport-mismatch " "$(bj "$BD_L_CODEX" "d['access']['transport']='cli'")"
bd_refuse "a wrong hosting provider" "provider-mismatch " "$(bj "$BD_L_CODEX" "d['access']['provider']='anthropic'")"
bd_refuse "a wrong account" "account-mismatch " "$(bj "$BD_L_CODEX" "d['access']['account']='secondary'")"
bd_refuse "a wrong billing class" "billing-mismatch " "$(bj "$BD_L_CODEX" "d['access']['billing']='api'")"
bd_refuse "an API credential expected where the agent is on a subscription" "credential-mismatch " "$(bj "$BD_L_CODEX" "d['access']['credential']='env:BD_KEY_CODEXM_REF'")"
bd_refuse "no credential expected where the agent is on an API route" "credential-mismatch " "$(bj "$BD_L_GEMINI" "d['access']['credential']=None")"
bd_refuse "a different credential reference" "credential-mismatch " "$(bj "$BD_L_GEMINI" "d['access']['credential']='env:BD_VENICE_KEY'")"
bd_refuse "an incomplete access object (no account)" "access-incomplete " "$(bj "$BD_L_CODEX" "del d['access']['account']")"
bd_refuse "no access object at all" "access-incomplete " "$(bj "$BD_L_CODEX" "del d['access']")"
bd_refuse "several defects at once: every code is collected, not only the first" "account-mismatch billing-mismatch route-mismatch " "$(bj "$BD_L_CODEX" "d['route_id']='x'; d['access'].update(account='y', billing='free')")"
BD_REQ_FROM=codex   # claude cannot be both the author and a leg
bd_refuse "claude (no applied, attested policy; no access entry)" "agent-unbindable no-access-profile " "$(bj "$BD_L_CODEX" "d.update(agent='claude', ref='res-claude')")"
BD_REQ_FROM=claude
bd_refuse "grok (no applied, attested policy; no access entry)" "agent-unbindable no-access-profile " "$(bj "$BD_L_CODEX" "d.update(agent='grok', ref='res-grok')")"
bd_refuse "a generic ACP profile (consult-only)" "agent-unbindable no-access-profile " "$(bj "$BD_L_GLM" "d.update(agent='gacp', ref='res-gacp')")"
bd_refuse "a mailbox leg (nobody drives it)" "agent-unbindable " "$BD_L_CODEX" COMMS_DELIVERY=mailbox
bd_refuse "a model the runtime cannot serve (disabled in the map)" "model-unservable " "$(bj "$BD_L_GEMINI" "d['model']='gemini-4-pro'")"
printf '#!/bin/sh\necho "codex-cli 0.154.0"\n' > "$BD/old-codex"; chmod +x "$BD/old-codex"
bd_refuse "a model newer than the reviewer runtime" "model-unservable " "$(bj "$BD_L_CODEX" "d.update(model='gpt-6-sol', effort='high')")" COMMS_ACP_CODEX_PATH="$BD/old-codex"
bd_refuse "an effort outside the model's accepted set" "effort-refused " "$(bj "$BD_L_CODEX" "d['effort']='ultra'")"
bd_refuse "a null effort on a model with a native scale" "effort-mismatch " "$(bj "$BD_L_CODEX" "d['effort']=None")"
bd_refuse "an effort on a pinned-model profile that has no scale" "effort-mismatch " "$(bj "$BD_L_GLM" "d['effort']='high'")"
bd_refuse "a model the profile does not pin" "model-mismatch " "$(bj "$BD_L_GLM" "d['model']='venice/some-other-model'")"
bd_refuse "an environment model pin that differs from the binding" "pin-conflict " "$BD_L_CODEX" COMMS_ACP_CODEX_MODEL=gpt-6.1-sol
bd_refuse "an environment effort pin that differs from the binding" "pin-conflict " "$BD_L_CODEX" COMMS_ACP_CODEX_EFFORT=high
bd_refuse "COMMS_REVIEW_MAX (use max) in the dispatching environment" "pin-conflict " "$BD_L_CODEX" COMMS_REVIEW_MAX=1
bd_refuse "an API credential that is not present" "credential-unavailable " "$BD_L_GEMINI" BD_GEMINI_KEY=
bd_mut access "d['agents']['codex'].update(billing='api', credential='env:BD_KEY_CODEXM_REF', route_id='codex-api')"
bd_refuse "a (codex, api) pair with no explicit API selection" "auth-route-unsupported " "$(bj "$BD_L_CODEX" "d['route_id']='codex-api'; d['access']['billing']='api'; d['access']['credential']='env:BD_KEY_CODEXM_REF'")" BD_KEY_CODEXM_REF="$BD_KEY_CODEXM"
bd_reset
# THE SAVED LOGIN STATE, planted and judged without reading a secret: the key alone selects nothing, so a leg
# whose saved login says otherwise is refused rather than run on the hope that the environment wins.
cp "$BD_HOME/.codex/auth.json" "$BD/codex-auth.chatgpt"
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"canary-codex-apikey-0009"}\n' > "$BD_HOME/.codex/auth.json"
bd_refuse "a subscription codex leg whose saved login is in API-key mode" "auth-selected-type-conflict " "$BD_L_CODEX"
rm -f "$BD_HOME/.codex/auth.json"
bd_refuse "a subscription codex leg with no saved login" "auth-login-missing " "$BD_L_CODEX"
cp "$BD/codex-auth.chatgpt" "$BD_HOME/.codex/auth.json"
bd_mut access "d['agents']['gemini'].update(billing='subscription', credential=None, route_id='gemini-sub')"
printf '{"security":{"auth":{"selectedType":"gemini-api-key"}}}\n' > "$BD_HOME/.gemini/settings.json"
bd_refuse "a subscription gemini leg while the operator's selected auth type is an API key" "auth-selected-type-conflict " "$BD_L_GEMINI_SUB"
printf '{}\n' > "$BD_HOME/.gemini/settings.json"; mv "$BD_HOME/.gemini/oauth_creds.json" "$BD/gemini-oauth.saved"
bd_refuse "a subscription gemini leg with no saved login and no OAuth selection" "auth-login-missing " "$BD_L_GEMINI_SUB"
mv "$BD/gemini-oauth.saved" "$BD_HOME/.gemini/oauth_creds.json"
printf '{"security":{"auth":{"selectedType":"oauth-personal"}}}\n' > "$BD_HOME/.gemini/settings.json"
bd_reset

# NO PARTIAL PANEL. Two good legs and a bad third: nothing was snapshotted, logged, indexed or sent, and no provider
# stub was ever invoked.
bd_wb "$BD/partial.json" "$BD_L_CODEX" "$BD_L_GEMINI" "$(bj "$BD_L_GLM" "d['access']['account']='nope'")"
PN_REQ="$(bd_req bd-partial)"
OUT="$(bd COMMS_WAIT=1 AX_CWD_LOG="$BD_TL" GM_LOG="$BD_TL" "$COMMS" panel dispatch --bindings "$BD/partial.json" "$PN_REQ" 2>"$BD/partial.err")"; A=$?
{ [ "$A" = 1 ] && [ -z "$OUT" ] && [ "$(bd_codes "$(cat "$BD/partial.err")")" = "account-mismatch " ]; } \
  && ok "a three-leg dispatch whose last leg is bad is refused as a whole, naming the bad leg" || fail "partial panel (rc=$A): $OUT $(cat "$BD/partial.err")"
[ "$(bd_tree | grep -v 'bd-request-')" = "$(grep -v 'bd-request-' <<<"$BD_T0")" ] \
  && ok "it left no snapshot ref, event, index row, attempts marker, leg file or run directory (directory comparison)" || fail "a refused panel wrote: $(diff <(grep -v 'bd-request-' <<<"$BD_T0") <(bd_tree | grep -v 'bd-request-') | head -6 | tr '\n' ' ')"
[ ! -e "$BD_TL" ] && [ "$(bd_run_dirs)" = 0 ] && ok "and no provider stub (acpx, gemini) was invoked for any of the three legs" || fail "a stub ran: $(cat "$BD_TL" 2>/dev/null | head -3)"
[ -z "$(git -C "$BD_REPO" for-each-ref refs/agent-comms)" ] && [ ! -e "$BD_REPO/.comms/events.tsv" ] \
  && ok "the artifact was never retained and the coordinator log was never created" || fail "snapshot refs or an event log exist after a refusal"
# An OPTIONAL leg failing validation refuses the dispatch too: which legs exist is the caller's decision, so this
# tool never drops one.
bd_wb "$BD/opt.json" "$BD_L_CODEX" "$(bj "$BD_L_GEMINI" "d['model']='gemini-4-pro'")"
OUT="$(bd "$COMMS" panel dispatch --bindings "$BD/opt.json" "$(bd_req)" 2>&1)"; A=$?
{ [ "$A" = 1 ] && grep -q '^refused gemini model-unservable' <<<"$OUT" && [ "$(bd_run_dirs)" = 0 ]; } \
  && ok "an optional leg that cannot run refuses the whole dispatch (the gate never starts); agent-comms never drops a leg itself" || fail "optional leg (rc=$A): $OUT"

# MALFORMED BINDINGS are usage errors (exit 2), and write nothing.
bd_malformed() {  # <label> <file-writing shell>
  eval "$2"
  OUT="$(bd "$COMMS" panel dispatch --bindings "$BD/mal.json" "$(bd_req)" 2>&1)"; A=$?
  { [ "$A" = 2 ] && [ "$(bd_tree | grep -v 'bd-request-')" = "$(grep -v 'bd-request-' <<<"$BD_T0")" ]; } && ok "malformed bindings refused with exit 2: $1" || fail "malformed bindings ($1): rc=$A $OUT"
}
bd_malformed "not JSON" "printf 'nope' > \"\$BD/mal.json\""
bd_malformed "a duplicate key" "printf '{\"schema\":\"leg-bindings/1\",\"schema\":\"leg-bindings/1\",\"legs\":[]}' > \"\$BD/mal.json\""
bd_malformed "another schema" "python3 -c 'import json; json.dump({\"schema\":\"leg-bindings/2\",\"legs\":[json.loads(\"\"\"$BD_L_CODEX\"\"\")]}, open(\"$BD/mal.json\",\"w\"))'"
bd_malformed "an unknown leg field" "bd_wb \"\$BD/mal.json\" \"\$(bj \"\$BD_L_CODEX\" \"d['tier']='fast'\")\""
bd_malformed "an unknown access field" "bd_wb \"\$BD/mal.json\" \"\$(bj \"\$BD_L_CODEX\" \"d['access']['seat']='x'\")\""
bd_malformed "no legs" "printf '{\"schema\":\"leg-bindings/1\",\"legs\":[]}' > \"\$BD/mal.json\""
bd_malformed "an agent listed twice" "bd_wb \"\$BD/mal.json\" \"\$BD_L_CODEX\" \"\$(bj \"\$BD_L_CODEX\" \"d['ref']='other'\")\""
bd_malformed "a model that is not a bare token" "bd_wb \"\$BD/mal.json\" \"\$(bj \"\$BD_L_CODEX\" \"d['model']='a b'\")\""
bd_malformed "a missing leg field (no model)" "bd_wb \"\$BD/mal.json\" \"\$(bj \"\$BD_L_CODEX\" \"del d['model']\")\""
bd_malformed "a file over the size bound" "python3 -c 'print(\" \"*70000)' > \"\$BD/mal.json\""
OUT="$(bd "$COMMS" panel dispatch --bindings "$BD/nofile.json" "$(bd_req)" 2>&1)"; [ $? = 2 ] && ok "a bindings file that does not exist is a usage error" || fail "missing bindings file accepted"

section "binding: roster family semantics (one leg per family, whatever the route or account)"
bd_wb "$BD/fam.json" "$BD_L_GLM" "$(bj "$BD_L_GLM" "d.update(agent='glmx', ref='res-glmx', route_id='venice-other'); d['access'].update(account='other', credential='env:BD_VENICE_OTHER_KEY')")"
OUT="$(bd "$COMMS" panel dispatch --bindings "$BD/fam.json" "$(bd_req)" 2>&1)"; A=$?
{ [ "$A" = 2 ] && grep -q "two legs on provider 'glm'" <<<"$OUT"; } \
  && ok "two accounts of one family (glm on two Venice routes) are two legs on one provider: refused as a usage error" || fail "same-family legs (rc=$A): $OUT"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/fam.json" 2>&1)"; A=$?
[ "$A" = 2 ] && ok "a plan refuses the same roster dispatch would, so a plan cannot promise it" || fail "plan accepted a same-family roster (rc=$A)"
bd_wb "$BD/fam2.json" "$BD_L_CODEX" "$BD_L_GLM"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/fam2.json" 2>&1)"; A=$?
[ "$A" = 0 ] && [ "$(wc -l <<<"$OUT" | tr -d ' ')" = 2 ] \
  && ok "a custom family-glm leg (Venice-hosted) and a codex leg are independent: both bind" || fail "glm+codex (rc=$A): $OUT"
bd_wb "$BD/fam3.json" "$BD_L_GLM" "$(bj "$BD_L_GLM" "d.update(agent='glm2', ref='res-glm2', model='venice/glm-model-b')")"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/fam3.json" 2>&1)"; A=$?
[ "$A" = 0 ] && grep -q 'agent=glm2 .*route_id=venice-api .*model=venice/glm-model-b ' <<<"$OUT" && grep -q 'agent=glm .*route_id=venice-api ' <<<"$OUT" \
  && ok "one Venice route serves two agents pinned to different models (independent families): each binds its own pinned model" || fail "shared route (rc=$A): $OUT"
bd_wb "$BD/fam4.json" "$BD_L_CODEX" "$(bj "$BD_L_CODEX" "d.update(agent='codex-review', ref='res-twin')")"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/fam4.json" 2>&1)"; A=$?
{ [ "$A" = 2 ] && grep -q "two legs on provider 'codex'" <<<"$OUT"; } \
  && ok "a driver and its own review twin are one family: refused" || fail "codex + codex-review (rc=$A): $OUT"
bd_wb "$BD/fam5.json" "$BD_L_CODEX" "$BD_L_CODEX"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/fam5.json" 2>&1)"; [ $? = 2 ] && ok "one agent listed twice is refused" || fail "duplicate agent accepted"
bd_wb "$BD/fam6.json" "$(bj "$BD_L_CODEX" "d.update(agent='claude', ref='res-self')")"
OUT="$(bd "$COMMS" panel dispatch --bindings "$BD/fam6.json" "$(bd_req)" 2>&1)"; A=$?
{ [ "$A" = 2 ] && grep -q "'claude' authored this request" <<<"$OUT"; } && ok "the author is never a leg, whatever the binding says" || fail "author as a leg (rc=$A): $OUT"

section "binding: retained policy records stay readable (versions 1 and 2) and a custom profile binds through no map row"
# RETAINED RECORDS. A version-1 policy record written before an upgrade is read after it: provider-config, policy and route-view.
AP="$REPO/helpers/acp.sh"
bda() { (cd "$BD_REPO" && env AGENT_COMMS_HOME="$BD_AH" HOME="$BD_HOME" PATH="$GMB:$AXB:$PATH" "$@"); }
bda "$AP" resolve codex --transport acp-mounted --tier fast --effort low --decision rd-0123456789abcdef0123456789abcdef --routing on --phase implement --candidate-source explicit > "$BD/v1.rec" 2>/dev/null
{ [ "$(sed -n 1p "$BD/v1.rec")" = "policy_record	1" ] && ! grep -q '^\(route_id\|access_digest\|bound\)	' "$BD/v1.rec" && [ "$(awk -F'\t' '{print $1}' "$BD/v1.rec" | tr '\n' ' ')" = "policy_record map_version provider transport capability routing decision candidate_source phase candidate_tier candidate_effort model effort model_source effort_source limit_id effective_tier effective_effort pair runtime runtime_version fallback verify policy_digest " ]; } \
  && ok "an unbound resolution still writes version 1 with exactly its 24 original keys in their original order" || fail "unbound record shape: $(awk -F'\t' '{print $1}' "$BD/v1.rec" | tr '\n' ' ')"
BD_V1CFG="$(bda "$AP" provider-config codex --policy-file "$BD/v1.rec")"; BD_V1POL="$(bda "$AP" policy codex --policy-file "$BD/v1.rec")"
grep -q '^model = "gpt-6-luna"$' <<<"$BD_V1CFG" && grep -q "gpt-6-luna	low" <<<"$BD_V1POL" \
  && [ "$(bda "$AP" route-view codex "$BD/v1.rec")" = "transport=acp-mounted capability=eligible model=gpt-6-luna effort=low limit_id=- model_source=route effort_source=route routing=on decision=rd-0123456789abcdef0123456789abcdef phase=implement map_version=$BD_MAPV" ] \
  && ok "a retained version-1 record still reads (provider-config, policy) and its route view keeps the version-1 fields" || fail "v1 record no longer reads"
bda "$AP" resolve codex --transport acp-mounted --bound-model gpt-6-luna --bound-effort low --route-id codex-subscription --access-digest "$BD_DG_CODEX" > "$BD/v2.rec" 2>/dev/null
{ [ "$(sed -n 1p "$BD/v2.rec")" = "policy_record	2" ] && [ "$(awk -F'\t' '{print $1}' "$BD/v2.rec" | tail -3 | tr '\n' ' ')" = "route_id access_digest bound " ] && grep -q '^candidate_source	bound$' "$BD/v2.rec" && grep -q '^decision	none$' "$BD/v2.rec"; } \
  && ok "a bound resolution writes version 2: the same keys plus route_id, access_digest and bound" || fail "v2 record: $(tr '\t\n' '= ' < "$BD/v2.rec" | cut -c1-300)"
BD_V2CFG="$(bda "$AP" provider-config codex --policy-file "$BD/v2.rec")"
grep -q '^model = "gpt-6-luna"$' <<<"$BD_V2CFG" \
  && [ "$(bda "$AP" route-view codex "$BD/v2.rec")" = "transport=acp-mounted capability=eligible model=gpt-6-luna effort=low limit_id=- model_source=bound effort_source=bound routing=off decision=none phase=- map_version=$BD_MAPV route_id=codex-subscription access_digest=$BD_DG_CODEX" ] \
  && ok "a version-2 record reads everywhere, and its route view (fields version 2) appends route_id and access_digest" || fail "v2 record read: $(bda "$AP" route-view codex "$BD/v2.rec" 2>&1)"
{ grep -v '^bound	' "$BD/v2.rec" > "$BD/v2-nobound.rec"; ! bda "$AP" provider-config codex --policy-file "$BD/v2-nobound.rec" >/dev/null 2>&1; } \
  && ok "a version-2 record missing a version-2 key is refused" || fail "incomplete v2 record read"
{ { cat "$BD/v1.rec"; printf 'bound\t1\n'; } > "$BD/v1-bound.rec"; ! bda "$AP" provider-config codex --policy-file "$BD/v1-bound.rec" >/dev/null 2>&1 && ! bda "$AP" route-view codex "$BD/v1-bound.rec" >/dev/null 2>&1; } \
  && ok "a version-1 record that carries a version-2 key is refused (each version is held to its own field set)" || fail "v1 record with a v2 key accepted"
bda "$AP" resolve codex --transport acp-mounted --bound-model gpt-6-luna --bound-effort low --route-id codex-subscription --access-digest "$(printf 'f%.0s' $(seq 64))" > "$BD/v2b.rec" 2>/dev/null
[ "$(awk -F'\t' '$1=="policy_digest"{print $2}' "$BD/v2.rec")" != "$(awk -F'\t' '$1=="policy_digest"{print $2}' "$BD/v2b.rec")" ] \
  && [ "$(awk -F'\t' '$1=="policy_digest"{print $2}' "$BD/v2.rec")" != "$(awk -F'\t' '$1=="policy_digest"{print $2}' "$BD/v1.rec")" ] \
  && ok "the access digest is part of the policy digest, so two accounts never share one warm session" || fail "policy digest ignores the access digest"
# usage errors of the bound resolver (nothing resolved, nothing written)
for BD_BADARGS in "--bound-model gpt-6-luna" "--bound-model gpt-6-luna --bound-effort low --route-id r --access-digest abc" "--bound-model gpt-6-luna --bound-effort low --route-id r --access-digest $BD_DG_CODEX --tier fast" "--bound-model gpt-6-luna --bound-effort low --route-id r --access-digest $BD_DG_CODEX --custom-profile"; do
  bda "$AP" resolve codex --transport acp-mounted $BD_BADARGS >/dev/null 2>&1; [ $? = 2 ] && ok "acp.sh resolve usage error (exit 2): ${BD_BADARGS%% --access*}" || fail "resolve accepted: $BD_BADARGS"
done
OUT="$(bda "$AP" resolve claude --transport acp-mounted --bound-model x --bound-effort high --route-id r --access-digest "$BD_DG_CODEX" 2>&1)"
grep -q 'code=capability-unsupported' <<<"$OUT" \
  && ok "a bound resolution for claude (no applied policy) is refused as capability-unsupported" || fail "claude bound resolve"

# CUSTOM PROFILES bind through their pinned model, and through no map row.
bda "$AP" resolve glm --transport acp-mounted --bound-model venice/glm-model-a --bound-effort - --route-id venice-api --access-digest "$BD_DG_GLM" --custom-profile > "$BD/glm.rec" 2>"$BD/glm.err"; A=$?
{ [ "$A" = 0 ] && grep -q '^capability	profile$' "$BD/glm.rec" && grep -q '^model	venice/glm-model-a$' "$BD/glm.rec" && grep -q '^effort	n/a$' "$BD/glm.rec" && grep -q '^verify	model$' "$BD/glm.rec" && grep -q '^model_source	bound$' "$BD/glm.rec" && ! grep -q 'glm' "$REPO/helpers/policy-map.tsv"; } \
  && ok "an OpenCode profile resolves bound to its pinned model with no effort, and the policy map has no row for it" || fail "custom bound resolve (rc=$A): $(cat "$BD/glm.err")"
[ "$(bda "$AP" resolve glm 2>/dev/null | awk -F'\t' '$1=="capability"{print $2} $1=="policy_record"{print $2}' | tr '\n' ' ')" = "1 unsupported " ] \
  && ok "the same profile resolved UNBOUND is still unsupported at version 1, as before" || fail "unbound custom resolve changed"
OUT="$(bda "$AP" resolve gacp --transport acp-mounted --bound-model vendor/generic-model --bound-effort - --route-id r --access-digest "$BD_DG_GLM" --custom-profile 2>&1)"
grep -q 'code=agent-unbindable consult-only' <<<"$OUT" \
  && ok "a generic ACP profile is refused as consult-only: it has no mounted review runner" || fail "generic ACP bound resolve"

section "binding: the installed copy negotiates, plans and refuses (install.sh into a test-owned scope)"
BD_INS="$BD/inst"; mkdir -p "$BD_INS/proj"; git -C "$BD_INS/proj" init -q -b main
(cd "$BD_INS/proj" && env CODEX_AGENTS_FILE="$BD_INS/gh/AGENTS.md" CLAUDE_COMMANDS_DIR="$BD_INS/gh/commands" CODEX_SKILLS_DIR="$BD_INS/gh/skills" \
  GROK_COMMANDS_DIR="$BD_INS/gh/grok-commands" AGENT_COMMS_HOME="$BD_INS/gh/ac" AGENT_COMMS_SETUP=0 HOME="$BD_INS/gh/home" \
  bash "$REPO/install.sh" --scope=global >"$BD_INS/install.out" 2>&1)
BD_IC="$BD_INS/gh/ac/comms.sh"
{ [ -f "$BD_INS/gh/ac/access_profiles.py" ] && [ -f "$BD_INS/gh/ac/leg_binding.py" ] && [ -f "$BD_INS/gh/ac/credential-env.tsv" ] && [ -x "$BD_IC" ]; } \
  && ok "install.sh lists and installs access_profiles.py, leg_binding.py and credential-env.tsv beside comms.sh" || fail "installed helpers missing: $(ls "$BD_INS/gh/ac" 2>&1 | tr '\n' ' ')"
OUT="$(bd "$BD_IC" review-route capability 2>&1)"
[ "$(sed -n 1p <<<"$OUT")" = "leg-binding-capability v1 leg-bindings=1 route-view=2 leg-metadata=1" ] && grep -q '^agent=codex class=bindable ' <<<"$OUT" \
  && ok "the INSTALLED copy answers review-route capability" || fail "installed capability: $OUT"
OUT="$(bd "$BD_IC" review-route plan --bindings "$BD/b3.json" 2>&1)"; A=$?
[ "$A" = 0 ] && [ "$OUT" = "$BD_PL_CODEX
$BD_PL_GEMINI
$BD_PL_GLM" ] && ok "the INSTALLED copy plans the same three legs identically (policy map and credential table installed beside it)" || fail "installed plan (rc=$A): $OUT"
bd_wb "$BD/inst-bad.json" "$(bj "$BD_L_CODEX" "d['access']['account']='nope'")"
OUT="$(bd "$BD_IC" panel dispatch --bindings "$BD/inst-bad.json" "$(bd_req)" 2>&1)"; A=$?
{ [ "$A" = 1 ] && grep -q '^refused codex account-mismatch' <<<"$OUT"; } && ok "the INSTALLED copy refuses a bound dispatch with the leg's code" || fail "installed refusal (rc=$A): $OUT"
OUT="$(bd "$BD_IC" agents --access gemini 2>&1)"; [ "$(sed -n 's/.*access_digest=//p' <<<"$OUT")" = "$BD_DG_GEMINI" ] && ok "the INSTALLED copy reads access.json: agents --access prints the same digest" || fail "installed agents --access: $OUT"

section "binding: contract tests (python: scrub set, environment, stamp, quota, auth-route read-back)"
BD_UNIT_RC=0
if git -C "$REPO" ls-files --error-unmatch tests/test_leg_binding.py >/dev/null 2>&1; then
  python3 "$REPO/tests/test_leg_binding.py" --report "$WORK/binding-report.json" > "$WORK/binding-unit.log" 2>&1 || BD_UNIT_RC=$?
fi
if python3 - "$WORK/binding-report.json" > "$WORK/binding-cases.tsv" <<'REPORT'
import json,sys
for case in json.load(open(sys.argv[1])):
    print(('pass' if case['passed'] else 'fail') + '\t' + case['name'])
REPORT
then
  BD_UNIT_FAILURES=0
  while IFS=$'\t' read -r status name; do
    if [ "$status" = pass ]; then ok "$name"
    else fail "$name"; BD_UNIT_FAILURES=$((BD_UNIT_FAILURES + 1)); fi
  done < "$WORK/binding-cases.tsv"
  if [ "$BD_UNIT_RC" -ne 0 ]; then
    cat "$WORK/binding-unit.log"
    [ "$BD_UNIT_FAILURES" -gt 0 ] || fail "binding unit runner aborted without a failed case"
  fi
else fail "binding case report missing or invalid"; cat "$WORK/binding-unit.log" 2>/dev/null; fi
