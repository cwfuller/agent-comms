# Run through tests/run.sh; no live API or developer profile is used.
section "profiles: parser, launch and evidence contracts"
PF_UNIT_RC=0
# Enumerate the index, not a possibly recreated untracked file.
if git -C "$REPO" ls-files --error-unmatch tests/test_agent_profiles.py >/dev/null 2>&1; then
  python3 "$REPO/tests/test_agent_profiles.py" --report "$WORK/profiles-report.json" > "$WORK/profiles-unit.log" 2>&1 || PF_UNIT_RC=$?
fi
if python3 - "$WORK/profiles-report.json" > "$WORK/profiles-cases.tsv" <<'REPORT'
import json,sys
for case in json.load(open(sys.argv[1])):
    print(('pass' if case['passed'] else 'fail') + '\t' + case['name'])
REPORT
then
  PF_UNIT_FAILURES=0
  while IFS=$'\t' read -r status name; do
    if [ "$status" = pass ]; then ok "$name"
    else fail "$name"; PF_UNIT_FAILURES=$((PF_UNIT_FAILURES + 1)); fi
  done < "$WORK/profiles-cases.tsv"
  if [ "$PF_UNIT_RC" -ne 0 ]; then
    cat "$WORK/profiles-unit.log"
    [ "$PF_UNIT_FAILURES" -gt 0 ] || fail "profile runner aborted without a failed case"
  fi
else fail "profile case report missing or invalid"; cat "$WORK/profiles-unit.log" 2>/dev/null; fi
section "profiles: registry and family integration"
PF_FIX="$WORK/profiles-repo"; mkdir -p "$PF_FIX/.comms"
git -C "$PF_FIX" init -q -b main
printf '.comms/\n' > "$PF_FIX/.gitignore"
git -C "$PF_FIX" add .gitignore
git -C "$PF_FIX" -c user.name=t -c user.email=t@t commit -qm init
python3 - "$AGENT_COMMS_HOME/agents.json" <<'PY'
import json,sys
profiles={n:dict(adapter='acp',command=[sys.executable],family=f,model=m) for n,f,m in [
    ('alpha','example','vendor/model-v1'),('beta','example','vendor/model-v2'),('delta','different','other/model')]}
json.dump({'version':1,'agents':profiles},open(sys.argv[1],'w'))
PY
printf 'agents = codex alpha beta delta\ndefault-target = alpha\n' > "$PF_FIX/.comms/config"
run_pf() { (cd "$PF_FIX" && COMMS_SELF=codex "$COMMS" "$@"); }
[ "$(run_pf agents)" = "codex alpha beta delta codex-review alpha-review beta-review delta-review" ] && ok "profiles add drivers and twins" || fail "profile registry"
[ "$(run_pf agents --provider alpha-review)" = alpha ] && [ "$(run_pf agents --family alpha-review)" = example ] && ok "execution profile and family are separate accessors" || fail "profile accessors"
[ "$(run_pf agents --others codex)" = "alpha,delta" ] && ok "default panel keeps one identity per family" || fail "family defaults"
check_not "roster rejects different model pins in one family" run_pf agents --roster codex alpha,beta
[ "$(run_pf agents --roster alpha alpha,delta)" = "alpha-review,delta" ] && ok "custom driver resolves to its own review twin" || fail "custom twin resolution"
[ "$(run_pf agents --others alpha)" = "codex,delta" ] && ok "other reviewers exclude all aliases of own family" || fail "own family exclusion"
PF_BINDING="$(run_pf agents --profile alpha)"
check "current profile binding passes execution guard" python3 "$REPO/helpers/agent_profiles.py" check-binding "$PF_BINDING" alpha
python3 - "$AGENT_COMMS_HOME/agents.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p));d['agents']['alpha']['model']='vendor/model-v3';json.dump(d,open(p,'w'))
PY
check_not "changed profile refuses outstanding execution" python3 "$REPO/helpers/agent_profiles.py" check-binding "$PF_BINDING" alpha
# A malformed global file must fail registry reads even when a built-in was requested.
printf '{"version":1,"agents":{},"agents":{}}' > "$AGENT_COMMS_HOME/agents.json"
check_not "malformed operator profiles fail closed" run_pf agents --provider codex
rm "$AGENT_COMMS_HOME/agents.json"
