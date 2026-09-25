# Run through tests/run.sh; each group gets fresh fixtures.
section "worktree list/retire: hand-run session-lifecycle retirement"
# docs/ROADMAP.md "session-lifecycle retirement" (2026-09-03) as basis slice 0b. Every refusal
# is proven by a RETAINED worktree and branch after `--yes`, not by an exit code alone.
WR="$WORK/retire-repo"; mkdir -p "$WR"; WR="$(cd "$WR" && pwd -P)"
git -C "$WR" init -q -b main
printf '.comms/\n.claude/worktrees/\nnode_modules/\ndata/\n.env\ndist\n' > "$WR/.gitignore"
echo base > "$WR/a.txt"
printf '#!/bin/bash\ntest -f a.txt\n' > "$WR/suite.sh"; chmod +x "$WR/suite.sh"
git -C "$WR" add .gitignore a.txt suite.sh
git -C "$WR" -c user.email=t@t -c user.name=t commit -qm init
mkdir -p "$WR/.comms"; printf 'suite-cmd = bash ./suite.sh\n' > "$WR/.comms/config"
WR_BIN="$WORK/retire-bin"; mkdir -p "$WR_BIN"
WR_GIT="$(command -v git)"
run_wr() { (cd "$WR" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_PRESENCE_TTL_SECS=60 "$COMMS" "$@"); }
wr_commit() { git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2"; }
wr_path() { printf '%s/.claude/worktrees/%s' "$WR" "$1"; }
wr_new() {  # <slug> — a managed worktree with one commit, NOT landed
  run_wr worktree new "$1" >/dev/null 2>&1
  echo "$1" > "$(wr_path "$1")/$1.txt"
  git -C "$(wr_path "$1")" add "$1.txt"; wr_commit "$(wr_path "$1")" "feat: $1"
}
wr_landed() { wr_new "$1"; git -C "$WR" merge -q --ff-only "worktree-$1"; }
wr_kept() { [ -d "$(wr_path "$1")" ] && git -C "$WR" rev-parse -q --verify "refs/heads/worktree-$1" >/dev/null; }
wr_gone() { [ ! -e "$(wr_path "$1")" ] && ! git -C "$WR" rev-parse -q --verify "refs/heads/worktree-$1" >/dev/null; }
wr_line() { run_wr worktree list 2>/dev/null | grep -F " branch=$1 "; }
# wr_refused <desc> <slug> <reason-pattern> [env...] — `--yes` exits 3, names the gate, keeps both.
wr_refused() {
  local desc="$1" slug="$2" pat="$3" out rc; shift 3
  out="$(cd "$WR" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_PRESENCE_TTL_SECS=60 "$@" "$COMMS" worktree retire "worktree-$slug" --yes 2>&1)" && rc=0 || rc=$?
  if [ "$rc" = 3 ] && printf '%s\n' "$out" | grep -q "refused: $pat" && wr_kept "$slug"; then ok "$desc"
  else fail "$desc (rc=$rc kept=$(wr_kept "$slug" && echo yes || echo no)): $(printf '%s' "$out" | tail -3 | tr '\n' '|')"; fi
}
wr_retired() {  # <desc> <slug> [env...]
  local desc="$1" slug="$2" out rc; shift 2
  out="$(cd "$WR" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_PRESENCE_TTL_SECS=60 "$@" "$COMMS" worktree retire "worktree-$slug" --yes 2>&1)" && rc=0 || rc=$?
  if [ "$rc" = 0 ] && wr_gone "$slug"; then ok "$desc"
  else fail "$desc (rc=$rc): $(printf '%s' "$out" | tail -3 | tr '\n' '|')"; fi
}
wr_wait_lsof() {  # <pid> <path-fragment> — until lsof shows the process holding the path (<=5s)
  local n=0
  while [ "$n" -lt 50 ]; do
    lsof -n -P -w -p "$1" -Fn 2>/dev/null | grep_full -qF "$2" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

# ---- a bare `worktree` never creates (three friction reports of stray session worktrees) ----
WR_WT_BEFORE="$(git -C "$WR" worktree list --porcelain | grep -c '^worktree ')"; WR_BR_BEFORE="$(git -C "$WR" branch --list | wc -l | tr -d ' ')"
WR_BARE="$(run_wr worktree 2>&1)"; WR_BARERC=$?
[ "$WR_BARERC" = 2 ] && printf '%s' "$WR_BARE" | grep -q 'usage: comms.sh worktree new' \
  && [ "$(git -C "$WR" worktree list --porcelain | grep -c '^worktree ')" = "$WR_WT_BEFORE" ] \
  && [ "$(git -C "$WR" branch --list | wc -l | tr -d ' ')" = "$WR_BR_BEFORE" ] \
  && ok "bare 'worktree' prints usage, exits 2, and creates no worktree or branch" || fail "bare worktree rc=$WR_BARERC: $WR_BARE"
WR_HELP="$(run_wr worktree help 2>/dev/null)"; WR_HELPRC=$?
[ "$WR_HELPRC" = 0 ] && printf '%s' "$WR_HELP" | grep -q 'worktree retire <branch>' \
  && ok "'worktree help' prints usage on stdout, exit 0" || fail "worktree help rc=$WR_HELPRC"
WR_UNK="$(run_wr worktree lsit 2>&1)"; WR_UNKRC=$?
[ "$WR_UNKRC" = 2 ] && printf '%s' "$WR_UNK" | grep -q "unknown subcommand 'lsit'" \
  && [ "$(git -C "$WR" worktree list --porcelain | grep -c '^worktree ')" = "$WR_WT_BEFORE" ] \
  && ok "an unknown subcommand is refused with usage and creates nothing" || fail "unknown subcommand rc=$WR_UNKRC: $WR_UNK"

# ---- list: classification and on-main detection ----
wr_landed done1
wr_new open1
wr_new cp1
git -C "$WR" -c user.email=t@t -c user.name=t cherry-pick -x "$(git -C "$WR" rev-parse worktree-cp1)" >/dev/null 2>&1
wr_new sq1
echo more > "$(wr_path sq1)/sq1-b.txt"; git -C "$(wr_path sq1)" add sq1-b.txt; wr_commit "$(wr_path sq1)" "feat: sq1 b"
git -C "$WR" merge -q --squash worktree-sq1 >/dev/null 2>&1; wr_commit "$WR" "feat: sq1 squashed"
WR_MOUNT="$(cd "$WORK" && pwd -P)/mstore/$(printf 'a%.0s' $(seq 1 64))/sq-ident/view/tree"; mkdir -p "$(dirname "$WR_MOUNT")"
git -C "$WR" worktree add -q --detach "$WR_MOUNT" main >/dev/null 2>&1
git -C "$WR" worktree add -q -b side "$WORK/side-wt" main >/dev/null 2>&1
git -C "$WR" worktree add -q -b worktree-agent-a1b2c3d4 "$(wr_path agent-a1b2c3d4)" main >/dev/null 2>&1
WR_LIST="$(run_wr worktree list 2>/dev/null)"
printf '%s\n' "$WR_LIST" | grep -q "^worktree-list v1 kind=primary branch=main .*retire=never path=$WR\$" \
  && ok "list: the primary checkout is kind=primary and never retirable" || fail "list primary row: $WR_LIST"
printf '%s\n' "$WR_LIST" | grep -F " branch=worktree-done1 " | grep_full -q "kind=managed branch=worktree-done1 on_main=ancestor .*retire=ok" \
  && ok "list: a landed clean managed worktree is on_main=ancestor, retire=ok" || fail "list landed row: $(printf '%s\n' "$WR_LIST" | grep done1)"
printf '%s\n' "$WR_LIST" | grep -F " branch=worktree-open1 " | grep_full -q "on_main=no .*retire=blocked:landed" \
  && ok "list: unlanded work is on_main=no and blocked" || fail "list unlanded row"
printf '%s\n' "$WR_LIST" | grep -F " branch=worktree-cp1 " | grep_full -q "on_main=cherry " \
  && ok "list: a cherry-picked branch reads on_main=cherry" || fail "list cherry row: $(printf '%s\n' "$WR_LIST" | grep cp1)"
printf '%s\n' "$WR_LIST" | grep -F " branch=worktree-sq1 " | grep_full -q "on_main=squash " \
  && ok "list: a squash-merged branch reads on_main=squash" || fail "list squash row: $(printf '%s\n' "$WR_LIST" | grep sq1)"
printf '%s\n' "$WR_LIST" | grep -F "path=$WR_MOUNT" | grep_full -q "kind=mount " \
  && ok "list: a review mount is kind=mount (store layout, not base path)" || fail "list mount row"
printf '%s\n' "$WR_LIST" | grep -F " branch=side " | grep_full -q "kind=unmanaged " \
  && ok "list: a hand-made sibling worktree is kind=unmanaged" || fail "list unmanaged row"
printf '%s\n' "$WR_LIST" | grep -F " branch=worktree-agent-a1b2c3d4 " | grep_full -q "kind=subagent .*retire=ok" \
  && ok "list: an agent-<hex> managed-shape worktree is kind=subagent" || fail "list subagent row"
wr_landed dirt1
echo edit >> "$(wr_path dirt1)/a.txt"; echo new > "$(wr_path dirt1)/scratch.txt"
wr_line worktree-dirt1 | grep_full -q "tracked=1 untracked=1 " \
  && ok "list: tracked and untracked dirt are counted separately" || fail "list dirt: $(wr_line worktree-dirt1)"
printf '#!/bin/sh\nexit 1\n' > "$WR_BIN/lsof"; chmod +x "$WR_BIN/lsof"
(cd "$WR" && env PATH="$WR_BIN:$PATH" "$COMMS" worktree list 2>/dev/null) | grep -F " branch=worktree-done1 " | grep_full -q "procs=? .*retire=blocked:processes" \
  && ok "list: a failing lsof reads procs=? and blocks (unknown is never clean)" || fail "list lsof unknown"
rm -f "$WR_BIN/lsof"

# ---- retire: dry run, then the one permitted path ----
WR_DRY="$(run_wr worktree retire worktree-done1 2>&1)"; WR_DRC=$?
[ "$WR_DRC" = 0 ] && printf '%s' "$WR_DRY" | grep -q 'would remove .*dry run' && wr_kept done1 \
  && ok "retire without --yes is a dry run that changes nothing" || fail "dry run rc=$WR_DRC: $WR_DRY"
wr_retired "retire --yes removes a landed clean managed worktree and deletes its branch" done1
wr_retired "retire accepts a landed clean subagent worktree" agent-a1b2c3d4
wr_landed regen1
mkdir -p "$(wr_path regen1)/node_modules/pkg"; echo x > "$(wr_path regen1)/node_modules/pkg/index.js"
wr_retired "ignored content on the regenerable list (node_modules) does not block" regen1

# ---- retire: every refusal ----
wr_refused "refuses a branch that is not on main" open1 "landed: tip"
wr_refused "refuses cherry-equivalence as proof of landing" cp1 "landed: .*cherry-equivalence"
wr_refused "refuses squash-equivalence as proof of landing" sq1 "landed: .*squash-equivalence"
wr_landed dirt2; echo edit >> "$(wr_path dirt2)/a.txt"
wr_refused "refuses tracked changes" dirt2 "dirty: 1 tracked"
wr_landed dirt3; echo new > "$(wr_path dirt3)/scratch.txt"
wr_refused "refuses untracked files" dirt3 "dirty: 1 untracked"
wr_landed ign1; mkdir -p "$(wr_path ign1)/data"; echo '{"cost":21.54}' > "$(wr_path ign1)/data/results.json"
wr_refused "refuses ignored content off the regenerable list" ign1 "ignored: .*data/"
wr_landed sec1; echo 'TOKEN=x' > "$(wr_path sec1)/.env"
wr_refused "refuses a secret-named ignored file" sec1 "secrets: .*\.env"
wr_landed nest1; mkdir -p "$(wr_path nest1)/node_modules/dep"; git -C "$(wr_path nest1)/node_modules/dep" init -q
wr_refused "refuses a nested repository, even inside a regenerable directory" nest1 "nested-git: "
# ---- round 1 (codex, grok): hidden edits, file-shaped names, bare repos ----
wr_landed skw1; git -C "$(wr_path skw1)" update-index --skip-worktree skw1.txt; echo local > "$(wr_path skw1)/skw1.txt"
wr_refused "refuses an edit hidden by skip-worktree" skw1 "dirty: 1 tracked"
grep -q local "$(wr_path skw1)/skw1.txt" && ok "the skip-worktree edit survives the refusal" || fail "skip-worktree edit lost"
wr_landed asu1; git -C "$(wr_path asu1)" update-index --assume-unchanged asu1.txt; echo local > "$(wr_path asu1)/asu1.txt"
wr_refused "refuses an edit hidden by assume-unchanged" asu1 "dirty: 1 tracked"
wr_landed asu2; git -C "$(wr_path asu2)" update-index --assume-unchanged asu2.txt
wr_retired "an assume-unchanged path with unchanged bytes does not block" asu2
wr_landed dfile1; echo precious > "$(wr_path dfile1)/dist"
wr_refused "an ignored FILE named like a build directory is not regenerable" dfile1 "ignored: .*dist"
wr_landed ddir1; mkdir -p "$(wr_path ddir1)/dist"; echo built > "$(wr_path ddir1)/dist/app.js"
wr_retired "an ignored dist/ directory is regenerable" ddir1
wr_landed bare1; git init -q --bare "$(wr_path bare1)/node_modules/mirror.git"
wr_refused "refuses a bare repository inside a regenerable directory" bare1 "nested-git: .*mirror.git"
# ---- field report 2026-09-25: husky's hook dir and TypeScript build info ----
# husky ignores `.husky/_/` through its own `*` .gitignore, so git lists the directory AND its
# files. `.husky/`, `lib/` and `pkg/` are tracked, as in a real repo, so only the ignored parts list.
wr_tracked() {  # <slug> <path...> — a landed managed worktree that also tracks these paths
  local slug="$1" f; shift; wr_new "$slug"
  for f in "$@"; do mkdir -p "$(dirname "$(wr_path "$slug")/$f")"; echo keep > "$(wr_path "$slug")/$f"; done
  git -C "$(wr_path "$slug")" add -- "$@"; wr_commit "$(wr_path "$slug")" "chore: track $*"
  git -C "$WR" merge -q --ff-only "worktree-$slug"
}
wr_selfignored() { mkdir -p "$1"; printf '*\n' > "$1/.gitignore"; echo gen > "$1/$2"; }
wr_tracked hsk1 .husky/pre-commit; wr_selfignored "$(wr_path hsk1)/.husky/_" husky.sh
wr_retired "husky's self-ignored .husky/_/ and the files git lists inside it are regenerable" hsk1
wr_tracked hsk2 lib/keep; wr_selfignored "$(wr_path hsk2)/lib/_" results.json
wr_refused "a self-ignored _/ outside .husky is not regenerable (no bare-basename match)" hsk2 "ignored: .*lib/_/"
wr_tracked hsk3 .husky/pre-commit; wr_selfignored "$(wr_path hsk3)/.husky/_" .env
wr_refused "a secret-named file inside a regenerable directory is still refused" hsk3 "secrets: .*\.husky/_/\.env"
printf '*.tsbuildinfo\n' >> "$WR/.git/info/exclude"
wr_tracked tsb1 pkg/keep; echo '{}' > "$(wr_path tsb1)/tsconfig.tsbuildinfo"; echo '{}' > "$(wr_path tsb1)/pkg/tsconfig.app.tsbuildinfo"
wr_retired "*.tsbuildinfo files are regenerable" tsb1
wr_landed tsb2; mkdir -p "$(wr_path tsb2)/cache.tsbuildinfo"; echo precious > "$(wr_path tsb2)/cache.tsbuildinfo/data"
wr_refused "an ignored DIRECTORY named *.tsbuildinfo is not regenerable (the suffix is file-only)" tsb2 "ignored: .*cache\.tsbuildinfo/"
# ---- round 2 (codex, grok): raw bytes and modes, newline-bearing repo paths ----
wr_landed flt1
printf 'flt1.txt filter=strip\n' >> "$WR/.git/info/attributes"; git -C "$WR" config filter.strip.clean "sed /LOCAL=/d"
git -C "$(wr_path flt1)" update-index --assume-unchanged flt1.txt; echo 'LOCAL=1' >> "$(wr_path flt1)/flt1.txt"
wr_refused "a clean filter cannot hide an assume-unchanged edit (raw bytes compared)" flt1 "dirty: 1 tracked"
: > "$WR/.git/info/attributes"; git -C "$WR" config --unset filter.strip.clean
wr_landed exe1; git -C "$(wr_path exe1)" update-index --assume-unchanged exe1.txt; chmod +x "$(wr_path exe1)/exe1.txt"
wr_refused "an executable-bit change under assume-unchanged is refused" exe1 "dirty: 1 tracked"
run_wr worktree new lnk1 >/dev/null 2>&1; ln -s target-one "$(wr_path lnk1)/lnk"
git -C "$(wr_path lnk1)" add lnk; wr_commit "$(wr_path lnk1)" "feat: lnk"; git -C "$WR" merge -q --ff-only worktree-lnk1
git -C "$(wr_path lnk1)" update-index --assume-unchanged lnk; ln -sfn "$(printf 'target\none')" "$(wr_path lnk1)/lnk"
wr_refused "a symlink retargeted under assume-unchanged is refused (link text exact)" lnk1 "dirty: 1 tracked"
wr_landed bare2; git init -q --bare "$(wr_path bare2)/node_modules/$(printf 'mirror\nrepo.git')"
wr_refused "a bare repository under a newline-bearing directory is refused" bare2 "nested-git: "
wr_landed proc1
(cd "$(wr_path proc1)" && exec sleep 30) & WR_P1=$!
wr_wait_lsof "$WR_P1" "$(wr_path proc1)" || true
wr_refused "refuses while a process has its cwd inside" proc1 "processes: pid .*$WR_P1"
kill "$WR_P1" 2>/dev/null; wait "$WR_P1" 2>/dev/null
wr_landed proc2
sleep 30 < "$(wr_path proc2)/proc2.txt" & WR_P2=$!
wr_wait_lsof "$WR_P2" "proc2.txt" || true
wr_refused "refuses while a process holds a file open inside" proc2 "processes: pid .*$WR_P2"
kill "$WR_P2" 2>/dev/null; wait "$WR_P2" 2>/dev/null
wr_retired "the same worktree retires once the process is gone" proc2
wr_landed lsof1
printf '#!/bin/sh\nexit 1\n' > "$WR_BIN/lsof"; chmod +x "$WR_BIN/lsof"
wr_refused "refuses when processes cannot be listed (lsof failed)" lsof1 "processes: could not list" PATH="$WR_BIN:$PATH"
rm -f "$WR_BIN/lsof"
wr_landed lock1; git -C "$WR" worktree lock --reason "another session" "$(wr_path lock1)"
wr_refused "refuses a worktree locked by its owner" lock1 "lock: .*another session"
git -C "$WR" worktree unlock "$(wr_path lock1)"
wr_landed cwd1
WR_CWD="$(cd "$(wr_path cwd1)" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" worktree retire worktree-cwd1 --yes 2>&1)"; WR_CRC=$?
[ "$WR_CRC" = 3 ] && printf '%s' "$WR_CWD" | grep -q 'refused: cwd:' && wr_kept cwd1 \
  && ok "refuses the worktree you are standing in" || fail "cwd rc=$WR_CRC: $WR_CWD"
check_not "refuses an unmanaged worktree" run_wr worktree retire side --yes
[ -d "$WORK/side-wt" ] && ok "the unmanaged worktree survives the refused retire" || fail "unmanaged worktree removed"
WR_MAIN="$(run_wr worktree retire main --yes 2>&1)"; WR_MRC=$?
[ "$WR_MRC" = 3 ] && printf '%s' "$WR_MAIN" | grep -q 'refused: kind: the primary' \
  && ok "refuses the primary checkout / default branch" || fail "main rc=$WR_MRC: $WR_MAIN"
mkdir -p "$WORK/elsewhere/sym1"; ln -s "$WORK/elsewhere/sym1" "$(wr_path sym1)"
git -C "$WR" worktree add -q -b worktree-sym1 "$(wr_path sym1)" main >/dev/null 2>&1
git -C "$WR" rev-parse -q --verify refs/heads/worktree-sym1 >/dev/null \
  && ! run_wr worktree list 2>/dev/null | grep -F " branch=worktree-sym1 " | grep_full -q "kind=managed" \
  && ! run_wr worktree retire worktree-sym1 --yes >/dev/null 2>&1 && [ -d "$WORK/elsewhere/sym1" ] \
  && ok "a symlinked managed-path component is not managed and is refused" || fail "symlinked slug accepted"

# ---- presence: owner stamp, name match, self, dead ----
WR_CL="$(run_wr presence claim --name owner-sess --role "owns pres1")"
WR_OI="$(printf '%s' "$WR_CL" | sed -n 's/.*instance: //p')"
(cd "$WR" && env COMMS_PRESENCE_NAME=owner-sess COMMS_PRESENCE_INSTANCE="$WR_OI" "$COMMS" worktree new pres1) >/dev/null 2>&1
[ -f "$WR/.comms/worktrees/pres1.owner" ] && ok "worktree new stamps the creating session as owner" || fail "no owner stamp"
wr_refused "refuses while the owning session is live (owner stamp)" pres1 "presence: live:owner-sess"
wr_retired "the owning session itself may retire it" pres1 COMMS_PRESENCE_NAME=owner-sess COMMS_PRESENCE_INSTANCE="$WR_OI"
[ ! -f "$WR/.comms/worktrees/pres1.owner" ] && ok "a successful retire removes the owner stamp" || fail "owner stamp left behind"
wr_landed pres2
WR_CL2="$(run_wr presence claim --name pres2 --role "name match")"
wr_refused "refuses while a live session is named like the slug" pres2 "presence: live:pres2"
wr_landed pres4
WR_CL4="$(run_wr presence claim --name owner4 --role "owns pres4")"
WR_OI4="$(printf '%s' "$WR_CL4" | sed -n 's/.*instance: //p')"
printf 'owner4 %s\n' "$WR_OI4" > "$WR/.comms/worktrees/pres4.owner"
printf 'not json' > "$WR/.comms/sessions/owner4-$WR_OI4.json"
wr_refused "an unreadable owner record blocks as ambiguous (associated by filename)" pres4 "presence: ambig:owner4"
wr_landed pres3
printf '{\n  "name": "pres3", "instance": "cccccccccccccccccccccccccccccccc", "state": "working", "host": "%s", "pid": "99999999", "pid_started": "gone", "last_heartbeat_epoch": "1"\n}\n' "$(hostname)" > "$WR/.comms/sessions/pres3-cccccccccccccccccccccccccccccccc.json"
wr_retired "a dead presence record does not block" pres3

# ---- the branch CAS, branch-only targets, usage ----
wr_landed cas1
WR_TIP="$(git -C "$WR" rev-parse worktree-cas1)"
WR_ADV="$(git -C "$WR" commit-tree "$WR_TIP^{tree}" -p "$WR_TIP" -m advance)"
printf '#!/bin/bash\nif [ "$3" = update-ref ]; then "%s" -C "$2" update-ref refs/heads/worktree-cas1 "%s"; fi\nexec "%s" "$@"\n' "$WR_GIT" "$WR_ADV" "$WR_GIT" > "$WR_BIN/git"; chmod +x "$WR_BIN/git"
(cd "$WR" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE PATH="$WR_BIN:$PATH" "$COMMS" worktree retire worktree-cas1 --yes) >/dev/null 2>&1; WR_CAS=$?
rm -f "$WR_BIN/git"
[ "$WR_CAS" = 4 ] && [ ! -e "$(wr_path cas1)" ] && [ "$(git -C "$WR" rev-parse -q --verify refs/heads/worktree-cas1)" = "$WR_ADV" ] \
  && ok "a branch advanced after the worktree removal survives (CAS delete, exit 4)" || fail "CAS rc=$WR_CAS"
git -C "$WR" symbolic-ref refs/heads/alias1 refs/heads/main
WR_MAINTIP="$(git -C "$WR" rev-parse main)"
WR_AL="$(run_wr worktree retire alias1 --yes 2>&1)"; WR_ARC=$?
[ "$WR_ARC" = 3 ] && printf '%s' "$WR_AL" | grep -q 'symbolic ref' && [ "$(git -C "$WR" rev-parse -q --verify refs/heads/main)" = "$WR_MAINTIP" ] \
  && ok "a symbolic branch is refused and the branch it points at survives" || fail "symref rc=$WR_ARC: $WR_AL"
git -C "$WR" symbolic-ref -d refs/heads/alias1
git -C "$WR" branch -q bis1 main
git -C "$WR" worktree add -q "$WORK/bis-wt" bis1 >/dev/null 2>&1
(cd "$WORK/bis-wt" && git bisect start -q main "$(git rev-parse main~4)" >/dev/null 2>&1)
WR_BI="$(run_wr worktree retire bis1 --yes 2>&1)"; WR_BRC=$?
[ "$WR_BRC" = 3 ] && printf '%s' "$WR_BI" | grep -q 'bisect in progress' && git -C "$WR" rev-parse -q --verify refs/heads/bis1 >/dev/null \
  && ok "a branch held by a paused bisect is refused" || fail "bisect rc=$WR_BRC: $WR_BI"
git -C "$WR" branch -q rb1 main~1
git -C "$WR" worktree add -q "$WORK/rb-wt" rb1 >/dev/null 2>&1
(cd "$WORK/rb-wt" && git -c user.email=t@t -c user.name=t rebase -q -x false main~3 >/dev/null 2>&1)
WR_RB="$(run_wr worktree retire rb1 --yes 2>&1)"; WR_RRC=$?
[ "$WR_RRC" = 3 ] && printf '%s' "$WR_RB" | grep -q 'rebase in progress' && git -C "$WR" rev-parse -q --verify refs/heads/rb1 >/dev/null \
  && ok "a branch held by a paused rebase is refused" || fail "rebase rc=$WR_RRC: $WR_RB"
WR_RBGD="$(git -C "$WORK/rb-wt" rev-parse --absolute-git-dir)"
chmod 000 "$WR_RBGD/rebase-merge"
WR_RB2="$(run_wr worktree retire rb1 --yes 2>&1)"; WR_RRC2=$?
chmod 755 "$WR_RBGD/rebase-merge"
[ "$WR_RRC2" = 3 ] && printf '%s' "$WR_RB2" | grep -q 'unreadable' && git -C "$WR" rev-parse -q --verify refs/heads/rb1 >/dev/null \
  && ok "operation state that cannot be read counts as held (permission denied)" || fail "denied rebase state rc=$WR_RRC2: $WR_RB2"
git -C "$WR" branch -q ur1 main~1
git -C "$WR" worktree add -q -b urx "$WORK/ur-wt" main >/dev/null 2>&1
(cd "$WORK/ur-wt" && git -c user.email=t@t -c user.name=t rebase -q --update-refs -x false main~3 >/dev/null 2>&1)
WR_UR="$(run_wr worktree retire ur1 --yes 2>&1)"; WR_URRC=$?
[ "$WR_URRC" = 3 ] && printf '%s' "$WR_UR" | grep -q 'update-refs' && git -C "$WR" rev-parse -q --verify refs/heads/ur1 >/dev/null \
  && ok "a branch reserved by a paused rebase --update-refs is refused" || fail "update-refs rc=$WR_URRC: $WR_UR"
wr_landed am1
printf 'From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\nFrom: t <t@t>\nSubject: [PATCH] x\n\n---\n a.txt | 2 +-\n\ndiff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-nomatch\n+other\n' > "$WORK/am1.patch"
(cd "$(wr_path am1)" && git -c user.email=t@t -c user.name=t am -q "$WORK/am1.patch" >/dev/null 2>&1)
[ -d "$(git -C "$(wr_path am1)" rev-parse --absolute-git-dir)/rebase-apply" ] \
  && wr_refused "a worktree with a paused git am is refused" am1 "branch: held by an operation in progress" \
  || fail "fixture: git am did not pause"
wr_landed cpk1
(cd "$(wr_path cpk1)" && git -c user.email=t@t -c user.name=t cherry-pick HEAD >/dev/null 2>&1)
[ -e "$(git -C "$(wr_path cpk1)" rev-parse --absolute-git-dir)/CHERRY_PICK_HEAD" ] \
  && wr_refused "a worktree with a stopped (empty) cherry-pick is refused" cpk1 "branch: held by an operation in progress" \
  || fail "fixture: cherry-pick did not stop"
wr_line worktree-cpk1 | grep_full -q "retire=blocked:.*branch" \
  && ok "list runs the same operation gate as retire" || fail "list missed the stopped cherry-pick: $(wr_line worktree-cpk1)"
# ---- round 3 (codex): notes merges, private refs, literal pathspecs ----
wr_landed nm1
WR_NMC="$(git -C "$(wr_path nm1)" rev-parse HEAD)"
git -C "$(wr_path nm1)" -c user.email=t@t -c user.name=t notes --ref=na add -m one "$WR_NMC"
git -C "$(wr_path nm1)" -c user.email=t@t -c user.name=t notes --ref=nb add -m two "$WR_NMC"
(cd "$(wr_path nm1)" && git -c user.email=t@t -c user.name=t notes --ref=na merge nb >/dev/null 2>&1)
[ -d "$(git -C "$(wr_path nm1)" rev-parse --absolute-git-dir)/NOTES_MERGE_WORKTREE" ] \
  && wr_refused "a worktree with a paused notes merge is refused" nm1 "branch: held by an operation in progress" \
  || fail "fixture: notes merge did not pause"
wr_landed pr1
WR_PRC="$(git -C "$(wr_path pr1)" commit-tree "HEAD^{tree}" -p HEAD -m saved)"
git -C "$(wr_path pr1)" update-ref refs/worktree/saved "$WR_PRC"
wr_refused "a private worktree ref naming unlanded history is refused" pr1 "private-ref: .*refs/worktree/saved"
wr_landed pr2; git -C "$(wr_path pr2)" update-ref refs/worktree/kept HEAD
wr_retired "a private worktree ref already on main does not block" pr2
run_wr worktree new col1 >/dev/null 2>&1
echo same > "$(wr_path col1)/a2"; echo other > "$(wr_path col1)/:a2"
git -C "$(wr_path col1)" add -- a2 ./:a2; wr_commit "$(wr_path col1)" "feat: col"; git -C "$WR" merge -q --ff-only worktree-col1
git -C "$(wr_path col1)" update-index --assume-unchanged ':a2'; echo same > "$(wr_path col1)/:a2"
wr_refused "a hidden edit to a colon-prefixed file is compared against itself (literal pathspec)" col1 "dirty: 1 tracked"
grep -q same "$(wr_path col1)/:a2" && ok "the colon-prefixed file's edit survives" || fail "colon file edit lost"
# ---- round 4 (codex): unsearchable directories are unknown, never absent ----
wr_landed acc1; wr_landed acc2
chmod 000 "$(wr_path acc1)"
WR_AL="$(run_wr worktree list 2>/dev/null)"; WR_ALRC=$?
WR_AR="$(run_wr worktree retire worktree-acc1 --yes 2>&1)"; WR_ARRC=$?
chmod 755 "$(wr_path acc1)"
[ "$WR_ALRC" = 0 ] && printf '%s\n' "$WR_AL" | grep -F " branch=worktree-acc1 " | grep_full -q "retire=blocked:.*unreadable" \
  && printf '%s\n' "$WR_AL" | grep -qF " branch=worktree-acc2 " \
  && ok "an unenterable worktree is a blocked row and list continues past it" || fail "list aborted on an unenterable tree rc=$WR_ALRC"
[ "$WR_ARRC" = 3 ] && wr_kept acc1 && ok "retire refuses (exit 3) an unenterable worktree" || fail "unenterable retire rc=$WR_ARRC: $WR_AR"
WR_CL5="$(run_wr presence claim --name owner5 --role "owns acc3")"
WR_OI5="$(printf '%s' "$WR_CL5" | sed -n 's/.*instance: //p')"
(cd "$WR" && env COMMS_PRESENCE_NAME=owner5 COMMS_PRESENCE_INSTANCE="$WR_OI5" "$COMMS" worktree new acc3) >/dev/null 2>&1
echo acc3 > "$(wr_path acc3)/acc3.txt"; git -C "$(wr_path acc3)" add acc3.txt; wr_commit "$(wr_path acc3)" "feat: acc3"; git -C "$WR" merge -q --ff-only worktree-acc3
chmod 000 "$WR/.comms/worktrees"
WR_S1="$(run_wr worktree retire worktree-acc3 --yes 2>&1)"; WR_S1RC=$?
chmod 755 "$WR/.comms/worktrees"
[ "$WR_S1RC" = 3 ] && printf '%s' "$WR_S1" | grep -q 'refused: presence' && wr_kept acc3 \
  && ok "an unsearchable owner-stamp directory blocks (unknown owner)" || fail "hidden stamp rc=$WR_S1RC: $WR_S1"
chmod 000 "$WR/.comms"
WR_S2="$(run_wr worktree retire worktree-acc3 --yes 2>&1)"; WR_S2RC=$?
chmod 755 "$WR/.comms"
[ "$WR_S2RC" = 3 ] && printf '%s' "$WR_S2" | grep -q 'refused: presence' && wr_kept acc3 \
  && ok "an unsearchable .comms blocks (sessions and stamps unknown)" || fail "hidden .comms rc=$WR_S2RC: $WR_S2"
# ---- round 5 (codex, grok): registrations git drops, unreachable metadata, the default ref ----
for WR_F in HEAD gitdir; do
  git -C "$WR" worktree add -q -b "reg-$WR_F" "$WORK/reg-$WR_F-wt" main >/dev/null 2>&1
  WR_RG="$(git -C "$WORK/reg-$WR_F-wt" rev-parse --absolute-git-dir)"
  chmod 000 "$WR_RG/$WR_F"
  WR_RR="$(run_wr worktree retire "reg-$WR_F" --yes 2>&1)"; WR_RRRC=$?
  chmod 644 "$WR_RG/$WR_F"
  [ "$WR_RRRC" = 3 ] && printf '%s' "$WR_RR" | grep -q 'unreadable worktree registration' \
    && git -C "$WR" rev-parse -q --verify "refs/heads/reg-$WR_F" >/dev/null && [ -d "$WORK/reg-$WR_F-wt" ] \
    && ok "an unreadable registration $WR_F refuses (git drops it from the listing)" || fail "unreadable $WR_F rc=$WR_RRRC: $WR_RR"
done
WR_CL6="$(run_wr presence claim --name owner6 --role "owns acc4")"
WR_OI6="$(printf '%s' "$WR_CL6" | sed -n 's/.*instance: //p')"
(cd "$WR" && env COMMS_PRESENCE_NAME=owner6 COMMS_PRESENCE_INSTANCE="$WR_OI6" "$COMMS" worktree new acc4) >/dev/null 2>&1
echo acc4 > "$(wr_path acc4)/acc4.txt"; git -C "$(wr_path acc4)" add acc4.txt; wr_commit "$(wr_path acc4)" "feat: acc4"; git -C "$WR" merge -q --ff-only worktree-acc4
mkdir -p "$WORK/hidden"; mv "$WR/.comms/sessions" "$WORK/hidden/sessions"; ln -s "$WORK/hidden/sessions" "$WR/.comms/sessions"; chmod 000 "$WORK/hidden"
WR_S3="$(run_wr worktree retire worktree-acc4 --yes 2>&1)"; WR_S3RC=$?
chmod 755 "$WORK/hidden"; rm "$WR/.comms/sessions"; mv "$WORK/hidden/sessions" "$WR/.comms/sessions"
[ "$WR_S3RC" = 3 ] && printf '%s' "$WR_S3" | grep -q 'refused: presence' && wr_kept acc4 \
  && ok "a sessions dir symlinked somewhere unreachable is unknown, not empty" || fail "hidden symlinked sessions rc=$WR_S3RC: $WR_S3"
wr_landed oct1
printf '{\n  "name": "oct1", "instance": "dddddddddddddddddddddddddddddddd", "state": "working", "host": "%s", "last_heartbeat_epoch": "08"\n}\n' "$(hostname)" > "$WR/.comms/sessions/oct1-dddddddddddddddddddddddddddddddd.json"
run_wr worktree list >/dev/null 2>&1 && ok "a heartbeat bash cannot do arithmetic on does not abort list" || fail "octal heartbeat aborted list"
wr_refused "that record is ambiguous and blocks" oct1 "presence: ambig:oct1"
rm -f "$WR/.comms/sessions/oct1-dddddddddddddddddddddddddddddddd.json"
chmod 000 "$WR/.claude/worktrees"
WR_UW="$(run_wr worktree list 2>/dev/null | grep -F ' branch=worktree-acc2 ')"
chmod 755 "$WR/.claude/worktrees"
printf '%s' "$WR_UW" | grep -q 'unreadable' && ! printf '%s' "$WR_UW" | grep -q 'missing' \
  && ok "an unsearchable parent reads as unreadable, never as missing (no prune advice)" || fail "unsearchable parent row: $WR_UW"
DM="$WORK/default-repo"; mkdir -p "$DM"; DM="$(cd "$DM" && pwd -P)"
git -C "$DM" init -q -b main; printf '.comms/\n.claude/worktrees/\n' > "$DM/.gitignore"; git -C "$DM" add .gitignore; wr_commit "$DM" init
(cd "$DM" && "$COMMS" worktree new dm1) >/dev/null 2>&1
echo x > "$DM/.claude/worktrees/dm1/x.txt"; git -C "$DM/.claude/worktrees/dm1" add x.txt; wr_commit "$DM/.claude/worktrees/dm1" "feat: x"
git -C "$DM" branch -q master worktree-dm1; git -C "$DM" checkout -q --detach
chmod 000 "$DM/.git/refs/heads/main"
(cd "$DM" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" worktree retire worktree-dm1 --yes) >/dev/null 2>&1; WR_DMRC=$?
chmod 644 "$DM/.git/refs/heads/main"
[ "$WR_DMRC" != 0 ] && [ -d "$DM/.claude/worktrees/dm1" ] && git -C "$DM" rev-parse -q --verify refs/heads/worktree-dm1 >/dev/null \
  && ok "an unreadable main never falls back to master as the landing gate" || fail "unreadable main fell back (rc=$WR_DMRC)"
# ---- round 6 (codex, grok): git without show-ref --exists; unstat-able bare-repo siblings ----
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = --exists ] && { echo "error: unknown option" >&2; exit 129; }; done\nexec "%s" "$@"\n' "$WR_GIT" > "$WR_BIN/git"; chmod +x "$WR_BIN/git"
(cd "$WR" && env PATH="$WR_BIN:$PATH" "$COMMS" worktree new old1) >/dev/null 2>&1 && [ -d "$(wr_path old1)" ] \
  && ok "worktree new works on a git without show-ref --exists" || fail "worktree new broke on older git"
MS="$WORK/master-repo"; mkdir -p "$MS"; MS="$(cd "$MS" && pwd -P)"
git -C "$MS" init -q -b master; printf '.comms/\n.claude/worktrees/\n' > "$MS/.gitignore"; git -C "$MS" add .gitignore; wr_commit "$MS" init
(cd "$MS" && env PATH="$WR_BIN:$PATH" "$COMMS" worktree new ms1) >/dev/null 2>&1 && [ "$(git -C "$MS" rev-parse worktree-ms1)" = "$(git -C "$MS" rev-parse master)" ] \
  && ok "older git: a provably absent main falls back to master (ref store read directly)" || fail "older-git master fallback"
chmod 000 "$DM/.git/refs/heads/main"
(cd "$DM" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE PATH="$WR_BIN:$PATH" "$COMMS" worktree retire worktree-dm1 --yes) >/dev/null 2>&1; WR_DM2=$?
chmod 644 "$DM/.git/refs/heads/main"
rm -f "$WR_BIN/git"
[ "$WR_DM2" != 0 ] && [ -d "$DM/.claude/worktrees/dm1" ] \
  && ok "older git: an unreadable main still never falls back to master" || fail "older-git unreadable main fell back (rc=$WR_DM2)"
wr_landed bare3; WR_B3="$(wr_path bare3)/node_modules/m.git"; mkdir -p "$WR_B3/refs" "$WORK/sealed/objects"
echo 'ref: refs/heads/main' > "$WR_B3/HEAD"; ln -s "$WORK/sealed/objects" "$WR_B3/objects"; chmod 000 "$WORK/sealed"
wr_refused "a bare repo whose objects/ cannot be stat'd is still a nested repo" bare3 "nested-git: .*m.git"
chmod 755 "$WORK/sealed"
# ---- round 7 (codex): refs a listing omits; the target of a symbolic default branch ----
wr_landed pr3
WR_PR3="$(git -C "$(wr_path pr3)" commit-tree "HEAD^{tree}" -p HEAD -m saved)"
git -C "$(wr_path pr3)" update-ref refs/worktree/saved "$WR_PR3"
WR_PR3F="$(git -C "$(wr_path pr3)" rev-parse --absolute-git-dir)/refs/worktree/saved"
chmod 000 "$WR_PR3F"
WR_P3="$(run_wr worktree retire worktree-pr3 --yes 2>&1)"; WR_P3RC=$?
chmod 644 "$WR_PR3F"
[ "$WR_P3RC" = 3 ] && printf '%s' "$WR_P3" | grep -q 'refused: content' && wr_kept pr3 \
  && [ "$(git -C "$(wr_path pr3)" rev-parse -q --verify refs/worktree/saved)" = "$WR_PR3" ] \
  && ok "an unreadable private ref is unknown content, and it survives" || fail "unreadable private ref rc=$WR_P3RC: $WR_P3"
SY="$WORK/symmain-repo"; mkdir -p "$SY"; SY="$(cd "$SY" && pwd -P)"
git -C "$SY" init -q -b master; printf '.comms/\n.claude/worktrees/\n' > "$SY/.gitignore"; git -C "$SY" add .gitignore; wr_commit "$SY" init
git -C "$SY" symbolic-ref refs/heads/main refs/heads/master; git -C "$SY" checkout -q --detach
WR_SY="$(cd "$SY" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" worktree retire master --yes 2>&1)"; WR_SYRC=$?
[ "$WR_SYRC" = 3 ] && printf '%s' "$WR_SY" | grep -q 'symbolic ref refs/heads/main points at it' \
  && git -C "$SY" rev-parse -q --verify refs/heads/master >/dev/null && git -C "$SY" rev-parse -q --verify refs/heads/main >/dev/null \
  && ok "the target of a symbolic default branch is refused and main still resolves" || fail "symbolic default target rc=$WR_SYRC: $WR_SY"
# ---- round 8 (codex): ref directories that can be entered but not listed ----
chmod 333 "$SY/.git/refs"
WR_SY2="$(cd "$SY" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" worktree retire master --yes 2>&1)"; WR_SY2RC=$?
chmod 755 "$SY/.git/refs"
[ "$WR_SY2RC" = 3 ] && git -C "$SY" rev-parse -q --verify refs/heads/master >/dev/null \
  && ok "an unlistable refs/ cannot hide that master is main's target" || fail "unlistable refs rc=$WR_SY2RC: $WR_SY2"
wr_landed pr4
WR_PR4="$(git -C "$(wr_path pr4)" commit-tree "HEAD^{tree}" -p HEAD -m saved)"
git -C "$(wr_path pr4)" update-ref refs/worktree/saved "$WR_PR4"
WR_PR4G="$(git -C "$(wr_path pr4)" rev-parse --absolute-git-dir)"
chmod 333 "$WR_PR4G/refs"
WR_P4="$(run_wr worktree retire worktree-pr4 --yes 2>&1)"; WR_P4RC=$?
chmod 755 "$WR_PR4G/refs"
[ "$WR_P4RC" = 3 ] && printf '%s' "$WR_P4" | grep -q 'refused: private-ref: .*refs/worktree/saved' && wr_kept pr4 \
  && ok "a private ref git skips (unlistable refs/) is found on disk and refused" || fail "skipped private ref rc=$WR_P4RC: $WR_P4"
# ---- round 9 (codex): a ref backend whose on-disk layout the gates cannot read ----
RT="$WORK/reftable-repo"; mkdir -p "$RT"; RT="$(cd "$RT" && pwd -P)"
git init -q --ref-format=reftable -b main "$RT"; printf '.comms/\n.claude/worktrees/\n' > "$RT/.gitignore"; git -C "$RT" add .gitignore; wr_commit "$RT" init
(cd "$RT" && "$COMMS" worktree new rt1) >/dev/null 2>&1
printf 'From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\nFrom: t <t@t>\nSubject: [PATCH] x\n\n---\n .gitignore | 2 +-\n\ndiff --git a/.gitignore b/.gitignore\n--- a/.gitignore\n+++ b/.gitignore\n@@ -1 +1 @@\n-nomatch\n+other\n' > "$WORK/rt1.patch"
(cd "$RT/.claude/worktrees/rt1" && git -c user.email=t@t -c user.name=t am -q "$WORK/rt1.patch" >/dev/null 2>&1)
WR_RT="$(cd "$RT" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" worktree retire worktree-rt1 --yes 2>&1)"; WR_RTRC=$?
[ "$WR_RTRC" = 3 ] && printf '%s' "$WR_RT" | grep -q "refused: backend: ref storage 'reftable'" && [ -d "$RT/.claude/worktrees/rt1" ] \
  && [ -d "$(git -C "$RT/.claude/worktrees/rt1" rev-parse --absolute-git-dir)/rebase-apply" ] \
  && ok "a reftable repository is refused and its paused am survives" || fail "reftable rc=$WR_RTRC: $WR_RT"
git -C "$WR" branch -q bonly "$(git -C "$WR" rev-parse main)"
run_wr worktree retire bonly --yes >/dev/null 2>&1 && ! git -C "$WR" rev-parse -q --verify refs/heads/bonly >/dev/null \
  && ok "a landed branch with no worktree is deleted" || fail "branch-only retire"
git -C "$WR" branch -q bonly2 "$WR_ADV"
check_not "an unlanded branch with no worktree is refused" run_wr worktree retire bonly2 --yes
git -C "$WR" rev-parse -q --verify refs/heads/bonly2 >/dev/null && ok "the refused branch survives" || fail "unlanded branch deleted"
WR_U="$(run_wr worktree retire worktree-open1 worktree-cp1 2>&1)"; WR_URC=$?
[ "$WR_URC" = 2 ] && printf '%s' "$WR_U" | grep -q 'one target at a time' \
  && ok "retire takes one target at a time" || fail "two targets rc=$WR_URC"
WR_NB="$(run_wr worktree retire no-such-branch 2>&1)"; WR_NRC=$?
[ "$WR_NRC" = 3 ] && ok "an unknown branch is refused" || fail "unknown branch rc=$WR_NRC"

# ---- integrate retires nothing; the removal primitives are the safe ones ----
wr_new land1
run_wr integrate worktree-land1 >/dev/null 2>&1 && wr_kept land1 \
  && [ "$(git -C "$WR" rev-parse main)" = "$(git -C "$WR" rev-parse worktree-land1)" ] \
  && ok "integrate lands and leaves the source worktree and branch in place" || fail "integrate retired or did not land"
# Code lines only: the comments explain WHY these primitives are banned, by naming them.
! grep -vE '^[[:space:]]*#' "$REPO/helpers/worktree.sh" | grep_full -qE 'branch -[dD]|worktree remove.*(--force| -f)' \
  && ok "worktree.sh never uses branch -d/-D or a forced worktree remove" || fail "unsafe removal primitive in worktree.sh"
grep -qE '^HELPERS=".*worktree\.sh' "$REPO/install.sh" \
  && ok "install.sh ships worktree.sh" || fail "install.sh does not ship worktree.sh"

section "worktree new: pins the workspace name for the new worktree"
# basis slice 0b: a branch rename must not split one thread into two state files. The pin is the
# name the tree resolved to at creation, kept in the worktree's own git admin dir.
WP="$WORK/pin-repo"; mkdir -p "$WP"; WP="$(cd "$WP" && pwd -P)"
git -C "$WP" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$WP/.gitignore"; git -C "$WP" add .gitignore; wr_commit "$WP" init
run_wp() { (cd "$WP" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" "$@"); }
ws_in() { (cd "$1" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" workspace 2>/dev/null); }
WP_NEW="$(run_wp worktree new pin1 2>&1)"; WP1="$WP/.claude/worktrees/pin1"
printf '%s\n' "$WP_NEW" | grep -qx 'workspace: worktree-pin1 (pinned for this worktree)' && [ "$(ws_in "$WP1")" = worktree-pin1 ] \
  && ok "worktree new pins the name the new tree resolves to, and says so" || fail "worktree new pin output: $WP_NEW"
# The send happens BEFORE the rename; the state lookup AFTER it must still find the thread.
WP_MSG="$WP/.comms/to-codex/worktree-pin1_2026-09-25T10-00-00_pin-1.md"; mkdir -p "$WP/.comms/to-codex"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-09-25T10:00:00Z\nworkspace: worktree-pin1\nmessage_id: worktree-pin1_2026-09-25T10-00-00_pin-1\nthread: pin-thread\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 10\n---\n\n## What was done\nx\n' > "$WP_MSG"
(cd "$WP1" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" send --to codex "$WP_MSG") >/dev/null 2>&1
git -C "$WP1" branch -m pin1-renamed
[ "$(ws_in "$WP1")" = worktree-pin1 ] && (cd "$WP1" && "$COMMS" state get pin-thread >/dev/null 2>&1) \
  && [ "$(ls "$WP/.comms/state" | grep -c 'pin-thread')" = 1 ] \
  && ok "after a branch rename the identity holds and the thread keeps ONE state file" || fail "renamed pin: ws=$(ws_in "$WP1") state=$(ls "$WP/.comms/state" 2>&1 | tr '\n' ' ')"
# Control: the same rename in a tree `worktree new` did not create DOES re-key it — the case above
# is the pin's doing, not a resolver that ignores branches.
git -C "$WP" worktree add -q -b ctl-a "$WORK/pin-ctl" main >/dev/null 2>&1
WP_C1="$(ws_in "$WORK/pin-ctl")"; git -C "$WORK/pin-ctl" branch -m ctl-b; WP_C2="$(ws_in "$WORK/pin-ctl")"
[ "$WP_C1" = ctl-a ] && [ "$WP_C2" = ctl-b ] \
  && ok "control: an unpinned worktree's identity follows its branch" || fail "control ws: $WP_C1 -> $WP_C2"
[ -z "$(git -C "$WP1" status --porcelain)" ] && [ -f "$(git -C "$WP1" rev-parse --absolute-git-dir)/agent-comms-workspace" ] \
  && ok "the pin lives in the worktree's git admin dir, invisible to git status" || fail "pin location: $(git -C "$WP1" status --porcelain)"
[ "$(ws_in "$WP")" = main ] \
  && ok "the main checkout keeps its own identity (a worktree pin is per worktree)" || fail "main ws: $(ws_in "$WP")"
run_wp workspace set repo-ident >/dev/null 2>&1
[ "$(ws_in "$WP1")" = repo-ident ] \
  && ok "the repo pin still outranks a worktree pin (workspace set names every session)" || fail "repo pin order: $(ws_in "$WP1")"
WP_NEW="$(run_wp worktree new pin2 2>&1)"
printf '%s\n' "$WP_NEW" | grep -qx 'workspace: repo-ident (pinned for this worktree)' \
  && ok "under a repo pin, worktree new pins the repo's name, so removing the repo pin cannot re-key it" || fail "pin under repo pin: $WP_NEW"
rm -f "$WP/.comms/workspace"
[ "$(ws_in "$WP/.claude/worktrees/pin2")" = repo-ident ] \
  && ok "with the repo pin gone, that worktree keeps the name it was created under" || fail "pin2 after repo unpin: $(ws_in "$WP/.claude/worktrees/pin2")"
WP_LONG="abcdefghij-abcdefghij-abcdefghij-abcdefgh"   # 41 chars: the slug grammar's maximum
WP_NEW="$(run_wp worktree new "$WP_LONG" 2>&1)"
printf '%s\n' "$WP_NEW" | grep -qx "workspace: worktree-$WP_LONG (pinned for this worktree)" \
  && ok "the longest slug still pins (the shared name grammar allows 64 chars)" || fail "long slug pin: $WP_NEW"
WP_64="$(printf 'a%.0s' $(seq 1 64))"
run_wp workspace set "$WP_64" >/dev/null 2>&1 && ! run_wp workspace set "${WP_64}a" >/dev/null 2>&1 \
  && ok "workspace set shares that grammar: 64 chars accepted, 65 refused" || fail "workspace set 64/65"
rm -f "$WP/.comms/workspace"
# Retire removes the pin with the worktree's admin dir; it never blocks retirement.
WP3="$WP/.claude/worktrees/pin3"; run_wp worktree new pin3 >/dev/null 2>&1
WP3_ADMIN="$(git -C "$WP3" rev-parse --absolute-git-dir)"
echo x > "$WP3/x.txt"; git -C "$WP3" add x.txt; wr_commit "$WP3" "feat: x"; git -C "$WP" merge -q --ff-only worktree-pin3
run_wp worktree retire worktree-pin3 --yes >/dev/null 2>&1 && [ ! -e "$WP3" ] && [ ! -e "$WP3_ADMIN" ] \
  && ok "retire removes a pinned worktree, and the pin goes with its admin dir" || fail "retire pinned: $(ls "$WP3_ADMIN" 2>&1)"
