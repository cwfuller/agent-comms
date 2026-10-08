# Run through tests/run.sh; each group gets fresh fixtures.
# Deferred deletion (helpers/trash.sh) and its reaper (`runphase.sh reap`), driven directly: real
# git worktrees, a real detached reaper, and a test hook wherever a race is planted. The sites that
# call it (a throwaway mount, `clean mounts --thread`, integrate) are covered in their own groups.
TS="$WORK/trash"; mkdir -p "$TS"; TS="$(cd "$TS" && pwd -P)"
TS_SH="$REPO/helpers/trash.sh"
# One trash.sh function under the helpers' own shell options; prints "<rc> <TRASH_HOLD>".
ts_fn() { bash -c 'set -euo pipefail; . "$1"; shift; rc=0; "$@" || rc=$?; printf "%s %s\n" "$rc" "$TRASH_HOLD"' _ "$TS_SH" "$@"; }
ts_rc() { printf '%s' "${1%% *}"; }
ts_hold() { printf '%s' "${1#* }"; }
TS_R="$TS/repo"; git init -q -b main "$TS_R"
printf 'x\n' > "$TS_R/f.txt"; git -C "$TS_R" add f.txt; git -C "$TS_R" -c user.email=t@t -c user.name=t commit -qm init
TS_W="$TS_R/.claude/worktrees"; TS_T="$TS_W/.comms-trash"; TS_GD="$TS_R/.git"; mkdir -p "$TS_W"
ts_wt() { git -C "$TS_R" worktree add -q --detach "$TS_W/$1" >/dev/null 2>&1 && [ -f "$TS_W/$1/.git" ]; }
ts_adm() { sed -n 's/^gitdir: //p' "$1/.git" 2>/dev/null; }
ts_reg() { git -C "$TS_R" worktree list --porcelain 2>/dev/null | grep_full -qxF "worktree $1"; }
ts_age() { python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2])*60; os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
ts_dead_pid() { ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
# Every hook logs "<event> <path> <its parent pid>" and blocks at $TS_BLOCK_AT until $TS_RELEASE
# exists (bounded: 60s). The parent of a reap hook is the reaper; of a trash hook, the put's maker.
cat > "$TS/hook-block" <<'EOF'
#!/bin/bash
printf '%s %s %s\n' "$1" "$2" "$PPID" >> "$TS_HOOK_LOG"
[ "$1" = "${TS_BLOCK_AT:-}" ] || exit 0
n=0; while [ ! -e "$TS_RELEASE" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
exit 0
EOF
cat > "$TS/hook-kill" <<'EOF'
#!/bin/bash
[ "$1" = held ] && kill -9 "$PPID"
exit 0
EOF
cat > "$TS/hook-repoint" <<'EOF'
#!/bin/bash
[ "$1" = held ] && printf '%s\n' "$TS_REPOINT_TO" > "$TS_REPOINT_ADM/gitdir"
exit 0
EOF
chmod +x "$TS/hook-block" "$TS/hook-kill" "$TS/hook-repoint"
# Trees named for pid 1 are owned by a process that is always alive, so the repo sweep of every
# reaper started below keeps them: only section 4's trees are the sweep's to judge.

section "trash: the worktree-aware rename drops exactly the moved tree's registration"
TS_OK=1
ts_wt .integrate-1-1 && ts_wt keep && ts_wt decoy || TS_OK=0
TS_A1="$(ts_adm "$TS_W/.integrate-1-1")"; TS_AK="$(ts_adm "$TS_W/keep")"; TS_AD="$(ts_adm "$TS_W/decoy")"
rm -rf "$TS_W/decoy"   # registered but missing: only a prune would drop it
TS_O="$(ts_fn trash_tree "$TS_GD" "$TS_T" integrate "$TS_W/.integrate-1-1")"; TS_H1="$(ts_hold "$TS_O")"
if [ "$TS_OK" = 1 ] && [ "$(ts_rc "$TS_O")" = 0 ] && [ ! -e "$TS_W/.integrate-1-1" ] && [ -f "$TS_H1/payload/f.txt" ] \
   && grep -qE '^\.hold\.[0-9]{10}\.integrate\.[0-9]+\.[0-9a-f]{6}$' <<<"${TS_H1##*/}" && [ -f "$TS_H1/owner" ] \
   && [ -n "$TS_A1" ] && [ ! -e "$TS_A1" ] && ! ts_reg "$TS_W/.integrate-1-1" \
   && [ -d "$TS_AK" ] && ts_reg "$TS_W/keep" && [ -d "$TS_AD" ] && ts_reg "$TS_W/decoy"; then
  ok "trash_tree moves the tree into a hold and drops exactly its admin dir; a missing decoy stays registered, so no prune ran"
else
  fail "worktree-aware rename: rc=$(ts_rc "$TS_O") hold=$TS_H1 admin=$TS_A1 keep=$TS_AK decoy=$TS_AD"
fi
ts_fn trash_commit "$TS_T" "$TS_H1" >/dev/null
TS_RW=0; reap_wait "$TS_T" && TS_RW=1
[ "$TS_RW" = 1 ] && [ ! -e "$TS_H1" ] && [ -z "$(trash_holds "$TS_T")" ] \
  && ok "trash_commit seals the hold and a detached reaper deletes the entry" \
  || fail "commit and reap: idle=$TS_RW hold left=$([ -e "$TS_H1" ] && echo y) holds=$(trash_holds "$TS_T") entries=$(trash_entries "$TS_T")"
# The admin's back-pointer names another path BEFORE the move: nothing moves and the admin is kept.
ts_wt .integrate-1-2; TS_A2="$(ts_adm "$TS_W/.integrate-1-2")"
printf '%s\n' "$TS/elsewhere/.git" > "$TS_A2/gitdir"
TS_O="$(ts_fn trash_tree "$TS_GD" "$TS_T" integrate "$TS_W/.integrate-1-2")"
[ "$(ts_rc "$TS_O")" = 1 ] && [ -f "$TS_W/.integrate-1-2/f.txt" ] && [ "$(cat "$TS_A2/gitdir" 2>/dev/null)" = "$TS/elsewhere/.git" ] \
  && [ -z "$(trash_holds "$TS_T")" ] \
  && ok "an admin whose gitdir names another path before the move is kept, and nothing moves (1)" \
  || fail "repointed before the move: rc=$(ts_rc "$TS_O") holds=$(trash_holds "$TS_T")"
printf '%s\n' "$TS_W/.integrate-1-2/.git" > "$TS_A2/gitdir"
# ... and AFTER the rename (git freed the name and handed it to another tree): kept, result 2.
ts_wt .integrate-1-3; TS_A3="$(ts_adm "$TS_W/.integrate-1-3")"
TS_O="$(TS_REPOINT_ADM="$TS_A3" TS_REPOINT_TO="$TS_W/other/.git" COMMS_TEST_TRASH_HOOK="$TS/hook-repoint" \
  ts_fn trash_tree "$TS_GD" "$TS_T" integrate "$TS_W/.integrate-1-3")"; TS_H3="$(ts_hold "$TS_O")"
[ "$(ts_rc "$TS_O")" = 2 ] && [ -f "$TS_H3/payload/f.txt" ] && [ ! -e "$TS_W/.integrate-1-3" ] \
  && [ -d "$TS_A3" ] && [ "$(cat "$TS_A3/gitdir" 2>/dev/null)" = "$TS_W/other/.git" ] \
  && ok "an admin whose gitdir names another tree after the rename is kept, and the result is 2 (held, registration left)" \
  || fail "repointed after the rename: rc=$(ts_rc "$TS_O") hold=$TS_H3 admin=$([ -d "$TS_A3" ] && echo kept)"
ts_fn trash_commit "$TS_T" "$TS_H3" >/dev/null; rm -rf "$TS_A3"
# A relative gitfile (worktree.useRelativePaths) is not judged: nothing moves.
ts_wt .integrate-1-4; TS_A4="$(ts_adm "$TS_W/.integrate-1-4")"
printf 'gitdir: ../../../.git/worktrees/%s\n' "${TS_A4##*/}" > "$TS_W/.integrate-1-4/.git"
TS_O="$(ts_fn trash_tree "$TS_GD" "$TS_T" integrate "$TS_W/.integrate-1-4")"
[ "$(ts_rc "$TS_O")" = 1 ] && [ -f "$TS_W/.integrate-1-4/f.txt" ] && [ -d "$TS_A4" ] \
  && ok "a relative gitfile returns 1 and moves nothing" || fail "relative gitfile: rc=$(ts_rc "$TS_O")"
printf 'gitdir: %s\n' "$TS_A4" > "$TS_W/.integrate-1-4/.git"
# A PAUSE between the rename and the checks: a reaper that runs to completion meanwhile never
# touches the hold or the moved .git it is about to read.
ts_wt .integrate-1-5; TS_A5="$(ts_adm "$TS_W/.integrate-1-5")"
TS_RW=0; reap_wait "$TS_T" && TS_RW=1
: > "$TS/held.log"; : > "$TS/reap5.log"; rm -f "$TS/release5"
( TS_HOOK_LOG="$TS/held.log" TS_BLOCK_AT=held TS_RELEASE="$TS/release5" COMMS_TEST_TRASH_HOOK="$TS/hook-block" \
    ts_fn trash_tree "$TS_GD" "$TS_T" integrate "$TS_W/.integrate-1-5" > "$TS/held.out" ) &
TS_BG=$!
TS_READY=0; wait_until grep -q '^held ' "$TS/held.log" && TS_READY=1
TS_H5="$(awk '$1=="held"{print $2; exit}' "$TS/held.log")"
COMMS_TEST_REAP_HOOK="$TS/hook-block" TS_HOOK_LOG="$TS/reap5.log" ts_fn trash_reap_start repo "$TS_R" >/dev/null
TS_RAN=0; wait_until grep -q '^locked ' "$TS/reap5.log" && wait_until reap_idle "$TS_T" && TS_RAN=1
if [ "$TS_RW" = 1 ] && [ "$TS_READY" = 1 ] && [ "$TS_RAN" = 1 ] && [ -f "$TS_H5/owner" ] && [ -f "$TS_H5/payload/f.txt" ] \
   && [ "$(cat "$TS_H5/payload/.git" 2>/dev/null)" = "gitdir: $TS_A5" ] && [ -d "$TS_A5" ]; then
  ok "a reaper that runs to completion while a put is held leaves the hold and its moved .git untouched"
else
  fail "held put vs reaper: ready=$TS_READY ran=$TS_RAN hold=$TS_H5 $(ls -A "$TS_H5" 2>/dev/null | tr '\n' ' ')"
fi
touch "$TS/release5"; wait "$TS_BG" 2>/dev/null
TS_O="$(cat "$TS/held.out" 2>/dev/null)"
ts_fn trash_commit "$TS_T" "$TS_H5" >/dev/null
TS_RW=0; reap_wait "$TS_T" && TS_RW=1
[ "$(ts_rc "$TS_O")" = 0 ] && [ ! -e "$TS_A5" ] && [ "$TS_RW" = 1 ] && [ ! -e "$TS_H5" ] && [ -z "$(trash_holds "$TS_T")" ] \
  && ok "released, trash_tree finishes its checks (0, admin dropped) and the committed entry is reaped" \
  || fail "after release: out='$TS_O' admin=$([ -e "$TS_A5" ] && echo kept) idle=$TS_RW"
# A MAKER THAT DIES HOLDING: the next reaper proves the death, commits and deletes its hold, and
# leaves alone the hold of a maker that is still alive.
ts_wt .integrate-1-6; TS_A6="$(ts_adm "$TS_W/.integrate-1-6")"
COMMS_TEST_TRASH_HOOK="$TS/hook-kill" ts_fn trash_tree "$TS_GD" "$TS_T" integrate "$TS_W/.integrate-1-6" >/dev/null 2>&1
TS_H6="$(trash_holds "$TS_T" | head -1)"; TS_H6="${TS_H6:+$TS_T/$TS_H6}"
ts_wt .integrate-1-7
: > "$TS/held7.log"; : > "$TS/reap7.log"; rm -f "$TS/release7"
( TS_HOOK_LOG="$TS/held7.log" TS_BLOCK_AT=held TS_RELEASE="$TS/release7" COMMS_TEST_TRASH_HOOK="$TS/hook-block" \
    ts_fn trash_tree "$TS_GD" "$TS_T" integrate "$TS_W/.integrate-1-7" > "$TS/held7.out" ) &
TS_BG=$!
TS_READY=0; wait_until grep -q '^held ' "$TS/held7.log" && TS_READY=1
TS_H7="$(awk '$1=="held"{print $2; exit}' "$TS/held7.log")"
COMMS_TEST_REAP_HOOK="$TS/hook-block" TS_HOOK_LOG="$TS/reap7.log" ts_fn trash_reap_start repo "$TS_R" >/dev/null
TS_RAN=0; wait_until grep -q '^locked ' "$TS/reap7.log" && wait_until reap_idle "$TS_T" && TS_RAN=1
if [ -n "$TS_H6" ] && [ "$TS_H6" != "$TS_H7" ] && [ "$TS_READY" = 1 ] && [ "$TS_RAN" = 1 ] && [ ! -e "$TS_H6" ] \
   && grep -q "^before-delete $TS_T/${TS_H6##*/.hold.} " "$TS/reap7.log" && [ -f "$TS_H7/payload/f.txt" ]; then
  ok "a hold whose maker was SIGKILLed is committed and deleted by the next reaper; a live maker's hold is left alone"
else
  fail "dead maker: dead=$TS_H6 live=$TS_H7 ran=$TS_RAN left=$([ -e "$TS_H6" ] && echo y) log=$(tr '\n' '|' < "$TS/reap7.log")"
fi
touch "$TS/release7"; wait "$TS_BG" 2>/dev/null
ts_fn trash_commit "$TS_T" "$TS_H7" >/dev/null
git -C "$TS_R" worktree prune >/dev/null 2>&1   # the killed maker's registration (registered-but-missing)
TS_RW=0; reap_wait "$TS_T" && TS_RW=1
[ "$TS_RW" = 1 ] && [ -z "$(trash_holds "$TS_T")" ] && [ -n "$TS_A6" ] \
  && ok "fixture: the live maker finishes and its entry is reaped too" || fail "live maker cleanup: idle=$TS_RW holds=$(trash_holds "$TS_T")"

section "trash: one reaper per trash, and a killed reaper's half-done delete is finished by the next"
: > "$TS/r6.log"; rm -f "$TS/release6"
COMMS_TEST_REAP_HOOK="$TS/hook-block" TS_HOOK_LOG="$TS/r6.log" TS_BLOCK_AT=locked TS_RELEASE="$TS/release6" \
  ts_fn trash_reap_start repo "$TS_R" >/dev/null
TS_READY=0; wait_until grep -q '^locked ' "$TS/r6.log" && TS_READY=1
COMMS_TEST_REAP_HOOK="$TS/hook-block" TS_HOOK_LOG="$TS/r6.log" ts_fn trash_reap_start repo "$TS_R" >/dev/null
COMMS_TEST_REAP_HOOK="$TS/hook-block" TS_HOOK_LOG="$TS/r6.log" ts_fn trash_reap_start repo "$TS_R" >/dev/null
TS_NP="$(reaper_count "$TS_T")"
TS_NL="$(grep -c '^locked ' "$TS/r6.log")"
touch "$TS/release6"
TS_RW=0; reap_wait "$TS_T" && TS_RW=1
[ "$TS_READY" = 1 ] && [ "$TS_NP" = 1 ] && [ "$TS_NL" = 1 ] && [ "$TS_RW" = 1 ] \
  && ok "while one reaper holds the lock, a second and third start run nothing: one reaper process, one 'locked'" \
  || fail "lock: ready=$TS_READY processes=$TS_NP locked=$TS_NL idle=$TS_RW"
cat > "$TS/hook-partial" <<'EOF'
#!/bin/bash
printf '%s %s %s\n' "$1" "$2" "$PPID" >> "$TS_HOOK_LOG"
[ "$1" = before-delete ] || exit 0
rm -f "$2/payload/f1" "$2/payload/f2"
n=0; while [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
exit 0
EOF
chmod +x "$TS/hook-partial"
mkdir -p "$TS/victim"; for TS_I in 1 2 3 4 5; do printf '%s\n' "$TS_I" > "$TS/victim/f$TS_I"; done
: > "$TS/r6b.log"
TS_O="$(ts_fn trash_put "$TS_T" verify "$TS/victim")"
COMMS_TEST_REAP_HOOK="$TS/hook-partial" TS_HOOK_LOG="$TS/r6b.log" ts_fn trash_commit "$TS_T" "$(ts_hold "$TS_O")" >/dev/null
TS_READY=0; wait_until grep -q '^before-delete ' "$TS/r6b.log" && TS_READY=1
TS_RP="$(awk '$1=="before-delete"{print $3; exit}' "$TS/r6b.log")"
TS_PG="$(ps -o pgid= -p "${TS_RP:-0}" 2>/dev/null | tr -d ' ')"
TS_MYPG="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
TS_KILLED=0
if [ -n "$TS_PG" ] && [ "$TS_PG" != "$TS_MYPG" ]; then kill -KILL -- "-$TS_PG" 2>/dev/null && TS_KILLED=1; fi
TS_GONE=0; wait_until process_stopped "${TS_RP:-0}" && TS_GONE=1
TS_E="$(trash_entries "$TS_T")"
if [ "$TS_READY" = 1 ] && [ "$TS_KILLED" = 1 ] && [ "$TS_GONE" = 1 ] && [ "$(printf '%s\n' "$TS_E" | grep -c .)" = 1 ] \
   && [ ! -e "$TS_T/$TS_E/payload/f1" ] && [ -f "$TS_T/$TS_E/payload/f3" ]; then
  ok "a reaper SIGKILLed mid-delete (its whole process group) leaves one half-deleted, well-named entry"
else
  fail "kill mid-delete: ready=$TS_READY pg=$TS_PG mine=$TS_MYPG killed=$TS_KILLED gone=$TS_GONE entries=$TS_E"
fi
ts_fn trash_reap_start repo "$TS_R" >/dev/null
TS_RW=0; reap_wait "$TS_T" && TS_RW=1
[ "$TS_RW" = 1 ] && [ -n "$TS_E" ] && [ ! -e "$TS_T/$TS_E" ] && [ ! -e "$TS/victim" ] \
  && ok "the kernel freed the killed reaper's lock, and the next start deletes the rest" \
  || fail "after the kill: idle=$TS_RW entry=$TS_E left=$([ -e "$TS_T/$TS_E" ] && echo y)"
# Manual runs cannot share a trash: the reaper refuses (2) unless fd 9 holds the trash's lock.
TS_M1=0; "$REPO/helpers/runphase.sh" reap --repo "$TS_R" >/dev/null 2>&1 || TS_M1=$?
TS_M2=0; COMMS_TRASH_LOCK_FD=9 "$REPO/helpers/runphase.sh" reap --repo "$TS_R" 9>"$TS/not-the-lock" >/dev/null 2>&1 || TS_M2=$?
[ "$TS_M1" = 2 ] && [ "$TS_M2" = 2 ] \
  && ok "a reap run without the trash's lock on fd 9 refuses (exit 2)" || fail "manual reap: rc=$TS_M1/$TS_M2"

section "trash: the store sweep applies the 120-minute aside horizon to every ident"
TS_S="$TS/store"; TS_K="$(printf 'a%.0s' $(seq 1 64))"; TS_ST="$TS_S/.comms-trash"
mkdir -p "$TS_S/$TS_K/quiet" "$TS_S/$TS_K/busy" "$TS_S/$TS_K/other/.aside.fresh" "$TS_S/$TS_K/.retire.x.AbCdEf"
ts_aside() { mkdir -p "$1/held" && printf 'x\n' > "$1/held/x" && ts_age "$1" "$2"; }   # <dir> <minutes old>
ts_aside "$TS_S/$TS_K/quiet/.aside.old111" 121; ts_aside "$TS_S/$TS_K/busy/.aside.old222" 121
ts_aside "$TS_S/$TS_K/.retire.x.AbCdEf/.aside.old333" 121
sleep 300 </dev/null >/dev/null 2>&1 & TS_LIVE=$!
TS_LSTART="$(LC_ALL=C TZ=UTC ps -p "$TS_LIVE" -o lstart= | tr -s ' ' | sed 's/^ *//; s/ *$//')"
printf 'pid=%s\nfmt=v2\nstart=%s\nrun=live\n' "$TS_LIVE" "$TS_LSTART" > "$TS_S/$TS_K/busy/.claim.0"
ts_aside "$TS_S/$TS_K/quiet/.aside.new111" 119
# Another ident's put starts the reaper; nothing restages quiet or busy.
TS_O="$(ts_fn trash_put "$TS_ST" aside "$TS_S/$TS_K/other/.aside.fresh")"
ts_fn trash_commit "$TS_ST" "$(ts_hold "$TS_O")" >/dev/null
TS_RW=0; reap_wait "$TS_ST" && TS_RW=1
if [ "$(ts_rc "$TS_O")" = 0 ] && [ "$TS_RW" = 1 ] && [ ! -e "$TS_S/$TS_K/other/.aside.fresh" ] \
   && [ ! -e "$TS_S/$TS_K/quiet/.aside.old111" ] && [ -f "$TS_S/$TS_K/quiet/.aside.new111/held/x" ]; then
  ok "a reap another ident's put started moves a 121-minute aside of an ident that never restages, and keeps a 119-minute one"
else
  fail "store sweep: put=$(ts_rc "$TS_O") idle=$TS_RW old=$([ -e "$TS_S/$TS_K/quiet/.aside.old111" ] && echo kept) new=$([ -e "$TS_S/$TS_K/quiet/.aside.new111" ] && echo kept)"
fi
[ -f "$TS_S/$TS_K/busy/.aside.old222/held/x" ] && [ -f "$TS_S/$TS_K/.retire.x.AbCdEf/.aside.old333/held/x" ] \
  && ok "an expired aside is kept on an ident a live process holds, and the sweep never enters a tombstone" \
  || fail "store sweep took a held ident's aside or entered a tombstone"
kill "$TS_LIVE" 2>/dev/null; wait "$TS_LIVE" 2>/dev/null

section "trash: a leaked integrate or verify tree is swept only once its owner is proven dead"
sleep 300 </dev/null >/dev/null 2>&1 & TS_LIVE=$!
TS_LSTART="$(LC_ALL=C TZ=UTC ps -p "$TS_LIVE" -o lstart= | tr -s ' ' | sed 's/^ *//; s/ *$//')"
TS_D1="$(ts_dead_pid)"; TS_D2="$(ts_dead_pid)"
ts_owner() { printf 'pid=%s\nfmt=v2\nstart=%s\n' "$2" "$3" > "$(ts_adm "$1")/agent-comms-owner"; }   # <tree> <pid> <start>
TS_OK=1
ts_wt ".integrate-$TS_D1-11" && ts_owner "$TS_W/.integrate-$TS_D1-11" "$TS_D1" "Thu Jan  1 00:00:00 1970" || TS_OK=0
ts_wt ".integrate-$TS_LIVE-12" && ts_owner "$TS_W/.integrate-$TS_LIVE-12" "$TS_LIVE" "Thu Jan  1 00:00:00 1970" || TS_OK=0
ts_wt ".integrate-$TS_D2" || TS_OK=0
ts_wt ".verify-$TS_LIVE-13" && ts_owner "$TS_W/.verify-$TS_LIVE-13" "$TS_LIVE" "$TS_LSTART" || TS_OK=0
ts_wt ".integrate-abcdefgh12" && ts_age "$TS_W/.integrate-abcdefgh12" 4320 || TS_OK=0
ts_fn trash_reap_start repo "$TS_R" >/dev/null
TS_RW=0; reap_wait "$TS_T" && TS_RW=1
if [ "$TS_OK" = 1 ] && [ "$TS_RW" = 1 ] \
   && [ ! -e "$TS_W/.integrate-$TS_D1-11" ] && ! ts_reg "$TS_W/.integrate-$TS_D1-11" \
   && [ ! -e "$TS_W/.integrate-$TS_LIVE-12" ] && ! ts_reg "$TS_W/.integrate-$TS_LIVE-12" \
   && [ ! -e "$TS_W/.integrate-$TS_D2" ] && ! ts_reg "$TS_W/.integrate-$TS_D2"; then
  ok "swept: a dead recorded owner, a live pid whose start differs from the record, and a legacy .integrate-<pid> whose pid is dead"
else
  fail "leaked-tree sweep: fixture=$TS_OK idle=$TS_RW left: $(ls -A "$TS_W" | tr '\n' ' ')"
fi
[ -f "$TS_W/.verify-$TS_LIVE-13/f.txt" ] && ts_reg "$TS_W/.verify-$TS_LIVE-13" \
  && [ -f "$TS_W/.integrate-abcdefgh12/f.txt" ] && ts_reg "$TS_W/.integrate-abcdefgh12" \
  && ok "kept: a tree its live owner records, and a legacy instance-named tree with no record however old" \
  || fail "the sweep took a live or unprovable tree: $(ls -A "$TS_W" | tr '\n' ' ')"
kill "$TS_LIVE" 2>/dev/null; wait "$TS_LIVE" 2>/dev/null
