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
rt_live_claim() {  # <kdir> — a live v2 runner claim; prints the holder pid
  local p; sleep 300 </dev/null >/dev/null 2>&1 & p=$!
  printf 'pid=%s\nfmt=v2\nstart=%s\nrun=live\n' "$p" "$(LC_ALL=C TZ=UTC ps -p "$p" -o lstart= | tr -s ' ' | sed 's/^ *//; s/ *$//')" > "$1/.claim.99"
  printf '%s' "$p"
}
rt_unclaim() { kill "$2" 2>/dev/null; wait "$2" 2>/dev/null; rm -f "$1/.claim.99"; }

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
if [ "$RT_U1" = 2 ] && [ "$RT_U2" = 2 ] && [ "$RT_U3" = 2 ] && [ "$RT_U4" = 2 ] && [ "$RT_U5" = 2 ] \
   && rt_intact "$RT_A1" && rt_intact "$RT_B1"; then
  ok "a missing, empty or unknown selector and --orphans with --thread are usage errors that remove nothing"
else
  fail "selector refusals rc=$RT_U1/$RT_U2/$RT_U3/$RT_U4/$RT_U5"
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
RT_E1="$(rt_turn rt-echo grok)"
rt_state retire rt-echo >/dev/null
RT_EDRY="$(rt_cm --thread rt-echo)"
RT_EP="$(rt_live_claim "$RT_E1")"
RT_EB="$(rt_cm --thread rt-echo --yes)"; RT_EBC=$?
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
RT_RC="$(COMMS_TEST_CLEAN_MOUNTS_HOOK="$WORK/rt-hook-claim" rt_cm --thread rt-echo --yes)"; RT_RCC=$?
kill "$(cat "$WORK/rt-hook-claim.pid" 2>/dev/null)" 2>/dev/null; rm -f "$RT_E1"/.claim.98
if [ "$RT_RCC" = 3 ] && rt_line "$RT_RC" "$RT_E1" skipped busy-claim && rt_intact "$RT_E1"; then
  ok "a claim that lands between the check and the exclusion claim preserves the mount"
else
  fail "in-run claim race (rc=$RT_RCC): $RT_RC"
fi
# A queue lease still present is a live (or stale — indistinguishable) owner: skipped, never removed.
RT_LEASE="$RT_HOME/.acpx/queues/$(printf '%s' "$(cat "$RT_E1/.state.record")" | shasum -a 256 | cut -c1-24).lock"
: > "$RT_LEASE"
RT_OW="$(rt_cm --thread rt-echo --yes)"; RT_OWC=$?
rm -f "$RT_LEASE"
[ "$RT_OWC" = 3 ] && rt_line "$RT_OW" "$RT_E1" skipped busy-owner && rt_intact "$RT_E1" \
  && ok "an acpx queue lease (live or stale) skips the target" || fail "owner lease (rc=$RT_OWC): $RT_OW"
# Stale pid evidence: an older-format claim naming a LIVE pid cannot be proven recycled.
sleep 300 </dev/null >/dev/null 2>&1 & RT_SP=$!
printf 'pid=%s\nrun=old\n' "$RT_SP" > "$RT_E1/.claim.99"
RT_ST="$(rt_cm --thread rt-echo --yes)"; RT_STC=$?
rt_unclaim "$RT_E1" "$RT_SP"
[ "$RT_STC" = 3 ] && rt_line "$RT_ST" "$RT_E1" skipped busy-claim && rt_intact "$RT_E1" \
  && ok "a live pid in a claim without a start time is never read as dead" || fail "stale pid (rc=$RT_STC): $RT_ST"

# ---- every gate refuses safely; each case restores the mount and re-proves it intact ----
rt_refused() {  # <desc> <reason> — apply refuses with <reason>, exit 4, and the ident dir survives
  local out rc
  out="$(rt_cm --thread rt-echo --yes)"; rc=$?
  if [ "$rc" = 4 ] && rt_line "$out" "$RT_E1" refused "$2" && [ -d "$RT_E1" ] \
     && grep -q '^clean-mounts-result v1 status=blocked ' <<<"$out"; then ok "$1"; else fail "$1 (rc=$rc): $out"; fi
}
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
git -C "$RT" update-ref -d "refs/agent-comms/artifacts/$RT_ART"
rt_refused "a tree whose artifact is no longer retained refuses" artifact-unretained
git -C "$RT" update-ref "refs/agent-comms/artifacts/$RT_ART" "$RT_ART"
mv "$RT_E1/view/tree" "$WORK/rt-tree-real"; ln -s "$WORK/rt-tree-real" "$RT_E1/view/tree"
rt_refused "a symlink substituted for the tree is never followed" unsafe-path
rm "$RT_E1/view/tree"; mv "$WORK/rt-tree-real" "$RT_E1/view/tree"
mv "$RT_E1" "$RT_E1.real"; ln -s "$RT_E1.real" "$RT_E1"
RT_SY="$(rt_cm --thread rt-echo --yes)"; RT_SYC=$?
rm "$RT_E1"; mv "$RT_E1.real" "$RT_E1"
[ "$RT_SYC" = 4 ] && rt_line "$RT_SY" "$RT_E1" refused unsafe-path && rt_intact "$RT_E1" \
  && ok "a symlink substituted for the ident dir refuses and its target survives" || fail "ident symlink (rc=$RT_SYC): $RT_SY"
(cd "$RT" && env "$RP" hold rt-echo >/dev/null 2>&1)
RT_HD="$(rt_cm --thread rt-echo --yes)"; RT_HDC=$?
(cd "$RT" && env "$RP" release rt-echo >/dev/null 2>&1)
[ "$RT_HDC" = 4 ] && grep -q '^clean-mounts-result v1 status=blocked .* selected=0 ' <<<"$RT_HD" && rt_intact "$RT_E1" \
  && ok "a held (paused) thread is not cleaned even when retired" || fail "held thread (rc=$RT_HDC): $RT_HD"
# With every gate restored, the mount goes — while an UNRELATED thread holds a live claim, which
# the whole-store GC would refuse the entire repo-key over. It is neither read nor touched.
RT_BP="$(rt_live_claim "$RT_B1")"
RT_OK="$(rt_cm --thread rt-echo --yes)"; RT_OKC=$?
if [ "$RT_OKC" = 0 ] && rt_line "$RT_OK" "$RT_E1" removed proven && rt_gone "$RT_E1" \
   && ! grep -qF "path=$RT_B1" <<<"$RT_OK" && [ -f "$RT_B1/.claim.99" ] && rt_intact "$RT_B1"; then
  ok "with every gate restored the mount is removed; a live claim on another thread neither blocks nor is touched"
else
  fail "restored mount beside a live unrelated claim (rc=$RT_OKC): $RT_OK"
fi
rt_unclaim "$RT_B1" "$RT_BP"

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
rt_state retire rt_alpha-grok >/dev/null
RT_SH2="$(rt_cm --thread rt_alpha --yes)"; RT_SH2C=$?
[ "$RT_SH2C" = 0 ] && rt_line "$RT_SH2" "$RT_B1" removed proven && rt_gone "$RT_B1" \
  && ok "once every thread sharing the copy is retired it is removed" || fail "shared then retired (rc=$RT_SH2C): $RT_SH2"

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

# ---- a crashed run's disposable copy is the thread's too, named from its own run dir ----
# The shape a runner killed mid-turn on a degrade path leaves: a registered worktree holding the
# artifact, its session bookkeeping, and the runner's claim with a dead pid.
RT_TD="$RT/.comms/logs/rt-tmp-run"; mkdir -p "$RT_TD"
printf 'thread\trt-tango\nset\t\nagent\tgrok\nartifact\t%s\n' "$RT_ART" > "$RT_TD/turn.tsv"
RT_KEYDIR="$(dirname "$RT_PEER")"; RT_TW="$RT_KEYDIR/tmp-rt-tmp-run"
mkdir -p "$RT_TW/view" "$RT_TW/home"
git -C "$RT" worktree add -q --detach "$RT_TW/view/tree" "$RT_HEAD" >/dev/null 2>&1
git -C "$RT_TW/view/tree" read-tree -u --reset "$RT_ART" && git -C "$RT_TW/view/tree" reset -q --mixed "$RT_HEAD"
git -C "$RT_TW/view/tree" rev-parse --absolute-git-dir > "$RT_TW/.state.admin"
printf 'tw-rec\n' > "$RT_TW/.state.record"; printf '%s\n' "$RT_HOME" > "$RT_TW/.state.home"
printf '{\n  "cwd": "%s",\n  "name": "x"\n}\n' "$RT_TW/view/tree" > "$RT_HOME/.acpx/sessions/tw-rec.json"
( exit 0 ) & RT_DEAD=$!; wait "$RT_DEAD"
printf 'pid=%s\nrun=%s\n' "$RT_DEAD" "$RT_TD" > "$RT_TW/.claim.0"
rt_state retire rt-tango >/dev/null
RT_TT="$(rt_cm --thread rt-tango --yes)"; RT_TTC=$?
[ "$RT_TTC" = 0 ] && grep -F " path=$RT_TW" <<<"$RT_TT" | grep_full -q "status=removed reason=proven kind=throwaway use=run " \
  && rt_gone "$RT_TW" && rt_intact "$RT_PEER" \
  && ok "a crashed run's throwaway copy is selected by its run dir's name and removed" \
  || fail "throwaway (rc=$RT_TTC): $RT_TT"
