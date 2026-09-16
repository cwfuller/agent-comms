# Run through tests/run.sh; each group gets fresh fixtures.
section "grading pilot: findings extraction (the single-reviewer baseline)"
GR_FIX="$WORK/grading-repo"
mkdir -p "$GR_FIX"
GR_FIX="$(cd "$GR_FIX" && pwd -P)"
git -C "$GR_FIX" init -q -b main
printf '.comms/\n.agent-comms/\n' > "$GR_FIX/.gitignore"
git -C "$GR_FIX" add .gitignore >/dev/null 2>&1
git -C "$GR_FIX" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$GR_FIX/.comms/archive"
run_gr() { (cd "$GR_FIX" && env "$COMMS" "$@"); }

cat > "$GR_FIX/.comms/archive/gr_2026-08-01T10-00-00_fb-1.md" <<'GREOF'
---
type: review-feedback
from: codex
timestamp: 2026-08-01T10:00:00Z
head_sha: deadbeefcafe
workspace: gr
message_id: gr_2026-08-01T10-00-00_fb-1
thread: gr-thread-1
workflow: auto-implement
phase: implement
round: 1
max-rounds: 4
verdict: REQUEST_CHANGES
---

## Summary
Two real problems.

## Findings

### Blocking
- `helpers/x.sh:42` — the guard is inverted and the fail-closed path never runs.
  This continuation line belongs to the same finding.

### Advisory
- lib/legacy.rb:7 - bare path anchor, no backticks (the pre-2026-07 shape).
- The naming here reads inconsistently with the rest of the module, but there is
  no single line to point at.

### Process
- The handoff message was clear; no comms friction. This must never be graded.

## Validation
- `bash tests/run.sh`: passed. This bullet is outside the finding lanes.
GREOF

cat > "$GR_FIX/.comms/archive/gr_2026-08-02T10-00-00_fb-2.md" <<'GREOF'
---
type: review-feedback
from: grok
timestamp: 2026-08-02T10:00:00Z
workspace: gr
message_id: gr_2026-08-02T10-00-00_fb-2
thread: gr-thread-1
workflow: auto-implement
phase: implement
round: 2
max-rounds: 4
verdict: APPROVE
---

## Findings

### Blocking
- None.

### Advisory
- None.
GREOF

cat > "$GR_FIX/.comms/archive/gr_2026-08-03T10-00-00_req-1.md" <<'GREOF'
---
type: review-request
from: claude
timestamp: 2026-08-03T10:00:00Z
workspace: gr
message_id: gr_2026-08-03T10-00-00_req-1
thread: gr-thread-1
---

## Findings

### Blocking
- A review-REQUEST is not an observation and must never be extracted.
GREOF

GR_OUT="$(run_gr findings 2>/dev/null)"
GR_ROWS="$(printf '%s\n' "$GR_OUT" | tail -n +2)"
[ "$(printf '%s\n' "$GR_ROWS" | grep -c .)" = "3" ] \
  && ok "extracts exactly the 3 real findings (Process, None., and non-feedback excluded)" \
  || fail "finding count (got $(printf '%s\n' "$GR_ROWS" | grep -c .))"
printf '%s\n' "$GR_OUT" | head -1 | grep -q '^schema_version	finding_id' && ok "TSV header is emitted first" || fail "TSV header"
printf '%s\n' "$GR_ROWS" | grep -q 'never be graded' && fail "### Process leaked into the ledger" || ok "### Process never becomes a graded observation"
printf '%s\n' "$GR_ROWS" | grep -q 'outside the finding lanes' && fail "## Validation bullets leaked" || ok "bullets outside the lanes are not findings"
printf '%s\n' "$GR_ROWS" | grep -q 'review-REQUEST is not an observation' && fail "review-request extracted" || ok "only review-feedback is extracted"
printf '%s\n' "$GR_ROWS" | awk -F'\t' '$14=="helpers/x.sh:42"' | grep -q . \
  && ok "backticked path:line becomes the anchor" || fail "backtick anchor"
printf '%s\n' "$GR_ROWS" | awk -F'\t' '$14=="lib/legacy.rb:7"' | grep -q . \
  && ok "bare path:line anchor recovered (pre-2026-07 corpus shape)" || fail "bare anchor fallback"
printf '%s\n' "$GR_ROWS" | awk -F'\t' '$14=="" && $15 ~ /reads inconsistently/' | grep -q . \
  && ok "unanchored prose finding is KEPT with an empty anchor, never dropped" || fail "prose finding dropped"
printf '%s\n' "$GR_ROWS" | grep -q 'continuation line belongs to the same finding' \
  && ok "wrapped finding folds into one claim" || fail "continuation folding"
[ "$(printf '%s\n' "$GR_ROWS" | awk -F'\t' '$15 ~ /guard is inverted/' | wc -l | tr -d ' ')" = "1" ] \
  && ok "a wrapped finding is ONE row, not two" || fail "continuation split the finding"
printf '%s\n' "$GR_ROWS" | awk -F'\t' '$13=="blocking"' | grep -q 'guard is inverted' && ok "lane recorded" || fail "lane"
printf '%s\n' "$GR_ROWS" | awk -F'\t' '$5=="deadbeefcafe" && $9=="codex" && $8=="1"' | grep -q . \
  && ok "frontmatter provenance (base_sha, reviewer, round) is carried" || fail "provenance"
printf '%s\n' "$GR_ROWS" | awk -F'\t' '$4!="" || $10!="" || $11!=""' | grep -q . \
  && fail "retro rows invented artifact/runtime/prompt identity" \
  || ok "unknown fields stay EMPTY on retro rows, never guessed"
[ "$(printf '%s\n' "$GR_ROWS" | cut -f2 | sort -u | wc -l | tr -d ' ')" = "3" ] \
  && ok "finding_id is unique per finding" || fail "finding_id collision"
printf '%s\n' "$GR_ROWS" | cut -f12 | sort -u | grep -qx gating && ok "role defaults to gating" || fail "role default"

section "grading pilot: --out ledger is append-only and idempotent"
GR_LED="$GR_FIX/.comms/grades/findings.tsv"
run_gr findings --out "$GR_LED" >/dev/null
[ "$(tail -n +2 "$GR_LED" | grep -c .)" = "3" ] && ok "ledger seeded with 3 rows" || fail "ledger seed"
run_gr findings --out "$GR_LED" >/dev/null
[ "$(tail -n +2 "$GR_LED" | grep -c .)" = "3" ] && ok "re-extraction adds nothing (idempotent by finding_id)" || fail "ledger duplicated rows"
cat > "$GR_FIX/.comms/archive/gr_2026-08-04T10-00-00_fb-3.md" <<'GREOF'
---
type: review-feedback
from: codex
timestamp: 2026-08-04T10:00:00Z
workspace: gr
message_id: gr_2026-08-04T10-00-00_fb-3
thread: gr-thread-2
verdict: REQUEST_CHANGES
---

## Findings

### Blocking
- `helpers/y.sh:9` — a later review, extracted on the next pass.
GREOF
run_gr findings --out "$GR_LED" >/dev/null
[ "$(tail -n +2 "$GR_LED" | grep -c .)" = "4" ] && ok "a new review appends only its new row" || fail "incremental append"
[ "$(head -1 "$GR_LED" | grep -c '^schema_version')" = "1" ] && ok "header written exactly once" || fail "header duplicated"

section "grading pilot: shadow role + run identity are stamped, not inferred"
GR_SHADOW="$(run_gr findings --role shadow --review-set rs-1 --artifact art-abc \
  --reviewer-version 'grok/1.0.5' --prompt-version 'pv-deadbeef' \
  "$GR_FIX/.comms/archive/gr_2026-08-04T10-00-00_fb-3.md" 2>/dev/null | tail -n +2)"
printf '%s\n' "$GR_SHADOW" | awk -F'\t' '$12=="shadow" && $3=="rs-1" && $4=="art-abc" && $10=="grok/1.0.5" && $11=="pv-deadbeef"' | grep -q . \
  && ok "shadow row carries role, review_set, artifact, runtime and prompt identity" || fail "shadow stamping"
check_not "findings rejects an unknown role" run_gr findings --role primary
check_not "findings rejects an unknown option" run_gr findings --bogus

section "grading pilot: snapshot RETAINS the reviewed tree (a hash alone cannot)"
echo "worktree edit" > "$GR_FIX/dirty.txt"
git -C "$GR_FIX" add -A >/dev/null 2>&1
echo "untracked too" > "$GR_FIX/loose.txt"
GR_SNAP="$(run_gr snapshot)"
printf '%s' "$GR_SNAP" | grep -qE '^[0-9a-f]{40}$' && ok "snapshot prints a git object id" || fail "snapshot id (got $GR_SNAP)"
git -C "$GR_FIX" cat-file -e "$GR_SNAP^{commit}" 2>/dev/null && ok "snapshot id is a real commit object" || fail "snapshot object"
git -C "$GR_FIX" ls-tree -r --name-only "$GR_SNAP" 2>/dev/null | grep -qx dirty.txt \
  && ok "snapshot contains the uncommitted change under review" || fail "snapshot missing staged change"
git -C "$GR_FIX" ls-tree -r --name-only "$GR_SNAP" 2>/dev/null | grep -qx loose.txt \
  && ok "snapshot contains untracked files (a reviewer reads those too)" || fail "snapshot missing untracked"
run_gr snapshot list | grep -qx "$GR_SNAP" && ok "snapshot list reports the retained artifact" || fail "snapshot list"
# The whole point of anchoring: an unreferenced stash commit is gc bait, and a
# garbage-collected artifact is exactly the failure this prerequisite exists to fix.
git -C "$GR_FIX" reflog expire --expire=now --all >/dev/null 2>&1
git -C "$GR_FIX" gc --prune=now --quiet >/dev/null 2>&1
git -C "$GR_FIX" cat-file -e "$GR_SNAP^{commit}" 2>/dev/null \
  && ok "artifact survives an aggressive gc (the ref anchor is the retention)" || fail "artifact was garbage-collected"
git -C "$GR_FIX" -c user.email=t@t -c user.name=t commit -q -am "clean it" 2>/dev/null
rm -f "$GR_FIX/loose.txt"
GR_CLEAN_SNAP="$(run_gr snapshot)"
[ "$GR_CLEAN_SNAP" = "$(git -C "$GR_FIX" rev-parse HEAD)" ] \
  && ok "a clean tree snapshots to HEAD rather than failing" || fail "clean-tree snapshot"
check_not "snapshot rejects an unknown argument" run_gr snapshot bogus

section "grading pilot: prompt-version partitions grades across an instruction edit"
GR_HOME="$WORK/grading-home"
mkdir -p "$GR_HOME"
mkdir -p "$GR_FIX/.agent-comms" "$GR_FIX/.claude/commands"
echo "reviewer prompt v1" > "$GR_FIX/.claude/commands/auto.md"
run_gr_h() { (cd "$GR_FIX" && env HOME="$GR_HOME" "$COMMS" "$@"); }
PV1="$(run_gr_h prompt-version)"
printf '%s' "$PV1" | grep -qE '^[0-9a-f]{12}$' && ok "prompt-version prints a short content hash" || fail "prompt-version shape (got $PV1)"
[ "$PV1" = "$(run_gr_h prompt-version)" ] && ok "prompt-version is stable when nothing changes" || fail "prompt-version unstable"
echo "reviewer prompt v2 — one sentence added" > "$GR_FIX/.claude/commands/auto.md"
[ "$PV1" != "$(run_gr_h prompt-version)" ] && ok "editing a reviewer instruction changes the version" || fail "prompt-version blind to an edit"
echo "reviewer prompt v1" > "$GR_FIX/.claude/commands/auto.md"
[ "$PV1" = "$(run_gr_h prompt-version)" ] && ok "reverting the edit restores the version" || fail "prompt-version not content-addressed"
PV_BEFORE="$(run_gr_h prompt-version)"
echo "a newly installed surface" > "$GR_FIX/.claude/commands/read-from-codex.md"
[ "$PV_BEFORE" != "$(run_gr_h prompt-version)" ] \
  && ok "a surface APPEARING changes the version (missing files are hashed as markers)" || fail "prompt-version blind to an added surface"
# Capture BEFORE grepping: `producer | grep -q` races under `set -o pipefail` —
# grep exits on the first match, the producer takes SIGPIPE, and the pipeline
# reports 141. Cost us two phantom failures.
PV_LIST="$(run_gr_h prompt-version --list)"
printf '%s\n' "$PV_LIST" | grep -q 'auto.md' && ok "prompt-version --list names its inputs" || fail "prompt-version --list"
printf '%s\n' "$PV_LIST" | grep -q '^MISSING ' && ok "--list marks surfaces this install does not have" || fail "prompt-version missing marker"
check_not "prompt-version rejects an unknown option" run_gr_h prompt-version --bogus

section "grading pilot: shadow reviewer is a MEASUREMENT, structurally unable to gate"
SH_FIX="$WORK/shadow-repo"
mkdir -p "$SH_FIX"; SH_FIX="$(cd "$SH_FIX" && pwd -P)"
git -C "$SH_FIX" init -q -b main
git -C "$SH_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$SH_FIX/.comms/to-claude" "$SH_FIX/.comms/to-codex" "$SH_FIX/.comms/to-grok" "$SH_FIX/.comms/archive"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$SH_FIX/.comms/config"
printf '.comms/\n.agent-comms/\n' > "$SH_FIX/.gitignore"
echo "code under review" > "$SH_FIX/subject.txt"
SH_BIN="$WORK/shadow-bin"; mkdir -p "$SH_BIN"
cat > "$SH_BIN/grok" <<'SHSTUB'
#!/bin/bash
case "$1" in --version) echo "grok 9.9.9-stub"; exit 0 ;; esac
pf=""; prev=""
for a in "$@"; do [ "$prev" = "--prompt-file" ] && pf="$a"; prev="$a"; done
[ -n "$pf" ] && [ -f "$pf" ] || { echo "stub: no prompt file" >&2; exit 2; }
cp "$pf" "${SHADOW_PROMPT_COPY:-/dev/null}" 2>/dev/null || true
[ -n "${SHADOW_CWD_COPY:-}" ] && pwd > "$SHADOW_CWD_COPY"
[ -n "${SHADOW_SUBJECT_COPY:-}" ] && cat subject.txt > "$SHADOW_SUBJECT_COPY" 2>/dev/null
[ -n "${SHADOW_STUB_FAIL:-}" ] && exit 7
esc() { printf '%s' "$1" | awk '{printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-shadow-1"}\n'
REPLY="$(printf -- 'VERDICT: REQUEST_CHANGES\n\n## Summary\nshadow pass\n\n## Findings\n\n### Blocking\n- `subject.txt:1` — the shadow reviewer found something the primary did not.\n\n### Advisory\n- None.\n\n### Process\n- no friction')"
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
SHSTUB
chmod +x "$SH_BIN/grok"
run_sh() { (cd "$SH_FIX" && env PATH="$SH_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }

SH_REQ="$SH_FIX/.comms/to-codex/shadow-repo_2026-08-22T09-00-00_req-1.md"
cat > "$SH_REQ" <<'SHEOF'
---
type: review-request
from: claude
timestamp: 2026-08-22T09:00:00Z
workspace: shadow-repo
message_id: shadow-repo_2026-08-22T09-00-00_req-1
thread: sh-thread-1
workflow: auto-implement
phase: implement
round: 1
max-rounds: 4
---

## What was done
Changed subject.txt.

## Acceptance criteria
1. It works.
SHEOF

SH_OUT="$(run_sh shadow --to grok "$SH_REQ" 2>&1)"; SH_RC=$?
[ "$SH_RC" = "0" ] && ok "shadow run completes" || fail "shadow run (rc=$SH_RC): $SH_OUT"
SH_SET="$(find "$SH_FIX/.comms/grades/shadow" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)"
[ -n "$SH_SET" ] && [ -s "$SH_SET/grok.md" ] && ok "shadow reply is stored under .comms/grades/shadow/" || fail "shadow reply stored"
grep -q '^verdict: REQUEST_CHANGES$' "$SH_SET/grok.md" && ok "stored reply keeps its verdict (recorded, not obeyed)" || fail "stored verdict"

# The three properties that make "the shadow cannot gate" mechanical:
[ -z "$(find "$SH_FIX/.comms/to-claude" -type f 2>/dev/null)" ] \
  && ok "NOTHING was delivered to any inbox — the loop can never read it" || fail "shadow leaked a message into an inbox"
[ -f "$SH_REQ" ] && ok "the primary's review-request is NOT archived out from under it" || fail "shadow archived the inbound"
[ -z "$(find "$SH_FIX/.comms/state" -name '*sh-thread-1*' -type f 2>/dev/null)" ] \
  && ok "thread state is untouched (no awaiting_from clobber mid-loop)" || fail "shadow wrote thread state"

SH_LED="$SH_FIX/.comms/grades/findings.tsv"
[ -s "$SH_LED" ] && ok "shadow findings land in the ledger" || fail "ledger written"
SH_ROW="$(tail -n +2 "$SH_LED" | awk -F'\t' '$12=="shadow"' | head -1)"
[ -n "$SH_ROW" ] && ok "the row is stamped role=shadow" || fail "shadow role stamp"
printf '%s\n' "$SH_ROW" | awk -F'\t' '$4!="" && $3!="" && $11!=""' | grep -q . \
  && ok "shadow row carries artifact_id, review_set and prompt_version" || fail "shadow row identity"
printf '%s\n' "$SH_ROW" | awk -F'\t' '$10 ~ /9\.9\.9-stub/' | grep -q . \
  && ok "reviewer CLI version is captured at run time (unreconstructable later)" || fail "reviewer_version capture"
printf '%s\n' "$SH_ROW" | awk -F'\t' '$9=="grok"' | grep -q . && ok "reviewer identity recorded" || fail "reviewer identity"
SH_ART="$(printf '%s\n' "$SH_ROW" | cut -f4)"
git -C "$SH_FIX" cat-file -e "$SH_ART^{commit}" 2>/dev/null \
  && ok "the artifact the shadow read is retained and resolvable" || fail "artifact retained"
git -C "$SH_FIX" show "$SH_ART:subject.txt" 2>/dev/null | grep -q 'code under review' \
  && ok "the retained artifact really contains the reviewed content" || fail "artifact content"

[ -s "$SH_FIX/.comms/grades/sets.tsv" ] && ok "the set index is written" || fail "sets.tsv"
awk -F'\t' 'NR>1 && $3=="sh-thread-1" && $4=="1" && $10=="grok"' "$SH_FIX/.comms/grades/sets.tsv" | grep -q . \
  && ok "set index pairs thread+phase+round with the shadow agent" || fail "set index contents"

# The join: the GATING reviewer replies later, through the normal loop, knowing
# nothing about the shadow — and must still land on the same artifact.
SH_PRIMARY="$SH_FIX/.comms/archive/shadow-repo_2026-08-22T09-05-00_fb-1.md"
cat > "$SH_PRIMARY" <<'SHEOF'
---
type: review-feedback
from: codex
timestamp: 2026-08-22T09:05:00Z
workspace: shadow-repo
message_id: shadow-repo_2026-08-22T09-05-00_fb-1
thread: sh-thread-1
workflow: auto-implement
phase: implement
round: 1
max-rounds: 4
verdict: REQUEST_CHANGES
---

## Findings

### Blocking
- `subject.txt:1` — the gating reviewer's own finding.
SHEOF
run_sh findings --out "$SH_LED" "$SH_PRIMARY" >/dev/null
SH_PRIM_ROW="$(tail -n +2 "$SH_LED" | awk -F'\t' '$9=="codex"' | head -1)"
[ -n "$SH_PRIM_ROW" ] && ok "the gating reviewer's finding is extracted" || fail "primary extraction"
[ "$(printf '%s\n' "$SH_PRIM_ROW" | cut -f4)" = "$SH_ART" ] \
  && ok "gating and shadow rows JOIN on the same artifact via the set index" || fail "artifact join"
[ "$(printf '%s\n' "$SH_PRIM_ROW" | cut -f3)" = "$(printf '%s\n' "$SH_ROW" | cut -f3)" ] \
  && ok "both rows share one review_set_id — this is the matched pair" || fail "review_set join"
[ "$(printf '%s\n' "$SH_PRIM_ROW" | cut -f12)" = "gating" ] \
  && ok "the loop's own reviewer stays role=gating" || fail "gating role"

check_not "shadow refuses to shadow the request's own author" run_sh shadow --to claude "$SH_REQ"
check_not "shadow refuses a message that is not a review-request" run_sh shadow --to grok "$SH_PRIMARY"

# --no-deliver suppresses the trusted-parent BROKER, so "cannot gate" is a mechanism rather than a
# convention. WHETHER it can be honoured is a property of (agent, transport), NOT of the agent
# alone: over ACP the parent stamps and delivers, so a self-sending agent never sends and
# suppression holds. `shadow` used to gate on the registry string alone and so refused codex on
# the very path runphase WOULD have honoured (it checks `[ "$via" != "acp" ]` first). One
# accessor now states the rule for both. (S3-5.)
#
# The refusal branch is only REACHABLE where ACP cannot run, so it is tested with a node that
# fails the version probe — otherwise every registered agent is shadowable and this asserts
# nothing. That is the honest fixture, not a convenience.
SH_NONODE="$WORK/shadow-nonode"; mkdir -p "$SH_NONODE"
printf '#!/bin/sh\nexit 1\n' > "$SH_NONODE/node"; chmod +x "$SH_NONODE/node"
SH_UNBROKERED="$(PATH="$SH_NONODE:$PATH" run_sh shadow --to codex "$SH_REQ" 2>&1)" && SH_URC=0 || SH_URC=$?
[ "$SH_URC" != "0" ] && ok "shadow still refuses a self-sending agent when no brokered transport exists" || fail "unbrokered agent accepted with no ACP"
printf '%s\n' "$SH_UNBROKERED" | grep -q 'parent-brokered' \
  && ok "the refusal names WHY (only a parent-brokered transport can be shadowed)" || fail "unbrokered refusal message"
# ONE accessor, and it answers with the TRANSPORT, so shadow cannot re-decide the rule.
grep -q '^suppression_ok()' "$REPO/helpers/comms.sh" \
  && ok "one suppression_ok accessor states when --no-deliver can be honoured" || fail "no shared suppression predicate"
# node_ok must REFUSE a version-less node as a predicate, not by way of a numeric-comparison
# error. The verdict was already right; relying on the error was not. (codex, r1, advisory.)
SH_NODEOUT="$(PATH="$SH_NONODE:$PATH" "$REPO/helpers/acp.sh" supports codex 2>&1)" && SH_NODERC=0 || SH_NODERC=$?
[ "$SH_NODERC" -ne 0 ] && [ -z "$SH_NODEOUT" ] \
  && ok "an unusable node is refused cleanly, with no integer-expression diagnostic" || fail "node probe noisy or accepting (rc=$SH_NODERC out=$SH_NODEOUT)"
sed -n '/^cmd_shadow()/,/^}/p' "$REPO/helpers/comms.sh" | grep -q 'suppression_ok' \
  && ok "shadow gates on the shared accessor rather than the registry string" || fail "shadow still re-implements the rule"
sed -n '/^cmd_shadow()/,/^}/p' "$REPO/helpers/comms.sh" | grep -q -- '--via "$shadow_via"' \
  && ok "shadow PASSES the transport that makes suppression honourable" || fail "shadow does not pass --via"
# THE SUCCESS GATE, behaviourally. Everything above pins the REFUSAL and the source shape, so a
# suppression_ok that always returned 1 would leave them all green — the same vacuity shape this
# thread has already hit twice. A version-ok `node` makes acp_supports TRUE; a failing `npx` makes
# the turn die DOWNSTREAM of the gate, which is precisely what we want to observe. The assertion
# is the ABSENCE of the capability refusal, not the turn succeeding. (grok, r1, advisory.)
SH_OKBIN="$WORK/shadow-oknode"; mkdir -p "$SH_OKBIN"
printf '#!/bin/sh\nprintf "v22.22.3\\n"\n' > "$SH_OKBIN/node"; chmod +x "$SH_OKBIN/node"
printf '#!/bin/sh\nexit 9\n' > "$SH_OKBIN/npx"; chmod +x "$SH_OKBIN/npx"
SH_PASTGATE="$(PATH="$SH_OKBIN:$PATH" run_sh shadow --to codex "$SH_REQ" 2>&1 || true)"
printf '%s\n' "$SH_PASTGATE" | grep -q 'parent-brokered' \
  && fail "shadow refused codex at the capability gate even though ACP was available" \
  || ok "shadow gets PAST the capability gate for codex when a brokered transport exists"
# THE TRAP: relaxing the registry instead would let --no-deliver through on the NON-ACP path,
# where the child sends its own reply and suppression is a lie. runphase reads the same string.
cmd_agents_out="$(run_sh agents --supported)"
printf '%s' "$cmd_agents_out" | awk -F'\t' '$1=="codex"{print $2}' | grep -qv 'reviewer-consult-only' \
  && ok "codex was NOT given reviewer-consult-only (that would relax runphase's non-ACP guard)" || fail "registry relaxed for codex"
printf '%s' "$cmd_agents_out" | awk -F'\t' '$1=="claude"{print $2}' | grep -qv 'reviewer-consult-only' \
  && ok "claude was NOT given reviewer-consult-only either" || fail "registry relaxed for claude"
# CAPABILITY DRIFT, caught independently of cmd_transport. The registry is a SECOND source of
# routing truth: a caller reading it instead of the selector would infer a direct headless route
# for claude/codex that headless_ok refuses and runphase rejects. grok must still advertise it.
# (codex, S4-2 r3, blocking + process.)
printf '%s' "$cmd_agents_out" | awk -F'\t' '$1=="claude"||$1=="codex"{print $2}' | grep -q 'headless' \
  && fail "the registry still advertises a direct headless route for claude/codex" \
  || ok "claude and codex are not advertised as direct-headless-capable"
printf '%s' "$cmd_agents_out" | awk -F'\t' '$1=="grok"{print $2}' | grep -q 'headless' \
  && ok "grok still advertises headless (the one provider that keeps a non-ACP route)" \
  || fail "grok lost its headless capability"

# Prompt parity is the one thing this command must guarantee: an earlier version
# stamped review_set/artifact_id/role into a copy, which told the child it was a
# measurement and stopped the two reviewers answering the same prompt.
SH_PROMPT="$WORK/shadow-prompt-copy.md"
sh_req_for() {  # a distinct request per sub-test — one pairing per thread+phase+round
  local tag="$1" f="$SH_FIX/.comms/to-codex/shadow-repo_req-$1.md"
  sed -e "s|^thread: .*|thread: sh-$tag|" -e "s|^message_id: .*|message_id: shadow-repo_req-$tag|" "$SH_REQ" > "$f"
  printf '%s' "$f"
}
SH_REQ_PARITY="$(sh_req_for parity)"
(cd "$SH_FIX" && env PATH="$SH_BIN:$PATH" SHADOW_PROMPT_COPY="$SH_PROMPT" \
  COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" shadow --to grok --review-set parity-set "$SH_REQ_PARITY") >/dev/null 2>&1 || true
if [ -s "$SH_PROMPT" ]; then
  grep -qE '^(role: shadow|review_set:|artifact_id:|prompt_version:)' "$SH_PROMPT" \
    && fail "the shadow child was told it is a measurement (prompt parity broken)" \
    || ok "the shadow child sees the request WITHOUT any measurement field (prompt parity)"
  grep -q "$(grep -m1 '^message_id:' "$SH_REQ_PARITY")" "$SH_PROMPT" \
    && ok "the shadow child sees the ORIGINAL request, not a rewritten copy" || fail "shadow child saw a rewritten message_id"
else
  fail "shadow prompt was not captured"
fi

# grok_broker writes reply.md and validates it AFTERWARDS, so a stamped-but-degenerate
# reply exists on disk after a failed turn. Keying success on the file would score it.
cat > "$SH_BIN/grok" <<'SHSTUB3'
#!/bin/bash
case "$1" in --version) echo "grok 9.9.9-stub"; exit 0 ;; esac
printf '{"type":"system","subtype":"init","session_id":"stub-shadow-3"}\n'
printf '{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: APPROVE"}\n'
SHSTUB3
chmod +x "$SH_BIN/grok"
SH_EMPTY_ROWS_BEFORE="$(tail -n +2 "$SH_LED" | grep -c .)"
SH_EMPTY_OUT="$(run_sh shadow --to grok --review-set emptybody-set "$(sh_req_for emptybody)" 2>&1)" && SH_ERC=0 || SH_ERC=$?
[ "$SH_ERC" != "0" ] && ok "a verdict-line-only reply (empty body) fails the shadow run" || fail "empty-body shadow exit code"
[ "$(tail -n +2 "$SH_LED" | grep -c .)" = "$SH_EMPTY_ROWS_BEFORE" ] \
  && ok "a stamped-but-invalid reply is NOT scored (success is the runner's verdict, not a file's existence)" \
  || fail "an invalid reply was scored into the ledger"

# An agent that dies is an OPERATIONAL failure. Recording it as a clean review
# would credit a crashed reviewer with finding nothing.
SH_FAIL_OUT="$( (cd "$SH_FIX" && env PATH="$SH_BIN:$PATH" SHADOW_STUB_FAIL=1 \
  COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" shadow --to grok "$(sh_req_for crash)") 2>&1 )" && SH_FRC=0 || SH_FRC=$?
[ "$SH_FRC" != "0" ] && ok "a crashed shadow turn exits non-zero" || fail "failed shadow exit code"
printf '%s\n' "$SH_FAIL_OUT" | grep -q 'OPERATIONAL FAILURE' \
  && ok "a crashed shadow turn is reported as operational failure, not zero findings" || fail "failure classification"
SH_LED_ROWS_BEFORE_FAIL="$(tail -n +2 "$SH_LED" | grep -c .)"
[ "$(tail -n +2 "$SH_LED" | grep -c .)" = "$SH_LED_ROWS_BEFORE_FAIL" ] \
  && ok "a failed turn adds no findings rows (never scored as a clean review)" || fail "failed turn polluted the ledger"
[ -z "$(find "$SH_FIX/.comms/to-claude" -type f 2>/dev/null)" ] \
  && ok "a failed shadow still delivers nothing" || fail "failed shadow leaked into an inbox"

# The live-discovered case: the CLI succeeds and produces a full review, but the
# reply breaks the verdict-line contract. Throwing that text away would discard
# the whole turn and the only evidence of which contract it broke.
cat > "$SH_BIN/grok" <<'SHSTUB2'
#!/bin/bash
case "$1" in --version) echo "grok 9.9.9-stub"; exit 0 ;; esac
esc() { printf '%s' "$1" | awk '{printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-shadow-2"}\n'
REPLY="$(printf -- 'HEAD matches. I reviewed it properly but forgot the verdict line.\n\n## Findings\n\n### Blocking\n- `subject.txt:1` — real content that must not be thrown away.')"
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
SHSTUB2
chmod +x "$SH_BIN/grok"
SH_NOVERD_OUT="$(run_sh shadow --to grok --review-set noverdict-set "$(sh_req_for noverdict)" 2>&1)" && SH_NRC=0 || SH_NRC=$?
# A reply that omits the VERDICT line but carries `### Blocking` findings now has its
# verdict DERIVED from the structure — loopspec's own equivalence — instead of the whole
# review being discarded over a formatting slip. (Observed three times live.)
[ "$SH_NRC" = "0" ] && ok "a reply with findings but no VERDICT line is derived, not discarded" || fail "no-verdict derivation (rc=$SH_NRC)"
SH_NOVERD_DIR="$(find "$SH_FIX/.comms/grades/shadow" -maxdepth 1 -type d -name 'noverdict-set-*' | head -1)"
[ -n "$SH_NOVERD_DIR" ] && [ -s "$SH_NOVERD_DIR/grok.md" ] \
  && ok "the derived reply is stored as a normal stamped review" || fail "derived reply not stored"
grep -q '^verdict: REQUEST_CHANGES' "$SH_NOVERD_DIR/grok.md" 2>/dev/null \
  && ok "a blocking finding derives REQUEST_CHANGES" || fail "derived verdict wrong"
grep -q 'must not be thrown away' "$SH_NOVERD_DIR/grok.md" 2>/dev/null \
  && ok "the reviewer's actual findings survive derivation" || fail "findings lost in derivation"
tail -n +2 "$SH_LED" | grep -q 'must not be thrown away' \
  && ok "a derived reply IS scored — it is a real review, not a failed turn" \
  || fail "derived reply was not scored"

# A contract-break writes no set row, so the pairing guard does not catch a retry. Without
# an EARLY store check the retry re-ran the reviewer for the full review and only then
# refused — paying for work it threw away. (grok, first passing shadow run.)
SH_RETRY_MARK="$WORK/retry-invoked"
rm -f "$SH_RETRY_MARK"
cat > "$SH_BIN/grok" <<'SHSTUB4'
#!/bin/bash
case "$1" in --version) echo "grok 9.9.9-stub"; exit 0 ;; esac
: > "${SHADOW_RETRY_MARK:-/dev/null}"
printf '{"type":"system","subtype":"init","session_id":"stub-retry"}\n'
printf '{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: APPROVE\\n\\n## Summary\\nretry\\n"}\n'
SHSTUB4
chmod +x "$SH_BIN/grok"
SH_RETRY_OUT="$( (cd "$SH_FIX" && env PATH="$SH_BIN:$PATH" \
  SHADOW_RETRY_MARK="$SH_RETRY_MARK" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
  "$COMMS" shadow --to grok --review-set noverdict-set "$(sh_req_for noverdict2)") 2>&1 )" && SH_RRC=0 || SH_RRC=$?
[ "$SH_RRC" != "0" ] && ok "retrying into a set that already holds a result is refused" || fail "retry accepted"
[ ! -e "$SH_RETRY_MARK" ] \
  && ok "the refusal happens BEFORE the reviewer runs (nothing was spent)" || fail "retry re-ran the reviewer before refusing"
printf '%s\n' "$SH_RETRY_OUT" | grep -q 'nothing was run' \
  && ok "the refusal says nothing was run" || fail "retry refusal message"

# loop-rounds must ride the broker stamp onto the REPLY: the approval reply is the
# only file the driver holds at the plan->implement handoff, so a budget that lives
# solely in the (archived) plan message silently falls back to the default.
# (codex, panel r1.)
cat > "$SH_BIN/grok" <<'SHSTUB5'
#!/bin/bash
case "$1" in --version) echo "grok 9.9.9-stub"; exit 0 ;; esac
printf '{"type":"system","subtype":"init","session_id":"stub-loopr"}\n'
printf '{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: APPROVE\\n\\n## Summary\\nplan direction is sound.\\n"}\n'
SHSTUB5
chmod +x "$SH_BIN/grok"
SH_REQ_LOOPR="$(sh_req_for loopr)"
perl -pi -e 's/^(max-rounds: .*)$/$1\nloop-rounds: 7/' "$SH_REQ_LOOPR"
run_sh shadow --to grok --review-set loopr-set "$SH_REQ_LOOPR" >/dev/null 2>&1 || true
SH_LOOPR_DIR="$(find "$SH_FIX/.comms/grades/shadow" -maxdepth 1 -type d -name 'loopr-set-*' | head -1)"
[ -n "$SH_LOOPR_DIR" ] && grep -q '^loop-rounds: 7' "$SH_LOOPR_DIR/grok.md" 2>/dev/null \
  && ok "the broker stamps loop-rounds onto the reply (budget survives the handoff)" \
  || fail "loop-rounds did not survive the broker stamp (got: $(grep -m1 loop-rounds "$SH_LOOPR_DIR/grok.md" 2>/dev/null))"

# review_set must ride the broker stamp the same way: a brokered reply without its
# panel identity is processed as a single-reviewer reply and the first arriving leg
# steers the loop — the round-1 lifecycle defect, back through the broker path.
# (codex + grok, panel r2.)
SH_REQ_RSET="$(sh_req_for rset)"
perl -pi -e 's/^(max-rounds: .*)$/$1\nreview_set: rs-broker-77/' "$SH_REQ_RSET"
run_sh shadow --to grok --review-set rset-set "$SH_REQ_RSET" >/dev/null 2>&1 || true
SH_RSET_DIR="$(find "$SH_FIX/.comms/grades/shadow" -maxdepth 1 -type d -name 'rset-set-*' | head -1)"
[ -n "$SH_RSET_DIR" ] && grep -q '^review_set: rs-broker-77' "$SH_RSET_DIR/grok.md" 2>/dev/null \
  && ok "the broker stamps review_set onto the reply (panel identity survives)" \
  || fail "review_set did not survive the broker stamp (got: $(grep -m1 review_set "$SH_RSET_DIR/grok.md" 2>/dev/null))"

# FINDINGS BEFORE A LATE VERDICT: a reviewer that writes its review first and the
# verdict line last must lose ONLY that line — cutting the body at the verdict
# discarded the entire review before composition (AC2). (codex, panel r3.)
cat > "$SH_BIN/grok" <<'SHSTUB6'
#!/bin/bash
case "$1" in --version) echo "grok 9.9.9-stub"; exit 0 ;; esac
esc() { printf '%s' "$1" | awk '{printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-lateverdict"}\n'
REPLY="$(printf -- '## Summary\nfindings first, verdict last.\n\n## Findings\n\n### Blocking\n- `s.txt:3` — the finding that must survive.\n\n### Advisory\n- None.\n\nVERDICT: REQUEST_CHANGES')"
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
SHSTUB6
chmod +x "$SH_BIN/grok"
run_sh shadow --to grok --review-set latev-set "$(sh_req_for latev)" >/dev/null 2>&1 || true
SH_LATEV_DIR="$(find "$SH_FIX/.comms/grades/shadow" -maxdepth 1 -type d -name 'latev-set-*' | head -1)"
grep -q '^verdict: REQUEST_CHANGES' "$SH_LATEV_DIR/grok.md" 2>/dev/null \
  && ok "a trailing VERDICT line is honoured" || fail "late verdict not honoured"
grep -q 'the finding that must survive' "$SH_LATEV_DIR/grok.md" 2>/dev/null \
  && ok "findings ABOVE a late verdict survive into the stamped reply" \
  || fail "late verdict discarded the findings above it (AC2)"
grep -q '^VERDICT: REQUEST_CHANGES$' "$SH_LATEV_DIR/grok.md" 2>/dev/null \
  && fail "the raw VERDICT line leaked into the stamped body" \
  || ok "only the verdict LINE is excised from the body"

section "grading pilot: round-1 review fixes (mounted artifact, safe ids, whole claims)"
GR2="$WORK/shadow-repo2"
mkdir -p "$GR2"; GR2="$(cd "$GR2" && pwd -P)"
git -C "$GR2" init -q -b main
printf '.comms/\n.agent-comms/\n' > "$GR2/.gitignore"
echo "ORIGINAL CONTENT" > "$GR2/subject.txt"
git -C "$GR2" add -A >/dev/null 2>&1
git -C "$GR2" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$GR2/.comms/to-codex" "$GR2/.comms/to-claude"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$GR2/.comms/config"
run_g2() { (cd "$GR2" && env PATH="$SH_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }

# a request whose cwd: points somewhere ELSE entirely
G2_REQ="$GR2/.comms/to-codex/shadow-repo2_2026-08-22T10-00-00_req-1.md"
cat > "$G2_REQ" <<G2EOF
---
type: review-request
from: claude
timestamp: 2026-08-22T10:00:00Z
head_sha: $(git -C "$GR2" rev-parse HEAD)
workspace: shadow-repo2
cwd: /nonexistent/elsewhere
message_id: shadow-repo2_2026-08-22T10-00-00_req-1
thread: g2/thread/with/slashes
workflow: auto-implement
phase: implement
round: 1
max-rounds: 4
---

## What was done
Edited subject.txt.
G2EOF

# B1 — the reviewer must READ the retained artifact, not the live tree.
cat > "$SH_BIN/grok" <<'G2STUB'
#!/bin/bash
case "$1" in --version) echo "grok 9.9.9-stub"; exit 0 ;; esac
[ -n "${SHADOW_CWD_COPY:-}" ] && pwd > "$SHADOW_CWD_COPY"
[ -n "${SHADOW_SUBJECT_COPY:-}" ] && cat subject.txt > "$SHADOW_SUBJECT_COPY" 2>/dev/null
pf=""; prev=""
for a in "$@"; do [ "$prev" = "--prompt-file" ] && pf="$a"; prev="$a"; done
cp "$pf" "${SHADOW_PROMPT_COPY:-/dev/null}" 2>/dev/null || true
esc() { printf '%s' "$1" | awk '{printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-g2"}\n'
LONG="$(awk 'BEGIN{for(i=0;i<130;i++) printf "verylongclaimsegment "}')"
REPLY="$(printf -- 'VERDICT: REQUEST_CHANGES\n\n## Summary\ns\n\n## Findings\n\n### Blocking\n- `subject.txt:1` — %s\n' "$LONG")"
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
G2STUB
chmod +x "$SH_BIN/grok"
cat > "$SH_BIN/grok" <<'G2STUB2'
#!/bin/bash
case "$1" in --version) echo "grok ${GROK_STUB_VERSION:-9.9.9-stub}"; exit 0 ;; esac
[ -n "${SHADOW_CWD_COPY:-}" ] && pwd > "$SHADOW_CWD_COPY"
[ -n "${SHADOW_SUBJECT_COPY:-}" ] && cat subject.txt > "$SHADOW_SUBJECT_COPY" 2>/dev/null
# What the reviewer can actually SEE: its HEAD, its diff, its untracked files.
[ -n "${SHADOW_SHAPE_COPY:-}" ] && {
  { echo "HEAD=$(git rev-parse HEAD 2>/dev/null)"
    echo "DIFFLINES=$(git diff --name-only 2>/dev/null | grep -c .)"
    echo "UNTRACKED=$(git status --porcelain 2>/dev/null | grep -c '^??')"
  } > "$SHADOW_SHAPE_COPY"
}
pf=""; prev=""
for a in "$@"; do [ "$prev" = "--prompt-file" ] && pf="$a"; prev="$a"; done
cp "$pf" "${SHADOW_PROMPT_COPY:-/dev/null}" 2>/dev/null || true
esc() { printf '%s' "$1" | awk '{printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-g2"}\n'
LONG="$(awk 'BEGIN{for(i=0;i<130;i++) printf "verylongclaimsegment "}')"
REPLY="$(printf -- 'VERDICT: REQUEST_CHANGES\n\n## Summary\ns\n\n## Findings\n\n### Blocking\n- `subject.txt:1` — %s\n' "$LONG")"
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
G2STUB2
chmod +x "$SH_BIN/grok"

G2_CWD="$WORK/g2-cwd.txt"; G2_SUBJ="$WORK/g2-subject.txt"
# baseline run: the mount's CONTENT. (The comment here once claimed a live edit between
# snapshot and read but performed none — codex caught the dead claim in round 2. The real
# edit-then-mount case is the shape test below, which mutates before its run.)
G2_OUT="$( (cd "$GR2" && env PATH="$SH_BIN:$PATH" \
  SHADOW_CWD_COPY="$G2_CWD" SHADOW_SUBJECT_COPY="$G2_SUBJ" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
  "$COMMS" shadow --to grok "$G2_REQ") 2>&1 )" && G2_RC=0 || G2_RC=$?
[ "$G2_RC" = "0" ] && ok "shadow completes against a mounted artifact" || fail "mounted shadow run: $G2_OUT"
[ -s "$G2_CWD" ] && [ "$(cat "$G2_CWD")" != "$GR2" ] \
  && ok "the reviewer ran in an ISOLATED checkout, not the live worktree" || fail "reviewer ran in the live tree ($(cat "$G2_CWD" 2>/dev/null))"
grep -q 'ORIGINAL CONTENT' "$G2_SUBJ" 2>/dev/null \
  && ok "the reviewer read the RETAINED artifact's content" || fail "reviewer did not read the artifact"
# The mount must be SHAPED like the worktree the gating reviewer reads. Checking the
# synthetic artifact commit out directly put HEAD on that commit and left `git diff`
# EMPTY — the reviewer would fail its own head check and see no patch. (codex, round 2.)
G2_BASE="$(git -C "$GR2" rev-parse HEAD)"
G2_SHAPE="$WORK/g2-shape.txt"
G2_REQ2="$GR2/.comms/to-codex/shadow-repo2_req-shape.md"
sed -e 's|^thread: .*|thread: g2-shape|' -e 's|^message_id: .*|message_id: shadow-repo2_req-shape|' "$G2_REQ" > "$G2_REQ2"
echo "EDITED AFTER THE FIRST RUN" > "$GR2/subject.txt"
echo "brand new file" > "$GR2/added.txt"
(cd "$GR2" && env PATH="$SH_BIN:$PATH" SHADOW_SHAPE_COPY="$G2_SHAPE" \
  SHADOW_SUBJECT_COPY="$WORK/g2-subject2.txt" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
  "$COMMS" shadow --to grok "$G2_REQ2") >/dev/null 2>&1 || true
if [ -s "$G2_SHAPE" ]; then
  grep -qx "HEAD=$G2_BASE" "$G2_SHAPE" \
    && ok "the mounted reviewer's HEAD is the request's base, not a synthetic commit" \
    || fail "mounted HEAD wrong ($(grep '^HEAD=' "$G2_SHAPE"))"
  [ "$(sed -n 's/^DIFFLINES=//p' "$G2_SHAPE")" -gt 0 ] \
    && ok "the mounted reviewer sees the reviewed change as an ordinary git diff" \
    || fail "mounted git diff is empty — the reviewer would see no patch"
  [ "$(sed -n 's/^UNTRACKED=//p' "$G2_SHAPE")" -gt 0 ] \
    && ok "files that were untracked are untracked in the mount too" || fail "untracked files lost in the mount"
else
  fail "mount shape was not captured"
fi
grep -q 'EDITED AFTER THE FIRST RUN' "$WORK/g2-subject2.txt" 2>/dev/null \
  && ok "the mount carries the live edit made before this run's snapshot" || fail "mount content"

# A request with NO cwd: must still be pointed at the mount — otherwise runphase falls
# back to the live main root and the artifact is silently un-mounted. (codex, round 2.)
G2_NOCWD="$GR2/.comms/to-codex/shadow-repo2_req-nocwd.md"
grep -v '^cwd:' "$G2_REQ" | sed -e 's|^thread: .*|thread: g2-nocwd|' -e 's|^message_id: .*|message_id: shadow-repo2_req-nocwd|' > "$G2_NOCWD"
grep -q '^cwd:' "$G2_NOCWD" && fail "fixture still has cwd" || ok "fixture: a valid request with no cwd: field"
G2_NOCWD_CWD="$WORK/g2-nocwd-cwd.txt"
(cd "$GR2" && env PATH="$SH_BIN:$PATH" SHADOW_CWD_COPY="$G2_NOCWD_CWD" \
  COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" shadow --to grok "$G2_NOCWD") >/dev/null 2>&1 || true
[ -s "$G2_NOCWD_CWD" ] && [ "$(cat "$G2_NOCWD_CWD")" != "$GR2" ] \
  && ok "a request with no cwd: is still run inside the mount" || fail "no-cwd request escaped to the live tree"

# The mount path must not announce the measurement role the design hides.
case "$(cat "$G2_NOCWD_CWD" 2>/dev/null)" in
  *shadow*|*grade*) fail "the mount path leaks the measurement role" ;;
  *) ok "the mount path is opaque about the measurement role" ;;
esac

# B2 — review_set_id is a path component; a slash-bearing thread is legal protocol.
G2_STORE="$(find "$GR2/.comms/grades/shadow" -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -n "$G2_STORE" ] && ok "a slash-bearing thread still produces exactly one store dir" || fail "slash thread store"
case "$G2_STORE" in *"$GR2/.comms/grades/shadow/"*) ok "the store stayed inside the grade namespace" ;; *) fail "store escaped: $G2_STORE" ;; esac
[ "$(find "$GR2/.comms/grades/shadow" -mindepth 2 -type d | wc -l | tr -d ' ')" = "0" ] \
  && ok "no set id created a nested directory" || fail "a set id created nested dirs"
check_not "shadow refuses a traversal review-set id" run_g2 shadow --to grok --review-set "../../escape" "$G2_REQ"
[ ! -e "$WORK/escape" ] && [ ! -e "$GR2/../escape" ] && ok "no file was written outside the grade store" || fail "traversal wrote outside"

# B3 — a long claim is EVIDENCE; truncating it is permanent under finding_id idempotence.
G2_LED="$GR2/.comms/grades/findings.tsv"
G2_LONGEST="$(tail -n +2 "$G2_LED" | awk -F'\t' '{if(length($15)>m)m=length($15)}END{print m+0}')"
[ "$G2_LONGEST" -gt 600 ] && ok "a >600-char finding is stored WHOLE (was clipped in v1)" || fail "claim still truncated (longest=$G2_LONGEST)"
tail -n +2 "$G2_LED" | awk -F'\t' '$15 ~ /\.\.\.$/' | grep -q . && fail "claims still carry an injected ellipsis" || ok "no injected truncation marker survives"
[ "$(awk -F'\t' 'NR==2{print $1}' "$G2_LED")" = "2" ] && ok "rows carry schema_version 2" || fail "schema version"
sed -i.bak '2s/^2\t/1\t/' "$G2_LED" && rm -f "$G2_LED.bak"
check_not "appending to a mixed-generation ledger is refused" run_g2 findings --out "$G2_LED"
run_g2 findings --out "$G2_LED" --rebuild >/dev/null 2>&1
[ "$(awk -F'\t' 'NR==2{print $1}' "$G2_LED")" = "2" ] && ok "--rebuild regenerates the ledger at the current schema" || fail "rebuild schema"
tail -n +2 "$G2_LED" | awk -F'\t' '$12=="shadow"' | grep -q . \
  && ok "--rebuild recovers shadow rows from the grade store, not just the archive" || fail "rebuild lost shadow rows"

# B4 — the join must be one-to-one, and must record who it is pairing against.
G2_IDX="$GR2/.comms/grades/sets.tsv"
awk -F'\t' 'NR>1 && $9=="codex"' "$G2_IDX" | grep -q . \
  && ok "the set records the GATING agent (derived from the dispatch inbox)" || fail "gating_agent not recorded"
awk -F'\t' 'NR>1 && $2=="shadow-repo2_2026-08-22T10-00-00_req-1"' "$G2_IDX" | grep -q . \
  && ok "the set records the originating request message_id" || fail "request_message_id not recorded"
awk -F'\t' 'NR>1 && $8!=""' "$G2_IDX" | grep -q . && ok "the set records base_sha" || fail "base_sha not recorded"
tail -n +2 "$G2_LED" | awk -F'\t' '$12=="shadow" && $5!=""' | grep -q . \
  && ok "shadow rows carry base_sha (the brokered envelope has none of its own)" || fail "shadow base_sha empty"
echo "DRIFTED" > "$GR2/subject.txt"
G2_DUP="$(run_g2 shadow --to grok --review-set second-set "$G2_REQ" 2>&1)" && G2_DRC=0 || G2_DRC=$?
[ "$G2_DRC" != "0" ] && ok "a SECOND pairing for one thread+phase+round is refused" || fail "duplicate pairing accepted"
printf '%s\n' "$G2_DUP" | grep -q 'already paired' && ok "the refusal names the existing set" || fail "duplicate refusal message"

# B5 — the runphase entry point must not offer a guarantee it cannot keep.
# safe_name NORMALIZES; normalization is not identity. `a/b` and `a_b` must not share a
# directory, or the second run overwrites the first's stored reply. (codex, round 2.)
G2_ID1="$(run_g2 shadow --to grok --review-set 'a/b' "$GR2/.comms/to-codex/shadow-repo2_req-idA.md" 2>&1 || true)"
sed -e 's|^thread: .*|thread: g2-idA|' -e 's|^message_id: .*|message_id: shadow-repo2_req-idA|' "$G2_REQ" > "$GR2/.comms/to-codex/shadow-repo2_req-idA.md"
sed -e 's|^thread: .*|thread: g2-idB|' -e 's|^message_id: .*|message_id: shadow-repo2_req-idB|' "$G2_REQ" > "$GR2/.comms/to-codex/shadow-repo2_req-idB.md"
run_g2 shadow --to grok --review-set 'a/b' "$GR2/.comms/to-codex/shadow-repo2_req-idA.md" >/dev/null 2>&1 || true
run_g2 shadow --to grok --review-set 'a_b' "$GR2/.comms/to-codex/shadow-repo2_req-idB.md" >/dev/null 2>&1 || true
[ "$(find "$GR2/.comms/grades/shadow" -mindepth 1 -maxdepth 1 -type d -name 'a_b*' | wc -l | tr -d ' ')" = "2" ] \
  && ok "two distinct set ids that normalize alike get distinct stores" || fail "set id collision"

# One pairing per thread+phase+round, UNCONDITIONALLY — including a re-run with the same id.
G2_SAME="$(run_g2 shadow --to grok --review-set 'a/b' "$GR2/.comms/to-codex/shadow-repo2_req-idA.md" 2>&1)" && G2_SRC=0 || G2_SRC=$?
[ "$G2_SRC" != "0" ] && ok "re-running the SAME thread+phase+round with the same id is refused" || fail "same-id re-run overwrote a pairing"

# Rebuild must not invent runtime identity: the version RECORDED at run time wins over
# whatever the CLI reports today. (codex, round 2.)
G2_LED2="$GR2/.comms/grades/findings.tsv"
G2_RECORDED="$(cat "$(find "$GR2/.comms/grades/shadow" -name 'grok.version' | head -1)" 2>/dev/null)"
[ -n "$G2_RECORDED" ] && ok "the reviewer CLI version is persisted at run time" || fail "reviewer version not persisted"
GROK_STUB_VERSION="99.99.99-upgraded" run_g2 findings --out "$G2_LED2" --rebuild >/dev/null 2>&1
tail -n +2 "$G2_LED2" | awk -F'\t' '$12=="shadow" && $10 ~ /99\.99\.99/' | grep -q . \
  && fail "rebuild stamped historical rows with today's CLI version" \
  || ok "rebuild preserves the recorded version instead of probing the CLI"

# A rebuild that cannot complete must leave the original ledger intact.
G2_BEFORE="$(wc -l < "$G2_LED2")"
chmod 500 "$(dirname "$G2_LED2")" 2>/dev/null || true
run_g2 findings --out "$G2_LED2" --rebuild >/dev/null 2>&1 || true
chmod 700 "$(dirname "$G2_LED2")" 2>/dev/null || true
[ "$(wc -l < "$G2_LED2")" = "$G2_BEFORE" ] \
  && ok "a failed rebuild leaves the original ledger untouched" || fail "failed rebuild destroyed the ledger"

# Drift is a TRI-STATE: empty must never read as confirmed-identical.
awk -F'\t' 'NR>1 && ($11=="same_endpoint" || $11=="changed" || $11=="unknown")' "$GR2/.comms/grades/sets.tsv" | grep -q . \
  && ok "the set records an explicit drift_status, not an empty field" || fail "drift_status missing"

# `/auto-full` keeps ONE thread across plan->implement and restarts at round 1, so
# thread+round is not a pair identity — plan r1 and implement r1 are different artifacts.
# (codex, round 3.)
G2_PLAN="$GR2/.comms/to-codex/shadow-repo2_req-plan-r1.md"
G2_IMPL="$GR2/.comms/to-codex/shadow-repo2_req-impl-r1.md"
sed -e 's|^thread: .*|thread: g2-phases|' -e 's|^phase: .*|phase: plan|' -e 's|^message_id: .*|message_id: shadow-repo2_req-plan-r1|' "$G2_REQ" > "$G2_PLAN"
sed -e 's|^thread: .*|thread: g2-phases|' -e 's|^phase: .*|phase: implement|' -e 's|^message_id: .*|message_id: shadow-repo2_req-impl-r1|' "$G2_REQ" > "$G2_IMPL"
run_g2 shadow --to grok "$G2_PLAN" >/dev/null 2>&1 || true
echo "implement-phase content" > "$GR2/subject.txt"
G2_PH2="$(run_g2 shadow --to grok "$G2_IMPL" 2>&1)" && G2_PHRC=0 || G2_PHRC=$?
[ "$G2_PHRC" = "0" ] && ok "implement round 1 pairs even though plan round 1 used the same thread+round" \
  || fail "phase collision blocked a legitimate pair: $G2_PH2"
G2_IDXF="$GR2/.comms/grades/sets.tsv"
[ "$(awk -F'\t' 'NR>1 && $3=="g2-phases"' "$G2_IDXF" | wc -l | tr -d ' ')" = "2" ] \
  && ok "both phases hold their own set row" || fail "phase rows"
G2_PLAN_ART="$(awk -F'\t' 'NR>1 && $3=="g2-phases" && $5=="plan" {print $6}' "$G2_IDXF")"
G2_IMPL_ART="$(awk -F'\t' 'NR>1 && $3=="g2-phases" && $5=="implement" {print $6}' "$G2_IDXF")"
[ -n "$G2_PLAN_ART" ] && [ "$G2_PLAN_ART" != "$G2_IMPL_ART" ] \
  && ok "the two phases retained DIFFERENT artifacts" || fail "phase artifacts collapsed"
# and a gating reply in each phase must join to its own artifact
mkdir -p "$GR2/.comms/archive"
for ph in plan implement; do
  cat > "$GR2/.comms/archive/fb-$ph.md" <<PHEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-22T11:00:00Z
workspace: shadow-repo2
message_id: shadow-repo2_fb-$ph
thread: g2-phases
phase: $ph
round: 1
verdict: REQUEST_CHANGES
---

## Findings

### Blocking
- \`subject.txt:1\` — gating finding in the $ph phase.
PHEOF
done
G2_JOIN="$WORK/g2-join.tsv"
run_g2 findings --out "$G2_JOIN" "$GR2/.comms/archive/fb-plan.md" "$GR2/.comms/archive/fb-implement.md" >/dev/null 2>&1
G2_JP="$(tail -n +2 "$G2_JOIN" | awk -F'\t' '$7=="plan" {print $4; exit}')"
G2_JI="$(tail -n +2 "$G2_JOIN" | awk -F'\t' '$7=="implement" {print $4; exit}')"
[ "$G2_JP" = "$G2_PLAN_ART" ] && [ "$G2_JI" = "$G2_IMPL_ART" ] && [ "$G2_JP" != "$G2_JI" ] \
  && ok "each phase's gating findings join to that phase's artifact" || fail "phase join wrong (plan=$G2_JP impl=$G2_JI)"

# The version stamped on the live row must be the one captured BEFORE the run — a CLI that
# changes mid-review would otherwise disagree with its own sidecar. (codex, round 3.)
cat > "$SH_BIN/grok" <<'G2STUB3'
#!/bin/bash
VMARK="${GROK_STUB_VERSION_MARK:-/dev/null}"
case "$1" in
  --version)
    if [ -f "$VMARK" ]; then echo "grok 2.0.0-upgraded-midrun"; else echo "grok 1.0.0-atdispatch"; fi
    exit 0 ;;
esac
# the "upgrade" happens while the review is running
[ "${GROK_STUB_VERSION_MARK:-}" != "" ] && : > "$GROK_STUB_VERSION_MARK"
esc() { printf '%s' "$1" | awk '{printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-ver"}\n'
REPLY="$(printf -- 'VERDICT: REQUEST_CHANGES\n\n## Summary\ns\n\n## Findings\n\n### Blocking\n- `subject.txt:1` — version provenance case.\n')"
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
G2STUB3
chmod +x "$SH_BIN/grok"
G2_VREQ="$GR2/.comms/to-codex/shadow-repo2_req-ver.md"
sed -e 's|^thread: .*|thread: g2-ver|' -e 's|^message_id: .*|message_id: shadow-repo2_req-ver|' "$G2_REQ" > "$G2_VREQ"
G2_VLED="$WORK/g2-ver.tsv"
(cd "$GR2" && env PATH="$SH_BIN:$PATH" GROK_STUB_VERSION_MARK="$WORK/vmark" \
  COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" shadow --to grok --out "$G2_VLED" "$G2_VREQ") >/dev/null 2>&1 || true
G2_LIVE_V="$(tail -n +2 "$G2_VLED" 2>/dev/null | awk -F'\t' '$12=="shadow" {print $10; exit}')"
G2_SIDE_V="$(cat "$(find "$GR2/.comms/grades/shadow" -path '*g2-ver*' -name 'grok.version' | head -1)" 2>/dev/null)"
[ -n "$G2_LIVE_V" ] && [ "$G2_LIVE_V" = "$G2_SIDE_V" ] \
  && ok "the live row uses the version captured at dispatch, matching its own sidecar" \
  || fail "live row version ($G2_LIVE_V) disagrees with the sidecar ($G2_SIDE_V)"
case "$G2_LIVE_V" in *upgraded-midrun*) fail "the live row picked up a mid-review CLI upgrade" ;; *) ok "a mid-review CLI upgrade does not reach the row" ;; esac

G2_RP="$( (cd "$GR2" && env "$REPO/helpers/runphase.sh" run --message "$G2_REQ" --dir "$WORK/g2rp" --provider codex --no-deliver) 2>&1 )" && G2_RPRC=0 || G2_RPRC=$?
[ "$G2_RPRC" != "0" ] && ok "runphase refuses --no-deliver for an ACP-only provider" || fail "runphase --no-deliver accepted for codex"
# Pin text UNIQUE to the --no-deliver refusal: a bare 'ACP-only' also matches the guard
# below it, so this assertion would still pass if the wrong die fired first.
printf '%s\n' "$G2_RP" | grep -q 'no non-ACP turn to suppress' \
  && ok "the runphase refusal explains why" || fail "runphase refusal message"

# SPAWN must refuse on the SAME condition as run. It execs `run` detached via nohup, so before
# this guard the operator got `spawned runphase pid=NNN` and exit 0 while the child died on the
# ACP-only check a second later — a false success at the spawn layer, which is exactly what S4-2
# exists to remove. One predicate (`require_acp_transport`), two callers. (grok, S4-2 r1.)
G2_SP="$( (cd "$GR2" && env COMMS_RUNPHASE_VIA= "$REPO/helpers/runphase.sh" spawn --message "$G2_REQ" --provider codex) 2>&1 )" && G2_SPRC=0 || G2_SPRC=$?
[ "$G2_SPRC" != "0" ] && ok "spawn refuses an ACP-only provider without --via acp" || fail "spawn accepted a non-ACP codex turn"
printf '%s\n' "$G2_SP" | grep -q '^spawned runphase' && fail "spawn reported success for a turn that cannot run" || ok "a refused spawn prints no pid line"
# Non-zero + no pid line is satisfied by ANY earlier die, so pin the refusal to text unique to
# require_acp_transport — the same hole the --no-deliver pin already closed. (grok, r3.)
printf '%s\n' "$G2_SP" | grep -q 'unstamped, unmounted reply that still reported success' \
  && ok "the spawn refusal is require_acp_transport's, not an earlier die" || fail "spawn refusal text (got: $G2_SP)"
