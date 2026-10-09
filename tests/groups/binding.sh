# Run through tests/run.sh; each group gets fresh fixtures. The static half of the exact-per-leg-binding
# contract: access profiles, the capability line, plan and dispatch refusals, record compatibility, the installed copy.
. "$REPO/tests/lib/binding.sh"
fixture_binding

section "binding: access profiles (access.json), agents --access and the capability line"
BD_D_CODEX="$(python3 -c 'import hashlib,json; e={"route_id":"codex-subscription","transport":"acp","provider":"openai","account":"primary","billing":"subscription","credential":None}; print(hashlib.sha256(json.dumps(e,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
OUT="$(bd "$COMMS" agents --access codex 2>&1)"
[ "$OUT" = "access v1 agent=codex route_id=codex-subscription transport=acp provider=openai account=primary billing=subscription credential=- access_digest=$BD_D_CODEX" ] \
  && ok "agents --access prints the agent's one access entry and the sha256 of its canonical form" || fail "agents --access codex: $OUT"
OUT="$(bd "$COMMS" agents --access glm2 2>&1)"
case "$OUT" in *"credential=env:BD_VENICE_KEY "*) ok "an api entry names its credential REFERENCE" ;; *) fail "agents --access glm2: $OUT" ;; esac
case "$OUT" in *"$BD_KEY_VENICE"*) fail "agents --access printed a credential VALUE" ;; *) ok "agents --access never prints, and never needs, the credential value" ;; esac
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
bd_bad "a value-shaped credential" "d['agents']['glm2']['credential']='sk-live-0123456789abcdef'" "never a value"
bd_bad "an api route with no credential reference" "d['agents']['glm2']['credential']=None" "exactly one credential"
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
  && [ "$(cap_line glm)" = "agent=glm class=bindable-model-only harness=glm reason=- billing=api" ] \
  && ok "codex is bindable (model and effort); an OpenCode profile is bindable-model-only" || fail "capability classes: $(grep '^agent=' <<<"$OUT" | tr '\n' '|')"
[ "$(cap_line claude)" = "agent=claude class=bindable harness=claude reason=- billing=-" ] \
  && [ "$(cap_line claude-review)" = "agent=claude-review class=bindable harness=claude reason=- billing=-" ] \
  && ok "claude and its review twin are bindable (model and native effort, on the mounted ACP runner); with no access entry their billing is -" || fail "claude capability: $(grep '^agent=claude' <<<"$OUT" | tr '\n' '|')"
[ "$(cap_line grok)" = "agent=grok class=unbindable harness=grok reason=grok-unsupported billing=-" ] \
  && [ "$(cap_line gemini)" = "agent=gemini class=unbindable harness=gemini reason=gemini-unsupported billing=-" ] \
  && [ "$(cap_line gacp)" = "agent=gacp class=unbindable harness=gacp reason=consult-only billing=-" ] \
  && ok "grok (no applied, attested policy), gemini (agy runs directly, no ACP session) and a generic ACP profile (consult-only) are unbindable, with the reason" || fail "capability unbindables: $(grep '^agent=' <<<"$OUT" | tr '\n' '|')"
# WITH THE OPERATOR'S ENTRY (key `claude`, which the twin inherits): billing is the entry's, the versions and the
# class vocabulary are unchanged, in the text and the JSON form alike.
bd_claude_on
OUT6="$(bd "$COMMS" review-route capability 2>&1)"; OUT7="$(bd "$COMMS" review-route capability --json 2>&1)"
[ "$(grep '^agent=claude' <<<"$OUT6")" = "agent=claude class=bindable harness=claude reason=- billing=subscription
agent=claude-review class=bindable harness=claude reason=- billing=subscription" ] && [ "$(sed -n 1p <<<"$OUT6")" = "leg-binding-capability v1 leg-bindings=1 route-view=2 leg-metadata=1" ] \
  && ok "with the operator's claude entry, claude and claude-review are bindable with billing subscription" || fail "claude capability with an entry: $OUT6"
[ "$(python3 -c '
import json,sys
d=json.loads(sys.argv[1]); rows={a["agent"]: a for a in d["agents"]}
print(d["capability_version"], d["leg_bindings"], d["route_view"], d["leg_metadata"],
      [(rows[a]["class"], rows[a]["reason"], rows[a]["billing"]) for a in ("claude", "claude-review")],
      {a["class"] for a in d["agents"]} <= {"bindable", "bindable-model-only", "unbindable", "unbindable-billing"})' "$OUT7")" = "1 1 2 1 [('bindable', None, 'subscription'), ('bindable', None, 'subscription')] True" ] \
  && ok "capability --json says the same, with versions 1 1 2 1 and no class outside the closed vocabulary" || fail "claude capability --json: $OUT7"
bd_reset
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
$BD_PL_GLM2
$BD_PL_GLM" ] \
  && ok "plan prints one route-plan v2 line per leg: codex (gpt-6-luna/low) and two OpenCode/Venice profiles (their pinned models, no effort), in file order" \
  || fail "bound plan (rc=$A): $OUT $(cat "$BD/plan.err")"
OUT2="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" 2>&1)"
[ "$OUT2" = "$OUT" ] && ok "a repeated plan is byte-identical" || fail "plan output drifted between runs"
[ "$(bd_tree)" = "$BD_T0" ] && ok "a bound plan writes nothing: no file, event, decision, index row or snapshot ref" || fail "plan wrote to the repository"
case "$OUT$(cat "$BD/plan.err")" in *"$BD_KEY_VENICE"*|*canary-*) fail "plan output carries a credential value" ;; *) ok "plan output carries credential REFERENCES only, never a value" ;; esac
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" --to codex,glm2,glm 2>&1)"; A=$?
[ "$A" = 0 ] && ok "--to is accepted when it names exactly the bindings file's agents, in order" || fail "plan with equal --to (rc=$A)"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" --to glm2,codex,glm 2>&1)"; A=$?
[ "$A" = 2 ] && ok "--to in a different order is a usage error: the file decides the roster" || fail "reordered --to accepted (rc=$A)"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/b3.json" --phase implement 2>&1)"; A=$?
[ "$A" = 2 ] && ok "a bound plan takes no routed-plan flags (--phase, --thread)" || fail "bound plan accepted --phase (rc=$A)"

# THE LEGACY PLAN IS UNCHANGED, byte for byte: all-or-nothing, route-plan v1, no access fields.
OUT="$(bd "$COMMS" review-route plan --to codex,grok 2>&1)"; A=$?
case "$OUT" in "route-plan v1 agent=codex provider=codex transport=acp-mounted capability=eligible model=gpt-6.1-sol effort=high limit_id=- model_source=baseline effort_source=baseline routing=off decision=none phase=implement map_version=$BD_MAPV
route-plan v1 agent=grok provider=grok "*) [ "$A" = 0 ] && ok "the legacy plan still prints route-plan v1 lines with no access fields" || fail "legacy plan rc=$A" ;; *) fail "legacy plan changed: $OUT" ;; esac

# EVERY LEG'S VERDICT IS PRINTED, and a refusal is exit 1: Basis needs each candidate's answer to choose among them.
bd_wb "$BD/bmix.json" "$BD_L_CODEX" "$(bj "$BD_L_GLM2" "d['access']['account']='someone-else'")" "$BD_L_GLM"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/bmix.json" 2>"$BD/mix.err")"; A=$?
{ [ "$A" = 1 ] && [ "$(sed -n 1p <<<"$OUT")" = "$BD_PL_CODEX" ] && [ "$(sed -n 3p <<<"$OUT")" = "$BD_PL_GLM" ] \
  && [ "$(sed -n 2p <<<"$OUT" | sed 's/ access_digest=[0-9a-f]* / access_digest=D /')" = "$(sed 's/ access_digest=[0-9a-f]* / access_digest=D /; s/ status=ok code=- / status=refused code=account-mismatch /' <<<"$BD_PL_GLM2")" ]; } \
  && ok "a plan with one refusing leg still prints all three verdicts (the refused leg shows the CONFIGURED account) and exits 1" || fail "mixed plan (rc=$A): $OUT"
bd_wb "$BD/blit.json" "$(bj "$BD_L_GLM2" "d['access']['credential']='canary-literal-sk-0123456789'")"
OUT="$(bd "$COMMS" review-route plan --bindings "$BD/blit.json" 2>&1)"; A=$?
{ [ "$A" = 1 ] && case "$OUT" in *canary-literal*) false ;; *code=credential-mismatch*) true ;; *) false ;; esac; } \
  && ok "a plan refuses a literal key supplied as the expected credential, naming the code and never the value" || fail "plan echoed or missed a literal credential (rc=$A): $OUT"
grep -q '^refused glm2 account-mismatch expected someone-else, configured primary' "$BD/mix.err" \
  && ok "the refusal names both sides: what was expected and what is configured" || fail "refusal detail: $(cat "$BD/mix.err")"
[ "$(bd_tree)" = "$BD_T0" ] && ok "a refusing plan writes nothing either" || fail "refusing plan wrote to the repository"

section "binding: all-or-nothing validation before the first durable write (panel dispatch --bindings)"
# ONE LEG, ONE DEFECT, each through the real dispatch: the whole dispatch is refused with the leg's stable code, and the
# repository — mailbox, coordinator log, index, snapshot refs, working tree — is byte-identical afterwards.
bd_refuse() {  # <label> <expected codes, sorted, space-terminated> <leg-json> [env assignments...]
  local label="$1" want="$2" leg="$3"; shift 3
  bd_wb "$BD/one.json" "$leg"
  local req err="$BD/one.err"; req="$(bd_req)"
  OUT="$(bd AX_CWD_LOG="$BD_TL" "$@" "$COMMS" panel dispatch --bindings "$BD/one.json" "$req" 2>"$err")"; A=$?
  { [ "$A" = 1 ] && [ "$(bd_codes "$(cat "$err")")" = "$want" ] && [ -z "$OUT" ] && [ "$(bd_tree | grep -v 'bd-request-')" = "$(grep -v 'bd-request-' <<<"$BD_T0")" ]; } \
    && ok "refused: $label ($want)" || fail "refusal: $label (rc=$A, codes '$(bd_codes "$(cat "$err")")', want '$want'; out: $OUT; $(head -c 300 "$err"))"
}
bd_refuse "a wrong route id" "route-mismatch " "$(bj "$BD_L_CODEX" "d['route_id']='codex-metered'")"
bd_refuse "a wrong transport" "transport-mismatch " "$(bj "$BD_L_CODEX" "d['access']['transport']='cli'")"
bd_refuse "a wrong hosting provider" "provider-mismatch " "$(bj "$BD_L_CODEX" "d['access']['provider']='anthropic'")"
bd_refuse "a wrong account" "account-mismatch " "$(bj "$BD_L_CODEX" "d['access']['account']='secondary'")"
bd_refuse "a wrong billing class" "billing-mismatch " "$(bj "$BD_L_CODEX" "d['access']['billing']='api'")"
bd_refuse "an API credential expected where the agent is on a subscription" "credential-mismatch " "$(bj "$BD_L_CODEX" "d['access']['credential']='env:BD_KEY_CODEXM_REF'")"
bd_refuse "no credential expected where the agent is on an API route" "credential-mismatch " "$(bj "$BD_L_GLM2" "d['access']['credential']=None")"
bd_refuse "a different credential reference" "credential-mismatch " "$(bj "$BD_L_GLM2" "d['access']['credential']='env:BD_VENICE_OTHER_KEY'")"
# A LITERAL SECRET PASTED WHERE A REFERENCE BELONGS is refused and never echoed: not on stderr, not on stdout.
bd_refuse "a literal key where a credential reference belongs" "credential-mismatch " "$(bj "$BD_L_GLM2" "d['access']['credential']='canary-literal-sk-0123456789'")"
case "$(cat "$BD/one.err")" in *canary-literal*) fail "dispatch refusal echoed a literal credential" ;; *) ok "a dispatch refusal never echoes a literal credential supplied as the expected reference" ;; esac
bd_refuse "an incomplete access object (no account)" "access-incomplete " "$(bj "$BD_L_CODEX" "del d['access']['account']")"
bd_refuse "no access object at all" "access-incomplete " "$(bj "$BD_L_CODEX" "del d['access']")"
bd_refuse "several defects at once: every code is collected, not only the first" "account-mismatch billing-mismatch route-mismatch " "$(bj "$BD_L_CODEX" "d['route_id']='x'; d['access'].update(account='y', billing='free')")"
BD_REQ_FROM=codex   # claude cannot be both the author and a leg
bd_refuse "claude with no access entry, bound to a model the map cannot attest for it" "model-unservable no-access-profile " "$(bj "$BD_L_CODEX" "d.update(agent='claude', ref='res-claude')")"
# A BOUND CLAUDE LEG with the operator's entry: the resolution's codes and the login read-back, each before any write.
bd_claude_on
bd_refuse "claude: a launch id with no pair or recorded row (an alias the map cannot attest)" "model-unservable " "$(bj "$BD_L_CLAUDE" "d['model']='haiku'")"
bd_refuse "claude: a null effort for a model with an effort scale" "effort-mismatch " "$(bj "$BD_L_CLAUDE" "d['effort']=None")"
bd_refuse "claude: an effort outside the model's list" "effort-refused " "$(bj "$BD_L_CLAUDE" "d['effort']='ultra'")"
bd_refuse "claude: COMMS_REVIEW_MAX in the dispatching environment" "pin-conflict " "$BD_L_CLAUDE" COMMS_REVIEW_MAX=1
bd_claude_login "$BD_HOME/.claude" console
bd_refuse "claude: a login that is not a claude.ai first-party subscription" "auth-selected-type-conflict " "$BD_L_CLAUDE"
bd_claude_login "$BD_HOME/.claude" none
bd_refuse "claude: no login in the leg's config directory" "auth-login-missing " "$BD_L_CLAUDE"
bd_claude_login "$BD_HOME/.claude" subscription
bd_claude_on "d['agents']['claude'].update(billing='api', credential='env:BD_CL_KEY')"
bd_refuse "claude: an api route, which has no explicit, readable selection" "auth-route-unsupported " "$(bj "$BD_L_CLAUDE" "d['access'].update(billing='api', credential='env:BD_CL_KEY')")" BD_CL_KEY=canary-claude-api-0024
bd_reset
BD_REQ_FROM=claude
bd_refuse "grok (no applied, attested policy; no access entry)" "agent-unbindable no-access-profile " "$(bj "$BD_L_CODEX" "d.update(agent='grok', ref='res-grok')")"
bd_refuse "a generic ACP profile (consult-only)" "agent-unbindable no-access-profile " "$(bj "$BD_L_GLM" "d.update(agent='gacp', ref='res-gacp')")"
bd_refuse "gemini (agy runs directly with no ACP session, so nothing mounted over ACP can bind it; no access entry)" "agent-unbindable no-access-profile " "$BD_L_GEMINI"
bd_refuse "a mailbox leg (nobody drives it)" "agent-unbindable " "$BD_L_CODEX" COMMS_DELIVERY=mailbox
printf '#!/bin/sh\necho "codex-cli 0.154.0"\n' > "$BD/old-codex"; chmod +x "$BD/old-codex"
bd_refuse "a model newer than the reviewer runtime" "model-unservable " "$(bj "$BD_L_CODEX" "d.update(model='gpt-6-sol', effort='high')")" COMMS_ACP_CODEX_PATH="$BD/old-codex"
bd_refuse "an effort outside the model's accepted set" "effort-refused " "$(bj "$BD_L_CODEX" "d['effort']='ultra'")"
bd_refuse "a null effort on a model with a native scale" "effort-mismatch " "$(bj "$BD_L_CODEX" "d['effort']=None")"
bd_refuse "an effort on a pinned-model profile that has no scale" "effort-mismatch " "$(bj "$BD_L_GLM" "d['effort']='high'")"
bd_refuse "a model the profile does not pin" "model-mismatch " "$(bj "$BD_L_GLM" "d['model']='venice/some-other-model'")"
bd_refuse "an environment model pin that differs from the binding" "pin-conflict " "$BD_L_CODEX" COMMS_ACP_CODEX_MODEL=gpt-6.1-sol
bd_refuse "an environment effort pin that differs from the binding" "pin-conflict " "$BD_L_CODEX" COMMS_ACP_CODEX_EFFORT=high
bd_refuse "COMMS_REVIEW_MAX (use max) in the dispatching environment" "pin-conflict " "$BD_L_CODEX" COMMS_REVIEW_MAX=1
bd_refuse "an API credential that is not present" "credential-unavailable " "$BD_L_GLM2" BD_VENICE_KEY=
# THE CONFIGURED TRANSPORT IS CHECKED AGAINST THE ONE THE RUNNER WOULD DRIVE: a `cli` entry the caller also expects as `cli`
# matches field for field, and would be stamped into a leg this runner reaches over ACP.
bd_mut access "d['agents']['codex']['transport']='cli'"
bd_refuse "a configured AND expected transport of cli for an agent the runner drives over ACP" "transport-mismatch " "$(bj "$BD_L_CODEX" "d['access']['transport']='cli'")"
bd_reset
# THE CUSTOM RUNTIME IS VERIFIED LOCALLY BEFORE ANYTHING IS WRITTEN: a declared version is a claim, and an executable that
# cannot run (or runs as another version) would otherwise fail only after its siblings had started.
printf '#!/bin/sh\nexit 1\n' > "$BD/oc-bad"; chmod +x "$BD/oc-bad"
bd_mut agents "d['agents']['glm']['command']=['$BD/oc-bad']"
bd_refuse "a custom runtime that exits non-zero though its profile declares the pinned version" "model-unservable " "$BD_L_GLM"
bd_wb "$BD/badrt.json" "$BD_L_CODEX" "$BD_L_GLM2" "$BD_L_GLM"
OUT="$(bd COMMS_WAIT=1 AX_CWD_LOG="$BD_TL" "$COMMS" panel dispatch --bindings "$BD/badrt.json" "$(bd_req bd-badrt)" 2>"$BD/badrt.err")"; A=$?
{ [ "$A" = 1 ] && [ -z "$OUT" ] && [ "$(bd_codes "$(cat "$BD/badrt.err")")" = "model-unservable " ] \
  && [ "$(bd_tree | grep -v 'bd-request-')" = "$(grep -v 'bd-request-' <<<"$BD_T0")" ] && [ ! -e "$BD_TL" ]; } \
  && ok "a three-leg dispatch whose LAST (custom) leg's runtime cannot run is refused whole: no snapshot, event, leg file or provider launch" || fail "bad custom runtime panel (rc=$A): $OUT $(head -c 300 "$BD/badrt.err")"
bd_reset
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
bd_reset

# NO PARTIAL PANEL. Two good legs and a bad third: nothing was snapshotted, logged, indexed or sent, and no provider
# stub was ever invoked.
bd_wb "$BD/partial.json" "$BD_L_CODEX" "$BD_L_GLM2" "$(bj "$BD_L_GLM" "d['access']['account']='nope'")"
PN_REQ="$(bd_req bd-partial)"
OUT="$(bd COMMS_WAIT=1 AX_CWD_LOG="$BD_TL" "$COMMS" panel dispatch --bindings "$BD/partial.json" "$PN_REQ" 2>"$BD/partial.err")"; A=$?
{ [ "$A" = 1 ] && [ -z "$OUT" ] && [ "$(bd_codes "$(cat "$BD/partial.err")")" = "account-mismatch " ]; } \
  && ok "a three-leg dispatch whose last leg is bad is refused as a whole, naming the bad leg" || fail "partial panel (rc=$A): $OUT $(cat "$BD/partial.err")"
[ "$(bd_tree | grep -v 'bd-request-')" = "$(grep -v 'bd-request-' <<<"$BD_T0")" ] \
  && ok "it left no snapshot ref, event, index row, attempts marker, leg file or run directory (directory comparison)" || fail "a refused panel wrote: $(diff <(grep -v 'bd-request-' <<<"$BD_T0") <(bd_tree | grep -v 'bd-request-') | head -6 | tr '\n' ' ')"
[ ! -e "$BD_TL" ] && [ "$(bd_run_dirs)" = 0 ] && ok "and no provider stub (acpx, agy) was invoked for any of the three legs" || fail "a stub ran: $(cat "$BD_TL" 2>/dev/null | head -3)"
[ -z "$(git -C "$BD_REPO" for-each-ref refs/agent-comms)" ] && [ ! -e "$BD_REPO/.comms/events.tsv" ] \
  && ok "the artifact was never retained and the coordinator log was never created" || fail "snapshot refs or an event log exist after a refusal"
# A final OpenCode leg whose connection reads a variable its credential mapping never supplies would pass every
# other check, then fail at launch after the siblings started: it is judged before anything is written.
bd_mut agents "d['agents']['glm']['credentials']={'UNUSED_KEY': {'env': 'BD_VENICE_KEY'}}"
bd_wb "$BD/conn.json" "$BD_L_CODEX" "$BD_L_GLM2" "$BD_L_GLM"
OUT="$(bd COMMS_WAIT=1 AX_CWD_LOG="$BD_TL" "$COMMS" panel dispatch --bindings "$BD/conn.json" "$(bd_req bd-conn)" 2>"$BD/conn.err")"; A=$?
{ [ "$A" = 1 ] && [ -z "$OUT" ] && [ "$(bd_codes "$(cat "$BD/conn.err")")" = "capability-unsupported " ] && [ ! -e "$BD_TL" ] && [ "$(bd_run_dirs)" = 0 ] \
  && [ "$(bd_tree | grep -v 'bd-request-')" = "$(grep -v 'bd-request-' <<<"$BD_T0")" ]; } \
  && ok "a final OpenCode leg whose connection key variable its credential mapping does not supply refuses the whole panel before any write" || fail "connection key (rc=$A): $OUT $(cat "$BD/conn.err")"
bd_mut agents "d['agents']['glm']['credentials']={}"
bd_mut access "d['agents']['glm'].update(route_id='venice-local', billing='local', credential=None)"
bd_wb "$BD/local.json" "$BD_L_CODEX" "$BD_L_GLM2" "$(bj "$BD_L_GLM" "d['route_id']='venice-local'; d['access'].update(billing='local', credential=None)")"
OUT="$(bd COMMS_WAIT=1 AX_CWD_LOG="$BD_TL" "$COMMS" panel dispatch --bindings "$BD/local.json" "$(bd_req bd-local)" 2>"$BD/local.err")"; A=$?
{ [ "$A" = 1 ] && [ -z "$OUT" ] && [ "$(bd_codes "$(cat "$BD/local.err")")" = "capability-unsupported " ] && [ ! -e "$BD_TL" ] && [ "$(bd_run_dirs)" = 0 ]; } \
  && ok "a final OpenCode leg with a connection and no credential mapping (a local route) refuses the whole panel before any write" || fail "local connection (rc=$A): $OUT $(cat "$BD/local.err")"
bd_reset
# An OPTIONAL leg failing validation refuses the dispatch too: which legs exist is the caller's decision, so this
# tool never drops one.
bd_wb "$BD/opt.json" "$BD_L_CODEX" "$(bj "$BD_L_GLM2" "d['model']='venice/some-other-model'")"
OUT="$(bd "$COMMS" panel dispatch --bindings "$BD/opt.json" "$(bd_req)" 2>&1)"; A=$?
{ [ "$A" = 1 ] && grep -q '^refused glm2 model-mismatch' <<<"$OUT" && [ "$(bd_run_dirs)" = 0 ]; } \
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
bda() { (cd "$BD_REPO" && env AGENT_COMMS_HOME="$BD_AH" HOME="$BD_HOME" PATH="$AGB:$AXB:$PATH" "$@"); }
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
OUT="$(bda "$AP" resolve grok --transport acp-mounted --bound-model x --bound-effort high --route-id r --access-digest "$BD_DG_CODEX" 2>&1)"
grep -q 'code=capability-unsupported' <<<"$OUT" \
  && ok "a bound resolution for grok (no applied policy) is still refused as capability-unsupported" || fail "grok bound resolve: $OUT"
# CLAUDE RESOLVES BOUND: version 2, capability bound, the transcript's model id beside the launch id, and a policy
# digest over the pair, the pinned adapter and its version, and the access digest.
bda "$AP" resolve claude --transport acp-mounted --bound-model claude-opus-5-5 --bound-effort low --route-id kernel-claude --access-digest "$BD_DG_CODEX" > "$BD/cl.rec" 2>"$BD/cl.err"; A=$?
BD_CL_DG="$(printf 'claude-opus-5-5\0low\0@agentclientprotocol/claude-agent-acp\0%s\0%s' "$(sed -n 's/^CLAUDE_ACP_VERSION="\(.*\)"$/\1/p' "$AP")" "$BD_DG_CODEX" | shasum -a 256 | cut -c1-12)"
{ [ "$A" = 0 ] && [ "$(awk -F'\t' '$1~/^(policy_record|capability|model|effort|verify|attest_model|runtime|runtime_version|pair)$/{printf "%s=%s ", $1, $2}' "$BD/cl.rec")" = "policy_record=2 capability=bound model=claude-opus-5-5 effort=low pair=validated runtime=@agentclientprotocol/claude-agent-acp runtime_version=0.88.0 verify=model,effort attest_model=claude-opus-5-5 " ] \
  && [ "$(awk -F'\t' '$1=="policy_digest"{print $2}' "$BD/cl.rec")" = "$BD_CL_DG" ] && [ "$(awk -F'\t' '{print $1}' "$BD/cl.rec" | tail -3 | tr '\n' ' ')" = "route_id access_digest bound " ] \
  && [ "$(bda "$AP" resolve claude --transport acp-mounted --bound-model sonnet --bound-effort high --route-id kernel-claude --access-digest "$BD_DG_CODEX" 2>/dev/null | awk -F'\t' '$1~/^(model|attest_model)$/{printf "%s=%s ", $1, $2}')" = "model=sonnet attest_model=claude-sonnet-5-5 " ]; } \
  && ok "acp.sh resolve claude --bound-* resolves: capability bound, attest_model (an alias keeps its launch id beside the id its transcript records), the pinned adapter as the runtime, and a digest that covers the adapter version" || fail "claude bound resolve (rc=$A): $(cat "$BD/cl.err") $(tr '\t\n' '= ' < "$BD/cl.rec")"
[ "$(bda "$AP" resolve claude 2>/dev/null | awk -F'\t' '$1~/^(policy_record|capability|verify|fallback|runtime)$/{printf "%s=%s ", $1, $2}')" = "policy_record=1 capability=unsupported runtime=n/a fallback=capability-unsupported verify=none " ] \
  && [ -z "$(bda "$AP" adapter claude)" ] && [ "$(bda "$AP" adapter claude --bound)" = "npx -y @agentclientprotocol/claude-agent-acp@0.88.0" ] \
  && ok "an UNBOUND claude resolution is unchanged (version 1, unsupported), and only a bound leg gets the pinned adapter" || fail "unbound claude: $(bda "$AP" resolve claude 2>&1 | tr '\t\n' '= ')"
[ "$(bda "$AP" claude-env --policy-file "$BD/cl.rec")" = "CLAUDE_CODE_EFFORT_LEVEL	low" ] \
  && ok "acp.sh claude-env names the one variable the runner injects, with the record's effort" || fail "claude-env: $(bda "$AP" claude-env --policy-file "$BD/cl.rec" 2>&1)"
# THE PREFLIGHT reads what acpx re-applies: the saved model preference and the effort option (acp.sh policy_check_claude).
bd_pc() {  # <effort option|''> <saved model|''> <saved effort|''> [record] -> the claude preflight's exit status
  python3 -c '
import json,sys
e,m,d=sys.argv[1:4]
ax={"config_options":[{"id":"model","currentValue":"opus"}]+([{"id":"effort","currentValue":e}] if e else [])}
if m: ax["session_options"]={"model":m}
if d: ax["desired_config_options"]={"effort":d}
print(json.dumps({"acpx":ax}))' "$1" "$2" "$3" | bda "$AP" policy-check claude - --policy-file "${4:-$BD/cl.rec}" >/dev/null 2>&1; echo $?
}
[ "$(bd_pc low claude-opus-5-5 low) $(bd_pc low sonnet low) $(bd_pc high claude-opus-5-5 low) $(bd_pc low claude-opus-5-5 high) $(bd_pc '' claude-opus-5-5 low) $(bd_pc low '' low)" = "0 20 20 20 23 20" ] \
  && ok "the claude preflight passes only the bound saved model and effort; a missing effort option is 23 (effort-mismatch)" || fail "claude preflight codes: $(bd_pc low claude-opus-5-5 low) $(bd_pc low sonnet low) $(bd_pc high claude-opus-5-5 low) $(bd_pc low claude-opus-5-5 high) $(bd_pc '' claude-opus-5-5 low) $(bd_pc low '' low)"
[ "$(bda "$AP" policy-attest claude low claude-opus-5-5 --policy-file "$BD/cl.rec" >/dev/null 2>&1; echo $?) $(bda "$AP" policy-attest claude null claude-opus-5-5 --policy-file "$BD/cl.rec" >/dev/null 2>&1; echo $?) $(bda "$AP" policy-attest claude low claude-sonnet-5-5 --policy-file "$BD/cl.rec" >/dev/null 2>&1; echo $?) $(bda "$AP" policy-attest claude low claude-opus-5-5 --policy-file "$BD/v2.rec" >/dev/null 2>&1; echo $?)" = "0 21 20 21" ] \
  && ok "the claude verdict compares the transcript's pair with attest_model and the effort; no effort is undecidable, never a pass" || fail "claude attest verdicts"
# A MODEL WITH NO EFFORT SCALE (`pair ... none`): a copy of acp.sh beside a map that declares one.
BD_PM="$BD/pm-none"; mkdir -p "$BD_PM"; cp "$AP" "$BD_PM/acp.sh"; chmod +x "$BD_PM/acp.sh"
{ cat "$REPO/helpers/policy-map.tsv"; printf 'pair\tclaude\tacp-mounted\ttest-haiku\tnone\nrecorded\tclaude\tacp-mounted\ttest-haiku\tclaude-test-haiku\n'; } > "$BD_PM/policy-map.tsv"
bda "$BD_PM/acp.sh" resolve claude --transport acp-mounted --bound-model test-haiku --bound-effort - --route-id kernel-claude --access-digest "$BD_DG_CODEX" > "$BD/cl0.rec" 2>/dev/null; A=$?
OUT="$(bda "$BD_PM/acp.sh" resolve claude --transport acp-mounted --bound-model test-haiku --bound-effort low --route-id kernel-claude --access-digest "$BD_DG_CODEX" 2>&1)"
{ [ "$A" = 0 ] && [ "$(awk -F'\t' '$1~/^(effort|verify|attest_model|effective_effort)$/{printf "%s=%s ", $1, $2}' "$BD/cl0.rec")" = "effort=n/a effective_effort=n/a verify=model attest_model=claude-test-haiku " ] \
  && grep -q 'code=effort-mismatch' <<<"$OUT" && [ -z "$(bda "$BD_PM/acp.sh" claude-env --policy-file "$BD/cl0.rec")" ]; } \
  && ok "an effortless model binds only with a null effort (verify model, no injection); any effort for it is effort-mismatch" || fail "effortless resolve (rc=$A): $OUT"
[ "$(bda "$BD_PM/acp.sh" policy-attest claude null claude-test-haiku --policy-file "$BD/cl0.rec" >/dev/null 2>&1; echo $?) $(bda "$BD_PM/acp.sh" policy-attest claude low claude-test-haiku --policy-file "$BD/cl0.rec" >/dev/null 2>&1; echo $?) $(bd_pc '' test-haiku '' "$BD/cl0.rec") $(bd_pc default test-haiku '' "$BD/cl0.rec")" = "0 20 0 23" ] \
  && ok "an effortless model is attested on the model alone (an observed effort is a mismatch) and its session must offer no effort option" || fail "effortless verdicts"
for BD_BADROW in 'pair\tclaude\tacp-mounted\tm-x\tnone,low' 'recorded\tclaude\tacp-mounted\tm-x' 'capability\tclaude\tacp-x\tboundish\tm\te\tv\tn'; do
  { cat "$REPO/helpers/policy-map.tsv"; printf "$BD_BADROW\n"; } > "$BD_PM/policy-map.tsv"
  bda "$BD_PM/acp.sh" capabilities >/dev/null 2>&1 && fail "a malformed map row was accepted: $BD_BADROW" || ok "the policy map refuses a malformed row: $(printf "$BD_BADROW" | tr '\t' ' ')"
done
# A map row cannot make an unbound claude turn claim a policy: only `bound` counts for claude/acp-mounted.
{ grep -v '^capability	claude	acp-mounted	' "$REPO/helpers/policy-map.tsv"; printf 'capability\tclaude\tacp-mounted\tfixed\tm\te\tv\tn\nbaseline\tclaude\tacp-mounted\tclaude-opus-5-5\thigh\n'; } > "$BD_PM/policy-map.tsv"
OUT="$(bda "$BD_PM/acp.sh" resolve claude --transport acp-mounted --bound-model claude-opus-5-5 --bound-effort low --route-id kernel-claude --access-digest "$BD_DG_CODEX" 2>&1)"
grep -q 'code=capability-unsupported' <<<"$OUT" && [ "$(bda "$BD_PM/acp.sh" resolve claude 2>/dev/null | awk -F'\t' '$1=="fallback"{print $2}')" = "capability-unimplemented;capability-unsupported" ] \
  && ok "a claude row marked fixed is downgraded for unbound and bound resolutions alike (claude applies a bound pair only)" || fail "claude fixed row: $OUT"

# CUSTOM PROFILES bind through their pinned model, and through no map row.
bda "$AP" resolve glm --transport acp-mounted --bound-model venice/glm-model-a --bound-effort - --route-id venice-api --access-digest "$BD_DG_GLM" --custom-profile > "$BD/glm.rec" 2>"$BD/glm.err"; A=$?
{ [ "$A" = 0 ] && grep -q '^capability	profile$' "$BD/glm.rec" && grep -q '^model	venice/glm-model-a$' "$BD/glm.rec" && grep -q '^effort	n/a$' "$BD/glm.rec" && grep -q '^verify	model$' "$BD/glm.rec" && grep -q '^model_source	bound$' "$BD/glm.rec" && ! grep -q 'glm' "$REPO/helpers/policy-map.tsv"; } \
  && ok "an OpenCode profile resolves bound to its pinned model with no effort, and the policy map has no row for it" || fail "custom bound resolve (rc=$A): $(cat "$BD/glm.err")"
[ "$(bda "$AP" resolve glm 2>/dev/null | awk -F'\t' '$1=="capability"{print $2} $1=="policy_record"{print $2}' | tr '\n' ' ')" = "1 unsupported " ] \
  && ok "the same profile resolved UNBOUND is still unsupported at version 1, as before" || fail "unbound custom resolve changed"
OUT="$(bda "$AP" resolve gacp --transport acp-mounted --bound-model vendor/generic-model --bound-effort - --route-id r --access-digest "$BD_DG_GLM" --custom-profile 2>&1)"
grep -q 'code=agent-unbindable consult-only' <<<"$OUT" \
  && ok "a generic ACP profile is refused as consult-only: it has no mounted review runner" || fail "generic ACP bound resolve"

section "binding: a bound claude leg's launch-time read-back (scrub set, the runner's own injection, user settings, login)"
# THE SCRUB SET gains claude's credential-bearing names no pattern matches, and its model and effort selectors; the
# leg's config directory is NOT in it (the leg runs on its own CLAUDE_CONFIG_DIR's login).
OUT="$(bd python3 "$REPO/helpers/access_profiles.py" scrub-set 2>&1)"; BD_MISS=""
for BD_N in ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_IDENTITY_TOKEN_FILE CLAUDE_SESSION_INGRESS_TOKEN_FILE CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR \
            CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR CLAUDE_CODE_HOST_AUTH_ENV_VAR CLAUDE_CODE_CLIENT_CERT \
            CLAUDE_CODE_CLIENT_KEY CLAUDE_CODE_CLIENT_KEY_PASSPHRASE CLAUDE_CODE_CUSTOM_OAUTH_URL CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_MANAGED_SETTINGS_PATH \
            ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL CLAUDE_EFFORT; do
  grep -qx "$BD_N" <<<"$OUT" || BD_MISS="$BD_MISS $BD_N"
done
[ -z "$BD_MISS" ] && ! grep -qx CLAUDE_CONFIG_DIR <<<"$OUT" \
  && ok "access_profiles.py scrub-set lists claude's header, file, descriptor, mTLS and OAuth-endpoint credentials and its model/effort selectors, never CLAUDE_CONFIG_DIR" || fail "scrub set missing:$BD_MISS"
OUT="$(bd ANTHROPIC_DEFAULT_SONNET_MODEL=x CLAUDE_LOCAL_OAUTH_API_BASE=x CLAUDE_BG_AUTH_SNAPSHOT_PATH=x CLAUDE_CONFIG_DIR="$BD/none" python3 "$REPO/helpers/access_profiles.py" env-plan claude claude subscription 2>&1)"
{ grep -qx 'unset	ANTHROPIC_DEFAULT_SONNET_MODEL' <<<"$OUT" && grep -qx 'unset	CLAUDE_LOCAL_OAUTH_API_BASE' <<<"$OUT" && grep -qx 'unset	CLAUDE_BG_AUTH_SNAPSHOT_PATH' <<<"$OUT" \
  && ! grep -q 'CLAUDE_CONFIG_DIR' <<<"$OUT" && ! grep -q '^credential' <<<"$OUT"; } \
  && ok "a claude subscription leg's environment plan strips the prefixed alias, OAuth-endpoint and background-auth names, keeps CLAUDE_CONFIG_DIR and restores no credential" || fail "claude env plan: $OUT"
# THE GUARD, called directly in an exact environment (env -i), as the runner calls it inside the leg's acpx environment.
BD_GD="$BD/guard"; mkdir -p "$BD_GD/home/.claude"; bd_claude_login "$BD_GD/home/.claude" subscription
bd_guard() {  # <record> [NAME=value...] -> the guard's one line (`observed`, or `mismatch<TAB>detail`)
  local rec="$1"; shift
  (cd "$BD_REPO" && env -i PATH="$BD_CB:$PATH" HOME="$BD_GD/home" AGENT_COMMS_HOME="$BD_AH" "$@" \
     python3 "$REPO/helpers/leg_binding.py" auth-readback --adapter claude --billing subscription --policy-file "$rec" 2>&1)
}
[ "$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low)" = observed ] \
  && ok "the guard passes the leg whose only scrubbed name is the runner's own effort, holding the record's value, on a subscription login" || fail "guard control: $(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low)"
BD_G1="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low "ANTHROPIC_CUSTOM_HEADERS=Authorization: Bearer canary-hdr-0031")"
BD_G2="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low ZZ_SERVICE_API_KEY=canary-pattern-0033)"
{ [ "${BD_G1%%	*}" = mismatch ] && grep -q ANTHROPIC_CUSTOM_HEADERS <<<"$BD_G1" && [ "${BD_G2%%	*}" = mismatch ] && grep -q ZZ_SERVICE_API_KEY <<<"$BD_G2" \
  && ! grep -q canary <<<"$BD_G1$BD_G2"; } \
  && ok "the guard refuses a surviving header credential and a pattern-shaped one, naming the variable and never its value" || fail "guard credentials: $BD_G1 / $BD_G2"
BD_G3="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=max)"; BD_G4="$(bd_guard "$BD/cl.rec")"
sed -e 's/^verify	model,effort$/verify	model/' -e 's/^effort	low$/effort	n\/a/' "$BD/cl.rec" > "$BD/cl-noeffort.rec"
BD_G5="$(bd_guard "$BD/cl-noeffort.rec" CLAUDE_CODE_EFFORT_LEVEL=low)"; BD_G6="$(bd_guard "$BD/cl-noeffort.rec")"
{ [ "${BD_G3%%	*}" = mismatch ] && [ "${BD_G4%%	*}" = mismatch ] && [ "${BD_G5%%	*}" = mismatch ] && [ "$BD_G6" = observed ]; } \
  && ok "the runner's own effort must hold exactly the record's value: another value, a missing one, or one present for an effortless record refuses" || fail "guard injection: $BD_G3 / $BD_G4 / $BD_G5 / $BD_G6"
printf '{"effortLevel":"high","env":{"BD_HARMLESS_SETTING":"1"}}\n' > "$BD_GD/home/.claude/settings.json"; BD_G7="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low)"
printf '{"env":{"BD_HARMLESS_SETTING":"1","ANTHROPIC_CUSTOM_HEADERS":"Authorization: Bearer canary-hdr-0034"}}\n' > "$BD_GD/home/.claude/settings.json"; BD_G8="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low)"
printf '{"apiKeyHelper":"/bin/echo canary-helper-0035"}\n' > "$BD_GD/home/.claude/settings.json"; BD_G9="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low)"
rm -f "$BD_GD/home/.claude/settings.json"
{ [ "$BD_G7" = observed ] && [ "${BD_G8%%	*}" = mismatch ] && grep -q ANTHROPIC_CUSTOM_HEADERS <<<"$BD_G8" && [ "${BD_G9%%	*}" = mismatch ] && grep -q apiKeyHelper <<<"$BD_G9" \
  && ! grep -q canary <<<"$BD_G8$BD_G9"; } \
  && ok "the guard reads the user settings' key names: an env block naming a scrubbed variable, or an apiKeyHelper, refuses; unrelated names pass" || fail "guard settings: $BD_G7 / $BD_G8 / $BD_G9"
mkdir -p "$BD_GD/ccd"; bd_claude_login "$BD_GD/ccd" console
BD_G10="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low CLAUDE_CONFIG_DIR="$BD_GD/ccd")"
bd_claude_login "$BD_GD/ccd" subscription; bd_claude_login "$BD_GD/home/.claude" none
BD_G11="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low CLAUDE_CONFIG_DIR="$BD_GD/ccd")"; BD_G12="$(bd_guard "$BD/cl.rec" CLAUDE_CODE_EFFORT_LEVEL=low)"
{ [ "${BD_G10%%	*}" = mismatch ] && grep -q 'authMethod=console' <<<"$BD_G10" && [ "$BD_G11" = observed ] && [ "${BD_G12%%	*}" = mismatch ] \
  && ! grep -q canary <<<"$BD_G10$BD_G11$BD_G12"; } \
  && ok "the login is read back from the leg's own config directory (CLAUDE_CONFIG_DIR set, or HOME's), keeping only its three route fields" || fail "guard login: $BD_G10 / $BD_G11 / $BD_G12"

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
$BD_PL_GLM2
$BD_PL_GLM" ] && ok "the INSTALLED copy plans the same three legs identically (policy map and credential table installed beside it)" || fail "installed plan (rc=$A): $OUT"
bd_wb "$BD/inst-bad.json" "$(bj "$BD_L_CODEX" "d['access']['account']='nope'")"
OUT="$(bd "$BD_IC" panel dispatch --bindings "$BD/inst-bad.json" "$(bd_req)" 2>&1)"; A=$?
{ [ "$A" = 1 ] && grep -q '^refused codex account-mismatch' <<<"$OUT"; } && ok "the INSTALLED copy refuses a bound dispatch with the leg's code" || fail "installed refusal (rc=$A): $OUT"
OUT="$(bd "$BD_IC" agents --access glm2 2>&1)"; [ "$(sed -n 's/.*access_digest=//p' <<<"$OUT")" = "$BD_DG_GLM2" ] && ok "the INSTALLED copy reads access.json: agents --access prints the same digest" || fail "installed agents --access: $OUT"

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
