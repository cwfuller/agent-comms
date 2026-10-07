# Fixtures for the exact-per-leg-binding groups (binding, bindrun). No live provider, account or network is used:
# every provider is a stub, every credential a canary string, and every home is test-owned. Sourced by each group
# and run once (`fixture_binding`), so the two groups share one definition and own separate repositories.
fixture_binding() {
fixture_agy   # acpx and agy stubs (AXB, AGB); fixture_acp underneath (gemini is no longer bindable: agy is run directly)
BD="$WORK/bind"; mkdir -p "$BD"
BD_AH="$BD/ah"; mkdir -p "$BD_AH"                    # the operator's agent-comms home: agents.json, access.json
BD_HOME="$BD/home"; mkdir -p "$BD_HOME/.acpx/sessions" "$BD_HOME/.acpx/queues" "$BD_HOME/.codex"
: > "$BD_HOME/.acpx-test-store"                        # the stubs write session records only into a store the suite marked
BD_MBASE="$BD/mbase"; mkdir -p "$BD_MBASE"; BD_MBASE="$(cd "$BD_MBASE" && pwd -P)"
BD_REPO="$BD/repo"; mkdir -p "$BD_REPO"; BD_REPO="$(cd "$BD_REPO" && pwd -P)"
git -C "$BD_REPO" init -q -b main
printf '.comms/\n' > "$BD_REPO/.gitignore"; echo subject > "$BD_REPO/s.txt"
git -C "$BD_REPO" add .gitignore s.txt
git -C "$BD_REPO" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$BD_REPO/.comms"
printf 'agents = claude codex grok gemini glm glm2 glmx gacp\ndefault-target = codex\n' > "$BD_REPO/.comms/config"
# THE REVIEWERS' CANARIES. Every credential below is a recognisable string; each assertion about what reaches a
# provider process looks for exactly these.
BD_KEY_VENICE="canary-venice-key-0002"; BD_KEY_CODEXM="canary-codex-metered-0003"
BD_KEY_OTHER="canary-unconfigured-pattern-0004"; BD_KEY_TABLE="canary-table-listed-0005"; BD_KEY_PLAIN="canary-configured-plain-0006"
# A saved ChatGPT login for codex: observable by presence and mode, never printed.
printf '{"auth_mode":"chatgpt","tokens":{"id_token":"canary-codex-login-0007"}}\n' > "$BD_HOME/.codex/auth.json"
# A stand-in OpenCode runtime for the custom (Venice-style) profiles: it reports the pinned version, records
# the environment it was launched with, and exits.
BD_OC="$BD/opencode"
cat > "$BD_OC" <<'OCSTUB'
#!/bin/sh
case "$1" in
  --version) echo 1.18.32; exit 0 ;;
  acp) if [ -n "${OC_ENV_LOG:-}" ]; then for v in ${OC_ENV_VARS:-}; do printf '%s=%s\n' "$v" "$(printenv "$v" 2>/dev/null || printf '<unset>')" >> "$OC_ENV_LOG"; done; fi; exit 0 ;;
esac
exit 0
OCSTUB
chmod +x "$BD_OC"

# ---- the operator's files, rewritten from a base by a mutation, so each case names only what it changes ----
cat > "$BD/access.base.json" <<'JSON'
{"version": 1, "agents": {
  "codex":  {"route_id": "codex-subscription", "transport": "acp", "provider": "openai", "account": "primary", "billing": "subscription", "credential": null},
  "glm":    {"route_id": "venice-api", "transport": "acp", "provider": "venice", "account": "primary", "billing": "api", "credential": "env:BD_VENICE_KEY"},
  "glm2":   {"route_id": "venice-api", "transport": "acp", "provider": "venice", "account": "primary", "billing": "api", "credential": "env:BD_VENICE_KEY"},
  "glmx":   {"route_id": "venice-other", "transport": "acp", "provider": "venice", "account": "other", "billing": "api", "credential": "env:BD_VENICE_OTHER_KEY"}}}
JSON
python3 - "$BD/agents.base.json" "$BD_OC" <<'PY'
import json,sys
def oc(model, family, env):
    return dict(adapter='opencode', command=[sys.argv[2]], runtime_version='1.18.32', model=model, family=family,
                api_provider='venice', credentials={'VENICE_API_KEY': {'env': env}},
                connection=dict(base_url='https://venice.example.invalid/api/v1', api_key_env='VENICE_API_KEY', context=1000, output=100))
agents = {'glm': oc('venice/glm-model-a', 'glm', 'BD_VENICE_KEY'),
          'glm2': oc('venice/glm-model-b', 'glm-b', 'BD_VENICE_KEY'),
          'glmx': oc('venice/glm-model-a', 'glm', 'BD_VENICE_OTHER_KEY'),
          'gacp': dict(adapter='acp', command=[sys.executable], family='generic', model='vendor/generic-model',
                       credentials={'API_KEY': {'env': 'MY_INFERENCE_KEY'}})}
json.dump({'version': 1, 'agents': agents}, open(sys.argv[1], 'w'))
PY
bd_mut() {  # <access|agents> <python statements on d> — rewrite the operator's file from its base, mutated
  python3 - "$BD/$1.base.json" "$BD_AH/$([ "$1" = access ] && echo access.json || echo agents.json)" "$2" <<'PY'
import json,sys
d = json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(d, open(sys.argv[2], 'w'))
PY
  chmod 600 "$BD_AH/access.json" "$BD_AH/agents.json" 2>/dev/null || true
}
bd_reset() { bd_mut access 'pass'; bd_mut agents 'pass'; }
bd_reset

# Run comms.sh (or any command) in the binding repo with hermetic homes and the acp transport: a bound leg
# is a mounted ACP turn, so a mailbox or headless delivery is unbindable by definition. Leading NAME=value
# words are extra environment.
bd() { (cd "$BD_REPO" && env AGENT_COMMS_HOME="$BD_AH" HOME="$BD_HOME" CODEX_HOME="$BD_HOME/.codex" \
          COMMS_DELIVERY=acp COMMS_SELF=claude COMMS_MOUNT_BASE="$BD_MBASE" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
          COMMS_RUNPHASE_OWNER_WAIT_SECS=3 PATH="$AGB:$AXB:$PATH" \
          BD_VENICE_KEY="$BD_KEY_VENICE" BD_VENICE_OTHER_KEY="$BD_KEY_VENICE" "$@"); }
bj() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(d))' "$1" "$2"; }   # edit a leg's JSON
bd_wb() {  # <file> <leg-json>... — a leg-bindings file
  python3 - "$1" "${@:2}" <<'PY'
import json,sys
json.dump({"schema": "leg-bindings/1", "legs": [json.loads(a) for a in sys.argv[2:]]}, open(sys.argv[1], "w"))
PY
}
BD_L_CODEX='{"ref":"res-codex","agent":"codex","role":"gate","requirement":"required","route_id":"codex-subscription","model":"gpt-6-luna","effort":"low","access":{"transport":"acp","provider":"openai","account":"primary","billing":"subscription","credential":null}}'
BD_L_GLM='{"ref":"res-glm","agent":"glm","role":"extra","requirement":"optional","route_id":"venice-api","model":"venice/glm-model-a","effort":null,"access":{"transport":"acp","provider":"venice","account":"primary","billing":"api","credential":"env:BD_VENICE_KEY"}}'
# A second OpenCode profile on the same route: the "extra, optional" API leg of the multi-leg cases (gemini cannot be one:
# it runs agy directly and a bound leg runs mounted over ACP only).
BD_L_GLM2='{"ref":"res-glm2","agent":"glm2","role":"extra","requirement":"optional","route_id":"venice-api","model":"venice/glm-model-b","effort":null,"access":{"transport":"acp","provider":"venice","account":"primary","billing":"api","credential":"env:BD_VENICE_KEY"}}'
# gemini, bound anyway: refused as unbindable whatever it is bound to.
BD_L_GEMINI='{"ref":"res-gemini","agent":"gemini","role":"extra","requirement":"optional","route_id":"gemini-api","model":"gemini-3.1-pro","effort":"high","access":{"transport":"acp","provider":"google","account":"metered","billing":"api","credential":"env:BD_GEMINI_KEY"}}'
# The whole repository, contents, refs and mailbox included: any file, event, index row or snapshot ref a verb
# creates, removes or rewrites shows here.
bd_tree() { ( cd "$BD_REPO" && { find . -path ./.git -prune -o -print | LC_ALL=C sort; find . -path ./.git -prune -o -type f -exec shasum {} + | LC_ALL=C sort
    git for-each-ref; git status --porcelain; } ); }
bd_codes() { sed -n 's/^refused [a-z0-9-]* \([a-z-]*\) .*/\1/p' <<<"$1" | LC_ALL=C sort | tr '\n' ' '; }   # the refusal codes on stderr
BD_REQ_N=0
BD_REQ_FROM=claude
bd_req() {  # [thread] -> path of a fresh review-request authored by $BD_REQ_FROM (claude)
  BD_REQ_N=$((BD_REQ_N + 1)); local thr="${1:-bd-thread-$BD_REQ_N}" f="$BD_REPO/.comms/bd-request-$BD_REQ_N.md"
  cat > "$f" <<REQ
---
type: review-request
from: $BD_REQ_FROM
timestamp: 2026-10-03T10:00:00Z
head_sha: $(git -C "$BD_REPO" rev-parse HEAD)
workspace: $(basename "$BD_REPO")
message_id: bd-req-$BD_REQ_N
thread: $thr
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## What was done
binding fixture
REQ
  printf '%s' "$f"
}
bd_res() {  # <agent> <key...> — one value from the newest result.json written for <agent>; <null> when absent
  local f
  f="$(grep -l "\"agent\": \"$1\"" $(find "$BD_REPO/.comms/logs" -name result.json 2>/dev/null) 2>/dev/null | xargs ls -t 2>/dev/null | head -1)"
  [ -n "$f" ] || { echo "<norun>"; return; }
  shift
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2:]: d=d.get(k) if isinstance(d,dict) else None
print("<null>" if d is None else (json.dumps(d,sort_keys=True,separators=(",",":")) if isinstance(d,(dict,list)) else d))' "$f" "$@" 2>/dev/null || echo "<unreadable>"
}
bd_run_dirs() { find "$BD_REPO/.comms/logs" -name result.json 2>/dev/null | wc -l | tr -d ' '; }
BD_MAPV="$(awk -F'\t' '$1=="version"{print $2; exit}' "$REPO/helpers/policy-map.tsv")"
bd_dig() { bd "$COMMS" agents --access "$1" | sed -n 's/.* access_digest=//p'; }
BD_DG_CODEX="$(bd_dig codex)"; BD_DG_GLM="$(bd_dig glm)"; BD_DG_GLM2="$(bd_dig glm2)"
BD_PL_CODEX="route-plan v2 ref=res-codex agent=codex harness=codex status=ok code=- route_id=codex-subscription transport=acp provider=openai account=primary billing=subscription credential=- access_digest=$BD_DG_CODEX model=gpt-6-luna effort=low model_source=bound effort_source=bound capability=eligible limit_id=- routing=off decision=none phase=- map_version=$BD_MAPV capability_version=1"
BD_PL_GLM2="$(sed 's/ref=res-glm agent=glm harness=glm /ref=res-glm2 agent=glm2 harness=glm2 /; s/model=venice\/glm-model-a/model=venice\/glm-model-b/' <<<"$BD_PL_GLM")"
BD_PL_GLM="route-plan v2 ref=res-glm agent=glm harness=glm status=ok code=- route_id=venice-api transport=acp provider=venice account=primary billing=api credential=env:BD_VENICE_KEY access_digest=$BD_DG_GLM model=venice/glm-model-a effort=- model_source=bound effort_source=bound capability=profile limit_id=n/a routing=off decision=none phase=- map_version=$BD_MAPV capability_version=1"
bd_wb "$BD/b3.json" "$BD_L_CODEX" "$BD_L_GLM2" "$BD_L_GLM"
BD_T0="$(bd_tree)"
BD_TL="$BD/test-legs.log"; rm -f "$BD_TL"
}
