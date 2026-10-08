# Run through tests/run.sh; each group gets fresh fixtures.
# Its own group, not a section of `mounts`: every mount here comes from a real stubbed ACP turn,
# and the section's ~10 turns would otherwise serialize behind that group's.
fixture_acp

section "clean mounts --thread: remove ONE retired thread's proven review mounts"
# Basis retires a finished task's review copies without touching another task's warm ones and
# without waiting for every review in the repo to stop (the whole-store GC above refuses the
# whole repo-key on any one live ident). Every mount here is made by a REAL stubbed ACP turn; its
# ident dir is read from the cwd the CHILD reported, never recomputed by the test.
RT="$WORK/rt-repo"; mkdir -p "$RT"; RT="$(cd "$RT" && pwd -P)"
git -C "$RT" init -q -b main
printf '.comms/\n' > "$RT/.gitignore"; printf 'base\n' > "$RT/a.txt"
git -C "$RT" add .gitignore a.txt; git -C "$RT" -c user.email=t@t -c user.name=t commit -qm init
mkdir -p "$RT/.comms/archive" "$RT/.comms/logs" "$RT/.comms/grades" "$RT/.comms/to-claude"
RT_WS="$(cd "$RT" && env "$COMMS" workspace)"
RT_HEAD="$(git -C "$RT" rev-parse HEAD)"
printf 'reviewed\n' > "$RT/rt.txt"
RT_TREE="$(cd "$RT" && GIT_INDEX_FILE="$WORK/rt.idx" git add -A -- . >/dev/null 2>&1; GIT_INDEX_FILE="$WORK/rt.idx" git -C "$RT" write-tree)"
rm -f "$RT/rt.txt" "$WORK/rt.idx"
RT_ART="$(git -C "$RT" -c user.email=t@t -c user.name=t commit-tree "$RT_TREE" -p HEAD -m art)"
git -C "$RT" update-ref "refs/agent-comms/artifacts/$RT_ART" "$RT_ART"
RT_HOME="$WORK/rt-home"; mkdir -p "$RT_HOME/.acpx/sessions" "$RT_HOME/.acpx/queues"; : > "$RT_HOME/.acpx-test-store"
RT_MB="$WORK/rt-mbase"; mkdir -p "$RT_MB"; RT_MB="$(cd "$RT_MB" && pwd -P)"; RT_STORE="$RT_MB/agent-comms/mounts"
RT_CWDLOG="$WORK/rt-cwd.log"; RT_N=0
printf 'VERDICT: APPROVE\n\n## Summary\nstub\n\n### Blocking\n- None.\n' > "$AXD/payload"
rt_turn() {  # <thread> <agent> [review_set] [run dir] -> the ident dir the child ran in, or ""
  local thread="$1" agent="$2" set="${3:-}" dir="${4:-}" m tag cwd
  RT_N=$((RT_N + 1)); tag="rt$RT_N"
  [ -n "$dir" ] || dir="$RT/.comms/logs/$tag"
  mkdir -p "$dir" "$RT/.comms/to-$agent"
  m="$RT/.comms/to-$agent/${RT_WS}_2026-09-28T10-00-00_$tag.md"
  { printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-09-28T10:00:00Z\nworkspace: %s\n' "$RT_WS"
    printf 'message_id: %s_2026-09-28T10-00-00_%s\nthread: %s\n' "$RT_WS" "$tag" "$thread"
    [ -z "$set" ] || printf 'review_set: %s\n' "$set"
    [ "$agent" = "${agent%-review}" ] || printf 'review_provider: %s\n' "${agent%-review}"
    printf 'artifact_id: %s\nhead_sha: %s\nworkflow: auto\nphase: plan\nround: 1\nmax-rounds: 4\n---\n## Plan\nreview\n' "$RT_ART" "$RT_HEAD"
  } > "$m"
  : > "$RT_CWDLOG"
  ( cd "$RT" && env PATH="$AXB:$PATH" HOME="$RT_HOME" COMMS_MOUNT_BASE="$RT_STORE" \
      ACP_PARITY_PAYLOAD="$AXD/payload" AX_CWD_LOG="$RT_CWDLOG" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_RUNPHASE_OWNER_WAIT_SECS=3 COMMS_RUNPHASE_ALLOW_UNCONTAINED=1 \
      "$RP" run --message "$m" --dir "$dir" --agent "$agent" --via acp --timeout-secs 20 ) >/dev/null 2>&1
  cwd="$(awk -F'\t' '$2 !~ /sessions (ensure|show|set-mode)/ {print $1}' "$RT_CWDLOG" | sed -n '$p')"
  case "$cwd" in "$RT_STORE"/*/*/view/tree) printf '%s' "${cwd%/view/tree}" ;; esac
}
rt_sets() {  # <set> <leg thread> <agent> — the index row `panel dispatch` writes per leg
  local idx="$RT/.comms/grades/sets.tsv"
  [ -s "$idx" ] || printf 'review_set_id\trequest_message_id\tthread\tround\tphase\tartifact_id\tprompt_version\tbase_sha\tgating_agent\tshadow_agent\tdrift_status\tdrift_artifact_id\tcreated\tdispatch\n' > "$idx"
  printf '%s\treq\t%s\t1\tplan\t%s\tv1\t%s\tgrok\t%s\tdispatched\t\t2026-09-28T10:00:00Z\td1\n' "$1" "$2" "$RT_ART" "$RT_HEAD" "$3" >> "$idx"
}
rt_cm() { (cd "$RT" && env HOME="$RT_HOME" COMMS_MOUNT_BASE="$RT_STORE" "$RP" clean-mounts "$@" 2>&1); }
rt_state() { (cd "$RT" && env "$COMMS" state "$@" 2>&1); }
rt_reg() { git -C "$RT" worktree list --porcelain | grep_full -qxF "worktree $1/view/tree"; }
rt_intact() {  # <kdir> — tree, session bookkeeping and registration all still there
  [ -f "$1/view/tree/rt.txt" ] && [ -f "$1/.state.record" ] && [ -f "$1/.state.home" ] && [ -f "$1/.state.admin" ] \
    && [ -f "$RT_HOME/.acpx/sessions/$(cat "$1/.state.record").json" ] && rt_reg "$1"
}
rt_gone() {  # <kdir> — the ident, its registration and any tombstone are all gone
  [ ! -e "$1" ] && ! rt_reg "$1" && [ -z "$(ls -d "$(dirname "$1")/.retire.$(basename "$1")".* 2>/dev/null)" ]
}
rt_line() { grep -F " path=$2" <<<"$1" | grep_full -q "^clean-mounts-target v1 status=$3 reason=$4 "; }
rt_none() { grep -q '^clean-mounts-result v1 status=blocked .* selected=0 ' <<<"$1"; }   # refused before selecting
rt_live_claim() {  # <kdir> — a live v2 runner claim; prints the holder pid
  local p; sleep 300 </dev/null >/dev/null 2>&1 & p=$!
  printf 'pid=%s\nfmt=v2\nstart=%s\nrun=live\n' "$p" "$(LC_ALL=C TZ=UTC ps -p "$p" -o lstart= | tr -s ' ' | sed 's/^ *//; s/ *$//')" > "$1/.claim.99"
  printf '%s' "$p"
}
rt_unclaim() { kill "$2" 2>/dev/null; wait "$2" 2>/dev/null; rm -f "$1/.claim.99"; }
RT_ECHO='rt\echo'   # a backslash in the raw thread must reach every comparison verbatim

# Thread A = rt/alpha and thread B = rt_alpha share a safe_name; both have panel legs to two
# reviewers (grok and its review twin), so each owns two durable mounts.
rt_sets set-a "rt/alpha-grok" grok; rt_sets set-a "rt/alpha-grok-review" grok-review
rt_sets set-b "rt_alpha-grok" grok; rt_sets set-b "rt_alpha-grok-review" grok-review
RT_A1="$(rt_turn "rt/alpha-grok" grok set-a)"; RT_A2="$(rt_turn "rt/alpha-grok-review" grok-review set-a)"
RT_B1="$(rt_turn "rt_alpha-grok" grok set-b)"; RT_B2="$(rt_turn "rt_alpha-grok-review" grok-review set-b)"
if [ -n "$RT_A1" ] && [ -n "$RT_A2" ] && [ -n "$RT_B1" ] && [ -n "$RT_B2" ] \
   && [ "$(printf '%s\n' "$RT_A1" "$RT_A2" "$RT_B1" "$RT_B2" | sort -u | wc -l | tr -d ' ')" = 4 ] \
   && rt_intact "$RT_A1" && rt_intact "$RT_A2" && rt_intact "$RT_B1" && rt_intact "$RT_B2"; then
  ok "fixture: two sanitized-equal threads x two reviewers mount four distinct warm idents"
else
  fail "fixture: the four warm mounts were not created (a1=$RT_A1 a2=$RT_A2 b1=$RT_B1 b2=$RT_B2)"
fi
RT_LEDGER_B4="$(cat "$RT/.comms/grades/sets.tsv"; find "$RT/.comms" -type f -not -path '*/state/*' | sort | xargs cat 2>/dev/null | shasum)"

# ---- selectors: nothing unknown, nothing empty, never the whole store ----
rt_cm --thread >/dev/null; RT_U1=$?
rt_cm --thread "" >/dev/null; RT_U2=$?
rt_cm --thread rt/alpha --orphans >/dev/null; RT_U3=$?
rt_cm --thread rt/alpha --ident x --yes >/dev/null; RT_U4=$?
(cd "$RT" && env HOME="$RT_HOME" COMMS_MOUNT_BASE="$RT_STORE" "$COMMS" clean --thread rt/alpha --yes >/dev/null 2>&1); RT_U5=$?
(cd "$RT" && env HOME="$RT_HOME" COMMS_MOUNT_BASE="$RT_STORE" "$COMMS" clean mounts --thread rt/alpha --bogus --yes >/dev/null 2>&1); RT_U6=$?
(cd "$RT" && env HOME="$RT_HOME" COMMS_MOUNT_BASE="$RT_STORE" "$COMMS" clean --bogus mounts --thread rt/alpha --yes >/dev/null 2>&1); RT_U7=$?
if [ "$RT_U1" = 2 ] && [ "$RT_U2" = 2 ] && [ "$RT_U3" = 2 ] && [ "$RT_U4" = 2 ] && [ "$RT_U5" = 2 ] \
   && [ "$RT_U6" = 2 ] && [ "$RT_U7" = 2 ] && rt_intact "$RT_A1" && rt_intact "$RT_B1"; then
  ok "a missing, empty or unknown selector and --orphans with --thread are usage errors that remove nothing"
else
  fail "selector refusals rc=$RT_U1/$RT_U2/$RT_U3/$RT_U4/$RT_U5/$RT_U6/$RT_U7"
fi

# ---- authority: an idle loop between rounds is not retired ----
# Both turns are over and their queue owners exited — exactly what a paused loop looks like.
RT_NR="$(rt_cm --thread rt/alpha --yes)"; RT_NRC=$?
if [ "$RT_NRC" = 5 ] && grep -q '^clean-mounts-result v1 status=not-retired .* selected=0 ' <<<"$RT_NR" \
   && rt_intact "$RT_A1" && rt_intact "$RT_A2"; then
  ok "an idle, unretired thread (owner exited, no runner) selects nothing and exits 5"
else
  fail "an unretired thread was acted on (rc=$RT_NRC): $RT_NR"
fi
rt_state retire rt/alpha >/dev/null
rt_state retired rt/alpha >/dev/null; RT_R1=$?
rt_state retired rt_alpha >/dev/null; RT_R2=$?
[ "$RT_R1" = 0 ] && [ "$RT_R2" = 3 ] \
  && ok "retirement is keyed on the RAW thread: retiring rt/alpha does not retire rt_alpha" \
  || fail "retirement keying rc=$RT_R1/$RT_R2"

# ---- dry run, then apply: exactly A's two proven mounts ----
RT_DRY="$(rt_cm --thread rt/alpha)"; RT_DRC=$?
if [ "$RT_DRC" = 0 ] && rt_line "$RT_DRY" "$RT_A1" would-remove proven && rt_line "$RT_DRY" "$RT_A2" would-remove proven \
   && grep -q '^clean-mounts-result v1 status=ready mode=dry-run selected=2 ' <<<"$RT_DRY" \
   && ! grep -qF "path=$RT_B1" <<<"$RT_DRY" && rt_intact "$RT_A1" && rt_intact "$RT_A2"; then
  ok "the dry run names exactly A's two leg mounts, never B's, and removes nothing"
else
  fail "dry run (rc=$RT_DRC): $RT_DRY"
fi
RT_AP="$(rt_cm --thread rt/alpha --yes)"; RT_APC=$?
if [ "$RT_APC" = 0 ] && rt_line "$RT_AP" "$RT_A1" removed proven && rt_line "$RT_AP" "$RT_A2" removed proven \
   && grep -q '^clean-mounts-result v1 status=complete mode=apply selected=2 removed=2 ' <<<"$RT_AP" \
   && rt_gone "$RT_A1" && rt_gone "$RT_A2"; then
  ok "apply removes A's mounts and their worktree registrations, leaving no tombstone"
else
  fail "apply (rc=$RT_APC): $RT_AP"
fi
rt_intact "$RT_B1" && rt_intact "$RT_B2" \
  && ok "B's warm sessions, trees and metadata are intact after A is retired" \
  || fail "retiring A disturbed B's mounts"
[ "$(cat "$RT/.comms/grades/sets.tsv"; find "$RT/.comms" -type f -not -path '*/state/*' | sort | xargs cat 2>/dev/null | shasum)" = "$RT_LEDGER_B4" ] \
  && ok "replies, run records (usage evidence) and the set index are untouched" \
  || fail "cleanup changed a file under .comms"
RT_RE="$(rt_cm --thread rt/alpha --yes)"; RT_REC=$?
[ "$RT_REC" = 0 ] && rt_line "$RT_RE" "$RT_A1" absent already-absent && rt_line "$RT_RE" "$RT_A2" absent already-absent \
  && ok "a repeated apply is an idempotent success: both targets report absent" \
  || fail "repeat apply (rc=$RT_REC): $RT_RE"

# ---- scope: a busy target is a scoped skip; an unrelated live thread never blocks ----
RT_E1="$(rt_turn "$RT_ECHO" grok)"
rt_state retire "$RT_ECHO" >/dev/null
RT_EDRY="$(rt_cm --thread "$RT_ECHO")"
RT_EP="$(rt_live_claim "$RT_E1")"
RT_EB="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_EBC=$?
if rt_line "$RT_EDRY" "$RT_E1" would-remove proven && [ "$RT_EBC" = 3 ] && rt_line "$RT_EB" "$RT_E1" skipped busy-claim \
   && grep -q '^clean-mounts-result v1 status=retry ' <<<"$RT_EB" && rt_intact "$RT_E1"; then
  ok "a claim taken between the dry run and the apply is honoured: a scoped skip, exit 3"
else
  fail "busy target (rc=$RT_EBC): $RT_EB"
fi
rt_unclaim "$RT_E1" "$RT_EP"
# The race INSIDE one apply: a runner claims after the unlocked check and before ours.
cat > "$WORK/rt-hook-claim" <<EOF
#!/bin/bash
[ "\$1" = prechecked ] || exit 0
sleep 300 </dev/null >/dev/null 2>&1 & p=\$!
printf 'pid=%s\nfmt=v2\nstart=%s\nrun=race\n' "\$p" "\$(LC_ALL=C TZ=UTC ps -p "\$p" -o lstart= | tr -s ' ' | sed 's/^ *//; s/ *\$//')" > "\$3/.claim.98"
printf '%s' "\$p" > "$WORK/rt-hook-claim.pid"
EOF
chmod +x "$WORK/rt-hook-claim"
RT_RC="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-claim" rt_cm --thread "$RT_ECHO" --yes)"; RT_RCC=$?
kill "$(cat "$WORK/rt-hook-claim.pid" 2>/dev/null)" 2>/dev/null; rm -f "$RT_E1"/.claim.98
if [ "$RT_RCC" = 3 ] && rt_line "$RT_RC" "$RT_E1" skipped busy-claim && rt_intact "$RT_E1"; then
  ok "a claim that lands between the check and the exclusion claim preserves the mount"
else
  fail "in-run claim race (rc=$RT_RCC): $RT_RC"
fi
# A queue lease still present is a live (or stale — indistinguishable) owner: skipped, never removed.
RT_LEASE="$RT_HOME/.acpx/queues/$(printf '%s' "$(cat "$RT_E1/.state.record")" | shasum -a 256 | cut -c1-24).lock"
: > "$RT_LEASE"
RT_OW="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_OWC=$?
rm -f "$RT_LEASE"
[ "$RT_OWC" = 3 ] && rt_line "$RT_OW" "$RT_E1" skipped busy-owner && rt_intact "$RT_E1" \
  && ok "an acpx queue lease (live or stale) skips the target" || fail "owner lease (rc=$RT_OWC): $RT_OW"
# Stale pid evidence: an older-format claim naming a LIVE pid cannot be proven recycled.
sleep 300 </dev/null >/dev/null 2>&1 & RT_SP=$!
printf 'pid=%s\nrun=old\n' "$RT_SP" > "$RT_E1/.claim.99"
RT_ST="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_STC=$?
rt_unclaim "$RT_E1" "$RT_SP"
[ "$RT_STC" = 3 ] && rt_line "$RT_ST" "$RT_E1" skipped busy-claim && rt_intact "$RT_E1" \
  && ok "a live pid in a claim without a start time is never read as dead" || fail "stale pid (rc=$RT_STC): $RT_ST"

# ---- every gate refuses safely; each case restores the mount and re-proves it intact ----
rt_refused_at() {  # <thread> <kdir> <desc> <reason> — apply refuses with <reason>, exit 4, and the ident dir survives
  local out rc
  out="$(rt_cm --thread "$1" --yes)"; rc=$?
  if [ "$rc" = 4 ] && rt_line "$out" "$2" refused "$4" && [ -d "$2" ] \
     && grep -q '^clean-mounts-result v1 status=blocked ' <<<"$out"; then ok "$3"; else fail "$3 (rc=$rc): $out"; fi
}
rt_refused() { rt_refused_at "$RT_ECHO" "$RT_E1" "$@"; }
RT_REC_ID="$(cat "$RT_E1/.state.record")"
chmod 000 "$RT_E1/.state.record"; rt_refused "an unreadable session record refuses" state-unreadable
chmod 644 "$RT_E1/.state.record"
mv "$RT_E1/.state.record" "$WORK/rt-rec"; rt_refused "a tree without a session record refuses (owner unprovable)" state-missing
mv "$WORK/rt-rec" "$RT_E1/.state.record"
printf 'bad id!\n' > "$RT_E1/.state.record"; rt_refused "a corrupt session record refuses" state-corrupt
printf '%s\n' "$RT_REC_ID" > "$RT_E1/.state.record"
mv "$RT_E1/.state.home" "$WORK/rt-home-rec"; rt_refused "a record with no owner home refuses" owner-unprovable
mv "$WORK/rt-home-rec" "$RT_E1/.state.home"
cp "$RT_HOME/.acpx/sessions/$RT_REC_ID.json" "$WORK/rt-sess"
sed 's|"cwd": *"[^"]*"|"cwd": "/elsewhere"|' "$WORK/rt-sess" > "$RT_HOME/.acpx/sessions/$RT_REC_ID.json"
rt_refused "a session record that names another cwd refuses (owner uncorroborated)" owner-uncorroborated
cp "$WORK/rt-sess" "$RT_HOME/.acpx/sessions/$RT_REC_ID.json"
printf 'edit\n' >> "$RT_E1/view/tree/rt.txt"; rt_refused "a tree edited away from its artifact refuses as dirty" dirty
git -C "$RT" show "$RT_ART:rt.txt" > "$RT_E1/view/tree/rt.txt"
printf 'scratch\n' > "$RT_E1/view/tree/notes.txt"; rt_refused "an untracked file in the tree refuses as dirty" dirty
rm -f "$RT_E1/view/tree/notes.txt"
mkdir -p "$RT_E1/view/tree/.comms"; printf 'x\n' > "$RT_E1/view/tree/.comms/residue"
rt_refused "ignored residue in the tree refuses as dirty" dirty
rm -rf "$RT_E1/view/tree/.comms"
printf 'mine\n' > "$RT_E1/notes.txt"; rt_refused "an unknown entry beside the mount refuses" unknown-content
rm -f "$RT_E1/notes.txt"
# A pending generation is normal while a live runner restages: its claim is read first, so that
# is a scoped skip. Only with no live holder is it an abandoned restage that needs the runner.
mkdir "$RT_E1/.new.rtpend"; printf '%s\n' "$RT_E1/.new.rtpend" > "$RT_E1/.state.pending"
RT_PP="$(rt_live_claim "$RT_E1")"
RT_PG="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_PGC=$?
rt_unclaim "$RT_E1" "$RT_PP"
[ "$RT_PGC" = 3 ] && rt_line "$RT_PG" "$RT_E1" skipped busy-claim && [ -d "$RT_E1/.new.rtpend" ] && rt_intact "$RT_E1" \
  && ok "a live runner mid-restage (pending generation) is a scoped skip, not a refusal" \
  || fail "restage under a live claim (rc=$RT_PGC): $RT_PG"
rt_refused "a pending generation no live runner holds refuses" pending-generation
rm -rf "$RT_E1/.new.rtpend" "$RT_E1/.state.pending"
git -C "$RT" update-ref -d "refs/agent-comms/artifacts/$RT_ART"
rt_refused "a tree whose artifact is no longer retained refuses" artifact-unretained
git -C "$RT" update-ref "refs/agent-comms/artifacts/$RT_ART" "$RT_ART"
mv "$RT_E1/view/tree" "$WORK/rt-tree-real"; ln -s "$WORK/rt-tree-real" "$RT_E1/view/tree"
rt_refused "a symlink substituted for the tree is never followed" unsafe-path
rm "$RT_E1/view/tree"; mv "$WORK/rt-tree-real" "$RT_E1/view/tree"
mv "$RT_E1" "$RT_E1.real"; ln -s "$RT_E1.real" "$RT_E1"
RT_SY="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_SYC=$?
rm "$RT_E1"; mv "$RT_E1.real" "$RT_E1"
[ "$RT_SYC" = 4 ] && rt_line "$RT_SY" "$RT_E1" refused unsafe-path && rt_intact "$RT_E1" \
  && ok "a symlink substituted for the ident dir refuses and its target survives" || fail "ident symlink (rc=$RT_SYC): $RT_SY"
# A glob over an unlistable dir reads as EMPTY. An unlistable view hid its dirty tree from `-d`, so
# the registration went and the payload delete failed; once access returned, the replay deleted the
# tree nothing had verified. Absent is concluded only from a listing that worked.
printf 'unverified\n' > "$RT_E1/view/tree/sentinel.txt"; chmod u-rwx "$RT_E1/view"
RT_UV="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_UVC=$?
chmod u+rwx "$RT_E1/view"
RT_UV2="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_UV2C=$?
if [ "$RT_UVC" = 4 ] && rt_line "$RT_UV" "$RT_E1" refused content-unverifiable \
   && [ "$RT_UV2C" = 4 ] && rt_line "$RT_UV2" "$RT_E1" refused dirty \
   && [ -f "$RT_E1/view/tree/sentinel.txt" ] && rt_intact "$RT_E1" \
   && [ -z "$(ls -d "$(dirname "$RT_E1")/.retire.$(basename "$RT_E1")".* 2>/dev/null)" ]; then
  ok "an unlistable view refuses, and once access returns its unverified content is still judged and kept"
else
  fail "unlistable view (rc=$RT_UVC/$RT_UV2C): $RT_UV / $RT_UV2"
fi
rm -f "$RT_E1/view/tree/sentinel.txt"
mkdir -p "$RT_E1/.aside.rt1/held"; printf 'unverified\n' > "$RT_E1/.aside.rt1/held/sentinel.txt"; chmod u-r "$RT_E1"
RT_UI="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_UIC=$?
chmod u+r "$RT_E1"
[ "$RT_UIC" = 4 ] && rt_line "$RT_UI" "$RT_E1" refused content-unverifiable \
  && [ -f "$RT_E1/.aside.rt1/held/sentinel.txt" ] && rt_intact "$RT_E1" \
  && ok "a searchable but unlistable ident dir refuses: an aside it hides is never read as absent" \
  || fail "unlistable ident dir (rc=$RT_UIC): $RT_UI"
rm -rf "$RT_E1/.aside.rt1"
(cd "$RT" && env "$RP" hold "$RT_ECHO" >/dev/null 2>&1)
RT_HD="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_HDC=$?
(cd "$RT" && env "$RP" release "$RT_ECHO" >/dev/null 2>&1)
[ "$RT_HDC" = 4 ] && grep -q '^clean-mounts-result v1 status=blocked .* selected=0 ' <<<"$RT_HD" && rt_intact "$RT_E1" \
  && ok "a held (paused) thread is not cleaned even when retired" || fail "held thread (rc=$RT_HDC): $RT_HD"
# With every gate restored, the mount goes — while an UNRELATED thread holds a live claim, which
# the whole-store GC would refuse the entire repo-key over. It is neither read nor touched.
RT_BP="$(rt_live_claim "$RT_B1")"
RT_OK="$(rt_cm --thread "$RT_ECHO" --yes)"; RT_OKC=$?
if [ "$RT_OKC" = 0 ] && rt_line "$RT_OK" "$RT_E1" removed proven && rt_gone "$RT_E1" \
   && ! grep -qF "path=$RT_B1" <<<"$RT_OK" && [ -f "$RT_B1/.claim.99" ] && rt_intact "$RT_B1"; then
  ok "with every gate restored the mount is removed; a live claim on another thread neither blocks nor is touched"
else
  fail "restored mount beside a live unrelated claim (rc=$RT_OKC): $RT_OK"
fi
rt_unclaim "$RT_B1" "$RT_BP"

# ---- content under a gitlink is invisible to tree identity, so it refuses ----
# `git add -A` records a populated submodule's HEAD — never its edits or untracked files — and
# skips files dropped into an unpopulated one, so the tree still EQUALS the artifact in each case.
RT_SUB="$WORK/rt-sub"; git init -q -b main "$RT_SUB"; printf 'sub\n' > "$RT_SUB/s.txt"
git -C "$RT_SUB" add s.txt; git -C "$RT_SUB" -c user.email=t@t -c user.name=t commit -qm s
RT_SM_TREE="$(cd "$RT" && GIT_INDEX_FILE="$WORK/rt-sm.idx" git read-tree "$RT_ART" \
  && GIT_INDEX_FILE="$WORK/rt-sm.idx" git update-index --add --cacheinfo "160000,$(git -C "$RT_SUB" rev-parse HEAD),sm" \
  && GIT_INDEX_FILE="$WORK/rt-sm.idx" git write-tree)"
rm -f "$WORK/rt-sm.idx"
RT_SM_ART="$(git -C "$RT" -c user.email=t@t -c user.name=t commit-tree "$RT_SM_TREE" -p "$RT_HEAD" -m sm)"
git -C "$RT" update-ref "refs/agent-comms/artifacts/$RT_SM_ART" "$RT_SM_ART"
RT_S1="$(RT_ART="$RT_SM_ART" rt_turn rt-sierra grok)"; RT_SM="$RT_S1/view/tree/sm"
rt_state retire rt-sierra >/dev/null
rmdir "$RT_SM" && git clone -q "$RT_SUB" "$RT_SM" && printf 'edit\n' >> "$RT_SM/s.txt"
rt_refused_at rt-sierra "$RT_S1" "a modified file inside a populated submodule refuses" nested-repo
git -C "$RT_SM" checkout -q -- s.txt && printf 'new\n' > "$RT_SM/new.txt"
rt_refused_at rt-sierra "$RT_S1" "an untracked file inside a populated submodule refuses" nested-repo
rm -rf "$RT_SM" && mkdir "$RT_SM" && printf 'stray\n' > "$RT_SM/stray.txt"
rt_refused_at rt-sierra "$RT_S1" "a file dropped into an unpopulated submodule path refuses" nested-repo
rm -f "$RT_SM/stray.txt"
RT_SMR="$(rt_cm --thread rt-sierra --yes)"; RT_SMRC=$?
[ -n "$RT_S1" ] && [ "$RT_SMRC" = 0 ] && rt_line "$RT_SMR" "$RT_S1" removed proven && rt_gone "$RT_S1" \
  && ok "the same mount with its gitlink path left empty, as the checkout made it, is removed" \
  || fail "clean gitlink mount (rc=$RT_SMRC, s1=$RT_S1): $RT_SMR"

# ---- ownership that cannot be proven is report-only ----
# A turn whose run record is not in this repo's ledger: the copy exists, nothing proves whose.
RT_G1="$(rt_turn rt-gamma grok "" "$WORK/rt-unledgered")"
rt_state retire rt-gamma >/dev/null
RT_GM="$(rt_cm --thread rt-gamma --yes)"; RT_GMC=$?
[ "$RT_GMC" = 4 ] && rt_line "$RT_GM" "$RT_G1" ambiguous no-ownership-evidence && rt_intact "$RT_G1" \
  && ok "a copy no ledger attributes to the thread is reported, never removed" || fail "no evidence (rc=$RT_GMC): $RT_GM"
# B's grok leg thread `rt_alpha-grok` is ALSO a thread in its own right once a direct turn uses it.
mkdir -p "$RT/.comms/logs/rt-direct"
printf 'thread\trt_alpha-grok\nset\t\ndispatch\t\nround\t1\nrequest\tx\nartifact\t%s\nprovider\tgrok\nagent\tgrok\n' "$RT_ART" \
  > "$RT/.comms/logs/rt-direct/turn.tsv"
rt_state retire rt_alpha >/dev/null
RT_SH="$(rt_cm --thread rt_alpha --yes)"; RT_SHC=$?
if [ "$RT_SHC" = 4 ] && rt_line "$RT_SH" "$RT_B1" ambiguous shared-with-live-thread && rt_intact "$RT_B1" \
   && rt_line "$RT_SH" "$RT_B2" removed proven && rt_gone "$RT_B2"; then
  ok "a copy shared with a live thread of the leg's name is report-only; the unshared one goes"
else
  fail "shared ident (rc=$RT_SHC): $RT_SH"
fi
# The direct turn's record is the ONLY evidence that B1 is also rt_alpha-grok's. A record that is
# not a regular file, or sits behind a symlink, must refuse the call — never drop out of the scan
# and leave the panel ledger attributing the copy to retired rt_alpha alone.
RT_DREC="$RT/.comms/logs/rt-direct/turn.tsv"
mv "$RT_DREC" "$WORK/rt-direct.tsv"; ln -s "$WORK/rt-direct.tsv" "$RT_DREC"
RT_SL="$(rt_cm --thread rt_alpha --yes)"; RT_SLC=$?
rm -f "$RT_DREC"; mv "$WORK/rt-direct.tsv" "$RT_DREC"
[ "$RT_SLC" = 4 ] && rt_none "$RT_SL" && rt_intact "$RT_B1" \
  && ok "a symlinked direct-turn record refuses the whole call: the shared copy is never read as the leg's alone" \
  || fail "symlinked record (rc=$RT_SLC): $RT_SL"
mv "$RT/.comms/logs/rt-direct" "$WORK/rt-direct-dir"; ln -s "$WORK/rt-direct-dir" "$RT/.comms/logs/rt-direct"
RT_SD="$(rt_cm --thread rt_alpha --yes)"
rm -f "$RT/.comms/logs/rt-direct"; mv "$WORK/rt-direct-dir" "$RT/.comms/logs/rt-direct"
mv "$RT/.comms/logs" "$WORK/rt-logs-dir"; ln -s "$WORK/rt-logs-dir" "$RT/.comms/logs"
RT_SG="$(rt_cm --thread rt_alpha --yes)"
rm -f "$RT/.comms/logs"; mv "$WORK/rt-logs-dir" "$RT/.comms/logs"
mkdir -p "$RT/.comms/logs/rt-dirrec/turn.tsv"
RT_SR="$(rt_cm --thread rt_alpha --yes)"
rmdir "$RT/.comms/logs/rt-dirrec/turn.tsv" "$RT/.comms/logs/rt-dirrec"
rt_none "$RT_SD" && rt_none "$RT_SG" && rt_none "$RT_SR" && rt_intact "$RT_B1" \
  && ok "a symlinked run dir, a symlinked logs dir or a directory-shaped record refuses the whole call" \
  || fail "unverifiable record shapes: $RT_SD / $RT_SG / $RT_SR"
# A record cut short before its agent line (a run still writing it, or one written before records
# carried an agent) or a leg row missing its agent column is an UNATTRIBUTABLE use, never an absent
# one: dropping it left the panel ledger attributing the shared copy to retired rt_alpha alone.
cp "$RT_DREC" "$WORK/rt-direct.full"; cp "$RT/.comms/grades/sets.tsv" "$WORK/rt-sets.full"
sed '$d' "$WORK/rt-direct.full" > "$RT_DREC"
RT_TR="$(rt_cm --thread rt_alpha --yes)"; RT_TRC=$?
cp "$WORK/rt-direct.full" "$RT_DREC"
printf 'set-b\treq\trt_alpha-grok\t1\tplan\t%s\tv1\t%s\tgrok\n' "$RT_ART" "$RT_HEAD" >> "$RT/.comms/grades/sets.tsv"
RT_TS="$(rt_cm --thread rt_alpha --yes)"; RT_TSC=$?
cp "$WORK/rt-sets.full" "$RT/.comms/grades/sets.tsv"
if [ "$RT_TRC" = 4 ] && rt_line "$RT_TR" "$RT_B1" ambiguous ownership-unresolved \
   && [ "$RT_TSC" = 4 ] && rt_line "$RT_TS" "$RT_B1" ambiguous ownership-unresolved && rt_intact "$RT_B1"; then
  ok "a co-owner's record cut short before its agent, or a leg row without one, keeps the shared copy report-only"
else
  fail "incomplete co-owner evidence (rc=$RT_TRC/$RT_TSC): $RT_TR / $RT_TS"
fi
: > "$RT_DREC"
RT_TE="$(rt_cm --thread rt_alpha --yes)"; RT_TEC=$?
cp "$WORK/rt-direct.full" "$RT_DREC"
printf 'set-b\treq\n' >> "$RT/.comms/grades/sets.tsv"
RT_TN="$(rt_cm --thread rt_alpha --yes)"; RT_TNC=$?
cp "$WORK/rt-sets.full" "$RT/.comms/grades/sets.tsv"
[ "$RT_TEC" = 4 ] && rt_none "$RT_TE" && [ "$RT_TNC" = 4 ] && rt_none "$RT_TN" && rt_intact "$RT_B1" \
  && ok "a run record or set-index row that names no thread refuses the whole call" \
  || fail "threadless evidence (rc=$RT_TEC/$RT_TNC): $RT_TE / $RT_TN"
rt_state retire rt_alpha-grok >/dev/null
RT_SH2="$(rt_cm --thread rt_alpha --yes)"; RT_SH2C=$?
[ "$RT_SH2C" = 0 ] && rt_line "$RT_SH2" "$RT_B1" removed proven && rt_gone "$RT_B1" \
  && ok "once every thread sharing the copy is retired it is removed" || fail "shared then retired (rc=$RT_SH2C): $RT_SH2"
# Ownership is re-proven UNDER the claim: a direct turn on the leg thread `rt-lima-grok` — a live
# thread in its own right — is recorded after the unlocked check and before the claim.
rt_sets set-l "rt-lima-grok" grok
RT_L1="$(rt_turn "rt-lima-grok" grok set-l)"
rt_state retire rt-lima >/dev/null
cat > "$WORK/rt-hook-own" <<EOF
#!/bin/bash
[ "\$1" = prechecked ] || exit 0
mkdir -p "$RT/.comms/logs/rt-late"
printf 'thread\trt-lima-grok\nset\t\nagent\tgrok\nartifact\t%s\n' "$RT_ART" > "$RT/.comms/logs/rt-late/turn.tsv"
EOF
chmod +x "$WORK/rt-hook-own"
RT_LO="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-own" rt_cm --thread rt-lima --yes)"; RT_LOC=$?
if [ -n "$RT_L1" ] && [ "$RT_LOC" = 4 ] && rt_line "$RT_LO" "$RT_L1" ambiguous shared-with-live-thread && rt_intact "$RT_L1"; then
  ok "a live thread that starts sharing the copy before the claim keeps it: ownership is re-proven under the claim"
else
  fail "late shared use (rc=$RT_LOC, l1=$RT_L1): $RT_LO"
fi
rm -rf "$RT/.comms/logs/rt-late"
RT_LR="$(rt_cm --thread rt-lima --yes)"; RT_LRC=$?
[ "$RT_LRC" = 0 ] && rt_line "$RT_LR" "$RT_L1" removed proven && rt_gone "$RT_L1" \
  && ok "the refused apply released its claim: once the late use is gone the next apply removes the copy" \
  || fail "after the late use (rc=$RT_LRC): $RT_LR"
# The set index's first line is skipped only once it proves to be the header. Here LIVE thread
# rt-hotel's leg row is the only evidence that retired direct thread rt-hotel-grok's copy is shared:
# an index that opens with that row (no header), or with a header naming other columns, must refuse
# the call — never drop the row and read the copy as rt-hotel-grok's alone.
RT_IDX="$RT/.comms/grades/sets.tsv"
RT_H1="$(rt_turn rt-hotel-grok grok)"
rt_sets set-h "rt-hotel-grok" grok
rt_state retire rt-hotel-grok >/dev/null
RT_HX="$(rt_cm --thread rt-hotel-grok --yes)"; RT_HXC=$?
cp "$RT_IDX" "$WORK/rt-sets.hdr"
{ sed -n '$p' "$WORK/rt-sets.hdr"; sed '1d;$d' "$WORK/rt-sets.hdr"; } > "$RT_IDX"
RT_HN="$(rt_cm --thread rt-hotel-grok --yes)"; RT_HNC=$?
{ sed -n '1p' "$WORK/rt-sets.hdr" | awk -F'\t' -v OFS='\t' '{ t = $3; $3 = $10; $10 = t; print }'; sed '1d' "$WORK/rt-sets.hdr"; } > "$RT_IDX"
RT_HW="$(rt_cm --thread rt-hotel-grok --yes)"; RT_HWC=$?
cp "$WORK/rt-sets.hdr" "$RT_IDX"
if [ -n "$RT_H1" ] && [ "$RT_HXC" = 4 ] && rt_line "$RT_HX" "$RT_H1" ambiguous shared-with-live-thread \
   && [ "$RT_HNC" = 4 ] && rt_none "$RT_HN" && [ "$RT_HWC" = 4 ] && rt_none "$RT_HW" && rt_intact "$RT_H1"; then
  ok "a set index without its header, or whose header names other columns, refuses: a live co-owner's first row is never skipped"
else
  fail "set index header (rc=$RT_HXC/$RT_HNC/$RT_HWC, h1=$RT_H1): $RT_HX / $RT_HN / $RT_HW"
fi

# ---- evidence that cannot be read refuses the whole call before anything is selected ----
RT_M1="$(rt_turn rt-mike grok)"
rt_state retire rt-mike >/dev/null
RT_MK="$(ls "$RT/.comms/state/retired/"rt-mike-* 2>/dev/null | head -1)"
cp "$RT_MK" "$WORK/rt-marker"; printf 'thread=rt-other\nretired_at=x\n' > "$RT_MK"
RT_MC="$(rt_cm --thread rt-mike --yes)"; RT_MCC=$?
rt_state retired rt-mike >/dev/null; RT_MRC=$?
cp "$WORK/rt-marker" "$RT_MK"
if [ -n "$RT_M1" ] && [ -n "$RT_MK" ] && [ "$RT_MCC" = 4 ] && [ "$RT_MRC" = 4 ] \
   && grep -q '^clean-mounts-result v1 status=blocked .* selected=0 ' <<<"$RT_MC" && rt_intact "$RT_M1"; then
  ok "a retirement marker that names another thread is unverifiable: exit 4, nothing selected"
else
  fail "corrupt marker (rc=$RT_MCC/$RT_MRC, m1=$RT_M1): $RT_MC"
fi
chmod 000 "$RT/.comms/grades/sets.tsv"
RT_LS="$(rt_cm --thread rt-mike --yes)"; RT_LSC=$?
chmod 644 "$RT/.comms/grades/sets.tsv"
RT_RUN1="$(ls -d "$RT/.comms/logs/"*/turn.tsv | head -1)"
chmod 000 "$RT_RUN1"
RT_LT="$(rt_cm --thread rt-mike --yes)"; RT_LTC=$?
chmod 644 "$RT_RUN1"
if [ "$RT_LSC" = 4 ] && [ "$RT_LTC" = 4 ] && grep -q '^clean-mounts-result v1 status=blocked .* selected=0 ' <<<"$RT_LS" \
   && grep -q '^clean-mounts-result v1 status=blocked .* selected=0 ' <<<"$RT_LT" && rt_intact "$RT_M1"; then
  ok "an unreadable set index or run record refuses the whole call: ownership is never proven on partial evidence"
else
  fail "unreadable ledger (rc=$RT_LSC/$RT_LTC): $RT_LS / $RT_LT"
fi

# ---- interruption at each destructive boundary: the re-run finishes, peers are untouched ----
RT_PEER="$RT_G1"   # unproven, so every run below must leave it exactly as it is
cat > "$WORK/rt-hook-kill" <<'EOF'
#!/bin/bash
[ "$1" = "$RT_KILL_AT" ] && kill -9 "$PPID"
exit 0
EOF
chmod +x "$WORK/rt-hook-kill"
rt_state retire rt-kilo >/dev/null
for RT_AT in tombstoned renamed unregistered; do
  RT_K="$(rt_turn rt-kilo grok)"
  RT_KO="$(RT_KILL_AT="$RT_AT" COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-kilo --yes 2>/dev/null)"; RT_KOC=$?
  RT_KR="$(rt_cm --thread rt-kilo --yes)"; RT_KRC=$?
  if [ -n "$RT_K" ] && [ "$RT_KOC" = 137 ] && ! grep -q '^clean-mounts-result' <<<"$RT_KO" \
     && [ "$RT_KRC" = 0 ] && grep -q '^clean-mounts-result v1 status=complete .* removed=1 ' <<<"$RT_KR" \
     && rt_gone "$RT_K" && rt_intact "$RT_PEER"; then
    ok "killed after '$RT_AT': the re-run completes the removal and the peer is untouched"
  else
    fail "killed after '$RT_AT' (rc=$RT_KOC then $RT_KRC, k=$RT_K): $RT_KR"
  fi
done
# A removal that cannot finish is reported as incomplete — never as removed — and resumes later.
RT_K="$(rt_turn rt-kilo grok)"
cat > "$WORK/rt-hook-lock" <<'EOF'
#!/bin/bash
[ "$1" = renamed ] && printf 'x\n' > "$3/$2/home/pinned" && chmod 000 "$3/$2/home"
exit 0
EOF
chmod +x "$WORK/rt-hook-lock"
RT_IN="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-lock" rt_cm --thread rt-kilo --yes)"; RT_INC=$?
RT_TOMB="$(ls -d "$RT_STORE"/*/.retire."$(basename "$RT_K")".* 2>/dev/null | head -1)"
if [ "$RT_INC" = 3 ] && rt_line "$RT_IN" "$RT_K" incomplete remove-failed && [ -n "$RT_TOMB" ] && [ ! -e "$RT_K" ]; then
  ok "a removal blocked mid-delete reports incomplete (exit 3) and keeps its tombstone"
else
  fail "incomplete removal (rc=$RT_INC): $RT_IN"
fi
[ -n "$RT_TOMB" ] && chmod 755 "$RT_TOMB/$(basename "$RT_K")/home" 2>/dev/null
RT_IR="$(rt_cm --thread rt-kilo --yes)"; RT_IRC=$?
[ "$RT_IRC" = 0 ] && rt_line "$RT_IR" "$RT_K" removed interrupted && rt_gone "$RT_K" && rt_intact "$RT_PEER" \
  && ok "the re-run finishes the kept tombstone and reports it removed" || fail "resume after incomplete (rc=$RT_IRC): $RT_IR"
# The registration's back-pointer is deleted LAST, so a delete obstructed INSIDE the admin dir
# keeps what the re-run re-proves it by: once the obstruction is gone the re-run finishes.
cat > "$WORK/rt-hook-admlock" <<'EOF'
#!/bin/bash
[ "$1" = renamed ] || exit 0
a="$(cat "$3/$2/.state.admin")"
mkdir -p "$a/logs" && printf 'x\n' > "$a/logs/pinned" && chmod 000 "$a/logs"
exit 0
EOF
chmod +x "$WORK/rt-hook-admlock"
RT_K="$(rt_turn rt-kilo grok)"; RT_KADM="$(cat "$RT_K/.state.admin" 2>/dev/null)"
RT_AI="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-admlock" rt_cm --thread rt-kilo --yes)"; RT_AIC=$?
RT_AT="$(ls -d "$RT_STORE"/*/.retire."$(basename "$RT_K")".* 2>/dev/null | head -1)"
if [ -n "$RT_KADM" ] && [ "$RT_AIC" = 3 ] && rt_line "$RT_AI" "$RT_K" incomplete admin-remove-failed && [ -n "$RT_AT" ] \
   && [ "$(cat "$RT_KADM/gitdir" 2>/dev/null)" = "$RT_K/view/tree/.git" ] && grep -qxF "admin=$RT_KADM" "$RT_AT/record" \
   && [ -f "$RT_AT/$(basename "$RT_K")/view/tree/rt.txt" ]; then
  ok "a delete obstructed inside the admin dir is incomplete and keeps the registration's back-pointer and the payload"
else
  fail "obstructed admin delete (rc=$RT_AIC, adm=$RT_KADM, tomb=$RT_AT): $RT_AI"
fi
[ -n "$RT_KADM" ] && chmod 755 "$RT_KADM/logs" 2>/dev/null
RT_AR="$(rt_cm --thread rt-kilo --yes)"; RT_ARC=$?
[ "$RT_ARC" = 0 ] && rt_line "$RT_AR" "$RT_K" removed interrupted && rt_gone "$RT_K" && [ -n "$RT_KADM" ] && [ ! -e "$RT_KADM" ] \
  && rt_intact "$RT_PEER" \
  && ok "with the admin dir's obstruction gone the re-run re-proves the registration and finishes" \
  || fail "resume obstructed admin delete (rc=$RT_ARC): $RT_AR"
# Without its back-pointer an admin dir still holding anything proves nothing, and one a copy
# re-created at the ident claims is that copy's (git hands it the freed name, same back-pointer):
# both are left for a human. One emptied down to itself registers nothing and holds nothing to lose.
RT_K="$(rt_turn rt-kilo grok)"; RT_KADM="$(cat "$RT_K/.state.admin" 2>/dev/null)"
RT_KILL_AT=renamed COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-kilo --yes >/dev/null 2>&1
RT_ET="$(ls -d "$RT_STORE"/*/.retire."$(basename "$RT_K")".* 2>/dev/null | head -1)"
RT_EUC=x; RT_ELC=x
if [ -n "$RT_ET" ] && [ -n "$RT_KADM" ] && mv "$RT_KADM/gitdir" "$WORK/rt-gitdir"; then
  RT_EU="$(rt_cm --thread rt-kilo --yes)"; RT_EUC=$?
  mv "$WORK/rt-gitdir" "$RT_KADM/gitdir"
  mkdir -p "$RT_K/view/tree"; printf 'gitdir: %s\n' "$RT_KADM" > "$RT_K/view/tree/.git"
  RT_EL="$(rt_cm --thread rt-kilo --yes)"; RT_ELC=$?
  rm -rf "$RT_K"
fi
if [ "$RT_EUC" = 3 ] && rt_line "$RT_EU" "$RT_K" incomplete admin-unverified \
   && [ "$RT_ELC" = 3 ] && rt_line "$RT_EL" "$RT_K" incomplete admin-unverified \
   && [ -f "$RT_KADM/gitdir" ] && [ -f "$RT_KADM/HEAD" ] && [ -f "$RT_ET/$(basename "$RT_K")/view/tree/rt.txt" ]; then
  ok "an admin dir with no back-pointer, or one a re-created copy's gitfile names, is left with the payload"
else
  fail "unprovable admin dir (rc=$RT_EUC/$RT_ELC, tomb=$RT_ET): $RT_EU / $RT_EL"
fi
[ -n "$RT_KADM" ] && [ -d "$RT_KADM" ] && find "$RT_KADM" -mindepth 1 -delete 2>/dev/null
RT_EE="$(rt_cm --thread rt-kilo --yes)"; RT_EEC=$?
[ "$RT_EEC" = 0 ] && rt_line "$RT_EE" "$RT_K" removed interrupted && rt_gone "$RT_K" && [ ! -e "$RT_KADM" ] && rt_intact "$RT_PEER" \
  && ok "an admin dir emptied down to itself is dropped and the re-run finishes" \
  || fail "emptied admin dir (rc=$RT_EEC): $RT_EE"
# Whether a tombstone received the ident is read from its listing, and a glob over a searchable but
# unlistable one reads as EMPTY: the registration went, the payload was skipped as never moved, and
# dropping the "empty" tombstone deleted its journal beside the payload, which every later replay
# then refused for good. Nothing is touched until it lists, and the journal goes only once it
# provably holds nothing else.
cat > "$WORK/rt-hook-unlist" <<'EOF'
#!/bin/bash
[ "$1" = renamed ] && chmod u-r "$3"
exit 0
EOF
chmod +x "$WORK/rt-hook-unlist"
RT_K="$(rt_turn rt-kilo grok)"; RT_KADM="$(cat "$RT_K/.state.admin" 2>/dev/null)"
RT_UL="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-unlist" rt_cm --thread rt-kilo --yes)"; RT_ULC=$?
RT_UT="$(ls -d "$RT_STORE"/*/.retire."$(basename "$RT_K")".* 2>/dev/null | head -1)"
RT_UD="$(rt_cm --thread rt-kilo)"; RT_UDC=$?
if [ -n "$RT_K" ] && [ -n "$RT_KADM" ] && [ "$RT_ULC" = 4 ] && rt_line "$RT_UL" "$RT_K" refused content-unverifiable \
   && [ "$RT_UDC" = 4 ] && rt_line "$RT_UD" "$RT_K" refused content-unverifiable && [ -n "$RT_UT" ] \
   && grep -qxF "admin=$RT_KADM" "$RT_UT/record" && [ "$(cat "$RT_KADM/gitdir" 2>/dev/null)" = "$RT_K/view/tree/.git" ] \
   && [ -f "$RT_UT/$(basename "$RT_K")/view/tree/rt.txt" ]; then
  ok "an unlistable tombstone refuses in dry run and apply, keeping its journal, registration and payload"
else
  fail "unlistable tombstone (rc=$RT_ULC/$RT_UDC, tomb=$RT_UT): $RT_UL / $RT_UD"
fi
[ -n "$RT_UT" ] && chmod u+r "$RT_UT"
RT_UR="$(rt_cm --thread rt-kilo --yes)"; RT_URC=$?
[ "$RT_URC" = 0 ] && rt_line "$RT_UR" "$RT_K" removed interrupted && rt_gone "$RT_K" && [ -n "$RT_KADM" ] && [ ! -e "$RT_KADM" ] \
  && rt_intact "$RT_PEER" \
  && ok "once the tombstone lists again the re-run finishes the removal from its journal" \
  || fail "resume unlistable tombstone (rc=$RT_URC): $RT_UR"
# One level up, the same glob finds the tombstone in the scope: an unlistable scope hid it, and the
# moved ident read as already absent — a success report beside a payload nothing removed.
RT_K="$(rt_turn rt-kilo grok)"; RT_SS="$(dirname "$RT_K")"
RT_KILL_AT=renamed COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-kilo --yes >/dev/null 2>&1
RT_ST2="$(ls -d "$RT_SS"/.retire."$(basename "$RT_K")".* 2>/dev/null | head -1)"
chmod u-r "$RT_SS"
RT_SL="$(rt_cm --thread rt-kilo --yes)"; RT_SLC=$?
chmod u+r "$RT_SS"
RT_SR="$(rt_cm --thread rt-kilo --yes)"; RT_SRC=$?
if [ -n "$RT_K" ] && [ -n "$RT_ST2" ] && [ "$RT_SLC" = 1 ] && grep -q '^clean-mounts-result v1 status=store-error ' <<<"$RT_SL" \
   && ! grep -q '^clean-mounts-target ' <<<"$RT_SL" \
   && [ "$RT_SRC" = 0 ] && rt_line "$RT_SR" "$RT_K" removed interrupted && rt_gone "$RT_K" && rt_intact "$RT_PEER"; then
  ok "an unlistable scope refuses the call before any target, and the re-run finishes the hidden tombstone"
else
  fail "unlistable scope (rc=$RT_SLC/$RT_SRC, tomb=$RT_ST2): $RT_SL / $RT_SR"
fi
# The journal is published through a file created exclusively for it. A staging entry left in a
# tombstone is at most a plain file: a symlink there — to a peer's file — refuses before anything
# is deleted and is never written through, and a plain leftover is cleared with the tombstone.
RT_K="$(rt_turn rt-kilo grok)"
RT_KILL_AT=renamed COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-kilo --yes >/dev/null 2>&1
RT_ST="$(ls -d "$RT_STORE"/*/.retire."$(basename "$RT_K")".* 2>/dev/null | head -1)"
printf 'peer\n' > "$WORK/rt-sentinel"
RT_SAC=x; RT_SBC=x
if [ -n "$RT_ST" ]; then
  ln -s "$WORK/rt-sentinel" "$RT_ST/record.tmp"
  RT_SA="$(rt_cm --thread rt-kilo --yes)"; RT_SAC=$?
  rm -f "$RT_ST/record.tmp"; ln -s "$WORK/rt-sentinel" "$RT_ST/record.Zz9Zz9"
  RT_SB="$(rt_cm --thread rt-kilo --yes)"; RT_SBC=$?
  rm -f "$RT_ST/record.Zz9Zz9"
fi
if [ "$RT_SAC" = 4 ] && rt_line "$RT_SA" "$RT_K" refused unknown-content \
   && [ "$RT_SBC" = 4 ] && rt_line "$RT_SB" "$RT_K" refused unsafe-path \
   && [ "$(cat "$WORK/rt-sentinel")" = peer ] && [ -f "$RT_ST/$(basename "$RT_K")/view/tree/rt.txt" ] && rt_reg "$RT_K"; then
  ok "a symlinked staging entry in an interrupted tombstone refuses, deletes nothing and leaves its target unchanged"
else
  fail "symlinked journal staging (rc=$RT_SAC/$RT_SBC, tomb=$RT_ST, sentinel=$(cat "$WORK/rt-sentinel")): $RT_SA / $RT_SB"
fi
[ -n "$RT_ST" ] && printf 'half' > "$RT_ST/record.Qq1Qq1"
RT_SC="$(rt_cm --thread rt-kilo --yes)"; RT_SCC=$?
[ "$RT_SCC" = 0 ] && rt_line "$RT_SC" "$RT_K" removed interrupted && rt_gone "$RT_K" && [ "$(cat "$WORK/rt-sentinel")" = peer ] \
  && rt_intact "$RT_PEER" \
  && ok "a plain staging file left by an interrupted journal write is cleared and the re-run finishes" \
  || fail "leftover journal staging (rc=$RT_SCC): $RT_SC"

# The journal names its owner: a record another thread's cleanup wrote, or one missing a field,
# is never replayed — the copy in it stays until its own thread's cleanup finishes it.
RT_K="$(rt_turn rt-kilo grok)"
RT_KILL_AT=renamed COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-kilo --yes >/dev/null 2>&1
RT_KT="$(ls -d "$RT_STORE"/*/.retire."$(basename "$RT_K")".* 2>/dev/null | head -1)"
if [ -n "$RT_KT" ] && [ -f "$RT_KT/record" ]; then
  cp "$RT_KT/record" "$WORK/rt-krec"
  sed 's/^thread=.*/thread=rt-other/' "$WORK/rt-krec" > "$RT_KT/record"
  RT_KF="$(rt_cm --thread rt-kilo --yes)"; RT_KFC=$?
  grep -v '^run=' "$WORK/rt-krec" > "$RT_KT/record"
  RT_KU="$(rt_cm --thread rt-kilo --yes)"; RT_KUC=$?
  cp "$WORK/rt-krec" "$RT_KT/record"
fi
if [ -n "$RT_KT" ] && [ "$RT_KFC" = 4 ] && rt_line "$RT_KF" "$RT_K" ambiguous foreign-tombstone \
   && [ "$RT_KUC" = 4 ] && rt_line "$RT_KU" "$RT_K" refused tombstone-unverifiable \
   && [ -f "$RT_KT/$(basename "$RT_K")/view/tree/rt.txt" ] && rt_reg "$RT_K"; then
  ok "a tombstone whose record names another thread, or lacks its owner, is left with its copy and registration"
else
  fail "foreign/partial journal (rc=$RT_KFC/$RT_KUC, tomb=$RT_KT): $RT_KF / $RT_KU"
fi
RT_KR="$(rt_cm --thread rt-kilo --yes)"; RT_KRC=$?
[ "$RT_KRC" = 0 ] && rt_line "$RT_KR" "$RT_K" removed interrupted && rt_gone "$RT_K" && rt_intact "$RT_PEER" \
  && ok "with its own record restored the thread's re-run finishes the removal" || fail "restored journal (rc=$RT_KRC): $RT_KR"

# ---- a replay is a removal: the authority and ownership gates run before it, and under its claim ----
# The interrupted run proved them once. A hold on the leg (a paused loop), a withdrawn retirement or
# a live co-owner recorded since must each keep the journal, the moved copy and its registration.
rt_sets set-j "rt-juliet-grok" grok
rt_state retire rt-juliet >/dev/null
RT_J="$(rt_turn "rt-juliet-grok" grok set-j)"
RT_KILL_AT=renamed COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-juliet --yes >/dev/null 2>&1
RT_JT="$(ls -d "$RT_STORE"/*/.retire."$(basename "$RT_J")".* 2>/dev/null | head -1)"
rt_jtomb() {  # the journal, the moved copy and its registration are exactly as the kill left them
  [ -n "$RT_JT" ] && [ -f "$RT_JT/record" ] && [ -f "$RT_JT/$(basename "$RT_J")/view/tree/rt.txt" ] \
    && rt_reg "$RT_J" && [ ! -e "$RT_J" ]
}
(cd "$RT" && env "$RP" hold rt-juliet-grok >/dev/null 2>&1)
RT_JD="$(rt_cm --thread rt-juliet)"; RT_JDC=$?
RT_JA="$(rt_cm --thread rt-juliet --yes)"; RT_JAC=$?
(cd "$RT" && env "$RP" release rt-juliet-grok >/dev/null 2>&1)
if [ -n "$RT_J" ] && [ "$RT_JDC" = 4 ] && rt_line "$RT_JD" "$RT_J" refused held \
   && [ "$RT_JAC" = 4 ] && rt_line "$RT_JA" "$RT_J" refused held && rt_jtomb; then
  ok "a held leg's interrupted removal is refused before its tombstone is replayed, in dry run and apply"
else
  fail "held leg replay (rc=$RT_JDC/$RT_JAC, j=$RT_J, tomb=$RT_JT): $RT_JD / $RT_JA"
fi
cat > "$WORK/rt-hook-regate" <<EOF
#!/bin/bash
[ "\$1" = reclaimed ] || exit 0
case "\$RT_REGATE" in
  hold) "$RP" hold rt-juliet-grok ;;
  unretire) "$COMMS" state unretire rt-juliet ;;
  share) mkdir -p "$RT/.comms/logs/rt-jshare"
         printf 'thread\trt-juliet-grok\nset\t\nagent\tgrok\nartifact\t%s\n' "$RT_ART" > "$RT/.comms/logs/rt-jshare/turn.tsv" ;;
esac >/dev/null 2>&1
exit 0
EOF
chmod +x "$WORK/rt-hook-regate"
RT_JH="$(RT_REGATE=hold COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-regate" rt_cm --thread rt-juliet --yes)"; RT_JHC=$?
(cd "$RT" && env "$RP" release rt-juliet-grok >/dev/null 2>&1)
RT_JU="$(RT_REGATE=unretire COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-regate" rt_cm --thread rt-juliet --yes)"; RT_JUC=$?
rt_state retire rt-juliet >/dev/null
RT_JS="$(RT_REGATE=share COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-regate" rt_cm --thread rt-juliet --yes)"; RT_JSC=$?
if [ "$RT_JHC" = 4 ] && rt_line "$RT_JH" "$RT_J" refused held \
   && [ "$RT_JUC" = 4 ] && rt_line "$RT_JU" "$RT_J" refused unretired \
   && [ "$RT_JSC" = 4 ] && rt_line "$RT_JS" "$RT_J" ambiguous shared-with-live-thread && rt_jtomb; then
  ok "a hold, a withdrawn retirement or a live co-owner appearing under the replay's claim keeps the tombstone whole"
else
  fail "replay re-gate (rc=$RT_JHC/$RT_JUC/$RT_JSC): $RT_JH / $RT_JU / $RT_JS"
fi
# Ownership refused at SELECTION, before any claim: the ident path is gone (its copy sits in the
# tombstone), so a report keyed on that path alone let the pending removal read as complete.
RT_JCD="$(rt_cm --thread rt-juliet)"; RT_JCDC=$?
RT_JC="$(rt_cm --thread rt-juliet --yes)"; RT_JCC=$?
rm -rf "$RT/.comms/logs/rt-jshare"
if [ "$RT_JCDC" = 4 ] && rt_line "$RT_JCD" "$RT_J" ambiguous shared-with-live-thread \
   && [ "$RT_JCC" = 4 ] && rt_line "$RT_JC" "$RT_J" ambiguous shared-with-live-thread \
   && grep -q '^clean-mounts-result v1 status=blocked ' <<<"$RT_JC" && rt_jtomb; then
  ok "a co-owner still recorded at the next run reports the pending tombstone and replays nothing, in dry run and apply"
else
  fail "co-owner before the retry (rc=$RT_JCDC/$RT_JCC): $RT_JCD / $RT_JC"
fi
mkdir -p "$RT/.comms/logs/rt-jagentless"
printf 'thread\trt-juliet-grok\nset\t\nartifact\t%s\n' "$RT_ART" > "$RT/.comms/logs/rt-jagentless/turn.tsv"
RT_JN="$(rt_cm --thread rt-juliet --yes)"; RT_JNC=$?
rm -rf "$RT/.comms/logs/rt-jagentless"
if [ "$RT_JNC" = 4 ] && rt_line "$RT_JN" "$RT_J" ambiguous ownership-unresolved \
   && grep -q '^clean-mounts-result v1 status=blocked ' <<<"$RT_JN" && rt_jtomb; then
  ok "an agentless record present before the retry reports the pending tombstone and replays nothing"
else
  fail "agentless record before the retry (rc=$RT_JNC): $RT_JN"
fi
RT_JR="$(rt_cm --thread rt-juliet --yes)"; RT_JRC=$?
[ "$RT_JRC" = 0 ] && rt_line "$RT_JR" "$RT_J" removed interrupted && rt_gone "$RT_J" && rt_intact "$RT_PEER" \
  && ok "with every gate restored the replay finishes the interrupted removal" \
  || fail "replay after the re-gate (rc=$RT_JRC): $RT_JR"

# ---- two applies at once: a live cleanup's tombstone is never replayed from under it ----
# A second apply of the same thread runs INSIDE the first, at the boundary under test, and must
# find the tombstone claimed by a live maker: a scoped skip that leaves the journal as it was.
cat > "$WORK/rt-hook-peer" <<EOF
#!/bin/bash
[ -z "\${RT_NESTED:-}" ] && [ "\$1" = "\$RT_PEER_AT" ] || exit 0
RT_NESTED=1 "$RP" clean-mounts --thread rt-oscar --yes > "$WORK/rt-peer.out" 2>&1
echo \$? > "$WORK/rt-peer.rc"
{ [ -f "\$3/record" ] && echo record; [ -d "\$3/\$2" ] && echo moved; } > "$WORK/rt-peer.tomb"
EOF
chmod +x "$WORK/rt-hook-peer"
rt_state retire rt-oscar >/dev/null
for RT_AT in tombstoned renamed; do
  RT_O="$(rt_turn rt-oscar grok)"
  rm -f "$WORK/rt-peer.out" "$WORK/rt-peer.rc" "$WORK/rt-peer.tomb"
  RT_OA="$(RT_PEER_AT="$RT_AT" COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-peer" rt_cm --thread rt-oscar --yes)"; RT_OAC=$?
  RT_OB="$(cat "$WORK/rt-peer.out" 2>/dev/null)"
  if [ "$RT_AT" = tombstoned ]; then RT_OW=record; else RT_OW="record moved"; fi
  if [ -n "$RT_O" ] && [ "$(cat "$WORK/rt-peer.rc" 2>/dev/null)" = 3 ] && rt_line "$RT_OB" "$RT_O" skipped busy-cleanup \
     && [ "$(tr '\n' ' ' < "$WORK/rt-peer.tomb" 2>/dev/null)" = "$RT_OW " ] \
     && [ "$RT_OAC" = 0 ] && rt_line "$RT_OA" "$RT_O" removed proven && rt_gone "$RT_O"; then
    ok "a second apply at '$RT_AT' skips the live cleanup's tombstone, which then finishes its own removal"
  else
    fail "concurrent apply at '$RT_AT' (rc=$RT_OAC, o=$RT_O, peer rc=$(cat "$WORK/rt-peer.rc" 2>/dev/null) tomb=$(cat "$WORK/rt-peer.tomb" 2>/dev/null)): $RT_OA / $RT_OB"
  fi
done

# ---- a crashed run's disposable copy is the thread's too, when it names that run ----
# The runner records the physical run dir a throwaway was made for; a real degraded turn shows it.
RT_X1="$(rt_turn rt-xray grok)"; printf 'bad id!\n' > "$RT_X1/.state.record"
RT_XD="$RT/.comms/logs/rt-xray-run"; mkdir -p "$RT_XD"
export AX_KDIR_RUN_LOG="$WORK/rt-kdir-run.log"; : > "$AX_KDIR_RUN_LOG"
RT_X2="$(rt_turn rt-xray grok "" "$RT_XD")"
unset AX_KDIR_RUN_LOG
case "$RT_X2" in */tmp-rt-xray-run) RT_XT=1 ;; *) RT_XT=0 ;; esac
[ "$RT_XT" = 1 ] && [ "$(sed -n '$p' "$WORK/rt-kdir-run.log")" = "$(cd "$RT_XD" && pwd -P)" ] && [ ! -e "$RT_X2" ] \
  && ok "a degraded turn's throwaway records the physical run dir it was made for" \
  || fail "throwaway run record (x2=$RT_X2): $(cat "$WORK/rt-kdir-run.log")"
# The shape a runner killed mid-turn on a degrade path leaves: a registered worktree holding the
# artifact, its session bookkeeping, the run it was made for, and the runner's claim with a dead pid.
RT_KEYDIR="$(dirname "$RT_PEER")"
rt_tmp() {  # <run dir> <thread> [--no-run] — record the run as the thread's and leave its crashed throwaway; prints its path
  local rd="$1" tw dead
  mkdir -p "$rd"; printf 'thread\t%s\nset\t\nagent\tgrok\nartifact\t%s\n' "$2" "$RT_ART" > "$rd/turn.tsv"
  tw="$RT_KEYDIR/tmp-$(printf '%s' "$(basename "$rd")" | tr -c 'A-Za-z0-9._-' '_')"
  mkdir -p "$tw/view" "$tw/home"
  git -C "$RT" worktree add -q --detach "$tw/view/tree" "$RT_HEAD" >/dev/null 2>&1
  git -C "$tw/view/tree" read-tree -u --reset "$RT_ART" && git -C "$tw/view/tree" reset -q --mixed "$RT_HEAD"
  git -C "$tw/view/tree" rev-parse --absolute-git-dir > "$tw/.state.admin"
  printf '%s-rec\n' "${tw##*/}" > "$tw/.state.record"; printf '%s\n' "$RT_HOME" > "$tw/.state.home"
  printf '{\n  "cwd": "%s",\n  "name": "x"\n}\n' "$tw/view/tree" > "$RT_HOME/.acpx/sessions/${tw##*/}-rec.json"
  ( exit 0 ) & dead=$!; wait "$dead"
  printf 'pid=%s\nrun=%s\n' "$dead" "$rd" > "$tw/.claim.0"
  [ "${3:-}" = --no-run ] || (cd "$rd" && pwd -P) > "$tw/.state.run"
  printf '%s' "$tw"
}
RT_TD="$RT/.comms/logs/rt-tmp-run"
RT_TW="$(rt_tmp "$RT_TD" rt-tango --no-run)"
rt_state retire rt-tango >/dev/null
RT_TN="$(rt_cm --thread rt-tango --yes)"; RT_TNC=$?
[ "$RT_TNC" = 4 ] && rt_line "$RT_TN" "$RT_TW" ambiguous no-ownership-evidence && rt_intact "$RT_TW" \
  && ok "a throwaway that records no run is report-only: its name alone proves nothing" \
  || fail "throwaway without a run record (rc=$RT_TNC): $RT_TN"
(cd "$RT_TD" && pwd -P) > "$RT_TW/.state.run"
RT_TT="$(rt_cm --thread rt-tango --yes)"; RT_TTC=$?
[ "$RT_TTC" = 0 ] && grep -F " path=$RT_TW" <<<"$RT_TT" | grep_full -q "status=removed reason=proven kind=throwaway use=run " \
  && rt_gone "$RT_TW" && rt_intact "$RT_PEER" \
  && ok "a crashed run's throwaway copy that names the thread's run is selected and removed" \
  || fail "throwaway (rc=$RT_TTC): $RT_TT"
# Run dirs `rt+tw` (thread rt-uniform) and `rt_tw` (thread rt-victor) both name `tmp-rt_tw`, and
# both reviewed one artifact, so only the run the copy records can tell whose it is.
RT_UD="$RT/.comms/logs/rt+tw"; mkdir -p "$RT_UD"
printf 'thread\trt-uniform\nset\t\nagent\tgrok\nartifact\t%s\n' "$RT_ART" > "$RT_UD/turn.tsv"
RT_VW="$(rt_tmp "$RT/.comms/logs/rt_tw" rt-victor)"
rt_state retire rt-uniform >/dev/null
RT_UV="$(rt_cm --thread rt-uniform --yes)"; RT_UVC=$?
[ "$RT_UVC" = 4 ] && rt_line "$RT_UV" "$RT_VW" ambiguous run-mismatch && rt_intact "$RT_VW" \
  && ok "retiring a thread whose run dir normalizes alike leaves another thread's crashed throwaway intact" \
  || fail "aliased throwaway (rc=$RT_UVC): $RT_UV"
# Under the claim the copy is read again: a run that re-records it between the check and the
# claim takes it out of this thread's hands.
rt_state retire rt-victor >/dev/null
cat > "$WORK/rt-hook-run" <<EOF
#!/bin/bash
[ "\$1" = prechecked ] || exit 0
[ -f "\$3/.state.run" ] && (cd "$RT_UD" && pwd -P) > "\$3/.state.run"
exit 0
EOF
chmod +x "$WORK/rt-hook-run"
RT_VR="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-run" rt_cm --thread rt-victor --yes)"; RT_VRC=$?
[ "$RT_VRC" = 4 ] && rt_line "$RT_VR" "$RT_VW" ambiguous run-mismatch && rt_intact "$RT_VW" \
  && ok "a throwaway re-recorded to another run before the claim is kept: its maker is re-read under the claim" \
  || fail "re-recorded throwaway (rc=$RT_VRC): $RT_VR"
(cd "$RT/.comms/logs/rt_tw" && pwd -P) > "$RT_VW/.state.run"
RT_VO="$(rt_cm --thread rt-victor --yes)"; RT_VOC=$?
[ "$RT_VOC" = 0 ] && rt_line "$RT_VO" "$RT_VW" removed proven && rt_gone "$RT_VW" && rt_intact "$RT_PEER" \
  && ok "the thread whose run the throwaway names removes it" \
  || fail "owner's throwaway (rc=$RT_VOC): $RT_VO"
# A tombstone is named after the ident, so B's interrupted removal of its throwaway sits under the
# name A's run also derives. A (retired) must neither replay nor clear it — nor may it once B is
# unretired — and B's own replay re-checks the relocated copy's recorded run before deleting it.
RT_VW="$(rt_tmp "$RT/.comms/logs/rt_tw" rt-victor)"
RT_VK="$(RT_KILL_AT=renamed COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-victor --yes 2>/dev/null)"; RT_VKC=$?
RT_VT="$(ls -d "$RT_KEYDIR/.retire.$(basename "$RT_VW")".* 2>/dev/null | head -1)"
rt_vtomb() {  # B's journal and its moved copy are exactly as the kill left them
  [ -n "$RT_VT" ] && [ -f "$RT_VT/record" ] && [ -f "$RT_VT/$(basename "$RT_VW")/view/tree/rt.txt" ] \
    && [ -f "$RT_VT/$(basename "$RT_VW")/.state.run" ] && rt_reg "$RT_VW" && [ ! -e "$RT_VW" ]
}
RT_UD1="$(rt_cm --thread rt-uniform)"; RT_UD1C=$?
RT_UA1="$(rt_cm --thread rt-uniform --yes)"; RT_UA1C=$?
if [ "$RT_VKC" = 137 ] && ! grep -q '^clean-mounts-result' <<<"$RT_VK" && [ "$RT_UD1C" = 0 ] && [ "$RT_UA1C" = 0 ] \
   && ! grep -qF "path=$RT_VW" <<<"$RT_UD1$RT_UA1" && rt_vtomb; then
  ok "a retired thread's cleanup never replays another thread's interrupted throwaway tombstone of the same name"
else
  fail "aliased tombstone (rc=$RT_VKC/$RT_UD1C/$RT_UA1C, tomb=$RT_VT): $RT_UD1 / $RT_UA1"
fi
rt_state unretire rt-victor >/dev/null
RT_UA2="$(rt_cm --thread rt-uniform --yes)"; RT_UA2C=$?
[ "$RT_UA2C" = 0 ] && ! grep -qF "path=$RT_VW" <<<"$RT_UA2" && rt_vtomb \
  && ok "the aliased tombstone stays untouched after its own thread is unretired" \
  || fail "aliased tombstone after unretire (rc=$RT_UA2C): $RT_UA2"
rt_state retire rt-victor >/dev/null
RT_VRUN="$RT_VT/$(basename "$RT_VW")/.state.run"
cp "$RT_VRUN" "$WORK/rt-vrun"; (cd "$RT_UD" && pwd -P) > "$RT_VRUN"
RT_VM="$(rt_cm --thread rt-victor --yes)"; RT_VMC=$?
cp "$WORK/rt-vrun" "$RT_VRUN"
[ "$RT_VMC" = 4 ] && rt_line "$RT_VM" "$RT_VW" ambiguous run-mismatch && rt_vtomb \
  && ok "a replay whose relocated copy records another run is report-only" \
  || fail "relocated copy re-recorded (rc=$RT_VMC): $RT_VM"
RT_VF="$(rt_cm --thread rt-victor --yes)"; RT_VFC=$?
[ "$RT_VFC" = 0 ] && rt_line "$RT_VF" "$RT_VW" removed interrupted && rt_gone "$RT_VW" && rt_intact "$RT_PEER" \
  && ok "the thread whose run the journal names finishes its interrupted throwaway removal" \
  || fail "owner's replay (rc=$RT_VFC): $RT_VF"
# A throwaway delete that stops part-way keeps the copy's run record beside what it could not
# remove, and its journal has already forgotten the dropped registration, so once the obstruction
# is gone the re-run re-proves the copy and finishes: nothing has to be rebuilt by hand.
RT_WW="$(rt_tmp "$RT/.comms/logs/rt-whiskey-run" rt-whiskey)"
RT_WADM="$(cat "$RT_WW/.state.admin")"
rt_state retire rt-whiskey >/dev/null
RT_WI="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-lock" rt_cm --thread rt-whiskey --yes)"; RT_WIC=$?
RT_WT="$(ls -d "$RT_KEYDIR/.retire.$(basename "$RT_WW")".* 2>/dev/null | head -1)"
RT_WM="$RT_WT/$(basename "$RT_WW")"
RT_WLEFT="$(LC_ALL=C ls -A "$RT_WM" 2>/dev/null | tr '\n' ' ')"
if [ "$RT_WIC" = 3 ] && rt_line "$RT_WI" "$RT_WW" incomplete remove-failed && [ -n "$RT_WT" ] \
   && [ "$RT_WLEFT" = ".state.run home " ] && grep -qx 'admin=' "$RT_WT/record" && [ ! -e "$RT_WADM" ] && [ ! -e "$RT_WW" ]; then
  ok "a throwaway delete stopped part-way keeps its run record, and its journal no longer names the dropped registration"
else
  fail "partial throwaway delete (rc=$RT_WIC, tomb=$RT_WT, left=$RT_WLEFT): $RT_WI"
fi
[ -n "$RT_WT" ] && chmod 755 "$RT_WM/home" 2>/dev/null && chmod 000 "$RT_WM/.state.run" 2>/dev/null
RT_WU="$(rt_cm --thread rt-whiskey --yes)"; RT_WUC=$?
[ -n "$RT_WT" ] && chmod 644 "$RT_WM/.state.run" 2>/dev/null
[ "$RT_WUC" = 4 ] && rt_line "$RT_WU" "$RT_WW" refused state-unreadable && [ -f "$RT_WM/home/pinned" ] \
  && ok "a replay that cannot read the moved copy's run record is refused and deletes nothing" \
  || fail "unreadable moved run record (rc=$RT_WUC): $RT_WU"
# A copy re-created since gets the lowest free admin name — the one just dropped — with the same
# back-pointer; the replay no longer claims a registration, so it must leave that one alone.
RT_WKEEP=0
if [ -n "$RT_WT" ] && mkdir "$RT_WADM" 2>/dev/null; then
  printf '%s/view/tree/.git\n' "$RT_WW" > "$RT_WADM/gitdir"
  RT_WF="$(rt_cm --thread rt-whiskey --yes)"; RT_WFC=$?
  [ -f "$RT_WADM/gitdir" ] && RT_WKEEP=1
  rm -rf "$RT_WADM"
fi
[ "$RT_WFC" = 0 ] && rt_line "$RT_WF" "$RT_WW" removed interrupted && [ "$RT_WKEEP" = 1 ] && rt_gone "$RT_WW" && rt_intact "$RT_PEER" \
  && ok "with the obstruction gone the re-run finishes the throwaway and leaves a same-named registration alone" \
  || fail "resume partial throwaway delete (rc=$RT_WFC, kept=$RT_WKEEP): $RT_WF"
# The run record goes last, so a delete stopped between it and the final rmdir leaves an EMPTY
# copy: nothing is left to prove, so it finishes. One still holding anything stays report-only.
RT_YW="$(rt_tmp "$RT/.comms/logs/rt-yankee-run" rt-yankee)"
rt_state retire rt-yankee >/dev/null
RT_KILL_AT=unregistered COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-yankee --yes >/dev/null 2>&1
RT_YT="$(ls -d "$RT_KEYDIR/.retire.$(basename "$RT_YW")".* 2>/dev/null | head -1)"
RT_YM="$RT_YT/$(basename "$RT_YW")"
[ -n "$RT_YT" ] && rm -f "$RT_YM/.state.run"
RT_YA="$(rt_cm --thread rt-yankee --yes)"; RT_YAC=$?
[ -n "$RT_YT" ] && [ "$RT_YAC" = 4 ] && rt_line "$RT_YA" "$RT_YW" ambiguous no-ownership-evidence && [ -f "$RT_YM/view/tree/rt.txt" ] \
  && ok "a moved throwaway that still holds content but no run record is report-only" \
  || fail "moved throwaway without a run record (rc=$RT_YAC, tomb=$RT_YT): $RT_YA"
[ -n "$RT_YT" ] && find "$RT_YM" -mindepth 1 -delete 2>/dev/null
RT_YE="$(rt_cm --thread rt-yankee --yes)"; RT_YEC=$?
[ -n "$RT_YT" ] && [ "$RT_YEC" = 0 ] && rt_line "$RT_YE" "$RT_YW" removed interrupted && rt_gone "$RT_YW" && rt_intact "$RT_PEER" \
  && ok "a moved throwaway already emptied down to its directory is finished: nothing is left to prove" \
  || fail "emptied moved throwaway (rc=$RT_YEC): $RT_YE"

section "clean mounts --thread: the retired copy is handed to the store's trash and reaped later"
# Unregistered and journaled, the tombstone (record, claims and copy) moves into <store>/.comms-trash
# in one rename and the clean returns; a detached reaper takes the tombstone claim and deletes it.
RT_TR="$RT_STORE/.comms-trash"
cat > "$WORK/rt-hook-reap" <<'EOF'
#!/bin/bash
# A reap hook: log "<event> <name> [claimed]"; block at $RT_REAP_BLOCK until $RT_REAP_RELEASE (bounded).
c=""; [ "$1" = before-delete ] && grep -qs '^run=reaper:' "$2"/payload/.claim.[0-9]* && c=" claimed"
printf '%s %s%s\n' "$1" "${2##*/}" "$c" >> "$RT_REAP_LOG"
[ "$1" = "${RT_REAP_BLOCK:-}" ] || exit 0
n=0; while [ ! -e "$RT_REAP_RELEASE" ] && [ "$n" -lt 900 ]; do sleep 0.1; n=$((n + 1)); done
exit 0
EOF
chmod +x "$WORK/rt-hook-reap"
rt_state retire rt-romeo >/dev/null
RT_RQ=0; reap_wait "$RT_TR" && RT_RQ=1
RT_R1="$(rt_turn rt-romeo grok)"
: > "$WORK/rt-reap.log"; rm -f "$WORK/rt-reap.release"
RT_RO="$(RT_REAP_LOG="$WORK/rt-reap.log" RT_REAP_BLOCK=locked RT_REAP_RELEASE="$WORK/rt-reap.release" \
  COMMS_TEST_REAP_HOOK="$WORK/rt-hook-reap" rt_cm --thread rt-romeo --yes)"; RT_ROC=$?
RT_RB=0; wait_until grep -q '^locked ' "$WORK/rt-reap.log" && RT_RB=1
RT_RE="$(trash_entries "$RT_TR")"
if [ "$RT_RQ" = 1 ] && [ -n "$RT_R1" ] && [ "$RT_ROC" = 0 ] && rt_line "$RT_RO" "$RT_R1" removed proven && rt_gone "$RT_R1" \
   && [ "$RT_RB" = 1 ] && reaper_running "$RT_TR" && [ "$(printf '%s\n' "$RT_RE" | grep -c '\.retire\.')" = 1 ] \
   && [ -f "$RT_TR/$RT_RE/payload/record" ] && [ -f "$RT_TR/$RT_RE/payload/$(basename "$RT_R1")/view/tree/rt.txt" ]; then
  ok "clean mounts --thread returns removed while the reaper is blocked: the tombstone has left the scope and waits in the trash"
else
  fail "hand-off (rc=$RT_ROC, r1=$RT_R1, blocked=$RT_RB, entries=$RT_RE): $RT_RO"
fi
touch "$WORK/rt-reap.release"
RT_RW=0; reap_wait "$RT_TR" && RT_RW=1
[ "$RT_RW" = 1 ] && [ -n "$RT_RE" ] && [ ! -e "$RT_TR/$RT_RE" ] && grep -qx "before-delete $RT_RE claimed" "$WORK/rt-reap.log" \
  && ok "released, the reaper takes the tombstone's claim before it deletes the payload" \
  || fail "reap of the tombstone: idle=$RT_RW log=$(tr '\n' '|' < "$WORK/rt-reap.log")"
# FALLBACK: a rename the trash refuses (EXDEV, or an unwritable trash) deletes inline as before.
RT_R2="$(rt_turn rt-romeo grok)"
RT_FX="$(COMMS_TEST_TRASH_RENAME_ERRNO=EXDEV rt_cm --thread rt-romeo --yes)"; RT_FXC=$?
RT_FXE="$(trash_entries "$RT_TR")$(trash_holds "$RT_TR")"
RT_R3="$(rt_turn rt-romeo grok)"
chmod 500 "$RT_TR"
RT_FU="$(rt_cm --thread rt-romeo --yes)"; RT_FUC=$?
RT_FUE="$(trash_entries "$RT_TR")$(trash_holds "$RT_TR")"
chmod 700 "$RT_TR"
if [ -n "$RT_R2" ] && [ "$RT_FXC" = 0 ] && rt_line "$RT_FX" "$RT_R2" removed proven && [ -z "$RT_FXE" ] \
   && [ -n "$RT_R3" ] && [ "$RT_FUC" = 0 ] && rt_line "$RT_FU" "$RT_R3" removed proven && [ -z "$RT_FUE" ] && rt_gone "$RT_R3"; then
  ok "with EXDEV, or an unwritable trash, the retired copy is removed inline exactly as before and nothing reaches the trash"
else
  fail "hand-off fallback (rc=$RT_FXC/$RT_FUC, entries=$RT_FXE|$RT_FUE): $RT_FX / $RT_FU"
fi
# Killed after the hand-off and before its commit, the clean leaves a hold naming a dead maker. A
# re-run finds nothing left in the scope (absent) and starts the reaper, which proves the maker
# dead, commits the hold and deletes it — with no mounted turn in between.
RT_R4="$(rt_turn rt-romeo grok)"
RT_RQ=0; reap_wait "$RT_TR" && RT_RQ=1
RT_KILL_AT=handed-off COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-kill" rt_cm --thread rt-romeo --yes >/dev/null 2>&1; RT_HKC=$?
RT_HH="$(trash_holds "$RT_TR")"
RT_HA="$(rt_cm --thread rt-romeo --yes)"; RT_HAC=$?
RT_RW=0; reap_wait "$RT_TR" && RT_RW=1
if [ "$RT_RQ" = 1 ] && [ -n "$RT_R4" ] && [ "$RT_HKC" = 137 ] && [ "$(printf '%s\n' "$RT_HH" | grep -c '\.retire\.')" = 1 ] \
   && [ "$RT_HAC" = 0 ] && rt_line "$RT_HA" "$RT_R4" absent already-absent && rt_gone "$RT_R4" \
   && [ "$RT_RW" = 1 ] && [ -z "$(trash_holds "$RT_TR")" ] && [ ! -e "$RT_TR/$RT_HH" ]; then
  ok "killed at 'handed-off', a re-run reports absent and the reaper it starts commits and deletes the dead maker's hold"
else
  fail "kill at handed-off (rc=$RT_HKC then $RT_HAC, hold=$RT_HH, idle=$RT_RW): $RT_HA"
fi

section "deferred deletion never moves a credential the runner wrote into a trash"
# The provider login carries a unique marker. COMMS_TEST_ISO_STAGE_HOOK fires inside _iso_place
# between writing the staged copy and renaming it to auth.json: it records whether the staged file
# holds the marker (the negative control: the interruption really leaves credential bytes on disk),
# then interrupts the runner. A trash hook (at the put) and a reap hook (before the delete) grep
# whatever is about to be trashed or deleted for the marker.
RT_MARK="rt-credential-marker-$$-$RANDOM"
mkdir -p "$RT_HOME/.codex"; printf '{"tokens":"%s"}\n' "$RT_MARK" > "$RT_HOME/.codex/auth.json"; chmod 600 "$RT_HOME/.codex/auth.json"
cat > "$WORK/rt-hook-stage" <<'EOF'
#!/bin/bash
case "$2" in */auth.json) ;; *) exit 0 ;; esac
if grep -qF "$RT_MARK" "$1"; then echo marker >> "$RT_STAGE_LOG"; else echo none >> "$RT_STAGE_LOG"; fi
kill "-$RT_STAGE_SIG" "$PPID"
exit 0
EOF
cat > "$WORK/rt-hook-cred" <<'EOF'
#!/bin/bash
case "$1" in held|before-delete) ;; *) exit 0 ;; esac
if grep -rqF "$RT_MARK" "$2" 2>/dev/null; then r=found; else r=clean; fi
printf '%s %s %s\n' "$1" "$r" "${2##*/}" >> "$RT_CRED_LOG"
exit 0
EOF
chmod +x "$WORK/rt-hook-stage" "$WORK/rt-hook-cred"
export RT_MARK RT_STAGE_LOG="$WORK/rt-stage.log" RT_CRED_LOG="$WORK/rt-cred.log"
: > "$RT_STAGE_LOG"; : > "$RT_CRED_LOG"
RT_C1="$(rt_turn rt-sierra codex)"
[ -n "$RT_C1" ] && grep -qF "$RT_MARK" "$RT_C1/home/auth.json" 2>/dev/null \
  && ok "fixture: a mounted codex turn stages the marked login into its durable home" \
  || fail "fixture: no durable codex mount with the staged login (c1=$RT_C1)"
# THROWAWAY: a malformed session record degrades the next turn to a throwaway; TERM mid-staging
# runs the runner's EXIT teardown, which clears the credentials and only then trashes the ident.
cp "$RT_C1/.state.record" "$WORK/rt-c1.record" 2>/dev/null; printf 'bad id!\n' > "$RT_C1/.state.record"
RT_RQ=0; reap_wait "$RT_TR" && RT_RQ=1
RT_STAGE_SIG=TERM COMMS_TEST_ISO_STAGE_HOOK="$WORK/rt-hook-stage" COMMS_TEST_TRASH_HOOK="$WORK/rt-hook-cred" \
  COMMS_TEST_REAP_HOOK="$WORK/rt-hook-cred" rt_turn rt-sierra codex >/dev/null
RT_RW=0; reap_wait "$RT_TR" && RT_RW=1
if [ "$RT_RQ" = 1 ] && [ "$(sed -n 1p "$RT_STAGE_LOG")" = marker ] && [ "$RT_RW" = 1 ] \
   && grep -qE '^held clean \.hold\.[0-9]{10}\.throwaway\.' "$RT_CRED_LOG" && grep -qE '^before-delete clean [0-9]{10}\.throwaway\.' "$RT_CRED_LOG" \
   && ! grep -q ' found ' "$RT_CRED_LOG" && [ -z "$(ls -d "$(dirname "$RT_C1")"/tmp-* 2>/dev/null)" ]; then
  ok "a throwaway interrupted mid-staging (TERM) is trashed only after its staged credential is cleared"
else
  fail "throwaway credential: stage=$(tr '\n' ' ' < "$RT_STAGE_LOG") idle=$RT_RW cred=$(tr '\n' '|' < "$RT_CRED_LOG")"
fi
# DURABLE: SIGKILL mid-staging runs no teardown, so the durable home keeps its auth.json and a
# credential-bearing .stage.*. Retired through clean mounts, both are cleared before the hand-off.
cp "$WORK/rt-c1.record" "$RT_C1/.state.record" 2>/dev/null
RT_STAGE_SIG=KILL COMMS_TEST_ISO_STAGE_HOOK="$WORK/rt-hook-stage" rt_turn rt-sierra codex >/dev/null
RT_CK="$(ls "$RT_C1/home/".stage.* 2>/dev/null | head -1)"
RT_CKM=0; [ -n "$RT_CK" ] && grep -qF "$RT_MARK" "$RT_CK" && grep -qF "$RT_MARK" "$RT_C1/home/auth.json" && RT_CKM=1
rt_state retire rt-sierra >/dev/null
: > "$RT_CRED_LOG"
RT_CC="$(COMMS_TEST_TRASH_HOOK="$WORK/rt-hook-cred" COMMS_TEST_REAP_HOOK="$WORK/rt-hook-cred" rt_cm --thread rt-sierra --yes)"; RT_CCC=$?
RT_RW=0; reap_wait "$RT_TR" && RT_RW=1
RT_LEFT="$(grep -rlF "$RT_MARK" "$RT_STORE" 2>/dev/null)"
if [ "$(sed -n 2p "$RT_STAGE_LOG")" = marker ] && [ "$RT_CKM" = 1 ] && [ "$RT_CCC" = 0 ] && rt_line "$RT_CC" "$RT_C1" removed proven \
   && [ "$RT_RW" = 1 ] && grep -qE '^held clean \.hold\.[0-9]{10}\.retire\.' "$RT_CRED_LOG" \
   && grep -qE '^before-delete clean [0-9]{10}\.retire\.' "$RT_CRED_LOG" && ! grep -q ' found ' "$RT_CRED_LOG"; then
  ok "a durable home's auth.json and a killed runner's staged copy are cleared before its tombstone reaches the trash"
else
  fail "durable credential (rc=$RT_CCC, stage=$(tr '\n' ' ' < "$RT_STAGE_LOG"), left=$RT_CKM, cred=$(tr '\n' '|' < "$RT_CRED_LOG")): $RT_CC"
fi
[ -z "$RT_LEFT" ] && [ "$RT_RW" = 1 ] \
  && ok "once the reaper finishes, no file in the store or its trash holds the credential" \
  || fail "credential bytes left in the store: $RT_LEFT"
rm -f "$RT_HOME/.codex/auth.json"; unset RT_MARK RT_STAGE_LOG RT_CRED_LOG
