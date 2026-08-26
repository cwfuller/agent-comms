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

# Loops became headless-first on 2026-08-25, so the pane path is now OPT-IN. The cmux
# sections below exercise pane mechanics that still exist and still matter, so they ask
# for cmux explicitly instead of relying on a default that no longer points at them.
# Sections that test the DEFAULT routing clear this with `env -u COMMS_DELIVERY`.
export COMMS_DELIVERY=cmux

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMS="$REPO/helpers/comms.sh"
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
# Direction awareness must survive a THIRD agent: the old rule derived the sender
# as "the other one of exactly two", so registering grok silently turned the hint
# unfiltered and it started reporting the reader's own message back at it.
printf 'agents = claude codex grok\n' > "$REPO_FIX/.comms/config"
ARCH_HINT3="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" list --as codex --thread archive-order) 2>&1 1>/dev/null || true)"
rm -f "$REPO_FIX/.comms/config"
echo "$ARCH_HINT3" | grep -q "$(basename "$ARCH_NEW")" \
  && ok "archive hint stays direction-aware with three agents registered" || fail "3-agent archive hint (got: $ARCH_HINT3)"
echo "$ARCH_HINT3" | grep -q "$(basename "$ARCH_WRONG_DIRECTION")" \
  && fail "3-agent hint crossed reader direction" || ok "3-agent hint excludes the reader's own messages"

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
[ -f "$INST_FIX/.claude/commands/auto.md" ] && ok "local scope installs commands" || fail "local scope installs commands"
[ -f "$INST_FIX/.claude/commands/ask.md" ] && ok "local scope installs /ask" || fail "local scope installs ask.md"
# The collapse deleted five commands; installing a removed one would resurrect it.
for dead in auto-plan.md auto-full.md auto-implement.md fleet.md ask-codex.md; do
  [ -f "$INST_FIX/.claude/commands/$dead" ] && fail "removed command $dead was installed" || ok "removed command $dead stays removed"
done
echo "$LOCAL_OUT" | grep -qi "shadow" && ok "local scope prints pin/shadow note" || fail "local scope prints pin/shadow note"

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
[ -f "$GHOME/commands/auto.md" ] && ok "global scope installs commands (env-overridden)" || fail "global scope installs commands"
[ -f "$GHOME/commands/ask.md" ] && ok "global scope installs /ask" || fail "global scope installs ask.md"
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
[ "$WS_STICKY" = "test-project" ] && ok "cached identity survives a flaky tree (no cached-name/default-branch flap)" || fail "cached identity sticks (got: $WS_STICKY)"
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
echo "$LONE_OUT" | grep -q "runphase.sh was not found" && ok "missing runphase degrades with an explicit warning" || fail "missing runphase warning (got: $LONE_OUT)"
# The warning must not claim an env var the operator did not set — headless is the
# default now, so naming COMMS_DELIVERY=headless as the cause is simply wrong.
echo "$LONE_OUT" | grep -q "COMMS_DELIVERY=headless but" && fail "warning still blames an unset env var" || ok "missing-runner warning states the default, not a phantom env var"

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

echo "== multi-agent: registry contract =="
MA_FIX="$WORK/ma-repo"; mkdir -p "$MA_FIX"; MA_FIX="$(cd "$MA_FIX" && pwd -P)"
git -C "$MA_FIX" init -q -b feature/ma-tests
git -C "$MA_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$MA_FIX/.comms/to-claude" "$MA_FIX/.comms/to-codex" "$MA_FIX/.comms/archive"
run_ma() { (cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }
MA_WS="$(run_ma workspace)"

[ "$(run_ma agents)" = "claude codex grok" ] && ok "zero-config agents default includes grok" || fail "zero-config agents (got: $(run_ma agents))"
[ "$(run_ma agents default)" = "codex" ] && ok "zero-config default target" || fail "zero-config default target"
run_ma agents --supported | grep -q 'grok' && ok "supported table lists grok" || fail "supported table lists grok"

printf 'agents = claude codex grok\ndefault-target = codex\n' > "$MA_FIX/.comms/config"
[ "$(run_ma agents)" = "claude codex grok" ] && ok "registry registers grok" || fail "registry registers grok (got: $(run_ma agents))"
printf 'agents = claude Codex\n' > "$MA_FIX/.comms/config"
check_not "uppercase agent name rejected" run_ma agents
printf 'agents = claude ../evil\n' > "$MA_FIX/.comms/config"
check_not "path-traversal agent name rejected" run_ma agents
printf 'agents = claude co.dex\n' > "$MA_FIX/.comms/config"
check_not "dotted agent name rejected" run_ma agents
printf 'agents = claude gemini\n' > "$MA_FIX/.comms/config"
check_not "unsupported agent (gemini) rejected at parse" run_ma agents
printf 'agents = claude codex claude\n' > "$MA_FIX/.comms/config"
check_not "duplicate agent rejected" run_ma agents
printf 'agents = claude codex\nagents = claude\n' > "$MA_FIX/.comms/config"
check_not "duplicate agents key rejected" run_ma agents
printf 'agents = claude codex grok\ndefault-target = grok claude\n' > "$MA_FIX/.comms/config"
check_not "multi-word default-target rejected" run_ma agents default
printf 'agents = claude codex\ndefault-target = grok\n' > "$MA_FIX/.comms/config"
check_not "unregistered default-target rejected" run_ma agents default
printf 'agents = claude codex\ndefault-target = gemini\n' > "$MA_FIX/.comms/config"
check_not "malformed default-target propagates through status" run_ma status
check_not "malformed default-target propagates through list" run_ma list --as claude
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$MA_FIX/.comms/config"
check_not "unknown agent dies on inbox use" run_ma list --as gemini

echo "== multi-agent: sender enforcement + grok inbox round-trip =="
MA_TS="2026-08-20T09-00-00"
MA_MSG="$MA_FIX/.comms/to-grok/${MA_WS}_${MA_TS}_review-req-1.md"
mkdir -p "$MA_FIX/.comms/to-grok"
cat > "$MA_MSG" <<MAEOF
---
type: review-request
from: claude
timestamp: 2026-08-20T14:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_${MA_TS}_review-req-1
thread: ma-arc-1
workflow: auto-full
phase: plan
round: 1
max-rounds: 4
---

## Plan
review this plan
MAEOF
check "grok inbox lists the message" bash -c "run_ma() { (cd '$MA_FIX' && env -u CMUX_WORKSPACE_ID '$COMMS' \"\$@\"); }; run_ma list --as grok | grep -q review-req-1"
BAD_FROM="$MA_FIX/.comms/to-claude/${MA_WS}_${MA_TS}_badfrom-1.md"
sed 's/^from: claude$/from: gemini/' "$MA_MSG" > "$BAD_FROM"
check_not "validate rejects unregistered from:" run_ma validate "$BAD_FROM"
rm -f "$BAD_FROM"

echo "== multi-agent: grok stub + full-arc runphase legs =="
export GROK_STUB_LOG="$WORK/grok.log"
cat > "$STUB_BIN/grok" <<'GSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "${GROK_STUB_LOG:-/dev/null}"
pf=""; prev=""
for a in "$@"; do [ "$prev" = "--prompt-file" ] && pf="$a"; prev="$a"; done
[ -n "$pf" ] && [ -f "$pf" ] || { echo "stub: no prompt file" >&2; exit 2; }
# streaming-messages-json shape (live 1.0.5): init event carries session_id and
# the final result event carries the COMPLETE reply text. Under the
# parent-stamped envelope the child emits ONLY a VERDICT line (reviews) + body.
esc() { printf '%s' "$1" | awk '{printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-grok-session-1"}\n'
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"narration to ignore"}]}}\n'
if [ -n "${GROK_STUB_NO_VERDICT:-}" ]; then
  REPLY="$(printf -- '## Summary\nreview without any verdict line')"
elif [ -n "${GROK_STUB_BAD_VERDICT:-}" ]; then
  REPLY="$(printf -- 'VERDICT: SHIP_IT\n\n## Summary\nnonstandard verdict value')"
elif [ -n "${GROK_STUB_EMPTY_BODY:-}" ]; then
  REPLY="$(printf -- 'VERDICT: APPROVE')"
else
  REPLY="$(printf -- 'VERDICT: %s\n\n## Summary\nstub review of the handoff\n\n## Findings\n### Blocking\n- none' "${GROK_STUB_VERDICT:-APPROVE}")"
fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
GSTUB
chmod +x "$STUB_BIN/grok"

RP="$REPO/helpers/runphase.sh"
run_grok_leg() {  # <msg-path> <run-dir> [env overrides via caller export]
  (cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" \
     COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$1" --dir "$2" --provider grok)
}

# Leg 1: plan round 1 -> REQUEST_CHANGES reply lands for claude, inbound archived
R1="$WORK/ma-leg1"; mkdir -p "$R1"
GROK_STUB_VERDICT=REQUEST_CHANGES run_grok_leg "$MA_MSG" "$R1" >/dev/null 2>&1
[ "$(cd "$MA_FIX" && "$COMMS" root >/dev/null 2>&1; echo done)" = done ] || true
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R1/result.json" | head -1)" = "completed" ] \
  && ok "grok leg 1 completes" || fail "grok leg 1 result (see $R1/result.json)"
REPLY1="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f | head -1)"
[ -n "$REPLY1" ] && ok "grok reply persisted to claude inbox by the PARENT" || fail "grok reply persisted"
grep -q '^from: grok$' "$REPLY1" && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY1" \
  && ok "reply carries grok identity and stub verdict" || fail "reply identity/verdict"
grep -q '^thread: ma-arc-1$' "$REPLY1" && ok "reply copies the thread" || fail "reply thread copy"
[ ! -f "$MA_MSG" ] && [ -f "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" ] \
  && ok "inbound archived from to-grok by owner derivation" || fail "inbound archive movement"
STATE1="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_ma-arc-1.json"
grep -q '"awaiting_from": "claude"' "$STATE1" && ok "awaiting_from = explicit send target (claude)" || fail "awaiting_from authority (see $STATE1)"
grep -q '"grok_session_id": "stub-grok-session-1"' "$STATE1" && ok "generic grok_session_id recorded" || fail "grok session field"
grep -q -- '--sandbox read-only' "$GROK_STUB_LOG" && grep -q -- '--permission-mode dontAsk' "$GROK_STUB_LOG" \
  && grep -q -- '--output-format streaming-messages-json' "$GROK_STUB_LOG" \
  && ok "grok argv pins read-only sandbox + dontAsk + whole-message format" || fail "grok argv sandbox/mode/format"
grep -q -- "--deny Bash(rm \*) --deny Bash(git push\*)" "$GROK_STUB_LOG" \
  && ok "grok argv carries both deny rules" || fail "grok argv deny rules"
grep -qE '(^| )-p( |$)' "$GROK_STUB_LOG" && fail "grok argv must not use -p" || ok "grok argv avoids -p (prompt-file only)"

# Leg 2a: plan round 2 — built the way the READER builds it: reviewer derived
# from the round-1 reply's from:, round incremented, in-reply-to threaded.
LEG2_REVIEWER="$(sed -n '2,/^---$/p' "$REPLY1" | grep -m1 '^from:' | sed 's/^from: //')"
[ "$LEG2_REVIEWER" = "grok" ] && ok "reader-side reviewer derivation from the grok reply" || fail "reviewer derivation (got: $LEG2_REVIEWER)"
REPLY1_ID="$(sed -n '2,/^---$/p' "$REPLY1" | grep -m1 '^message_id:' | sed 's/^message_id: //')"
MA_MSG2="$MA_FIX/.comms/to-$LEG2_REVIEWER/${MA_WS}_2026-08-20T09-10-00_plan-r2-1.md"
sed -e 's/^round: 1$/round: 2/' -e "s/^message_id: .*/message_id: ${MA_WS}_2026-08-20T09-10-00_plan-r2-1/" \
    -e "s/^in-reply-to: .*/in-reply-to: $REPLY1_ID/" \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG2"
grep -q '^in-reply-to:' "$MA_MSG2" || sed -i.bak "s/^thread: ma-arc-1\$/thread: ma-arc-1\nin-reply-to: $REPLY1_ID/" "$MA_MSG2"
R2A="$WORK/ma-leg2a"; mkdir -p "$R2A"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSG2" "$R2A" >/dev/null 2>&1
REPLY2="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f ! -path "$REPLY1" | sort | tail -1)"
[ -n "$REPLY2" ] && [ "$REPLY2" != "$REPLY1" ] && grep -q '^verdict: APPROVE$' "$REPLY2" \
  && grep -q '^round: 2$' "$REPLY2" \
  && ok "plan round 2 approved by the same reviewer" || fail "plan round-2 leg"
[ -f "$MA_FIX/.comms/archive/$(basename "$MA_MSG2")" ] && ok "round-2 inbound archived exactly" || fail "round-2 archive movement"

# Leg 2b: the plan→implement CONTINUATION — implement round 1 to the reviewer
# derived from the APPROVAL (the transition the reader performs), same thread.
LEG2B_REVIEWER="$(sed -n '2,/^---$/p' "$REPLY2" | grep -m1 '^from:' | sed 's/^from: //')"
REPLY2_ID="$(sed -n '2,/^---$/p' "$REPLY2" | grep -m1 '^message_id:' | sed 's/^message_id: //')"
MA_MSG2B="$MA_FIX/.comms/to-$LEG2B_REVIEWER/${MA_WS}_2026-08-20T09-15-00_impl-r1-1.md"
sed -e 's/^phase: plan$/phase: implement/' -e 's/^round: 2$/round: 1/' \
    -e "s/^message_id: .*/message_id: ${MA_WS}_2026-08-20T09-15-00_impl-r1-1/" \
    -e "s/^in-reply-to: .*/in-reply-to: $REPLY2_ID/" \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG2")" > "$MA_MSG2B"
grep -q "^in-reply-to: $REPLY2_ID$" "$MA_MSG2B" \
  && ok "implement continuation threads to the round-2 APPROVAL" || fail "continuation in-reply-to"
R2B="$WORK/ma-leg2b"; mkdir -p "$R2B"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSG2B" "$R2B" >/dev/null 2>&1
REPLY2B="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f | sort | tail -1)"
grep -q '^phase: implement$' "$REPLY2B" && grep -q '^from: grok$' "$REPLY2B" \
  && ok "plan→implement continuation reviewed by the SAME reviewer (full arc)" || fail "implement continuation leg"
STATUS_OUT="$(run_ma status 2>/dev/null)"
echo "$STATUS_OUT" | grep -q 'pending in to-grok' && ok "status iterates the grok inbox" || fail "status grok inbox line"
# Backdate the awaiting epoch so the age is deterministically > threshold —
# a same-second run otherwise races age_s > 0 and sees nothing stalled.
STATE_ARC="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_ma-arc-1.json"
BACKDATE=$(( $(date +%s) - 120 ))
sed -i.bak "s/\"awaiting_since_epoch\": \"[0-9]*\"/\"awaiting_since_epoch\": \"$BACKDATE\"/" "$STATE_ARC" && rm -f "$STATE_ARC.bak"
STALLED_OUT="$(run_ma stalled 1 2>/dev/null)"
echo "$STALLED_OUT" | grep -q 'thread=ma-arc-1' && echo "$STALLED_OUT" | grep -q 'awaiting=claude' \
  && ok "stalled resolves the arc thread with the explicit-target awaiting" || fail "stalled arc lookup (got: $STALLED_OUT)"
MA_MSG2="$MA_MSG2B"

# Leg 3: peer-from-from — inbound from codex routes the reply to to-codex/
MA_MSG3="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-20-00_from-codex-1.md"
# leg 2 archived MA_MSG2 — build leg 3's inbound from the archived copy directly
sed -e 's/^from: claude$/from: codex/' -e 's/^thread: ma-arc-1$/thread: ma-arc-2/' \
    -e 's/_impl-r1-1$/_from-codex-1/' \
    "$MA_FIX/.comms/archive/$(basename "$MA_MSG2")" > "$MA_MSG3"
[ -s "$MA_MSG3" ] || fail "leg-3 fixture construction produced an empty file"
R3="$WORK/ma-leg3"; mkdir -p "$R3"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSG3" "$R3" >/dev/null 2>&1
find "$MA_FIX/.comms/to-codex" -name '*grok-reply*' -type f | grep -q . \
  && ok "pickup peer derives from inbound from: (reply to to-codex/)" || fail "peer-from-from derivation"

# Broker failures under the parent-stamped envelope: the model cannot author
# ANY frontmatter, so the adversarial surface is the verdict-line contract and
# body validity — each must fail with nothing persisted and nothing archived.
MA_MSG4="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-30-00_noverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-3/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG4"
R4="$WORK/ma-leg4"; mkdir -p "$R4"
PRE_CLAUDE_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
GROK_STUB_NO_VERDICT=1 run_grok_leg "$MA_MSG4" "$R4" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R4/result.json" | head -1)" = "failed" ] \
  && grep -q 'no leading' "$R4/result.json" && [ -f "$MA_MSG4" ] \
  && ok "review reply without a VERDICT line fails closed" || fail "missing-verdict broker path"
MA_MSG5="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-35-00_badverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-4/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG5"
R6="$WORK/ma-leg6"; mkdir -p "$R6"
GROK_STUB_BAD_VERDICT=1 run_grok_leg "$MA_MSG5" "$R6" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R6/result.json" | head -1)" = "failed" ] && [ -f "$MA_MSG5" ] \
  && ok "nonstandard verdict value fails closed" || fail "bad-verdict broker path"
MA_MSG7="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-37-00_emptybody-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-5/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG7"
R7="$WORK/ma-leg7"; mkdir -p "$R7"
GROK_STUB_EMPTY_BODY=1 run_grok_leg "$MA_MSG7" "$R7" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R7/result.json" | head -1)" = "failed" ] \
  && grep -q 'failed validation' "$R7/result.json" && [ -f "$MA_MSG7" ] \
  && ok "verdict-only empty body refused by validate" || fail "empty-body broker path"
[ "$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')" = "$PRE_CLAUDE_CT" ] \
  && ok "all broker failures persisted nothing to the claude inbox" || fail "broker-failure persistence atomicity"
# Path-shaped / unregistered inbound from: — refused BEFORE any routing
MA_MSG8="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-39-00_evilfrom-1.md"
sed -e 's|^from: claude$|from: ../evil|' -e 's/^thread: ma-arc-1$/thread: ma-arc-6/' \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG8"
R8="$WORK/ma-leg8"; mkdir -p "$R8"
run_grok_leg "$MA_MSG8" "$R8" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R8/result.json" | head -1)" = "failed" ] \
  && grep -q 'not a registered agent' "$R8/result.json" && [ -f "$MA_MSG8" ] \
  && [ ! -d "$MA_FIX/.comms/to-../evil" ] \
  && ok "path-shaped inbound from: refused before routing" || fail "unregistered-peer refusal"
# Question leg (/ask grok path): the stub STILL emits a leading canonical
# VERDICT line — for a consult that line must become body text, never metadata.
MA_MSGQ="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-41-00_ask-q-1.md"
cat > "$MA_MSGQ" <<QEOF
---
type: question
from: claude
timestamp: 2026-08-20T14:41:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-20T09-41-00_ask-q-1
---

## Question
Is the retry approach sound?
QEOF
RQ="$WORK/ma-legq"; mkdir -p "$RQ"
run_grok_leg "$MA_MSGQ" "$RQ" >/dev/null 2>&1
QREPLY="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f | sort | tail -1)"
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RQ/result.json" | head -1)" = "completed" ] \
  && ok "question leg completes" || fail "question leg status"
sed -n '2,/^---$/p' "$QREPLY" | grep -q '^type: response$' \
  && ok "question reply stamped type: response" || fail "question reply type"
[ "$(sed -n '2,/^---$/p' "$QREPLY" | grep -c '^verdict:')" = "0" ] \
  && ok "question reply carries NO verdict field" || fail "question verdict leak"
grep -q '^VERDICT: APPROVE$' "$QREPLY" \
  && ok "stray verdict line preserved as consult body text" || fail "consult body preservation"
[ ! -f "$MA_MSGQ" ] && [ -f "$MA_FIX/.comms/archive/$(basename "$MA_MSGQ")" ] \
  && ok "question inbound archived to the sender-derived owner" || fail "question archive movement"

# Prompt-shape contracts (first-live-consult findings, codex-triaged):
grep -q 'NOT a review' "$RQ/prompt.md" && ! grep -q 'Review discipline:' "$RQ/prompt.md" \
  && ! grep -q "VERDICT: APPROVE' or" "$RQ/prompt.md" && grep -q 'Grok Take' "$RQ/prompt.md" \
  && ok "consult prompt carries no reviewer framing or verdict bar" || fail "consult prompt split"
grep -q 'Review discipline:' "$R1/prompt.md" && grep -q 'completeness, architecture' "$R1/prompt.md" \
  && grep -q 'Acceptance criteria' "$R1/prompt.md" && ! grep -q 'NOT a review' "$R1/prompt.md" \
  && ok "review prompt carries the bar + plan focus + criteria pointer" || fail "review prompt round 1"
grep -q 'round 2' "$R2A/prompt.md" && grep -q 'blank checklist' "$R2A/prompt.md" \
  && grep -q 'bar does not move' "$R2A/prompt.md" \
  && ok "round-2 prompt carries holistic re-review + pinned-criteria rule" || fail "review prompt round 2 playbook"
grep -q 'entry points' "$R2B/prompt.md" && grep -q 'Phase focus (implement)' "$R2B/prompt.md" \
  && ok "implement prompt carries the checklist" || fail "implement prompt checklist"
grep -q 'rev-parse HEAD' "$R1/prompt.md" && grep -q 'THE REVIEW IS THE WORK' "$R1/prompt.md" \
  && ok "review prompt carries the inspection contract" || fail "inspection contract"

# FAIL-CLOSED: a review turn with no obtainable verdict discipline must refuse
# BEFORE the child runs; a question turn under identical conditions completes.
BARE="$WORK/bare-helpers"; mkdir -p "$BARE"
cp "$REPO/helpers/comms.sh" "$REPO/helpers/runphase.sh" "$BARE/"
chmod +x "$BARE"/*.sh
MA_MSGFC="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-45-00_failclosed-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-7/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGFC"
RFC1="$WORK/ma-legfc"; mkdir -p "$RFC1"
(cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" CODEX_SKILLS_DIR="$WORK/no-skills" \
   COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$BARE/runphase.sh" run --message "$MA_MSGFC" --dir "$RFC1" --provider grok) >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RFC1/result.json" | head -1)" = "failed" ] \
  && grep -q 'no review bar' "$RFC1/result.json" && [ -f "$MA_MSGFC" ] && [ ! -s "$RFC1/events.ndjson" ] \
  && ok "review turn with no discipline fails closed BEFORE the child runs" || fail "discipline fail-closed"
MA_MSGFQ="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-46-00_fcq-1.md"
sed -e 's/^type: review-request$/type: question/' -e 's/^thread: ma-arc-1$/thread: ma-arc-8/' \
    -e '/^workflow:/d' -e '/^phase:/d' -e '/^round:/d' -e '/^max-rounds:/d' \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGFQ"
RFC2="$WORK/ma-legfq"; mkdir -p "$RFC2"
(cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" CODEX_SKILLS_DIR="$WORK/no-skills" \
   COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$BARE/runphase.sh" run --message "$MA_MSGFQ" --dir "$RFC2" --provider grok) >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RFC2/result.json" | head -1)" = "completed" ] \
  && ok "question turn completes without the review bar (never loads it)" || fail "question turn under bare install"

# Mailbox isolation: the parent assembles the prompt; the child is given NO
# mailbox path, NO helper invocation, and no way to reach another thread. An
# inherited env var was NOT a boundary (a child with shell access can unset it),
# so the guarantee is: nothing to query + kernel read-limit to CWD (strict).
SENS="$MA_FIX/.comms/archive/${MA_WS}_2026-08-19T01-00-00_other-thread-1.md"
cat > "$SENS" <<SEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-19T01:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-19T01-00-00_other-thread-1
thread: unrelated-arc-99
verdict: APPROVE
---

## Summary
SENSITIVE-UNRELATED-CONTENT lives here
SEOF
# The target thread MUST have prior history, or the context path never runs and
# the isolation assertions pass vacuously (round-3 review caught exactly that).
PRIOR="$MA_FIX/.comms/archive/${MA_WS}_2026-08-19T05-00-00_prior-round-1.md"
cat > "$PRIOR" <<PEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-19T05:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-19T05-00-00_prior-round-1
thread: ma-arc-10
workflow: auto-implement
phase: implement
round: 1
verdict: REQUEST_CHANGES
---

## Summary
LEGITIMATE-PRIOR-ROUND-CONTEXT for this very thread

### Blocking
- .comms/archive/agent-comms_2026-08-19T00-00-00_x.md — realistic review prose
  naming comms.sh and archive-search, exactly as this project's reviews do.
PEOF
# Adversarial: an UNRELATED thread whose BODY quotes the target thread id — a
# literal grep would pull it in along with its adjacent secret.
QUOTER="$MA_FIX/.comms/archive/${MA_WS}_2026-08-19T06-00-00_quoter-1.md"
cat > "$QUOTER" <<QEOF2
---
type: review-feedback
from: codex
timestamp: 2026-08-19T06:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-19T06-00-00_quoter-1
thread: unrelated-arc-98
verdict: APPROVE
---

## Summary
Cross-reference to ma-arc-10 appears here, and so does SENSITIVE-QUOTER-SECRET
QEOF2
MA_MSGISO="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-48-00_isolation-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-10/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGISO"
RISO="$WORK/ma-legiso"; mkdir -p "$RISO"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSGISO" "$RISO" >/dev/null 2>&1
grep -q 'LEGITIMATE-PRIOR-ROUND-CONTEXT' "$RISO/prompt.md" \
  && ok "parent context path actually ran (prior round present)" || fail "prior-context path did not run"
grep -q 'SENSITIVE-UNRELATED-CONTENT' "$RISO/prompt.md" \
  && fail "LEAK: unrelated archived thread reached the generated prompt" \
  || ok "unrelated archived threads never reach the generated prompt"
grep -q 'SENSITIVE-QUOTER-SECRET' "$RISO/prompt.md" \
  && fail "LEAK: an unrelated thread QUOTING the target id reached the prompt" \
  || ok "thread match is exact frontmatter, not a body-quote grep"
# Honest contract (round-4 escalation, user-decided): paths CAN appear inside
# quoted review prose — this project's reviews discuss .comms by nature, and
# redacting them would degrade the review. What must hold: the renderer adds no
# paths of its own, and the prompt tells the child not to act on quoted ones.
grep -q 'do not run comms helpers even' "$RISO/prompt.md" \
  && ok "prompt instructs the child not to act on quoted helper mentions" || fail "quoted-mention instruction"
grep -q 'no mailbox access' "$RISO/prompt.md" \
  && fail "prompt still makes the unattainable no-mailbox-access claim" \
  || ok "prompt makes no claim it cannot keep"
# The checkable contract: the prompt SCAFFOLDING (everything the parent writes
# itself, excluding quoted message/prior-context blocks) advertises no helper and
# no mailbox path. Quoted review prose may contain both — this project's reviews
# discuss .comms by nature — which is why the kernel deny-profile, not path
# secrecy, is the boundary.
SCAFFOLD="$WORK/prompt-scaffold.txt"
awk '/----- BEGIN (MESSAGE|PRIOR CONTEXT) -----/{skip=1} /----- END (MESSAGE|PRIOR CONTEXT) -----/{skip=0; next} !skip' \
  "$RISO/prompt.md" > "$SCAFFOLD"
grep -q 'archive-search' "$SCAFFOLD" && fail "prompt scaffolding still advertises archive-search" \
  || ok "prompt scaffolding advertises no mailbox query helper"
grep -qE '"\$COMMS"|comms\.sh ' "$SCAFFOLD" && fail "prompt scaffolding still invokes a comms helper" \
  || ok "prompt scaffolding invokes no comms helper"
grep -qE '\.comms/(archive|to-)' "$SCAFFOLD" && fail "prompt scaffolding still emits a mailbox path" \
  || ok "prompt scaffolding emits no mailbox path"
grep -q 'archive-search' "$RISO/prompt.md" \
  && ok "control: quoted review prose DOES carry helper names (the honest case)" \
  || fail "fixture is not realistic — quoted prose lacks helper names"
grep -q "$MA_FIX/.comms" "$RISO/prompt.md" && fail "prompt leaks a mailbox path" \
  || ok "no mailbox path outside quoted material"
grep -q 'BEGIN MESSAGE' "$RISO/prompt.md" && grep -q 'inlined here by the' "$RISO/prompt.md" \
  && ok "parent inlines the message the child must review" || fail "message inlining"
grep -q -- '--sandbox read-only' "$GROK_STUB_LOG" \
  && ok "grok argv defaults to the read-only sandbox" || fail "sandbox argv"
: > "$GROK_STUB_LOG"
# Fresh inbound: the isolation leg archived its own message.
MA_MSGSBX="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-49-00_sandbox-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-11/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGSBX"
mkdir -p "$WORK/ma-legsbx" "$WORK/ma-legsbx2"
(cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   COMMS_RUNPHASE_GROK_SANDBOX=agent-comms-review "$RP" run --message "$MA_MSGSBX" --dir "$WORK/ma-legsbx" --provider grok) >/dev/null 2>&1 || true
grep -q -- '--sandbox agent-comms-review' "$GROK_STUB_LOG" \
  && ok "operator custom sandbox profile is honored by the runner" || fail "custom sandbox selection"
MA_MSGSBX2="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-50-00_sandbox-2.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-12/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGSBX2"
for badsbx in off devbox workspace "not a name"; do
  cp "$MA_MSGSBX2" "$MA_MSGSBX2.keep" 2>/dev/null || true
  OUTSBX="$( (cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      COMMS_RUNPHASE_GROK_SANDBOX="$badsbx" "$RP" run --message "$MA_MSGSBX2" --dir "$WORK/ma-legsbx2" --provider grok) 2>&1 )" && rcs=0 || rcs=$?
  [ "$rcs" -ne 0 ] && echo "$OUTSBX" | grep -qi 'refuse\|must be a bare profile' \
    && ok "sandbox knob refuses '$badsbx'" || fail "sandbox knob refusal for '$badsbx' (rc=$rcs)"
  mv -f "$MA_MSGSBX2.keep" "$MA_MSGSBX2" 2>/dev/null || true
done
rm -f "$SENS" "$PRIOR" "$QUOTER"

# Fail-closed also when the skill EXISTS but carries no fragment markers.
MARKERLESS="$WORK/markerless-skills"; mkdir -p "$MARKERLESS/send-to-claude"
printf '# Send To Claude\nno fragments here\n' > "$MARKERLESS/send-to-claude/SKILL.md"
MA_MSGFM="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-47-00_markerless-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-9/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGFM"
RFM="$WORK/ma-legfm"; mkdir -p "$RFM"
(cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" CODEX_SKILLS_DIR="$MARKERLESS" \
   COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$BARE/runphase.sh" run --message "$MA_MSGFM" --dir "$RFM" --provider grok) >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RFM/result.json" | head -1)" = "failed" ] \
  && grep -q 'fragment markers absent' "$RFM/result.json" \
  && ok "markerless skill also fails closed with the precise cause" || fail "markerless fail-closed"

# Parent-stamped envelope: the successful legs prove the authority — re-assert
# the stamped fields on the leg-1 reply match the INBOUND turn exactly.
grep -q '^in-reply-to: '"${MA_WS}"'_2026-08-20T09-00-00_review-req-1$' "$REPLY1" \
  && grep -q '^workflow: auto-full$' "$REPLY1" && grep -q '^round: 1$' "$REPLY1" \
  && ok "stamped envelope binds the reply to the inbound turn" || fail "envelope-binding assertion"

echo "== multi-agent: grok arg refusals =="
R5="$WORK/ma-leg5"; mkdir -p "$R5"
for bad in "COMMS_RUNPHASE_GROK_ARGS=--sandbox workspace" "COMMS_RUNPHASE_GROK_ARGS=--sandbox off" \
           "COMMS_RUNPHASE_GROK_ARGS=--sandbox devbox" "COMMS_RUNPHASE_GROK_ARGS=--sandbox=off" \
           "COMMS_RUNPHASE_GROK_ARGS=--sandbox=workspace" "COMMS_RUNPHASE_GROK_ARGS=--sandbox=devbox" \
           "COMMS_RUNPHASE_GROK_ARGS=--sandbox=read-only" "COMMS_RUNPHASE_GROK_ARGS=--sandbox strict" "COMMS_RUNPHASE_GROK_ARGS=--always-approve" \
           "COMMS_RUNPHASE_GROK_ARGS=$(printf -- '--sandbox\toff')" \
           "COMMS_RUNPHASE_GROK_ARGS=$(printf -- '--sandbox\nworkspace')" \
           "COMMS_RUNPHASE_GROK_ARGS=--permission-mode=bypassPermissions" \
           "COMMS_RUNPHASE_GROK_PERMISSION_MODE=bypassPermissions"; do
  OUT="$( (cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      "$bad" "$RP" run --message "$MA_MSG4" --dir "$R5" --provider grok) 2>&1 )" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && echo "$OUT" | grep -qi 'refused'; then
    ok "refused: $bad"
  else
    fail "refusal missing for: $bad (rc=$rc)"
  fi
done

echo "== multi-agent: archive-owner authority (comms.sh send) =="
# Retry idempotency: inbound already archived -> no-op success
OUTB="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T09-40-00_r2-1.md"
cat > "$OUTB" <<MAEOF
---
type: review-request
from: claude
timestamp: 2026-08-20T14:40:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-20T09-40-00_r2-1
thread: ma-arc-1
workflow: auto-full
phase: implement
round: 2
max-rounds: 4
---

body
MAEOF
IDEMP_OUT="$(cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$OUTB" --archive-inbound "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && echo "$IDEMP_OUT" | grep -q 'no-op' && ok "already-archived inbound is a no-op success (retry idempotent)" || fail "archive retry idempotency (rc=$rc)"
# Cross-inbox mismatch: outbound from: claude but inbound sits in to-codex/
STRAY="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T09-50-00_stray-1.md"
cp "$OUTB" "$STRAY"
STATE_ARC1="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_ma-arc-1.json"
STATE_BEFORE="$(cat "$STATE_ARC1" 2>/dev/null || true)"
CMUX_LOG_BEFORE="$(wc -l < "$CMUX_STUB_LOG" 2>/dev/null | tr -d ' ' || echo 0)"
MISMATCH_OUT="$(cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$OUTB" --archive-inbound "$STRAY" 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$MISMATCH_OUT" | grep -q 'cross-inbox mismatch' \
  && ok "cross-inbox archive mismatch refused" || fail "cross-inbox mismatch refusal (rc=$rc)"
echo "$MISMATCH_OUT" | grep -q 'delivered to' && fail "mismatch must refuse BEFORE delivery" || ok "mismatch refusal precedes delivery (nothing nudged)"
[ "$(wc -l < "$CMUX_STUB_LOG" 2>/dev/null | tr -d ' ' || echo 0)" = "$CMUX_LOG_BEFORE" ] \
  && ok "mismatch refusal makes zero cmux calls" || fail "mismatch cmux-call atomicity"
[ "$(cat "$STATE_ARC1" 2>/dev/null || true)" = "$STATE_BEFORE" ] \
  && ok "mismatch refusal mutates no thread state" || fail "mismatch state atomicity"
rm -f "$STRAY" "$OUTB"

echo "== multi-agent: template source contracts =="
grep -qF '"$COMMS_SH" agents' "$REPO/templates/claude-commands/ask.md" \
  && ok "ask.md reads known agents from the registry helper" || fail "ask.md registry hookup"
# One loop command now. `--reviewers` is PLURAL and held as a list: a singular name
# stretched into a list is how one REVIEWER scalar ends up copied across every write path.
AUTOF="$REPO/templates/claude-commands/auto.md"
grep -q -- '--reviewers a,b' "$AUTOF" && ok "auto.md takes a reviewer LIST" || fail "auto.md reviewers flag"
grep -qF 'GATING=' "$AUTOF" && ok "auto.md names a gating reviewer distinct from the list" || fail "auto.md gating reviewer"
grep -q 'Default 4' "$AUTOF" && ok "auto.md defaults max-rounds to 4" || fail "auto.md rounds default"
grep -q 'DIRECTION' "$AUTOF" && ok "auto.md gives --plan a direction-only bar" || fail "auto.md plan bar"
grep -q 'capped at 2 rounds' "$AUTOF" && ok "auto.md caps the plan phase" || fail "auto.md plan cap"
grep -qF 'REVIEWER=$(awk' "$REPO/templates/claude-commands/read-from-codex.md" \
  && grep -q 'ok) print v' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "reader extractor is close-delimiter-gated" || fail "reader REVIEWER capture (bounded)"
RFC_SRC="$REPO/templates/claude-commands/read-from-codex.md"
DERIVE_LN="$(grep -n 'Derive the reviewer BEFORE acting on validation results' "$RFC_SRC" | cut -d: -f1 | head -1)"
ERRLANE_LN="$(grep -n 'send --to "\$REVIEWER" "<error file>"' "$RFC_SRC" | cut -d: -f1 | head -1)"
[ -n "$DERIVE_LN" ] && [ -n "$ERRLANE_LN" ] && [ "$DERIVE_LN" -lt "$ERRLANE_LN" ] \
  && ok "reviewer derivation precedes the error lane" || fail "error-lane REVIEWER ordering"
grep -q 'FAIL CLOSED: report the malformed message' "$RFC_SRC" \
  && ok "unregistered-sender error lane fails closed" || fail "error-lane fail-closed rule"
# Execute the template's ACTUAL extractor line against adversarial fixtures.
EXTRACT_LINE="$(grep -m1 'REVIEWER=\$(awk' "$RFC_SRC" | sed 's/^ *//')"
NOCLOSE="$WORK/noclose.md"
printf -- '---\ntype: review-feedback\n\nbody text\nfrom: grok\nmore body\n' > "$NOCLOSE"
GOT="$(eval "${EXTRACT_LINE/\"<message file>\"/\"$NOCLOSE\"}"; printf '%s' "$REVIEWER")"
[ -z "$GOT" ] && ok "template extractor yields empty on missing close delimiter" || fail "extractor missing-close (got: $GOT)"
CRLF="$WORK/crlf.md"
printf -- '---\r\ntype: review-feedback\r\nfrom: codex\r\n---\r\n\r\nbody\r\n' > "$CRLF"
GOT2="$(eval "${EXTRACT_LINE/\"<message file>\"/\"$CRLF\"}"; printf '%s' "$REVIEWER")"
[ "$GOT2" = "codex" ] && ok "template extractor handles CRLF frontmatter" || fail "extractor CRLF (got: $GOT2)"
# Duplicate authoritative fields: extraction must AGREE with the helper's
# first-field parse — validation and routing must select the same sender.
DUPFROM="$WORK/dupfrom.md"
printf -- '---\ntype: review-feedback\nfrom: codex\nfrom: grok\ntimestamp: 2026-08-20T14:00:00Z\nverdict: APPROVE\n---\n\nbody\n' > "$DUPFROM"
GOT3="$(eval "${EXTRACT_LINE/\"<message file>\"/\"$DUPFROM\"}"; printf '%s' "$REVIEWER")"
[ "$GOT3" = "codex" ] && ok "duplicate from: routes to the FIRST (validated) sender" || fail "duplicate-from agreement (got: $GOT3)"
grep -qF 'send --to "$REVIEWER" "<your reply file>"' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "reader continuations send to the derived reviewer" || fail "reader continuation target"

echo "== acp.sh: consult transport (stubbed npx) =="
ACP="$REPO/helpers/acp.sh"
ACP_STUB="$WORK/acp-bin"; mkdir -p "$ACP_STUB"
export ACP_STUB_LOG="$WORK/acp.log"
cat > "$ACP_STUB/npx" <<'NSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "${ACP_STUB_LOG:-/dev/null}"
[ -n "${ACP_STUB_EXIT:-}" ] && exit "$ACP_STUB_EXIT"
case " $* " in
  *" sessions ensure "*) echo "stub-session-id (created)" ;;
  *) echo "stub answer"; echo "[acpx] tokens: input=100 output=5 cache_read=25000 total=25105" ;;
esac
NSTUB
chmod +x "$ACP_STUB/npx"
cat > "$ACP_STUB/node" <<'NODESTUB'
#!/bin/bash
echo "${ACP_STUB_NODE_V:-v22.22.3}"
NODESTUB
chmod +x "$ACP_STUB/node"

run_acp() { PATH="$ACP_STUB:$PATH" bash "$ACP" "$@"; }
OUT="$(run_acp consult codex is the retry approach sound 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'stub answer' && ok "consult passes the answer through" || fail "consult happy path (rc=$rc)"
grep -q -- '-y acpx@0.13.1 codex sessions ensure --name agent-comms-ask' "$ACP_STUB_LOG" \
  && ok "warm consult ensures the pinned named session" || fail "session ensure argv"
grep -q -- '-y acpx@0.13.1 --format quiet --approve-reads --non-interactive-permissions deny codex -s agent-comms-ask is the retry approach sound' "$ACP_STUB_LOG" \
  && ok "warm consult prompts the named session with the pinned acpx" || fail "warm prompt argv"
# A consult that cannot read is useless — it would answer from recall instead of the
# tree. Denied permissions killed a real consult mid-answer before this was added.
grep -q -- '--approve-reads' "$ACP_STUB_LOG" && ok "consults may READ the tree" || fail "consult read approval"
grep -q -- '--non-interactive-permissions deny' "$ACP_STUB_LOG" \
  && ok "consults still refuse writes (prompting is impossible here)" || fail "consult write denial"
: > "$ACP_STUB_LOG"
run_acp consult codex --oneshot quick check >/dev/null 2>&1
grep -q -- 'codex exec quick check' "$ACP_STUB_LOG" && ! grep -q -- '-s agent-comms-ask' "$ACP_STUB_LOG" \
  && ok "--oneshot uses stateless exec, no session" || fail "oneshot argv"
QF="$WORK/acp-q.md"; printf 'excerpted discussion\n' > "$QF"
: > "$ACP_STUB_LOG"
run_acp consult codex --file "$QF" >/dev/null 2>&1
grep -q -- "--file $QF" "$ACP_STUB_LOG" && ok "file-form payload passes through" || fail "file-form argv"
for code in 2 3 4 5 130 7; do
  OUT="$(ACP_STUB_EXIT=$code run_acp consult codex hello 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && echo "$OUT" | grep -qi 'mailbox' && ! echo "$OUT" | grep -qi 'retry'; then
    ok "exit-$code maps: nonzero + mailbox fallback + no retry advice"
  else
    fail "exit-$code contract (rc=$rc, out: $(echo "$OUT" | head -1))"
  fi
done
OUT="$(run_acp consult codex hello --file 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q -- '--file requires a path' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "trailing --file dies with diagnostic + fallback" || fail "trailing --file guard (rc=$rc)"
pf_check() {  # pf_check <desc> <args...> — nonzero + mailbox + no retry advice
  local desc="$1"; shift
  local out rc=0
  out="$(run_acp "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && echo "$out" | grep -qi 'mailbox' && ! echo "$out" | grep -qi 'retry'; then
    ok "preflight failure carries fallback: $desc"
  else
    fail "preflight fallback missing: $desc (rc=$rc, out: $(echo "$out" | head -1))"
  fi
}
pf_check "missing agent" consult
pf_check "missing question" consult codex
pf_check "empty --file value" consult codex --file "" hello
pf_check "nonexistent --file path" consult codex --file "$WORK/does-not-exist.md"
# Measurement consistency: one arithmetic, stated identically on every surface.
if grep -rn '134x' "$REPO/helpers" "$REPO/docs" "$REPO/templates" >/dev/null 2>&1; then
  fail "stale 134x ratio still published somewhere"
else
  ok "no stale measurement ratio published"
fi
for mf in "$REPO/helpers/acp.sh" "$REPO/docs/INTERNALS.md" "$REPO/docs/COMMANDS.md"; do
  grep -q '18,562' "$mf" && grep -q '127x' "$mf" \
    && ok "measurement consistent in $(basename "$mf")" || fail "measurement surfaces in $(basename "$mf")"
done
OUT="$(ACP_STUB_NODE_V=v18.0.0 run_acp consult codex hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'Node >= 22.13' && ok "node version gate fails closed with guidance" || fail "node gate"
OUT="$(ACP_STUB_NODE_V=v18.0.0 run_acp doctor 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 3 ] && ok "doctor exits 3 without a usable node" || fail "doctor node gate (rc=$rc)"
: > "$ACP_STUB_LOG"
# gemini has no ACP profile here; grok DOES since 2026-08-25 (acpx `grok-build`,
# verified against `acpx --help` and one live consult).
OUT="$(run_acp consult gemini hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'mailbox path' && [ ! -s "$ACP_STUB_LOG" ] \
  && ok "an agent with no ACP profile fails closed before any acpx call" || fail "unsupported-agent refusal"
for acp_a in codex claude grok; do
  bash "$REPO/helpers/acp.sh" supports "$acp_a" >/dev/null 2>&1 \
    && ok "acp supports $acp_a" || fail "acp supports $acp_a"
done
bash "$REPO/helpers/acp.sh" supports gemini >/dev/null 2>&1 \
  && fail "acp claims to support an unprofiled agent" || ok "acp supports probe is machine-readable and refuses gemini"
grep -q 'ACPX_VERSION="0.13.1"' "$ACP" && ok "acpx version is pinned in one place" || fail "acpx pin"
[ -x "$INST_FIX/.agent-comms/acp.sh" ] && ok "local install ships an executable acp.sh" || fail "local install acp.sh"
grep -qF '"$ACP_SH" consult' "$REPO/templates/claude-commands/ask.md" \
  && grep -q -- '--via acp' "$REPO/templates/claude-commands/ask.md" \
  && grep -q 'Do NOT retry the ACP path' "$REPO/templates/claude-commands/ask.md" \
  && ok "ask.md carries the ACP transport with fallback discipline" || fail "ask.md ACP source contract"
grep -q 'Parse BOTH transport modifiers out' "$REPO/templates/claude-commands/ask.md" \
  && grep -qF 'consult "$TARGET" --oneshot --file' "$REPO/templates/claude-commands/ask.md" \
  && grep -q 'if and only if the user' "$REPO/templates/claude-commands/ask.md" \
  && ok "ask.md parses and conditionally forwards --oneshot" || fail "ask.md oneshot forwarding contract"
grep -q 'acp.sh' "$REPO/install.sh" && ok "installer ships acp.sh" || fail "installer acp.sh"

echo "== scope-dial template source contract =="
# Scope-dial trio: the load-bearing new prose, pinned mechanically.
FRAGVD="$REPO/docs/loopspec/fragments/verdict-discipline.md"
grep -q 'Pre-existing defects in code the change did not touch are Advisory by default' "$FRAGVD" \
  && ok "verdict-discipline fragment carries the pre-existing-defects rule" || fail "fragment pre-existing-defects rule"
AIF="$REPO/templates/claude-commands/auto.md"
grep -q '## Acceptance criteria' "$AIF" && grep -q 'PINNED at round 1' "$AIF" \
  && ok "auto.md pins acceptance criteria at round 1" || fail "auto acceptance criteria"
RFC="$REPO/templates/claude-commands/read-from-codex.md"
grep -q 'pinned `## Acceptance criteria`' "$RFC" \
  && ok "auto-full implement handoff pins acceptance criteria" || fail "read-from-codex criteria handoff"
grep -q '### Scope additions' "$RFC" && grep -q 'Copy the ledger forward verbatim' "$RFC" \
  && ok "reply spec carries the scope-additions ledger forward" || fail "read-from-codex scope ledger"
grep -q 'copied forward VERBATIM' "$RFC" && grep -q 'amended round N' "$RFC" \
  && ok "reply spec copies acceptance criteria forward with explicit amendments" || fail "read-from-codex criteria lifecycle"
grep -q 'amendment proposal alone' "$RFC" && grep -c 'amended round N' "$RFC" | grep -q '2' \
  && ok "amendment rule present in reply spec AND auto-full handoff" || fail "amendment rule in both handoff paths"
RFCL="$REPO/templates/codex-skills/read-from-claude/SKILL.md"
grep -q 'Judge against the pinned' "$RFCL" && grep -q 'does not move with each' "$RFCL" \
  && ok "reviewer judges against pinned criteria" || fail "read-from-claude pinned-criteria judging"
grep -q 'amendment proposal alone is non-blocking' "$RFCL" \
  && ok "reviewer treats amendment proposals as non-blocking" || fail "read-from-claude amendment non-blocking"

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

echo "== grading pilot: findings extraction (the single-reviewer baseline) =="
GR_FIX="$WORK/grading-repo"
mkdir -p "$GR_FIX"
GR_FIX="$(cd "$GR_FIX" && pwd -P)"
git -C "$GR_FIX" init -q -b main
printf '.comms/\n.agent-comms/\n' > "$GR_FIX/.gitignore"
git -C "$GR_FIX" add .gitignore >/dev/null 2>&1
git -C "$GR_FIX" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$GR_FIX/.comms/archive"
run_gr() { (cd "$GR_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }

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

echo "== grading pilot: --out ledger is append-only and idempotent =="
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

echo "== grading pilot: shadow role + run identity are stamped, not inferred =="
GR_SHADOW="$(run_gr findings --role shadow --review-set rs-1 --artifact art-abc \
  --reviewer-version 'grok/1.0.5' --prompt-version 'pv-deadbeef' \
  "$GR_FIX/.comms/archive/gr_2026-08-04T10-00-00_fb-3.md" 2>/dev/null | tail -n +2)"
printf '%s\n' "$GR_SHADOW" | awk -F'\t' '$12=="shadow" && $3=="rs-1" && $4=="art-abc" && $10=="grok/1.0.5" && $11=="pv-deadbeef"' | grep -q . \
  && ok "shadow row carries role, review_set, artifact, runtime and prompt identity" || fail "shadow stamping"
check_not "findings rejects an unknown role" run_gr findings --role primary
check_not "findings rejects an unknown option" run_gr findings --bogus

echo "== grading pilot: snapshot RETAINS the reviewed tree (a hash alone cannot) =="
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

echo "== grading pilot: prompt-version partitions grades across an instruction edit =="
GR_HOME="$WORK/grading-home"
mkdir -p "$GR_HOME"
mkdir -p "$GR_FIX/.agent-comms" "$GR_FIX/.claude/commands"
echo "reviewer prompt v1" > "$GR_FIX/.claude/commands/auto-implement.md"
run_gr_h() { (cd "$GR_FIX" && env -u CMUX_WORKSPACE_ID HOME="$GR_HOME" "$COMMS" "$@"); }
PV1="$(run_gr_h prompt-version)"
printf '%s' "$PV1" | grep -qE '^[0-9a-f]{12}$' && ok "prompt-version prints a short content hash" || fail "prompt-version shape (got $PV1)"
[ "$PV1" = "$(run_gr_h prompt-version)" ] && ok "prompt-version is stable when nothing changes" || fail "prompt-version unstable"
echo "reviewer prompt v2 — one sentence added" > "$GR_FIX/.claude/commands/auto-implement.md"
[ "$PV1" != "$(run_gr_h prompt-version)" ] && ok "editing a reviewer instruction changes the version" || fail "prompt-version blind to an edit"
echo "reviewer prompt v1" > "$GR_FIX/.claude/commands/auto-implement.md"
[ "$PV1" = "$(run_gr_h prompt-version)" ] && ok "reverting the edit restores the version" || fail "prompt-version not content-addressed"
PV_BEFORE="$(run_gr_h prompt-version)"
echo "a newly installed surface" > "$GR_FIX/.claude/commands/auto-plan.md"
[ "$PV_BEFORE" != "$(run_gr_h prompt-version)" ] \
  && ok "a surface APPEARING changes the version (missing files are hashed as markers)" || fail "prompt-version blind to an added surface"
# Capture BEFORE grepping: `producer | grep -q` races under `set -o pipefail` —
# grep exits on the first match, the producer takes SIGPIPE, and the pipeline
# reports 141. Cost us two phantom failures.
PV_LIST="$(run_gr_h prompt-version --list)"
printf '%s\n' "$PV_LIST" | grep -q 'auto-implement.md' && ok "prompt-version --list names its inputs" || fail "prompt-version --list"
printf '%s\n' "$PV_LIST" | grep -q '^MISSING ' && ok "--list marks surfaces this install does not have" || fail "prompt-version missing marker"
check_not "prompt-version rejects an unknown option" run_gr_h prompt-version --bogus

echo "== grading pilot: shadow reviewer is a MEASUREMENT, structurally unable to gate =="
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
run_sh() { (cd "$SH_FIX" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }

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

# --no-deliver suppresses the trusted-parent BROKER. An agent that authors and sends
# its own reply would still reach an inbox, making "cannot gate" a convention rather
# than a mechanism. (grok, first live shadow run 2026-08-22.)
SH_UNBROKERED="$(run_sh shadow --to codex "$SH_REQ" 2>&1)" && SH_URC=0 || SH_URC=$?
[ "$SH_URC" != "0" ] && ok "shadow refuses an agent that sends its own replies" || fail "unbrokered agent accepted"
printf '%s\n' "$SH_UNBROKERED" | grep -q 'parent-brokered' \
  && ok "the refusal names WHY (only parent-brokered reviewers can be shadowed)" || fail "unbrokered refusal message"

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
(cd "$SH_FIX" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" SHADOW_PROMPT_COPY="$SH_PROMPT" \
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
SH_FAIL_OUT="$( (cd "$SH_FIX" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" SHADOW_STUB_FAIL=1 \
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
[ "$SH_NRC" != "0" ] && ok "a contract-breaking reply fails the shadow run" || fail "no-verdict shadow exit code"
SH_NOVERD_DIR="$(find "$SH_FIX/.comms/grades/shadow" -maxdepth 1 -type d -name 'noverdict-set-*' | head -1)"
[ -n "$SH_NOVERD_DIR" ] && [ -s "$SH_NOVERD_DIR/grok.raw.md" ] \
  && ok "the reviewer's RAW text is preserved when the reply breaks the contract" || fail "raw text discarded"
grep -q 'must not be thrown away' "$SH_NOVERD_DIR/grok.raw.md" 2>/dev/null \
  && ok "the preserved raw text is the reviewer's actual output" || fail "raw text content"
tail -n +2 "$SH_LED" | grep -q 'must not be thrown away' \
  && fail "an unstamped reply was scored into the ledger" \
  || ok "a reply that failed the contract is preserved but NOT scored"

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
SH_RETRY_OUT="$( (cd "$SH_FIX" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" \
  SHADOW_RETRY_MARK="$SH_RETRY_MARK" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
  "$COMMS" shadow --to grok --review-set noverdict-set "$(sh_req_for noverdict2)") 2>&1 )" && SH_RRC=0 || SH_RRC=$?
[ "$SH_RRC" != "0" ] && ok "retrying into a set that already holds a result is refused" || fail "retry accepted"
[ ! -e "$SH_RETRY_MARK" ] \
  && ok "the refusal happens BEFORE the reviewer runs (nothing was spent)" || fail "retry re-ran the reviewer before refusing"
printf '%s\n' "$SH_RETRY_OUT" | grep -q 'nothing was run' \
  && ok "the refusal says nothing was run" || fail "retry refusal message"

echo "== grading pilot: round-1 review fixes (mounted artifact, safe ids, whole claims) =="
GR2="$WORK/shadow-repo2"
mkdir -p "$GR2"; GR2="$(cd "$GR2" && pwd -P)"
git -C "$GR2" init -q -b main
printf '.comms/\n.agent-comms/\n' > "$GR2/.gitignore"
echo "ORIGINAL CONTENT" > "$GR2/subject.txt"
git -C "$GR2" add -A >/dev/null 2>&1
git -C "$GR2" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$GR2/.comms/to-codex" "$GR2/.comms/to-claude"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$GR2/.comms/config"
run_g2() { (cd "$GR2" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }

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
G2_OUT="$( (cd "$GR2" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" \
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
(cd "$GR2" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" SHADOW_SHAPE_COPY="$G2_SHAPE" \
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
(cd "$GR2" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" SHADOW_CWD_COPY="$G2_NOCWD_CWD" \
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
(cd "$GR2" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" GROK_STUB_VERSION_MARK="$WORK/vmark" \
  COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" shadow --to grok --out "$G2_VLED" "$G2_VREQ") >/dev/null 2>&1 || true
G2_LIVE_V="$(tail -n +2 "$G2_VLED" 2>/dev/null | awk -F'\t' '$12=="shadow" {print $10; exit}')"
G2_SIDE_V="$(cat "$(find "$GR2/.comms/grades/shadow" -path '*g2-ver*' -name 'grok.version' | head -1)" 2>/dev/null)"
[ -n "$G2_LIVE_V" ] && [ "$G2_LIVE_V" = "$G2_SIDE_V" ] \
  && ok "the live row uses the version captured at dispatch, matching its own sidecar" \
  || fail "live row version ($G2_LIVE_V) disagrees with the sidecar ($G2_SIDE_V)"
case "$G2_LIVE_V" in *upgraded-midrun*) fail "the live row picked up a mid-review CLI upgrade" ;; *) ok "a mid-review CLI upgrade does not reach the row" ;; esac

G2_RP="$( (cd "$GR2" && env -u CMUX_WORKSPACE_ID "$REPO/helpers/runphase.sh" run --message "$G2_REQ" --dir "$WORK/g2rp" --provider codex --no-deliver) 2>&1 )" && G2_RPRC=0 || G2_RPRC=$?
[ "$G2_RPRC" != "0" ] && ok "runphase refuses --no-deliver for a self-sending provider" || fail "runphase --no-deliver accepted for codex"
printf '%s\n' "$G2_RP" | grep -q 'authors and sends its own reply' \
  && ok "the runphase refusal explains why" || fail "runphase refusal message"

echo "== comms.sh: transport selection (no pane must not strand a consult) =="
TR_FIX="$WORK/transport-repo"; mkdir -p "$TR_FIX"; TR_FIX="$(cd "$TR_FIX" && pwd -P)"
git -C "$TR_FIX" init -q -b main
git -C "$TR_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
mkdir -p "$TR_FIX/.comms"
run_tr() { (cd "$TR_FIX" && env -u CMUX_WORKSPACE_ID -u COMMS_DELIVERY "$COMMS" "$@"); }
run_tr_cmux() { (cd "$TR_FIX" && env -u COMMS_DELIVERY PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:7 "$COMMS" "$@"); }
run_tr_want_cmux() { (cd "$TR_FIX" && env COMMS_DELIVERY=cmux PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:7 "$COMMS" "$@"); }

# No cmux surface anywhere: an interactive agent must NOT fall to the mailbox while a
# synchronous transport is available — that is the case that stranded a real consult.
TR_CODEX="$(run_tr transport codex 2>/dev/null)"
[ "$TR_CODEX" = "acp" ] || [ "$TR_CODEX" = "mailbox" ] && ok "transport resolves for codex with no pane (got: $TR_CODEX)" || fail "transport codex (got: $TR_CODEX)"
if bash "$REPO/helpers/acp.sh" supports codex >/dev/null 2>&1; then
  [ "$TR_CODEX" = "acp" ] && ok "with ACP available, no pane routes to acp, never mailbox" || fail "no-pane consult fell to $TR_CODEX despite ACP"
else
  [ "$TR_CODEX" = "mailbox" ] && ok "without ACP, no pane honestly reports mailbox" || fail "no-ACP fallback"
fi

# grok has no interactive surface by definition, so it can never reach a pane.
TR_GROK="$(run_tr transport grok 2>/dev/null)"
if bash "$REPO/helpers/acp.sh" supports grok >/dev/null 2>&1; then
  [ "$TR_GROK" = "acp" ] && ok "a headless-only agent prefers acp for a consult" || fail "grok consult (got: $TR_GROK)"
else
  [ "$TR_GROK" = "headless" ] && ok "a headless-only agent reports headless" || fail "grok consult (got: $TR_GROK)"
fi
# Loops DO route to acp now (2026-08-26): the reviewer permission profile turned out
# to exist — --approve-reads plus --non-interactive-permissions deny — and one live
# loop delivered a stamped reply into the inbox. What a loop must never do is take a
# pane it was not asked for.
[ "$(run_tr transport grok --loop 2>/dev/null)" != "cmux" ] \
  && ok "a headless-only agent's loop never resolves to a pane" || fail "grok loop transport"

# An explicit COMMS_DELIVERY=headless override beats everything.
[ "$( (cd "$TR_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless "$COMMS" transport codex) 2>/dev/null)" = "headless" ] \
  && ok "COMMS_DELIVERY=headless overrides transport selection" || fail "headless override"

cat > "$CMUX_STUB_DIR/tree-workspace_7.txt" <<'TRTREE'
workspace:7
  pane:1
    surface:23 [terminal] codex
TRTREE
# A LOOP is unattended work: it must not require a pane to be open.
TR_LOOP_DEFAULT="$(run_tr transport codex --loop 2>/dev/null)"
if bash "$REPO/helpers/acp.sh" supports codex >/dev/null 2>&1; then
  [ "$TR_LOOP_DEFAULT" = "acp" ] && ok "a loop defaults to acp — the cheapest measured transport" || fail "loop default (got: $TR_LOOP_DEFAULT)"
else
  [ "$TR_LOOP_DEFAULT" = "headless" ] && ok "with no ACP, a loop falls back to headless" || fail "loop default (got: $TR_LOOP_DEFAULT)"
fi
[ "$(run_tr_cmux transport codex --loop 2>/dev/null)" != "cmux" ] \
  && ok "a loop does not take a live pane — cmux is opt-in now" || fail "loop took the pane by default"
[ "$(run_tr_want_cmux transport codex --loop 2>/dev/null)" = "cmux" ] \
  && ok "COMMS_DELIVERY=cmux opts a loop back into the watchable pane" || fail "cmux opt-in"
# Asking for cmux when none is live must not silently substitute another transport.
[ "$( (cd "$TR_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=cmux "$COMMS" transport codex --loop) 2>/dev/null)" = "mailbox" ] \
  && ok "cmux requested but none live reports mailbox, never a substitute" || fail "cmux-requested fallback"

# A live pane still wins: switching a watchable workflow out from under someone is a
# surprise, not a fallback.
[ "$(run_tr_cmux transport codex 2>/dev/null)" = "cmux" ] \
  && ok "a live pane still wins over acp" || fail "pane preference (got: $(run_tr_cmux transport codex 2>/dev/null))"

# END-TO-END, not just the selector. `deliver` used to hardcode --loop, so every send
# was reclassified as a loop and a live-pane CONSULT spawned headless instead of nudging
# the pane. The suite-wide COMMS_DELIVERY=cmux masked it, so these run with it cleared.
# (codex, transport-flip round 1.)
mkdir -p "$TR_FIX/.comms/to-codex"
TR_CONSULT="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-25T10-00-00_q-1.md"
cat > "$TR_CONSULT" <<TRQ
---
type: question
from: claude
timestamp: 2026-08-25T10:00:00Z
workspace: $(basename "$TR_FIX")
message_id: $(basename "$TR_FIX")_2026-08-25T10-00-00_q-1
---

## Question
does a consult still reach a live pane?
TRQ
TR_LOOPMSG="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-25T10-01-00_wf-1.md"
cat > "$TR_LOOPMSG" <<TRW
---
type: review-request
from: claude
timestamp: 2026-08-25T10:01:00Z
workspace: $(basename "$TR_FIX")
message_id: $(basename "$TR_FIX")_2026-08-25T10-01-00_wf-1
thread: tr-loop-1
workflow: auto-implement
phase: implement
round: 1
max-rounds: 4
---

## What was done
loop message
TRW
TR_WS="$(basename "$TR_FIX")"
run_tr_deliver() { (cd "$TR_FIX" && env -u COMMS_DELIVERY PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:7 "$COMMS" "$@"); }
cat > "$CMUX_STUB_DIR/tree-workspace_7.txt" <<'TRTREE2'
workspace:7
  pane:1
    surface:23 [terminal] codex
TRTREE2
TR_CONSULT_OUT="$(run_tr_deliver deliver codex "$TR_CONSULT" 2>&1 || true)"
printf '%s\n' "$TR_CONSULT_OUT" | grep -q 'delivered to surface' \
  && ok "a CONSULT with a live pane is nudged, not spawned headless" \
  || fail "consult reclassified as a loop (got: $TR_CONSULT_OUT)"
TR_LOOP_OUT="$(run_tr_deliver deliver codex "$TR_LOOPMSG" 2>&1 || true)"
printf '%s\n' "$TR_LOOP_OUT" | grep -q 'delivered to surface' \
  && fail "a workflow message took the pane instead of the headless runner" \
  || ok "a LOOP message goes headless even with a live pane"
# "did not reach a surface" is also true of manual pickup and of a spawn failure, so
# assert the POSITIVE signal. (codex, transport-flip round 2.)
printf '%s\n' "$TR_LOOP_OUT" | grep -q 'spawned runphase' \
  && ok "the loop actually spawned a headless runner (criterion 1, pinned directly)" \
  || fail "loop did not spawn (got: $TR_LOOP_OUT)"

# The regression codex asked for: cmux explicitly requested with NO workspace identity
# must still surface the picker's specific reason, and must not trip `set -u`.
TR_NOWS="$( (cd "$TR_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=cmux "$COMMS" deliver codex "$TR_CONSULT") 2>&1 || true)"
printf '%s\n' "$TR_NOWS" | grep -q 'unbound variable' \
  && fail "unset CMUX_WORKSPACE_ID trips set -u" || ok "unset cmux identity does not trip set -u"
printf '%s\n' "$TR_NOWS" | grep -q 'tree unavailable' \
  && ok "the picker's specific reason still surfaces with no cmux identity" \
  || fail "specific reason lost (got: $TR_NOWS)"
# The mode comes from the MESSAGE, so `transport` agrees with what deliver did.
[ "$(run_tr_deliver transport codex)" = "cmux" ] && ok "consult mode resolves to the live pane" || fail "consult transport"
[ "$(run_tr_deliver transport codex --loop)" != "cmux" ] && ok "loop mode never resolves to the pane by default" || fail "loop transport"

# Criterion 3: with runphase.sh genuinely absent, a loop must fall back to the pane
# rather than strand. Untested until grok pointed it out. A bare copy of the helper (no
# runphase.sh beside it) is the honest way to simulate a partial install.
TR_BARE="$WORK/bare-install"; mkdir -p "$TR_BARE"
cp "$COMMS" "$TR_BARE/comms.sh"; chmod +x "$TR_BARE/comms.sh"
[ ! -e "$TR_BARE/runphase.sh" ] && ok "fixture: a helper install with no runphase.sh" || fail "bare fixture"
TR_BARE_LOOP="$( (cd "$TR_FIX" && env -u COMMS_DELIVERY PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:7 "$TR_BARE/comms.sh" transport codex --loop) 2>/dev/null)"
[ "$TR_BARE_LOOP" = "cmux" ] \
  && ok "no headless runner + a live pane falls back to cmux, never stranding the loop" \
  || fail "missing-runner fallback (got: $TR_BARE_LOOP)"
TR_BARE_NOPANE="$( (cd "$TR_FIX" && env -u COMMS_DELIVERY -u CMUX_WORKSPACE_ID "$TR_BARE/comms.sh" transport codex --loop) 2>/dev/null)"
[ "$TR_BARE_NOPANE" = "mailbox" ] \
  && ok "no runner and no pane reports mailbox honestly" || fail "bare no-pane (got: $TR_BARE_NOPANE)"

# round-note: counts are DERIVED so a later reader can trust them; the prose is required
# so a round is never recorded without an assessment.
TR_RN="$TR_FIX/.comms/archive/rn-1.md"
mkdir -p "$TR_FIX/.comms/archive"
cat > "$TR_RN" <<'RNEOF'
---
type: review-feedback
from: codex
timestamp: 2026-08-25T12:00:00Z
workspace: tr
thread: rn-thread
phase: implement
round: 3
verdict: REQUEST_CHANGES
---

## Findings

### Blocking
- `a.sh:1` — one blocking thing.
- `b.sh:2` — another blocking thing.

### Advisory
- `c.sh:3` — one advisory thing.

### Process
- process noise that must not be counted
RNEOF
run_tr round-note "$TR_RN" --note "caught the real one, missed nothing" >/dev/null 2>&1
RN_TSV="$TR_FIX/.comms/grades/rounds.tsv"
[ -s "$RN_TSV" ] && ok "round-note writes a rounds ledger" || fail "rounds.tsv"
awk -F'\t' 'NR>1 && $7=="2" && $8=="1"' "$RN_TSV" | grep -q . \
  && ok "round-note DERIVES the counts (2 blocking, 1 advisory) rather than trusting input" || fail "derived counts"
awk -F'\t' 'NR>1 && $5=="codex" && $6=="REQUEST_CHANGES" && $4=="3"' "$RN_TSV" | grep -q . \
  && ok "round-note carries reviewer, verdict and round from the reply" || fail "round-note provenance"
grep -q 'process noise' "$RN_TSV" && fail "### Process leaked into the round ledger" || ok "### Process is not counted as a finding"
awk -F'\t' 'NR>1 && $9!=""' "$RN_TSV" | grep -q . \
  && ok "round-note stamps prompt_version so rounds are comparable only within one" || fail "prompt_version missing"
check_not "round-note requires an assessment" run_tr round-note "$TR_RN"
check_not "round-note rejects a missing file" run_tr round-note "$TR_FIX/nope.md" --note x

# SNAPSHOT ON SEND. Without a pinned artifact the reviewer reads whatever the author
# happens to be typing, and two reviewers on one request race each other — "they read
# the same artifact" is unprovable. Loops only; a consult reviews nothing.
TR_WF2="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-26T10-00-00_wf-2.md"
sed -e 's|^message_id: .*|message_id: wf-2|' -e 's|^thread: .*|thread: tr-stamp|' "$TR_LOOPMSG" > "$TR_WF2"
grep -q '^artifact_id:' "$TR_WF2" && fail "fixture already stamped" || ok "fixture: a loop message with no artifact_id"
run_tr_deliver send --to codex "$TR_WF2" >/dev/null 2>&1 || true
grep -q '^artifact_id:' "$TR_WF2" && ok "send stamps the retained artifact onto a loop message" || fail "send did not stamp artifact_id"
TR_AID="$(grep -m1 '^artifact_id:' "$TR_WF2" | sed 's/^artifact_id: //')"
git -C "$TR_FIX" cat-file -e "${TR_AID}^{commit}" 2>/dev/null \
  && ok "the stamped artifact is a real, resolvable object" || fail "stamped artifact does not resolve"
# Re-sending must not re-stamp: the artifact is pinned at dispatch, not at every retry.
run_tr_deliver send --to codex "$TR_WF2" >/dev/null 2>&1 || true
[ "$(grep -c '^artifact_id:' "$TR_WF2")" = "1" ] && ok "re-sending does not re-stamp or duplicate the field" || fail "artifact_id duplicated on resend"
[ "$(grep -m1 '^artifact_id:' "$TR_WF2" | sed 's/^artifact_id: //')" = "$TR_AID" ] \
  && ok "the pinned artifact does not move on resend" || fail "artifact_id changed on resend"
# A consult has nothing under review.
TR_Q2="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-26T10-01-00_q-2.md"
sed -e 's|^message_id: .*|message_id: q-2|' "$TR_CONSULT" > "$TR_Q2"
run_tr_deliver send --to codex "$TR_Q2" >/dev/null 2>&1 || true
grep -q '^artifact_id:' "$TR_Q2" && fail "a consult was stamped with an artifact" || ok "consults are never stamped — they review nothing"
run_tr_deliver validate "$TR_WF2" >/dev/null 2>&1 && ok "a stamped message still validates" || fail "stamping broke validation"

# Artifact retention FAILS CLOSED: dispatching a loop against an unpinned tree would
# review whatever the working tree holds while the message implies a pinned artifact —
# invisible afterwards. (codex, transport-flip round 4.)
TR_NOGIT="$WORK/not-a-repo"; mkdir -p "$TR_NOGIT/.comms/to-codex"
cp "$TR_LOOPMSG" "$TR_NOGIT/.comms/to-codex/wf.md" 2>/dev/null || true
TR_FC="$( (cd "$TR_NOGIT" && env -u COMMS_DELIVERY "$COMMS" send --to codex "$TR_NOGIT/.comms/to-codex/wf.md") 2>&1 )" && TR_FCRC=0 || TR_FCRC=$?
[ "$TR_FCRC" != "0" ] && ok "a loop outside a git repo is refused, not dispatched unpinned" || fail "unpinned dispatch was allowed"

# CRLF frontmatter must still get stamped, and must stay CRLF.
TR_CRLF="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-26T11-00-00_crlf.md"
sed -e 's|^message_id: .*|message_id: crlf-1|' -e 's|^thread: .*|thread: tr-crlf|' "$TR_LOOPMSG" | sed 's/$/\r/' > "$TR_CRLF"
run_tr_deliver send --to codex "$TR_CRLF" >/dev/null 2>&1 || true
grep -q '^artifact_id:' "$TR_CRLF" && ok "a CRLF message still gets stamped" || fail "CRLF message not stamped"
grep -q $'\r' "$TR_CRLF" && ok "stamping leaves CRLF line endings intact" || fail "stamping rewrote line endings"

# The spawn guard must be ATOMIC: scan-then-create lets two concurrent deliveries both
# spawn, which under panel fan-out is a phantom extra reviewer.
grep -q 'ATOMIC claim' "$REPO/helpers/runphase.sh" && ok "spawn guard documents its atomicity" || fail "spawn guard comment"
grep -q 'mkdir "\$claim"' "$REPO/helpers/runphase.sh" \
  && ok "spawn claims the message with an atomic mkdir, not a scan" || fail "spawn guard is not atomic"
grep -q 'rm -rf "\$claim"' "$REPO/helpers/runphase.sh" \
  && ok "a stale claim from a dead holder is reclaimable" || fail "stale claim is not reclaimable"

check_not "transport rejects an unregistered agent" run_tr transport gemini
check_not "transport rejects an unknown option" run_tr transport codex --bogus

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
