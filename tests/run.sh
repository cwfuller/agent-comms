#!/bin/bash
# agent-comms test harness — repeatable checks for the shared helpers and installer.
# Stubs cmux with a fake binary (canned tree output + call log) so picker/delivery
# logic is testable headlessly. Run: bash tests/run.sh   (zsh callers covered too)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMS="$REPO/helpers/comms.sh"
FLEET="$REPO/helpers/fleet.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
check() { # check <desc> <expr...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
check_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc (expected failure)"; else ok "$desc"; fi
}

# ---------- fixtures ----------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake repo with a deterministic branch name.
# Canonicalize (pwd -P) so comparisons survive macOS /var -> /private/var.
REPO_FIX="$WORK/fixture-repo"
mkdir -p "$REPO_FIX"
REPO_FIX="$(cd "$REPO_FIX" && pwd -P)"
git -C "$REPO_FIX" init -q -b feature/helper-tests
git -C "$REPO_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$REPO_FIX/.comms/to-claude" "$REPO_FIX/.comms/to-codex" "$REPO_FIX/.comms/archive"

# cmux stub: serves canned output, logs every invocation
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
export CMUX_STUB_LOG="$WORK/cmux.log"
export CMUX_STUB_DIR="$WORK/cmux-data"
mkdir -p "$CMUX_STUB_DIR"
cat > "$STUB_BIN/cmux" <<'STUB'
#!/bin/bash
echo "$*" >> "$CMUX_STUB_LOG"
cmd="$1"; shift
ref=""
while [ "$#" -gt 0 ]; do
  case "$1" in --workspace) shift; ref="$1" ;; esac
  shift
done
case "$cmd" in
  tree)
    [ -n "${CMUX_STUB_TREE_EMPTY:-}" ] && exit 0
    cat "$CMUX_STUB_DIR/tree-${ref//:/_}.txt" 2>/dev/null ;;
  list-workspaces) cat "$CMUX_STUB_DIR/list.txt" 2>/dev/null ;;
  send)
    [ -n "${CMUX_STUB_SANDBOX:-}" ] && { echo "Operation not permitted (cmux.sock)" >&2; exit 1; }
    [ -n "${CMUX_STUB_FAIL:-}" ] && exit 1
    exit 0 ;;
  send-key) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/cmux"

# Canned control-workspace tree: here-pane (1) + codex pane (2)
cat > "$CMUX_STUB_DIR/tree-workspace_10.txt" <<'TREE'
workspace workspace:10 "Test Project"
├── pane pane:1
│   └── surface surface:11 [terminal] "⠋ thinking" ◀ here
└── pane pane:2
    └── surface surface:22 [terminal] "Codex"
TREE

# HERMETIC: scrub the live session's CMUX_WORKSPACE_ID — without this, tests
# inherit a real cmux workspace and "deliver" sends keystrokes to REAL panes.
run_comms() { (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }

echo "== comms.sh: root/workspace =="
[ "$(run_comms root)" = "$REPO_FIX/.comms" ] && ok "root resolves main repo .comms" || fail "root resolves main repo .comms"
[ "$(run_comms workspace)" = "feature-helper-tests" ] && ok "workspace falls back to branch (no cmux)" || fail "workspace falls back to branch (got $(run_comms workspace))"
WS_CMUX="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" workspace)"
[ "$WS_CMUX" = "test-project" ] && ok "workspace prefers cmux title (lowercased, hyphenated)" || fail "workspace prefers cmux title (got $WS_CMUX)"
if command -v zsh >/dev/null 2>&1; then
  WS_ZSH="$(cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID zsh -c "\"$COMMS\" workspace")"
  [ "$WS_ZSH" = "feature-helper-tests" ] && ok "helper is caller-shell agnostic (zsh)" || fail "helper under zsh (got $WS_ZSH)"
fi

echo "== comms.sh: validate =="
GOOD="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T12-00-00_test-1.md"
cat > "$GOOD" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-06-04T12:00:00Z
workspace: feature-helper-tests
workflow: auto-implement
phase: implement
round: 1
max-rounds: 10
---

## What was done
Things.
MSG
check "valid claude workflow message (no verdict needed)" run_comms validate "$GOOD"

BAD_NOVERDICT="$WORK/codex-noverdict.md"
sed 's/from: claude/from: codex/' "$GOOD" > "$BAD_NOVERDICT"
check_not "codex workflow reply without verdict is rejected" run_comms validate "$BAD_NOVERDICT"

BAD_NOTYPE="$WORK/notype.md"
grep -v '^type:' "$GOOD" > "$BAD_NOTYPE"
check_not "missing type is rejected" run_comms validate "$BAD_NOTYPE"

BAD_EMPTY="$WORK/empty-body.md"
awk '/^## /{exit} {print}' "$GOOD" > "$BAD_EMPTY"
check_not "empty body is rejected" run_comms validate "$BAD_EMPTY"

echo "== comms.sh: archive (idempotent, own inbox only) =="
IN1="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T12-01-00_reply-1.md"
sed 's/from: claude/from: codex/; s/^---$/---/; ' "$GOOD" > "$IN1"
echo "verdict: APPROVE" >> /dev/null # (verdict not needed for archive test)
check "archive own inbox file" run_comms archive --as claude "$IN1"
[ -f "$REPO_FIX/.comms/archive/$(basename "$IN1")" ] && ok "file landed in archive/" || fail "file landed in archive/"
check "re-archive is a no-op (idempotent)" run_comms archive --as claude "$IN1"
check_not "archiving a file from the OTHER inbox is refused" run_comms archive --as claude "$GOOD"

echo "== comms.sh: list =="
check_not "list exits non-zero on empty inbox" run_comms list --as claude
LIST_ERR="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" list --as claude) 2>&1 1>/dev/null || true)"
echo "$LIST_ERR" | grep -q "latest archived" && ok "empty inbox reports latest archived (late-nudge UX)" || fail "empty inbox reports latest archived (got: $LIST_ERR)"

echo "== comms.sh: deliver via stubbed cmux =="
: > "$CMUX_STUB_LOG"
OUT="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" deliver codex)"
echo "$OUT" | grep -q "delivered to surface:22" && ok "picker chose other-pane surface (not ◀ here)" || fail "picker chose other-pane surface (got: $OUT)"
grep -q 'send --surface surface:22 --workspace workspace:10 $read-from-claude' "$CMUX_STUB_LOG" && ok "codex nudge types \$read-from-claude" || fail "codex nudge types \$read-from-claude"
: > "$CMUX_STUB_LOG"
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" deliver claude) >/dev/null
grep -q 'send --surface surface:22 --workspace workspace:10 i' "$CMUX_STUB_LOG" && ok "claude nudge includes vim-mode insert" || fail "claude nudge includes vim-mode insert"
grep -q 'send --surface surface:22 --workspace workspace:10 /read-from-codex' "$CMUX_STUB_LOG" && ok "claude nudge types /read-from-codex" || fail "claude nudge types /read-from-codex"
OUT="$(cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" deliver codex)"
echo "$OUT" | grep -q "manual pickup" && ok "deliver without cmux degrades to manual pickup" || fail "deliver without cmux degrades to manual pickup"

echo "== comms.sh: send (atomicity guard) =="
IN2="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T12-02-00_reply-2.md"
cp "$REPO_FIX/.comms/archive/$(basename "$IN1")" "$IN2"
BADOUT="$WORK/malformed-out.md"
echo "not a message" > "$BADOUT"
check_not "send refuses malformed outbound" run_comms send --to codex "$BADOUT" --archive-inbound "$IN2"
[ -f "$IN2" ] && ok "inbound NOT archived when outbound malformed" || fail "inbound NOT archived when outbound malformed"
check "send valid outbound (manual pickup) archives inbound" run_comms send --to codex "$GOOD" --archive-inbound "$IN2"
[ ! -f "$IN2" ] && ok "inbound archived after successful send" || fail "inbound archived after successful send"

echo "== fleet.sh: list/status/dispatch with stubbed cmux =="
cat > "$CMUX_STUB_DIR/list.txt" <<'LIST'
* workspace:88  ws-ctrl  [selected]
  workspace:81  ws-10
  workspace:79  ws-1
  workspace:80  ws-2
LIST
cat > "$CMUX_STUB_DIR/tree-workspace_79.txt" <<'TREE'
workspace workspace:79 "ws-1"
├── pane pane:1
│   └── surface surface:31 [terminal] "⠙ implementing feature"
└── pane pane:2
    └── surface surface:32 [terminal] "Codex"
TREE
cat > "$CMUX_STUB_DIR/tree-workspace_80.txt" <<'TREE'
workspace workspace:80 "ws-2"
├── pane pane:1
│   └── surface surface:41 [terminal] "Claude Code"
└── pane pane:2
    └── surface surface:42 [terminal] "Codex"
TREE
cp "$CMUX_STUB_DIR/tree-workspace_80.txt" "$CMUX_STUB_DIR/tree-workspace_81.txt"

run_fleet() { (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$FLEET" "$@"); }

STATUS_OUT="$(run_fleet status)"
echo "$STATUS_OUT" | head -1 | grep -q '^ws-1 ' && ok "status natural sort: ws-1 first" || fail "status natural sort: ws-1 first"
echo "$STATUS_OUT" | sed -n '2p' | grep -q '^ws-2 ' && ok "status natural sort: ws-2 before ws-10" || fail "status natural sort: ws-2 before ws-10 (got: $(echo "$STATUS_OUT" | sed -n 2p))"
echo "$STATUS_OUT" | grep '^ws-1 ' | grep -q 'claude=active' && ok "braille title classified active" || fail "braille title classified active"
echo "$STATUS_OUT" | grep '^ws-2 ' | grep -q 'claude=idle' && ok "bare title classified idle" || fail "bare title classified idle"

mkdir -p "$REPO_FIX/docs"
TRICKY="docs/foo--plan-first-draft.md"
echo "brief" > "$REPO_FIX/$TRICKY"
check_not "dispatch onto busy workspace is rejected" run_fleet dispatch ws-1 "$TRICKY"
: > "$CMUX_STUB_LOG"
DISPATCH_OUT="$(run_fleet dispatch ws-2 "$TRICKY" 2>&1)"
echo "$DISPATCH_OUT" | grep -q 'mode=/auto-implement' && ok "tricky brief name does not flip mode" || fail "tricky brief name does not flip mode (got: $DISPATCH_OUT)"
grep -q "/auto-implement $TRICKY" "$CMUX_STUB_LOG" && ok "brief path delivered unmutated" || fail "brief path delivered unmutated"
: > "$CMUX_STUB_LOG"
run_fleet dispatch ws-2 "$TRICKY" --plan-first >/dev/null 2>&1
grep -q "/auto-full $TRICKY" "$CMUX_STUB_LOG" && ok "--plan-first flips mode to auto-full" || fail "--plan-first flips mode to auto-full"

# dispatch-all dry-run: ws-2/ws-10 idle, no archive -> free; mapping printed, nothing fired
: > "$CMUX_STUB_LOG"
DA_OUT="$(run_fleet dispatch-all "$TRICKY" 2>&1)"
echo "$DA_OUT" | grep -q -- "-> ws-2" && ok "dispatch-all maps brief to first free ws" || fail "dispatch-all maps brief to first free ws (got: $DA_OUT)"
grep -q 'send' "$CMUX_STUB_LOG" && fail "dispatch-all dry-run must not fire" || ok "dispatch-all dry-run does not fire"

echo "== install.sh: scopes =="
INST_FIX="$WORK/install-repo"
mkdir -p "$INST_FIX"
git -C "$INST_FIX" init -q -b main
(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=project >/dev/null 2>&1)
[ -d "$INST_FIX/.comms/to-codex" ] && ok "project scope creates .comms" || fail "project scope creates .comms"
grep -qxF '.comms/' "$INST_FIX/.gitignore" && ok "project scope gitignores .comms/" || fail "project scope gitignores .comms/"
SUM1="$(cat "$INST_FIX/.gitignore")"
(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=project >/dev/null 2>&1)
[ "$SUM1" = "$(cat "$INST_FIX/.gitignore")" ] && ok "project scope is idempotent" || fail "project scope is idempotent"
LOCAL_OUT="$(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=local 2>&1)"
[ -x "$INST_FIX/.agent-comms/comms.sh" ] && ok "local scope installs executable helpers" || fail "local scope installs executable helpers"
[ -f "$INST_FIX/.claude/commands/auto-implement.md" ] && ok "local scope installs commands" || fail "local scope installs commands"
[ -f "$INST_FIX/.claude/commands/read-from-mgr.md" ] && ok "local scope installs read-from-mgr (CLAUDE_COMMANDS not drifted)" || fail "read-from-mgr.md not installed"
echo "$LOCAL_OUT" | grep -qi "shadow" && ok "local scope prints pin/shadow note" || fail "local scope prints pin/shadow note"

echo "== fleet.sh: harvest + frontmatter boundary =="
# Archive whose frontmatter has NO verdict but whose BODY quotes one — must NOT count as approved.
QUOTED="$REPO_FIX/.comms/archive/ws-2_2026-06-04T11-00-00_auto-implement.md"
cat > "$QUOTED" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-06-04T11:00:00Z
workspace: ws-2
workflow: auto-implement
phase: implement
round: 1
max-rounds: 10
---

## Body quoting a verdict line
verdict: APPROVE
MSG
HV="$(run_fleet harvest)"
echo "$HV" | grep '^ws-2:' | grep -q 'not approved' && ok "body-quoted verdict does NOT fake approval (fm boundary)" || fail "body-quoted verdict does NOT fake approval (got: $(echo "$HV" | grep '^ws-2:'))"

# A real APPROVE in frontmatter (newer) -> READY
sleep 1
APPROVED="$REPO_FIX/.comms/archive/ws-2_2026-06-04T11-30-00_review.md"
cat > "$APPROVED" <<'MSG'
---
type: review-feedback
from: codex
timestamp: 2026-06-04T11:30:00Z
workspace: ws-2
workflow: auto-implement
phase: implement
round: 1
max-rounds: 10
verdict: APPROVE
---

## Summary
Approved.
MSG
HV="$(run_fleet harvest)"
echo "$HV" | grep '^ws-2:' | grep -q 'READY' && ok "frontmatter APPROVE -> READY" || fail "frontmatter APPROVE -> READY (got: $(echo "$HV" | grep '^ws-2:'))"

# A pending to-claude message newer than the archive -> PENDING, not READY
sleep 1
PEND="$REPO_FIX/.comms/to-claude/ws-2_2026-06-04T11-45-00_reply.md"
cp "$APPROVED" "$PEND"
HV="$(run_fleet harvest)"
echo "$HV" | grep '^ws-2:' | grep -q 'PENDING' && ok "newer unread message -> PENDING" || fail "newer unread message -> PENDING (got: $(echo "$HV" | grep '^ws-2:'))"
rm -f "$PEND"

echo "== fleet.sh: dispatch-all --yes skips a dead target without aborting the batch =="
# ws-10's tree has only ONE pane -> cmd_dispatch dies on pane resolution at fire
# time; the batch must skip it and still complete (regression: exit-vs-skip).
cat > "$CMUX_STUB_DIR/tree-workspace_81.txt" <<'TREE'
workspace workspace:81 "ws-10"
├── pane pane:1
│   └── surface surface:51 [terminal] "Claude Code"
TREE
BRIEF2="docs/brief-two.md"
echo "brief two" > "$REPO_FIX/$BRIEF2"
: > "$CMUX_STUB_LOG"
DA_FIRE="$(run_fleet dispatch-all "$TRICKY" "$BRIEF2" --yes 2>&1)"
DA_RC=$?
[ "$DA_RC" -eq 0 ] && ok "batch completes despite one dead target" || fail "batch completes despite one dead target (rc=$DA_RC)"
echo "$DA_FIRE" | grep -q "skipped ws-10" && ok "dead target reported as skipped" || fail "dead target reported as skipped (got: $DA_FIRE)"
[ "$(grep -c '/auto-implement' "$CMUX_STUB_LOG")" = "1" ] && ok "exactly one brief fired (ws-2 only)" || fail "exactly one brief fired (log: $(grep -c '/auto-implement' "$CMUX_STUB_LOG"))"

echo "== fleet.sh: dispatch-all excludes workspaces with unread mail =="
PEND2="$REPO_FIX/.comms/to-claude/ws-2_2026-06-04T12-30-00_unread.md"
cp "$APPROVED" "$PEND2"
DA_EX="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$FLEET" dispatch-all "$TRICKY") 2>&1 )"
echo "$DA_EX" | grep -q "excluding ws-2" && ok "pending unread mail excludes workspace from free list" || fail "pending exclusion (got: $DA_EX)"
rm -f "$PEND2"

echo "== fleet.sh: dispatch-all --force propagates to per-target dispatch =="
: > "$CMUX_STUB_LOG"
DA_CAP="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 FLEET_MAX=0 "$FLEET" dispatch-all "$TRICKY" --yes) 2>&1 )"
grep -q '/auto-implement' "$CMUX_STUB_LOG" && fail "capped batch must not fire (FLEET_MAX=0)" || ok "capped batch does not fire (FLEET_MAX=0)"
echo "$DA_CAP" | grep -q 'skipped' && ok "capped target reported as skipped" || fail "capped target reported as skipped (got: $DA_CAP)"
: > "$CMUX_STUB_LOG"
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 FLEET_MAX=0 "$FLEET" dispatch-all "$TRICKY" --yes --force) >/dev/null 2>&1
grep -q "/auto-implement $TRICKY" "$CMUX_STUB_LOG" && ok "--force forwarded: batch fires past the cap" || fail "--force forwarded: batch fires past the cap"

echo "== fleet.sh: dispatch-all excludes first-handoff workspace (no archive, unread mail) =="
PEND10="$REPO_FIX/.comms/to-codex/ws-10_2026-06-04T12-40-00_auto-implement.md"
cp "$GOOD" "$PEND10"
DA_FH="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$FLEET" dispatch-all "$TRICKY") 2>&1 )"
echo "$DA_FH" | grep -q "excluding ws-10" && ok "no-archive + pending message is excluded (first round in flight)" || fail "first-handoff exclusion (got: $DA_FH)"
rm -f "$PEND10"

echo "== fleet.sh: clear =="
cp "$CMUX_STUB_DIR/tree-workspace_80.txt" "$CMUX_STUB_DIR/tree-workspace_81.txt"
: > "$CMUX_STUB_LOG"
run_fleet clear ws-2 >/dev/null
[ "$(grep -c 'send --surface surface:4[12] --workspace workspace:80 /new' "$CMUX_STUB_LOG")" = "2" ] && ok "clear /new's both panes" || fail "clear /new's both panes"

echo "== comms.sh: status smoke =="
ST="$(run_comms status)"
echo "$ST" | grep -q "workspace: feature-helper-tests" && ok "status prints workspace" || fail "status prints workspace"
echo "$ST" | grep -q "latest archived:" && ok "status prints latest archived" || fail "status prints latest archived"
echo "$ST" | grep -q "pending in to-claude:" && ok "status prints pending counts" || fail "status prints pending counts"

echo "== install.sh: local pin gitignored + global scope (overridden HOME dirs) =="
grep -qxF '.agent-comms/' "$INST_FIX/.gitignore" && ok "local install gitignores .agent-comms/" || fail "local install gitignores .agent-comms/"
GHOME="$WORK/ghome"
(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global >/dev/null 2>&1)
[ -x "$GHOME/agent-comms/comms.sh" ] && ok "global scope installs executable helpers (env-overridden)" || fail "global scope installs executable helpers"
[ -f "$GHOME/commands/fleet.md" ] && ok "global scope installs commands (env-overridden)" || fail "global scope installs commands"
[ -f "$GHOME/skills/read-from-claude/SKILL.md" ] && ok "global scope installs skills (env-overridden)" || fail "global scope installs skills"

echo "== comms.sh v2: thread filter + verdict normalization + error lane =="
TA="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-00-00_alpha-1.md"
TB="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-00-01_beta-1.md"
cat > "$TA" <<'MSG'
---
type: review-feedback
from: codex
timestamp: 2026-06-04T13:00:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T13-00-00_alpha-1
thread: loop-alpha
workflow: auto-implement
phase: implement
round: 1
max-rounds: 10
verdict:  approve
---

## Summary
Alpha reply.
MSG
sed 's/alpha/beta/g; s/loop-beta/loop-beta/' "$TA" > "$TB"
LIST_T="$(run_comms list --as claude --thread loop-alpha)"
[ "$(echo "$LIST_T" | grep -c .)" = "1" ] && echo "$LIST_T" | grep -q alpha-1 && ok "list --thread isolates one loop's messages" || fail "list --thread isolation (got: $LIST_T)"
[ "$(run_comms verdict "$TA")" = "APPROVE" ] && ok "verdict normalizes ' approve ' -> APPROVE" || fail "verdict normalization (got: $(run_comms verdict "$TA"))"
ERRMSG="$WORK/error-lane.md"
sed 's/type: review-feedback/type: error/; /^verdict:/d' "$TA" > "$ERRMSG"
check "type: error from codex passes without verdict" run_comms validate "$ERRMSG"
NOTHREAD="$WORK/nothread.md"
grep -v '^thread:' "$TA" > "$NOTHREAD"
WARN="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" validate "$NOTHREAD") 2>&1 1>/dev/null )"
echo "$WARN" | grep -q "no thread field" && ok "workflow message without thread warns (soft, non-fatal)" || fail "thread soft warning (got: $WARN)"

echo "== comms.sh v2: state lifecycle =="
OUT_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-05-00_round-2-777.md"
cat > "$OUT_WF" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-06-04T13:05:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T13-05-00_round-2-777
thread: loop-alpha
workflow: auto-implement
phase: implement
round: 2
max-rounds: 10
---

## What was done
Round two.
MSG
check "send (manual pickup) succeeds" run_comms send --to codex "$OUT_WF"
SF="$REPO_FIX/.comms/state/feature-helper-tests_loop-alpha.json"
[ -f "$SF" ] && ok "send writes thread state file" || fail "send writes thread state file"
grep -q '"awaiting_from": "codex"' "$SF" && ok "state records who owes the next message" || fail "state awaiting_from"
grep -q '"last_delivery": "manual"' "$SF" && ok "state records delivery outcome (manual)" || fail "state last_delivery manual"
run_comms state list | grep -q 'loop-alpha.*r2/10' && ok "state list summarizes thread" || fail "state list (got: $(run_comms state list))"
# stalled: backdate the awaiting epoch by an hour
perl -pi -e 's/"awaiting_since_epoch": "\d+"/"awaiting_since_epoch": "'"$(( $(date +%s) - 3600 ))"'"/' "$SF"
run_comms stalled 15 | grep -q 'STALLED.*loop-alpha' && ok "stalled flags threads awaiting too long" || fail "stalled detection (got: $(run_comms stalled 15))"
check "state complete marks thread done" run_comms state complete loop-alpha
grep -q '"status": "complete"' "$SF" && ok "state complete persists" || fail "state complete persists"
run_comms stalled 15 | grep -q 'no stalled' && ok "completed thread is not stalled" || fail "completed thread is not stalled"

echo "== comms.sh v2: delivery failure is explicit and recorded =="
DELIV_OUT="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_FAIL=1 "$COMMS" deliver codex)"
echo "$DELIV_OUT" | grep -q "FAILED mid-sequence" && ok "mid-sequence cmux failure reported explicitly" || fail "delivery failure report (got: $DELIV_OUT)"
# Under stub cmux the RESOLVED workspace (test-project) keys the state file —
# the helper warns about the frontmatter mismatch and keys on the resolver.
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_FAIL=1 "$COMMS" send --to codex "$OUT_WF") >/dev/null 2>&1
SF_CMUX="$REPO_FIX/.comms/state/test-project_loop-alpha.json"
grep -q '"last_delivery": "failed"' "$SF_CMUX" && ok "failed delivery recorded in state (resolved-ws key)" || fail "failed delivery recorded in state (state dir: $(ls "$REPO_FIX/.comms/state/" 2>/dev/null))"

echo "== comms.sh v2: state hardening (slash thread, garbage epoch, quotes) =="
SLASH_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-10-00_slash-1.md"
SLASH_IN="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-09-00_slashin.md"
sed 's/thread: loop-alpha/thread: fix-auth\/login-99/; s/round: 2/round: 3/' "$OUT_WF" > "$SLASH_WF"
cp "$TA" "$SLASH_IN"
check "send survives a thread containing a slash" run_comms send --to codex "$SLASH_WF" --archive-inbound "$SLASH_IN"
[ ! -f "$SLASH_IN" ] && ok "inbound archived despite slash thread (no desync)" || fail "inbound archived despite slash thread"
[ -f "$REPO_FIX/.comms/state/feature-helper-tests_fix-auth_login-99.json" ] && ok "slash thread sanitized into state filename" || fail "slash thread sanitized (state dir: $(ls "$REPO_FIX/.comms/state/" 2>/dev/null))"
# garbage epoch must not crash stalled or fleet status
perl -pi -e 's/"awaiting_since_epoch": "\d+"/"awaiting_since_epoch": "garbage"/' "$REPO_FIX/.comms/state/feature-helper-tests_fix-auth_login-99.json"
check "stalled survives a garbage epoch" run_comms stalled 15
QUOTE_WF="$WORK/quote-wf.md"
sed 's/phase: implement/phase: fix "login" bug/' "$OUT_WF" > "$QUOTE_WF"
(cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$QUOTE_WF") >/dev/null 2>&1
grep -q '\\"login\\"' "$REPO_FIX/.comms/state/feature-helper-tests_loop-alpha.json" && ok "embedded quotes escaped in state JSON" || fail "embedded quotes escaped (got: $(grep phase "$REPO_FIX/.comms/state/feature-helper-tests_loop-alpha.json"))"

echo "== fleet.sh: dispatch-all accepts a lowercase/whitespace verdict (normalized) =="
# Newest ws-2 archive gets a sloppy verdict — dispatch-all must still treat it as APPROVE
sleep 1
SLOPPY="$REPO_FIX/.comms/archive/ws-2_2026-06-04T12-50-00_review.md"
sed 's/^verdict: APPROVE$/verdict:  approve /' "$APPROVED" > "$SLOPPY"
DA_NORM="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$FLEET" dispatch-all "$TRICKY") 2>&1 )"
echo "$DA_NORM" | grep -q -- "-> ws-2" && ok "dispatch-all normalizes verdict (' approve ' is eligible)" || fail "dispatch-all verdict normalization (got: $DA_NORM)"
rm -f "$SLOPPY"

echo "== comms.sh v2: state dir blocked as a FILE must not break send/archive =="
mv "$REPO_FIX/.comms/state" "$REPO_FIX/.comms/state.bak"
touch "$REPO_FIX/.comms/state"
BLOCK_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-20-00_blocked-1.md"
BLOCK_IN="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-19-00_blockedin.md"
sed 's/round: 2/round: 4/' "$OUT_WF" > "$BLOCK_WF"
cp "$TA" "$BLOCK_IN"
BLOCK_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$BLOCK_WF" --archive-inbound "$BLOCK_IN") 2>&1 )"
BLOCK_RC=$?
[ "$BLOCK_RC" -eq 0 ] && ok "send succeeds when state dir is blocked (rc=0)" || fail "send succeeds when state dir is blocked (rc=$BLOCK_RC; out: $BLOCK_OUT)"
[ ! -f "$BLOCK_IN" ] && ok "inbound archived despite blocked state dir (no desync)" || fail "inbound archived despite blocked state dir"
echo "$BLOCK_OUT" | grep -q "cannot create state dir" && ok "blocked state dir produces explicit warning" || fail "blocked state dir warning (got: $BLOCK_OUT)"
rm -f "$REPO_FIX/.comms/state"
mv "$REPO_FIX/.comms/state.bak" "$REPO_FIX/.comms/state"

echo "== comms.sh v2.1: workspace resilience (empty cmux tree must not abort or flap) =="
rm -f "$REPO_FIX/.comms/.cache/ws-workspace_10"
WS_EMPTY="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_TREE_EMPTY=1 "$COMMS" workspace) 2>/dev/null )"
WS_EMPTY_RC=$?
[ "$WS_EMPTY_RC" -eq 0 ] && ok "empty cmux tree does not abort the helper (rc=0)" || fail "empty cmux tree aborts helper (rc=$WS_EMPTY_RC)"
[ "$WS_EMPTY" = "feature-helper-tests" ] && ok "no-cache fallback resolves branch name" || fail "no-cache fallback (got: $WS_EMPTY)"
# Prime the cache with a good resolution, then break the tree: identity must stick.
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" workspace) >/dev/null
WS_STICKY="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_TREE_EMPTY=1 "$COMMS" workspace) 2>/dev/null )"
[ "$WS_STICKY" = "test-project" ] && ok "cached identity survives a flaky tree (no atlas/master flap)" || fail "cached identity sticks (got: $WS_STICKY)"

echo "== comms.sh v2.1: surface binding =="
check "bind sets an explicit surface" env -u X bash -c "cd '$REPO_FIX' && PATH='$STUB_BIN:$PATH' CMUX_WORKSPACE_ID=workspace:10 '$COMMS' bind claude surface:11"
: > "$CMUX_STUB_LOG"
BOUND_OUT="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" deliver claude)"
echo "$BOUND_OUT" | grep -q "delivered to surface:11 (bound)" && ok "deliver honors the binding over the picker" || fail "deliver honors binding (got: $BOUND_OUT)"
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" bind claude surface:999) >/dev/null
BOUND_GONE="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" deliver claude)"
echo "$BOUND_GONE" | grep -q "delivered to surface:22" && ok "absent bound surface falls back to picker" || fail "absent binding falls back (got: $BOUND_GONE)"
grep -q "delivered to surface:22" <<<"$BOUND_GONE" && [ "$(cd "$REPO_FIX" && cat .comms/.cache/surface-claude-workspace_10)" = "surface:22" ] && ok "successful delivery refreshes the surface cache" || fail "delivery refreshes surface cache"

echo "== comms.sh v2.1.1: binding survives a flaky tree (optimistic delivery) =="
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" bind claude surface:22) >/dev/null
: > "$CMUX_STUB_LOG"
OPT_OUT="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_TREE_EMPTY=1 "$COMMS" deliver claude)"
echo "$OPT_OUT" | grep -q "delivered to surface:22 (bound (tree unavailable — optimistic))" && ok "bound surface used when tree is unavailable" || fail "optimistic bound delivery (got: $OPT_OUT)"
grep -q 'send --surface surface:22' "$CMUX_STUB_LOG" && ok "optimistic delivery actually sent keystrokes" || fail "optimistic delivery sent keystrokes"
# No binding + no tree -> manual, with a diagnostic naming the why
rm -f "$REPO_FIX/.comms/.cache/surface-codex-workspace_10"
DIAG="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_TREE_EMPTY=1 "$COMMS" deliver codex) 2>&1 )"
echo "$DIAG" | grep -q "manual pickup" && ok "no binding + no tree degrades to manual" || fail "no binding + no tree (got: $DIAG)"
echo "$DIAG" | grep -q "tree unavailable after retries" && ok "empty-tree manual outcome carries a diagnostic" || fail "empty-tree diagnostic (got: $DIAG)"

echo "== comms.sh v2.1.2: cmux-socket sandbox failure names the wrapper, not escalation =="
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" bind claude surface:22) >/dev/null
SBX="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_SANDBOX=1 "$COMMS" deliver claude) 2>&1 )"
echo "$SBX" | grep -q "outside this sandbox" && ok "socket failure is recognized as a sandbox issue" || fail "sandbox recognition (got: $SBX)"
echo "$SBX" | grep -q "Do NOT request escalation" && ok "sandbox failure tells caller not to escalate" || fail "no-escalation guidance (got: $SBX)"
echo "$SBX" | grep -q "/bin/zsh -lc" && ok "sandbox failure prints the exact wrapper command" || fail "wrapper command printed (got: $SBX)"
echo "$SBX" | grep -qF "$COMMS" && ok "wrapper hint uses the helper's LITERAL path, not \$COMMS_SH" || fail "wrapper hint uses literal path (got: $SBX)"
echo "$SBX" | grep -q "cmux said:" && ok "sandbox failure echoes the cmux error" || fail "cmux error echoed (got: $SBX)"
# send classifies the sandbox block as its own outcome (not silent 'manual')
SBX_SEND="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_SANDBOX=1 "$COMMS" send --to claude "$OUT_WF") 2>/dev/null | tail -1 )"
case "$SBX_SEND" in "RESULT: blocked"*) ok "send RESULT is 'blocked' on a sandboxed socket (not 'manual')" ;; *) fail "blocked RESULT (got: $SBX_SEND)" ;; esac
echo "$SBX_SEND" | grep -q "do NOT escalate" && ok "blocked RESULT says do NOT escalate" || fail "blocked RESULT escalation guidance (got: $SBX_SEND)"
# The self-resolving wrapper from the skills actually runs in a child zsh with no COMMS_SH
if command -v zsh >/dev/null 2>&1; then
  # -c (not -lc) so the login profile can't change cwd in the test; the skill's
  # real wrapper uses -lc, but the mechanism under test (no inherited COMMS_SH)
  # is identical either way.
  WRAP="$( (cd "$REPO_FIX" && env -u COMMS_SH -u CMUX_WORKSPACE_ID zsh -c 'C=$(git worktree list --porcelain 2>/dev/null|head -1|sed "s/^worktree //")/.agent-comms/comms.sh; [ -x "$C" ]||C="'"$REPO"'/helpers/comms.sh"; "$C" workspace') 2>/dev/null )"
  [ "$WRAP" = "feature-helper-tests" ] && ok "self-resolving wrapper runs with no inherited COMMS_SH" || fail "self-resolving wrapper (got: $WRAP)"
fi

echo "== comms.sh v2.1.1: status shouts when a loop stalled undelivered =="
perl -pi -e 's/"last_delivery": "[^"]*"/"last_delivery": "manual"/; s/"status": "[^"]*"/"status": "in-progress"/' "$SF"
ST_OUT="$(run_comms status)"
echo "$ST_OUT" | grep -q "ACTION NEEDED" && ok "status prints ACTION NEEDED on undelivered last send" || fail "status ACTION line (got: $(echo "$ST_OUT" | tail -2))"
perl -pi -e 's/"status": "in-progress"/"status": "complete"/' "$SF"
ST_OUT="$(run_comms status)"
echo "$ST_OUT" | grep -q "ACTION NEEDED" && fail "completed thread must not shout" || ok "completed thread does not shout"

echo "== comms.sh v2.1: send emits a loud RESULT line — and it is the FINAL line =="
RES_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$OUT_WF") 2>/dev/null )"
echo "$RES_OUT" | grep -q "^RESULT: manual" && ok "manual outcome includes RESULT: manual" || fail "RESULT line (got: $(echo "$RES_OUT" | tail -1))"
# The autonomous path (--archive-inbound) must ALSO end with RESULT, not "archived:".
RES_IN="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-30-00_resin.md"
cp "$TA" "$RES_IN"
RES_TAIL="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$OUT_WF" --archive-inbound "$RES_IN") 2>/dev/null | tail -1 )"
case "$RES_TAIL" in RESULT:*) ok "tail -1 of send --archive-inbound is the RESULT line" ;; *) fail "final line on archive path (got: $RES_TAIL)" ;; esac
[ ! -f "$RES_IN" ] && ok "inbound still archived on the RESULT-last path" || fail "inbound archived on RESULT-last path"

echo "== fleet.sh: status shows thread-state owes note =="
mkdir -p "$REPO_FIX/.comms/state"
cat > "$REPO_FIX/.comms/state/ws-2_loop-x.json" <<JSON
{
  "workspace": "ws-2",
  "thread": "loop-x",
  "workflow": "auto-implement",
  "phase": "implement",
  "round": "1",
  "max_rounds": "10",
  "status": "in-progress",
  "awaiting_from": "codex",
  "awaiting_since": "2026-06-04T13:00:00Z",
  "awaiting_since_epoch": "$(( $(date +%s) - 120 ))",
  "last_sent": "x",
  "last_delivery": "delivered"
}
JSON
run_fleet status | grep '^ws-2 ' | grep -q 'owes=codex' && ok "fleet status surfaces state ground truth (owes=)" || fail "fleet status owes note (got: $(run_fleet status | grep '^ws-2 '))"
rm -f "$REPO_FIX/.comms/state/ws-2_loop-x.json"

echo "== comms.sh v2: clean (guarded, dry-run default) — runs last, deletes fixture =="
PRE_COUNT="$(find "$REPO_FIX/.comms/to-claude" "$REPO_FIX/.comms/to-codex" "$REPO_FIX/.comms/archive" -type f | wc -l | tr -d ' ')"
DRY="$(run_comms clean --as claude workspace)"
echo "$DRY" | grep -q "would delete" && ok "clean dry-runs without --yes" || fail "clean dry-run (got: $DRY)"
POST_COUNT="$(find "$REPO_FIX/.comms/to-claude" "$REPO_FIX/.comms/to-codex" "$REPO_FIX/.comms/archive" -type f | wc -l | tr -d ' ')"
[ "$PRE_COUNT" = "$POST_COUNT" ] && ok "dry-run deleted nothing" || fail "dry-run deleted nothing ($PRE_COUNT -> $POST_COUNT)"
run_comms clean --as claude workspace --yes >/dev/null
[ -z "$(find "$REPO_FIX/.comms/to-claude" -name 'feature-helper-tests_*' -type f 2>/dev/null)" ] && ok "clean --yes empties own inbox" || fail "clean --yes empties own inbox"
[ -n "$(find "$REPO_FIX/.comms/to-codex" -name 'feature-helper-tests_*' -type f 2>/dev/null)" ] && ok "clean workspace mode never touches the other inbox" || fail "clean spares other inbox"
run_comms clean --as claude all --yes >/dev/null
[ -z "$(find "$REPO_FIX/.comms/to-codex" -type f 2>/dev/null)" ] && ok "clean all --yes wipes both inboxes" || fail "clean all wipes"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
