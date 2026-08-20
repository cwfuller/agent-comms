#!/bin/bash
# agent-comms test harness — repeatable checks for the shared helpers and installer.
# Stubs cmux with a fake binary (canned tree output + call log) so picker/delivery
# logic is testable headlessly. Run: bash tests/run.sh   (zsh callers covered too)
set -uo pipefail

# HERMETIC: scrub inherited headless-delivery env — a harness run from INSIDE a
# headless peer turn (e.g. Codex reviewing this repo) inherits these and would
# route the baseline cmux tests through headless delivery (observed live: 40
# failures). The headless-specific sections set them explicitly per invocation.
unset COMMS_DELIVERY COMMS_HEADLESS_PICKUP 2>/dev/null || true

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
  list-workspaces)
    [ -n "${CMUX_STUB_SANDBOX:-}" ] && { echo "Operation not permitted (cmux.sock)" >&2; exit 1; }
    cat "$CMUX_STUB_DIR/list.txt" 2>/dev/null ;;
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
# Current cmux text includes selection/active markers and callers commonly carry
# a UUID in CMUX_WORKSPACE_ID even though the tree prints a workspace:N ref.
MODERN_WS_ID="9F42CB3D-80E6-4189-8705-C3BB065237C7"
cat > "$CMUX_STUB_DIR/tree-$MODERN_WS_ID.txt" <<'TREE'
window window:1 [current] ◀ active
└── workspace workspace:14 "Modern Project" [selected] ◀ active
    ├── pane pane:26
    │   └── surface surface:41 [terminal] "Codex" [selected] ◀ here tty=ttys025
    └── pane pane:27 [focused] ◀ active
        └── surface surface:42 [terminal] "Claude" [selected] ◀ active tty=ttys046
TREE
WS_MODERN="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID="$MODERN_WS_ID" "$COMMS" workspace)"
[ "$WS_MODERN" = "modern-project" ] && ok "workspace parses current cmux tree shape with UUID env id" || fail "current cmux tree parse (got $WS_MODERN)"
# A successful but decorated parse must not overwrite an established identity.
cat > "$CMUX_STUB_DIR/tree-$MODERN_WS_ID.txt" <<'TREE'
workspace workspace:14 "⠐ Review Modern Project PRD"
TREE
WS_DECORATED="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID="$MODERN_WS_ID" "$COMMS" workspace)"
[ "$WS_DECORATED" = "modern-project" ] && ok "cmux spinner title cannot overwrite cached workspace identity" || fail "decorated title changed identity (got $WS_DECORATED)"
[ "$(cat "$REPO_FIX/.comms/.cache/ws-$MODERN_WS_ID")" = "modern-project" ] && ok "decorated title leaves authoritative cache unchanged" || fail "decorated title poisoned cache"
SPINNER_MSG="$REPO_FIX/.comms/to-claude/modern-project_spinner-regression.md"
printf '%s\n' pending > "$SPINNER_MSG"
SPINNER_LIST="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID="$MODERN_WS_ID" "$COMMS" list --as claude)"
[ "$SPINNER_LIST" = "$SPINNER_MSG" ] && ok "spinner title cannot hide a scoped pending message" || fail "spinner title hid pending message (got $SPINNER_LIST)"
rm -f "$SPINNER_MSG"
if command -v zsh >/dev/null 2>&1; then
  WS_ZSH="$(cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID zsh -c "\"$COMMS\" workspace")"
  [ "$WS_ZSH" = "feature-helper-tests" ] && ok "helper is caller-shell agnostic (zsh)" || fail "helper under zsh (got $WS_ZSH)"
fi

echo "== comms.sh: Codex cmux permission preflight =="
printf '%s\n' 'workspace:10 Test Project' > "$CMUX_STUB_DIR/list.txt"
DOC_OK="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" "$COMMS" doctor)"
[ "$DOC_OK" = "cmux socket: reachable" ] \
  && ok "doctor confirms a reachable cmux socket" || fail "doctor reachable result (got: $DOC_OK)"
if DOC_BLOCKED="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_STUB_SANDBOX=1 "$COMMS" doctor 2>&1)"; then
  DOC_RC=0
else
  DOC_RC=$?
fi
[ "$DOC_RC" = 3 ] && ok "doctor distinguishes a sandbox-blocked socket" || fail "doctor blocked rc (got: $DOC_RC)"
echo "$DOC_BLOCKED" | grep -q "codex-permissions" \
  && ok "doctor points to the persistent Codex fix" || fail "doctor permission-profile hint"
PERM_OUT="$(env -u CMUX_SOCKET -u CMUX_SOCKET_PATH -u XDG_STATE_HOME HOME=/Users/example "$COMMS" codex-permissions)"
echo "$PERM_OUT" | grep -q 'default_permissions = "workspace-cmux"' \
  && ok "codex-permissions selects the profile globally by default" || fail "codex-permissions default profile"
echo "$PERM_OUT" | grep -q 'extends = ":workspace"' \
  && ok "codex-permissions preserves the workspace sandbox baseline" || fail "codex-permissions workspace baseline"
echo "$PERM_OUT" | grep -q '"/Users/example/.local/state/cmux/cmux.sock" = "allow"' \
  && ok "codex-permissions allowlists only the resolved cmux socket" || fail "codex-permissions socket allowlist"
echo "$PERM_OUT" | grep -q 'Do not launch it with --sandbox' \
  && ok "codex-permissions warns that launch overrides defeat the global default" || fail "codex-permissions launch override warning"

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
sed 's/from: claude/from: codex/; s/type: review-request/type: review-feedback/' "$GOOD" > "$BAD_NOVERDICT"
check_not "workflow review-feedback without verdict is rejected" run_comms validate "$BAD_NOVERDICT"
# The verdict rule binds by TYPE, not sender: a reverse-topology review-request
# FROM codex needs no verdict.
REV_REQ="$WORK/codex-request.md"
sed 's/from: claude/from: codex/' "$GOOD" > "$REV_REQ"
check "reverse-topology review-request from codex validates without verdict" run_comms validate "$REV_REQ"

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
UNMATCHED="$REPO_FIX/.comms/to-claude/other-workspace_pending.md"
printf '%s\n' pending > "$UNMATCHED"
LIST_MISMATCH="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" list --as claude) 2>&1 1>/dev/null || true)"
echo "$LIST_MISMATCH" | grep -q "possible workspace identity mismatch" && ok "empty scoped list warns when unmatched inbox files exist" || fail "unmatched inbox warning (got: $LIST_MISMATCH)"
rm -f "$UNMATCHED"

echo "== comms.sh: latest archive is direction/thread/time aware =="
ARCH_OLD="$REPO_FIX/.comms/archive/feature-helper-tests_z-round-6.md"
ARCH_NEW="$REPO_FIX/.comms/archive/feature-helper-tests_a-round-7.md"
ARCH_WRONG_DIRECTION="$REPO_FIX/.comms/archive/feature-helper-tests_zz-wrong-direction.md"
cat > "$ARCH_OLD" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-07-28T10:00:00Z
workspace: feature-helper-tests
thread: archive-order
workflow: auto-implement
phase: implement
round: 6
max-rounds: 10
---
old
MSG
cat > "$ARCH_NEW" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-07-28T11:00:00Z
workspace: feature-helper-tests
thread: archive-order
workflow: auto-implement
phase: implement
round: 7
max-rounds: 10
---
new
MSG
cat > "$ARCH_WRONG_DIRECTION" <<'MSG'
---
type: review-feedback
from: codex
timestamp: 2026-07-28T12:00:00Z
workspace: feature-helper-tests
thread: archive-order
workflow: auto-implement
phase: implement
round: 8
max-rounds: 10
verdict: APPROVE
---
wrong direction
MSG
ARCH_HINT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" list --as codex --thread archive-order) 2>&1 1>/dev/null || true)"
echo "$ARCH_HINT" | grep -q "$(basename "$ARCH_NEW")" && ok "latest archive uses protocol time, not filename order" || fail "protocol-time archive order (got: $ARCH_HINT)"
echo "$ARCH_HINT" | grep -q "$(basename "$ARCH_WRONG_DIRECTION")" && fail "latest archive crossed reader direction" || ok "latest archive is reader-direction aware"

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
[ -f "$INST_FIX/.claude/commands/ask.md" ] && [ -f "$INST_FIX/.claude/commands/ask-codex.md" ] \
  && ok "local scope installs /ask and the deprecated alias" || fail "local scope installs ask.md + ask-codex.md"
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
GH_OUT="$(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global 2>&1)"
[ -x "$GHOME/agent-comms/comms.sh" ] && ok "global scope installs executable helpers (env-overridden)" || fail "global scope installs executable helpers"
[ -f "$GHOME/commands/fleet.md" ] && ok "global scope installs commands (env-overridden)" || fail "global scope installs commands"
[ -f "$GHOME/commands/ask.md" ] && [ -f "$GHOME/commands/ask-codex.md" ] \
  && ok "global scope installs /ask and the deprecated alias" || fail "global scope installs ask.md + ask-codex.md"
[ -f "$GHOME/skills/read-from-claude/SKILL.md" ] && ok "global scope installs skills (env-overridden)" || fail "global scope installs skills"
echo "$GH_OUT" | grep -q "codex-permissions" \
  && ok "global install names the one-time default Codex socket setup" || fail "global install Codex socket setup hint"

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
run_comms stalled 15 | grep -q 'inbox=unread' && ok "stalled distinguishes an unread persisted message" || fail "stalled unread evidence (got: $(run_comms stalled 15))"
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

echo "== fleet.sh: loopspec pass synonym gates like APPROVE (kernel parity) =="
sleep 1
PASSV="$REPO_FIX/.comms/archive/ws-2_2026-06-04T12-55-00_review.md"
sed 's/^verdict: APPROVE$/verdict: pass/' "$APPROVED" > "$PASSV"
DA_PASS="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$FLEET" dispatch-all "$TRICKY") 2>&1 )"
echo "$DA_PASS" | grep -q -- "-> ws-2" && ok "dispatch-all treats 'verdict: pass' as completion" || fail "dispatch-all pass synonym (got: $DA_PASS)"
HV_PASS="$(run_fleet harvest)"
echo "$HV_PASS" | grep '^ws-2:' | grep -q 'READY' && ok "harvest treats 'verdict: pass' as READY" || fail "harvest pass synonym (got: $(echo "$HV_PASS" | grep '^ws-2:'))"
rm -f "$PASSV"

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
# Recover a cache already poisoned by an auto-title spinner. On the fixture's
# feature branch, the stable repo-derived fallback is feature-helper-tests.
POISON_WS_ID="workspace:spinner-poison"
printf '%s' '⠐-review-helper-tests' > "$REPO_FIX/.comms/.cache/ws-workspace_spinner-poison"
WS_REPAIRED="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID="$POISON_WS_ID" CMUX_STUB_TREE_EMPTY=1 "$COMMS" workspace) 2>/dev/null )"
[ "$WS_REPAIRED" = "feature-helper-tests" ] && ok "decorated cache is rejected and repaired from repo identity" || fail "decorated cache repair (got: $WS_REPAIRED)"
[ "$(cat "$REPO_FIX/.comms/.cache/ws-workspace_spinner-poison")" = "feature-helper-tests" ] && ok "repaired identity replaces poisoned cache" || fail "poisoned cache not replaced"

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

echo "== comms.sh v2.2: sandbox block emits direct recovery + state reconciliation =="
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" bind claude surface:22) >/dev/null
SBX="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_SANDBOX=1 "$COMMS" deliver claude) 2>&1 )"
echo "$SBX" | grep -q "nested helper cannot access cmux" && ok "socket failure is classified as nested-helper sandboxing" || fail "sandbox recognition (got: $SBX)"
echo "$SBX" | grep -q "^RECOVER: cmux send-key" && ok "sandbox failure prints one direct-cmux recovery command" || fail "direct recovery command (got: $SBX)"
echo "$SBX" | grep -q "/bin/zsh -lc" && fail "obsolete wrapper retry still printed" || ok "sandbox recovery no longer promises wrapper escape"
echo "$SBX" | grep -q "cmux said:" && ok "sandbox failure echoes the cmux error" || fail "cmux error echoed (got: $SBX)"
echo "$SBX" | grep -q "retries from this unchanged sandbox will also block" \
  && ok "sandbox failure stops blind in-session retries" || fail "sandbox retry guidance (got: $SBX)"
# send classifies the sandbox block as its own outcome (not silent 'manual')
SBX_SEND_ALL="$( (cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_SANDBOX=1 "$COMMS" send --to claude "$OUT_WF") 2>/dev/null )"
SBX_SEND="$(echo "$SBX_SEND_ALL" | tail -1)"
case "$SBX_SEND" in "RESULT: blocked"*) ok "send RESULT is 'blocked' on a sandboxed socket (not 'manual')" ;; *) fail "blocked RESULT (got: $SBX_SEND)" ;; esac
echo "$SBX_SEND" | grep -q "restart with cmux socket permission" \
  && ok "blocked RESULT names the persistent fix" || fail "blocked RESULT permission hint (got: $SBX_SEND)"
echo "$SBX_SEND_ALL" | grep -qF "$COMMS' reconcile '$OUT_WF" && ok "RECOVER chain ends with literal helper+message reconciliation" || fail "RECOVER reconciliation tail (got: $SBX_SEND_ALL)"
grep -q '"last_delivery": "blocked"' "$SF_CMUX" && ok "blocked send is recorded before recovery" || fail "blocked state before recovery"
REC_CMD="$(printf '%s\n' "$SBX_SEND_ALL" | sed -n 's/^RECOVER: //p' | head -1)"
: > "$CMUX_STUB_LOG"
REC_OUT="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 bash -c "$REC_CMD")"
echo "$REC_OUT" | grep -q "^RESULT: delivered" && ok "exact RECOVER command nudges and reconciles" || fail "RECOVER execution (got: $REC_OUT)"
grep -q 'send --surface surface:22' "$CMUX_STUB_LOG" && grep -q 'send-key --surface surface:22' "$CMUX_STUB_LOG" && ok "RECOVER uses direct cmux commands" || fail "RECOVER direct cmux log (got: $(cat "$CMUX_STUB_LOG"))"
grep -q '"last_delivery": "delivered"' "$SF_CMUX" && grep -q '"last_notified_at":' "$SF_CMUX" && ok "reconcile repairs delivery state with timestamp" || fail "reconciled state (got: $(cat "$SF_CMUX"))"

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

echo "== runphase v0: headless delivery via stubbed codex =="
RUNPHASE="$REPO/helpers/runphase.sh"
# codex stub: logs argv + the child's COMMS_DELIVERY, consumes the stdin prompt,
# emits canned JSONL, honors -o. Behavior toggles: CODEX_STUB_FAIL, CODEX_STUB_HANG.
# HERMETIC: without this stub on PATH, a headless test would spawn a REAL codex
# turn and burn real tokens (see ROADMAP: a non-hermetic test once fired a live agent).
export CODEX_STUB_LOG="$WORK/codex.log"
export COMMS_FOR_STUB="$COMMS"
cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/bash
{ echo "argv: $*"; echo "env: COMMS_DELIVERY=${COMMS_DELIVERY:-}"; } >> "$CODEX_STUB_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
cat > /dev/null   # consume the prompt from stdin
[ -n "${CODEX_STUB_HANG:-}" ] && sleep "$CODEX_STUB_HANG"
echo '{"type":"thread.started","thread_id":"stub-thread-42"}'
if [ -n "${CODEX_STUB_FAIL:-}" ]; then
  echo '{"type":"turn.failed","error":"stub failure"}'
  exit 1
fi
if [ -n "${CODEX_STUB_REPLY:-}" ]; then
  # Behave like the REAL peer: write a reply and atomically send it with
  # --archive-inbound, which MOVES the incoming message out of to-codex/.
  # (Regression: the runner's exit path must not re-read the archived file.)
  ROOT="$(git rev-parse --show-toplevel)/.comms"
  MSG="$(ls -t "$ROOT/to-codex/"*.md 2>/dev/null | head -1)"
  WS="$(basename "$MSG" | sed 's/_.*//')"
  REPLY="$ROOT/to-claude/${WS}_2026-06-04T14-30-00_stubreply-$$.md"
  {
    echo '---'
    echo 'type: review-feedback'
    echo 'from: codex'
    echo 'timestamp: 2026-06-04T14:30:00Z'
    echo "workspace: $WS"
    awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f' "$MSG" \
      | grep -E '^(thread|workflow|phase|round|max-rounds):'
    echo 'verdict: APPROVE'
    echo '---'
    echo ''
    echo '## Summary'
    echo 'Stub review.'
  } > "$REPLY"
  "$COMMS_FOR_STUB" send --to claude "$REPLY" --archive-inbound "$MSG" >/dev/null 2>&1 || exit 1
fi
echo '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":10}}'
[ -n "$out" ] && echo "stub last message" > "$out"
exit 0
STUB
chmod +x "$STUB_BIN/codex"

run_headless() { (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless PATH="$STUB_BIN:$PATH" "$COMMS" "$@"); }
run_rp() { (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless PATH="$STUB_BIN:$PATH" "$RUNPHASE" "$@"); }
rundir_of() { echo "$1" | sed -n 's/^ *run dir: //p' | head -1; }

# -- workflow message: spawn -> await -> completed, state mirrored --
HL_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-00-00_headless-1.md"
sed 's/thread: loop-alpha/thread: loop-headless/; s/round: 2/round: 1/' "$OUT_WF" > "$HL_WF"
: > "$CMUX_STUB_LOG"
HL_OUT="$(run_headless send --to codex "$HL_WF" 2>/dev/null)"
HL_TAIL="$(echo "$HL_OUT" | tail -1)"
case "$HL_TAIL" in "RESULT: spawned"*) ok "headless send ends with RESULT: spawned" ;; *) fail "headless RESULT line (got: $HL_TAIL)" ;; esac
[ ! -s "$CMUX_STUB_LOG" ] && ok "headless delivery never touches cmux" || fail "headless delivery touched cmux: $(cat "$CMUX_STUB_LOG")"
HL_DIR="$(rundir_of "$HL_OUT")"
[ -n "$HL_DIR" ] && [ -d "$HL_DIR" ] && ok "spawn printed a real run dir" || fail "spawn run dir (got: $HL_DIR)"
HL_SF="$REPO_FIX/.comms/state/feature-helper-tests_loop-headless.json"
grep -q '"last_delivery": "spawned"' "$HL_SF" && ok "state records last_delivery=spawned" || fail "state spawned (got: $(cat "$HL_SF" 2>/dev/null))"
AWAIT_OUT="$(run_rp await "$HL_DIR" --timeout-secs 30)"
AWAIT_RC=$?
[ "$AWAIT_RC" -eq 0 ] && ok "await exits 0 on completed turn" || fail "await rc on success (rc=$AWAIT_RC; out: $AWAIT_OUT)"
echo "$AWAIT_OUT" | grep -q '"status": "completed"' && ok "result.json status=completed" || fail "result status (got: $AWAIT_OUT)"
echo "$AWAIT_OUT" | grep -q '"session_id": "stub-thread-42"' && ok "session id captured from thread.started" || fail "session id capture (got: $AWAIT_OUT)"
grep -q '"thread.started"' "$HL_DIR/events.ndjson" && ok "events.ndjson has the JSONL event log" || fail "events.ndjson content"
grep -q "$(basename "$HL_WF")" "$HL_DIR/prompt.md" && ok "prompt names the target message file" || fail "prompt message path"
grep -q "RESULT: manual" "$HL_DIR/prompt.md" && ok "prompt pre-briefs the expected manual send result" || fail "prompt manual note"
grep -q "argv: exec --json -s workspace-write" "$CODEX_STUB_LOG" && ok "codex invoked as exec --json with workspace-write sandbox" || fail "codex argv (got: $(grep argv "$CODEX_STUB_LOG"))"
grep -q "env: COMMS_DELIVERY=headless" "$CODEX_STUB_LOG" && ok "child codex inherits COMMS_DELIVERY=headless" || fail "child env propagation"
grep -q '"last_delivery": "completed"' "$HL_SF" && ok "state updated to completed on exit" || fail "state completed (got: $(cat "$HL_SF"))"
grep -q '"codex_thread_id": "stub-thread-42"' "$HL_SF" && ok "state records codex_thread_id for future resume" || fail "state codex_thread_id (got: $(cat "$HL_SF"))"
ST_HL="$(run_headless status)"
echo "$ST_HL" | grep -q "ACTION NEEDED" && fail "completed headless turn must not shout ACTION NEEDED" || ok "status does not shout on completed headless turn"

# -- failed turn: recorded as failed, await exits non-zero --
HL_WF2="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-05-00_headless-2.md"
sed 's/round: 1/round: 2/' "$HL_WF" > "$HL_WF2"
HL_OUT2="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless CODEX_STUB_FAIL=1 PATH="$STUB_BIN:$PATH" "$COMMS" send --to codex "$HL_WF2") 2>/dev/null )"
HL_DIR2="$(rundir_of "$HL_OUT2")"
AWAIT2="$(run_rp await "$HL_DIR2" --timeout-secs 30)"; AWAIT2_RC=$?
[ "$AWAIT2_RC" -ne 0 ] && ok "await exits non-zero on failed turn" || fail "await rc on failure"
echo "$AWAIT2" | grep -q '"status": "failed"' && ok "result.json status=failed" || fail "failed result (got: $AWAIT2)"
grep -q '"last_delivery": "failed"' "$HL_SF" && ok "state records failed headless turn" || fail "state failed (got: $(cat "$HL_SF"))"
ST_HL2="$(run_headless status)"
echo "$ST_HL2" | grep -q "ACTION NEEDED" && ok "failed headless turn DOES shout ACTION NEEDED" || fail "failed turn should shout (got: $(echo "$ST_HL2" | tail -2))"

# -- full peer behavior: reply sent + inbound archived; success still recorded --
# (Regression for the archived-message re-read bug: the runner must record
# completed even though the child moved the message file out of to-codex/.)
HL_WFR="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-08-00_headless-r.md"
sed 's/thread: loop-headless/thread: loop-hl-reply/; s/round: 1/round: 1/' "$HL_WF" > "$HL_WFR"
HL_OUTR="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless CODEX_STUB_REPLY=1 PATH="$STUB_BIN:$PATH" "$COMMS" send --to codex "$HL_WFR") 2>/dev/null )"
HL_DIRR="$(rundir_of "$HL_OUTR")"
AWAITR="$(run_rp await "$HL_DIRR" --timeout-secs 30)"; AWAITR_RC=$?
[ "$AWAITR_RC" -eq 0 ] && ok "turn that archives its inbound still completes (await rc=0)" || fail "reply-turn await rc (rc=$AWAITR_RC; out: $AWAITR; log: $(cat "$HL_DIRR/runner.log" 2>/dev/null | tail -3))"
echo "$AWAITR" | grep -q '"status": "completed"' && ok "reply-turn result.json status=completed" || fail "reply-turn result (got: $AWAITR)"
[ ! -f "$HL_WFR" ] && ok "inbound was archived by the peer's atomic send" || fail "inbound archived by peer"
ls "$REPO_FIX/.comms/to-claude/" | grep -q stubreply && ok "peer reply landed in to-claude" || fail "peer reply in to-claude"
HL_SFR="$REPO_FIX/.comms/state/feature-helper-tests_loop-hl-reply.json"
grep -q '"last_delivery": "completed"' "$HL_SFR" && ok "state mirrors completed despite archived message" || fail "reply-turn state completed (got: $(cat "$HL_SFR" 2>/dev/null))"
grep -q '"codex_thread_id": "stub-thread-42"' "$HL_SFR" && ok "codex_thread_id survives the reply flow" || fail "reply-turn codex_thread_id"
grep -q '"awaiting_from": "claude"' "$HL_SFR" && ok "peer reply flipped awaiting_from to claude" || fail "reply-turn awaiting_from"

# -- timeout: hung turn killed, recorded as timeout; live turn guards re-delivery --
HL_WF3="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-10-00_headless-3.md"
sed 's/round: 1/round: 3/' "$HL_WF" > "$HL_WF3"
HL_OUT3="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless CODEX_STUB_HANG=30 COMMS_RUNPHASE_TIMEOUT_SECS=6 PATH="$STUB_BIN:$PATH" "$COMMS" send --to codex "$HL_WF3") 2>/dev/null )"
HL_DIR3="$(rundir_of "$HL_OUT3")"
sleep 2
DUP_OUT="$(run_headless deliver codex)"
echo "$DUP_OUT" | grep -q "already running" && ok "re-delivery of an in-flight turn is guarded (no double-spawn)" || fail "double-spawn guard (got: $DUP_OUT)"
AWAIT3="$(run_rp await "$HL_DIR3" --timeout-secs 60)"; AWAIT3_RC=$?
[ "$AWAIT3_RC" -ne 0 ] && ok "await exits non-zero on timed-out turn" || fail "await rc on timeout"
echo "$AWAIT3" | grep -q '"status": "timeout"' && ok "result.json status=timeout (hung turn killed)" || fail "timeout result (got: $AWAIT3)"
grep -q '"last_delivery": "timeout"' "$HL_SF" && ok "state records timeout" || fail "state timeout (got: $(cat "$HL_SF"))"

# -- paths with spaces survive spawn -> prompt -> codex argv --
HL_SP="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-16-00_space test-1.md"
sed 's/thread: loop-headless/thread: loop-space/' "$HL_WF" > "$HL_SP"
SP_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless PATH="$STUB_BIN:$PATH" "$RUNPHASE" spawn --message "$HL_SP") )"
SP_DIR="$(rundir_of "$SP_OUT")"
run_rp await "$SP_DIR" --timeout-secs 30 >/dev/null && ok "message path with a space runs end-to-end" || fail "space-path turn (log: $(tail -3 "$SP_DIR/runner.log" 2>/dev/null))"
grep -q 'space\\ test' "$SP_DIR/prompt.md" && ok "prompt shell-quotes the message path" || fail "prompt quoting (got: $(grep 'space' "$SP_DIR/prompt.md" | head -2))"
rm -f "$HL_SP"

# -- one-shot message (no thread): runs fine, creates no state --
HL_Q="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-15-00_ask-q-1.md"
cat > "$HL_Q" <<'MSG'
---
type: question
from: claude
timestamp: 2026-06-04T14:15:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T14-15-00_ask-q-1
---

## Question
Is this fine?
MSG
PRE_STATE_COUNT="$(find "$REPO_FIX/.comms/state" -type f 2>/dev/null | wc -l | tr -d ' ')"
HL_OUTQ="$(run_headless send --to codex "$HL_Q" 2>/dev/null)"
HL_DIRQ="$(rundir_of "$HL_OUTQ")"
run_rp await "$HL_DIRQ" --timeout-secs 30 >/dev/null && ok "one-shot question runs headless" || fail "one-shot headless run"
POST_STATE_COUNT="$(find "$REPO_FIX/.comms/state" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$PRE_STATE_COUNT" = "$POST_STATE_COUNT" ] && ok "one-shot message creates no thread state" || fail "one-shot state leak ($PRE_STATE_COUNT -> $POST_STATE_COUNT)"

# -- replies to the driving session are a pickup no-op (both directions) --
HL_CL="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless COMMS_HEADLESS_PICKUP=claude PATH="$STUB_BIN:$PATH" "$COMMS" deliver claude) )"
echo "$HL_CL" | grep -q "no nudge needed" && ok "reply to a claude driver is a pickup no-op" || fail "claude pickup no-op (got: $HL_CL)"
HL_CX="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless COMMS_HEADLESS_PICKUP=codex PATH="$STUB_BIN:$PATH" "$COMMS" deliver codex) )"
echo "$HL_CX" | grep -q "no nudge needed" && ok "reply to a codex driver is a pickup no-op" || fail "codex pickup no-op (got: $HL_CX)"
# send-level: the reverse-direction pickup gets the expected-manual RESULT, not
# a false "NOT spawned" warning (real-review finding, round 1).
PICKUP_SEND="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless COMMS_HEADLESS_PICKUP=codex PATH="$STUB_BIN:$PATH" "$COMMS" send --to codex "$GOOD") 2>/dev/null | tail -1 )"
case "$PICKUP_SEND" in
  "RESULT: manual — headless mode: the reply is on disk"*) ok "pickup send RESULT promises driver pickup (reverse direction)" ;;
  *) fail "pickup send RESULT (got: $PICKUP_SEND)" ;;
esac
echo "$PICKUP_SEND" | grep -q "NOT spawned" && fail "pickup send must not warn NOT spawned" || ok "pickup send does not warn NOT spawned"

# -- bare deliver codex with an empty inbox: nothing spawned, no crash --
find "$REPO_FIX/.comms/to-codex" -maxdepth 1 -type f -name 'feature-helper-tests_*' -delete
HL_EMPTY="$(run_headless deliver codex)"
echo "$HL_EMPTY" | grep -q "nothing spawned" && ok "headless deliver with empty inbox reports nothing spawned" || fail "empty-inbox headless deliver (got: $HL_EMPTY)"
# Restore one pending to-codex message — the clean tests below assert that
# cleaning claude's side leaves the codex inbox untouched.
cp "$HL_Q" "$REPO_FIX/.comms/to-codex/$(basename "$HL_Q")" 2>/dev/null || cat > "$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-20-00_restore-1.md" <<'MSG'
---
type: question
from: claude
timestamp: 2026-06-04T14:20:00Z
workspace: feature-helper-tests
---

## Question
Restore fixture for the clean tests.
MSG

# -- missing runphase.sh degrades to manual pickup with a warning --
LONELY="$WORK/lonely"
mkdir -p "$LONELY"
cp "$COMMS" "$LONELY/comms.sh" && chmod +x "$LONELY/comms.sh"
LONE_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless "$LONELY/comms.sh" deliver codex) 2>&1 )"
echo "$LONE_OUT" | grep -q "runphase.sh not found" && ok "missing runphase degrades with an explicit warning" || fail "missing runphase warning (got: $LONE_OUT)"

# -- missing .comms/to-codex dir: bare headless deliver must not die silently --
NODIR_FIX="$WORK/nodir-repo"
mkdir -p "$NODIR_FIX"
git -C "$NODIR_FIX" init -q -b main
git -C "$NODIR_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
NODIR_OUT="$( (cd "$NODIR_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless PATH="$STUB_BIN:$PATH" "$COMMS" deliver codex) 2>&1 )"
NODIR_RC=$?
[ "$NODIR_RC" -eq 0 ] && ok "headless deliver survives a repo with no .comms (rc=0)" || fail "no-.comms headless deliver rc=$NODIR_RC"
echo "$NODIR_OUT" | grep -q "nothing spawned" && ok "no-.comms headless deliver says nothing spawned" || fail "no-.comms output (got: $NODIR_OUT)"

echo "== runphase step 2: claude backend, direction pickup, hold, watchdog =="
# claude stub: mirrors the codex stub — init event carries session_id, result
# event ends the turn. Toggles: CLAUDE_STUB_FAIL, CLAUDE_STUB_HANG.
cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/bash
{ echo "claude-argv: $*"; echo "claude-env: CLAUDECODE=${CLAUDECODE:-unset}"; } >> "$CODEX_STUB_LOG"
cat > /dev/null
# Real claude emits init promptly, then works — hang AFTER init so a timeout
# still has a session id to capture.
echo '{"type":"system","subtype":"init","session_id":"stub-claude-session-7"}'
[ -n "${CLAUDE_STUB_HANG:-}" ] && sleep "$CLAUDE_STUB_HANG"
if [ -n "${CLAUDE_STUB_FAIL:-}" ]; then
  echo '{"type":"result","subtype":"error","is_error":true}'
  exit 1
fi
echo '{"type":"result","subtype":"success","is_error":false}'
exit 0
STUB
chmod +x "$STUB_BIN/claude"

# -- reverse direction: codex-authored review request pending in to-claude --
RV="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T15-00-00_rev-review-1.md"
cat > "$RV" <<'MSG'
---
type: review-request
from: codex
timestamp: 2026-06-04T15:00:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T15-00-00_rev-review-1
thread: loop-reverse
workflow: auto-implement
phase: implement
round: 1
max-rounds: 10
verdict: REQUEST_CHANGES
---

## Findings
Reverse-direction fixture.
MSG
RV_OUT="$(run_headless send --to claude "$RV" 2>/dev/null)"
RV_TAIL="$(echo "$RV_OUT" | tail -1)"
case "$RV_TAIL" in "RESULT: spawned"*) ok "reverse-direction headless send spawns a claude turn" ;; *) fail "reverse RESULT (got: $RV_TAIL)" ;; esac
RV_DIR="$(rundir_of "$RV_OUT")"
RV_SF="$REPO_FIX/.comms/state/feature-helper-tests_loop-reverse.json"
grep -q '"last_run_dir": "/' "$RV_SF" && ok "state records last_run_dir for the watchdog" || fail "state last_run_dir (got: $(cat "$RV_SF" 2>/dev/null))"
run_rp await "$RV_DIR" --timeout-secs 30 >/dev/null && ok "claude turn completes" || fail "claude turn await (log: $(tail -3 "$RV_DIR/runner.log" 2>/dev/null))"
grep -q '"provider": "claude"' "$RV_DIR/result.json" && ok "result.json records provider=claude" || fail "result provider (got: $(cat "$RV_DIR/result.json"))"
grep -q '"session_id": "stub-claude-session-7"' "$RV_DIR/result.json" && ok "claude session id captured from init event" || fail "claude session capture"
grep -q 'claude-argv: -p --verbose --output-format stream-json --permission-mode acceptEdits --allowedTools Bash' "$CODEX_STUB_LOG" && ok "claude invoked with stream-json + non-bypass policy" || fail "claude argv (got: $(grep claude-argv "$CODEX_STUB_LOG" | tail -1))"
grep -q 'claude-env: CLAUDECODE=unset' "$CODEX_STUB_LOG" && ok "CLAUDECODE unset for the nested claude child" || fail "CLAUDECODE nesting (got: $(grep claude-env "$CODEX_STUB_LOG" | tail -1))"
grep -q '"claude_session_id": "stub-claude-session-7"' "$RV_SF" && ok "state records claude_session_id" || fail "state claude_session_id (got: $(cat "$RV_SF"))"
grep -q '"last_delivery": "completed"' "$RV_SF" && ok "reverse turn mirrored completed into state" || fail "reverse state completed"
grep -q "$(basename "$RV")" "$RV_DIR/prompt.md" && grep -q "read-from-codex" "$RV_DIR/prompt.md" && ok "claude prompt references the claude-side command files" || fail "claude prompt content"
grep -q -- '--to codex' "$RV_DIR/prompt.md" && ok "claude prompt routes the reply to codex" || fail "claude prompt reply direction"

# -- claude failed turn: provider-keyed recording (real-review coverage gap) --
RVF="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T15-02-00_rev-fail-1.md"
sed 's/rev-review-1/rev-fail-1/' "$RV" > "$RVF"
RVF_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless CLAUDE_STUB_FAIL=1 PATH="$STUB_BIN:$PATH" "$COMMS" send --to claude "$RVF") 2>/dev/null )"
RVF_DIR="$(rundir_of "$RVF_OUT")"
run_rp await "$RVF_DIR" --timeout-secs 30 >/dev/null 2>&1 && fail "failed claude turn must await non-zero" || ok "failed claude turn awaits non-zero"
grep -q '"provider": "claude"' "$RVF_DIR/result.json" && grep -q '"status": "failed"' "$RVF_DIR/result.json" && ok "failed claude turn records provider+status" || fail "claude failed result (got: $(cat "$RVF_DIR/result.json" 2>/dev/null))"
grep -q 'claude CLI exited 1' "$RVF_DIR/result.json" && ok "failure note names the claude CLI, not codex" || fail "provider-aware failure note (got: $(grep note "$RVF_DIR/result.json"))"
grep -q '"claude_session_id": "stub-claude-session-7"' "$RV_SF" && grep -q '"last_delivery": "failed"' "$RV_SF" && ok "failed claude turn mirrors state with claude_session_id" || fail "claude failed state (got: $(cat "$RV_SF"))"

# -- claude timeout: hung turn killed, session captured from pre-hang init --
RVT="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T15-03-00_rev-hang-1.md"
sed 's/rev-review-1/rev-hang-1/' "$RV" > "$RVT"
RVT_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless CLAUDE_STUB_HANG=30 COMMS_RUNPHASE_TIMEOUT_SECS=6 PATH="$STUB_BIN:$PATH" "$COMMS" send --to claude "$RVT") 2>/dev/null )"
RVT_DIR="$(rundir_of "$RVT_OUT")"
run_rp await "$RVT_DIR" --timeout-secs 60 >/dev/null 2>&1 && fail "hung claude turn must await non-zero" || ok "hung claude turn awaits non-zero"
grep -q '"status": "timeout"' "$RVT_DIR/result.json" && ok "claude timeout recorded" || fail "claude timeout result (got: $(cat "$RVT_DIR/result.json" 2>/dev/null))"
grep -q '"session_id": "stub-claude-session-7"' "$RVT_DIR/result.json" && ok "session id captured even on timeout (init precedes hang)" || fail "timeout session capture"
grep -q '"last_delivery": "timeout"' "$RV_SF" && ok "claude timeout mirrored into state" || fail "claude timeout state (got: $(cat "$RV_SF"))"

# -- hold: pause at the turn boundary, attach command printed, release resumes --
HOLD_OUT="$(run_rp hold loop-reverse)"
echo "$HOLD_OUT" | grep -q "held: loop-reverse" && ok "hold sets a thread marker" || fail "hold output (got: $HOLD_OUT)"
echo "$HOLD_OUT" | grep -q "claude --resume stub-claude-session-7" && ok "hold prints the exact claude attach command from state" || fail "hold attach print (got: $HOLD_OUT)"
RV2="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T15-05-00_rev-review-2.md"
sed 's/round: 1/round: 2/; s/rev-review-1/rev-review-2/' "$RV" > "$RV2"
HELD_OUT="$(run_headless send --to claude "$RV2" 2>/dev/null)"
HELD_TAIL="$(echo "$HELD_OUT" | tail -1)"
case "$HELD_TAIL" in "RESULT: held"*) ok "send on a held thread reports RESULT: held" ;; *) fail "held RESULT (got: $HELD_TAIL)" ;; esac
echo "$HELD_OUT" | grep -q "spawned runphase" && fail "held send must not spawn" || ok "held send spawns nothing"
grep -q '"last_delivery": "held"' "$RV_SF" && ok "state records held" || fail "state held (got: $(cat "$RV_SF"))"
ST_HELD="$(run_headless status)"
echo "$ST_HELD" | grep -q "ACTION NEEDED" && fail "held thread must not shout ACTION NEEDED" || ok "held thread does not shout"
run_rp release loop-reverse | grep -q "released" && ok "release lifts the hold" || fail "release output"
RES_OUT2="$(run_headless send --to claude "$RV2" 2>/dev/null)"
case "$(echo "$RES_OUT2" | tail -1)" in "RESULT: spawned"*) ok "released thread spawns again" ;; *) fail "post-release send (got: $(echo "$RES_OUT2" | tail -1))" ;; esac
run_rp await "$(rundir_of "$RES_OUT2")" --timeout-secs 30 >/dev/null || true

# -- global hold blocks everything --
run_rp hold >/dev/null
GH_OUT="$(run_headless deliver claude)"
echo "$GH_OUT" | grep -q "HELD:" && ok "global hold blocks all spawns" || fail "global hold (got: $GH_OUT)"
run_rp release >/dev/null

# -- stalled watchdog: dead runner vs finished turn vs live runner --
WD_RUN="$WORK/wd-run"
mkdir -p "$WD_RUN"
echo "999999" > "$WD_RUN/pid"
cat > "$REPO_FIX/.comms/state/feature-helper-tests_loop-watchdog.json" <<JSON
{
  "workspace": "feature-helper-tests",
  "thread": "loop-watchdog",
  "workflow": "auto-implement",
  "phase": "implement",
  "round": "1",
  "max_rounds": "10",
  "status": "in-progress",
  "awaiting_from": "codex",
  "awaiting_since": "2026-06-04T15:00:00Z",
  "awaiting_since_epoch": "$(( $(date +%s) - 3600 ))",
  "last_sent": "x",
  "last_run_dir": "$WD_RUN",
  "last_delivery": "spawned"
}
JSON
run_comms stalled 15 | grep -q "runner DEAD without a result" && ok "watchdog flags a dead runner with no result" || fail "watchdog dead (got: $(run_comms stalled 15))"
echo '{"status": "completed"}' > "$WD_RUN/result.json"
run_comms stalled 15 | grep -q "turn finished: completed" && ok "watchdog reports a finished-but-unread turn" || fail "watchdog finished (got: $(run_comms stalled 15))"
rm -f "$WD_RUN/result.json"
echo "$$" > "$WD_RUN/pid"
run_comms stalled 15 | grep -q "runner alive" && ok "watchdog reports a live runner still working" || fail "watchdog alive (got: $(run_comms stalled 15))"
rm -f "$REPO_FIX/.comms/state/feature-helper-tests_loop-watchdog.json"

# -- bypass/danger permission flags are refused for claude loop turns --
BP_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless COMMS_RUNPHASE_CLAUDE_ARGS="--dangerously-skip-permissions" PATH="$STUB_BIN:$PATH" "$RUNPHASE" spawn --provider claude --message "$RV") )"
BP_DIR="$(rundir_of "$BP_OUT")"
run_rp await "$BP_DIR" --timeout-secs 30 >/dev/null 2>&1 && fail "bypass-flag turn must not complete" || ok "bypass-flag turn refused (await non-zero)"
grep -q "bypass/danger permission flags are refused" "$BP_DIR/runner.log" && ok "refusal names the policy in runner.log" || fail "bypass refusal message (log: $(tail -2 "$BP_DIR/runner.log" 2>/dev/null))"

echo "== loopspec: conformance fixtures =="
if bash "$REPO/docs/loopspec/check.sh" --comms "$COMMS" > "$WORK/loopspec.out" 2>&1; then
  ok "loopspec conformance: $(tail -1 "$WORK/loopspec.out")"
else
  fail "loopspec conformance failed: $(grep '^FAIL' "$WORK/loopspec.out" | head -5 | tr '\n' ' ')"
fi

echo "== templates: bare dollar-digit/dollar-star hygiene =="
# INTERNALS editing rule made mechanical: Claude Code substitutes bare dollar-digit
# tokens (and dollar-star) into command markdown at render time with no escape syntax.
# dollar-paren, dollar-brace, and named variables are fine and must pass.
HYG_HITS="$(grep -rnE '\$[0-9]|\$\*' "$REPO/templates" || true)"
if [ -z "$HYG_HITS" ]; then
  ok "no bare dollar-digit/dollar-star tokens under templates/"
else
  fail "bare dollar token(s) under templates/: $(echo "$HYG_HITS" | head -3 | tr '\n' ' ')"
fi

echo "== /ask canonical template source contract =="
# Prompt templates ARE the executable surface — these pin the load-bearing rules.
ASKF="$REPO/templates/claude-commands/ask.md"
[ -f "$ASKF" ] && ok "ask.md exists" || fail "ask.md exists"
grep -q 'type: question' "$ASKF" && ok "ask.md message skeleton is type: question" || fail "ask.md type: question"
grep -q 'Eligible pair' "$ASKF" && grep -q 'overrides the cap' "$ASKF" \
  && ok "ask.md pins the eligible-pair floor over the soft cap" || fail "ask.md floor-over-cap contract"
grep -q 'question OR request' "$ASKF" && ok "ask.md pair selector covers imperative asks" || fail "ask.md request-or-question wording"
grep -q 'FAIL CLOSED' "$ASKF" && grep -q 'send nothing' "$ASKF" \
  && ok "ask.md fails closed with no eligible pair" || fail "ask.md fail-closed branch"
grep -q 'ENTIRE ORIGINAL argument' "$ASKF" && ok "ask.md preserves full argument on unknown first word" || fail "ask.md unknown-agent fallback"
grep -q 'non-interpolating file-write tool' "$ASKF" && grep -q 'PROVEN absent' "$ASKF" \
  && ok "ask.md requires collision-safe writer" || fail "ask.md write-safety contract"
# Delimiter-agnostic: ANY heredoc operator in ask.md reintroduces the early-close
# risk regardless of the delimiter word chosen, so reject the operator itself.
grep -qE '<<' "$ASKF" && fail "ask.md contains a heredoc operator — the write contract requires a non-interpolating writer" \
  || ok "ask.md carries no heredoc operator at all (delimiter-agnostic guard)"
grep -qF 'send --to "$TARGET"' "$ASKF" && ok "ask.md sends to a variable target" || fail "ask.md variable-target send"
grep -q 'loopspec:fragment result-spawned-exception' "$ASKF" \
  && ok "ask.md embeds the result-spawned-exception fragment" || fail "ask.md fragment embed present"

echo "== /ask-codex deprecated alias contract =="
ALIASF="$REPO/templates/claude-commands/ask-codex.md"
grep -qi 'deprecated' "$ALIASF" && ok "alias declares deprecation" || fail "alias declares deprecation"
grep -qF '`/ask' "$ALIASF" && ok "alias points at /ask" || fail "alias points at /ask"
grep -q 're-run install.sh' "$ALIASF" && ok "alias fails closed on stale install" || fail "alias stale-install fail-closed"
grep -q 'target pinned to codex' "$ALIASF" && ok "alias pins its target to codex" || fail "alias codex-pin instruction"
grep -q 'loopspec:fragment' "$ALIASF" && fail "alias regrew a fragment embed" || ok "alias carries no fragment embed"
grep -q 'type: question' "$ALIASF" && fail "alias regrew a frontmatter skeleton" || ok "alias carries no frontmatter skeleton"

echo "== loopspec: prompt fragments do not drift from docs/loopspec/fragments/ =="
# Every marked region in a template must match its fragment file byte-for-byte
# after per-line leading-whitespace normalization (templates embed at varying
# list indents). Drift is a failing check, not a habit.
FRAG_SEEN="$WORK/fragments-seen"
: > "$FRAG_SEEN"
for tf in "$REPO"/templates/claude-commands/*.md "$REPO"/templates/codex-skills/*/SKILL.md; do
  for name in $(sed -n 's/.*<!-- loopspec:fragment \([a-z0-9-]*\) -->.*/\1/p' "$tf" | sort -u); do
    echo "$name" >> "$FRAG_SEEN"
    frag="$REPO/docs/loopspec/fragments/$name.md"
    if [ ! -f "$frag" ]; then
      fail "template $(basename "$tf") references missing fragment: $name"
      continue
    fi
    want="$(sed 's/^[[:space:]]*//' "$frag")"
    # Compare EVERY marked region — a second embed of the same fragment in one
    # file must be drift-checked too, not just the first.
    count="$(grep -c "<!-- loopspec:fragment $name -->" "$tf" || true)"
    occ=1
    while [ "$occ" -le "$count" ]; do
      got="$(awk -v marker="<!-- loopspec:fragment $name -->" -v occ="$occ" '
        index($0, marker) {n++; if (n==occ) {c=1; next}}
        c && /<!-- \/loopspec:fragment -->/ {exit}
        c {sub(/^[[:space:]]+/, ""); print}' "$tf")"
      if [ "$got" = "$want" ]; then
        ok "fragment $name matches in $(basename "$tf") (region $occ/$count)"
      else
        fail "fragment DRIFT: $name in $(basename "$tf") region $occ — edit docs/loopspec/fragments/$name.md (the normative home) and re-embed"
      fi
      occ=$((occ+1))
    done
  done
done
for frag in "$REPO"/docs/loopspec/fragments/*.md; do
  n="$(basename "$frag" .md)"
  grep -q "^$n$" "$FRAG_SEEN" && ok "fragment $n is embedded by at least one template" || fail "orphan fragment (no template embeds it): $n"
done
# Tripwire: fragment signature phrases must never appear in a template OUTSIDE
# a marked region — an unmarked copy of normative discipline text would silently
# escape the drift check (real-review finding). Signatures are distinctive
# substrings of each fragment; extend this list when adding fragments.
sig_outside_markers() {  # <signature> — prints template:line for hits outside markers
  local sig="$1" tf
  for tf in "$REPO"/templates/claude-commands/*.md "$REPO"/templates/codex-skills/*/SKILL.md; do
    awk -v sig="$sig" -v f="$(basename "$tf")" '
      /<!-- loopspec:fragment / {inm=1}
      /<!-- \/loopspec:fragment -->/ {inm=0; next}
      !inm && index($0, sig) {print f ":" NR}' "$tf"
  done
}
while IFS='|' read -r sig label; do
  [ -n "$sig" ] || continue
  HITS="$(sig_outside_markers "$sig")"
  if [ -z "$HITS" ]; then
    ok "no unmarked copies of $label discipline in templates"
  else
    fail "unmarked $label discipline text in templates (wrap in loopspec:fragment markers): $(echo "$HITS" | tr '\n' ' ')"
  fi
done <<'SIGS'
RESULT: spawned|result-spawned
truly ship-stopping|verdict-discipline
blank checklist|holistic-rereview
SIGS

echo "== comms.sh: bounded reads (lessons) =="
# The whole point of these subcommands is a cap that holds no matter how large
# the log grows OR how hostile the arguments are, so the invariant is asserted
# as a byte measurement of stdout AND stderr together — tools return both.
LES="$WORK/lessons"; mkdir -p "$LES"
DIAG_MAX=256
cat > "$LES/adv.md" <<'ADV'
# Advisory carry-over

## 2026-01-01 — oldest dated
old body line

## 2026-05-05 — middle dated
mid body line

## No date in this heading
undated body line

## 2026-09-09 — appended at the BOTTOM, and newest
newest body line
ADV
les() { (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" lessons "$@" >"$WORK/l.out" 2>"$WORK/l.err"); }
les_total() { echo $(( $(wc -c <"$WORK/l.out") + $(wc -c <"$WORK/l.err") )); }

les --file "$LES/adv.md" --bytes 4000; LES_RC=$?
[ "$LES_RC" = 0 ] && ok "lessons exits 0 when everything fits" || fail "lessons exit 0 when it fits (got $LES_RC)"
ORDER="$(grep '^## ' "$WORK/l.out" | head -4 | tr '\n' '|')"
case "$ORDER" in
  "## 2026-09-09"*"## 2026-05-05"*"## 2026-01-01"*"## No date"*)
    ok "lessons sorts newest-first by heading date; a BOTTOM-appended entry still comes first" ;;
  *) fail "lessons ordering (got: $ORDER)" ;;
esac
grep -q "^## No date in this heading" "$WORK/l.out" \
  && ok "lessons sorts an undated heading LAST but never drops it" || fail "lessons keeps undated sections"
grep -q "without a date sort last" "$WORK/l.err" \
  && ok "lessons warns about undated sections" || fail "lessons warns about undated sections"

# A tight budget must truncate by whole sections and still report what it left.
# Sections are padded past the budget so this exercises real truncation rather
# than a fixture that happens to fit.
{
  for d in 2026-01-01 2026-05-05 2026-09-09; do
    echo "## $d — padded section"
    for i in 1 2 3 4 5 6; do echo "- padded body line $i for $d, long enough to matter"; done
    echo
  done
} > "$LES/big.md"
les --file "$LES/big.md" --bytes 512; LES_RC=$?
[ "$LES_RC" = 3 ] && ok "lessons exits 3 when truncated" || fail "lessons exit 3 on truncation (got $LES_RC)"
[ "$(wc -c <"$WORK/l.out")" -le 512 ] && ok "lessons stdout respects --bytes exactly" || fail "lessons stdout <= --bytes"
[ "$(les_total)" -le $((512 + DIAG_MAX)) ] \
  && ok "lessons combined stdout+stderr <= --bytes + DIAGNOSTIC_MAX" || fail "lessons combined output bound"
grep -q "omitted" "$WORK/l.out" && ok "lessons names what it omitted in stdout" || fail "lessons names omissions"
# Truncation must never hand back half a bullet that reads like a whole instruction:
# the oldest section is dropped or named, never partially emitted.
check_not "lessons never emits a partial section body" grep -q "padded body line 6 for 2026-01-01" "$WORK/l.out"

# The bound is only a constant if caller-controlled values are clipped first —
# this is the exact hole a plan review caught: --file and --surface are inputs.
LONG_PATH="/tmp/$(printf 'z%.0s' $(seq 1 5000))"
LONG_PAT="$(printf 'q%.0s' $(seq 1 5000))"
les --file "$LONG_PATH"
[ "$(les_total)" -le $((4000 + DIAG_MAX)) ] \
  && ok "lessons clips a pathological --file so the diagnostic stays constant" || fail "lessons clips --file"
les --file "$LES/adv.md" --surface "$LONG_PAT"
[ "$(les_total)" -le $((4000 + DIAG_MAX)) ] \
  && ok "lessons clips a pathological --surface so the diagnostic stays constant" || fail "lessons clips --surface"

les --file "$LES/adv.md" --bytes 511;   [ $? = 2 ] && ok "lessons rejects --bytes below the floor" || fail "lessons --bytes floor"
les --file "$LES/adv.md" --bytes abc;   [ $? = 2 ] && ok "lessons rejects a non-numeric --bytes" || fail "lessons --bytes numeric"
les --file "$LES/adv.md" --surface "";  [ $? = 2 ] && ok "lessons rejects an empty --surface" || fail "lessons empty --surface"
les --badflag;                          [ $? = 2 ] && ok "lessons rejects an unknown flag" || fail "lessons unknown flag"
les --file "$LES/nope.md";              [ $? = 0 ] && ok "lessons is a no-op when the log is absent" || fail "lessons missing file"
les --file "$LES/adv.md" --surface middle
grep -q "2026-05-05" "$WORK/l.out" && ! grep -q "2026-09-09" "$WORK/l.out" \
  && ok "lessons --surface filters to matching sections" || fail "lessons --surface filters"
les --file "$LES/adv.md" --surface ZZnotpresent
[ ! -s "$WORK/l.out" ] && ok "lessons emits nothing when --surface matches nothing" || fail "lessons no-match is empty"

# Project docs belong to the tree under review; .comms stays main-anchored. A
# review running in a linked worktree must not silently read main's lessons.
WT_MAIN="$WORK/wt-main"; mkdir -p "$WT_MAIN"; WT_MAIN="$(cd "$WT_MAIN" && pwd -P)"
git -C "$WT_MAIN" init -q -b main
mkdir -p "$WT_MAIN/docs"; echo '## 2026-01-01 — MAIN tree lesson' > "$WT_MAIN/docs/advisories.md"
git -C "$WT_MAIN" add -A >/dev/null 2>&1
git -C "$WT_MAIN" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$WT_MAIN" worktree add -q -b feat "$WORK/wt-linked" 2>/dev/null
mkdir -p "$WORK/wt-linked/docs"; echo '## 2026-02-02 — WORKTREE lesson' > "$WORK/wt-linked/docs/advisories.md"
WT_OUT="$(cd "$WORK/wt-linked" && env -u CMUX_WORKSPACE_ID "$COMMS" lessons 2>/dev/null | head -1)"
[ "$WT_OUT" = "## 2026-02-02 — WORKTREE lesson" ] \
  && ok "lessons reads the CURRENT worktree's advisories, not the main tree's" || fail "lessons worktree resolution (got: $WT_OUT)"
WT_ROOT="$(cd "$WORK/wt-linked" && env -u CMUX_WORKSPACE_ID "$COMMS" root)"
[ "$WT_ROOT" = "$WT_MAIN/.comms" ] \
  && ok "comms root stays anchored to the MAIN repo from a linked worktree" || fail "root stays main-anchored (got: $WT_ROOT)"

echo "== comms.sh: bounded reads (archive-search) =="
# Ordering across workspaces is the trap: filenames are <workspace>_<ISO>_<slug>,
# so any lexical shortcut sorts by WORKSPACE first and returns the wrong "newest"
# exactly in the multi-workspace case fleet.sh ships.
AS_ARCH="$REPO_FIX/.comms/archive"
mk_arch() { # mk_arch <file> <ts> <thread> <body>
  cat > "$AS_ARCH/$1" <<MSG
---
type: review-feedback
from: codex
timestamp: $2
thread: $3
round: 1
verdict: APPROVE
---

$4
MSG
}
mk_arch "zzz-workspace_2026-01-01T00-00-00_old.md"  "2026-01-01T00:00:00Z" "old-thread"  "widget handling notes"
mk_arch "aaa-workspace_2026-12-31T00-00-00_new.md"  "2026-12-31T00:00:00Z" "new-thread"  "widget handling notes"
ars() { (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" archive-search "$@" >"$WORK/a.out" 2>"$WORK/a.err"); }
ars widget
FIRST_HIT="$(head -1 "$WORK/a.out")"
case "$FIRST_HIT" in
  new-thread*) ok "archive-search returns the globally newest match across workspaces" ;;
  *) fail "archive-search cross-workspace ordering (got: $FIRST_HIT)" ;;
esac
grep -q '\.comms/archive/' "$WORK/a.out" \
  && ok "archive-search prints a repo-relative path so the follow-up read is actionable" || fail "archive-search path"
ars widget --limit 1
[ "$(grep -c 'thread' "$WORK/a.out")" -ge 1 ] && ok "archive-search honours --limit" || fail "archive-search --limit"
head -1 "$WORK/a.out" | grep -q '^new-thread' \
  && ok "archive-search applies --limit AFTER the global sort, not before" || fail "archive-search limit-after-sort"
ars widget --bytes 600
[ "$(( $(wc -c <"$WORK/a.out") + $(wc -c <"$WORK/a.err") ))" -le $((600 + DIAG_MAX)) ] \
  && ok "archive-search combined output <= --bytes + DIAGNOSTIC_MAX" || fail "archive-search combined bound"
ars ZZnotpresent; [ $? = 0 ] && ok "archive-search is a no-op when nothing matches" || fail "archive-search no-match"
# Flags and shell options are among the most useful things to search this archive
# for, so a literal pattern starting with '-' must be reachable.
mk_arch "aaa-workspace_2026-12-30T00-00-00_flag.md" "2026-12-30T00:00:00Z" "flag-thread" "used --archive-inbound here"
ars -- --archive-inbound
if [ $? = 0 ] && grep -q 'flag-thread' "$WORK/a.out"; then
  ok "archive-search finds a literal pattern starting with '-' after a -- terminator"
else
  fail "archive-search -- <dash-pattern>"
fi
ars --archive-inbound; [ $? = 2 ] \
  && ok "archive-search still rejects an unknown option without --" || fail "archive-search unknown option"
rm -f "$AS_ARCH/aaa-workspace_2026-12-30T00-00-00_flag.md"
ars; [ $? = 2 ] && ok "archive-search requires a pattern" || fail "archive-search requires pattern"
ars widget --limit 0; [ $? = 2 ] && ok "archive-search rejects --limit 0" || fail "archive-search --limit 0"
rm -f "$AS_ARCH/zzz-workspace_2026-01-01T00-00-00_old.md" "$AS_ARCH/aaa-workspace_2026-12-31T00-00-00_new.md"

echo "== comms.sh: help prints its whole header =="
HELP_OUT="$(cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" help)"
echo "$HELP_OUT" | grep -q 'archive-search' \
  && ok "help lists the last subcommand (no fixed-range truncation)" || fail "help truncates its own header"

echo "== install.sh: .codex/AGENTS.md managed block =="
# Rewriting a file the user may have hand-edited is the risk, so ownership is
# proven rather than assumed. The load-bearing case is the hand-edited one.
AG="$WORK/agents"; mkdir -p "$AG"
AG_B='<!-- agent-comms:begin -->'
AG_E='<!-- agent-comms:end -->'
ag_install() { (cd "$1" && bash "$REPO/install.sh" --scope=project >"$WORK/ag.out" 2>&1); }
ag_repo() { mkdir -p "$AG/$1" && git -C "$AG/$1" init -q -b main && mkdir -p "$AG/$1/.codex"; }

ag_repo fresh; ag_install "$AG/fresh"
grep -q 'agent-comms:begin' "$AG/fresh/.codex/AGENTS.md" \
  && ok "AGENTS.md is created with a marked managed block" || fail "AGENTS.md created marked"
AG_SUM="$(cat "$AG/fresh/.codex/AGENTS.md")"
ag_install "$AG/fresh"
[ "$AG_SUM" = "$(cat "$AG/fresh/.codex/AGENTS.md")" ] \
  && ok "a repeat install leaves AGENTS.md byte-identical (no-op diff)" || fail "AGENTS.md repeat install no-op"

# Legacy text an older installer wrote — safe to migrate because it is provably ours.
AG_LEGACY='## Agent Communication Protocol

This project uses a local file-based message queue for communication between Claude Code and Codex, with optional cmux auto-delivery.

- **Your inbox:** `.comms/to-codex/` — Claude writes review requests and responses here
- **Your outbox:** `.comms/to-claude/` — Write your findings and feedback here

**Skills:**
- `$read-from-claude` — Read the latest message from Claude Code and act on it
- `$send-to-claude` — Write your findings back to Claude Code and auto-deliver via cmux when available

**Auto-delivery:** When `cmux` is available, `$send-to-claude` automatically types `/read-from-codex` into Claude'"'"'s pane. Without `cmux`, messages are still written to `.comms/` for manual pickup.

When the user asks you to "check for messages from Claude" or "review what Claude did", use `$read-from-claude`. After completing a review, use `$send-to-claude` to send your findings back.'

ag_repo legacy; printf '%s\n' "$AG_LEGACY" > "$AG/legacy/.codex/AGENTS.md"
AG_BEFORE="$(wc -c <"$AG/legacy/.codex/AGENTS.md")"
ag_install "$AG/legacy"
grep -q 'agent-comms:begin' "$AG/legacy/.codex/AGENTS.md" \
  && ok "an exact legacy block is migrated to a managed block" || fail "legacy migration"
[ "$(wc -c <"$AG/legacy/.codex/AGENTS.md")" -lt "$AG_BEFORE" ] \
  && ok "the migrated AGENTS.md block is smaller than the legacy one" || fail "AGENTS.md shrinks"

# THE one that must never regress: a hand-edited section carries the user's own
# rules, so it is left completely alone rather than rewritten from under them.
ag_repo handedited
{ printf '%s\n' "$AG_LEGACY"; echo; echo '- MY OWN RULE: always run the full suite before replying'; } \
  > "$AG/handedited/.codex/AGENTS.md"
cp "$AG/handedited/.codex/AGENTS.md" "$WORK/handedited.bak"
ag_install "$AG/handedited"
cmp -s "$AG/handedited/.codex/AGENTS.md" "$WORK/handedited.bak" \
  && ok "a HAND-EDITED protocol section is left byte-identical (no data loss)" || fail "hand-edited AGENTS.md was rewritten"
grep -qi 'hand-edited' "$WORK/ag.out" \
  && ok "install explains why it skipped the hand-edited block" || fail "install explains the skip"

# Every marker shape that is NOT exactly one begin above one end must leave the
# file byte-identical. Nested and duplicated pairs, and marker text quoted inside
# a user's Markdown, both destroyed user content before these fixtures existed.
ag_marker_safe() { # ag_marker_safe <name> <must-survive-string>
  local name="$1" keep="$2"
  cp "$AG/$name/.codex/AGENTS.md" "$WORK/$name.bak"
  ag_install "$AG/$name"
  if cmp -s "$AG/$name/.codex/AGENTS.md" "$WORK/$name.bak"; then
    ok "AGENTS.md $name marker shape is fail-safe (byte-identical)"
  else
    fail "AGENTS.md $name marker shape rewrote the file"
  fi
  grep -qF "$keep" "$AG/$name/.codex/AGENTS.md" \
    && ok "AGENTS.md $name keeps user content" || fail "AGENTS.md $name LOST user content"
}

ag_repo onesided
{ echo '<!-- agent-comms:begin -->'; echo '## Agent Communication Protocol'; echo 'USER KEEP onesided'; } \
  > "$AG/onesided/.codex/AGENTS.md"
ag_marker_safe onesided 'USER KEEP onesided'

ag_repo nested
{ echo '<!-- agent-comms:begin -->'; echo '- USER KEEP nested A'
  echo '<!-- agent-comms:begin -->'; echo '- rule B'
  echo '<!-- agent-comms:end -->';   echo '- rule C'
  echo '<!-- agent-comms:end -->'; } > "$AG/nested/.codex/AGENTS.md"
ag_marker_safe nested 'USER KEEP nested A'

ag_repo dupends
{ echo '<!-- agent-comms:begin -->'; echo '- USER KEEP dupends'
  echo '<!-- agent-comms:end -->';   echo '<!-- agent-comms:end -->'; } > "$AG/dupends/.codex/AGENTS.md"
ag_marker_safe dupends 'USER KEEP dupends'

ag_repo outoforder
{ echo '<!-- agent-comms:end -->'; echo '- USER KEEP outoforder'
  echo '<!-- agent-comms:begin -->'; } > "$AG/outoforder/.codex/AGENTS.md"
ag_marker_safe outoforder 'USER KEEP outoforder'

# Marker text quoted inside prose is documentation, not ownership: recognizing it
# as a block replaced the user's example AND the private rule between the quotes.
ag_repo inline
{ echo '# My AGENTS'
  echo 'Example: `<!-- agent-comms:begin -->` opens the block.'
  echo '- USER KEEP inline private rule'
  echo 'Example: `<!-- agent-comms:end -->` closes it.'; } > "$AG/inline/.codex/AGENTS.md"
ag_install "$AG/inline"
grep -qF 'USER KEEP inline private rule' "$AG/inline/.codex/AGENTS.md" \
  && ok "AGENTS.md inline marker EXAMPLES never count as ownership" || fail "AGENTS.md inline example destroyed user content"
grep -qF 'Example: `<!-- agent-comms:begin -->` opens the block.' "$AG/inline/.codex/AGENTS.md" \
  && ok "AGENTS.md inline marker example text is preserved verbatim" || fail "AGENTS.md inline example text lost"

# Markers on their own lines INSIDE a fenced code block are documentation about
# the block, not the block itself. Treating them as owned rewrote the fence's
# contents in place (reproduced). Every original line must survive verbatim —
# asserted as a prefix check, not just a sentinel grep.
ag_fenced() { # ag_fenced <name> <sentinel>
  local name="$1" keep="$2" orig
  orig="$(wc -l <"$AG/$name/.codex/AGENTS.md")"
  cp "$AG/$name/.codex/AGENTS.md" "$WORK/$name.bak"
  ag_install "$AG/$name"
  if head -n "$orig" "$AG/$name/.codex/AGENTS.md" | cmp -s - "$WORK/$name.bak"; then
    ok "AGENTS.md $name fence: every original line survives verbatim"
  else
    fail "AGENTS.md $name fence: original content was modified"
  fi
  grep -qF "$keep" "$AG/$name/.codex/AGENTS.md" \
    && ok "AGENTS.md $name fence keeps the user sentinel" || fail "AGENTS.md $name fence LOST the sentinel"
}

ag_repo fencedbt
{ echo '# Documentation'; echo '```markdown'; echo "$AG_B"; echo 'USER KEEP fenced backtick'
  echo "$AG_E"; echo '```'; echo '- private rule after example'; } > "$AG/fencedbt/.codex/AGENTS.md"
ag_fenced fencedbt 'USER KEEP fenced backtick'

ag_repo fencedtilde
{ echo '# Documentation'; echo '~~~markdown'; echo "$AG_B"; echo 'USER KEEP fenced tilde'
  echo "$AG_E"; echo '~~~'; } > "$AG/fencedtilde/.codex/AGENTS.md"
ag_fenced fencedtilde 'USER KEEP fenced tilde'

# A longer outer fence wrapping a shorter inner one must nest, not close early.
ag_repo fencednested
{ echo '# Documentation'; echo '````text'; echo '```markdown'; echo "$AG_B"
  echo 'USER KEEP nested fence'; echo "$AG_E"; echo '```'; echo '````'; } > "$AG/fencednested/.codex/AGENTS.md"
ag_fenced fencednested 'USER KEEP nested fence'

# A legacy heading quoted in a fence is an example too.
ag_repo fencedlegacy
{ echo '# Documentation'; echo '```markdown'; echo '## Agent Communication Protocol'
  echo 'USER KEEP fenced legacy'; echo '```'; } > "$AG/fencedlegacy/.codex/AGENTS.md"
ag_fenced fencedlegacy 'USER KEEP fenced legacy'

# An unclosed fence makes inside/outside undecidable — fail safe, write nothing.
ag_repo fenceunclosed
{ echo '# Documentation'; echo '```markdown'; echo "$AG_B"; echo 'USER KEEP unclosed fence'; } \
  > "$AG/fenceunclosed/.codex/AGENTS.md"
cp "$AG/fenceunclosed/.codex/AGENTS.md" "$WORK/fenceunclosed.bak"
ag_install "$AG/fenceunclosed"
cmp -s "$AG/fenceunclosed/.codex/AGENTS.md" "$WORK/fenceunclosed.bak" \
  && ok "AGENTS.md an unclosed fence is fail-safe (byte-identical)" || fail "AGENTS.md unclosed fence rewrote the file"
grep -qi 'unclosed' "$WORK/ag.out" \
  && ok "install explains the unclosed-fence skip" || fail "install explains unclosed fence"

# After appending alongside a fenced example the file holds TWO begin markers —
# one documentation, one live. A second install must resolve to the live one and
# be a no-op, or fence awareness has merely moved the ambiguity.
cp "$AG/fencedbt/.codex/AGENTS.md" "$WORK/fencedbt.after1"
ag_install "$AG/fencedbt"
cmp -s "$AG/fencedbt/.codex/AGENTS.md" "$WORK/fencedbt.after1" \
  && ok "AGENTS.md stays idempotent when a fenced marker example sits beside the live block" \
  || fail "AGENTS.md second install changed the file next to a fenced example"
grep -qF 'USER KEEP fenced backtick' "$AG/fencedbt/.codex/AGENTS.md" \
  && ok "AGENTS.md fenced example survives the second install too" || fail "AGENTS.md fenced example lost on second pass"

# Fence awareness must not break the real thing.
ag_repo realblock
{ echo "$AG_B"; echo 'stale generated text'; echo "$AG_E"; } > "$AG/realblock/.codex/AGENTS.md"
ag_install "$AG/realblock"
grep -q 'Local file-based message queue' "$AG/realblock/.codex/AGENTS.md" \
  && ok "a genuine marked block is still refreshed after the fence fix" || fail "fence fix broke real block management"

ag_repo mixed
{ echo '# Project AGENTS'; echo; echo '## House rules'; echo '- run mix format'; echo;
  printf '%s\n' "$AG_LEGACY"; echo; echo '## Deploy'; echo '- fly deploy'; } \
  > "$AG/mixed/.codex/AGENTS.md"
ag_install "$AG/mixed"
if grep -q 'House rules' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'run mix format' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'Deploy' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'fly deploy' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'agent-comms:begin' "$AG/mixed/.codex/AGENTS.md"; then
  ok "migration preserves unrelated content on both sides of the legacy block"
else
  fail "migration lost unrelated AGENTS.md content"
fi

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
