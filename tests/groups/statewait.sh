# Run through tests/run.sh; each group gets fresh fixtures.
section "runphase: the state-file wait is DECLARED by the spawner, never guessed"
# The runner may wait for the thread-state file that `send` writes just after it
# spawns us. It must wait ONLY when a send is actually behind it. A bare
# `comms.sh deliver` (a public verb) spawns a runner with no send following, so
# the file is never coming and a timed wait is pure latency — this was a flat 6s
# on EVERY such turn, invisible because every caller redirects the note to
# /dev/null. Measured at 179s (35%) of this suite's own runtime.
SW="$WORK/statewait"; mkdir -p "$SW"; SW="$(cd "$SW" && pwd -P)"
git -C "$SW" init -q -b feature/sw-tests
git -C "$SW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$SW/.comms/to-grok" "$SW/.comms/to-claude" "$SW/.comms/archive" "$SW/.comms/state"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$SW/.comms/config"
SW_WS="$(cd "$SW" && env "$COMMS" workspace)"
SW_MSG="$SW/.comms/to-grok/${SW_WS}_2026-08-27T10-00-00_sw-1.md"
cat > "$SW_MSG" <<SWEOF
---
type: review-request
from: claude
timestamp: 2026-08-27T10:00:00Z
workspace: $SW_WS
message_id: ${SW_WS}_2026-08-27T10-00-00_sw-1
thread: sw-arc-1
workflow: auto-full
phase: plan
round: 1
max-rounds: 4
---

## Plan
review this plan
SWEOF
SW_SF="$SW/.comms/state/$(echo "$SW_WS" | tr '/' '-')_sw-arc-1.json"
# A turn that refuses its arguments still runs the EXIT trap, which is the path
# that reaches update_thread_state — the cheapest way to exercise the wait.
sw_run() {  # sw_run <rundir> [env assignments...] -- refuses, exits nonzero
  local rd="$1"; shift
  mkdir -p "$rd"
  ( cd "$SW" && env PATH="$STUB_BIN:$PATH" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$@" \
      "COMMS_RUNPHASE_GROK_ARGS=--sandbox off" \
      "$RP" run --message "$SW_MSG" --dir "$rd" --provider grok ) 2>&1
}
sw_elapsed() {  # prints whole seconds elapsed while running "$@"
  local t0 t1; t0=$(date +%s); "$@" >/dev/null 2>&1; t1=$(date +%s); echo $((t1 - t0))
}
SW_BIN="$WORK/sw-bin"; mkdir -p "$SW_BIN"
# Records the env it was launched with, and optionally writes the thread-state file
# from INSIDE the turn. That is the late write, without a sleep to race: the provider
# runs after the runner started and before its exit trap, by construction.
cat > "$SW_BIN/grok" <<'SWSTUB'
#!/bin/bash
env > "${SW_ENV_DUMP:-/dev/null}"
if [ -n "${SW_LATE_STATE:-}" ]; then
  printf '{\n  "workspace": "sw",\n  "thread": "sw-arc-1",\n  "last_delivery": "spawned"\n}\n' > "$SW_LATE_STATE"
fi
exit 2
SWSTUB
chmod +x "$SW_BIN/grok"
sw_turn() {  # sw_turn <rundir> [env assignments...] — a turn that REACHES the provider
  local rd="$1"; shift
  mkdir -p "$rd"
  ( cd "$SW" && env PATH="$SW_BIN:$PATH" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$@" \
      "$RP" run --message "$SW_MSG" --dir "$rd" --provider grok ) 2>&1
}

# 1. No declaration -> no wait. This is the regression that mattered.
SW_E1="$(sw_elapsed sw_run "$WORK/sw-r1")"
[ "$SW_E1" -lt 3 ] && ok "unheralded spawn does not wait for a state file that is not coming (${SW_E1}s)" \
  || fail "unheralded spawn still waits (${SW_E1}s, expected <3)"
# NB: sw_run exits nonzero BY DESIGN (it refuses), and this suite sets pipefail,
# so `sw_run | grep -q ...` is decided by the refusal's status, not by grep —
# it fails when the note is present and "passes" when it is absent. Capture,
# then match.
SW_O1="$(sw_run "$WORK/sw-r1b" || true)"
case "$SW_O1" in
  *'no thread state file to update'*) ok "unheralded spawn still reports the missing state file" ;;
  *) fail "missing-state note lost" ;;
esac

# 2. Declared, file never arrives -> the budget is HONOURED, not ignored. A fix
#    that simply deleted the wait would pass test 1 and fail this one.
SW_E2="$(sw_elapsed sw_run "$WORK/sw-r2" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=1)"
[ "$SW_E2" -ge 1 ] && ok "declared spawn waits out its budget when the write never lands (${SW_E2}s)" \
  || fail "declared spawn skipped its budget (${SW_E2}s, expected >=1)"

# 3. Declared, file lands DURING the turn -> the race window still works, and the
#    state is actually MUTATED. Asserting only that the "missing file" note is absent
#    would pass on a turn that found the file and then failed to write it. The stub
#    creates the file from inside the turn, so there is no sleep to lose under load.
SW_O3="$(SW_LATE_STATE="$SW_SF" sw_turn "$WORK/sw-r3" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=4 || true)"
case "$SW_O3" in
  *'no thread state file to update'*) fail "state file written during the turn was missed — the race window regressed" ;;
  *) ok "declared spawn picks up a state file written after it started" ;;
esac
grep -q '"last_delivery": "failed"' "$SW_SF" 2>/dev/null \
  && ok "the picked-up state file is actually mutated, not merely found" \
  || fail "state file found but last_delivery not updated ($(cat "$SW_SF" 2>/dev/null | tr -d '\n'))"
rm -f "$SW_SF"

# 3a. The poll must WAKE EARLY. Test 2 already covers "the wait exists at all"; 3a's
#     unique job is narrower — that the wait is a POLL and not a flat `sleep $budget`.
#     Test 3's file already exists when the waiter starts, so nothing there touches
#     the polling. Here the file lands ~1s into a 10s budget: a non-polling
#     implementation takes 10s and fails the <6s bound, while the real one returns
#     in ~1s. The margin is deliberately wide because this suite is known to flake
#     under machine load, and a false failure here costs more than a loose bound.
#     If load delays the runner past the 1s write, this degrades to test 3 (file
#     already present) and still passes — it loses coverage, never invents failure.
#     (codex + grok, panel r2 flagged the gap; codex, r3 asked for the wider margin.)
( sleep 1; printf '{\n  "workspace": "sw",\n  "thread": "sw-arc-1",\n  "last_delivery": "spawned"\n}\n' > "$SW_SF" ) &
SW_MIDW=$!
SW_E3A="$(sw_elapsed sw_run "$WORK/sw-r3a" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=10)"
wait "$SW_MIDW" 2>/dev/null || true
[ "$SW_E3A" -lt 6 ] && ok "a file landing mid-wait wakes the poll early (${SW_E3A}s of a 10s budget)" \
  || fail "the wait did not wake early (${SW_E3A}s of a 10s budget — is it polling?)"
grep -q '"last_delivery": "failed"' "$SW_SF" 2>/dev/null \
  && ok "the mid-wait file is mutated too" || fail "mid-wait file not mutated"
rm -f "$SW_SF"

# 3b. The declaration is THIS turn's, and must not reach the provider child. A
#     reviewer turn that runs this suite would otherwise inherit it and every direct
#     runner call above would wait again — re-acquiring the stall, and only when the
#     suite runs inside a headless turn. (codex, panel r1, blocking.)
SW_ENV_DUMP="$WORK/sw-childenv.txt" sw_turn "$WORK/sw-r3b" COMMS_RUNPHASE_EXPECT_STATE=1 >/dev/null 2>&1 || true
if [ -s "$WORK/sw-childenv.txt" ]; then
  ok "provider child env was captured"
  # Gate on the dump: a MISSING dump makes grep fail, which would otherwise take
  # the "no leak" branch and report a pass for a test that never ran. (grok, r2.)
  if grep -q '^COMMS_RUNPHASE_EXPECT_STATE=' "$WORK/sw-childenv.txt"; then
    fail "the state declaration leaked into the provider child"
  else
    ok "the state declaration does not reach the provider child"
  fi
else
  fail "provider child env not captured"
  fail "leak check could not run (no env dump)"
fi

# 3c. A malformed budget must not abort the exit trap mid-teardown: it is
#     interpolated into arithmetic, where `abc` or `08` kills the shell before the
#     result write. (codex, panel r1, advisory.)
SW_O3C="$(sw_run "$WORK/sw-r3c" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=abc || true)"
case "$SW_O3C" in
  *'no thread state file to update'*) ok "a non-integer budget falls back instead of aborting teardown" ;;
  *) fail "non-integer budget aborted the exit trap (teardown output lost)" ;;
esac
# The diagnostic alone does not prove the trap RAN TO COMPLETION — result.json is
# written after it, and an arithmetic abort would lose exactly that. (codex, r2.)
grep -q '"status"' "$WORK/sw-r3c/result.json" 2>/dev/null \
  && ok "teardown still recorded a result after a malformed budget" \
  || fail "result.json missing or statusless after a malformed budget"
# An absurd budget must not wrap negative and silently skip the declared wait —
# nor stall the turn for hours. It is malformed input: fall back to the default.
SW_E3D="$(sw_elapsed sw_run "$WORK/sw-r3d" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=1844674407370955161)"
[ "$SW_E3D" -ge 3 ] && ok "an overflowing budget still waits, not wrapped into no wait (${SW_E3D}s)" \
  || fail "an overflowing budget skipped the declared wait entirely (${SW_E3D}s)"
[ "$SW_E3D" -le 20 ] && ok "an overflowing budget falls back rather than stalling for hours (${SW_E3D}s)" \
  || fail "an overflowing budget was clamped to something enormous (${SW_E3D}s)"

# 4. Anti-drift, as a SOURCE contract: the writer's rule and the spawner's
#    promise must be the same predicate, not two copies that agree today. If
#    they diverge, nothing fails loudly — the runner just stalls for its whole
#    budget again, silently, exactly as it did before this fix.
SWC="$REPO/helpers/comms.sh"
[ "$(grep -c '^state_write_expected()' "$SWC")" = 1 ] \
  && ok "state_write_expected is defined exactly once" || fail "state_write_expected definition count"
grep -q 'state_write_expected "$thread" "$wf" || return 0' "$SWC" \
  && ok "state_update_from gates its write on the shared predicate" || fail "writer bypasses the shared predicate"
grep -q 'if state_write_expected "$(frontmatter_field "$file" thread)" "$(frontmatter_field "$file" workflow)"; then' "$SWC" \
  && ok "cmd_send gates COMMS_RUNPHASE_EXPECT_STATE on the shared predicate" || fail "spawner bypasses the shared predicate"
[ "$(grep -c 'export COMMS_RUNPHASE_EXPECT_STATE=' "$SWC")" = 1 ] \
  && ok "exactly one site declares an expected state write" || fail "COMMS_RUNPHASE_EXPECT_STATE exported in more than one place"
[ "$(grep -c 'unset COMMS_RUNPHASE_EXPECT_STATE' "$SWC")" = 1 ] \
  && ok "exactly one site withdraws the declaration" || fail "declaration withdrawn in more than one place"
grep -q 'RP_EXPECT_STATE="\${COMMS_RUNPHASE_EXPECT_STATE:-}"' "$REPO/helpers/runphase.sh" \
  && ok "the runner captures the declaration before any child can inherit it" || fail "runner does not capture the declaration"
grep -q 'RP_EXPECT_STATE:-' "$REPO/helpers/runphase.sh" \
  && ok "the waiter reads the captured copy set-u safely" || fail "waiter does not read the captured copy safely"
grep -q 'unset COMMS_RUNPHASE_EXPECT_STATE' "$REPO/helpers/runphase.sh" \
  && ok "the runner clears the declaration before launching the provider" || fail "runner does not clear the declaration for the child"
grep -A1 '^unset COMMS_DELIVERY' "$REPO/tests/lib/harness.sh" | grep -q 'COMMS_RUNPHASE_EXPECT_STATE' \
  && ok "the harness scrubs an inherited declaration" || fail "harness no longer scrubs the inherited declaration"
