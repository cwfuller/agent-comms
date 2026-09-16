# Run through tests/run.sh; each group gets fresh fixtures.
fixture_ma_archive
fixture_acp
section "runphase: warm ACP mounts live at a stable per-(thread,agent) path"
# The defect: run_dir is per-message, so mounting at $run_dir/tree gave acpx a NEW cwd
# every round. acpx keys session identity on (agent, cwd, name) and compares cwd as a
# string, so every mounted panel leg was a fresh session while the session NAME looked
# stable -- 210 such records on the development machine, none ever reused.
#
# Every cwd claim below is read from a file the CHILD wrote from inside its own working
# directory. Nothing here greps runphase.sh for a path expression: that is a string match
# that would stay green through any refactor which dropped the behaviour.
WM="$WORK/warm-mount"; mkdir -p "$WM"
# Mounts now live OUTSIDE the repo, under a validated base. Point COMMS_MOUNT_BASE at a
# throwaway so the suite never writes the developer's real ~/.local/state, and record the
# physical store prefix ($base/agent-comms/mounts, where <repo-key>/<ident> land under it).
WM_MBASE="$WM/mbase"; mkdir -p "$WM_MBASE"; WM_MBASE="$(cd "$WM_MBASE" && pwd -P)"
WM_STORE="$WM_MBASE/agent-comms/mounts"
# Every mounted turn runs against a TEST acpx store. The marker is what licenses the stub to
# write a session record at all, so a turn that forgets to point HOME here writes nothing
# rather than into the developer's real ~/.acpx.
mkdir -p "$WM/home/.acpx/sessions" "$WM/home/.acpx/queues"; : > "$WM/home/.acpx-test-store"
# The stable path is gated on `.comms` being ignore-covered, because a durable mount that
# snapshot-on-send could capture would put a second checkout into every artifact.
printf '.comms/\n' > "$MA_FIX/.gitignore"
# Two DISTINCT pinned artifacts, so "which round's tree did the child see" is answerable.
# They are dangling commits off the fixture HEAD; the live tree carries neither marker,
# which is what makes "the child saw a marker" mean "the child was inside a mount".
wm_artifact() { # <marker> -> commit sha
  local marker="$1" t
  printf '%s\n' "$marker" > "$MA_FIX/mount-marker.txt"
  t="$(cd "$MA_FIX" && GIT_INDEX_FILE="$WM/idx.$marker" git add -A -- . >/dev/null 2>&1; \
       GIT_INDEX_FILE="$WM/idx.$marker" git -C "$MA_FIX" write-tree 2>/dev/null)"
  rm -f "$MA_FIX/mount-marker.txt"
  git -C "$MA_FIX" -c user.email=t@t -c user.name=t commit-tree "$t" -p HEAD -m "artifact $marker" 2>/dev/null
}
WM_A1="$(wm_artifact round-1)"; WM_A2="$(wm_artifact round-2)"
WM_HEAD="$(git -C "$MA_FIX" rev-parse HEAD)"
WM_ROOT="$(cd "$MA_FIX" && env "$COMMS" root)"
if [ -n "$WM_A1" ] && [ -n "$WM_A2" ] && [ "$WM_A1" != "$WM_A2" ] \
   && git -C "$MA_FIX" cat-file -e "${WM_A1}^{commit}" 2>/dev/null \
   && [ ! -e "$MA_FIX/mount-marker.txt" ]; then
  ok "warm-mount fixture: two distinct artifacts resolve and the live tree carries no marker"
else
  fail "warm-mount fixture is not usable (a1=$WM_A1 a2=$WM_A2)"
fi

# Run one real mounted ACP turn. Returns the run dir it used.
# These turns drive the MOUNT LIFECYCLE, not containment, and they drive it as grok — which
# has no verified isolation backend on Darwin and is therefore refused by default now. They opt
# out explicitly rather than silently, so the refusal keeps its teeth everywhere else and the
# opt-out itself stays visible in this file. The refusal and the override are asserted directly
# in the isolation section below.
wm_turn() { # <thread> <tag> <artifact> [extra env assignments...]
  local thread="$1" tag="$2" art="$3"; shift 3
  local msg dir
  msg="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T10-00-00_wm-$tag.md"
  { head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
    printf 'artifact_id: %s\nhead_sha: %s\n' "$art" "$WM_HEAD"
    tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" \
      | sed -e "s|^thread: ma-arc-1\$|thread: $thread|"
  } > "$msg"
  dir="$WM/run-$tag"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" \
      HOME="$WM/home" \
      COMMS_MOUNT_BASE="$WM_STORE" \
      ACP_PARITY_PAYLOAD="$AXD/payload" AX_CWD_LOG="$WM/cwd.log" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_RUNPHASE_OWNER_WAIT_SECS=3 \
      COMMS_RUNPHASE_ALLOW_UNCONTAINED=1 \
      "$@" "$RP" run --message "$msg" --dir "$dir" \
      --provider grok --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}
wm_prompt_cwds() { # cwds of the PROMPT invocations only (not `sessions ensure`/`show`)
  awk -F'\t' '$2 !~ /sessions (ensure|show)/ {print $1}' "$WM/cwd.log" 2>/dev/null
}
# Deriving a kdir from a cwd that was never recorded yields "" and then `dirname` yields ".",
# and every subsequent rm/printf lands in the REPO ROOT. One such run left .state.pending and
# an ma-repo symlink in this checkout. Refuse to hand back anything but a real mount dir.
wm_kdir_of() {  # <prompt cwd = .../<ident>/view/tree> -> the ident dir, or empty
  local c="$1" v d
  case "$c" in ''|.|./*) printf ''; return 1 ;; esac
  # The mount cwd is <ident>/view/tree now, so the ident (state/claim/restage) dir is two up.
  v="$(dirname "$c")"; case "$v" in ''|.|/) printf ''; return 1 ;; esac
  d="$(dirname "$v")"; case "$d" in ''|.|/) printf ''; return 1 ;; esac
  [ -d "$d" ] || { printf ''; return 1; }
  # Only a real ident dir under this fixture's EXTERNAL store (base/<repo-key>/<ident>)
  # qualifies, so a fixture can never mutate some other parent.
  case "$d" in "$WM_STORE"/*/*) ;; *) printf ''; return 1 ;; esac
  printf '%s' "$d"
}
# A degrade must land on an EXTERNAL THROWAWAY (base/<repo-key>/tmp-*/view/tree), never the old
# $run_dir/tree and never in-repo. Pure string checks: the throwaway is removed at turn end.
wm_is_throwaway() {  # <cwd> <run_dir> -> 0 if an external throwaway distinct from run_dir/repo
  local c="$1" rd="$2" rp
  case "$c" in "$WM_STORE"/*/tmp-*/view/tree) ;; *) return 1 ;; esac
  rp="$(cd "$rd" 2>/dev/null && pwd -P)" || rp=""
  [ -n "$rp" ] && case "$c" in "$rp"/*) return 1 ;; esac
  case "$c" in "$WM_ROOT"/*) return 1 ;; esac
  return 0
}
wm_status() { sed -n 's/.*"status": "\([a-z]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }

printf 'VERDICT: APPROVE\n\n## Summary\nstub\n\n### Blocking\n- None.\n' > "$AXD/payload"
: > "$WM/cwd.log"
WM_D1="$(wm_turn wm-seq wm1 "$WM_A1" AX_CHILD_WRITE=round-1-was-here)"
WM_D2="$(wm_turn wm-seq wm2 "$WM_A2")"
WM_C1="$(wm_prompt_cwds | sed -n 1p)"; WM_C2="$(wm_prompt_cwds | sed -n 2p)"

# NON-VACUITY GATES. Without these, every assertion below can pass by never running.
[ "$(wm_prompt_cwds | awk 'END{print NR+0}')" -ge 2 ] \
  && ok "two mounted ACP turns really invoked the child" \
  || fail "the mounted child never ran — every warm-mount assertion below would be vacuous"
[ -n "$WM_D1" ] && [ -n "$WM_D2" ] && [ "$WM_D1" != "$WM_D2" ] \
  && ok "the two rounds really used different per-message run dirs" \
  || fail "run dirs did not differ, so a shared cwd proves nothing"

# AC1 — and this is the assertion that FAILS under the old $run_dir/tree scheme, because
# there the two cwds would be $WM_D1/tree and $WM_D2/tree.
[ -n "$WM_C1" ] && [ "$WM_C1" = "$WM_C2" ] \
  && ok "two sequential mounted rounds invoke acpx from the SAME cwd" \
  || fail "mounted rounds used different cwds (r1=$WM_C1 r2=$WM_C2)"
case "$WM_C1" in
  "$(cd "$WM_D1" && pwd -P)"/*|"$(cd "$WM_D2" && pwd -P)"/*)
    fail "the mount is still inside a per-message run dir ($WM_C1)" ;;
  *) ok "the mount is not inside either per-message run dir" ;;
esac
case "$WM_C1" in
  "$WM_STORE"/*/*/view/tree) ok "the mount lives OUTSIDE the repo, under the validated external store's <repo-key>/<ident>/view/tree" ;;
  *) fail "the mount is somewhere unexpected ($WM_C1)" ;;
esac
# A function of (thread, agent) only: neither message id may appear in the path.
case "$WM_C1" in
  *wm-wm1*|*wm-wm2*) fail "the mount path carries a message id ($WM_C1)" ;;
  *) ok "the mount path is a function of (thread, agent), not of the message" ;;
esac

# Each round must have restaged ITS OWN artifact, not kept round 1's.
[ "$(cat "$WM_D2/tree-marker" 2>/dev/null || true)" = "" ] && true
WM_M2="$(cd "$WM_C1" 2>/dev/null && cat mount-marker.txt 2>/dev/null || true)"
[ "$WM_M2" = "round-2" ] \
  && ok "the mount holds round 2's artifact after round 2 restaged it" \
  || fail "the mount does not hold round 2's artifact (marker=${WM_M2:-<none>})"
# Round 1's child wrote into its own mount, so the turn must be REFUSED rather than
# stamped: a verdict over a tree that is no longer the pinned artifact is exactly the
# silent-wrong-review this whole arc exists to prevent.
if [ "$(wm_status "$WM_D1")" = "failed" ] \
   && grep -q 'stopped matching artifact' "$WM_D1/result.json" 2>/dev/null; then
  ok "a child that contaminates its mount during the turn is refused, not stamped"
else
  fail "a contaminated mount was stamped anyway (status=$(wm_status "$WM_D1"))"
fi
[ "$(wm_status "$WM_D2")" = "completed" ] \
  && ok "a clean warm-mounted round completes and brokers a reply" \
  || fail "the clean warm-mounted round did not complete (status=$(wm_status "$WM_D2"))"

# AC3 — a previous --approve-all child's writes must not survive into the next round, at
# an untracked path OR an ignored one (the class a plain `git clean -fd` misses).
[ ! -e "$WM_C1/child-residue.txt" ] \
  && ok "round N+1's mount carries no untracked residue from round N" \
  || fail "round N's untracked write survived into round N+1"
[ ! -e "$WM_C1/.comms/child-ignored.txt" ] \
  && ok "round N+1's mount carries no IGNORED-path residue from round N" \
  || fail "round N's ignored-path write survived into round N+1"

# AC4 — a different leg thread is a different mount, and they do not collide.
: > "$WM/cwd.log"; WM_D3="$(wm_turn wm-seq-other wm3 "$WM_A1")"
WM_C3="$(wm_prompt_cwds | sed -n 1p)"
[ -n "$WM_C3" ] && [ "$WM_C3" != "$WM_C1" ] \
  && ok "a different leg thread gets its own mount" \
  || fail "two leg threads shared a mount ($WM_C3)"

# `safe_name` maps `a/b` and `a_b` onto one token, and the path is derived from the thread.
# Under a stable cwd that collapse would put two threads in one warm session.
: > "$WM/cwd.log"; wm_turn 'wm/collide' wm4 "$WM_A1" >/dev/null
WM_C4="$(wm_prompt_cwds | sed -n 1p)"
: > "$WM/cwd.log"; wm_turn 'wm_collide' wm5 "$WM_A1" >/dev/null
WM_C5="$(wm_prompt_cwds | sed -n 1p)"
[ -n "$WM_C4" ] && [ -n "$WM_C5" ] && [ "$WM_C4" != "$WM_C5" ] \
  && ok "threads that safe_name collapses still get separate mounts" \
  || fail "a safe_name collision put two threads in one mount ($WM_C4)"

# AC6 — a tree that carries its own acpx project config would choose the reviewer.
WM_A_RC="$( printf 'x\n' > "$MA_FIX/.acpxrc.json"; \
  t="$(cd "$MA_FIX" && GIT_INDEX_FILE="$WM/idx.rc" git add -A -- . >/dev/null 2>&1; \
       GIT_INDEX_FILE="$WM/idx.rc" git -C "$MA_FIX" write-tree)"; \
  rm -f "$MA_FIX/.acpxrc.json"; \
  git -C "$MA_FIX" -c user.email=t@t -c user.name=t commit-tree "$t" -p HEAD -m rc )"
: > "$WM/cwd.log"; WM_D6="$(wm_turn wm-rc wm6 "$WM_A_RC")"
if [ "$(wm_status "$WM_D6")" = "failed" ] && [ "$(wm_prompt_cwds | awk 'END{print NR+0}')" = "0" ]; then
  ok "a mounted tree carrying .acpxrc.json is refused before the agent is spawned"
else
  fail "a tree with .acpxrc.json was reviewed anyway (status=$(wm_status "$WM_D6"))"
fi

# AC5 — the bound record's cwd must BE the mount. acpx resolves a session by walking from
# cwd up to the git root, and a linked worktree's .git is a FILE, so the walk escapes the
# mount and can bind an ancestor record whose cwd is the live tree.
: > "$WM/cwd.log"; WM_D7="$(wm_turn wm-lie wm7 "$WM_A1" AX_LIE_CWD="$MA_FIX")"
if [ "$(wm_status "$WM_D7")" = "failed" ] && [ "$(wm_prompt_cwds | awk 'END{print NR+0}')" = "0" ]; then
  ok "a session bound outside the mount refuses the turn BEFORE the prompt"
else
  fail "a session bound at the live tree was prompted anyway (status=$(wm_status "$WM_D7"))"
fi

# AC2 — a crashed child can leave the mount path as a symlink at the main checkout.
# `find`-style emptying is a no-op through a symlink and `worktree add` writes through it,
# so the restage must move the LINK aside without ever dereferencing it.
WM_MAIN_BEFORE="$(git -C "$MA_FIX" status --porcelain)"
rm -rf "$WM_C1"; ln -s "$MA_FIX" "$WM_C1"
: > "$WM/cwd.log"; WM_D8="$(wm_turn wm-seq wm8 "$WM_A1")"
WM_C8="$(wm_prompt_cwds | sed -n 1p)"
if [ "$(git -C "$MA_FIX" status --porcelain)" = "$WM_MAIN_BEFORE" ] && [ -n "$WM_C8" ]; then
  ok "a mount vandalised into a symlink at the live tree restages without touching it"
else
  fail "restaging through a symlinked mount disturbed the main checkout"
fi

# Per-message state must stay per-message: only the TREE moved to a stable path.
[ -x "$WM_D1/shim/git" ] && [ -s "$WM_D1/result.json" ] && [ -s "$WM_D2/result.json" ] \
  && ok "the git shim, prompt and result.json stay per-message under the run dir" \
  || fail "per-message run-dir state went missing"

# --- the fail-closed and recovery paths, which the first pass asserted about but never ran.

# AC2 in full: a peer worktree must survive a restage, and the restaged tree must BE the
# artifact -- the first pass only compared the main checkout's `status --porcelain`.
git -C "$MA_FIX" worktree add --detach --quiet "$WM/peer" "$WM_HEAD" 2>/dev/null
WM_PEER_GITFILE="$(cat "$WM/peer/.git" 2>/dev/null)"
: > "$WM/cwd.log"; WM_D9="$(wm_turn wm-seq wm9 "$WM_A2")"
WM_C9="$(wm_prompt_cwds | sed -n 1p)"
if [ "$(cat "$WM/peer/.git" 2>/dev/null)" = "$WM_PEER_GITFILE" ] \
   && git -C "$WM/peer" rev-parse HEAD >/dev/null 2>&1; then
  ok "a restage leaves a peer worktree registered and usable"
else
  fail "a restage disturbed a peer worktree"
fi
# The mount IS the artifact, compared by tree identity rather than by status shape.
WM_WANT="$(git -C "$MA_FIX" rev-parse "${WM_A2}^{tree}")"
WM_HAVE="$( GIT_INDEX_FILE="$WM/vidx" git -C "$WM_C9" read-tree "$WM_A2" >/dev/null 2>&1; \
            GIT_INDEX_FILE="$WM/vidx" git -C "$WM_C9" add -A -- . >/dev/null 2>&1; \
            GIT_INDEX_FILE="$WM/vidx" git -C "$WM_C9" write-tree 2>/dev/null )"
[ -n "$WM_WANT" ] && [ "$WM_HAVE" = "$WM_WANT" ] \
  && ok "the restaged mount is byte-identical to the pinned artifact tree" \
  || fail "the restaged mount is not the artifact (have=$WM_HAVE want=$WM_WANT)"

# AC4 properly: two panelists CONCURRENTLY, on different leg threads, must not collide.
: > "$WM/cwd.log"
# Separate logs per child: two writers appending to one file can tear a line, and a torn
# line would corrupt the uniqueness count this assertion rests on.
( wm_turn wm-par-a wmA "$WM_A1" AX_CWD_LOG="$WM/cwd.a" >"$WM/pa.out" 2>&1 ) &
( wm_turn wm-par-b wmB "$WM_A1" AX_CWD_LOG="$WM/cwd.b" >"$WM/pb.out" 2>&1 ) &
wait
WM_PA="$(cat "$WM/pa.out" 2>/dev/null)"; WM_PB="$(cat "$WM/pb.out" 2>/dev/null)"
if [ "$(wm_status "$WM_PA")" = "completed" ] && [ "$(wm_status "$WM_PB")" = "completed" ] \
   && [ "$(awk -F'\t' '$2 !~ /sessions (ensure|show)/ {print $1}' "$WM/cwd.a" "$WM/cwd.b" 2>/dev/null | sort -u | wc -l | tr -d ' ')" = 2 ]; then
  ok "two CONCURRENT panelists get two distinct mounts and both complete"
else
  fail "concurrent panelists collided (a=$(wm_status "$WM_PA") b=$(wm_status "$WM_PB"))"
fi

# The ident includes the AGENT, so one thread reviewed by two providers cannot share a
# worktree. `shadow` does exactly this, concurrently, by design.
WM_IDENT_G="$(basename "$(wm_kdir_of "$WM_C9" || echo /none)")"
case "$WM_IDENT_G" in
  *-grok) ok "the mount ident carries the reviewing agent, so two providers cannot share one" ;;
  *) fail "the mount ident does not name the agent ($WM_IDENT_G)" ;;
esac

# CRASH WINDOW 1 — interrupted after `worktree add`, before the admin id was recorded.
# `.state.pending` names a registered temp worktree; without recovery it leaks forever.
WM_KDIR="$(wm_kdir_of "$WM_C9" || true)"
if [ -z "$WM_KDIR" ] || [ ! -d "$WM_KDIR" ]; then
  fail "could not derive the mount dir for the crash-window fixture; its assertion would be vacuous"
  WM_KDIR="$WM/no-such-kdir"; mkdir -p "$WM_KDIR"
fi
git -C "$MA_FIX" worktree add --detach --quiet "$WM_KDIR/.new.crash1" "$WM_HEAD" 2>/dev/null
printf '%s\n' "$WM_KDIR/.new.crash1" > "$WM_KDIR/.state.pending"
: > "$WM/cwd.log"; WM_D10="$(wm_turn wm-seq wm10 "$WM_A1")"
if [ "$(wm_status "$WM_D10")" = "completed" ] && [ ! -e "$WM_KDIR/.new.crash1" ] \
   && ! git -C "$MA_FIX" worktree list --porcelain | grep -qxF "worktree $WM_KDIR/.new.crash1"; then
  ok "a pending generation left by a crash is reclaimed, not leaked"
else
  fail "a crashed pending generation survived the next restage (status=$(wm_status "$WM_D10") cwd=$(wm_prompt_cwds | sed -n 1p) leftover=$([ -e "$WM_KDIR/.new.crash1" ] && echo yes || echo no) reg=$(git -C "$MA_FIX" worktree list --porcelain | grep -cxF "worktree $WM_KDIR/.new.crash1") note=$(sed -n 's/.*"note": "\([^"]*\)".*/\1/p' "$WM_D10/result.json" 2>/dev/null | head -1 | cut -c1-90))"
fi

# CRASH WINDOW 2 — interrupted between `mv` and `worktree repair`: the recorded admin's
# back-pointer still names the temp path. The strict gitdir test alone would refuse this
# FOREVER, so the recipe repairs first and only then applies the test.
WM_ADM="$(cat "$WM_KDIR/.state.admin" 2>/dev/null)"
if [ -n "$WM_ADM" ] && [ -d "$WM_ADM" ]; then
  printf '%s\n' "$WM_KDIR/.new.stale/.git" > "$WM_ADM/gitdir"
  : > "$WM/cwd.log"; WM_D11="$(wm_turn wm-seq wm11 "$WM_A1")"
  [ "$(wm_status "$WM_D11")" = "completed" ] \
    && ok "an admin back-pointer left naming the temp path is repaired, not wedged" \
    || fail "a half-moved generation wedged the mount permanently (status=$(wm_status "$WM_D11"))"
else
  fail "could not stage the half-moved-generation fixture"
fi

# The mount CONTAINER is as attackable as the mount. A symlinked container must refuse
# outright rather than be followed, adopted, and written through.
WM_IDENT_DIR="$WM_KDIR"
rm -rf "$WM_IDENT_DIR"; ln -s "$MA_FIX" "$WM_IDENT_DIR"
WM_MAIN_B4="$(git -C "$MA_FIX" status --porcelain)"
: > "$WM/cwd.log"; WM_D12="$(wm_turn wm-seq wm12 "$WM_A1")"
WM_C12="$(wm_prompt_cwds | sed -n 1p)"
if [ "$(git -C "$MA_FIX" status --porcelain)" = "$WM_MAIN_B4" ] && [ -L "$WM_IDENT_DIR" ] \
   && [ -n "$WM_C12" ] && wm_is_throwaway "$WM_C12" "$WM/run-wm12"; then
  ok "a symlinked mount container degrades to the per-message path instead of being followed"
else
  fail "a symlinked container was followed, or the turn did not degrade as specified (cwd=$WM_C12)"
fi
rm -f "$WM_IDENT_DIR"

# The ephemeral (non-ACP) path must still clean up: a trap that merely stopped unmounting
# would leak one admin dir per direct grok turn.
WM_ADM_BEFORE="$(ls "$MA_FIX/.git/worktrees" 2>/dev/null | wc -l | tr -d ' ')"
WM_MSG13="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T10-00-00_wm-13.md"
{ head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
  printf 'artifact_id: %s\nhead_sha: %s\n' "$WM_A1" "$WM_HEAD"
  tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" | sed -e 's|^thread: ma-arc-1$|thread: wm-ephemeral|'
} > "$WM_MSG13"
mkdir -p "$WM/run-wm13"
( cd "$MA_FIX" && env PATH="$AXB:$STUB_BIN:$PATH" ACP_PARITY_PAYLOAD="$AXD/payload" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$WM_MSG13" --dir "$WM/run-wm13" \
    --provider grok --timeout-secs 20 ) >/dev/null 2>&1
# Count-in/count-out alone would also pass if the turn never mounted at all, so require
# positive evidence that it DID mount before believing the cleanup.
if ! grep -q '"status": "completed"' "$WM/run-wm13/result.json" 2>/dev/null; then
  fail "the non-ACP stub turn did not complete, so cleanup alone proves nothing"
elif ! grep -q '^mount: staged artifact ' "$WM/run-wm13/runner.log" 2>/dev/null; then
  fail "the non-ACP turn never STAGED a mount, so its unmount assertion would be vacuous"
elif [ "$(ls "$MA_FIX/.git/worktrees" 2>/dev/null | wc -l | tr -d ' ')" = "$WM_ADM_BEFORE" ]; then
  ok "a non-ACP grok turn still unmounts and leaves no admin dir behind"
else
  fail "the ephemeral mount path leaked an admin dir"
fi

# The quiescence boundary itself. Both legs flagged it as untested: the npx stub never
# creates a lease, so `mount_owner_wait` always returned immediately and its fail-closed
# behaviour was asserted about rather than exercised. Point HOME at a throwaway store and
# plant a lease at the path the runner derives, so the wait actually has something to see.
# (The real ~/.acpx is never touched.)
WM_HOME="$WM/fakehome"; mkdir -p "$WM_HOME/.acpx/queues" "$WM_HOME/.acpx/sessions"; : > "$WM_HOME/.acpx-test-store"
WM_LEASE_HASH="$(printf '%s' "stub-record-1" | shasum -a 256 | cut -c1-24)"
printf '{ "pid": 1, "sessionId": "stub-record-1" }\n' > "$WM_HOME/.acpx/queues/$WM_LEASE_HASH.lock"
: > "$WM/cwd.log"; WM_D14="$(wm_turn wm-lease wm14 "$WM_A1" HOME="$WM_HOME" AX_RECORD_ID=stub-record-1)"
# First turn on this ident records no id, so the wait is skipped; the SECOND turn reads it
# back and must find the planted lease still there.
: > "$WM/cwd.log"; WM_D15="$(wm_turn wm-lease wm15 "$WM_A1" HOME="$WM_HOME" AX_RECORD_ID=stub-record-1)"
if [ "$(wm_status "$WM_D15")" = "failed" ] \
   && grep -q 'refusing to restage under a live owner' "$WM_D15/result.json" 2>/dev/null \
   && [ "$(wm_prompt_cwds | awk 'END{print NR+0}')" = "0" ]; then
  ok "a queue lease that never disappears refuses the next turn instead of restaging under it"
else
  fail "a mount was restaged while its queue lease was still present (status=$(wm_status "$WM_D15"))"
fi
# ...and the same turn succeeds once the lease is gone, so the refusal above is not just
# "this path always fails".
rm -f "$WM_HOME/.acpx/queues/$WM_LEASE_HASH.lock"
: > "$WM/cwd.log"; WM_D16="$(wm_turn wm-lease wm16 "$WM_A1" HOME="$WM_HOME" AX_RECORD_ID=stub-record-1)"
[ "$(wm_status "$WM_D16")" = "completed" ] \
  && ok "the same mount restages normally once the queue lease has gone" \
  || fail "the lease check refuses even with no lease present (status=$(wm_status "$WM_D16"))"

# A record written before the owner-home field existed carries no `.state.home`. Refusing
# there is an UPGRADE failure, not a safety property -- and it is not hypothetical: it
# refused every leg of a live review panel on an existing thread before this fallback
# landed. The suite had no assertion for it because every fixture starts from an empty kdir.
WM_KDIR16="$(wm_kdir_of "$(wm_prompt_cwds | sed -n 1p)" || true)"
if [ -n "$WM_KDIR16" ] && [ -f "$WM_KDIR16/.state.record" ]; then
  rm -f "$WM_KDIR16/.state.home"
  : > "$WM/cwd.log"; WM_D17="$(wm_turn wm-lease wm17 "$WM_A1" HOME="$WM_HOME" AX_RECORD_ID=stub-record-1)"
  WM_C17="$(wm_prompt_cwds | sed -n 1p)"
  if [ "$(wm_status "$WM_D17")" = "completed" ] \
     && wm_is_throwaway "$WM_C17" "$WM/run-wm17"; then
    ok "a record predating the owner-home field degrades to the per-message path, not a wedge"
  else
    fail "a legacy record neither ran nor degraded (status=$(wm_status "$WM_D17") cwd=$WM_C17)"
  fi
  # ...and it must NOT have rebuilt the stable mount, whose owner it cannot prove is gone.
  [ -d "$WM_KDIR16/view/tree" ] \
    && ok "the stable mount is left untouched when ownership cannot be established" \
    || fail "an unprovable-ownership turn rebuilt the stable mount anyway"
  # ...and the fallback must NOT adopt a store the record does not live in: probing the
  # wrong queues would report "gone" and restage under a live owner. Point HOME at an empty
  # store with no sessions/<id>.json and require a refusal.
  rm -f "$WM_KDIR16/.state.home"
  WM_HOME2="$WM/fakehome2"; mkdir -p "$WM_HOME2/.acpx/queues" "$WM_HOME2/.acpx/sessions"; : > "$WM_HOME2/.acpx-test-store"
  : > "$WM/cwd.log"; WM_D18="$(wm_turn wm-lease wm18 "$WM_A1" HOME="$WM_HOME2" AX_RECORD_ID=stub-record-1)"
  WM_C18="$(wm_prompt_cwds | sed -n 1p)"
  if [ "$(wm_status "$WM_D18")" = "completed" ] \
     && wm_is_throwaway "$WM_C18" "$WM/run-wm18"; then
    ok "a foreign acpx store is never adopted; the turn degrades instead"
  else
    fail "the home fallback adopted a foreign store (status=$(wm_status "$WM_D18") cwd=$WM_C18)"
  fi
else
  fail "could not stage the legacy-record fixture (kdir=$WM_KDIR16)"
fi

# Two runners racing ONE ident from a stale claim. The old check-delete-relink sequence was
# not a compare-and-swap: both could judge the same holder stale, and the second would delete
# the FIRST's live claim and install its own, so both restaged one mount concurrently.
# Self-contained: derive the ident dir from a turn on THIS thread rather than reusing another
# test's, or the stale claim is seeded somewhere the racers never look.
: > "$WM/cwd.log"; WM_DR0="$(wm_turn wm-race wmR0 "$WM_A1")"
WM_KR="$(wm_kdir_of "$(wm_prompt_cwds | sed -n 1p)" || true)"
if [ -n "$WM_KR" ] && [ -d "$WM_KR" ] && [ "$(wm_status "$WM_DR0")" = "completed" ]; then
  rm -f "$WM_KR"/.claim.* 2>/dev/null
  ( exec true ) & WM_DEADPID=$!; wait "$WM_DEADPID" 2>/dev/null
  printf 'pid=%s\nfmt=v2\nstart=NOT-A-REAL-START\nrun=crashed\n' "$WM_DEADPID" > "$WM_KR/.claim.0"
  ( wm_turn wm-race wmR1 "$WM_A1" AX_CWD_LOG="$WM/cwd.r1" >"$WM/r1.out" 2>&1 ) &
  ( wm_turn wm-race wmR2 "$WM_A1" AX_CWD_LOG="$WM/cwd.r2" >"$WM/r2.out" 2>&1 ) &
  wait
  WM_R1="$(cat "$WM/r1.out" 2>/dev/null)"; WM_R2="$(cat "$WM/r2.out" 2>/dev/null)"
  WM_S1="$(wm_status "$WM_R1")"; WM_S2="$(wm_status "$WM_R2")"
  WM_NDONE=0
  [ "$WM_S1" = "completed" ] && WM_NDONE=$(( WM_NDONE + 1 ))
  [ "$WM_S2" = "completed" ] && WM_NDONE=$(( WM_NDONE + 1 ))
  if [ "$WM_NDONE" = 1 ]; then
    ok "two runners racing one ident from a stale claim: exactly one gets the mount"
  else
    fail "a stale claim was granted to $WM_NDONE runners at once (r1=$WM_S1 r2=$WM_S2)"
  fi
else
  fail "could not stage the claim-race fixture (kdir=$WM_KR status=$(wm_status "$WM_DR0"))"
fi

# A LIVE holder must survive a contender that started in a DIFFERENT wall-clock second. The
# recycle guard reads the holder's start time; a version of it that compared the CONTENDER's
# own start instead declared every live peer recycled and granted the mount twice. The earlier
# race fixture could not see that, because starting both contenders together makes `ps
# lstart`'s one-second granularity render the two values identical.
if [ -n "$WM_KR" ] && [ -d "$WM_KR" ]; then
  rm -f "$WM_KR"/.claim.* 2>/dev/null
  sleep 45 & WM_LIVE=$!
  WM_LSTART="$(LC_ALL=C TZ=UTC ps -p "$WM_LIVE" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/^ *//; s/ *$//')"
  printf 'pid=%s\nfmt=v2\nstart=%s\nrun=live-holder\n' "$WM_LIVE" "$WM_LSTART" > "$WM_KR/.claim.0"
  sleep 1.2
  : > "$WM/cwd.log"; WM_DL="$(wm_turn wm-race wmL1 "$WM_A1")"
  if [ "$(wm_status "$WM_DL")" = "failed" ] \
     && grep -q 'held by runner pid' "$WM_DL/result.json" 2>/dev/null; then
    ok "a live claim holder is not reclaimed by a contender that started a second later"
  else
    fail "a live claim holder was reclaimed (status=$(wm_status "$WM_DL"))"
  fi
  kill "$WM_LIVE" 2>/dev/null; wait "$WM_LIVE" 2>/dev/null
  rm -f "$WM_KR"/.claim.* 2>/dev/null
else
  fail "could not stage the live-holder fixture"
fi

# Releasing must TOMBSTONE rather than unlink, or the generation is rewindable by ABA: a
# contender that read the old holder's fields and paused could wake after a NEW holder had
# taken the same pathname, judge its CACHED pid dead, and advance -- two owners at once.
: > "$WM/cwd.log"; WM_DT1="$(wm_turn wm-tomb wmT1 "$WM_A1")"
WM_KT="$(wm_kdir_of "$(wm_prompt_cwds | sed -n 1p)" || true)"
: > "$WM/cwd.log"; WM_DT2="$(wm_turn wm-tomb wmT2 "$WM_A1")"
# The tombstone is an EXPLICIT marker, not an empty file: emptiness reads the same whether a
# holder released or the read failed, which is what let a contender advance past a live claim.
if [ -n "$WM_KT" ] && grep -qx 'released=1' "$WM_KT/.claim.0" 2>/dev/null \
   && [ -e "$WM_KT/.claim.1" ]; then
  ok "a released claim is tombstoned, so its generation name is never reused"
else
  fail "a released claim name was freed for reuse (kdir=$WM_KT: $(ls -A "$WM_KT" 2>/dev/null | tr '\n' ' '))"
fi

# A numeric claim name must NEVER be freed while an arbitrarily delayed contender may target
# it. The interleaving: a contender reads a tombstoned .claim.0 and pauses; later holders take
# .claim.1 and .claim.2 and crash; a fourth takes .claim.3 and its cleanup deletes .claim.1;
# the paused contender wakes and links the now-free .claim.1 beside the live holder.
if [ -n "$WM_KT" ] && [ -d "$WM_KT" ]; then
  rm -f "$WM_KT"/.claim.* 2>/dev/null
  for wmg in 0 1 2; do
    ( exec true ) & WM_DP=$!; wait "$WM_DP" 2>/dev/null
    printf 'pid=%s\nfmt=v2\nstart=STALE\nrun=crashed-%s\n' "$WM_DP" "$wmg" > "$WM_KT/.claim.$wmg"
  done
  : > "$WM/cwd.log"; WM_DN="$(wm_turn wm-tomb wmN1 "$WM_A1")"
  WM_LOST=0
  for wmg in 0 1 2; do [ -e "$WM_KT/.claim.$wmg" ] || WM_LOST=$(( WM_LOST + 1 )); done
  if [ "$(wm_status "$WM_DN")" = "completed" ] && [ "$WM_LOST" = 0 ] && [ -e "$WM_KT/.claim.3" ]; then
    ok "advancing past crashed generations frees no earlier claim name"
  else
    fail "a claim name was freed while advancing (lost=$WM_LOST status=$(wm_status "$WM_DN"))"
  fi
  # An UNREADABLE claim is not evidence of anything. An empty field reads the same whether the
  # holder released or the read failed, and treating that as released lets a contender advance
  # while the holder is still live.
  rm -f "$WM_KT"/.claim.* 2>/dev/null
  printf 'pid=1\nfmt=v2\nstart=STALE\nrun=unreadable\n' > "$WM_KT/.claim.0"
  chmod 000 "$WM_KT/.claim.0" 2>/dev/null
  WM_UNREADABLE_STAGED=1
  : > "$WM/cwd.log"; WM_DU="$(wm_turn wm-tomb wmU1 "$WM_A1")"
  chmod 644 "$WM_KT/.claim.0" 2>/dev/null
  if [ "$(wm_status "$WM_DU")" = "failed" ] \
     && [ "$(wm_prompt_cwds | awk 'END{print NR+0}')" = "0" ]; then
    ok "an unreadable claim refuses the turn instead of reading as released"
  else
    fail "a turn advanced past an unreadable claim (status=$(wm_status "$WM_DU"))"
  fi
  rm -f "$WM_KT"/.claim.* 2>/dev/null
else
  fail "could not stage the claim-name-reuse fixture"
fi

# A claim TRUNCATED by the previous release scheme carries no marker. Refusing it wedges every
# mount an older helper released -- the same upgrade break as a missing `.state.home`, and it
# refused every leg of this loop's own panel before this case was added. An unverified read
# still refuses; only a zero-byte file whose read SUCCEEDED is treated as a legacy tombstone.
if [ -n "$WM_KT" ] && [ -d "$WM_KT" ]; then
  rm -f "$WM_KT"/.claim.* 2>/dev/null
  : > "$WM_KT/.claim.0"
  : > "$WM/cwd.log"; WM_DLG="$(wm_turn wm-tomb wmLG "$WM_A1")"
  [ "$(wm_status "$WM_DLG")" = "completed" ] \
    && ok "a claim truncated by an older release scheme is honoured, not a permanent wedge" \
    || fail "a legacy truncated claim wedged the mount (status=$(wm_status "$WM_DLG"))"
  # ...and a NON-empty claim with neither a pid nor a marker is still malformed, not free.
  rm -f "$WM_KT"/.claim.* 2>/dev/null
  printf 'garbage\n' > "$WM_KT/.claim.0"
  : > "$WM/cwd.log"; WM_DMF="$(wm_turn wm-tomb wmMF "$WM_A1")"
  [ "$(wm_status "$WM_DMF")" = "failed" ] \
    && ok "a malformed claim with content but no runner still refuses" \
    || fail "a malformed claim was treated as free (status=$(wm_status "$WM_DMF"))"
  rm -f "$WM_KT"/.claim.* 2>/dev/null
fi

# An UNREADABLE .state.record must not read as "no turn has ever run here". Flattening a read
# failure into an absent value is what let a mount restage under a possibly-live queue owner;
# the turn must degrade to the disposable path instead.
if [ -n "$WM_KT" ] && [ -f "$WM_KT/.state.record" ]; then
  chmod 000 "$WM_KT/.state.record" 2>/dev/null
  : > "$WM/cwd.log"; WM_DSR="$(wm_turn wm-tomb wmSR "$WM_A1")"
  WM_CSR="$(wm_prompt_cwds | sed -n 1p)"
  chmod 644 "$WM_KT/.state.record" 2>/dev/null
  if [ "$(wm_status "$WM_DSR")" = "completed" ] \
     && wm_is_throwaway "$WM_CSR" "$WM/run-wmSR"; then
    ok "an unreadable state record degrades instead of looking like a first turn"
  else
    fail "an unreadable state record was treated as absent (status=$(wm_status "$WM_DSR") cwd=$WM_CSR)"
  fi
fi

# Only a GENUINELY ABSENT state record may mean "no turn has ever run here" -- that meaning
# licenses skipping the queue-owner check. Present-but-empty and a dangling symlink both
# looked absent to the earlier reader, so both permitted a stable restage under a possibly
# live owner. Each must degrade to the per-message path instead.
if [ -n "$WM_KT" ] && [ -d "$WM_KT" ]; then
  for wmcase in empty dangling malformed; do
    rm -f "$WM_KT/.state.record" 2>/dev/null
    case "$wmcase" in
      empty)     : > "$WM_KT/.state.record" ;;
      dangling)  ln -s "$WM_KT/.no-such-target" "$WM_KT/.state.record" ;;
      malformed) printf 'not a valid id!!\n' > "$WM_KT/.state.record" ;;
    esac
    : > "$WM/cwd.log"; WM_DSX="$(wm_turn wm-tomb "wmSX$wmcase" "$WM_A1")"
    WM_CSX="$(wm_prompt_cwds | sed -n 1p)"
    if [ "$(wm_status "$WM_DSX")" = "completed" ] \
       && wm_is_throwaway "$WM_CSX" "$WM/run-wmSX$wmcase"; then
      ok "a $wmcase state record degrades instead of reading as a first turn"
    else
      fail "a $wmcase state record permitted a stable restage (status=$(wm_status "$WM_DSX") cwd=$WM_CSX)"
    fi
  done
  rm -f "$WM_KT/.state.record" 2>/dev/null
fi

# A prior --approve-all child can rewrite the state siblings. Rewriting `.state.home` to a
# store with no lease made the probe answer "gone" while the real owner stayed live in the
# store that actually holds it — a stable restage under a live owner. The recorded pair must
# be corroborated against an acpx record that names THIS mount, or the turn degrades.
if [ -n "$WM_KT" ] && [ -d "$WM_KT" ]; then
  WM_HOME_A="$WM/homeA"; WM_HOME_B="$WM/homeB"
  mkdir -p "$WM_HOME_A/.acpx/queues" "$WM_HOME_A/.acpx/sessions" "$WM_HOME_B/.acpx/sessions"
  : > "$WM_HOME_A/.acpx-test-store"; : > "$WM_HOME_B/.acpx-test-store"
  : > "$WM/cwd.log"; WM_DHA="$(wm_turn wm-home wmHA "$WM_A1" HOME="$WM_HOME_A" AX_RECORD_ID=stub-record-1)"
  WM_KHA="$(wm_kdir_of "$(wm_prompt_cwds | sed -n 1p)" || true)"
  if [ -n "$WM_KHA" ] && [ "$(wm_status "$WM_DHA")" = "completed" ]; then
    # a LIVE lease in A, and the child points the record at empty store B
    WM_LEASE_A="$(printf '%s' "stub-record-1" | shasum -a 256 | cut -c1-24)"
    printf '{ "pid": 1 }\n' > "$WM_HOME_A/.acpx/queues/$WM_LEASE_A.lock"
    WM_KHA_INO0="$(/usr/bin/stat -f %i "$WM_KHA/view/tree" 2>/dev/null || stat -c %i "$WM_KHA/view/tree" 2>/dev/null)"
    printf '%s\n' "$WM_HOME_B" > "$WM_KHA/.state.home"
    : > "$WM/cwd.log"; WM_DHB="$(wm_turn wm-home wmHB "$WM_A1" HOME="$WM_HOME_A" AX_RECORD_ID=stub-record-1)"
    WM_CHB="$(wm_prompt_cwds | sed -n 1p)"
    WM_KHA_INO="$(/usr/bin/stat -f %i "$WM_KHA/view/tree" 2>/dev/null || stat -c %i "$WM_KHA/view/tree" 2>/dev/null)"
    if wm_is_throwaway "$WM_CHB" "$WM/run-wmHB" \
       && [ "$(wm_status "$WM_DHB")" = "completed" ] \
       && [ "$WM_KHA_INO" = "$WM_KHA_INO0" ]; then
      ok "a rewritten owner home degrades, completes, and leaves the stable mount untouched"
    else
      fail "a rewritten owner home was mishandled (cwd=$WM_CHB status=$(wm_status "$WM_DHB") ino=$WM_KHA_INO want=$WM_KHA_INO0)"
    fi
    # An unreadable RECORD FILE must degrade too. A bare read of it under `set -e` aborted
    # the runner outright, which reads as "runner aborted unexpectedly" and wedges every retry.
    printf '%s\n' "$WM_HOME_A" > "$WM_KHA/.state.home"
    WM_RECJ="$WM_HOME_A/.acpx/sessions/$(cat "$WM_KHA/.state.record" 2>/dev/null).json"
    if [ -f "$WM_RECJ" ]; then
      chmod 000 "$WM_RECJ" 2>/dev/null
      : > "$WM/cwd.log"; WM_DUR="$(wm_turn wm-home wmUR "$WM_A1" HOME="$WM_HOME_A" AX_RECORD_ID=stub-record-1)"
      chmod 644 "$WM_RECJ" 2>/dev/null
      [ "$(wm_status "$WM_DUR")" = "completed" ] \
        && ok "an unreadable acpx record degrades rather than aborting the runner" \
        || fail "an unreadable acpx record aborted the turn (status=$(wm_status "$WM_DUR"))"
    else
      fail "could not stage the unreadable-record fixture ($WM_RECJ)"
    fi
    # A DELETED session record is not a first turn when the mount still exists: treating it
    # as one skips the owner check entirely and licenses a restage under a live owner.
    printf '%s\n' "$WM_HOME_A" > "$WM_KHA/.state.home"
    rm -f "$WM_KHA/.state.record" 2>/dev/null
    : > "$WM/cwd.log"; WM_DDR="$(wm_turn wm-home wmDR "$WM_A1" HOME="$WM_HOME_A" AX_RECORD_ID=stub-record-1)"
    WM_CDR="$(wm_prompt_cwds | sed -n 1p)"
    if wm_is_throwaway "$WM_CDR" "$WM/run-wmDR" && [ "$(wm_status "$WM_DDR")" = "completed" ]; then
      ok "a deleted session record degrades instead of passing as a first turn"
    else
      fail "a deleted session record was treated as a first turn (cwd=$WM_CDR status=$(wm_status "$WM_DDR"))"
    fi
    rm -f "$WM_HOME_A/.acpx/queues/$WM_LEASE_A.lock" 2>/dev/null
  else
    fail "could not stage the rewritten-home fixture (kdir=$WM_KHA status=$(wm_status "$WM_DHA"))"
  fi
fi

# These refusal checks use this group's registry, not transport.sh's private fixture.
wm_transport() { (cd "$MA_FIX" && env -u COMMS_DELIVERY "$COMMS" "$@"); }
check_not "transport rejects an unregistered agent" wm_transport transport gemini
check_not "transport rejects an unknown option" wm_transport transport codex --bogus

section "reviewer isolation: mounts live OUTSIDE the repo (relocation increment 1)"
# Self-contained: a fresh fixture so clean-mounts' repo-key scope never collides with the
# warm-mount leftovers above. Reuses the acpx stub ($AXB) and drives grok under the operator
# override, exactly as the warm-mount section does.
RELO_FIX="$WORK/relo-repo"; mkdir -p "$RELO_FIX"; RELO_FIX="$(cd "$RELO_FIX" && pwd -P)"
git -C "$RELO_FIX" init -q -b feature/relo
printf '.comms/\n' > "$RELO_FIX/.gitignore"
git -C "$RELO_FIX" -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null || \
  { git -C "$RELO_FIX" add -A >/dev/null 2>&1; git -C "$RELO_FIX" -c user.email=t@t -c user.name=t commit -q -m init; }
mkdir -p "$RELO_FIX/.comms/to-grok" "$RELO_FIX/.comms/to-claude" "$RELO_FIX/.comms/archive"
RELO_WS="$(cd "$RELO_FIX" && env "$COMMS" workspace)"
RELO_HEAD="$(git -C "$RELO_FIX" rev-parse HEAD)"
printf 'relo-marker\n' > "$RELO_FIX/relo.txt"
RELO_T="$(cd "$RELO_FIX" && GIT_INDEX_FILE="$WORK/relo.idx" git add -A -- . >/dev/null 2>&1; GIT_INDEX_FILE="$WORK/relo.idx" git -C "$RELO_FIX" write-tree)"
rm -f "$RELO_FIX/relo.txt"
RELO_ART="$(git -C "$RELO_FIX" -c user.email=t@t -c user.name=t commit-tree "$RELO_T" -p HEAD -m art 2>/dev/null)"
RELO_HOME="$WORK/relo-home"; mkdir -p "$RELO_HOME/.acpx/sessions" "$RELO_HOME/.acpx/queues"; : > "$RELO_HOME/.acpx-test-store"
RELO_STORE_MB="$WORK/relo-mbase"; mkdir -p "$RELO_STORE_MB"; RELO_STORE_MB="$(cd "$RELO_STORE_MB" && pwd -P)"
RELO_STORE="$RELO_STORE_MB/agent-comms/mounts"
: > "$WORK/relo-cwd.log"
relo_turn() {  # <thread> <tag> [extra env...] -> run dir
  local thread="$1" tag="$2"; shift 2
  local m="$RELO_FIX/.comms/to-grok/${RELO_WS}_2026-08-20T10-00-00_$tag.md" dir="$WORK/relo-run-$tag"
  cat > "$m" <<EOF
---
type: review-request
from: claude
timestamp: 2026-08-20T14:00:00Z
workspace: $RELO_WS
message_id: ${RELO_WS}_2026-08-20T10-00-00_$tag
thread: $thread
artifact_id: $RELO_ART
head_sha: $RELO_HEAD
workflow: auto
phase: plan
round: 1
max-rounds: 4
---
## Plan
review
EOF
  mkdir -p "$dir"
  ( cd "$RELO_FIX" && env PATH="$AXB:$PATH" HOME="$RELO_HOME" \
      COMMS_MOUNT_BASE="$RELO_STORE" ACP_PARITY_PAYLOAD="$AXD/payload" AX_CWD_LOG="$WORK/relo-cwd.log" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_RUNPHASE_OWNER_WAIT_SECS=3 COMMS_RUNPHASE_ALLOW_UNCONTAINED=1 \
      "$@" "$RP" run --message "$m" --dir "$dir" --provider grok --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}
relo_last_cwd() { awk -F'\t' '$2 !~ /sessions (ensure|show|set-mode)/ {print $1}' "$WORK/relo-cwd.log" | sed -n '$p'; }
relo_status() { sed -n 's/.*"status": "\([a-z]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }
relo_clean() { ( cd "$RELO_FIX" && env HOME="$RELO_HOME" COMMS_MOUNT_BASE="$RELO_STORE" "$RP" clean-mounts "$@" 2>&1 ); }

printf 'VERDICT: APPROVE\n\n## Summary\nstub\n\n### Blocking\n- None.\n' > "$AXD/payload"

# A base UNDER the repo is refused before anything is created — never mount inside the snapshot.
: > "$WORK/relo-cwd.log"; RELO_D1="$(relo_turn relo-underrepo r1 COMMS_MOUNT_BASE="$RELO_FIX/mounts")"
if [ "$(relo_status "$RELO_D1")" = failed ] && grep -q 'under the repo' "$RELO_D1/result.json" 2>/dev/null \
   && [ ! -e "$RELO_FIX/mounts" ]; then
  ok "a mount base under the repo is refused, and nothing is created inside the snapshot"
else
  fail "a base under the repo was accepted (status=$(relo_status "$RELO_D1"))"
fi

# A non-absolute base is refused.
RELO_D2="$(relo_turn relo-rel r2 COMMS_MOUNT_BASE="relative/mounts")"
[ "$(relo_status "$RELO_D2")" = failed ] && grep -q 'not an absolute path' "$RELO_D2/result.json" 2>/dev/null \
  && ok "a non-absolute mount base is refused" || fail "a non-absolute base was accepted (status=$(relo_status "$RELO_D2"))"

# The DEFAULT base (COMMS_MOUNT_BASE empty == unset) lands under \$HOME/.local/state, mode 700.
: > "$WORK/relo-cwd.log"; RELO_D3="$(relo_turn relo-default r3 COMMS_MOUNT_BASE=)"
RELO_C3="$(relo_last_cwd)"; RELO_DEF="$(cd "$RELO_HOME" && pwd -P)/.local/state/agent-comms/mounts"
case "$RELO_C3" in
  "$RELO_DEF"/*/*/view/tree) ok "the default base is \${XDG_STATE_HOME:-\$HOME/.local/state}/agent-comms/mounts" ;;
  *) fail "the default base is not under \$HOME/.local/state (cwd=$RELO_C3)" ;;
esac
case "$(ls -ld "$RELO_DEF" 2>/dev/null | awk '{print substr($1,5,6)}')" in
  "------") ok "the created mount base is mode 700 (no group/other access)" ;;
  *) fail "the created mount base is not mode 700" ;;
esac

# QUARANTINE: a legacy in-repo .comms/mounts/<ident> is NEVER selected, mkdir'd, or modified;
# the new turn runs externally and leaves the legacy tree byte-for-byte untouched.
RELO_LEG="$RELO_FIX/.comms/mounts/relo-legacy-grok"
mkdir -p "$RELO_LEG/tree"; printf 'FORGED\n' > "$RELO_LEG/.state.record"; printf 'legacy\n' > "$RELO_LEG/tree/marker"
RELO_LEG_B4="$(ls -laR "$RELO_LEG" 2>/dev/null)"
: > "$WORK/relo-cwd.log"; RELO_D4="$(relo_turn relo-quar r4)"
RELO_C4="$(relo_last_cwd)"; RELO_EXT4=0; RELO_INREPO4=0
case "$RELO_C4" in "$RELO_STORE"/*/*/view/tree) RELO_EXT4=1 ;; esac
case "$RELO_C4" in "$RELO_FIX"/*) RELO_INREPO4=1 ;; esac
if [ "$(relo_status "$RELO_D4")" = completed ] && [ "$RELO_EXT4" = 1 ] && [ "$RELO_INREPO4" = 0 ] \
   && [ "$(ls -laR "$RELO_LEG" 2>/dev/null)" = "$RELO_LEG_B4" ]; then
  ok "a legacy in-repo mount is quarantined: the turn runs externally and never touches it"
else
  fail "a legacy in-repo mount was selected or modified (cwd=$RELO_C4 ext=$RELO_EXT4 inrepo=$RELO_INREPO4)"
fi
rm -rf "$RELO_FIX/.comms/mounts"

# A degrade lands on an EXTERNAL throwaway that is REMOVED at turn end (no auth.json accretion).
# Force a degrade by planting an unreadable .state.record on the durable ident from a first turn.
: > "$WORK/relo-cwd.log"; RELO_D5="$(relo_turn relo-degrade r5)"
RELO_K5="$(dirname "$(dirname "$(relo_last_cwd)")")"
if [ -d "$RELO_K5" ] && [ -f "$RELO_K5/.state.record" ]; then
  chmod 000 "$RELO_K5/.state.record" 2>/dev/null
  : > "$WORK/relo-cwd.log"; RELO_D5B="$(relo_turn relo-degrade r5b)"
  chmod 644 "$RELO_K5/.state.record" 2>/dev/null
  RELO_C5B="$(relo_last_cwd)"; RELO_TW=0
  case "$RELO_C5B" in "$RELO_STORE"/*/tmp-*/view/tree) RELO_TW=1 ;; esac
  RELO_TWDIR="$(dirname "$(dirname "$RELO_C5B")")"
  if [ "$(relo_status "$RELO_D5B")" = completed ] && [ "$RELO_TW" = 1 ] && [ ! -e "$RELO_TWDIR" ] \
     && [ -d "$RELO_K5/view/tree" ]; then
    ok "a degrade uses an external throwaway that is removed at turn end, leaving the durable mount"
  else
    fail "the degrade throwaway was not external/removed, or the durable mount was disturbed (cwd=$RELO_C5B)"
  fi
else
  fail "could not stage the degrade fixture (kdir=$RELO_K5)"
fi

# clean-mounts: dry-run lists this repo's mounts and removes nothing; --yes then removes them.
RELO_DRY="$(relo_clean)"
RELO_ANY_MOUNT="$(find "$RELO_STORE" -maxdepth 2 -type d -name 'relo-*' 2>/dev/null | head -1)"
if printf '%s' "$RELO_DRY" | grep -qF 'would remove' && [ -n "$RELO_ANY_MOUNT" ] && [ -d "$RELO_ANY_MOUNT" ]; then
  ok "clean-mounts dry-run lists removable mounts and deletes nothing"
else
  fail "clean-mounts dry-run misbehaved (any=$RELO_ANY_MOUNT)"
fi
# A LIVE claim on any ident refuses the WHOLE repo-key, even under --yes.
RELO_K6="$(find "$RELO_STORE" -maxdepth 2 -type d -name 'relo-*-grok' 2>/dev/null | head -1)"
if [ -n "$RELO_K6" ] && [ -d "$RELO_K6" ]; then
  sleep 30 & RELO_LIVE=$!
  RELO_LS="$(LC_ALL=C TZ=UTC ps -p "$RELO_LIVE" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/^ *//; s/ *$//')"
  printf 'pid=%s\nfmt=v2\nstart=%s\nrun=live\n' "$RELO_LIVE" "$RELO_LS" > "$RELO_K6/.claim.0"
  RELO_CM_LIVE="$(relo_clean --yes)"
  kill "$RELO_LIVE" 2>/dev/null; wait "$RELO_LIVE" 2>/dev/null
  if printf '%s' "$RELO_CM_LIVE" | grep -qF 'refusing' && [ -d "$RELO_K6" ]; then
    ok "clean-mounts refuses the whole repo-key while an owner claim is live"
  else
    fail "clean-mounts removed a mount with a live claim"
  fi
  rm -f "$RELO_K6"/.claim.* 2>/dev/null
else
  fail "could not find a durable mount for the live-claim clean-mounts fixture"
fi
# With no live owner, --yes removes the repo-key's mounts and their registered worktrees.
relo_clean --yes >/dev/null 2>&1
RELO_LEFT="$(find "$RELO_STORE" -maxdepth 2 -type d \( -name 'relo-*-grok' -o -name 'tmp-*' \) 2>/dev/null | wc -l | tr -d ' ')"
[ "$RELO_LEFT" = 0 ] \
  && ok "clean-mounts --yes removes this repo's mounts once no owner is live" \
  || fail "clean-mounts --yes left $RELO_LEFT mount(s) behind"

# clean-mounts is SCOPED to this repo-key: a second repo sharing the same base is never touched,
# and the two repos hash to distinct repo-keys.
RELO_FIX2="$WORK/relo-repo2"; mkdir -p "$RELO_FIX2"; RELO_FIX2="$(cd "$RELO_FIX2" && pwd -P)"
git -C "$RELO_FIX2" init -q -b feature/relo2
printf '.comms/\n' > "$RELO_FIX2/.gitignore"
git -C "$RELO_FIX2" add -A >/dev/null 2>&1; git -C "$RELO_FIX2" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$RELO_FIX2/.comms"
RELO_KEY1="$(printf '%s' "$RELO_FIX" | shasum -a 256 | cut -c1-64)"
RELO_KEY2="$(printf '%s' "$RELO_FIX2" | shasum -a 256 | cut -c1-64)"
mkdir -p "$RELO_STORE/$RELO_KEY2/sentinel-ident/view"
printf '%s\n' "$RELO_FIX2" > "$RELO_STORE/$RELO_KEY2/.root"
if [ "$RELO_KEY1" != "$RELO_KEY2" ]; then
  ok "two repos sharing one base hash to distinct repo-keys"
else
  fail "two distinct repos collided on one repo-key"
fi
relo_clean --yes >/dev/null 2>&1
[ -d "$RELO_STORE/$RELO_KEY2/sentinel-ident" ] \
  && ok "clean-mounts never crosses into another repo-key's store" \
  || fail "clean-mounts deleted a sibling repo-key's mount"

# A repo-key store whose .root names a DIFFERENT root is refused, never adopted or deleted.
RELO_CM_MM="$( cd "$RELO_FIX" && env HOME="$RELO_HOME" COMMS_MOUNT_BASE="$RELO_STORE" \
  bash -c 'root="$('"$COMMS"' root)"; mr="${root%/.comms}"; mr="$(cd "$mr" && pwd -P)"; key="$(printf "%s" "$mr" | shasum -a 256 | cut -c1-64)"; printf "%s\n" "/somewhere/else" > "'"$RELO_STORE"'/$key/.root" 2>/dev/null; '"$RP"' clean-mounts --yes 2>&1' )"
printf '%s' "$RELO_CM_MM" | grep -qF '.root does not name this repo' \
  && ok "clean-mounts refuses a store whose .root names a different repo" \
  || fail "clean-mounts did not refuse a mismatched .root store"
# Restore this repo's .root so the orphan scan below (which validates the current scope first)
# is not blocked by the mismatch we just planted.
printf '%s\n' "$RELO_FIX" > "$RELO_STORE/$RELO_KEY1/.root" 2>/dev/null || true

# clean-mounts --orphans is REPORT-ONLY: it names a moved checkout's stale key but deletes nothing.
mkdir -p "$RELO_STORE/deadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadbeef/x"
printf '/no/such/checkout/anymore\n' > "$RELO_STORE/deadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadbeef/.root"
RELO_ORPH="$(relo_clean --orphans)"
if printf '%s' "$RELO_ORPH" | grep -qF 'orphan candidate' && printf '%s' "$RELO_ORPH" | grep -qF 'REPORT-ONLY' \
   && [ -d "$RELO_STORE/deadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadkeydeadbeef" ]; then
  ok "clean-mounts --orphans reports a moved checkout's stale key without deleting it"
else
  fail "clean-mounts --orphans deleted an orphan or did not report it"
fi

# The cwd-outside-repo gate and the non-gating git-ancestor probe both leave a runner.log trace.
grep -q 'git-ancestor probe' "$WORK/relo-run-r4/runner.log" 2>/dev/null \
  && ok "the git-ancestor probe is logged (non-gating in this increment)" \
  || fail "the git-ancestor probe left no log line"

# ---- round 2: GC/claim safety (codex + grok, impl r1 blocking) ----
# An UNREADABLE claim on a durable ident must read as LIVE, so clean-mounts refuses the whole
# repo-key rather than deleting a mount a runner may still hold. (codex + grok, impl r1, blocking.)
: > "$WORK/relo-cwd.log"; RELO_D7="$(relo_turn relo-failclosed r7)"
RELO_K7="$(dirname "$(dirname "$(relo_last_cwd)")")"
if [ -n "$RELO_K7" ] && [ -d "$RELO_K7" ]; then
  : > "$RELO_K7/.claim.0"; chmod 000 "$RELO_K7/.claim.0" 2>/dev/null
  RELO_CM_FC="$(relo_clean --yes)"
  chmod 644 "$RELO_K7/.claim.0" 2>/dev/null; rm -f "$RELO_K7"/.claim.* 2>/dev/null
  if printf '%s' "$RELO_CM_FC" | grep -qF 'refusing' && [ -d "$RELO_K7" ]; then
    ok "clean-mounts treats an unreadable claim as live and refuses (fail-closed)"
  else
    fail "clean-mounts deleted an ident with an unreadable claim"
  fi
else
  fail "could not stage the fail-closed-claim fixture (kdir=$RELO_K7)"
fi
# clean-mounts HOLDS an exclusion claim across the owner re-check and the delete (closes the
# scan-then-delete race), and never follows a symlinked view/tree into `git worktree remove`.
awk '/^cmd_clean_mounts\(\)/{f=1} f&&/mount_claim_take "\$d" "\$gc_rd"/{c=1} f&&/\[ ! -L "\$d\/view\/tree" \]/{s=1} /^}/{if(f && /^}/ && NR>1)f=f} END{exit !(c&&s)}' "$RP" \
  && ok "cmd_clean_mounts takes a claim before deleting and never-follows a symlinked view/tree" \
  || fail "cmd_clean_mounts deletes without a held claim or follows a symlinked view/tree"
# The THROWAWAY ident is claimed exactly like a durable one, so a live throwaway (non-ACP grok, or
# an ACP degrade after the ttl owner exits) is visible to clean-mounts. (grok, impl r1, blocking.)
awk '/^mount_use_throwaway\(\)/{f=1} f&&/mount_claim_take "\$mount_kdir" "\$run_dir"/{c=1} f&&/^}/{exit !c} END{exit !c}' "$RP" \
  && ok "mount_use_throwaway claims the throwaway ident (fail-closed)" \
  || fail "the throwaway ident is never claimed, so a live throwaway reads as dead"
# mount_alloc verifies the repo-key dir is uid-owned and mode 700 with a fail-closed chmod BEFORE
# writing .root — refusing an attacker-planted key dir on a shared sticky base. (codex, impl r1.)
grep -qF "cannot chmod repo-key dir" "$RP" \
  && grep -qF "not owned by the current uid — refusing a foreign-owned store" "$RP" \
  && grep -qF "refusing a group/other-accessible store" "$RP" \
  && ok "mount_alloc requires the repo-key dir uid-owned + mode 700 (fail-closed chmod) before .root" \
  || fail "mount_alloc adopts a repo-key dir without owner/mode verification"
# COMPLETENESS (the plan asked to grep BOTH old degrade assignment forms): neither remains.
[ "$(grep -cF 'mount_kdir="$run_dir"' "$RP")" = 0 ] && [ "$(grep -cF 'mount_dir="$run_dir/tree"' "$RP")" = 0 ] \
  && ok "no \$run_dir-derived mount path remains (both degrade assignment forms are gone)" \
  || fail "a \$run_dir-derived mount assignment survives"
# The cwd gate FAILS CLOSED on an unresolvable cwd (an empty pwd -P must not slip past). (grok r1.)
grep -qF "does not resolve — refusing rather than reviewing an unverifiable location" "$RP" \
  && ok "the mounted-cwd gate refuses an unresolvable cwd (fail-closed)" \
  || fail "the cwd gate can fail open on an unresolvable cwd"
# The acp wrapper also scrubs the index/object-dir GIT_* vars that redirect WRITES. (grok r1.)
grep -qF 'GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES' "$RP" \
  && ok "acp_exec also scrubs GIT_INDEX_FILE / GIT_OBJECT_DIRECTORY / GIT_ALTERNATE_OBJECT_DIRECTORIES" \
  || fail "the acp wrapper leaves index/object-dir GIT_* vars unscrubbed"
