# Run through tests/run.sh; each group gets fresh fixtures.
section "presence & worktrees: advisory coordination (plan presence-worktrees-15135)"
# Self-contained section (maintainability track: pre-split, local fixtures).
PW="$WORK/presence-repo"; mkdir -p "$PW"; PW="$(cd "$PW" && pwd -P)"
git -C "$PW" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$PW/.gitignore"
echo base > "$PW/a.txt"
printf '#!/bin/bash\ntest -f a.txt\n' > "$PW/suite.sh"; chmod +x "$PW/suite.sh"
git -C "$PW" add -A >/dev/null 2>&1
git -C "$PW" -c user.email=t@t -c user.name=t commit -qm init
mkdir -p "$PW/.comms"; printf 'suite-cmd = bash ./suite.sh\n' > "$PW/.comms/config"
run_pw() { (cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 "$COMMS" "$@"); }
PW_SD="$PW/.comms/sessions"

# Claim-then-check + exit contract (AC1).
PW_C1="$(run_pw presence claim --name alpha --role "first driver")"; PW_R1=$?
[ "$PW_R1" = 0 ] && ok "first claim on an empty field is direct-safe (exit 0)" || fail "first claim rc=$PW_R1"
PW_I1="$(printf '%s' "$PW_C1" | sed -n 's/.*instance: //p')"
[ -f "$PW_SD/alpha-$PW_I1.json" ] && ok "claim records BEFORE evaluating (file exists)" || fail "claim did not record"
PW_C2="$(run_pw presence claim --name beta --role "second")"; PW_R2=$?
[ "$PW_R2" = 3 ] && printf '%s' "$PW_C2" | grep -q 'peer: alpha' \
  && ok "a live peer forces isolation (exit 3, peer listed)" || fail "second claim rc=$PW_R2"
PW_I2="$(printf '%s' "$PW_C2" | sed -n 's/.*instance: //p')"

# Same-name lifecycle (AC4, plan r4): same-name B is a PEER to A, and B's release
# cannot touch A.
PW_C3="$(run_pw presence claim --name alpha --role "same-name interloper")"; PW_R3=$?
[ "$PW_R3" = 3 ] && ok "a same-name second session isolates (per-instance files)" || fail "same-name claim rc=$PW_R3"
PW_I3="$(printf '%s' "$PW_C3" | sed -n 's/.*instance: //p')"
run_pw presence release --name alpha --instance "$PW_I3"
[ -f "$PW_SD/alpha-$PW_I1.json" ] && ok "release deletes exactly self — A survives B's release" || fail "release crossed instances"
run_pw presence release --name beta --instance "$PW_I2"

# Heal restores presence, not tenure (AC1, plan r9).
rm -f "$PW_SD/alpha-$PW_I1.json"
run_pw presence beat --name alpha --instance "$PW_I1" --role "first driver" >/dev/null 2>&1; PW_RH=$?
[ "$PW_RH" = 5 ] && [ -f "$PW_SD/alpha-$PW_I1.json" ] \
  && ok "a beat that heals a vanished record exits 5 (re-check required)" || fail "heal rc=$PW_RH"

# Fail-closed reading (AC2): corrupt record and foreign host are peers; stale+live
# pid is LIVE (suspend rule); stale+dead pid is confidently dead.
printf 'not json' > "$PW_SD/corrupt-ffffffffffffffffffffffffffffffff.json"
run_pw presence others --name alpha --instance "$PW_I1" >/dev/null 2>&1; PW_RC=$?
[ "$PW_RC" = 3 ] && ok "a corrupt record reads as a peer (fail closed)" || fail "corrupt not a peer (rc=$PW_RC)"
rm -f "$PW_SD/corrupt-ffffffffffffffffffffffffffffffff.json"
printf '{\n  "name": "far", "instance": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "state": "working", "host": "another-machine", "pid": "1", "pid_started": "x", "last_heartbeat_epoch": "1"\n}\n' > "$PW_SD/far-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.json"
run_pw presence others --name alpha --instance "$PW_I1" >/dev/null 2>&1; PW_RF=$?
[ "$PW_RF" = 3 ] && ok "a foreign-host record is ambiguous, never dead" || fail "foreign host not a peer"
run_pw presence expire >/dev/null 2>&1; run_pw presence expire >/dev/null 2>&1
[ -f "$PW_SD/far-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.json" ] \
  && ok "expire never reaps a foreign-host record" || fail "foreign host reaped"
# --force is EXACT-name (codex, impl r5: `--force alpha` glob-matched
# `alpha-team-*` and erased an unrelated live session's records and covers).
printf '{\n  "name": "far-team", "instance": "e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2", "state": "working", "host": "%s", "last_heartbeat_epoch": "%s"\n}\n' "$(hostname)" "$(date +%s)" > "$PW_SD/far-team-e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2.json"
mkdir -p "$PW_SD/.reap"
printf '#obs 1\nx\n' > "$PW_SD/.reap/far-team-e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2.obs"
printf '#tomb 1\n' > "$PW_SD/.reap/far-team-e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2.tomb.beefbeef"
run_pw presence expire --force far >/dev/null 2>&1
[ ! -f "$PW_SD/far-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.json" ] \
  && ok "expire --force is the explicit operator path" || fail "force did not remove"
[ -f "$PW_SD/far-team-e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2.json" ] \
  && [ -f "$PW_SD/.reap/far-team-e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2.obs" ] \
  && [ -f "$PW_SD/.reap/far-team-e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2.tomb.beefbeef" ] \
  && ok "--force far leaves far-team's records AND covers untouched (exact-name match)" || fail "force over-matched a hyphenated sibling"
rm -f "$PW_SD/far-team-e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2.json" "$PW_SD/.reap/far-team"-* 2>/dev/null
PW_MYPID=$$
PW_MYSTART="$(ps -p $PW_MYPID -o lstart= 2>/dev/null)"
printf '{\n  "name": "napper", "instance": "dddddddddddddddddddddddddddddddd", "state": "working", "host": "%s", "pid": "%s", "pid_started": "%s", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" "$PW_MYPID" "$PW_MYSTART" > "$PW_SD/napper-dddddddddddddddddddddddddddddddd.json"
PW_NAPO="$(run_pw presence others --name alpha --instance "$PW_I1" || true)"
printf '%s\n' "$PW_NAPO" | grep -q 'napper.*live' \
  && ok "stale heartbeat + live matching pid = LIVE (suspend, not death)" || fail "suspend read as death"
rm -f "$PW_SD/napper-dddddddddddddddddddddddddddddddd.json"

# Two-pass reap + TOCTOU forcing (AC1/AC2, plan r7-r10): observation → BEAT → pass 2
# must not reap; unchanged-dead bytes must reap with a nonce tombstone cover.
printf '{\n  "name": "ghost", "instance": "cccccccccccccccccccccccccccccccc", "state": "working", "host": "%s", "pid": "99999999", "pid_started": "gone", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" > "$PW_SD/ghost-cccccccccccccccccccccccccccccccc.json"
run_pw presence expire >/dev/null 2>&1
PW_OBS="$PW_SD/.reap/ghost-cccccccccccccccccccccccccccccccc.obs"
[ -f "$PW_OBS" ] && [ -f "$PW_SD/ghost-cccccccccccccccccccccccccccccccc.json" ] \
  && ok "pass one observes and touches nothing" || fail "pass one misbehaved"
perl -pi -e 's/^#obs \d+/"#obs " . (time()-99999)/e' "$PW_OBS"
run_pw presence beat --name ghost --instance cccccccccccccccccccccccccccccccc >/dev/null 2>&1  # the racing beat
run_pw presence expire >/dev/null 2>&1
[ -f "$PW_SD/ghost-cccccccccccccccccccccccccccccccc.json" ] \
  && ok "a beat between passes ABORTS the reap (byte-identity, TOCTOU forced)" || fail "reaped a beaten record"
run_pw presence release --name ghost --instance cccccccccccccccccccccccccccccccc
printf '{\n  "name": "ghost2", "instance": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "state": "working", "host": "%s", "pid": "99999999", "pid_started": "gone", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" > "$PW_SD/ghost2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json"
run_pw presence expire >/dev/null 2>&1
perl -pi -e 's/^#obs \d+/"#obs " . (time()-99999)/e' "$PW_SD/.reap/ghost2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.obs"
run_pw presence expire >/dev/null 2>&1
[ ! -f "$PW_SD/ghost2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json" ] \
  && ls "$PW_SD/.reap/"ghost2-*.tomb.* >/dev/null 2>&1 \
  && ok "unchanged dead bytes reap after the grace, leaving a nonce tombstone" || fail "clean reap failed"
PW_COVO="$(run_pw presence others --name alpha --instance "$PW_I1" || true)"
printf '%s\n' "$PW_COVO" | grep -q 'ghost2.*reaped-cover' \
  && ok "a young tombstone with no record reads as a peer (cover)" || fail "cover not a peer"
PW_TOMB="$(ls "$PW_SD/.reap/"ghost2-*.tomb.* | head -1)"
run_pw presence expire >/dev/null 2>&1
[ -f "$PW_TOMB" ] && ok "cover GC never fires young (1(a) only)" || fail "young cover deleted"
printf '{\n  "name": "ghost2", "instance": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "state": "working", "host": "%s", "last_heartbeat_epoch": "%s"\n}\n' "$(hostname)" "$(date +%s)" > "$PW_SD/ghost2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json"
perl -pi -e 's/^#tomb \d+/"#tomb 1"/e' "$PW_TOMB"
run_pw presence expire >/dev/null 2>&1
[ -f "$PW_TOMB" ] && ok "a cover is NEVER deleted because a record exists" || fail "cover GC'd beside a live record"
run_pw presence release --name ghost2 --instance bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run_pw presence expire >/dev/null 2>&1
[ ! -f "$PW_TOMB" ] && ok "an old recordless cover is GC'd (old AND no record)" || fail "old cover survived"

# The liveness handle, and reaping AT CLAIM (2026-09-03). Every record this repo
# accumulated was pid-less, and a pid-less record can NEVER evaluate dead — so
# `expire` had nothing to collect and, being a verb nobody invoked, ran never.
# Both halves are needed: a pid makes death provable, and claim is what runs the
# collector. Own field, so exit statuses here are not perturbed by the block above.
PWQ="$WORK/presence-pid"; mkdir -p "$PWQ"; PWQ="$(cd "$PWQ" && pwd -P)"
git -C "$PWQ" init -q -b main; git -C "$PWQ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$PWQ/.comms"
run_pwq() { (cd "$PWQ" && env COMMS_PRESENCE_TTL_SECS=60 "$COMMS" "$@"); }
# <harness-pid> <args...> — claim with the environment a real agent session has.
claim_pwq() { local hp="$1"; shift; (cd "$PWQ" && env CLAUDE_PID="$hp" COMMS_PRESENCE_TTL_SECS=60 "$COMMS" "$@"); }
PWQ_SD="$PWQ/.comms/sessions"
PWQ_INST() { printf '%s' "$1" | sed -n 's/.*instance: //p'; }

# A pid VERIFIED ABSENT right now, floored so a pathological ps that answers for every
# argument fails the fixture loudly instead of spinning forever. (grok, implement r2.)
PWQ_GONE=99999990
while [ "$PWQ_GONE" -gt 99990000 ] && ps -p "$PWQ_GONE" -o pid= >/dev/null 2>&1; do PWQ_GONE=$((PWQ_GONE-1)); done
PWQ_A="$(PWQ_INST "$(claim_pwq $$ presence claim --name harness --role r 2>/dev/null)")"
grep -q "\"pid\": \"$$\"" "$PWQ_SD/harness-$PWQ_A.json" \
  && ok "claim adopts the harness session pid when no --pid is given" || fail "harness pid not adopted"
run_pwq presence release --name harness --instance "$PWQ_A" >/dev/null 2>&1
PWQ_B="$(PWQ_INST "$(claim_pwq $$ presence claim --name explicitpid --role r --pid 99999999 2>/dev/null)")"
grep -q '"pid": "99999999"' "$PWQ_SD/explicitpid-$PWQ_B.json" \
  && ok "an explicit --pid beats the harness environment" || fail "--pid did not win"
rm -f "$PWQ_SD/explicitpid-$PWQ_B.json"
# A pid that cannot be VERIFIED is worse than none: a record naming a process that
# does not exist evaluates `dead` at once, so the next reap would collect a LIVE
# session's own claim. Both unverifiable shapes must fall back to pid-less.
PWQ_C="$(PWQ_INST "$(claim_pwq 'not-a-number' presence claim --name badpid --role r 2>/dev/null)")"
[ -n "$PWQ_C" ] && grep -q '"pid": ""' "$PWQ_SD/badpid-$PWQ_C.json" \
  && ok "a non-numeric harness pid is ignored, and the claim still succeeds" || fail "non-numeric harness pid not ignored"
run_pwq presence release --name badpid --instance "$PWQ_C" >/dev/null 2>&1
PWQ_D="$(PWQ_INST "$(claim_pwq "$PWQ_GONE" presence claim --name gonepid --role r 2>/dev/null)")"
[ -n "$PWQ_D" ] && grep -q '"pid": ""' "$PWQ_SD/gonepid-$PWQ_D.json" \
  && ok "a harness pid naming no live process is ignored (never self-condemn)" || fail "unverified harness pid was recorded"
run_pwq presence release --name gonepid --instance "$PWQ_D" >/dev/null 2>&1

# Reap AT CLAIM, two-pass by construction: the first claim to see a dead record may
# only OBSERVE it. Nothing a claim has not already watched for a full TTL can vanish,
# so a merely suspended or mid-write session is never collected.
PWQ_DEAD="$PWQ_GONE"
printf '{\n  "name": "departed", "instance": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "state": "working", "host": "%s", "pid": "%s", "pid_started": "gone", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" "$PWQ_DEAD" > "$PWQ_SD/departed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"
printf '{\n  "name": "nohandle", "instance": "abababababababababababababababab", "state": "working", "host": "%s", "pid": "", "pid_started": "", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" > "$PWQ_SD/nohandle-abababababababababababababababab.json"
PWQ_O1="$(run_pwq presence claim --name w1 --role r 2>/dev/null)"
[ -f "$PWQ_SD/departed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json" ] \
  && [ -f "$PWQ_SD/.reap/departed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.obs" ] \
  && ok "the first claim to see a dead record only OBSERVES it" || fail "claim reaped on first sight"
PWQ_LEAK="$(printf '%s\n' "$PWQ_O1" | grep -vE '^(claimed|peer):' | grep -c . || true)"
[ -n "$PWQ_O1" ] && [ "$PWQ_LEAK" = 0 ] \
  && ok "claim stdout stays the claimed:/peer: contract (reap output is stderr)" \
  || fail "the reap leaked $PWQ_LEAK non-contract line(s) onto claim stdout"
run_pwq presence release --name w1 --instance "$(PWQ_INST "$PWQ_O1")" >/dev/null 2>&1
perl -pi -e 's/^#obs \d+/"#obs " . (time()-99999)/e' "$PWQ_SD/.reap/departed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.obs"
PWQ_O2="$(run_pwq presence claim --name w2 --role r 2>/dev/null)"
[ ! -f "$PWQ_SD/departed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json" ] \
  && ok "a later claim, grace served, collects the dead record" || fail "claim never reaps"
[ -f "$PWQ_SD/nohandle-abababababababababababababababab.json" ] \
  && printf '%s\n' "$PWQ_O2" | grep -q 'nohandle.*ambig' \
  && ok "a claim never reaps a pid-less record — it is not provably dead" || fail "pid-less record reaped"
run_pwq presence release --name w2 --instance "$(PWQ_INST "$PWQ_O2")" >/dev/null 2>&1
# The payoff: the field actually frees. A reap leaves a tombstone cover that still
# reads as a peer, so isolation persists until the cover itself ages out.
rm -f "$PWQ_SD/nohandle-abababababababababababababababab.json"
PWQ_TOMB="$(ls "$PWQ_SD/.reap/"departed-*.tomb.* 2>/dev/null | head -1)"
[ -n "$PWQ_TOMB" ] && perl -pi -e 's/^#tomb \d+/"#tomb 1"/e' "$PWQ_TOMB"
PWQ_O3="$(run_pwq presence claim --name w3 --role r 2>/dev/null)"; PWQ_R3=$?
[ "$PWQ_R3" = 0 ] && ok "once the cover ages out the field is free again (exit 0)" || fail "field never freed (rc=$PWQ_R3)"
run_pwq presence release --name w3 --instance "$(PWQ_INST "$PWQ_O3")" >/dev/null 2>&1
# THE RESUME HAZARD (codex, implement r1, blocking). A resumed session is a NEW
# harness process. A beat that merely preserved the recorded pid would leave a LIVE
# session named by an exited one — which now evaluates dead, gets collected, and then
# reads as a free field to the next claimer. Strictly worse than the immortality this
# change fixes, and reachable ONLY because records became reapable.
# A FRESH heartbeat masks this: presence_eval returns live by age before it ever reads
# the pid, so the fixture must be stale for the hazard to be visible at all — which is
# precisely why it survived the author's own attack list.
PWQ_STALE() { perl -pi -e 's/"last_heartbeat_epoch": "[0-9]*"/"last_heartbeat_epoch": "1"/' "$1"; }
PWQ_E="$(PWQ_INST "$(claim_pwq $$ presence claim --name resumed --role r 2>/dev/null)")"
perl -pi -e "s/\"pid\": \"[0-9]*\"/\"pid\": \"$PWQ_GONE\"/; s/\"pid_started\": \"[^\"]*\"/\"pid_started\": \"exited\"/" "$PWQ_SD/resumed-$PWQ_E.json"
PWQ_STALE "$PWQ_SD/resumed-$PWQ_E.json"
PWQ_PRE="$(run_pwq presence others --name probe --instance eeeeeeee11111111 2>&1 || true)"
printf '%s\n' "$PWQ_PRE" | grep -q 'resumed' \
  && fail "the stale-pid fixture is not actually condemnable — the hazard is unproven" \
  || ok "a stale record naming the OLD harness pid reads dead (the resume hazard is real)"
claim_pwq $$ presence beat --name resumed --instance "$PWQ_E" >/dev/null 2>&1
grep -q "\"pid\": \"$$\"" "$PWQ_SD/resumed-$PWQ_E.json" \
  && ok "a beat RE-PINS the liveness identity to the running harness process" || fail "beat left the exited pid in place"
# Re-stale it WITHOUT touching the pid: a fresh heartbeat would make any record live,
# so only this proves the RE-PIN is what protects a resumed session, not the beat's clock.
PWQ_STALE "$PWQ_SD/resumed-$PWQ_E.json"
PWQ_POST="$(run_pwq presence others --name probe --instance eeeeeeee11111111 2>&1 || true)"
printf '%s\n' "$PWQ_POST" | grep -q 'resumed.*live' \
  && ok "the RE-PINNED handle keeps a stale resumed session live (suspend rule, not the clock)" || fail "resumed session still condemnable"
# A probe that cannot answer must PRESERVE the recorded handle, never blank it: a
# beat that erased the pid would manufacture exactly the immortal record this fixes.
claim_pwq 'not-a-number' presence beat --name resumed --instance "$PWQ_E" >/dev/null 2>&1
grep -q "\"pid\": \"$$\"" "$PWQ_SD/resumed-$PWQ_E.json" \
  && ok "a beat with no verifiable handle keeps the recorded one (never blanks it)" || fail "beat blanked the pid"
run_pwq presence release --name resumed --instance "$PWQ_E" >/dev/null 2>&1

# Source precedence and FALL-THROUGH (grok, implement r1, advisory): a stale override
# that no longer verifies must not shadow a good CLAUDE_PID.
PWQ_F="$(PWQ_INST "$( (cd "$PWQ" && env COMMS_PRESENCE_PID=$$ CLAUDE_PID="$PWQ_GONE" COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence claim --name override --role r) 2>/dev/null)")"
grep -q "\"pid\": \"$$\"" "$PWQ_SD/override-$PWQ_F.json" \
  && ok "COMMS_PRESENCE_PID is adopted and outranks CLAUDE_PID" || fail "COMMS_PRESENCE_PID not preferred"
run_pwq presence release --name override --instance "$PWQ_F" >/dev/null 2>&1
PWQ_G="$(PWQ_INST "$( (cd "$PWQ" && env COMMS_PRESENCE_PID="$PWQ_GONE" CLAUDE_PID=$$ COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence claim --name fallthrough --role r) 2>/dev/null)")"
grep -q "\"pid\": \"$$\"" "$PWQ_SD/fallthrough-$PWQ_G.json" \
  && ok "an unverifiable override falls THROUGH to the next source, never shadows it" || fail "stale override shadowed a good handle"
run_pwq presence release --name fallthrough --instance "$PWQ_G" >/dev/null 2>&1
# THE PRE-FIRST-BEAT RESUME WINDOW (codex, implement r2, blocking). `others` is the
# MANDATORY post-resume re-check, and it used to refresh nothing — so a session that
# resumed, ran only `others`, and worked on stayed named by the exited harness and was
# collectable while alive. The regression codex asked for: an ALREADY-AGED observation
# exists before the resume, so the very next claim would otherwise reap it outright.
PWQ_H="$(PWQ_INST "$(claim_pwq $$ presence claim --name recheck --role r 2>/dev/null)")"
perl -pi -e "s/\"pid\": \"[0-9]*\"/\"pid\": \"$PWQ_GONE\"/; s/\"pid_started\": \"[^\"]*\"/\"pid_started\": \"exited\"/" "$PWQ_SD/recheck-$PWQ_H.json"
PWQ_STALE "$PWQ_SD/recheck-$PWQ_H.json"
run_pwq presence expire >/dev/null 2>&1                       # pass 1: the observation exists
perl -pi -e 's/^#obs \d+/"#obs " . (time()-99999)/e' "$PWQ_SD/.reap/recheck-$PWQ_H.obs"
# The resumed session now reaches its documented checkpoint BEFORE any beat.
claim_pwq $$ presence others --name recheck --instance "$PWQ_H" >/dev/null 2>&1
grep -q "\"pid\": \"$$\"" "$PWQ_SD/recheck-$PWQ_H.json" \
  && ok "the mandatory re-check RE-PINS the resumed session's handle before any beat" || fail "others left the exited pid in place"
# Re-stale FIRST: a clock-only write would satisfy both assertions below by age alone, so
# only this makes them depend on the re-pinned IDENTITY. (grok, implement r3.)
PWQ_STALE "$PWQ_SD/recheck-$PWQ_H.json"
PWQ_RC="$(run_pwq presence claim --name newcomer --role r 2>/dev/null)"; PWQ_RCR=$?
[ -f "$PWQ_SD/recheck-$PWQ_H.json" ] \
  && ok "a claim with an aged observation cannot collect the re-pinned session" || fail "resumed session reaped in the pre-beat window"
[ "$PWQ_RCR" = 3 ] \
  && ok "and the newcomer is told to isolate rather than shown a free field" || fail "newcomer saw a free field (rc=$PWQ_RCR)"
run_pwq presence release --name newcomer --instance "$(PWQ_INST "$PWQ_RC")" >/dev/null 2>&1
run_pwq presence release --name recheck --instance "$PWQ_H" >/dev/null 2>&1
# A recycled pid keeps its NUMBER while its start time changes, and a claim whose lstart
# probe failed stored a pid with an EMPTY start that stale eval reads ambiguous forever.
# Comparing only the number left both unrepaired. (grok, implement r2.)
PWQ_I="$(PWQ_INST "$(claim_pwq $$ presence claim --name samepid --role r 2>/dev/null)")"
perl -pi -e 's/"pid_started": "[^"]*"/"pid_started": ""/' "$PWQ_SD/samepid-$PWQ_I.json"
claim_pwq $$ presence beat --name samepid --instance "$PWQ_I" >/dev/null 2>&1
grep -q '"pid_started": ""' "$PWQ_SD/samepid-$PWQ_I.json" \
  && fail "an unchanged pid NUMBER skipped the repair, leaving an empty start time" \
  || ok "the handle is repaired even when the pid number did not change"
run_pwq presence release --name samepid --instance "$PWQ_I" >/dev/null 2>&1
# THE CHECKPOINT MUST FAIL CLOSED (codex, implement r3, blocking). Codex's ordering, which
# the r2 regression had backwards: the claimer WINS — it collects the record and releases —
# and only then does the resumed session reach its mandatory re-check. `presence_peers`
# excludes the caller's own tombstone, so a checkpoint that answered normally here would
# hand a live, record-less session a free field. Impossible while records were immortal;
# owned by this change because they are not.
PWQ_J="$(PWQ_INST "$(claim_pwq $$ presence claim --name victim --role r 2>/dev/null)")"
perl -pi -e "s/\"pid\": \"[0-9]*\"/\"pid\": \"$PWQ_GONE\"/; s/\"pid_started\": \"[^\"]*\"/\"pid_started\": \"exited\"/" "$PWQ_SD/victim-$PWQ_J.json"
PWQ_STALE "$PWQ_SD/victim-$PWQ_J.json"
run_pwq presence expire >/dev/null 2>&1
perl -pi -e 's/^#obs \d+/"#obs " . (time()-99999)/e' "$PWQ_SD/.reap/victim-$PWQ_J.obs"
PWQ_K="$(PWQ_INST "$(run_pwq presence claim --name reaper --role r 2>/dev/null)")"   # the claimer wins
run_pwq presence release --name reaper --instance "$PWQ_K" >/dev/null 2>&1
[ ! -f "$PWQ_SD/victim-$PWQ_J.json" ] \
  && ok "the claimer collects the record before the resumed session re-checks (codex's ordering)" || fail "fixture did not reap — the sequence is unproven"
claim_pwq $$ presence others --name victim --instance "$PWQ_J" >/dev/null 2>&1; PWQ_LT=$?
[ "$PWQ_LT" = 5 ] \
  && ok "a re-check whose own record was collected reports LOST TENURE, never direct-safe" || fail "others answered $PWQ_LT on a collected record"
[ ! -f "$PWQ_SD/victim-$PWQ_J.json" ] \
  && ok "and it does not resurrect the record — healing stays beat's deliberate exit-5 path" || fail "others silently healed a collected record"
run_pwq presence expire --force victim >/dev/null 2>&1
# A re-pin that cannot be written must ISOLATE, not answer normally: a silent failure
# would leave the dead handle, keep the session invisible to itself, and still return 0.
PWQ_L="$(PWQ_INST "$(claim_pwq $$ presence claim --name unwritable --role r 2>/dev/null)")"
rm -rf "$PWQ_SD/.tmp"; : > "$PWQ_SD/.tmp"          # a FILE where presence_write needs a directory
claim_pwq $$ presence others --name unwritable --instance "$PWQ_L" >/dev/null 2>&1; PWQ_WF=$?
rm -f "$PWQ_SD/.tmp"
[ "$PWQ_WF" = 4 ] \
  && ok "a re-pin that cannot be written fails closed (ISOLATE), never direct-safe" || fail "unwritable re-pin answered $PWQ_WF"
run_pwq presence release --name unwritable --instance "$PWQ_L" >/dev/null 2>&1
# The tombstone check must stand on its OWN, not on the record being absent: grok
# observed that the r4 "does not resurrect" assertion would pass even without it,
# because the old code already skipped a write when the file was gone at entry. A
# cover beside an EXISTING record is the state only this guard catches — and it is
# what the unlink-between-check-and-write race leaves behind.
PWQ_M="$(PWQ_INST "$(claim_pwq $$ presence claim --name covered --role r 2>/dev/null)")"
mkdir -p "$PWQ_SD/.reap"; printf '#tomb %s\n' "$(date +%s)" > "$PWQ_SD/.reap/covered-$PWQ_M.tomb.feedface"
claim_pwq $$ presence others --name covered --instance "$PWQ_M" >/dev/null 2>&1; PWQ_CT=$?
[ "$PWQ_CT" = 5 ] && [ -f "$PWQ_SD/covered-$PWQ_M.json" ] \
  && ok "a reap cover beside an existing record still reports LOST TENURE" || fail "covered re-check answered $PWQ_CT"
rm -f "$PWQ_SD/.reap/covered-$PWQ_M.tomb.feedface"
run_pwq presence release --name covered --instance "$PWQ_M" >/dev/null 2>&1
# A sessions dir that is GONE cannot be an empty field for an identity that claimed:
# the caller's own record went with it. This shortcut ran before the tenure check.
PWQ_N="$(PWQ_INST "$(claim_pwq $$ presence claim --name dirless --role r 2>/dev/null)")"
mv "$PWQ_SD" "$PWQ_SD.away"
claim_pwq $$ presence others --name dirless --instance "$PWQ_N" >/dev/null 2>&1; PWQ_ND=$?
mv "$PWQ_SD.away" "$PWQ_SD"
[ "$PWQ_ND" = 5 ] \
  && ok "a missing sessions dir is lost tenure, never a free field" || fail "missing sessions dir answered $PWQ_ND"
run_pwq presence release --name dirless --instance "$PWQ_N" >/dev/null 2>&1
# The reap decides while the record is ABSENT (renamed aside), so a concurrent
# re-check can never observe a record this pass is about to delete.
PWQ_O="$(PWQ_INST "$(claim_pwq $$ presence claim --name staged --role r 2>/dev/null)")"
perl -pi -e "s/\"pid\": \"[0-9]*\"/\"pid\": \"$PWQ_GONE\"/; s/\"pid_started\": \"[^\"]*\"/\"pid_started\": \"exited\"/" "$PWQ_SD/staged-$PWQ_O.json"
PWQ_STALE "$PWQ_SD/staged-$PWQ_O.json"
run_pwq presence expire >/dev/null 2>&1
perl -pi -e 's/^#obs \d+/"#obs " . (time()-99999)/e' "$PWQ_SD/.reap/staged-$PWQ_O.obs"
run_pwq presence beat --name staged --instance "$PWQ_O" >/dev/null 2>&1   # bytes change under the pass
run_pwq presence expire >/dev/null 2>&1
[ -f "$PWQ_SD/staged-$PWQ_O.json" ] && ! ls "$PWQ_SD/.reap/".staging.* >/dev/null 2>&1 \
  && ok "a record that changed under the reap is RESTORED, leaving no staged orphan" || fail "the staged record was lost or orphaned"
run_pwq presence release --name staged --instance "$PWQ_O" >/dev/null 2>&1

# worktree new (AC4/AC6): grammar, ignore-gate, local tip, main-root anchoring.
check_not "worktree new refuses a bad slug" run_pw worktree new 'Bad/Slug'
check_not "worktree new refuses a multiline slug (whole-scalar, not per-line)" run_pw worktree new "$(printf 'feat\n../../tmp')"
(cd "$PW" && git checkout -q -b session-primary)   # never-occupy-main migration
run_pw worktree new featone >/dev/null 2>&1 && [ -d "$PW/.claude/worktrees/featone" ] \
  && ok "worktree new creates under .claude/worktrees on its own branch" || fail "worktree new"
(cd "$PW/.claude/worktrees/featone" && env COMMS_PRESENCE_TTL_SECS=60 "$COMMS" worktree new nested >/dev/null 2>&1)
[ -d "$PW/.claude/worktrees/nested" ] && [ ! -d "$PW/.claude/worktrees/featone/.claude/worktrees/nested" ] \
  && ok "worktree new from inside a worktree anchors on the MAIN root (never nests)" || fail "worktree nesting"
PW_ST_BEFORE="$(cd "$PW" && git status --porcelain)"
[ -z "$PW_ST_BEFORE" ] && ok "session worktrees leave main's status untouched (ignored)" || fail "worktree dirtied status: $PW_ST_BEFORE"

# Snapshot strips session worktrees MECHANICALLY, even without the ignore entry (AC6).
printf '.comms/\n' > "$PW/.gitignore"    # remove the worktree ignore in the fixture
PW_SNAP="$(run_pw snapshot create 2>/dev/null)"
(cd "$PW" && git ls-tree -r --name-only "$PW_SNAP" 2>/dev/null) | grep -q 'claude/worktrees' \
  && fail "snapshot ingested a session worktree" || ok "snapshot strips session worktrees mechanically (ignore entry removed)"
printf '.comms/\n.claude/worktrees/\n' > "$PW/.gitignore"

# integrate (AC3/AC5): ff lands at the tested OID via CAS; non-ff and unset config refuse.
(cd "$PW/.claude/worktrees/featone" && echo two > b.txt && git add b.txt && git -c user.email=t@t -c user.name=t commit -qm "feat: b")
run_pw integrate worktree-featone >/dev/null 2>&1 \
  && [ "$(cd "$PW" && git rev-parse main)" = "$(cd "$PW" && git rev-parse worktree-featone)" ] \
  && ok "integrate lands the candidate OID on main (suite green, CAS)" || fail "integrate did not land"
check_not "integrate refuses a non-descendant (ff-only)" run_pw integrate session-primary
PW_CFG="$(cat "$PW/.comms/config")"; printf '' > "$PW/.comms/config"
check_not "integrate refuses without explicit suite-cmd" run_pw integrate worktree-featone
printf '%s\n' "$PW_CFG" > "$PW/.comms/config"
# CAS race: main advances after resolve — model by handing integrate a stale branch.
(cd "$PW" && git checkout -q -b session-c main && echo c > c.txt && git add c.txt && git -c user.email=t@t -c user.name=t commit -qm "feat: c" && git checkout -q session-primary)
run_pw integrate session-c >/dev/null 2>&1
(cd "$PW/.claude/worktrees/nested" && git merge -q --ff-only "$(cd "$PW" && git rev-parse main)" 2>/dev/null; echo d > d.txt; git add d.txt; git -c user.email=t@t -c user.name=t commit -qm "feat: d")
run_pw integrate worktree-nested >/dev/null 2>&1 \
  && ok "serial landings compose (second branch rebased onto advanced main)" || fail "serial landing failed"
# Failed suite leaves main untouched.
PW_MAIN_BEFORE="$(cd "$PW" && git rev-parse main)"
(cd "$PW/.claude/worktrees/featone" && git merge -q --ff-only "$PW_MAIN_BEFORE" 2>/dev/null; printf '#!/bin/bash\nexit 1\n' > suite.sh; git add -A; git -c user.email=t@t -c user.name=t commit -qm "break suite" ) 2>/dev/null
check_not "a failed suite refuses to land" run_pw integrate worktree-featone
[ "$(cd "$PW" && git rev-parse main)" = "$PW_MAIN_BEFORE" ] \
  && ok "a failed suite leaves main untouched (verify-then-move)" || fail "main moved on red suite"
# Lease refusal: a live integrating presence blocks a second integrator.
PW_C4="$(run_pw presence claim --name landlord --role "landing" --state integrating)"; PW_I4="$(printf '%s' "$PW_C4" | sed -n 's/.*instance: //p')"
check_not "a live integrating lease refuses a second integrator" run_pw integrate worktree-nested
run_pw presence release --name landlord --instance "$PW_I4"
# Lease restoration on EARLY exit (codex, impl r1: trap installed after the state
# mutation leaked a live integrating lease on invalid candidates).
PW_C5="$(run_pw presence claim --name lander --role "landing")"; PW_I5="$(printf '%s' "$PW_C5" | sed -n 's/.*instance: //p')"
(cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=lander COMMS_PRESENCE_INSTANCE="$PW_I5" "$COMMS" integrate no-such-branch) >/dev/null 2>&1
grep -q '"state": "working"' "$PW_SD/lander-$PW_I5.json" \
  && ok "an early integrate exit restores the lease (trap precedes mutation)" || fail "lease leaked on early exit: $(grep state "$PW_SD/lander-$PW_I5.json")"
# Presence-wrapped landing actually lands (grok, impl r1: the 143 path refused
# green suites; every earlier integrate test ran WITHOUT the presence env).
(cd "$PW/.claude/worktrees/nested" && git merge -q --ff-only "$(cd "$PW" && git rev-parse main)" 2>/dev/null; echo e > e.txt; git add e.txt; git -c user.email=t@t -c user.name=t commit -qm "feat: e")
(cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=lander COMMS_PRESENCE_INSTANCE="$PW_I5" "$COMMS" integrate worktree-nested) >/dev/null 2>&1; PW_LAND=$?
[ "$PW_LAND" = 0 ] && [ "$(cd "$PW" && git rev-parse main)" = "$(cd "$PW" && git rev-parse worktree-nested)" ] \
  && ok "a presence-wrapped integrate lands a green suite (the 143 regression)" || fail "presence-wrapped landing rc=$PW_LAND"
run_pw presence release --name lander --instance "$PW_I5"
# Suite result must be BOUND to the candidate (codex, impl r1): a suite that moves
# HEAD passes elsewhere and must be refused.
PW_CFG2="$(cat "$PW/.comms/config")"
printf 'suite-cmd = git checkout --detach HEAD~1\n' > "$PW/.comms/config"
check_not "a suite that moves HEAD off the candidate is refused" run_pw integrate worktree-nested
printf 'suite-cmd = \t \n' > "$PW/.comms/config"
check_not "a whitespace-only suite-cmd is refused (no zero-argv no-op landing)" run_pw integrate worktree-nested
printf '%s\n' "$PW_CFG2" > "$PW/.comms/config"
# FAILED presence-wrapped integrate must be RETRYABLE (grok, impl r2: die's EXIT
# trap fired after locals vanished, the registered worktree leaked, and the
# documented fix-and-re-run recovery hit 'missing but already registered').
PW_C6="$(run_pw presence claim --name retrier --role landing)"; PW_I6="$(printf '%s' "$PW_C6" | sed -n 's/.*instance: //p')"
(cd "$PW/.claude/worktrees/nested" && git merge -q --ff-only "$(cd "$PW" && git rev-parse main)" 2>/dev/null; printf '#!/bin/bash\nexit 1\n' > suite.sh; git add suite.sh; git -c user.email=t@t -c user.name=t commit -qm "red suite")
(cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=retrier COMMS_PRESENCE_INSTANCE="$PW_I6" "$COMMS" integrate worktree-nested) >/dev/null 2>&1; PW_RED=$?
[ "$PW_RED" != 0 ] && ok "the red presence-wrapped suite refuses to land" || fail "red suite landed"
(cd "$PW/.claude/worktrees/nested" && printf '#!/bin/bash\ntest -f a.txt\n' > suite.sh && git add suite.sh && git -c user.email=t@t -c user.name=t commit -qm "green suite")
(cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=retrier COMMS_PRESENCE_INSTANCE="$PW_I6" "$COMMS" integrate worktree-nested) >/dev/null 2>&1; PW_RETRY=$?
[ "$PW_RETRY" = 0 ] && [ "$(cd "$PW" && git rev-parse main)" = "$(cd "$PW" && git rev-parse worktree-nested)" ] \
  && ok "the SAME instance retries and lands after a failure (no leaked registration)" || fail "retry after red suite rc=$PW_RETRY"
grep -q '"state": "working"' "$PW_SD/retrier-$PW_I6.json" \
  && ok "the lease is restored after both the failure and the landing" || fail "lease stuck after retry"
run_pw presence release --name retrier --instance "$PW_I6"

# Self-heal (2026-08-27, from the arc's own first landing): ONE clean checkout
# idling on main at the expected tip is fast-forwarded through the landing
# instead of refused. Dirty occupants still refuse; a failed landing re-attaches
# the healed occupant to the unmoved main.
(cd "$PW" && git checkout -q main)
(cd "$PW/.claude/worktrees/nested" && git merge -q --ff-only "$(cd "$PW" && git rev-parse main)" 2>/dev/null; echo f > f.txt; git add f.txt; git -c user.email=t@t -c user.name=t commit -qm "feat: f")
run_pw integrate worktree-nested >/dev/null 2>&1; PW_HEAL=$?
[ "$PW_HEAL" = 0 ] && [ "$(cd "$PW" && git rev-parse main)" = "$(cd "$PW" && git rev-parse worktree-nested)" ] \
  && ok "a clean main occupant at the expected tip is healed through the landing" || fail "self-heal landing rc=$PW_HEAL"
[ "$(cd "$PW" && git symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
  && [ "$(cd "$PW" && git rev-parse HEAD)" = "$(cd "$PW" && git rev-parse worktree-nested)" ] \
  && ok "the healed occupant ends re-attached to main at the LANDED tip" || fail "occupant not fast-forwarded: $(cd "$PW" && git symbolic-ref --short HEAD 2>/dev/null) @ $(cd "$PW" && git rev-parse --short HEAD)"
# Dirty occupant: refused BEFORE the suite, main untouched, dirt intact.
(cd "$PW" && echo dirty >> a.txt)
PW_MAIN_OCC="$(cd "$PW" && git rev-parse main)"
check_not "a DIRTY main occupant refuses the landing (never-occupy-main)" run_pw integrate worktree-nested
[ "$(cd "$PW" && git rev-parse main)" = "$PW_MAIN_OCC" ] && (cd "$PW" && git status --porcelain | grep -q 'a.txt') \
  && ok "the dirty-occupant refusal touches neither main nor the dirt" || fail "dirty-occupant refusal mutated state"
(cd "$PW" && git checkout -q -- a.txt)
# Failed landing with a healed occupant: the trap re-attaches it to the UNMOVED main.
(cd "$PW/.claude/worktrees/nested" && printf '#!/bin/bash\nexit 1\n' > suite.sh && git add suite.sh && git -c user.email=t@t -c user.name=t commit -qm "red suite")
check_not "a red suite still refuses with a healed occupant" run_pw integrate worktree-nested
[ "$(cd "$PW" && git symbolic-ref --short HEAD 2>/dev/null)" = "main" ] && [ "$(cd "$PW" && git rev-parse main)" = "$PW_MAIN_OCC" ] \
  && ok "the failed landing re-attaches the healed occupant to the unmoved main" || fail "occupant stranded after red suite: $(cd "$PW" && git symbolic-ref --short HEAD 2>/dev/null)"
(cd "$PW/.claude/worktrees/nested" && printf '#!/bin/bash\ntest -f a.txt\n' > suite.sh && git add suite.sh && git -c user.email=t@t -c user.name=t commit -qm "green suite")
# An occupant that COMMITTED during the landing window is not the idle console
# we detached: re-attaching would abandon those commits (grok, r1).
(cd "$PW" && git checkout -q main)
(cd "$PW/.claude/worktrees/nested" && git merge -q --ff-only "$(cd "$PW" && git rev-parse main)" 2>/dev/null; echo h > h.txt; git add h.txt; git -c user.email=t@t -c user.name=t commit -qm "feat: h")
PW_OCC_CFG="$(cat "$PW/.comms/config")"
# suite-cmd is whitespace-split into argv with NOTHING shell-interpreted, so the
# racer must be a script file, not an inline `bash -c "..."` (that string is
# shredded into meaningless words — the shape this very test first got wrong).
printf '#!/bin/bash\ncd "%s" || exit 1\necho moved > moved.txt\ngit add moved.txt\ngit -c user.email=t@t -c user.name=t commit -qm racer >/dev/null 2>&1\nexit 0\n' "$PW" > "$WORK/racer.sh"
printf 'suite-cmd = bash %s\n' "$WORK/racer.sh" > "$PW/.comms/config"
run_pw integrate worktree-nested >/dev/null 2>&1
[ "$(cd "$PW" && git symbolic-ref --short HEAD 2>/dev/null)" != "main" ] \
  && (cd "$PW" && git log -1 --format=%s | grep -q racer) \
  && ok "an occupant that moved during the landing is left detached with its commit intact" \
  || fail "moved occupant was re-attached (commit abandoned): $(cd "$PW" && git symbolic-ref --short HEAD 2>/dev/null)"
printf '%s\n' "$PW_OCC_CFG" > "$PW/.comms/config"
(cd "$PW" && git checkout -q session-primary)
# The opt-in key is KNOWN to the one full-config validation path, and a
# duplicate (an appended `= 0` that consumers would never reach) is refused.
printf 'suite-cmd = bash ./suite.sh\nsuite-attest-secs = 600\n' > "$PW/.comms/config"
PW_CFGWARN="$( (cd "$PW" && env "$COMMS" agents) 2>&1 || true)"
printf '%s' "$PW_CFGWARN" | grep -q 'unknown line' \
  && fail "suite-attest-secs warns as an unknown config key" || ok "suite-attest-secs is a known config key"
printf 'suite-cmd = bash ./suite.sh\nsuite-attest-secs = 600\nsuite-attest-secs = 0\n' > "$PW/.comms/config"
check_not "a duplicate suite-attest-secs is refused (the disabling line must win)" bash -c "cd '$PW' && env '$COMMS' agents"
# The refusal must hold on the CONSUMER that matters: integrate reads the config
# directly and never calls registry_parse, so validating only there left the
# landing command consuming the first (enabling) value. (codex, r2 blocking.)
PW_DUPMAIN="$(cd "$PW" && git rev-parse main)"
check_not "integrate itself refuses a duplicate suite-attest-secs" run_pw integrate worktree-nested
[ "$(cd "$PW" && git rev-parse main)" = "$PW_DUPMAIN" ] \
  && ok "the duplicate-config refusal lands nothing" || fail "main moved on a duplicate-key config"
printf 'suite-cmd = bash ./suite.sh\nsuite-cmd = bash ./other.sh\n' > "$PW/.comms/config"
check_not "integrate refuses a duplicate suite-cmd (the permissive one must not win)" run_pw integrate worktree-nested
printf 'suite-cmd = bash ./suite.sh\n' > "$PW/.comms/config"

# Attested green (2026-08-27): a fresh attest-green record for EXACTLY the
# candidate OID stands in for integrate's re-run when config opts in.
check_not "attest-green refuses a tree with tracked changes" bash -c "cd '$PW/.claude/worktrees/nested' && echo dirty >> a.txt && '$COMMS' attest-green; rc=\$?; git checkout -q -- a.txt; exit \$rc"
# The attestation is bound to the commit the RUN was about: a checkout that
# races the end of a green run must not inherit its result (codex, r1 blocking).
PW_ATT_OTHER="$(cd "$PW/.claude/worktrees/nested" && git rev-parse HEAD~1)"
check_not "attest-green refuses when HEAD moved off the verified commit" bash -c "cd '$PW/.claude/worktrees/nested' && env '$COMMS' attest-green --expect '$PW_ATT_OTHER'"
grep -q "^$PW_ATT_OTHER " "$PW/.comms/cache/suite-attest.log" 2>/dev/null \
  && fail "a refused attestation still wrote a record" || ok "a refused --expect attestation records nothing"
check_not "attest-green --passed with no value is a usage error, not a crash" bash -c "cd '$PW/.claude/worktrees/nested' && env '$COMMS' attest-green --passed"
(cd "$PW/.claude/worktrees/nested" && env "$COMMS" attest-green --passed 7 >/dev/null 2>&1)
grep -q "^$(cd "$PW/.claude/worktrees/nested" && git rev-parse HEAD) " "$PW/.comms/cache/suite-attest.log" \
  && ok "attest-green records the checkout's HEAD in the main root's cache" || fail "attestation not recorded"
# Fresh attestation + a suite-cmd that would FAIL: landing succeeds only if the
# re-run was actually skipped.
printf 'suite-cmd = false\nsuite-attest-secs = 600\n' > "$PW/.comms/config"
run_pw integrate worktree-nested >/dev/null 2>&1; PW_ATT=$?
[ "$PW_ATT" = 0 ] && [ "$(cd "$PW" && git rev-parse main)" = "$(cd "$PW" && git rev-parse worktree-nested)" ] \
  && ok "a fresh same-OID attestation lands without the re-run" || fail "attested landing rc=$PW_ATT"
# A NEW candidate has no attestation: the (failing) suite must actually run.
(cd "$PW/.claude/worktrees/nested" && echo g > g.txt && git add g.txt && git -c user.email=t@t -c user.name=t commit -qm "feat: g")
check_not "an unattested candidate falls through to the real suite" run_pw integrate worktree-nested
# A STALE attestation for the right OID also falls through.
printf '%s 100 7\n' "$(cd "$PW/.claude/worktrees/nested" && git rev-parse HEAD)" >> "$PW/.comms/cache/suite-attest.log"
check_not "a stale attestation falls through to the real suite" run_pw integrate worktree-nested
printf 'suite-cmd = bash ./suite.sh\n' > "$PW/.comms/config"

# with-beat: a beat lands DURING a blocked child (AC1).
PW_HB_BEFORE="$(sed -n 's/.*"last_heartbeat_epoch": "\([0-9]*\)".*/\1/p' "$PW_SD/alpha-$PW_I1.json")"
(cd "$PW" && env COMMS_PRESENCE_TTL_SECS=3 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- sleep 4) >/dev/null 2>&1
PW_HB_AFTER="$(sed -n 's/.*"last_heartbeat_epoch": "\([0-9]*\)".*/\1/p' "$PW_SD/alpha-$PW_I1.json")"
[ "$PW_HB_AFTER" != "$PW_HB_BEFORE" ] && ok "with-beat lands a heartbeat DURING a blocked child" || fail "no beat during block"
# with-beat rc contract (grok, impl r1: wait-on-SIGTERM'd-beater returned 143 under
# errexit and green suites refused to land — the timestamp test alone missed it).
run_pw presence with-beat --name alpha --instance "$PW_I1" -- true >/dev/null 2>&1; PW_WB0=$?
[ "$PW_WB0" = 0 ] && ok "with-beat returns the child's success (not the beater's 143)" || fail "with-beat true rc=$PW_WB0"
run_pw presence with-beat --name alpha --instance "$PW_I1" -- false >/dev/null 2>&1; PW_WB1=$?
[ "$PW_WB1" != 0 ] && ok "with-beat returns the child's failure" || fail "with-beat false rc=0"
# HEAL MID-RUN (codex+grok, impl r2: the set-e beater died on beat exit 5 before
# the marker line — heal was eaten AND heartbeats stopped): delete the record
# during with-beat; the warning must surface AND a beat LATER than the heal must
# land (epoch strictly after start+3 proves post-heal ticks — reviewers noted the
# heal write alone satisfied the old assertion).
rm -f "$PW_SD/alpha-$PW_I1.json"
PW_WBT0="$(date +%s)"
PW_WBH="$( (cd "$PW" && env COMMS_PRESENCE_TTL_SECS=3 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- sleep 5) 2>&1 )"; PW_WBHRC=$?
printf '%s\n' "$PW_WBH" | grep -q 'HEALED a vanished record' \
  && ok "a heal during with-beat surfaces the tenure warning" || fail "heal eaten by the beater"
[ "$PW_WBHRC" = 0 ] && ok "the healing run still returns the child's status" || fail "heal perturbed rc=$PW_WBHRC"
PW_HB2="$(sed -n 's/.*"last_heartbeat_epoch": "\([0-9]*\)".*/\1/p' "$PW_SD/alpha-$PW_I1.json" 2>/dev/null)"
[ -n "$PW_HB2" ] && [ "$PW_HB2" -ge $((PW_WBT0 + 3)) ] \
  && ok "the beater survived the heal and kept beating (post-heal tick landed)" || fail "beater died after heal (epoch $PW_HB2 vs start $PW_WBT0)"
# SIGNAL CONTRACT (codex, impl r3): TERM to the WRAPPER tears down the whole child
# process tree (grandchildren included) and the wrapper's rc reflects the signal.
PW_MARK="$WORK/wb-descendant.$$"
# exec: the subshell BECOMES the wrapper, so the TERM lands on comms.sh itself —
# killing the intermediate subshell instead just orphaned the real wrapper and
# the first version of this test failed against a correct teardown.
( cd "$PW" && exec env COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- bash -c "sleep 30 & echo \$! > '$PW_MARK'; wait" ) & PW_WRAP=$!
sleep 2
kill -TERM "$PW_WRAP" 2>/dev/null
PW_SIGRC=0; wait "$PW_WRAP" 2>/dev/null || PW_SIGRC=$?
[ "$PW_SIGRC" != 0 ] && ok "TERM to the wrapper terminates it with a signal status" || fail "wrapper ignored TERM"
sleep 1
PW_GRAND="$(cat "$PW_MARK" 2>/dev/null)"
if [ -n "$PW_GRAND" ] && kill -0 "$PW_GRAND" 2>/dev/null; then
  kill "$PW_GRAND" 2>/dev/null; fail "a grandchild survived the wrapper's teardown"
else
  ok "the child's whole process group is torn down (no surviving grandchild)"
fi
# STDIN PRESERVATION (codex, impl r3): a piped client must still read its input.
PW_PIPE="$(echo piped-hello | run_pw presence with-beat --name alpha --instance "$PW_I1" -- head -1)"
[ "$PW_PIPE" = "piped-hello" ] && ok "with-beat preserves the wrapper's stdin for the child" || fail "stdin lost (got: $PW_PIPE)"
# INT identity (codex, impl r4): an INT-interrupted wrapper reports the INT status.
# Spawned under set -m: a background job of a NON-job-control shell inherits
# SIGINT ignored, and POSIX forbids trapping a signal ignored at entry — the
# first version of this test no-op'd its own kill and timed out to rc 0.
set -m
( cd "$PW" && exec env COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- sleep 30 ) & PW_IW=$!
set +m
sleep 2; kill -INT "$PW_IW" 2>/dev/null
PW_IRC=0; wait "$PW_IW" 2>/dev/null || PW_IRC=$?
[ "$PW_IRC" = 130 ] && ok "INT to the wrapper yields the child's INT status (130)" || fail "INT identity lost (rc=$PW_IRC)"
# CANCELLATION NEVER SUCCEEDS (codex, impl r5: a fast child exiting 0 before the
# re-signal produced 225/2000 false successes — integrate would land them). Twenty
# INT-at-spawn iterations with an instant child: no run may return 0.
# The 20-iteration loop runs in a FRESH bash child: the suite shell carries
# hundreds of prior background-job table entries, and the loop consistently
# produced exactly one spurious rc-0 there while 100-iteration standalone runs
# (and direct instrumentation) are always clean — a harness-shell interaction,
# not a wrapper defect. The child shell isolates the job table; forensics print
# on any zero.
PW_CANCEL_OUT="$(bash -c '
  C="$1"; PW="$2"; I="$3"
  false0=0; delivered=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    set -m
    ( cd "$PW" && exec env COMMS_PRESENCE_TTL_SECS=60 "$C" presence with-beat --name alpha --instance "$I" -- sleep 0.3 ) 2>/tmp/pwcancel.$$.err & p=$!
    set +m
    if kill -INT "$p" 2>/dev/null; then
      delivered=$((delivered + 1))
      rc=0; wait "$p" 2>/dev/null || rc=$?
      if [ "$rc" -eq 0 ]; then false0=$((false0 + 1)); echo "ZERO at iter $i:"; cat /tmp/pwcancel.$$.err; fi
    else
      wait "$p" 2>/dev/null || true
    fi
    rm -f /tmp/pwcancel.$$.err
  done
  # Instant-exit child: the child can finish with rc 0 BEFORE the INT lands, so
  # only the status coercion keeps a latched cancellation nonzero — the sleeping
  # child above never samples that path (grok, impl r8 advisory). A bare
  # kill-then-wait is FLAKY here: kill succeeds on a zombie too, and a wrapper
  # that finished uncancelled legitimately returns 0 (the r5 lesson). So each
  # iteration is STOP-gated: freeze the wrapper, confirm it is stopped and not a
  # zombie, queue the INT, thaw — a counted INT is provably delivered alive.
  fastn=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    set -m
    ( cd "$PW" && exec env COMMS_PRESENCE_TTL_SECS=60 "$C" presence with-beat --name alpha --instance "$I" -- true ) 2>/tmp/pwcancel.$$.err & p=$!
    set +m
    kill -STOP "$p" 2>/dev/null || true
    st="$(ps -p "$p" -o stat= 2>/dev/null || true)"
    case "$st" in
      *Z*|"") kill -CONT "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true ;;
      *) kill -INT "$p" 2>/dev/null || true
         kill -CONT "$p" 2>/dev/null || true
         fastn=$((fastn + 1)); delivered=$((delivered + 1))
         rc=0; wait "$p" 2>/dev/null || rc=$?
         if [ "$rc" -eq 0 ]; then false0=$((false0 + 1)); echo "ZERO at fast-iter $i:"; cat /tmp/pwcancel.$$.err; fi ;;
    esac
    rm -f /tmp/pwcancel.$$.err
  done
  [ "$fastn" -ge 5 ] || echo "WARN: only $fastn/10 fast-exit iterations were live at INT"
  echo "delivered=$delivered false0=$false0"
' cancel-probe "$COMMS" "$PW" "$PW_I1")"
PW_DELIVERED="$(printf '%s\n' "$PW_CANCEL_OUT" | sed -n 's/.*delivered=\([0-9]*\).*/\1/p')"
PW_FALSE0="$(printf '%s\n' "$PW_CANCEL_OUT" | sed -n 's/.*false0=\([0-9]*\).*/\1/p')"
[ "${PW_FALSE0:-1}" = 0 ] && [ "${PW_DELIVERED:-0}" -ge 15 ] \
  && ok "a latched cancellation never returns success ($PW_DELIVERED/$PW_DELIVERED delivered-INT runs nonzero)" \
  || fail "cancellation loop: $PW_CANCEL_OUT"
# LATE CANCEL during quiescence (codex, impl r6: the latch updated after the old
# coercion point and a signal during the polls returned 0): the child exits 0
# instantly but parks a TERM-ignoring descendant so the polls run; INT mid-poll
# must still yield a nonzero wrapper status.
set -m
( cd "$PW" && exec env COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- bash -c "trap '' TERM; sleep 4 & exit 0" ) & PW_LW=$!
set +m
sleep 1; kill -INT "$PW_LW" 2>/dev/null
PW_LRC=0; wait "$PW_LW" 2>/dev/null || PW_LRC=$?
[ "$PW_LRC" != 0 ] && ok "a cancel DURING quiescence still refuses success" || fail "late cancel returned 0"
# Reserved delimiter: a dotted name containing '.tomb.' is refused at every entry.
check_not "a name containing the reserved .tomb. delimiter is refused" run_pw presence claim --name 'foo.tomb.bar' --role x
# MULTILINE identifiers are refused everywhere (codex, impl r7: grep validates
# lines, so 'alpha<NL>../../tmp' passed on its first line and the tail reached
# paths, globs, and the integrate trap string).
PW_NL="$(printf 'alpha\n../../tmp')"
check_not "a multiline name is refused at claim" run_pw presence claim --name "$PW_NL" --role x
check_not "a multiline instance is refused at release" run_pw presence release --name alpha --instance "$PW_NL"
check_not "a multiline instance is refused at beat" run_pw presence beat --name alpha --instance "$PW_NL"
check_not "a multiline name is refused at expire --force" run_pw presence expire --force "$PW_NL"
check_not "a multiline instance is refused at integrate" run_pw integrate worktree-featone --name alpha --instance "$PW_NL"
PW_CR="$(printf 'alpha\r../../tmp')"
check_not "a CR-bearing name is refused at claim" run_pw presence claim --name "$PW_CR" --role x
check_not "a CR-bearing instance is refused at release" run_pw presence release --name alpha --instance "$PW_CR"
# QUIESCENCE (codex, impl r4): a successful wrapper return means the child's whole
# group is GONE — a TERM-ignoring descendant must be escalated to KILL, not left
# straggling for integrate to trust a live tree.
PW_QMARK="$WORK/wb-quiesce.$$"
run_pw presence with-beat --name alpha --instance "$PW_I1" -- bash -c "trap '' TERM; sleep 30 & echo \$! > '$PW_QMARK'; exit 0" >/dev/null 2>&1; PW_QRC=$?
PW_QPID="$(cat "$PW_QMARK" 2>/dev/null)"
if [ -n "$PW_QPID" ] && kill -0 "$PW_QPID" 2>/dev/null; then
  kill -KILL "$PW_QPID" 2>/dev/null; fail "a TERM-ignoring descendant survived a successful return"
else
  [ "$PW_QRC" = 0 ] && ok "successful return implies a quiescent child group (KILL escalation)" || fail "quiescence changed rc=$PW_QRC"
fi
# Unreadable tomb (grok, impl r4): the reader isolates, it never aborts mid-print.
printf '#tomb x\n' > "$PW_SD/.reap/veil-77777777777777777777777777777777.tomb.beef7777"
chmod 000 "$PW_SD/.reap/veil-77777777777777777777777777777777.tomb.beef7777" 2>/dev/null
run_pw presence others --name alpha --instance "$PW_I1" >/dev/null 2>&1; PW_VRC=$?
[ "$PW_VRC" = 3 ] || [ "$PW_VRC" = 4 ] \
  && ok "an unreadable tomb fail-closes the reader (3/4, never abort)" || fail "unreadable tomb rc=$PW_VRC"
chmod 644 "$PW_SD/.reap/veil-77777777777777777777777777777777.tomb.beef7777" 2>/dev/null
rm -f "$PW_SD/.reap/veil"-* 2>/dev/null
# Unreadable sessions dir: CLAIM must isolate, not report an empty field
# (codex, impl r2 — validation now lives in the shared reader).
chmod 300 "$PW_SD" 2>/dev/null
run_pw presence claim --name reader --role x >/dev/null 2>&1; PW_UR=$?
chmod 755 "$PW_SD" 2>/dev/null
[ "$PW_UR" = 4 ] && ok "claim on an unenumerable sessions dir isolates (exit 4)" || fail "claim unreadable rc=$PW_UR"
# Entry-point validation (codex advisory): a hostile instance is refused everywhere.
check_not "beat refuses an invalid instance" run_pw presence beat --name alpha --instance '../../etc'
check_not "release refuses an invalid instance" run_pw presence release --name alpha --instance '*'
# ps-failure ambiguity (codex, impl r1: a sandboxed ps exits 126 and a live stale
# session was read as dead and reaped).
PW_PSBIN="$WORK/psfail"; mkdir -p "$PW_PSBIN"
printf '#!/bin/bash\nexit 126\n' > "$PW_PSBIN/ps"; chmod +x "$PW_PSBIN/ps"
printf '{\n  "name": "sandboxed", "instance": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "state": "working", "host": "%s", "pid": "12345", "pid_started": "x", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" > "$PW_SD/sandboxed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"
PW_PSO="$( (cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 PATH="$PW_PSBIN:$PATH" "$COMMS" presence others --name alpha --instance "$PW_I1") || true)"
printf '%s\n' "$PW_PSO" | grep -q 'sandboxed' \
  && ok "a ps that cannot answer keeps the record ambiguous (peer, not dead)" || fail "ps failure read as death"
(cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 PATH="$PW_PSBIN:$PATH" "$COMMS" presence expire) >/dev/null 2>&1
(cd "$PW" && env COMMS_PRESENCE_TTL_SECS=60 PATH="$PW_PSBIN:$PATH" "$COMMS" presence expire) >/dev/null 2>&1
[ -f "$PW_SD/sandboxed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json" ] \
  && ok "expire never reaps under a failing ps" || fail "reaped on ps failure"
rm -f "$PW_SD/sandboxed-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json" "$PW_SD/.reap/sandboxed"-* 2>/dev/null
# Young cover beside a DEAD record still reads as a peer (codex+grok, impl r1).
printf '{\n  "name": "shade", "instance": "99999999999999999999999999999999", "state": "working", "host": "%s", "pid": "99999999", "pid_started": "gone", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" > "$PW_SD/shade-99999999999999999999999999999999.json"
printf '#tomb %s\n' "$(date +%s)" > "$PW_SD/.reap/shade-99999999999999999999999999999999.tomb.cafe1234"
PW_SHO="$(run_pw presence others --name alpha --instance "$PW_I1" || true)"
printf '%s\n' "$PW_SHO" | grep -q 'shade.*reaped-cover' \
  && ok "a young cover beside a DEAD record is still a peer" || fail "dead record hid its cover"
rm -f "$PW_SD/shade-99999999999999999999999999999999.json" "$PW_SD/.reap/shade"-* 2>/dev/null
run_pw presence release --name alpha --instance "$PW_I1"

# Template wiring (AC4): the gate and the re-check rule are in the always-loaded surfaces.
grep -q 'presence claim' "$REPO/templates/claude-commands/auto.md" \
  && grep -qi 'After EVERY wait' "$REPO/templates/claude-commands/auto.md" \
  && ok "auto.md carries the presence gate and the post-wait re-check" || fail "auto.md presence wiring"
# Step 0 runs before the helper-resolution step, so it must resolve COMMS_SH itself
# (codex, impl r1: the gate invoked an unset variable on every fresh session).
awk '/^0\. \*\*Presence gate/,/^1\. \*\*Parse/' "$REPO/templates/claude-commands/auto.md" | grep -q 'COMMS_SH="\$(git worktree list' \
  && ok "the gate resolves its own helper before claiming" || fail "gate uses unresolved COMMS_SH"
grep -qi 'Presence re-check after the wait — single-reviewer and panel alike' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "the reader re-checks presence on the COMMON autonomous path" || fail "reader presence wiring"
grep -qi 'presence <claim|beat' "$REPO/helpers/comms.sh" \
  && ok "comms.sh help names the presence/worktree/integrate verbs" || fail "help drift"
