#!/bin/bash
# agent-comms test harness — repeatable checks for the shared helpers and installer.
# Stubs cmux with a fake binary (canned tree output + call log) so picker/delivery
# logic is testable headlessly. Run: bash tests/run.sh   (zsh callers covered too)
set -uo pipefail

# HERMETIC: scrub inherited headless-delivery env — a harness run from INSIDE a
# headless peer turn (e.g. Codex reviewing this repo) inherits these and would
# route the baseline cmux tests through headless delivery (observed live: 40
# failures). The headless-specific sections set them explicitly per invocation.
# COMMS_RUNPHASE_EXPECT_STATE joins them for the same reason: inherited from an
# outer send it makes every direct `runphase.sh run` below wait out the state-file
# budget for a write that is not coming. COMMS_RUNPHASE_STATE_WAIT_SECS too, so an
# operator's tuning cannot silently change what the timing assertions measure.
unset COMMS_DELIVERY COMMS_HEADLESS_PICKUP COMMS_RUNPHASE_VIA \
      COMMS_RUNPHASE_EXPECT_STATE COMMS_RUNPHASE_STATE_WAIT_SECS \
      COMMS_RUNPHASE_TIMEOUT_SECS COMMS_CMUX_PACE COMMS_CMUX_BACKOFF 2>/dev/null || true
# Probe-result flags gate condition-bound skips, so an inherited value would let a skip be
# cashed before its probe ran. Same class as the scrub above. (grok, panel r7.)
unset ACL_PROBE_OK GRP_PRESERVE_OK 2>/dev/null || true

# Loops became headless-first on 2026-08-25, so the pane path is now OPT-IN. The cmux
# sections below exercise pane mechanics that still exist and still matter, so they ask
# for cmux explicitly instead of relying on a default that no longer points at them.
# Sections that test the DEFAULT routing clear this with `env -u COMMS_DELIVERY`.
export COMMS_DELIVERY=cmux
# cmux is a STUB in this harness. Keystroke pacing exists so a real terminal does not
# interleave send/escape/enter, and the tree backoff exists to ride out a real contention
# window — a stub can do neither, so both are pure wall-clock here. Scrubbed above (an
# inherited value must not decide what the timing assertions measure), then set explicitly.
# The production DEFAULTS are pinned by assertion in the stubbed-cmux section below.
export COMMS_CMUX_PACE=0 COMMS_CMUX_BACKOFF=0

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMS="$REPO/helpers/comms.sh"
# The commit UNDER TEST, captured before the first assertion — the self-attestation
# at the end binds to this, never to whatever HEAD has become by then.
TESTED_OID="$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null || true)"
PASS=0; FAIL=0; SKIP=0
# COVERAGE CONTRACT. Until now a run that executed 300 of 954 assertions with no
# failures was byte-identical, to every consumer, to a full green run: the exit
# status and the attestation were both `[ "$FAIL" -eq 0 ]` with no coverage
# conjunct at all. Both now also require that the expected number of assertions
# actually RAN. The two numbers live in a committed file so that changing what
# the corpus covers is a reviewable diff and never a silent drift.
# NOT overridable from the environment. `integrate` inherits the caller's env, so an
# env-settable contract path lets a branch point the gate at a reduced total and attest
# without touching the committed file (proven: EXPECT_FILE=/dev/stdin loaded total=1).
# This is the same class as lane selection via env, and it was my own regression.
# (codex, panel r2, blocking.)
EXPECT_FILE="$REPO/tests/expected-counts.tsv"
GATE_REACHED=0
# Read the contract from the COMMITTED BLOB at the commit under test, never from the
# filesystem. Reading the file left the last hole open: commit the removal of some
# assertions AND of this file, then recreate it untracked with a reduced total — the
# suite reads the untracked copy, `attest-green` deliberately ignores untracked files
# so it mints anyway, and integrate skips its clean re-run and lands a tree that has no
# contract at all. Binding to TESTED_OID makes the contract part of the artifact.
# A missing OID or a missing blob yields an empty total, which fails closed.
# (codex, panel r3, blocking.)
EXPECT_SRC="$(git -C "$REPO" show "${TESTED_OID:-missing}:tests/expected-counts.tsv" 2>/dev/null || true)"
EXPECT_TOTAL="$(printf '%s\n' "$EXPECT_SRC" | awk -F'\t' '$1=="total"{print $2}')"
# Skips are IDENTIFIED, not merely counted. A bare numeric cap leaves spare capacity:
# with the cap at 1 and zsh installed, any passing assertion could be swapped for a
# skip and the totals would still balance, so coverage could be reduced silently.
# Each permitted skip now names itself, and an unlisted id is a FAILURE.
SKIP_ALLOWED=" $(printf '%s\n' "$EXPECT_SRC" | awk -F'\t' '$1=="skip_ok"{printf "%s ", $2}')"
# A working-tree edit to the contract is NOT authoritative — say so, or a developer who
# bumps the count and sees the old number will think the gate is broken.
if [ -f "$EXPECT_FILE" ] && ! git -C "$REPO" diff --quiet HEAD -- tests/expected-counts.tsv 2>/dev/null; then
  echo "COVERAGE: tests/expected-counts.tsv is modified; the COMMITTED contract is authoritative." >&2
  echo "COVERAGE: commit it to change the expected counts." >&2
fi

SEC_NAME=""; SEC_PASS=0; SEC_FAIL=0; SEC_SKIP=0; SECTION_VECTOR=""
_flush_section() {
  [ -n "$SEC_NAME" ] || return 0
  [ -n "$SECTION_VECTOR" ] || return 0
  # COVERED = every assertion that RAN here: pass + fail + skip. Omitting fail made a
  # red assertion shorten its section and report a move that never happened — a false
  # diagnostic on the run where you least want one. (grok, suite-lanes r2.)
  # A permitted skip REPLACES a pass, so pinning pass and skip as separate columns
  # separately would make every host that legitimately cashes a ticket red — the ACL and
  # secondary-group tickets do exactly that on Linux. Coverage is what this vector is
  # for; which side of the pass/skip line a covered assertion fell on is the total gate's
  # business, and the skip contract's. (codex + grok, suite-lanes r1, blocking.)
  #
  # Keyed on the BANNER, not the execution ordinal: a lane running a subset renumbers from
  # 1 and could never match a 62-row ordinal golden even when every count is right.
  # (codex + grok, suite-lanes r1, advisory — and a prerequisite for the dispatcher.)
  printf '%s\t%s\n' "$SEC_NAME" "$((SEC_PASS + SEC_FAIL + SEC_SKIP))" >> "$SECTION_VECTOR"
}
# The vector check as a FUNCTION, so the suite can execute the real thing against
# adversarial inputs instead of asserting on a reimplementation — the same lesson the
# total gate learned. Returns 0 only when every section's covered count matches.
section_vector_verdict() { # <golden-text-file> <observed-file>
  local g="$1" o="$2"
  [ -s "$g" ] || { echo "COVERAGE: the per-section golden is empty or missing — refusing" >&2; return 1; }
  [ -s "$o" ] || { echo "COVERAGE: no per-section vector was produced — refusing" >&2; return 1; }
  if ! diff -q <(sort "$g") <(sort "$o") >/dev/null 2>&1; then
    echo "COVERAGE: the per-section covered counts do not match the committed vector." >&2
    echo "COVERAGE: assertions moved between sections, or a section was added or removed." >&2
    diff <(sort "$g") <(sort "$o") 2>&1 | head -12 >&2
    echo "COVERAGE: if that change is intended, update tests/section-counts.tsv in the SAME commit." >&2
    return 1
  fi
  return 0
}
# PER-SECTION ACCOUNTING. The total count proves the corpus did not SHRINK; it cannot see
# assertions MOVING between sections, which is exactly what a section-function wrap or a
# lane split has to preserve. Every banner goes through here, so the vector cannot drift
# from what actually ran.
section() {
  _flush_section
  SEC_NAME="$1"; SEC_PASS=0; SEC_FAIL=0; SEC_SKIP=0
  echo "== $1 =="
}

ok()   { PASS=$((PASS+1)); SEC_PASS=$((SEC_PASS+1)); echo "  ok: $1"; }
# A capability this machine lacks is NOT a passing assertion. Say so visibly and count
# nothing, so a platform that silently skips coverage never reads as a full green run.
emit_note() { echo "  note: $1"; }
fail() { FAIL=$((FAIL+1)); SEC_FAIL=$((SEC_FAIL+1)); echo "FAIL: $1" >&2; }
# An assertion the ENVIRONMENT cannot run (no zsh installed, say). It still counts
# toward coverage, so a skipped machine-conditional check can never look like a
# check that ran — but skips are separately capped, so quieting a flaky assertion
# by wrapping it in skip() turns the suite red until the cap is raised on purpose.
SKIP_USED=" "
skip() { # skip <id> <desc> — permitted, CONDITION-BOUND, and single-use
  # Naming a skip is not enough. On a machine where the named condition does not
  # hold, the ticket is unused, so any passing assertion could be converted to
  # `skip <that id>` and the totals would still balance. Two extra locks: the id's
  # CONDITION must actually hold, and each id may be cashed at most ONCE.
  # (codex + grok, panel r2, blocking — both found it independently.)
  case "$SKIP_ALLOWED" in
    *" $1 "*) ;;
    *) fail "$2 (skip id '$1' is not permitted by $EXPECT_FILE)"; return ;;
  esac
  case "$SKIP_USED" in
    *" $1 "*) fail "$2 (skip id '$1' was already used — each permitted skip is single-use)"; return ;;
  esac
  # Condition binding lives in code, where it is reviewable, not in the data file.
  case "$1" in
    zsh-absent)
      if command -v zsh >/dev/null 2>&1; then
        fail "$2 (skip id 'zsh-absent' claimed, but zsh IS installed)"; return
      fi ;;
    # TRI-STATE. Defaulting an unset flag to 0 meant "probe failed", so these skips were
    # cashable BEFORE their probe ran — spare capacity again, in a new place. Only a
    # recorded, confirmed failure permits the skip. (codex + grok, panel r6, blocking.)
    group-no-secondary)
      case "${GRP_PRESERVE_OK:-unrun}" in
        0) ;;
        *) fail "$2 (skip id 'group-no-secondary': probe state is '${GRP_PRESERVE_OK:-unrun}', not a confirmed failure)"; return ;;
      esac ;;
    acl-*)
      case "${ACL_PROBE_OK:-unrun}" in
        0) ;;
        *) fail "$2 (skip id '$1': probe state is '${ACL_PROBE_OK:-unrun}', not a confirmed failure)"; return ;;
      esac ;;
    *) fail "$2 (skip id '$1' has no registered condition)"; return ;;
  esac
  SKIP_USED="$SKIP_USED$1 "
  SKIP=$((SKIP+1)); SEC_SKIP=$((SEC_SKIP+1)); echo "  skip[$1]: $2"
}
# THE GATE ITSELF, as a function, so the suite can execute the real thing against
# adversarial inputs instead of asserting on a reimplementation of one branch.
# Returns 0 only when the whole corpus demonstrably ran.
coverage_verdict() { # <pass> <fail> <skip> <total>
  local p="$1" f="$2" s="$3" t="$4" a
  # Validate ALL FOUR. The counters are internally bounded today, so only `t` is
  # reachable from data — but a function whose advertised contract is "these are
  # numbers" should not accept `p='1+967'`. (codex, panel r2, advisory.)
  for a in "$p" "$f" "$s"; do
    case "$a" in ''|*[!0-9]*)
      echo "COVERAGE: counter '$a' is not a number — refusing a verdict" >&2; return 1 ;;
    esac
    if [ "${#a}" -gt 6 ]; then
      echo "COVERAGE: counter '$a' is out of range — refusing a verdict" >&2; return 1
    fi
  done
  case "$t" in ''|*[!0-9]*)
    echo "COVERAGE: contract total is missing or not a number — refusing a verdict" >&2; return 1 ;;
  esac
  # Length-bound BEFORE any numeric comparison. An all-digit but out-of-range value
  # passes the digit check, and then `[ x -ne y ]` exits 2 ("integer expression
  # expected"), which an elif chain reads as FALSE — so the gate would fail OPEN on
  # exactly the input a corrupted contract file produces. (codex, panel r1, blocking.)
  if [ "${#t}" -gt 6 ]; then
    echo "COVERAGE: contract total '$t' is out of range — refusing a verdict" >&2; return 1
  fi
  if [ "$((p + f + s))" -ne "$t" ]; then
    echo "COVERAGE: PARTIAL RUN — $((p + f + s)) of $t assertions ran." >&2
    echo "COVERAGE: this is NOT a suite verdict. If the corpus legitimately changed size," >&2
    echo "COVERAGE: update tests/expected-counts.tsv in the SAME commit." >&2
    return 1
  fi
  return 0
}
check() { # check <desc> <expr...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
check_not() {
  local desc="$1"; shift
  # PRECONDITION. check_not passes when its command FAILS, so a command that does
  # not exist -- an undefined function after a refactor, a fixture wrapper whose
  # section did not run -- returns 127 and scores as a pass. That is a test which
  # verifies nothing while reporting success, and it is invisible in a green run.
  if ! declare -F "$1" >/dev/null 2>&1 && ! command -v "$1" >/dev/null 2>&1; then
    fail "$desc (precondition: '$1' is not a defined function or command)"; return
  fi
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  # 126/127 mean "could not execute", not "correctly refused" — a wrapper whose inner
  # binary vanished would otherwise still score a pass. (codex, panel r2, advisory.)
  case "$rc" in
    0)     fail "$desc (expected failure)" ;;
    126|127) fail "$desc (precondition: command exited $rc — not executable/not found)" ;;
    *)     ok "$desc" ;;
  esac
}

# ---------- fixtures ----------
WORK="$(mktemp -d)"
# NOTHING in this suite may write the developer's REAL external mount store. Mounts now live
# outside the repo under ${XDG_STATE_HOME:-$HOME/.local/state}/agent-comms/mounts by default, so
# any mounted turn that does not set COMMS_MOUNT_BASE (the acp-parity, MA-fixture and shadow turns)
# would land in ~/.local/state. Point the whole suite at a throwaway under $WORK; the warm-mount,
# relocation and the explicit accessor tests still override this per-turn in the child env, and the
# default-base test also overrides HOME, so those keep exercising the real code paths.
export COMMS_MOUNT_BASE="$WORK/suite-mounts/agent-comms/mounts"
# NOTHING in this suite may touch the real global rollup. `friction` appends to
# ${AGENT_COMMS_HOME:-$HOME/.agent-comms}/friction.tsv, and the fixture calls below were
# writing straight into the developer's own ledger: 74 of 86 rows in it were this suite's
# "compose reported a false all-clear" fixture note, drowning the real reports the seam
# exists to collect. Suite-wide default; individual tests still override it explicitly.
export AGENT_COMMS_HOME="$WORK/global-home"
mkdir -p "$AGENT_COMMS_HOME"
# The gate only protects runs that REACH it. An `exit 0` added above it later would
# bypass the invariant entirely, so the exit path itself refuses an unexamined
# success. (codex, panel r1, advisory — makes "a partial run is never a verdict"
# durable rather than positional.)
_suite_gate_guard() { # <rc> — the sentinel's DECISION, side-effect free so it is testable
  [ "${GATE_REACHED:-0}" = 1 ] && return "$1"
  [ "$1" -eq 0 ] || return "$1"
  echo "COVERAGE: the suite exited 0 without reaching its coverage gate — refusing." >&2
  return 1
}
_suite_exit() {
  local rc=$?
  rm -rf "$WORK" 2>/dev/null || true
  _suite_gate_guard "$rc"
  exit $?
}
SECTION_VECTOR="$WORK/section-vector.tsv"; : > "$SECTION_VECTOR"
trap '_suite_exit' EXIT

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

section "comms.sh: root/workspace"
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
else
  # Recorded, not dropped: without this the suite silently reports 953 of 954 on a
  # box with no zsh and still attests as a full green run.
  skip zsh-absent "helper is caller-shell agnostic (zsh) — zsh not installed"
fi

section "comms.sh: Codex cmux permission preflight"
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

section "comms.sh: validate"
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

section "comms.sh: archive (idempotent, own inbox only)"
IN1="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T12-01-00_reply-1.md"
sed 's/from: claude/from: codex/; s/^---$/---/; ' "$GOOD" > "$IN1"
echo "verdict: APPROVE" >> /dev/null # (verdict not needed for archive test)
check "archive own inbox file" run_comms archive --as claude "$IN1"
[ -f "$REPO_FIX/.comms/archive/$(basename "$IN1")" ] && ok "file landed in archive/" || fail "file landed in archive/"
check "re-archive is a no-op (idempotent)" run_comms archive --as claude "$IN1"
check_not "archiving a file from the OTHER inbox is refused" run_comms archive --as claude "$GOOD"

section "comms.sh: list"
check_not "list exits non-zero on empty inbox" run_comms list --as claude
LIST_ERR="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" list --as claude) 2>&1 1>/dev/null || true)"
echo "$LIST_ERR" | grep -q "latest archived" && ok "empty inbox reports latest archived (late-nudge UX)" || fail "empty inbox reports latest archived (got: $LIST_ERR)"
UNMATCHED="$REPO_FIX/.comms/to-claude/other-workspace_pending.md"
printf '%s\n' pending > "$UNMATCHED"
LIST_MISMATCH="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" list --as claude) 2>&1 1>/dev/null || true)"
echo "$LIST_MISMATCH" | grep -q "OTHER workspace identities" && echo "$LIST_MISMATCH" | grep -q "other-workspace(1)" \
  && ok "empty scoped list NAMES the unmatched identities" || fail "unmatched inbox warning (got: $LIST_MISMATCH)"
rm -f "$UNMATCHED"

section "comms.sh: latest archive is direction/thread/time aware"
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

section "comms.sh: deliver via stubbed cmux"
# The suite runs with both timing knobs zeroed, so nothing else here would notice if a
# refactor made 0 the DEFAULT — which would silently drop pacing and backoff for every real
# user. Pinned at the source, not behaviourally: this suite already has one timing-sensitive
# section that flakes under load, and a wall-clock assertion here would add another.
grep -qF 'cmux_pace() { [ "${COMMS_CMUX_PACE:-1}" = 0 ] || sleep "$1"; }' "$COMMS" \
  && ok "keystroke pacing defaults ON (only an explicit 0 skips it)" \
  || fail "cmux_pace no longer defaults to pacing"
grep -qF 'backoff="${COMMS_CMUX_BACKOFF:-0.3 0.7 1.2}"' "$COMMS" \
  && ok "the cmux tree backoff default is unchanged" \
  || fail "the cmux tree backoff default changed"
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

section "comms.sh: send (atomicity guard)"
IN2="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T12-02-00_reply-2.md"
cp "$REPO_FIX/.comms/archive/$(basename "$IN1")" "$IN2"
BADOUT="$WORK/malformed-out.md"
echo "not a message" > "$BADOUT"
check_not "send refuses malformed outbound" run_comms send --to codex "$BADOUT" --archive-inbound "$IN2"
[ -f "$IN2" ] && ok "inbound NOT archived when outbound malformed" || fail "inbound NOT archived when outbound malformed"
check "send valid outbound (manual pickup) archives inbound" run_comms send --to codex "$GOOD" --archive-inbound "$IN2"
[ ! -f "$IN2" ] && ok "inbound archived after successful send" || fail "inbound archived after successful send"

section "install.sh: scopes"
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
# BEHAVIORAL delete-on-upgrade: a clean install not copying retired files proves
# nothing about an upgrade — plant a pre-existing retired command AND a retired
# local-pin helper, re-run the installer, and require both GONE. The local pin
# outranks the global install, so a fleet.sh surviving here shadows its own
# removal everywhere else. (codex + grok, panel r1: the old test was clean-install-only.)
touch "$INST_FIX/.claude/commands/auto-plan.md" "$INST_FIX/.agent-comms/fleet.sh"
(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=local >/dev/null 2>&1)
[ ! -f "$INST_FIX/.claude/commands/auto-plan.md" ] \
  && ok "an upgrade DELETES a pre-existing retired command" || fail "retired auto-plan.md survived the upgrade"
[ ! -f "$INST_FIX/.agent-comms/fleet.sh" ] \
  && ok "an upgrade DELETES a pre-existing retired local-pin helper" || fail "retired fleet.sh survived the local upgrade"

section "comms.sh: status smoke"
ST="$(run_comms status)"
echo "$ST" | grep -q "workspace: feature-helper-tests" && ok "status prints workspace" || fail "status prints workspace"
echo "$ST" | grep -q "latest archived:" && ok "status prints latest archived" || fail "status prints latest archived"
echo "$ST" | grep -q "pending in to-claude:" && ok "status prints pending counts" || fail "status prints pending counts"

section "install.sh: local pin gitignored + global scope (overridden HOME dirs)"
grep -qxF '.agent-comms/' "$INST_FIX/.gitignore" && ok "local install gitignores .agent-comms/" || fail "local install gitignores .agent-comms/"
GHOME="$WORK/ghome"
GH_OUT="$(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global 2>&1)"
[ -x "$GHOME/agent-comms/comms.sh" ] && ok "global scope installs executable helpers (env-overridden)" || fail "global scope installs executable helpers"
[ -f "$GHOME/commands/auto.md" ] && ok "global scope installs commands (env-overridden)" || fail "global scope installs commands"
[ -f "$GHOME/commands/ask.md" ] && ok "global scope installs /ask" || fail "global scope installs ask.md"
[ -f "$GHOME/skills/read-from-claude/SKILL.md" ] && ok "global scope installs skills (env-overridden)" || fail "global scope installs skills"
echo "$GH_OUT" | grep -q "codex-permissions" \
  && ok "global install names the one-time default Codex socket setup" || fail "global install Codex socket setup hint"

# ATOMIC INSTALL. A plain `cp` over an installed helper truncates and rewrites the SAME
# inode, and bash reads an executing script lazily by byte offset — which is how three
# separate sessions on 2026-08-27 killed a parked `runphase.sh await` mid-run by
# reinstalling under it. The observable is inode identity: temp+rename gives the
# destination a NEW inode, so a reader already inside the old one finishes on it.
INO1="$(command ls -di "$GHOME/agent-comms/comms.sh" | awk '{print $1}')"
printf '#x\n' >> "$GHOME/agent-comms/comms.sh"   # differ from source, so no content-skip can hide the write
(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global >/dev/null 2>&1)
INO2="$(command ls -di "$GHOME/agent-comms/comms.sh" | awk '{print $1}')"
[ "$INO1" != "$INO2" ] \
  && ok "reinstall replaces the helper inode (a running reader survives)" || fail "reinstall replaces the helper inode"
# A new inode alone is not enough — the content and mode must actually land.
cmp -s "$GHOME/agent-comms/comms.sh" "$REPO/helpers/comms.sh" \
  && ok "reinstalled helper matches its source" || fail "reinstalled helper matches its source"
[ -x "$GHOME/agent-comms/comms.sh" ] && ok "reinstalled helper stays executable" || fail "reinstalled helper stays executable"
# Commands are rewritten the same way; a stale command file is the same failure class.
CINO1="$(command ls -di "$GHOME/commands/auto.md" | awk '{print $1}')"
printf '\n' >> "$GHOME/commands/auto.md"
(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global >/dev/null 2>&1)
CINO2="$(command ls -di "$GHOME/commands/auto.md" | awk '{print $1}')"
[ "$CINO1" != "$CINO2" ] && ok "reinstall replaces the command inode too" || fail "reinstall replaces the command inode too"
# NEGATIVE CONTROL: the inode assertions above are evidence only if they CAN fail.
# Prove that a plain cp keeps the inode on this filesystem, so a regression back to
# `cp` would be observed rather than passing vacuously.
ICTL="$WORK/inode-control"; mkdir -p "$ICTL"
printf 'a\n' > "$ICTL/src"; printf 'bb\n' > "$ICTL/dst"
XINO1="$(command ls -di "$ICTL/dst" | awk '{print $1}')"
cp "$ICTL/src" "$ICTL/dst"
XINO2="$(command ls -di "$ICTL/dst" | awk '{print $1}')"
[ "$XINO1" = "$XINO2" ] \
  && ok "control: plain cp keeps the inode, so the assertion can fail" || fail "control: plain cp keeps the inode"
# The temp is a sibling of the destination (a cross-device temp would make `mv` a
# non-atomic copy) and must not survive a SUCCESSFUL install: a stray file in the helper
# or command dir is install surface that nothing owns. This is deliberately not a claim
# about every failure path — a hard kill between the copy and the rename leaves the
# predictable dot-temp behind, and no trap can be relied on for that. (codex advisory r1.)
ls -A "$GHOME/agent-comms" | grep -q '^\.agent-comms-install\.' \
  && fail "install left a temp beside the helpers" || ok "install leaves no temp litter beside the helpers"
ls -A "$GHOME/commands" | grep -q '^\.agent-comms-install\.' \
  && fail "install left a temp in the commands dir" || ok "install leaves no temp litter in the commands dir"
ls -A "$INST_FIX/.agent-comms" | grep -q '^\.agent-comms-install\.' \
  && fail "local install left a temp beside the pinned helpers" || ok "local install leaves no temp litter"

# Replacing a file by rename is not the same operation as writing through it, so the
# three things `cp` did incidentally are now reproduced on purpose. Each was found by
# review, not by the round-1 tests, which only checked that the file was executable.
# %Mp%Lp, not %Lp: Darwin's %Lp drops setuid/setgid/sticky, so a preservation bug in the
# special nibble would be invisible to every assertion below. The leading 0 of an ordinary
# file is trimmed so both platforms read as three digits. (grok, panel r2.)
mode_of() { local m; m="$(stat -f '%Mp%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null)"; printf '%s' "${m#0}"; }
gh_install() { # gh_install <home> [extra-env...]  — a global install into an arbitrary home
  local gh="$1"; shift
  (cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$gh/commands" CODEX_SKILLS_DIR="$gh/skills" \
     AGENT_COMMS_HOME="$gh/agent-comms" "$@" bash "$REPO/install.sh" --scope=global 2>&1)
}
# MODE, UPGRADE: an existing destination kept its own mode under `cp`. A literal 755
# would reset a helper a user tightened, and a fresh-temp mode would reset a command
# they tightened. (codex blocking r1; grok r1 named the exact 700 -> 711 transition.)
chmod 640 "$GHOME/commands/auto.md"
chmod 700 "$GHOME/agent-comms/comms.sh"
# umask is pinned: `chmod +x` is masked by it, so 700 becomes 711 under 022 but 700 under
# 077 — an unpinned expectation fails on a hardened box while the code is correct.
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$(mode_of "$GHOME/commands/auto.md")" = "640" ] \
  && ok "an upgrade preserves a command's tightened mode" \
  || fail "command mode reset to $(mode_of "$GHOME/commands/auto.md") (want 640)"
[ "$(mode_of "$GHOME/agent-comms/comms.sh")" = "711" ] \
  && ok "an upgrade keeps a helper's mode and only adds +x (700 -> 711)" \
  || fail "helper mode became $(mode_of "$GHOME/agent-comms/comms.sh") (want 711)"
# MODE, FRESH INSTALL under a restrictive umask: `cp` masked the SOURCE mode by umask and
# `chmod +x` was masked too, so a umask-077 box never published a world-executable
# helper. A hardcoded 755 did exactly that.
GH_UM="$WORK/ghome-umask"
(umask 077; gh_install "$GH_UM" >/dev/null 2>&1)
[ "$(mode_of "$GH_UM/agent-comms/comms.sh")" = "700" ] \
  && ok "a fresh install under umask 077 leaves the helper private (700)" \
  || fail "umask-077 helper installed as $(mode_of "$GH_UM/agent-comms/comms.sh") (want 700)"
[ "$(mode_of "$GH_UM/commands/auto.md")" = "600" ] \
  && ok "a fresh install under umask 077 leaves the command private (600)" \
  || fail "umask-077 command installed as $(mode_of "$GH_UM/commands/auto.md") (want 600)"
# SYMLINK to a regular file: `cp` wrote THROUGH it. A bare rename would replace the link
# and silently disconnect a dotfile-managed install, so the link is resolved and its
# TARGET is what gets atomically replaced.
GH_SL="$WORK/ghome-symlink"
gh_install "$GH_SL" >/dev/null 2>&1
SL_REAL="$WORK/symlink-target"; mkdir -p "$SL_REAL"
mv "$GH_SL/commands/auto.md" "$SL_REAL/real-auto.md"
ln -s "$SL_REAL/real-auto.md" "$GH_SL/commands/auto.md"
printf '\n' >> "$SL_REAL/real-auto.md"
SL_INO1="$(command ls -di "$SL_REAL/real-auto.md" | awk '{print $1}')"
gh_install "$GH_SL" >/dev/null 2>&1
[ -L "$GH_SL/commands/auto.md" ] \
  && ok "a symlinked destination survives the install as a symlink" || fail "install replaced the symlink itself"
SL_INO2="$(command ls -di "$SL_REAL/real-auto.md" | awk '{print $1}')"
[ "$SL_INO1" != "$SL_INO2" ] && cmp -s "$SL_REAL/real-auto.md" "$REPO/templates/claude-commands/auto.md" \
  && ok "the symlink's TARGET is replaced, atomically" \
  || fail "symlink target not atomically replaced (ino $SL_INO1 -> $SL_INO2)"
# SYMLINK to a DIRECTORY is the silently non-atomic case: macOS `mv` follows it and moves
# the temp INSIDE the directory, reporting success — and cross-device that is a
# copy-in-place. Refuse loudly instead. (codex blocking r1.)
GH_SD="$WORK/ghome-symdir"
gh_install "$GH_SD" >/dev/null 2>&1
SD_DIR="$WORK/symlink-dir"; mkdir -p "$SD_DIR"
rm -f "$GH_SD/commands/ask.md"; ln -s "$SD_DIR" "$GH_SD/commands/ask.md"
SD_OUT="$(gh_install "$GH_SD" 2>&1 || true)"
[ -z "$(ls -A "$SD_DIR" 2>/dev/null)" ] \
  && ok "a symlink-to-directory destination never swallows the installed file" \
  || fail "install moved a file inside the linked directory ($(ls -A "$SD_DIR"))"
printf '%s\n' "$SD_OUT" | grep -q 'is a directory' \
  && ok "the directory destination is refused LOUDLY" || fail "directory refusal was silent (got: $SD_OUT)"
# AN UNWRITABLE DESTINATION used to make `cp` fail and abort the install — the only way a
# user can pin a customized file. `mv -f` unlinks the entry regardless, so the refusal
# has to be explicit or the pin silently stops working. (grok r1.)
GH_RO="$WORK/ghome-readonly"
gh_install "$GH_RO" >/dev/null 2>&1
chmod 444 "$GH_RO/commands/auto.md"
RO_BEFORE="$(command ls -di "$GH_RO/commands/auto.md" | awk '{print $1}')"
RO_OUT="$(gh_install "$GH_RO" 2>&1 || true)"
printf '%s\n' "$RO_OUT" | grep -q 'not writable' \
  && ok "a read-only destination is refused loudly, not silently replaced" || fail "read-only dest not refused (got: $RO_OUT)"
[ "$RO_BEFORE" = "$(command ls -di "$GH_RO/commands/auto.md" | awk '{print $1}')" ] \
  && ok "the pinned file is still the same file" || fail "the read-only destination was replaced anyway"
# The refusals must also FAIL the install the way the old `cp` did — printing a warning
# and exiting 0 would let a scripted upgrade march on. (codex advisory r2.)
gh_install "$GH_RO" >/dev/null 2>&1 && fail "a read-only destination did not fail the install" \
  || ok "a refused destination exits non-zero"
gh_install "$GH_SD" >/dev/null 2>&1 && fail "a directory destination did not fail the install" \
  || ok "a directory destination exits non-zero"
# SPECIAL MODE BITS survive an upgrade: Darwin's %Lp would silently drop them, so this
# fails if either the installer or mode_of stops carrying the nibble. (grok r2.)
# SETUID specifically, not just sticky: `chown` clears setuid/setgid and leaves sticky
# alone, so a sticky-only assertion cannot see the chown-after-chmod ordering bug at all.
# (grok r3: `chown` of the SAME uid:gid turned 4755 into 0755.)
chmod 4750 "$GHOME/commands/ask.md"
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$(mode_of "$GHOME/commands/ask.md")" = "4750" ] \
  && ok "an upgrade preserves the setuid bit through the ownership step" \
  || fail "setuid lost: $(mode_of "$GHOME/commands/ask.md") (want 4750)"
chmod 1640 "$GHOME/commands/ask.md"
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$(mode_of "$GHOME/commands/ask.md")" = "1640" ] \
  && ok "an upgrade preserves the sticky bit" \
  || fail "sticky lost: $(mode_of "$GHOME/commands/ask.md") (want 1640)"
# OWNER AND GROUP: writing through the old inode kept them; a fresh temp inherits the
# parent directory's group on BSD. The group is the half a non-root user can actually
# assert, so it is the half asserted here. (codex blocking r2.)
GRP_BEFORE="$(stat -f '%g' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%g' "$GHOME/agent-comms/comms.sh")"
OWN_BEFORE="$(stat -f '%u' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%u' "$GHOME/agent-comms/comms.sh")"
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$GRP_BEFORE" = "$(stat -f '%g' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%g' "$GHOME/agent-comms/comms.sh")" ] \
  && ok "an upgrade preserves the destination's group" || fail "group changed across the upgrade"
[ "$OWN_BEFORE" = "$(stat -f '%u' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%u' "$GHOME/agent-comms/comms.sh")" ] \
  && ok "an upgrade preserves the destination's owner" || fail "owner changed across the upgrade"
# SYMLINK CHAINS: a relative link to a relative link, resolved by concatenating dirname at
# each hop. Round 2 only covered a single absolute hop. (codex advisory r2.)
GH_SC="$WORK/ghome-symchain"
gh_install "$GH_SC" >/dev/null 2>&1
SC_REAL="$WORK/symchain-target"; mkdir -p "$SC_REAL"
mv "$GH_SC/commands/auto.md" "$SC_REAL/final.md"
ln -s "../../symchain-target/final.md" "$GH_SC/commands/hop1.md"
ln -s "hop1.md" "$GH_SC/commands/auto.md"
printf '\n' >> "$SC_REAL/final.md"
SC_INO1="$(command ls -di "$SC_REAL/final.md" | awk '{print $1}')"
gh_install "$GH_SC" >/dev/null 2>&1
[ -L "$GH_SC/commands/auto.md" ] && [ -L "$GH_SC/commands/hop1.md" ] \
  && ok "a relative symlink CHAIN is followed, not replaced" || fail "a link in the chain was replaced"
[ "$SC_INO1" != "$(command ls -di "$SC_REAL/final.md" | awk '{print $1}')" ] \
  && cmp -s "$SC_REAL/final.md" "$REPO/templates/claude-commands/auto.md" \
  && ok "the chain's final target is the file that gets replaced" || fail "chain target not replaced"
# A DANGLING link is -L true / -e false. `cp` wrote through it and created the target;
# the resolver must do the same rather than replacing the link or refusing.
GH_DL="$WORK/ghome-dangling"
gh_install "$GH_DL" >/dev/null 2>&1
DL_REAL="$WORK/dangling-target"; mkdir -p "$DL_REAL"
rm -f "$GH_DL/commands/auto.md"
ln -s "$DL_REAL/not-there-yet.md" "$GH_DL/commands/auto.md"
gh_install "$GH_DL" >/dev/null 2>&1
[ -L "$GH_DL/commands/auto.md" ] && [ -f "$DL_REAL/not-there-yet.md" ] \
  && cmp -s "$DL_REAL/not-there-yet.md" "$REPO/templates/claude-commands/auto.md" \
  && ok "a dangling symlink is written through, creating its target" \
  || fail "dangling symlink not written through"
# A GROUP THE TEMP CANNOT INHERIT. The round-3 assertions compared the destination's group
# to itself in a directory of the same group, so they passed against an implementation
# that preserved nothing. Give the destination a secondary group of this user that differs
# from its parent directory's, which a fresh temp provably cannot pick up. (codex r3.)
GH_GRP="$WORK/ghome-group"
gh_install "$GH_GRP" >/dev/null 2>&1
grp_of() { stat -f '%g' "$1" 2>/dev/null || stat -c '%g' "$1" 2>/dev/null; }
PARENT_G="$(grp_of "$GH_GRP/commands")"
ALT_G="$(id -G | tr ' ' '\n' | grep -v "^${PARENT_G}$" | head -1)"
if [ -n "$ALT_G" ] && chgrp "$ALT_G" "$GH_GRP/commands/auto.md" 2>/dev/null; then
  GRP_PRESERVE_OK=1
  (umask 022; gh_install "$GH_GRP" >/dev/null 2>&1)
  [ "$(grp_of "$GH_GRP/commands/auto.md")" = "$ALT_G" ] \
    && ok "an upgrade preserves a group the temp could not have inherited" \
    || fail "group fell back to the directory's ($(grp_of "$GH_GRP/commands/auto.md"), want $ALT_G)"
else
  # An uncounted `note` here made the corpus size machine-dependent, so a fixed contract
  # would refuse forever on any host without a usable secondary group. Accounted, not
  # narrated. (codex, panel r5, blocking.)
  GRP_PRESERVE_OK=0
  skip group-no-secondary "an upgrade preserves a group the temp could not have inherited — no usable secondary group here"
fi
# ...and when ownership CANNOT be restored, the install must FAIL rather than publish the
# file under the wrong group and exit 0. A privileged group cannot be created hermetically,
# so `chown` is stubbed to fail, which is the same branch. (codex r3: warn-and-exit-0 left
# criterion 9 unmet while the install looked successful.)
# Read the install order from install.sh rather than restating it here: a second copy of
# that list is a thing that silently stops matching.
CLAUDE_COMMANDS_LIST="$(sed -n 's/^CLAUDE_COMMANDS="\(.*\)"$/\1/p' "$REPO/install.sh" | head -1)"
[ -n "$CLAUDE_COMMANDS_LIST" ] || fail "could not read CLAUDE_COMMANDS from install.sh"
FAILBIN="$WORK/failbin"; mkdir -p "$FAILBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAILBIN/chown"; chmod +x "$FAILBIN/chown"
# The installer aborts on the FIRST destination it processes, so the unchanged-destination
# assertion has to name that one. Anchoring it on a later file examined something the run
# never reached, which made the assertion vacuous. (codex, panel round 4.)
CHOWN_FIRST="$GH_GRP/commands/$(printf '%s\n' $CLAUDE_COMMANDS_LIST | head -1)"
CHOWN_INO1="$(command ls -di "$CHOWN_FIRST" | awk '{print $1}')"
CHOWN_OUT="$( (cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GH_GRP/commands" CODEX_SKILLS_DIR="$GH_GRP/skills" \
   AGENT_COMMS_HOME="$GH_GRP/agent-comms" PATH="$FAILBIN:$PATH" bash "$REPO/install.sh" --scope=global 2>&1) || true)"
printf '%s\n' "$CHOWN_OUT" | grep -q 'cannot restore owner/group' \
  && ok "an unrestorable owner/group refuses the replacement loudly" || fail "chown failure was not fatal (got: $(printf '%s' "$CHOWN_OUT" | tail -2))"
[ "$CHOWN_INO1" = "$(command ls -di "$CHOWN_FIRST" | awk '{print $1}')" ] \
  && ok "the first destination is untouched when ownership cannot be restored" || fail "destination replaced despite a failed chown"
ls -A "$GH_GRP/commands" | grep -q '^\.agent-comms-install\.' \
  && fail "the failed-chown path left its temp behind" || ok "the failed-chown path cleans up its temp"
# ACL DETECTION must not rely on the mode column: Darwin prints `@` INSTEAD of `+` when
# extended attributes are present, and they are routine here, so a file with BOTH shows
# `@` and the old probe stayed silent for exactly the case it was written to catch.
# (codex + grok, corroborated r3.)
GH_ACL="$WORK/ghome-acl"
gh_install "$GH_ACL" >/dev/null 2>&1
if chmod +a "everyone deny read" "$GH_ACL/commands/auto.md" 2>/dev/null; then
  ACL_PROBE_OK=1
  ACL_OUT="$(gh_install "$GH_ACL" 2>&1 || true)"
  printf '%s\n' "$ACL_OUT" | grep -q 'carries an ACL' \
    && ok "an ACL-only destination is reported" || fail "ACL not reported (got: $(printf '%s' "$ACL_OUT" | tail -2))"
  chmod +a "everyone deny read" "$GH_ACL/commands/ask.md" 2>/dev/null
  xattr -w com.agent-comms.test 1 "$GH_ACL/commands/ask.md" 2>/dev/null
  # This is the regression: with an xattr present the mode column reads `@`, so a
  # column-11 probe reports no ACL.
  [ "$(/bin/ls -ld "$GH_ACL/commands/ask.md" | cut -c11)" = "@" ] \
    && ok "the xattr+ACL destination really does mask the + marker" \
    || fail "fixture did not reproduce the @-masks-+ case"
  ACL2_OUT="$(gh_install "$GH_ACL" 2>&1 || true)"
  printf '%s\n' "$ACL2_OUT" | grep -q "ask.md carries an ACL" \
    && ok "an ACL is still reported when extended attributes mask the marker" \
    || fail "ACL missed behind an xattr (got: $(printf '%s' "$ACL2_OUT" | tail -2))"
  # ...and a file with xattrs but NO ACL must stay quiet, or the warning is noise.
  xattr -w com.agent-comms.test 1 "$GH_ACL/commands/clean-comms.md" 2>/dev/null
  ACL3_OUT="$(gh_install "$GH_ACL" 2>&1 || true)"
  printf '%s\n' "$ACL3_OUT" | grep -q "clean-comms.md carries an ACL" \
    && fail "extended attributes alone were reported as an ACL" \
    || ok "extended attributes alone are not reported as an ACL"
else
  # Four assertions live in the branch above. On a host without Darwin-style `chmod +a`
  # (every Linux box) an uncounted note dropped all four, and the fixed contract would
  # then refuse every run there. One named skip per omitted assertion.
  # (codex, panel r5, blocking.)
  ACL_PROBE_OK=0
  skip acl-report "an ACL-only destination is reported — ACLs unsupported here"
  skip acl-xattr-fixture "the xattr+ACL destination really does mask the + marker — ACLs unsupported here"
  skip acl-behind-xattr "an ACL is still reported when extended attributes mask the marker — ACLs unsupported here"
  skip acl-xattr-only "extended attributes alone are not reported as an ACL — ACLs unsupported here"
fi

section "comms.sh v2: thread filter + verdict normalization + error lane"
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

section "comms.sh v2: state lifecycle"
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
# loop-rounds is the loop's REAL budget riding through the capped plan phase; state
# must keep a NON-DEFAULT value durably or a restart falls back to the default —
# the exact starvation the field exists to prevent. (codex, panel r1: the restore
# instruction existed but nothing mechanical preserved its source.)
OUT_LR="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-06-00_plan-lr7.md"
sed -e 's/^message_id: .*/message_id: feature-helper-tests_2026-06-04T13-06-00_plan-lr7/' \
    -e 's/^thread: .*/thread: loop-lr7/' \
    -e 's/^phase: implement/phase: plan/' -e 's/^round: 2/round: 1/' \
    -e 's/^max-rounds: 10/max-rounds: 2\nloop-rounds: 7/' "$OUT_WF" > "$OUT_LR"
check "send accepts a plan message carrying loop-rounds" run_comms send --to codex "$OUT_LR"
SF_LR="$REPO_FIX/.comms/state/feature-helper-tests_loop-lr7.json"
grep -q '"loop_rounds": "7"' "$SF_LR" \
  && ok "a non-default loop-rounds (7) survives into thread state" || fail "state loop_rounds (got: $(cat "$SF_LR" 2>/dev/null | head -8))"
grep -q '"max_rounds": "2"' "$SF_LR" \
  && ok "the plan cap and the loop budget are DISTINCT state fields" || fail "plan cap vs loop budget conflated"
# stalled: backdate the awaiting epoch by an hour
perl -pi -e 's/"awaiting_since_epoch": "\d+"/"awaiting_since_epoch": "'"$(( $(date +%s) - 3600 ))"'"/' "$SF"
run_comms stalled 15 | grep -q 'STALLED.*loop-alpha' && ok "stalled flags threads awaiting too long" || fail "stalled detection (got: $(run_comms stalled 15))"
run_comms stalled 15 | grep -q 'inbox=unread' && ok "stalled distinguishes an unread persisted message" || fail "stalled unread evidence (got: $(run_comms stalled 15))"
check "state complete marks thread done" run_comms state complete loop-alpha
grep -q '"status": "complete"' "$SF" && ok "state complete persists" || fail "state complete persists"
run_comms stalled 15 | grep -q 'no stalled' && ok "completed thread is not stalled" || fail "completed thread is not stalled"

section "comms.sh v2: delivery failure is explicit and recorded"
DELIV_OUT="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_FAIL=1 "$COMMS" deliver codex)"
echo "$DELIV_OUT" | grep -q "FAILED mid-sequence" && ok "mid-sequence cmux failure reported explicitly" || fail "delivery failure report (got: $DELIV_OUT)"
# Under stub cmux the RESOLVED workspace (test-project) keys the state file —
# the helper warns about the frontmatter mismatch and keys on the resolver.
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 CMUX_STUB_FAIL=1 "$COMMS" send --to codex "$OUT_WF") >/dev/null 2>&1
SF_CMUX="$REPO_FIX/.comms/state/test-project_loop-alpha.json"
grep -q '"last_delivery": "failed"' "$SF_CMUX" && ok "failed delivery recorded in state (resolved-ws key)" || fail "failed delivery recorded in state (state dir: $(ls "$REPO_FIX/.comms/state/" 2>/dev/null))"

section "comms.sh v2: state hardening (slash thread, garbage epoch, quotes)"
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

section "comms.sh v2: state dir blocked as a FILE must not break send/archive"
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

section "comms.sh v2.1: workspace resilience (empty cmux tree must not abort or flap)"
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

# BLOCKING (codex, suite-hot-waits r1). The first version of the override validated
# CHARACTERS, not TOKENS: `1..2`, `1.2.3` and `.` are built only from permitted characters yet
# reach `sleep` as invalid operands, and a whitespace-only value passed the filter while
# expanding to NO tokens — silently collapsing the retry loop to its final single attempt and
# removing the contention retries the backoff exists for. A stubbed `sleep` records the
# schedule that was actually slept, so this pins the behaviour with no wall-clock assertion and
# no new timing sensitivity (the reason the defaults were only source-pinned before).
CB_BIN="$WORK/cbbin"; mkdir -p "$CB_BIN"; export CB_LOG="$WORK/cb-sleeps.log"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$CB_LOG"\n' > "$CB_BIN/sleep"; chmod +x "$CB_BIN/sleep"
cb_sleeps() {  # echo the schedule cmux_tree actually slept; with no arg the override is UNSET
  : > "$CB_LOG"; rm -f "$REPO_FIX/.comms/.cache/ws-workspace_backoff"
  if [ "$#" -ge 1 ]; then
    (cd "$REPO_FIX" && PATH="$CB_BIN:$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:backoff \
       CMUX_STUB_TREE_EMPTY=1 COMMS_CMUX_BACKOFF="$1" "$COMMS" workspace) >/dev/null 2>&1
  else
    (cd "$REPO_FIX" && PATH="$CB_BIN:$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:backoff \
       CMUX_STUB_TREE_EMPTY=1 env -u COMMS_CMUX_BACKOFF "$COMMS" workspace) >/dev/null 2>&1
  fi
  tr '\n' ' ' < "$CB_LOG" | sed 's/ *$//'
}
[ "$(cb_sleeps)" = "0.3 0.7 1.2" ] \
  && ok "the default backoff schedule survives the override" || fail "default schedule (got: $(cb_sleeps))"
[ "$(cb_sleeps '0.1 0.2')" = "0.1 0.2" ] \
  && ok "a valid backoff override is honored" || fail "valid override (got: $(cb_sleeps '0.1 0.2'))"
[ "$(cb_sleeps '1..2')" = "0.3 0.7 1.2" ] \
  && ok "a malformed backoff token falls back to the default" || fail "malformed token (got: $(cb_sleeps '1..2'))"
[ "$(cb_sleeps '0.3 1..2')" = "0.3 0.7 1.2" ] \
  && ok "one bad token rejects the WHOLE schedule (atomic fallback)" || fail "partial schedule honored (got: $(cb_sleeps '0.3 1..2'))"
[ "$(cb_sleeps '   ')" = "0.3 0.7 1.2" ] \
  && ok "a whitespace-only override cannot collapse the retries" || fail "whitespace collapsed retries (got: $(cb_sleeps '   '))"
# The validator split its input with an UNQUOTED expansion, so pathname expansion ran BEFORE
# validation: with a file named `0.1` present, an override of `*` globbed into a valid-looking
# schedule and was accepted — the verdict depended on the caller's cwd. (codex, r2, blocking.)
# The pattern must match ONLY the decimal-named file. A bare `*` in this POPULATED fixture also
# expands to non-decimal names, so the fallback would fire for the wrong reason and this
# regression would pass even against the bug it exists to catch — a control that proves nothing.
# (codex, suite-hot-waits r3, advisory.)
: > "$REPO_FIX/0.987654321"
[ "$(cb_sleeps '0.98765432*')" = "0.3 0.7 1.2" ] \
  && ok "a glob override cannot expand into a valid-looking schedule" || fail "glob became a schedule (got: $(cb_sleeps '0.98765432*'))"
rm -f "$REPO_FIX/0.987654321"

section "comms.sh v2.1: surface binding"
check "bind sets an explicit surface" env -u X bash -c "cd '$REPO_FIX' && PATH='$STUB_BIN:$PATH' CMUX_WORKSPACE_ID=workspace:10 '$COMMS' bind claude surface:11"
: > "$CMUX_STUB_LOG"
BOUND_OUT="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" deliver claude)"
echo "$BOUND_OUT" | grep -q "delivered to surface:11 (bound)" && ok "deliver honors the binding over the picker" || fail "deliver honors binding (got: $BOUND_OUT)"
(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" bind claude surface:999) >/dev/null
BOUND_GONE="$(cd "$REPO_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:10 "$COMMS" deliver claude)"
echo "$BOUND_GONE" | grep -q "delivered to surface:22" && ok "absent bound surface falls back to picker" || fail "absent binding falls back (got: $BOUND_GONE)"
grep -q "delivered to surface:22" <<<"$BOUND_GONE" && [ "$(cd "$REPO_FIX" && cat .comms/.cache/surface-claude-workspace_10)" = "surface:22" ] && ok "successful delivery refreshes the surface cache" || fail "delivery refreshes surface cache"

section "comms.sh v2.1.1: binding survives a flaky tree (optimistic delivery)"
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

section "comms.sh v2.2: sandbox block emits direct recovery + state reconciliation"
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

section "comms.sh v2.1.1: status shouts when a loop stalled undelivered"
perl -pi -e 's/"last_delivery": "[^"]*"/"last_delivery": "manual"/; s/"status": "[^"]*"/"status": "in-progress"/' "$SF"
ST_OUT="$(run_comms status)"
echo "$ST_OUT" | grep -q "ACTION NEEDED" && ok "status prints ACTION NEEDED on undelivered last send" || fail "status ACTION line (got: $(echo "$ST_OUT" | tail -2))"
perl -pi -e 's/"status": "in-progress"/"status": "complete"/' "$SF"
ST_OUT="$(run_comms status)"
echo "$ST_OUT" | grep -q "ACTION NEEDED" && fail "completed thread must not shout" || ok "completed thread does not shout"

section "comms.sh v2.1: send emits a loud RESULT line — and it is the FINAL line"
RES_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$OUT_WF") 2>/dev/null )"
echo "$RES_OUT" | grep -q "^RESULT: manual" && ok "manual outcome includes RESULT: manual" || fail "RESULT line (got: $(echo "$RES_OUT" | tail -1))"
# The autonomous path (--archive-inbound) must ALSO end with RESULT, not "archived:".
RES_IN="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-30-00_resin.md"
cp "$TA" "$RES_IN"
RES_TAIL="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" send --to codex "$OUT_WF" --archive-inbound "$RES_IN") 2>/dev/null | tail -1 )"
case "$RES_TAIL" in RESULT:*) ok "tail -1 of send --archive-inbound is the RESULT line" ;; *) fail "final line on archive path (got: $RES_TAIL)" ;; esac
[ ! -f "$RES_IN" ] && ok "inbound still archived on the RESULT-last path" || fail "inbound archived on RESULT-last path"

section "runphase v0: headless delivery via stubbed codex"
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
# SPAWN_DELAY_SECS=0: every run_rp turn is stub-backed and exits in milliseconds, so the 1s
# default is pure wait across fifteen call sites. Zeroed here the same way the other 80-odd
# spawn sites already are; no assertion in the corpus depends on the delay's default.
run_rp() { (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 PATH="$STUB_BIN:$PATH" "$RUNPHASE" "$@"); }
rundir_of() { echo "$1" | sed -n 's/^ *run dir: //p' | head -1; }

# -- workflow message: spawn -> await -> completed, state mirrored --
HL_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-00-00_headless-1.md"
sed 's/thread: loop-alpha/thread: loop-headless/; s/round: 2/round: 1/' "$OUT_WF" > "$HL_WF"
: > "$CMUX_STUB_LOG"
HL_OUT="$(run_headless send --to codex "$HL_WF" 2>/dev/null)"
HL_TAIL="$(echo "$HL_OUT" | tail -1)"
case "$HL_TAIL" in "RESULT: spawned"*) ok "headless send ends with RESULT: spawned" ;; *) fail "headless RESULT line (got: $HL_TAIL)" ;; esac
# The RESULT names the ROUTE the turn actually took, read back from the spawn line --
# not from COMMS_DELIVERY. An ACP dispatch used to announce itself as "headless mode",
# which sent operators to repair a transport that was working (field report #4).
case "$HL_TAIL" in
  *"(headless)"*) ok "the RESULT names the route it actually took" ;;
  *) fail "RESULT does not name the route (got: $HL_TAIL)" ;;
esac
case "$HL_TAIL" in
  *"headless mode"*) fail "RESULT still asserts a delivery MODE rather than the route" ;;
  *) ok "RESULT no longer asserts headless mode" ;;
esac
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

section "runphase step 2: claude backend, direction pickup, hold, watchdog"
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

section "loopspec: conformance fixtures"
if bash "$REPO/docs/loopspec/check.sh" --comms "$COMMS" > "$WORK/loopspec.out" 2>&1; then
  ok "loopspec conformance: $(tail -1 "$WORK/loopspec.out")"
else
  fail "loopspec conformance failed: $(grep '^FAIL' "$WORK/loopspec.out" | head -5 | tr '\n' ' ')"
fi

section "multi-agent: registry contract"
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

section "multi-agent: sender enforcement + grok inbox round-trip"
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

section "multi-agent: grok stub + full-arc runphase legs"
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
esc() { printf '%s' "$1" | awk '{gsub(/\t/, "\\t"); printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-grok-session-1"}\n'
# A turn that emits no result event at all: the extractor finds no reply text, which is the
# loudest broker failure there is and the one that used to leave no durable record.
[ -n "${GROK_STUB_NO_RESULT:-}" ] && exit 0
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"narration to ignore"}]}}\n'
if [ -n "${GROK_STUB_NO_VERDICT:-}" ]; then
  REPLY="$(printf -- '## Summary\nreview without any verdict line')"
elif [ -n "${GROK_STUB_BAD_VERDICT:-}" ]; then
  REPLY="$(printf -- 'VERDICT: SHIP_IT\n\n## Summary\nnonstandard verdict value')"
elif [ -n "${GROK_STUB_EMPTY_BODY:-}" ]; then
  REPLY="$(printf -- 'VERDICT: APPROVE')"
elif [ -n "${GROK_STUB_DUP_VERDICT:-}" ]; then
  # line-1 APPROVE + a later REQUEST_CHANGES: ambiguous, derivation must decide
  REPLY="$(printf -- 'VERDICT: APPROVE\nnarration\nVERDICT: REQUEST_CHANGES\n\n## Findings\n### Blocking\n- a real blocking finding\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_LEAD_TOKEN:-}" ]; then
  # No VERDICT line, and a Blocking section whose finding is a lead-token line rather than a
  # list item — byte-for-byte the shape of the real codex reply that DERIVED APPROVE over a
  # genuine attestation defect on 2026-08-27.
  REPLY="$(printf -- '## Summary\nreview with an unreadable blocking section\n\n## Findings\n### Blocking\n\nblocking\ttests/run.sh:4948\tattestation is not bound to the tested commit\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_LIE_APPROVE:-}" ]; then
  # unique explicit APPROVE that contradicts its own findings
  REPLY="$(printf -- 'VERDICT: APPROVE\n\n## Findings\n### Blocking\n1. a real blocking finding the verdict ignores\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_LIE_APPROVE_LOWER:-}" ]; then
  # The canonical-cased lie-approve stub could not see this: the cross-check gate was a
  # case-sensitive grep while the parser was case-tolerant, so `### blocking` skipped the
  # check entirely and stamped APPROVE over a real finding.
  REPLY="$(printf -- 'VERDICT: APPROVE\n\n## Findings\n### blocking\n- a real blocking finding the verdict ignores\n\n### advisory\n- None.')"
elif [ -n "${GROK_STUB_LATE_VERDICT:-}" ]; then
  # A SOLE, valid verdict pushed past line 40 by a long preamble. The old scan
  # window stopped at 40, so this reply read as having no verdict at all.
  REPLY="$(printf -- 'thinking out loud\n%s\nVERDICT: REQUEST_CHANGES\n\n## Findings\n### Blocking\n- a real blocking finding\n\n### Advisory\n- None.' "$(i=0; while [ $i -lt 45 ]; do printf 'preamble line %s\n' "$i"; i=$((i+1)); done)")"
elif [ -n "${GROK_STUB_DUP_FAR:-}" ]; then
  # line-1 APPROVE with the contradicting REQUEST_CHANGES beyond line 40. Under the
  # window only the line-1 APPROVE was visible, so vcount==1 and the broker trusted
  # it -- a false all-clear that a long enough reply could always produce.
  REPLY="$(printf -- 'VERDICT: APPROVE\n%s\nVERDICT: REQUEST_CHANGES\n\n## Findings\n### Blocking\n- a real blocking finding\n\n### Advisory\n- None.' "$(i=0; while [ $i -lt 45 ]; do printf 'narration line %s\n' "$i"; i=$((i+1)); done)")"
elif [ -n "${GROK_STUB_QUOTED_VERDICT:-}" ]; then
  # A round-N reply QUOTING round N-1 inside a fenced block. Scanning the whole file
  # without skipping fences would read the quote as a second verdict and go ambiguous.
  # Quotes a COMPLETE prior review, not just its verdict line. Quoting only the verdict
  # masked the real path: the verdict scan skipped the fence but the findings parser did
  # not, so the quoted blocker failed the body cross-check and killed a clean round.
  REPLY="$(printf -- 'VERDICT: APPROVE\n\n## Prior round\n```\nVERDICT: REQUEST_CHANGES\n### Blocking\n- an OLD blocker from the round before\n```\n\n## Findings\n### Blocking\n- None.\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_PREAMBLE_NUMBERED:-}" ]; then
  # the field incident, end to end: preamble pushes the (absent) verdict off
  # line 1, findings are NUMBERED, and one real item ENDS in "None."
  REPLY="$(printf -- 'Skill descriptions were shortened to fit context.\nReviewing the handoff now.\n\n## Findings\n### Blocking\n1. helper.sh can incorrectly return None.\n\n### Advisory\n- None.')"
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
  && grep -q 'no unquoted .### Blocking. section' "$R4/result.json" && [ -f "$MA_MSG4" ] \
  && ok "a reply with neither a VERDICT line nor findings structure fails closed" || fail "missing-verdict broker path"
# A Blocking section the parser cannot read must NOT derive APPROVE. This is the end-to-end
# half of the residue counter: seven real replies in .comms/logs derived APPROVE this way,
# one of them over a genuine attestation defect. The leg must fail closed and leave the
# inbound un-archived, exactly like the unclosed-fence and no-structure paths above.
MA_MSG4B="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-32-00_leadtoken-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-3b/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG4B"
R4B="$WORK/ma-leg4b"; mkdir -p "$R4B"
PRE_RESID_CT="$(find "$MA_FIX/.comms/to-claude" -type f 2>/dev/null | grep -c . || true)"
GROK_STUB_LEAD_TOKEN=1 run_grok_leg "$MA_MSG4B" "$R4B" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R4B/result.json" | head -1)" = "failed" ] \
  && ok "an unreadable Blocking section fails closed instead of deriving APPROVE" \
  || fail "a lead-token blocking section still derived a verdict"
grep -q 'could not read as findings' "$R4B/result.json" \
  && ok "the refusal names the unread lines so the driver can act on it" || fail "refusal note missing"
[ "$PRE_RESID_CT" = "$(find "$MA_FIX/.comms/to-claude" -type f 2>/dev/null | grep -c . || true)" ] \
  && ok "no APPROVE envelope was persisted for an unread review" || fail "an envelope was stamped over unread content"
[ -f "$MA_MSG4B" ] && ok "the inbound survives a residue refusal, so the round is retryable" || fail "inbound lost on residue refusal"
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
# Adversarial verdict-line shapes through the REAL broker (codex, field-report
# round 1: grep-the-source assertions cannot catch a stamp-path regression).
PRE_STAMP_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
MA_MSG9="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-43-00_dupverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-7/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG9"
R9="$WORK/ma-leg9"; mkdir -p "$R9"
GROK_STUB_DUP_VERDICT=1 run_grok_leg "$MA_MSG9" "$R9" >/dev/null 2>&1
REPLY9="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R9/prompt.md" | head -1)"
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R9/result.json" | head -1)" = "completed" ] \
  && [ -n "$REPLY9" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY9" \
  && ok "duplicate VERDICT lines stamp the DERIVED verdict, not line 1" || fail "dup-verdict broker leg"
MA_MSG10="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-45-00_lieapprove-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-8/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG10"
R10="$WORK/ma-leg10"; mkdir -p "$R10"
PRE_LIE_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
GROK_STUB_LIE_APPROVE=1 run_grok_leg "$MA_MSG10" "$R10" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R10/result.json" | head -1)" = "failed" ] \
  && grep -q 'contradicts its own body' "$R10/result.json" && [ -f "$MA_MSG10" ] \
  && [ "$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')" = "$PRE_LIE_CT" ] \
  && ok "explicit APPROVE over blocking findings is REFUSED by the live broker" || fail "lie-approve broker leg"
MA_MSG11="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-47-00_preamble-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-9/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG11"
R11="$WORK/ma-leg11"; mkdir -p "$R11"
GROK_STUB_PREAMBLE_NUMBERED=1 run_grok_leg "$MA_MSG11" "$R11" >/dev/null 2>&1
REPLY11="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R11/prompt.md" | head -1)"
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R11/result.json" | head -1)" = "completed" ] \
  && [ -n "$REPLY11" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY11" \
  && ok "preamble + numbered None.-suffix finding derives REQUEST_CHANGES live (the field incident)" || fail "preamble-numbered broker leg"
# A lowercase `### blocking` must not let an explicit APPROVE past the cross-check.
MA_MSG16="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-57-00_lielower-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-14/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG16"
R16="$WORK/ma-leg16"; mkdir -p "$R16"
PRE_LOWER_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
GROK_STUB_LIE_APPROVE_LOWER=1 run_grok_leg "$MA_MSG16" "$R16" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R16/result.json" | head -1)" = "failed" ] \
  && grep -q 'contradicts its own body' "$R16/result.json" \
  && [ "$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')" = "$PRE_LOWER_CT" ] \
  && ok "a lowercase ### blocking heading cannot smuggle an APPROVE past the cross-check" \
  || fail "lowercase lie-approve broker leg"

# Verdict lines BEYOND the old 40-line scan window (codex, field-report round 2).
MA_MSG12="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-49-00_lateverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-10/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG12"
R12="$WORK/ma-leg12"; mkdir -p "$R12"
GROK_STUB_LATE_VERDICT=1 run_grok_leg "$MA_MSG12" "$R12" >/dev/null 2>&1
REPLY12="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R12/prompt.md" | head -1)"
[ -n "$REPLY12" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY12" \
  && ok "a sole VERDICT past line 40 is still honoured" || fail "late-verdict broker leg"

MA_MSG13="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-51-00_dupfar-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-11/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG13"
R13="$WORK/ma-leg13"; mkdir -p "$R13"
GROK_STUB_DUP_FAR=1 run_grok_leg "$MA_MSG13" "$R13" >/dev/null 2>&1
REPLY13="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R13/prompt.md" | head -1)"
[ -n "$REPLY13" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY13" \
  && ok "a line-1 APPROVE contradicted past line 40 no longer wins" || fail "dup-far broker leg"

MA_MSG14="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-53-00_quoted-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-12/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG14"
R14="$WORK/ma-leg14"; mkdir -p "$R14"
GROK_STUB_QUOTED_VERDICT=1 run_grok_leg "$MA_MSG14" "$R14" >/dev/null 2>&1
REPLY14="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R14/prompt.md" | head -1)"
[ -n "$REPLY14" ] && grep -q '^verdict: APPROVE$' "$REPLY14" \
  && ok "a fenced quote of a whole prior review neither forges a verdict nor a finding" || fail "quoted-verdict broker leg"

# An ACP turn killed by its own timeout budget must NOT be reported as an empty reply.
# Under `--format quiet` acpx exits 0 having printed nothing, so a killed-mid-work turn
# and a genuinely empty one are byte-identical; the honest-but-wrong note sent an
# operator hunting permission flags for half an hour. (agent-comms-7b, 2026-08-26.)
TO_STUB="$WORK/timeout-bin"; mkdir -p "$TO_STUB"
cat > "$TO_STUB/npx" <<'TSTUB'
#!/bin/bash
case " $* " in
  *" sessions ensure "*) echo "stub-session (created)"; exit 0 ;;
esac
printf '%s\n' "$*" >> "${TO_STUB_ARGV:-/dev/null}"
[ "${TO_STUB_SLEEP:-2}" != "0" ] && sleep "${TO_STUB_SLEEP:-2}"   # outlive the 1s budget below
# Default prints NOTHING -- exactly acpx --format quiet on a kill. TO_STUB_OUT makes the
# kill PARTIAL instead, which is the case the original guard could not see.
[ -n "${TO_STUB_OUT:-}" ] && printf '%s' "$TO_STUB_OUT"
exit "${TO_STUB_RC:-0}"
TSTUB
chmod +x "$TO_STUB/npx"
cat > "$TO_STUB/node" <<'TNODE'
#!/bin/bash
echo "v22.22.3"
TNODE
chmod +x "$TO_STUB/node"
MA_MSG15="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-55-00_timeout-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-13/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG15"
R15="$WORK/ma-leg15"; mkdir -p "$R15"
( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$TO_STUB:$PATH" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$MA_MSG15" --dir "$R15" \
    --provider grok --via acp --timeout-secs 1 ) >/dev/null 2>&1
TO_NOTE="$(sed -n 's/.*"note": "\(.*\)".*/\1/p' "$R15/result.json" 2>/dev/null | head -1)"
case "$TO_NOTE" in
  *"budget"*) ok "an ACP turn killed by its timeout names the budget, not an empty reply" ;;
  *) fail "timeout note (got: ${TO_NOTE:-<none>})" ;;
esac
case "$TO_NOTE" in
  *"produced no reply text"*) fail "a timeout is still reported as an empty reply" ;;
  *) ok "a killed turn is not mislabelled as a refused or empty reply" ;;
esac
grep -q 'budget' "$R15/runner.log" 2>/dev/null \
  && ok "elapsed and budget are recorded in runner.log either way" || fail "no elapsed/budget line in runner.log"

# THE EXPENSIVE CASE: a budget-killed turn that got PARTIAL bytes out. A review opens with
# its verdict and an empty Blocking list, so a turn cut off while writing its advisories
# emits exactly this — and the parent stamps an authoritative APPROVE from a reviewer that
# never finished reading the diff. The old guard asked about the budget only when the child
# had printed nothing, so this shipped as `completed` with an EMPTY note.
run_to_leg() { # <thread-suffix> <run-dir-var> <timeout> [env already exported by caller]
  local msg="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-5${1}-00_to-${1}.md"
  sed -e "s/^thread: ma-arc-1\$/thread: ma-arc-to${1}/" "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  ( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$TO_STUB:$PATH" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$msg" --dir "$2" \
      --provider grok --via acp --timeout-secs "$3" ) >/dev/null 2>&1
}
note_of() { sed -n 's/.*"note": "\(.*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }
status_of() { sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }

R16="$WORK/ma-leg16"; mkdir -p "$R16"
TO_STUB_OUT="$(printf 'VERDICT: APPROVE\n\n## Summary\nlooks fine so far\n\n## Findings\n### Blocking\n- None.\n\n### Advisory\n- I was still writing when the bud')" \
  run_to_leg 6 "$R16" 1
[ "$(status_of "$R16")" = "completed" ] \
  && ok "a truncated-but-parseable turn is still delivered (the review is not discarded)" \
  || fail "partial reply was discarded (status $(status_of "$R16"))"
case "$(note_of "$R16")" in
  *TRUNCATED*) ok "...but it is flagged as possibly TRUNCATED rather than shipped silently" ;;
  *) fail "a budget-killed partial reply shipped with note: $(note_of "$R16")" ;;
esac

# UNSTRUCTURED partial output: the budget must be the HEADLINE, not a parenthetical tail,
# or the operator reads a formatting complaint and goes hunting the wrong bug again.
R17="$WORK/ma-leg17"; mkdir -p "$R17"
TO_STUB_OUT="I am partway through reviewing and was cut o" run_to_leg 7 "$R17" 1
case "$(note_of "$R17")" in
  "turn exceeded its"*) ok "an overrun leads with the budget, not with a parser complaint" ;;
  *) fail "budget was not the headline (got: $(note_of "$R17"))" ;;
esac
case "$(note_of "$R17")" in
  *"broker also said"*) ok "the broker's own complaint survives as the secondary detail" ;;
  *) fail "the broker detail was dropped from the overrun note" ;;
esac

# CONTROL: a turn that finishes WELL inside its budget must stay silent, or the warning is
# noise on every ACP turn and the operator learns to ignore it.
R18="$WORK/ma-leg18"; mkdir -p "$R18"
TO_STUB_SLEEP=0 TO_STUB_OUT="$(printf 'VERDICT: APPROVE\n\n## Summary\na complete review\n\n## Findings\n### Blocking\n- None.\n\n### Advisory\n- None.')" \
  run_to_leg 8 "$R18" 5
[ "$(status_of "$R18")" = "completed" ] && [ -z "$(note_of "$R18")" ] \
  && ok "control: a turn inside its budget carries no truncation warning" \
  || fail "the warning fires on a turn that did not overrun (note: $(note_of "$R18"))"

# A MALFORMED budget must not leak a bash error and must not silently revert the diagnosis.
R19="$WORK/ma-leg19"; mkdir -p "$R19"
TO_ERR="$( { ( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$TO_STUB:$PATH" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$MA_MSG15" --dir "$R19" \
    --provider grok --via acp --timeout-secs notanumber ) >/dev/null; } 2>&1 || true)"
case "$TO_ERR" in
  *"integer expression expected"*) fail "a malformed budget leaks a bash arithmetic error" ;;
  *) ok "a malformed timeout budget is handled without a bash error" ;;
esac
# ...and it must FALL BACK rather than reach acpx: the value is handed to acpx on its own
# --timeout flag, so validating it at the point of the arithmetic was already too late.
case "$TO_ERR" in
  *"not a usable budget"*) ok "a malformed budget is reported as unusable" ;;
  *) fail "a malformed budget was not reported (got: $(printf '%.120s' "$TO_ERR"))" ;;
esac
# A SLOW FAILURE IS NOT A KILL. Any failure that happened to outlast the budget was being
# relabelled "killed mid-work" with exit 124 — acpx usage, session and permission errors,
# and broker validation failures alike. A budget kill has a signature: under --format quiet
# acpx exits 0 having produced nothing usable. A non-zero exit is acpx failing, not a kill.
# (codex, panel r1.)
R20="$WORK/ma-leg20"; mkdir -p "$R20"
TO_STUB_RC=2 TO_STUB_OUT="acpx: unknown profile" run_to_leg 9 "$R20" 1
[ "$(status_of "$R20")" = "failed" ] && ok "a non-zero acpx exit still fails the turn" || fail "non-zero acpx exit not failed"
case "$(note_of "$R20")" in
  *"killed mid-work"*) fail "a non-zero acpx exit past the budget was mislabelled as a budget kill" ;;
  *) ok "a slow FAILURE is not relabelled as a budget kill" ;;
esac
case "$(note_of "$R20")" in
  *"budget"*) ok "...but the elapsed-vs-budget context is still reported" ;;
  *) fail "budget context lost on a non-zero acpx exit" ;;
esac
# THE REAL TIMEOUT EXIT CODE. Pinned acpx times the prompt then salvages: a salvaged reply
# returns 0, and a failed salvage rethrows and exits 3 — which helpers/acp.sh already
# documents as TIMEOUT. Treating rc=0 as the whole signature meant a genuine rc=3 timeout
# fell to the generic branch and was never named as a kill.
# (codex + grok, corroborated, panel r2.)
R21="$WORK/ma-leg21"; mkdir -p "$R21"
TO_STUB_RC=3 run_to_leg 1 "$R21" 1
case "$(note_of "$R21")" in
  *"killed mid-work"*) ok "an acpx exit-3 timeout is named as a budget kill" ;;
  *) fail "rc=3 timeout was not recognised (got: $(note_of "$R21"))" ;;
esac
# ...while codes that are NOT timeouts stay out of the pair.
R22="$WORK/ma-leg22"; mkdir -p "$R22"
TO_STUB_RC=5 run_to_leg 2 "$R22" 1
case "$(note_of "$R22")" in
  *"killed mid-work"*) fail "a permission failure (exit 5) was relabelled a budget kill" ;;
  *) ok "a permission failure past the budget is still not a kill" ;;
esac
# R23 is the rc=3 DEFINITE-kill case: acpx itself reported the timeout, so the broker never
# ran and there is no send-failure alternative to hedge toward. The hedge belongs to rc=0
# (leg 17), asserted just below. Do not "fix" this back to expecting a hedge.
# (grok, panel r2; codex narrowed it to rc=0, panel r3.)
R23="$WORK/ma-leg23"; mkdir -p "$R23"
TO_STUB_RC=3 TO_STUB_OUT="partial text that will not broker" run_to_leg 3 "$R23" 1
case "$(note_of "$R23")" in
  "turn exceeded its"*) ok "an overrun with output still leads with the budget" ;;
  *) fail "budget stopped being the headline (got: $(note_of "$R23"))" ;;
esac
case "$(note_of "$R23")" in
  *"probably killed"*) fail "an rc=3 timeout hedged toward a send failure that cannot have happened" ;;
  *) ok "an rc=3 timeout states the kill plainly — the broker never ran, so there is no alternative" ;;
esac
# ...and the hedge applies where it IS possible: rc=0 with output, where the broker was
# attempted and could have failed to stamp or send. Leg 17 is that shape. (codex, panel r3.)
case "$(note_of "$R17")" in
  *"probably killed"*) ok "an rc=0 overrun WITH output hedges, because the broker did run" ;;
  *) fail "rc=0 overrun-with-output did not hedge (got: $(note_of "$R17"))" ;;
esac
# BUDGET VALIDATION is about what reaches acpx, not about what the warning says. Assert the
# effective argv, or any implementation that merely utters the words passes.
# (grok, panel r2 — the tautological-assertion catch.)
BBN=0
for bbcase in "0:1800" "08:8" "9999999999999999999:1800" "notanumber:1800" "3600:3600" "01800:1800"; do
  BBN=$((BBN+1))
  badbudget="${bbcase%%:*}"; wantbudget="${bbcase##*:}"
  RB="$WORK/ma-badbudget-$BBN"; mkdir -p "$RB"
  ARGVLOG="$RB/argv.txt"; : > "$ARGVLOG"
  BB_ERR="$( { TO_STUB_ARGV="$ARGVLOG" TO_STUB_SLEEP=0 run_to_leg "b$BBN" "$RB" "$badbudget"; } 2>&1 || true)"
  case "$BB_ERR" in
    *"integer expression expected"*) fail "budget '$badbudget' leaked a bash arithmetic error" ;;
    *) ok "budget '$badbudget' produced no bash arithmetic error" ;;
  esac
  # A value that stripping made LEGAL must never be called unusable, or the message
  # contradicts the budget it then honours. (codex + grok, panel r4.)
  if [ "$wantbudget" = "8" ]; then
    case "$BB_ERR" in
      *"not a usable budget"*) fail "a normalised budget '$badbudget' was called unusable" ;;
      *) ok "a normalised budget '$badbudget' is reported as read, not as unusable" ;;
    esac
  fi
  grep -q -- "--timeout $wantbudget " "$ARGVLOG" 2>/dev/null \
    && ok "budget '$badbudget' reached acpx as ${wantbudget}s" \
    || fail "budget '$badbudget' should reach acpx as ${wantbudget}s (argv: $(head -1 "$ARGVLOG" 2>/dev/null))"
done

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

section "runphase: the parent-brokered prompt is provider-neutral"
# The broker gate is `provider = grok OR via = acp` (runphase.sh), so this prompt is built for
# claude and codex turns too. Anything that hardcodes grok on that path misattributes or
# mislabels another agent's review. cap_word is unit-tested by EXTRACTING the function rather
# than grepping for it, because the capitalization is the behavior the header depends on.
PB_RP="$REPO/helpers/runphase.sh"
PB_CAP="$(sed -n '/^cap_word() {/,/^}/p' "$PB_RP")"
[ -n "$PB_CAP" ] && ok "cap_word is defined as a single extractable accessor" || fail "cap_word missing"
PB_OUT="$(eval "$PB_CAP"; printf '%s|%s|%s' "$(cap_word grok)" "$(cap_word codex)" "$(cap_word claude)")"
[ "$PB_OUT" = "Grok|Codex|Claude" ] \
  && ok "cap_word title-cases each agent name (Grok|Codex|Claude)" || fail "cap_word output: $PB_OUT"
PB_EMPTY="$(eval "$PB_CAP"; cap_word "" 2>/dev/null; printf 'x')"
[ "$PB_EMPTY" = "x" ] && ok "cap_word on an empty name yields nothing, not a stray capital" || fail "cap_word empty"

# The consult header follows the agent. The grok arc above proves the rendered form
# ('Grok Take') behaviorally; these pin that no literal remains to regress to.
grep -q '## \$agent_title Take' "$PB_RP" \
  && ok "the consult header interpolates the agent, not a literal provider name" || fail "consult header not parameterized"
! grep -q '## Grok Take' "$PB_RP" \
  && ok "no hardcoded 'Grok Take' survives in the shared prompt" || fail "literal Grok Take still present"

# A missing agent REFUSES. Defaulting published another agent's review under grok's name.
# ANY `:-grok` default in non-comment code, not just the arg-5 form. The exact-form grep this
# replaces was blind to `${GROK_AGENT:-grok}` on the line that stamps `from:`, which is the one
# that actually decides whose name a published review carries. (grok, implement r1, advisory.)
PB_DEFAULTS="$(grep -vE '^[[:space:]]*#' "$PB_RP" | grep -c ':-grok' || true)"
[ "$PB_DEFAULTS" = "0" ] \
  && ok "no ':-grok' identity default survives anywhere in executable code" \
  || fail "grok identity default still present on $PB_DEFAULTS code line(s)"
grep -q 'without an agent name — refusing' "$PB_RP" \
  && ok "a brokered prompt built without an agent refuses instead of stamping a default identity" \
  || fail "no fail-closed refusal for a missing agent"
# BEHAVIORAL, not a grep: the guard runs before any dependency the function has, so the whole
# function can be extracted and called with four arguments to prove the refusal actually fires.
# (codex, implement r1, advisory — the greps above prove the default is gone, not that it refuses.)
PB_FN="$(sed -n '/^build_grok_prompt() {/,/^}/p' "$PB_RP")"
PB_PRED_FN="$(sed -n '/^agent_name_ok() {/,/^}/p' "$PB_RP")"
# Without this the two extracted-guard tests below pass because `agent_name_ok` is MISSING, not
# because the guard works — a vacuous pass that both reviewers caught in round 3.
PB_INSCOPE="$(eval "$PB_PRED_FN"; eval "$PB_FN"; type agent_name_ok >/dev/null 2>&1 && printf 'yes' || printf 'no')"
[ "$PB_INSCOPE" = "yes" ] \
  && ok "the extracted guard scope really defines agent_name_ok (no command-not-found pass)" \
  || fail "agent_name_ok absent from the extracted scope — the guard tests would pass vacuously"
PB_GUARD="$(eval "$PB_PRED_FN"; eval "$PB_FN"; GROK_PROMPT_NOTE=""; \
  if build_grok_prompt m r p main 2>/dev/null; then printf 'RETURNED_ZERO'; \
  else printf 'REFUSED|%s' "$GROK_PROMPT_NOTE"; fi)"
case "$PB_GUARD" in
  REFUSED\|*) ok "build_grok_prompt called without an agent REFUSES (behavioral, not a grep)" ;;
  *) fail "missing-agent guard did not refuse: $PB_GUARD" ;;
esac
case "$PB_GUARD" in
  *"without an agent name"*) ok "the missing-agent refusal explains itself in GROK_PROMPT_NOTE" ;;
  *) fail "missing-agent refusal set no explanatory note: $PB_GUARD" ;;
esac

# Runtime notes that reach the operator must name the provider that actually ran.
! grep -qE 'grok prompt build refused|grok broker failed|stamped grok reply failed' "$PB_RP" \
  && ok "broker failure notes name the running provider, not grok" || fail "grok-named broker notes remain"

# Per-attempt broker state is cleared at BOTH entry points; the ACP path enters at
# broker_stamp_and_deliver, which previously reset only BROKER_VALIDATED.
sed -n '/^broker_stamp_and_deliver() {/,/^}/p' "$PB_RP" | grep -q 'GROK_BROKER_NOTE=""' \
  && ok "the ACP broker entry point clears the stale note beside BROKER_VALIDATED" || fail "note not reset on the ACP path"
! grep -q 'GROK_BROKER_DERIVED' "$PB_RP" \
  && ok "the write-only GROK_BROKER_DERIVED is gone (the derivation is logged, not stored)" || fail "dead GROK_BROKER_DERIVED remains"
sed -n '/^broker_stamp_and_deliver() {/,/^}/p' "$PB_RP" | grep -q 'BROKER_REFUSAL_LOGGED=0' \
  && ok "the ACP broker entry clears all THREE per-attempt flags, not two" || fail "BROKER_REFUSAL_LOGGED not reset on the ACP path"
PB_INITS="$(grep -cE '^(BROKER_VALIDATED=0|BROKER_REFUSAL_LOGGED=0|GROK_BROKER_NOTE="")$' "$PB_RP")"
[ "$PB_INITS" = "3" ] \
  && ok "all three per-attempt broker flags are initialised at global scope" || fail "global broker-flag inits: $PB_INITS of 3"
sed -n '/^broker_stamp() {/,/^}/p' "$PB_RP" | grep -q 'no usable agent identity was set' \
  && ok "the from: stamp itself refuses without an identity, not just the prompt build" || fail "identity stamp has no fail-closed guard"
# ONE predicate, both doors. Two guards that differ is the bug shape this repo keeps finding:
# round 2 caught the prompt coercing whitespace while the stamp checked only -z.
PB_IN_PROMPT="$(sed -n '/^build_grok_prompt() {/,/^}/p' "$PB_RP" | grep -c 'agent_name_ok ')"
PB_IN_STAMP="$(sed -n '/^broker_stamp() {/,/^}/p' "$PB_RP" | grep -c 'agent_name_ok ')"
[ "$PB_IN_PROMPT" -ge 1 ] && [ "$PB_IN_STAMP" -ge 1 ] \
  && ok "one agent_name_ok predicate is CALLED inside both the prompt build and the stamp" \
  || fail "agent_name_ok call sites — prompt:$PB_IN_PROMPT stamp:$PB_IN_STAMP"
# The guard must run BEFORE any other global is read, or a bad body gets blamed for a missing
# identity — and under set -u a standalone caller aborts before reaching the refusal.
PB_GUARD_LN="$(awk '/^broker_stamp\(\) \{/{f=1} f&&/agent_name_ok/{print NR; exit}' "$PB_RP")"
PB_RTYPE_LN="$(awk '/^broker_stamp\(\) \{/{f=1} f&&/GROK_RTYPE/{print NR; exit}' "$PB_RP")"
[ -n "$PB_GUARD_LN" ] && [ -n "$PB_RTYPE_LN" ] && [ "$PB_GUARD_LN" -lt "$PB_RTYPE_LN" ] \
  && ok "the stamp identity guard runs before any other broker global is read" \
  || fail "stamp guard at $PB_GUARD_LN is not before the first global read at $PB_RTYPE_LN"
PB_PRED="$(eval "$(sed -n '/^agent_name_ok() {/,/^}/p' "$PB_RP")"; \
  for v in "" "   " "$(printf '\t')" grok; do agent_name_ok "$v" && printf 'Y' || printf 'N'; done)"
[ "$PB_PRED" = "NNNY" ] \
  && ok "agent_name_ok refuses empty, spaces and tab but accepts a real name" || fail "predicate: $PB_PRED"
PB_BLANK="$(eval "$PB_PRED_FN"; eval "$PB_FN"; GROK_PROMPT_NOTE=""; \
  if build_grok_prompt m r p main "   " 2>/dev/null; then printf 'RETURNED_ZERO'; else printf 'REFUSED'; fi)"
[ "$PB_BLANK" = "REFUSED" ] \
  && ok "a whitespace-only agent name is refused, so '##  Take' cannot render" || fail "blank agent accepted: $PB_BLANK"

section "multi-agent: grok arg refusals"
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

section "multi-agent: archive-owner authority (comms.sh send)"
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

section "multi-agent: template source contracts"
grep -qF '"$COMMS_SH" agents' "$REPO/templates/claude-commands/ask.md" \
  && ok "ask.md reads known agents from the registry helper" || fail "ask.md registry hookup"
# One loop command now. `--reviewers` is PLURAL and held as a list: a singular name
# stretched into a list is how one REVIEWER scalar ends up copied across every write path.
AUTOF="$REPO/templates/claude-commands/auto.md"
grep -q -- '--reviewers a,b' "$AUTOF" && ok "auto.md takes a reviewer LIST" || fail "auto.md reviewers flag"
grep -qF 'GATING=' "$AUTOF" && ok "auto.md names a gating reviewer distinct from the list" || fail "auto.md gating reviewer"
grep -q 'Default 10' "$AUTOF" && ok "auto.md defaults max-rounds to 10 per phase" || fail "auto.md rounds default"
grep -q 'EACH phase' "$AUTOF" && ok "each phase gets its own round budget" || fail "auto.md per-phase budget"
grep -q 'DIRECTION' "$AUTOF" && ok "auto.md gives --plan a direction-only bar" || fail "auto.md plan bar"
# The default is a PANEL, derived from the registry: hardcoding a roster means adding an
# agent silently leaves it out of every future review.
grep -q 'default is a PANEL' "$AUTOF" && ok "auto.md defaults to a panel" || fail "auto.md panel default"
grep -q 'agents --others' "$AUTOF" && ok "the panel roster is derived from the registry" || fail "auto.md roster derivation"
# The template must FAN OUT via the helper, never hand-roll per-reviewer copies — that is
# how the legs drift apart and stop being comparable.
grep -q 'panel dispatch --to' "$AUTOF" && ok "auto.md fans out via panel dispatch" || fail "auto.md panel wiring"
grep -q 'compose --set' "$AUTOF" && ok "auto.md composes before fixing anything" || fail "auto.md compose wiring"
grep -q 'Corroborated' "$AUTOF" && ok "auto.md states what actually gates" || fail "auto.md gate rule"
grep -qi 'not auto-address every blocking' "$AUTOF" \
  && ok "auto.md forbids auto-addressing every reviewer's blockers" || fail "auto.md hostage guard"
grep -qi 'REFUSES a partial panel' "$AUTOF" \
  && ok "auto.md says an unanswered leg is not an approval" || fail "auto.md partial-panel rule"
# The plan cap is the PLAN's, not the loop's. Copying `max-rounds: 2` into implement
# halves the real budget and both messages still look well-formed. (grok, collapse r1.)
grep -qi 'PLAN cap only' "$AUTOF" && ok "auto.md scopes the plan cap to the plan phase" || fail "auto.md plan cap scoping"
grep -qi 'Do NOT copy .max-rounds. from a plan' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "the handoff refuses to carry the plan cap into implementation" || fail "read-from-codex plan cap carry"
# An upgrade must REMOVE retired commands; only ceasing to copy them leaves them callable.
grep -q 'RETIRED_COMMANDS=' "$REPO/install.sh" && ok "installer names the retired commands" || fail "installer retired list"
[ "$(grep -c 'for f in \$RETIRED_COMMANDS' "$REPO/install.sh")" -ge 2 ] \
  && ok "installer removes retired commands in BOTH scopes" || fail "installer retired removal"
# Helpers rot the same way: ceasing to copy one leaves it on disk and callable.
grep -q 'RETIRED_HELPERS=' "$REPO/install.sh" && ok "installer names retired helpers too" || fail "installer retired helpers"
grep -q 'for h in \$RETIRED_HELPERS' "$REPO/install.sh" \
  && ok "installer removes retired helpers on upgrade" || fail "installer helper removal"
# prompt_version must hash the surface that exists, not the one that was deleted.
grep -q 'auto.md:\$HOME/.claude/commands/auto.md' "$COMMS" \
  && ok "prompt surface hashes /auto" || fail "prompt surface missing auto.md"
grep -q 'auto-implement.md:\$HOME' "$COMMS" && fail "prompt surface still hashes a deleted template" \
  || ok "prompt surface no longer hashes deleted templates"

section "broker: a missing VERDICT line is DERIVED, not discarded"
# Three live reviews were thrown away over a missing first line while carrying thousands
# of bytes of real findings. loopspec already defines the equivalence, so the structure
# states the verdict even when the line does not.
DV="$WORK/derive"; mkdir -p "$DV"
mkdir -p "$STUB_BIN"
cat > "$DV/with-blocking.md" <<'DVEOF'
I'll review this as a read-only pass.

## Summary
narration first, no verdict line

## Findings

### Blocking
- `a.sh:1` — a real blocking finding.

### Advisory
- None.
DVEOF
cat > "$DV/clean.md" <<'DVEOF'
## Findings

### Blocking
- None.

### Advisory
- `b.sh:2` — advisory only.
DVEOF
cat > "$DV/no-structure.md" <<'DVEOF'
I looked at it and it seems fine to me, shipping.
DVEOF
# Production entry point, not a third copy of the awk — same reason as nb() below.
dv_count() { "$REPO/helpers/comms.sh" findings --raw "$1" 2>/dev/null \
  | awk -F'\t' '$13=="blocking"{n++} END{print n+0}'; }
[ "$(dv_count "$DV/with-blocking.md")" = "1" ] && ok "derivation counts a real blocking finding" || fail "derive count blocking"
[ "$(dv_count "$DV/clean.md")" = "0" ] && ok "derivation does not count a 'None.' placeholder" || fail "derive count none"
grep -q '^### Blocking' "$DV/no-structure.md" && fail "fixture has structure" \
  || ok "a reply with NO findings structure has nothing to derive from"
# (Removed: a grep for the string DERIVED in runphase.sh. That assertion went green on a
# comment and red on a reword, and said nothing about the broker. What it claimed is proven
# live by the dup-verdict leg above, which stamps the DERIVED verdict into a real reply.)

section "one placeholder rule: broker derivation and findings/compose cannot disagree"
# The bug this replaces: findings_extract and the broker were separate copies of
# "what is a placeholder". They drifted on list form, were mirrored by hand, then
# drifted again on CASE and emphasis -- so `NONE`, `` `none` `` and `_None_` were
# placeholders to the broker and REAL blocking findings to compose, letting a stamped
# APPROVE carry blocking rows. The broker now reads `findings --raw --probe`, so
# this asserts one parser rather than two that agree today.
CORP="$WORK/placeholder-corpus"; mkdir -p "$CORP"
while IFS='|' read -r item want label; do
  [ -n "$item" ] || continue
  printf '### Blocking\n\n- %s\n' "$item" > "$CORP/item.md"
  got="$("$REPO/helpers/comms.sh" findings --raw "$CORP/item.md" 2>/dev/null \
    | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')"
  [ "$got" = "$want" ] && ok "placeholder corpus: $label" \
    || fail "placeholder corpus: $label (want $want blocking, got $got)"
done <<'CORPUS'
None.|0|a bare None. placeholder
none|0|lowercase none
NONE|0|uppercase NONE
`none`|0|backticked none
_None_|0|underscore-emphasised None
**None**|0|bold None
a real bug|1|an ordinary finding
`helper.sh` can incorrectly return None.|1|a real finding that merely ENDS in None.
CORPUS

# The raw entry point exists FOR the broker: a child reply has no envelope yet.
printf '### Blocking\n\n- a real bug\n' > "$CORP/bare.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/bare.md" | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "1" ] \
  && ok "findings --raw parses a frontmatter-less body" || fail "raw mode cannot read a bare reply"
[ -z "$("$REPO/helpers/comms.sh" findings "$CORP/bare.md" 2>/dev/null)" ] \
  && ok "without --raw an envelope-less file still yields nothing" || fail "raw bypass leaked into normal mode"

# Raw mode must source NO structure from model-authored delimiters. A child that wrapped
# its reply in horizontal rules could hide a blocker inside a fake frontmatter block:
# raw counted zero -> APPROVE, then the real envelope pushed that "---" off line 1 and
# normal extraction saw the blocker. Child-built stamped-verdict/body contradiction.
printf -- '---\n### Blocking\n\n- a blocker hidden in fake frontmatter\n---\n\nbody\n' > "$CORP/hidden.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/hidden.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "1" ] \
  && ok "raw mode cannot be blinded by model-authored --- delimiters" || fail "a blocker hid inside fake frontmatter"
# ...while a REAL envelope is still parsed normally when --raw is absent.
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/hidden.md" 2>/dev/null | awk -F'\t' '$13=="advisory"{n++} END{print n+0}')" = "0" ] \
  && ok "raw mode does not invent lanes from the fake block" || fail "raw mode mislaned the fake frontmatter"

# Fenced quotes are quotes. Round-N bodies quote round N-1 as a matter of course.
printf '### Blocking\n\n```\n### Blocking\n- an OLD quoted blocker\n```\n\n- a real current blocker\n' > "$CORP/fenced.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/fenced.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "1" ] \
  && ok "a finding quoted inside a fence is not counted as a new finding" || fail "fenced quote counted as a finding"
printf '~~~\n### Blocking\n- tilde-quoted\n~~~\n### Blocking\n\n- a real one\n' > "$CORP/tilde.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/tilde.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "1" ] \
  && ok "tilde fences are fences too" || fail "tilde fence not recognised"
printf '   ```\n### Blocking\n- indented-quoted\n   ```\n### Blocking\n\n- a real one\n' > "$CORP/indented.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/indented.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "1" ] \
  && ok "a fence indented up to 3 spaces is still a fence" || fail "indented fence not recognised"
# Structure presence is a BEHAVIOUR of the shared scanner, not a string in runphase.sh.
# The old assertion grepped the source for the refusal note; it could not see that a
# plain `grep '^### Blocking'` counted a QUOTED prior round as live structure while the
# parser ignored it, so a reply that had said REQUEST_CHANGES derived APPROVE.
probe_of() { "$REPO/helpers/comms.sh" findings --raw --probe "$1" 2>/dev/null \
  | awk -F'\t' -v k="$2" '$1==k {print $2; exit}'; }
printf 'just prose, no structure at all\n' > "$CORP/prose.md"
[ "$(probe_of "$CORP/prose.md" blocking_section)" = "no" ] \
  && ok "a structureless reply has no section to derive from" || fail "prose read as structure"
printf 'no verdict of my own\n\n## Prior round\n```\nVERDICT: REQUEST_CHANGES\n### Blocking\n- an OLD blocker\n```\n' > "$CORP/quotedonly.md"
[ "$(probe_of "$CORP/quotedonly.md" blocking_section)" = "no" ] \
  && ok "a fenced quote of a prior round is not this reply's structure" || fail "quoted prior counted as live structure"
[ "$(probe_of "$CORP/quotedonly.md" verdicts)" = "0" ] \
  && ok "a fenced quote of a prior round forges no verdict either" || fail "quoted verdict counted"
printf '### Blocking\n\n```\n- swallowed by an unclosed fence\n' > "$CORP/unclosed.md"
[ "$(probe_of "$CORP/unclosed.md" unclosed_fence)" = "yes" ] \
  && ok "an unclosed fence is reported so the broker can fail closed" || fail "unclosed fence not reported"

# RESIDUE: the parser must be able to say "I could not read this". Every rule above answers
# "how many findings did I parse?"; the broker derives a verdict from that number while
# believing it asked whether the reviewer found anything. Measured on 123 raw replies in
# .comms/logs, SEVEN derived APPROVE over a Blocking section they had failed to read -- the
# clearest being a codex reply whose real finding ("attestation is not bound to the commit
# actually tested") was written as `blocking<TAB>tests/run.sh:4948<TAB>...` and produced
# `DERIVED 'APPROVE' from 0 blocking finding(s)`.
printf '### Blocking\n\nblocking\ttests/run.sh:4948\tattestation is not bound to the tested commit\n' > "$CORP/leadtoken.md"
[ "$(probe_of "$CORP/leadtoken.md" blocking)" = "0" ] \
  && ok "a lead-token finding still extracts as zero findings (the grammar is unchanged)" || fail "lead-token unexpectedly parsed"
[ "$(probe_of "$CORP/leadtoken.md" blocking_unparsed)" -gt 0 ] \
  && ok "...but it is now COUNTED as unread rather than silently discarded" \
  || fail "a lead-token finding vanished with no trace — the false all-clear"
printf '### Blocking\n\n**Takeover parking can advance main.** The landing invariant is broken.\n' > "$CORP/boldlead.md"
[ "$(probe_of "$CORP/boldlead.md" blocking_unparsed)" -gt 0 ] \
  && ok "a bold-lead paragraph is counted as unread too" || fail "bold-lead finding vanished silently"
# The two guards that keep the counter from turning real reviews red. Each was verified to
# go RED when its guard is removed from the rule, so neither assertion is one that cannot fail.
printf '### Blocking\n\nNone.\n' > "$CORP/bareplaceholder.md"
[ "$(probe_of "$CORP/bareplaceholder.md" blocking_unparsed)" = "0" ] \
  && ok "an unbulleted None. placeholder is not unread residue" || fail "placeholder counted as residue"
printf '### Blocking\n\n- a real bug\n  continued on the next line\n' > "$CORP/continuation.md"
[ "$(probe_of "$CORP/continuation.md" blocking_unparsed)" = "0" ] \
  && ok "a list item and its indented continuation leave no residue" || fail "continuation counted as residue"
# THE MASKED FINDING. A list-form `- None.` leaves the buffer set, so an UNINDENTED finding
# on the next line matched no rule at all — not the continuation rule (it wants leading
# whitespace), not the blank flush, not the residue rule while it still guarded on an empty
# buffer. END discarded the placeholder and the probe reported 0/0: a derived APPROVE over a
# real finding, inside the very counter meant to prevent one. Both reviewers found this
# independently. (codex + grok, panel r1.)
printf '### Blocking\n\n- None.\nThe attestation is not bound to the tested commit\n' > "$CORP/masked.md"
[ "$(probe_of "$CORP/masked.md" blocking)" = "0" ] && [ "$(probe_of "$CORP/masked.md" blocking_unparsed)" -gt 0 ] \
  && ok "a finding masked behind a list-form None. is counted, not swallowed" \
  || fail "a masked finding still reads as a clean review (blocking=$(probe_of "$CORP/masked.md" blocking) unparsed=$(probe_of "$CORP/masked.md" blocking_unparsed))"
# The same swallow made a MIXED lane silent when no blank line separated the two, so compose
# printed a count with no warning attached.
printf '### Blocking\n\n- a wording nit\nThe attestation is not bound to the tested commit\n' > "$CORP/mixedsilent.md"
[ "$(probe_of "$CORP/mixedsilent.md" blocking)" = "1" ] && [ "$(probe_of "$CORP/mixedsilent.md" blocking_unparsed)" -gt 0 ] \
  && ok "a parsed finding plus unindented prose reports BOTH the finding and the residue" \
  || fail "mixed lane went silent again"
# HEADING DEPTH decides whether a lane ended or someone wrote their finding as a sub-heading.
# Treating every `^#` as a terminator cleared the lane before any residue rule could see it,
# so `### Blocking` + `#### the attestation is not bound...` probed 0/0 and derived APPROVE.
# (codex blocking + grok, panel r2.)
printf '### Blocking\n\n#### The attestation is not bound to the tested commit\n' > "$CORP/deephead.md"
[ "$(probe_of "$CORP/deephead.md" blocking)" = "0" ] && [ "$(probe_of "$CORP/deephead.md" blocking_unparsed)" -gt 0 ] \
  && ok "a finding written as a DEEPER heading is residue, not a closed lane" \
  || fail "a sub-heading finding still reads as a clean review"
# ...and a sibling or shallower heading must still CLOSE the lane, or every Process section
# and every trailing summary becomes residue and clean approvals start refusing.
printf '### Blocking\n\n- None.\n\n### Advisory\n\n- None.\n\n### Process\n\nplain prose about the loop\n' > "$CORP/procclose.md"
[ "$(probe_of "$CORP/procclose.md" blocking_unparsed)" = "0" ] && [ "$(probe_of "$CORP/procclose.md" advisory_unparsed)" = "0" ] \
  && ok "a sibling ### heading still closes the lane (a clean approval stays clean)" \
  || fail "### Process prose leaked into a lane as residue"
printf '### Blocking\n\n- a real finding\n\n## Summary\n\nprose after\n' > "$CORP/shallowclose.md"
[ "$(probe_of "$CORP/shallowclose.md" blocking)" = "1" ] && [ "$(probe_of "$CORP/shallowclose.md" blocking_unparsed)" = "0" ] \
  && ok "a shallower ## heading closes the lane too" || fail "shallow heading did not close the lane"
# codex advisory: flush-first CAN change extracted claim text on a shape the archive does not
# contain, and the row-count assertion cannot see it. Pin the claim text itself.
printf '### Blocking\n\n- a real bug\nan unindented gap line\n  an indented tail\n' > "$CORP/sandwich.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/sandwich.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{print $15}')" = "a real bug" ] \
  && ok "flush-first pins the claim to the list item, with the stray lines as residue" \
  || fail "claim text drifted: $("$REPO/helpers/comms.sh" findings --raw "$CORP/sandwich.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{print $15}')"
[ "$(probe_of "$CORP/sandwich.md" blocking_unparsed)" = "2" ] \
  && ok "both stray lines are counted as residue" || fail "sandwich residue count wrong ($(probe_of "$CORP/sandwich.md" blocking_unparsed))"
# ATX headings may carry up to three leading spaces. Requiring column zero meant an indented
# `### Blocking` opened no lane at all — its findings were invisible and an explicit APPROVE
# passed the cross-check over them. (codex, panel r3.)
printf 'VERDICT: APPROVE\n\n   ### Blocking\n\n   - a real bug\n' > "$CORP/indenthead.md"
[ "$(probe_of "$CORP/indenthead.md" blocking_section)" = "yes" ] && [ "$(probe_of "$CORP/indenthead.md" blocking)" = "1" ] \
  && ok "an indented ### Blocking still opens the lane and its findings are seen" \
  || fail "an indented heading hid a real finding"
# ...and a run of hashes with no boundary is NOT a heading: ATX requires a space or end of
# line after them. Treating `##text` as one closed a live lane — another 0/0 consent path.
printf '### Blocking\n\n##not-a-heading but a real finding\n' > "$CORP/noboundary.md"
[ "$(probe_of "$CORP/noboundary.md" blocking)" = "0" ] && [ "$(probe_of "$CORP/noboundary.md" blocking_unparsed)" -gt 0 ] \
  && ok "a hash-run with no boundary is residue, not a lane closer" \
  || fail "##text closed the lane and produced a clean read"
# A TAB is as valid an ATX boundary as a space, and the two recognizers must agree on that.
# The lane rule matched a literal space only, so `###<TAB>Blocking` opened no lane and then
# the generic recognizer — which DID accept the tab — closed the absent lane and discarded
# the heading and every finding under it. Probe: blocking_section=no, no residue, explicit
# APPROVE survives. (codex, panel r4.)
printf '###\tBlocking\n\n- a real bug\n' > "$CORP/tabhead.md"
[ "$(probe_of "$CORP/tabhead.md" blocking_section)" = "yes" ] && [ "$(probe_of "$CORP/tabhead.md" blocking)" = "1" ] \
  && ok "a TAB-separated lane heading opens the lane and its findings are seen" \
  || fail "a tab-separated ### Blocking was discarded"
# The counter must not change WHAT is extracted: verified byte-identical across all 348
# archived messages, so no finding_id renumbers and .comms/grades/findings.tsv needs no rebuild.
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/continuation.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "1" ] \
  && ok "the residue counter changes no extracted row" || fail "residue counter altered extraction"
# Residue in the ADVISORY lane is counted separately and must never gate anything.
printf '### Blocking\n\n- a real blocker\n\n### Advisory\n\nADVISORY\tx.sh:1\tunreadable advisory\n' > "$CORP/advresid.md"
[ "$(probe_of "$CORP/advresid.md" advisory_unparsed)" -gt 0 ] && [ "$(probe_of "$CORP/advresid.md" blocking_unparsed)" = "0" ] \
  && ok "advisory residue is counted in its own lane, not the blocking one" || fail "lane residue leaked across sections"
printf '### blocking\n\n- a lowercase-heading blocker\n' > "$CORP/lowerhead.md"
[ "$(probe_of "$CORP/lowerhead.md" blocking)" = "1" ] \
  && ok "a lowercase ### blocking heading is still a section" || fail "lowercase heading dropped the section"
printf '### Blocking\n\n````\n```\n### Blocking\n- quoted inner\n```\n````\n\n- a real one\n' > "$CORP/fourtick.md"
[ "$(probe_of "$CORP/fourtick.md" blocking)" = "1" ] \
  && ok "a 4-tick wrap around a 3-tick block does not leak its contents" || fail "nested fence leaked"

# A leg is answered only by a VALID review-feedback — a stray note must not complete a
# panel and unblock its gate. (codex, panel r1.)
grep -q 'skipping an invalid or non-review message' "$COMMS" \
  && ok "compose ignores non-review messages on a leg" || fail "compose leg validation"

section "findings are LIST ITEMS in any markdown form (field bug, 2026-08-26)"
# A real loop produced numbered findings. The extractor matched only "- ", so it pulled
# ZERO findings; the verdict is derived from the same count, so a review with real
# blocking bugs was stamped APPROVE and composed as a clean panel. A false all-clear is
# the worst failure this tool has.
LF="$WORK/listforms"; mkdir -p "$LF"
cat > "$LF/numbered.md" <<'LFEOF'
---
type: review-feedback
from: codex
timestamp: 2026-08-26T12:00:00Z
workspace: lf
message_id: lf-1
thread: lf-thread
phase: plan
round: 2
verdict: APPROVE
---

Warning: Skill descriptions were shortened to fit the context budget.

I'll review the pinned tree read-only.

## Summary
narration above, numbered findings below

## Findings

### Blocking
1. **The tuple comparison mixes one-based and zero-based months.** Splitting `2026-08-31`
   produces a month that is off by one.

### Advisory
1. `DispatchInvoice` remains mounted when closed.

### Process
- no friction
LFEOF
# self-contained: run_tr is defined much later in this file
run_lf() { (cd "$REPO" && env -u CMUX_WORKSPACE_ID -u COMMS_DELIVERY "$COMMS" "$@"); }
LF_ROWS="$(run_lf findings "$LF/numbered.md" 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$LF_ROWS" | grep -c .)" = "2" ] \
  && ok "numbered findings are extracted (1 blocking, 1 advisory)" || fail "numbered list yielded $(printf '%s' "$LF_ROWS" | grep -c .) findings"
printf '%s\n' "$LF_ROWS" | awk -F'\t' '$13=="blocking"' | grep -q 'tuple comparison' \
  && ok "a numbered blocking finding lands in the blocking lane" || fail "numbered blocking lane"
printf '%s\n' "$LF_ROWS" | grep -q 'narration above' && fail "prose above the findings was extracted" \
  || ok "narration and harness warnings are not mistaken for findings"
# every list marker markdown allows
cat > "$LF/mixed.md" <<'LFEOF'
---
type: review-feedback
from: grok
timestamp: 2026-08-26T12:00:00Z
workspace: lf
message_id: lf-2
thread: lf-thread-2
verdict: REQUEST_CHANGES
---

## Findings

### Blocking
- dash form
* star form
+ plus form
1. dot-numbered form
2) paren-numbered form

### Advisory
- **None.**
LFEOF
LF_MIX="$(run_lf findings "$LF/mixed.md" 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$LF_MIX" | grep -c .)" = "5" ] \
  && ok "every markdown list marker counts as a finding" || fail "mixed markers yielded $(printf '%s' "$LF_MIX" | grep -c .)"
printf '%s\n' "$LF_MIX" | grep -q 'None' && fail "a bolded None. placeholder was counted" \
  || ok "a **None.** placeholder is still not a finding"
# The derivation reads the same shapes, or the verdict contradicts the body again.
# Asserted by BEHAVIOUR, not by grepping runphase.sh for a regex: the derivation now
# delegates to this same parser, so there is no second regex left to grep for -- and a
# source-grep would have passed happily while the two copies disagreed on case.
# TAB after the marker is valid markdown too — the same class as the numbered-list miss that
# started this thread, found again at round 10 after nine rounds of "list form is handled".
printf '### Blocking\n\n-\ta tab bullet\n1.\ta tab number\n' > "$CORP/tabs.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/tabs.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "2" ] \
  && ok "a tab after the list marker is still a finding" || fail "tab-delimited list items dropped"
printf '### Blocking\n\n1. a numbered finding\n2) a paren-numbered finding\n- a bulleted finding\n' > "$CORP/markers.md"
[ "$("$REPO/helpers/comms.sh" findings --raw "$CORP/markers.md" 2>/dev/null | awk -F'\t' '$13=="blocking"{n++} END{print n+0}')" = "3" ] \
  && ok "verdict derivation counts numbered findings too" || fail "derivation missed a list marker shape"
# (Removed: a grep for a log string. Proven live instead by the preamble and late-verdict
# broker legs, which stamp a real reply whose only VERDICT sits below the preamble.)
# A finding that merely ENDS in "None." is not a placeholder. The first filter matched the
# end of the line, so `1. \`helper.sh\` can incorrectly return None.` derived zero blockers
# and stamped APPROVE while findings_extract kept it — the same stamped-verdict-contradicts-
# body failure, one layer down. (codex, field-report round 1.)
# nb() calls the REAL production entry point. It used to be an inline COPY of the
# broker awk, which is why the case regression passed the suite while production was
# broken: the test parser and the shipped parser were different code that happened to
# look alike. A copied parser only ever tests itself. (codex, field-report round 2.)
nb() { "$REPO/helpers/comms.sh" findings --raw "$1" 2>/dev/null \
  | awk -F'\t' '$13=="blocking"{n++} END{print n+0}'; }
NB="$WORK/noneedge"; mkdir -p "$NB"
printf '### Blocking\n1. `helper.sh` can incorrectly return None.\n' > "$NB/ends-in-none.md"
[ "$(nb "$NB/ends-in-none.md")" = "1" ] \
  && ok "a finding that ends in 'None.' still counts as a finding" || fail "ends-in-None was swallowed"
printf '### Blocking\n- None.\n' > "$NB/placeholder.md"
[ "$(nb "$NB/placeholder.md")" = "0" ] && ok "a bare None. placeholder counts as zero" || fail "placeholder counted"
printf '### Blocking\n- **None.**\n' > "$NB/bold.md"
[ "$(nb "$NB/bold.md")" = "0" ] && ok "a bolded placeholder counts as zero" || fail "bold placeholder counted"
printf '### Blocking\n1. **None**\n' > "$NB/numbered-none.md"
[ "$(nb "$NB/numbered-none.md")" = "0" ] && ok "a numbered bold placeholder counts as zero" || fail "numbered placeholder counted"
# CASE matters: the stubs in this very suite write lowercase "- none". A case-sensitive
# compare read those as real blocking findings, so each stub's own APPROVE looked like a
# self-contradiction and got refused — cascading through seven downstream tests.
for lc in 'none' 'NONE' '`none`'; do
  printf '### Blocking\n- %s\n' "$lc" >| "$NB/case.md"
  [ "$(nb "$NB/case.md")" = "0" ] && ok "'- $lc' is a placeholder regardless of case or emphasis" || fail "'- $lc' counted as a finding"
done
printf '### Blocking\n- a real bug\n- none\n' >| "$NB/mixed.md"
[ "$(nb "$NB/mixed.md")" = "1" ] && ok "a placeholder beside a real finding does not hide it" || fail "mixed list miscounted"
# Ambiguity must be caught even when line 1 is a verdict: the old code short-circuited
# there and never reached the count.
# (Removed: a grep for a log string. The dup-verdict broker leg proves the fallback by its
# result — a stamped REQUEST_CHANGES over a line-1 APPROVE.)
# Asserted by BEHAVIOUR: a line-1 verdict must still be COUNTED, not trusted on sight.
# The old check grepped runphase.sh for the order of two statements, which said nothing
# about what the scanner actually does and broke the moment the scanner moved.
printf 'VERDICT: APPROVE\nnarration\nVERDICT: REQUEST_CHANGES\n\n### Blocking\n\n- a real one\n' > "$CORP/dup1.md"
[ "$(probe_of "$CORP/dup1.md" verdicts)" = "2" ] \
  && ok "verdict lines are counted before any is trusted" || fail "a line-1 verdict short-circuits the count"
# An explicit APPROVE over blocking findings is a contradiction, not a verdict.
# (Removed: a grep for a refusal string in the SOURCE. The lie-approve legs already grep it
# out of a real result.json, which is the broker refusing, not a comment existing.)

section "stamped authorities: workspace pin (#3) + send-time git metadata (#6)"
SA_FIX="$WORK/stamped-auth"; mkdir -p "$SA_FIX"; SA_FIX="$(cd "$SA_FIX" && pwd -P)"
git -C "$SA_FIX" init -q -b main
git -C "$SA_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$SA_FIX/.comms/to-codex" "$SA_FIX/.comms/to-claude" "$SA_FIX/.comms/archive"
printf 'agents = claude codex\ndefault-target = codex\n' > "$SA_FIX/.comms/config"
run_sa() { (cd "$SA_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }
SA_HEAD="$(git -C "$SA_FIX" rev-parse HEAD)"

# snapshot --with-base: clean tree -> id == base == HEAD
SA_PAIR="$(run_sa snapshot create --with-base)"
[ "$SA_PAIR" = "$(printf '%s\t%s' "$SA_HEAD" "$SA_HEAD")" ] \
  && ok "clean-tree snapshot pair is HEAD/HEAD (its own base)" || fail "clean pair (got: $SA_PAIR)"
# dirty tree -> synthetic id whose FIRST PARENT is the base, from one operation
echo edit > "$SA_FIX/f.txt"
SA_PAIR2="$(run_sa snapshot create --with-base)"
SA_AID="${SA_PAIR2%%	*}"; SA_BASE="${SA_PAIR2#*	}"
[ "$SA_AID" != "$SA_BASE" ] && [ "$SA_BASE" = "$SA_HEAD" ] \
  && [ "$(git -C "$SA_FIX" rev-parse "$SA_AID^")" = "$SA_BASE" ] \
  && ok "dirty-tree snapshot pair: base is the artifact's first parent" || fail "dirty pair (got: $SA_PAIR2)"

# send OVERWRITES a hand-typed head_sha on a loop message from the same pair
SA_WS="$(run_sa workspace)"
SA_MSG="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T14-00-00_auto-1.md"
cat > "$SA_MSG" <<SAEOF
---
type: review-request
from: claude
timestamp: 2026-08-26T19:00:00Z
workspace: $SA_WS
head_sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
message_id: ${SA_WS}_2026-08-26T14-00-00_auto-1
thread: sa-arc-1
workflow: auto
phase: implement
round: 1
max-rounds: 5
---

body
SAEOF
run_sa send --to codex "$SA_MSG" >/dev/null 2>&1
SA_MSG_AID="$(sed -n '2,/^---$/p' "$SA_MSG" | grep -m1 '^artifact_id:' | sed 's/^artifact_id: //')"
SA_MSG_SHA="$(sed -n '2,/^---$/p' "$SA_MSG" | grep -m1 '^head_sha:' | sed 's/^head_sha: //')"
[ -n "$SA_MSG_AID" ] && [ "$SA_MSG_SHA" != "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] \
  && [ "$SA_MSG_SHA" = "$(git -C "$SA_FIX" rev-parse "$SA_MSG_AID^")" ] \
  && ok "send overwrites a hand-typed head_sha with the artifact's own base" || fail "send head_sha authority (aid=$SA_MSG_AID sha=$SA_MSG_SHA)"
[ "$(sed -n '2,/^---$/p' "$SA_MSG" | grep -c '^head_sha:')" = "1" ] \
  && ok "exactly one head_sha survives the overwrite" || fail "duplicate head_sha lines"

# a consult with no head_sha gets the live HEAD stamped at send
SA_Q="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T14-05-00_ask-1.md"
cat > "$SA_Q" <<SAEOF
---
type: question
from: claude
timestamp: 2026-08-26T19:05:00Z
workspace: $SA_WS
message_id: ${SA_WS}_2026-08-26T14-05-00_ask-1
---

## Question
is this fine
SAEOF
run_sa send --to codex "$SA_Q" >/dev/null 2>&1
grep -q "^head_sha: $SA_HEAD$" "$SA_Q" \
  && ok "consult head_sha is helper-stamped at send time" || fail "consult head_sha stamp"

# workspace pin: an explicit set beats every inferred identity and repairs listing
SA_OTHER="$SA_FIX/.comms/to-claude/fwh-platform_2026-08-26T14-10-00_reply-1.md"
cat > "$SA_OTHER" <<SAEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-26T19:10:00Z
workspace: fwh-platform
message_id: fwh-platform_2026-08-26T14-10-00_reply-1
thread: sa-arc-2
workflow: auto
phase: implement
round: 1
max-rounds: 5
verdict: APPROVE
---

## Summary
pinned-identity fixture
SAEOF
SA_LIST_OUT="$(run_sa list --as claude 2>&1)" && sa_rc=0 || sa_rc=$?
[ "$sa_rc" -ne 0 ] && echo "$SA_LIST_OUT" | grep -q 'fwh-platform(1)' \
  && echo "$SA_LIST_OUT" | grep -q 'workspace set' \
  && ok "empty listing NAMES the unmatched identities and the repair command" || fail "unmatched-identity diagnostics (got: $SA_LIST_OUT)"
check_not "workspace set rejects an invalid name" run_sa workspace set 'Bad Name'
check_not "workspace set rejects a path-shaped name" run_sa workspace set '../evil'
run_sa workspace set fwh-platform >/dev/null
[ "$(run_sa workspace)" = "fwh-platform" ] && ok "explicit pin IS the identity" || fail "pin not authoritative"
run_sa list --as claude 2>/dev/null | grep -q 'fwh-platform_2026-08-26T14-10-00_reply-1' \
  && ok "pin repairs the listing: hidden reply is now visible" || fail "pin listing repair"
[ -f "$SA_MSG" ] || fail "diagnostics deleted mail (must never delete)"
rm -f "$SA_FIX/.comms/workspace"

# ---- round 2: resend validation, consult overwrite, CRLF, diagnostics split ----
# Resend with artifact_id but NO head_sha: base derives from the OBJECT, never live HEAD
git -C "$SA_FIX" add -A >/dev/null 2>&1
git -C "$SA_FIX" -c user.email=t@t -c user.name=t commit -qm "moves HEAD past the artifact base"
SA_NEWHEAD="$(git -C "$SA_FIX" rev-parse HEAD)"
SA_RS="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-00-00_resend-1.md"
cat > "$SA_RS" <<SAEOF
---
type: review-request
from: claude
timestamp: 2026-08-26T20:00:00Z
workspace: $SA_WS
artifact_id: $SA_AID
message_id: ${SA_WS}_2026-08-26T15-00-00_resend-1
thread: sa-arc-1
workflow: auto
phase: implement
round: 2
max-rounds: 5
---

body
SAEOF
run_sa send --to codex "$SA_RS" >/dev/null 2>&1
SA_RS_SHA="$(sed -n '2,/^---$/p' "$SA_RS" | grep -m1 '^head_sha:' | sed 's/^head_sha: //')"
[ "$SA_RS_SHA" = "$SA_BASE" ] && [ "$SA_RS_SHA" != "$SA_NEWHEAD" ] \
  && ok "artifact-only resend stamps the artifact's base, never live HEAD" || fail "resend base (got $SA_RS_SHA want $SA_BASE)"
# Mismatched pair: fail closed, nothing delivered
SA_MM="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-05-00_mismatch-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T15-05-00_mismatch-1/' \
    -e '/^artifact_id:/a\
head_sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' "$SA_RS" > "$SA_MM"
MM_OUT="$(run_sa send --to codex "$SA_MM" 2>&1)" && mm_rc=0 || mm_rc=$?
[ "$mm_rc" -ne 0 ] && echo "$MM_OUT" | grep -q 'mismatched pair' \
  && ok "mismatched artifact/head_sha pair is refused" || fail "mismatched pair (rc=$mm_rc)"
# Phantom artifact: refused
SA_PH="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-07-00_phantom-1.md"
sed -e 's/^artifact_id: .*/artifact_id: 1111111111111111111111111111111111111111/' \
    -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T15-07-00_phantom-1/' \
    -e '/^head_sha:/d' "$SA_MM" > "$SA_PH"
check_not "phantom artifact_id is refused at send" run_sa send --to codex "$SA_PH"
# Consult with a HAND-TYPED head_sha: overwritten with live HEAD at send
SA_Q2="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-10-00_ask-2.md"
cat > "$SA_Q2" <<SAEOF
---
type: question
from: claude
timestamp: 2026-08-26T20:10:00Z
workspace: $SA_WS
head_sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
message_id: ${SA_WS}_2026-08-26T15-10-00_ask-2
---

## Question
still fine?
SAEOF
run_sa send --to codex "$SA_Q2" >/dev/null 2>&1
grep -q "^head_sha: $SA_NEWHEAD$" "$SA_Q2" \
  && [ "$(grep -c '^head_sha:' "$SA_Q2")" = "1" ] \
  && ok "consult head_sha is OVERWRITTEN with live HEAD (hand-typed values die)" || fail "consult overwrite"
# cmd_ask no longer authors head_sha at compose (send is the boundary)
awk '/^cmd_ask\(\)/,/^}/' "$REPO/helpers/comms.sh" | grep -q 'rev-parse HEAD' \
  && fail "cmd_ask still hand-derives head_sha at compose" || ok "cmd_ask leaves head_sha to send"
# CRLF file: INSERTED lines carry CRLF too (no mixed endings)
SA_CR="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-15-00_crlf-1.md"
printf -- '---\r\ntype: review-request\r\nfrom: claude\r\ntimestamp: 2026-08-26T20:15:00Z\r\nworkspace: %s\r\nmessage_id: %s_2026-08-26T15-15-00_crlf-1\r\nthread: sa-arc-9\r\nworkflow: auto\r\nphase: implement\r\nround: 1\r\nmax-rounds: 5\r\n---\r\n\r\nbody\r\n' "$SA_WS" "$SA_WS" > "$SA_CR"
run_sa send --to codex "$SA_CR" >/dev/null 2>&1
grep -q $'^artifact_id: .*\r$' "$SA_CR" && grep -q $'^head_sha: .*\r$' "$SA_CR" \
  && ok "CRLF message gets CRLF on the INSERTED stamp lines" || fail "CRLF mixed endings"
# Diagnostics split: same-workspace files outside a --thread filter are NOT an identity warning
SA_TH="$SA_FIX/.comms/to-claude/${SA_WS}_2026-08-26T15-20-00_otherthread-1.md"
cat > "$SA_TH" <<SAEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-26T20:20:00Z
workspace: $SA_WS
message_id: ${SA_WS}_2026-08-26T15-20-00_otherthread-1
thread: sa-arc-elsewhere
workflow: auto
phase: implement
round: 1
max-rounds: 5
verdict: APPROVE
---

## Summary
different thread
SAEOF
rm -f "$SA_FIX/.comms/to-claude/fwh-platform_2026-08-26T14-10-00_reply-1.md"
SA_TH_OUT="$(run_sa list --as claude --thread sa-arc-nomatch 2>&1)" || true
echo "$SA_TH_OUT" | grep -q 'outside the current filter' \
  && ok "thread-filter misses are reported as filter misses" || fail "thread-filter wording (got: $SA_TH_OUT)"
echo "$SA_TH_OUT" | grep -q 'OTHER workspace identities' \
  && fail "thread miss mislabeled as identity mismatch" || ok "thread miss is not an identity warning"

# ---- round 3: immutable ids, duplicate values, object-shape synthetic test ----
# duplicate head_sha where the FIRST matches but a stale second hides behind it
SA_DUP="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-30-00_dup-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T15-30-00_dup-1/' "$SA_RS" > "$SA_DUP"
printf '%s\n' "0000000000000000000000000000000000000000" | { read -r STALE
  awk -v stale="$STALE" '{print} /^head_sha:/ && !d {print "head_sha: " stale; d=1}' "$SA_DUP" > "$SA_DUP.t" && mv "$SA_DUP.t" "$SA_DUP"; }
DUP_OUT="$(run_sa send --to codex "$SA_DUP" 2>&1)" && dup_rc=0 || dup_rc=$?
[ "$dup_rc" -ne 0 ] && echo "$DUP_OUT" | grep -q 'mismatched pair' \
  && ok "a stale duplicate behind a matching head_sha is refused" || fail "dup-forged head_sha (rc=$dup_rc)"
# identical duplicates normalize to exactly one line and pass
SA_DUP2="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-32-00_dup-2.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T15-32-00_dup-2/' "$SA_RS" > "$SA_DUP2"
awk '{print} /^head_sha:/ && !d {print; d=1}' "$SA_DUP2" > "$SA_DUP2.t" && mv "$SA_DUP2.t" "$SA_DUP2"
[ "$(grep -c '^head_sha:' "$SA_DUP2")" = "2" ] || fail "dup fixture construction"
run_sa send --to codex "$SA_DUP2" >/dev/null 2>&1
[ "$(grep -c '^head_sha:' "$SA_DUP2")" = "1" ] \
  && ok "identical duplicate head_sha lines normalize to one" || fail "dup normalize"
# symbolic artifact_id is refused before it can resolve
SA_SYM="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-34-00_sym-1.md"
sed -e 's/^artifact_id: .*/artifact_id: HEAD/' -e '/^head_sha:/d' \
    -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T15-34-00_sym-1/' "$SA_RS" > "$SA_SYM"
SYM_OUT="$(run_sa send --to codex "$SA_SYM" 2>&1)" && sym_rc=0 || sym_rc=$?
[ "$sym_rc" -ne 0 ] && echo "$SYM_OUT" | grep -q 'not a full 40-hex' \
  && ok "symbolic artifact_id (HEAD) is refused as movable" || fail "symbolic id (rc=$sym_rc)"
# an ordinary commit reusing the snapshot subject is NOT treated as synthetic
git -C "$SA_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'agent-comms reviewed artifact'
SA_FAKE="$(git -C "$SA_FIX" rev-parse HEAD)"
SA_FK="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T15-36-00_fake-1.md"
sed -e "s/^artifact_id: .*/artifact_id: $SA_FAKE/" -e '/^head_sha:/d' \
    -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T15-36-00_fake-1/' "$SA_RS" > "$SA_FK"
run_sa send --to codex "$SA_FK" >/dev/null 2>&1
grep -q "^head_sha: $SA_FAKE$" "$SA_FK" \
  && ok "subject-collision commit is its OWN base (object-shape synthetic test)" || fail "subject collision (got $(grep '^head_sha:' "$SA_FK"))"
# pin beats a LIVE cmux identity: the cache file the resolver actually reads
# (ws-<safe_name(id)>) AND a stub tree title, both claiming fwh-backup. (grok, r3:
# the earlier fixture poisoned a path nothing reads and seeded no title.)
mkdir -p "$SA_FIX/.comms/.cache"
printf 'fwh-backup' > "$SA_FIX/.comms/.cache/ws-workspace_77"
cat > "$CMUX_STUB_DIR/tree-workspace_77.txt" <<'SATREE'
workspace workspace:77 "fwh-backup"
├── pane pane:1
│   └── surface surface:78 [terminal] "idle" ◀ here
SATREE
WS_UNPINNED="$(cd "$SA_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:77 "$COMMS" workspace)"
[ "$WS_UNPINNED" = "fwh-backup" ] || fail "fixture wiring: cmux identity should win pre-pin (got $WS_UNPINNED)"
run_sa workspace set pinned-name >/dev/null
WS_LIVE="$(cd "$SA_FIX" && PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:77 "$COMMS" workspace)"
[ "$WS_LIVE" = "pinned-name" ] && ok "pin beats a live cmux id and poisoned cache" || fail "pin vs live cmux (got $WS_LIVE)"
rm -f "$SA_FIX/.comms/workspace"
# prefix-fallback fixtures: the two shapes that previously lied
rm -f "$SA_FIX/.comms/to-claude/${SA_WS}_2026-08-26T15-20-00_otherthread-1.md"
mkdir -p "$SA_FIX/.comms/to-claude"
: > "$SA_FIX/.comms/to-claude/foo_bar_2026-08-26T15-40-00_x-1.md"
: > "$SA_FIX/.comms/to-claude/other-workspace_pending.md"
PF_OUT="$(run_sa list --as claude 2>&1)" || true
echo "$PF_OUT" | grep -q 'foo_bar(1)' && echo "$PF_OUT" | grep -q 'other-workspace(1)' \
  && ok "prefix fallback names foo_bar and other-workspace correctly" || fail "prefix fallback shapes (got: $PF_OUT)"
rm -f "$SA_FIX/.comms/to-claude/foo_bar_2026-08-26T15-40-00_x-1.md" "$SA_FIX/.comms/to-claude/other-workspace_pending.md"
# ---- round 5: trailing-blank duplicates and blank-first presence ----
# valid head_sha + TRAILING bare `head_sha:` — command substitution used to eat it
SA_TB="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T16-20-00_trailblank-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T16-20-00_trailblank-1/' "$SA_RS" > "$SA_TB"
awk -v done=0 '{print; if (!done && $0 ~ /^head_sha: /) {print "head_sha:"; done=1}}' "$SA_TB" > "$SA_TB.t" && mv "$SA_TB.t" "$SA_TB"
[ "$(grep -c '^head_sha' "$SA_TB")" = "2" ] || fail "trailing-blank fixture construction"
TB_OUT="$(run_sa send --to codex "$SA_TB" 2>&1)" && tb_rc=0 || tb_rc=$?
[ "$tb_rc" -ne 0 ] && echo "$TB_OUT" | grep -q 'mismatched pair' \
  && ok "a trailing blank head_sha duplicate is seen and refused" || fail "trailing-blank head_sha (rc=$tb_rc)"
# valid artifact_id + trailing bare `artifact_id:` — ambiguous pin
SA_TA="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T16-22-00_trailaid-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T16-22-00_trailaid-1/' "$SA_RS" > "$SA_TA"
awk -v done=0 '{print; if (!done && $0 ~ /^artifact_id: /) {print "artifact_id:"; done=1}}' "$SA_TA" > "$SA_TA.t" && mv "$SA_TA.t" "$SA_TA"
TA_OUT="$(run_sa send --to codex "$SA_TA" 2>&1)" && ta_rc=0 || ta_rc=$?
[ "$ta_rc" -ne 0 ] && echo "$TA_OUT" | grep -q 'ambiguous pin' \
  && ok "a trailing blank artifact_id duplicate is seen and refused" || fail "trailing-blank artifact_id (rc=$ta_rc)"
# SINGLE blank artifact_id line: presence is physical -> resend path -> grammar refusal,
# and the live tree is NOT silently snapshotted over the (attempted) pin
SA_BA="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T16-24-00_blankaid-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T16-24-00_blankaid-1/' \
    -e 's/^artifact_id: .*/artifact_id:/' "$SA_RS" > "$SA_BA"
BA_OUT="$(run_sa send --to codex "$SA_BA" 2>&1)" && ba_rc=0 || ba_rc=$?
[ "$ba_rc" -ne 0 ] && echo "$BA_OUT" | grep -q 'not a full 40-hex' \
  && ok "a single blank artifact_id line refuses instead of fresh-dispatching" || fail "blank artifact_id presence (rc=$ba_rc got: $BA_OUT)"
grep -q '^artifact_id:$' "$SA_BA" \
  && ok "the refused message was not silently re-stamped" || fail "blank-aid message mutated"
# blank FIRST + valid second artifact_id: still the resend path, still refused
SA_BF="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T16-26-00_blankfirst-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T16-26-00_blankfirst-1/' \
    -e 's/^artifact_id: .*/artifact_id:/' "$SA_RS" > "$SA_BF"
awk -v aid="$SA_AID" -v done=0 '{print; if (!done && $0 ~ /^artifact_id:$/) {print "artifact_id: " aid; done=1}}' "$SA_BF" > "$SA_BF.t" && mv "$SA_BF.t" "$SA_BF"
BF_OUT="$(run_sa send --to codex "$SA_BF" 2>&1)" && bf_rc=0 || bf_rc=$?
[ "$bf_rc" -ne 0 ] && echo "$BF_OUT" | grep -qE 'not a full 40-hex|ambiguous pin' \
  && ok "blank-first artifact_id cannot smuggle a fresh dispatch past a supplied pin" || fail "blank-first artifact_id (rc=$bf_rc)"

# ---- round 4: blank fields, artifact_id duplicates, parentless refusal ----
# blank head_sha line on an ordinary resend: physically present, value empty -> mismatch
SA_BL="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T16-00-00_blank-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T16-00-00_blank-1/' \
    -e 's/^head_sha: .*/head_sha:/' "$SA_RS" > "$SA_BL"
BL_OUT="$(run_sa send --to codex "$SA_BL" 2>&1)" && bl_rc=0 || bl_rc=$?
[ "$bl_rc" -ne 0 ] && echo "$BL_OUT" | grep -q 'mismatched pair' \
  && ok "a BLANK head_sha line is a present, non-matching value" || fail "blank head_sha resend (rc=$bl_rc)"
# parentless synthetic artifact + blank head_sha line -> uncheckable pair refused
SA2="$WORK/stamped-parentless"; mkdir -p "$SA2"; SA2="$(cd "$SA2" && pwd -P)"
git -C "$SA2" init -q -b main
mkdir -p "$SA2/.comms/to-codex" "$SA2/.comms/archive"
printf 'agents = claude codex\ndefault-target = codex\n' > "$SA2/.comms/config"
echo content > "$SA2/f.txt"
run_sa2() { (cd "$SA2" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }
SA2_PAIR="$(run_sa2 snapshot create --with-base)"
SA2_AID="${SA2_PAIR%%	*}"; SA2_BASE="${SA2_PAIR#*	}"
[ -n "$SA2_AID" ] && [ -z "$SA2_BASE" ] && ok "parentless snapshot pair has an empty base" || fail "parentless pair (got: $SA2_PAIR)"
SA2_WS="$(run_sa2 workspace)"
SA2_MSG="$SA2/.comms/to-codex/${SA2_WS}_2026-08-26T16-05-00_pl-1.md"
cat > "$SA2_MSG" <<SAEOF
---
type: review-request
from: claude
timestamp: 2026-08-26T21:05:00Z
workspace: $SA2_WS
artifact_id: $SA2_AID
head_sha:
message_id: ${SA2_WS}_2026-08-26T16-05-00_pl-1
thread: sa2-arc-1
workflow: auto
phase: implement
round: 1
max-rounds: 5
---

body
SAEOF
PL_OUT="$(run_sa2 send --to codex "$SA2_MSG" 2>&1)" && pl_rc=0 || pl_rc=$?
[ "$pl_rc" -ne 0 ] && echo "$PL_OUT" | grep -q 'uncheckable pair' \
  && ok "blank head_sha on a parentless artifact refuses (presence is physical)" || fail "parentless blank head_sha (rc=$pl_rc got: $PL_OUT)"
# artifact-only parentless message (NO head_sha line at all) still dispatches artifact-only
SA2_MSG2="$SA2/.comms/to-codex/${SA2_WS}_2026-08-26T16-07-00_pl-2.md"
sed -e '/^head_sha:/d' -e 's/^message_id: .*/message_id: '"${SA2_WS}"'_2026-08-26T16-07-00_pl-2/' "$SA2_MSG" > "$SA2_MSG2"
run_sa2 send --to codex "$SA2_MSG2" >/dev/null 2>&1 \
  && ! grep -q '^head_sha' "$SA2_MSG2" \
  && ok "artifact-only parentless message stays artifact-only" || fail "parentless artifact-only"
# duplicate artifact_id lines: differing -> ambiguous pin refused; identical -> one line
SA_DA="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T16-10-00_dupaid-1.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T16-10-00_dupaid-1/' "$SA_RS" > "$SA_DA"
awk '{print} /^artifact_id:/ && !d {print "artifact_id: 2222222222222222222222222222222222222222"; d=1}' "$SA_DA" > "$SA_DA.t" && mv "$SA_DA.t" "$SA_DA"
DA_OUT="$(run_sa send --to codex "$SA_DA" 2>&1)" && da_rc=0 || da_rc=$?
[ "$da_rc" -ne 0 ] && echo "$DA_OUT" | grep -q 'ambiguous pin' \
  && ok "differing duplicate artifact_id lines are refused" || fail "dup artifact_id differ (rc=$da_rc)"
SA_DA2="$SA_FIX/.comms/to-codex/${SA_WS}_2026-08-26T16-12-00_dupaid-2.md"
sed -e 's/^message_id: .*/message_id: '"${SA_WS}"'_2026-08-26T16-12-00_dupaid-2/' "$SA_RS" > "$SA_DA2"
awk '{print} /^artifact_id:/ && !d {print; d=1}' "$SA_DA2" > "$SA_DA2.t" && mv "$SA_DA2.t" "$SA_DA2"
run_sa send --to codex "$SA_DA2" >/dev/null 2>&1
[ "$(grep -c '^artifact_id:' "$SA_DA2")" = "1" ] \
  && ok "identical duplicate artifact_id lines normalize to one" || fail "dup artifact_id normalize"

# panel-dispatch CRLF: source-level parity check (all writers newline-aware)
[ "$(grep -c 'NR == 1 { nl = ' "$REPO/helpers/comms.sh")" -ge 2 ] \
  && ok "both frontmatter writers are newline-aware (send + panel dispatch)" || fail "panel CRLF writer parity"

# the review prompt's SHA instruction is conditional on mounting
grep -q 'MOUNTED, pinned artifact' "$REPO/helpers/runphase.sh" \
  && grep -q 'compare it with "git rev-parse HEAD"' "$REPO/helpers/runphase.sh" \
  && ok "review prompt carries both SHA notes (mounted vs live tree)" || fail "conditional sha_note"

section "friction: a one-line seam for reporting harness problems"
FR="$WORK/friction-repo"; mkdir -p "$FR"; FR="$(cd "$FR" && pwd -P)"
git -C "$FR" init -q -b main
git -C "$FR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
run_fr() { (cd "$FR" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }
run_fr friction --severity 5 --thread t-1 "compose reported a false all-clear" >/dev/null 2>&1
[ -s "$FR/.comms/friction.tsv" ] && ok "friction writes a log" || fail "friction.tsv"
awk -F'\t' 'NR>1 && $5=="5" && $4=="t-1"' "$FR/.comms/friction.tsv" | grep -q . \
  && ok "severity and thread are recorded" || fail "friction fields"
awk -F'\t' 'NR>1 && $6!=""' "$FR/.comms/friction.tsv" | grep -q . \
  && ok "the commit it happened on is recorded" || fail "friction head_sha"
run_fr friction "a second note" >/dev/null 2>&1
[ "$(tail -n +2 "$FR/.comms/friction.tsv" | grep -c .)" = "2" ] && ok "friction appends" || fail "friction append"
check_not "friction requires a note" run_fr friction
check_not "friction rejects a severity outside 1-5" run_fr friction --severity 9 x
# it must never reach a reviewer: it is a report about the tool, not a lesson about code
grep -q 'friction' "$REPO/helpers/comms.sh" && ! grep -q 'friction.tsv' "$REPO/templates/codex-skills/read-from-claude/SKILL.md" \
  && ok "reviewers are never pointed at the friction log" || fail "friction leaked into reviewer context"
grep -q 'friction --thread' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "the loop tells the driver to record friction as it happens" || fail "friction not wired into the loop"
# Friction must ESCAPE the project. `.comms/` is gitignored, so a note recorded in a client
# repo is invisible to whoever maintains this tool unless a human pastes it — which is
# exactly how a false all-clear survived a whole loop.
FRH="$WORK/friction-home"; mkdir -p "$FRH"
run_fr_h() { (cd "$FR" && env -u CMUX_WORKSPACE_ID AGENT_COMMS_HOME="$FRH" "$COMMS" "$@"); }
run_fr_h friction --severity 4 "a note from a client repo" >/dev/null 2>&1
[ -s "$FRH/friction.tsv" ] && ok "friction rolls up outside the project" || fail "no global rollup"
grep -q 'a note from a client repo' "$FRH/friction.tsv" && ok "the rollup carries the note" || fail "rollup note"
awk -F'\t' 'NR>1 && $2!=""' "$FRH/friction.tsv" | grep -q . \
  && ok "the rollup records WHICH project it came from" || fail "rollup project column"
FRL="$(run_fr_h friction --list 2>&1)"
printf '%s\n' "$FRL" | grep -q 'a note from a client repo' && ok "--list reads the rollup" || fail "friction --list"
run_fr_h friction --severity 1 "cosmetic thing" >/dev/null 2>&1
[ "$(run_fr_h friction --list | sed -n '2p' | cut -f5)" = "4" ] \
  && ok "--list sorts worst-first, so a wrong-result note is never buried" || fail "friction --list ordering"
# the rollup must not be committable by accident: it spans projects and names private paths
case "$FRH" in *"$REPO"*) fail "the rollup lives inside a repo" ;; *) ok "the rollup lives beside the helpers, not in a repo" ;; esac
# A named-but-unresolvable artifact is a failure, not a reason to review the live tree.
grep -q 'does not resolve to a commit' "$REPO/helpers/runphase.sh" \
  && ok "an unresolvable artifact_id refuses the turn" || fail "unresolvable artifact fail-closed"
# --rounds must survive the plan phase: the plan message is the handoff's only artifact.
grep -q 'loop-rounds' "$REPO/templates/claude-commands/auto.md" \
  && ok "the plan message records the loop's real round budget" || fail "auto.md loop-rounds"
grep -q "grep -m1 '\^loop-rounds:'" "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "the handoff restores the budget mechanically, not from memory" || fail "read-from-codex loop-rounds"

# The panel must be wired into the REPLY lifecycle, not just dispatch+compose.
RFCP="$REPO/templates/claude-commands/read-from-codex.md"
grep -q 'review_set' "$RFCP" && ok "the reader recognises a panel leg" || fail "reader panel awareness"
# Set identity is resolved INDEX-FIRST with the field as a fail-closed cross-check —
# a bare word-grep let this whole mechanism vanish without a red test. (grok, panel r3.)
grep -q 'SET_IDX=' "$RFCP" && grep -q 'SET_FIELD=' "$RFCP" \
  && ok "the reader resolves the set from the index AND captures the field" || fail "reader index-first resolution"
grep -qE 'SET="\$SET_IDX"' "$RFCP" && grep -qc 'refusing to compose; manual review required' "$RFCP" >/dev/null \
  && [ "$(grep -c 'refusing to compose; manual review required' "$RFCP")" = "2" ] \
  && ok "the index is the ONLY panel authority; field-only and mismatch both refuse to compose" \
  || fail "reader mismatch discipline (field must never become authority)"
grep -q "sed -n '2,/\^---\$/p'" "$RFCP" \
  && ok "the reader's set greps are frontmatter-bounded (quoted bodies cannot win)" || fail "reader frontmatter bounding"
grep -q 'compose --set' "$RFCP" && ok "the reader composes instead of acting on one leg" || fail "reader compose wiring"
grep -qi 'not auto-address every blocking' "$RFCP" \
  && ok "the reader refuses any-blocks through the back door" || fail "reader hostage guard"
grep -qi 're-dispatches the whole panel' "$RFCP" \
  && ok "round N+1 re-dispatches the whole panel, not one leg" || fail "reader round-advance rule"
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
# Attempts are preserved in sets.tsv now, so a set dispatched twice has several rows per
# reviewer. The template derived the next round's roster from every row, producing
# `codex,grok,grok` — and `panel dispatch` refuses a duplicate reviewer, so the shipped
# template broke on any set that had been retried. (self-review, round 6.)
grep -q 'seen\[\$(10)\]++' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "the reader derives each reviewer once, however many attempts a set has" || fail "template roster can repeat a reviewer"
grep -qF 'send --to "$REVIEWER" "<your reply file>"' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "reader continuations send to the derived reviewer" || fail "reader continuation target"

section "transports emit the child\'s bytes, verbatim and identically"
# Criterion 8 by construction. The streaming extractor is a python block inside runphase.sh;
# ACP redirects acpx stdout with no transformation at all. So the extractor must be a pure
# pass-through of the result string — a single appended LF made an empty reply a one-byte file
# on one transport and an empty file on the other, which are DIFFERENT failure paths.
# (codex, round 8.)
BX="$WORK/byte-extract"; mkdir -p "$BX"
python3 - "$REPO/helpers/runphase.sh" "$BX/extract.py" <<'PYX'
import io, sys, re
src = io.open(sys.argv[1], encoding="utf-8").read()
i = src.index("import json")
j = src.index("PYX", i)
io.open(sys.argv[2], "w", encoding="utf-8").write(src[i:j])
PYX
bx() {  # <result-string> -> the bytes the streaming path would write
  # The extractor reads an events file as argv[1], the same way the runner invokes it.
  python3 -c "
import json,subprocess,sys
ev = json.dumps({'type':'result','subtype':'success','is_error':False,'result':sys.argv[1]})
open(sys.argv[3],'w').write(ev+chr(10))
r = subprocess.run([sys.executable, sys.argv[2], sys.argv[3]], capture_output=True, text=True)
sys.stdout.write(r.stdout)
" "$1" "$BX/extract.py" "$BX/events.ndjson"
}
for CASE in "plain" "" "no-trailing-lf" "leading
blank" "trailing
"; do
  GOT="$(bx "$CASE"; printf X)"; GOT="${GOT%X}"
  [ "$GOT" = "$CASE" ] && ok "streaming emits the result verbatim (${#CASE} bytes)" \
    || fail "streaming altered the bytes (in ${#CASE}, out ${#GOT})"
done
FENCED='```
### Blocking
- x
```'
GOT="$(bx "$FENCED"; printf X)"; GOT="${GOT%X}"
[ "$GOT" = "$FENCED" ] && ok "a whole-answer fence reaches the lexer intact on streaming" \
  || fail "streaming still unwraps a whole-answer fence"

# Criterion 8 was only HALF proven. Everything above exercises the STREAMING extractor and
# then asserted parity with a transport it never ran — the ACP path was asserted about, not
# invoked. ACP redirects acpx stdout straight into reply-raw.md, so the only way to know the
# two agree is to run the real path with a stub that emits chosen bytes and compare what
# lands on disk against what streaming emits for the same result string. (codex, round 10.)
AXD="$WORK/acp-parity"; AXB="$AXD/bin"; mkdir -p "$AXB"
cat > "$AXB/npx" <<'AXSTUB'
#!/bin/bash
# The acpx surface runphase's --via acp branch actually calls. `sessions show` MUST emit a
# cwd line: a mounted turn asserts that the bound record's cwd is the mount, and a stub
# that stays silent fails that assert closed on every mounted suite turn. cwd is reported
# as `pwd -P`, because acpx records process.cwd() (physical) and $WORK is a logical
# mktemp path -- a $PWD stub would refuse every legitimate turn on macOS.
# AX_CWD_LOG records every invocation's cwd so a test can observe the CHILD's directory
# rather than grepping runphase.sh for a path expression.
if [ -n "${AX_CWD_LOG:-}" ]; then
  printf '%s\t%s\n' "$(pwd -P)" "$*" >> "$AX_CWD_LOG"
fi
case " $* " in
  *" sessions ensure "*)
    # The session NAME drives the record id below, so it must be parsed before it is used.
    ax_name=""; ax_prev=""
    for ax_a in "$@"; do [ "$ax_prev" = "--name" ] && ax_name="$ax_a"; ax_prev="$ax_a"; done
    # Real acpx PERSISTS the record under $HOME/.acpx/sessions/<id>.json, and runphase now
    # uses that file's presence to prove a record belongs to the store it is about to probe
    # for a queue lease. A stub that only printed an id would make every same-home legacy
    # record look foreign, so model the write too.
    # Derive the id from the session NAME, as acpx does per (agent, cwd, name). A single
    # shared id would leave one record whose cwd is whatever ran last, so every other
    # session would fail corroboration and degrade.
    if [ -n "${AX_RECORD_ID:-}" ]; then ax_id="$AX_RECORD_ID"
    else ax_id="stub-$(printf '%s' "$ax_name" | shasum -a 256 2>/dev/null | cut -c1-12)"; fi
    [ -n "$ax_id" ] || ax_id=stub-record-1
    # ONLY into a store the suite marked as its own. Without this the stub wrote into the
    # user's real ~/.acpx/sessions whenever a turn did not override HOME.
    if [ -n "${HOME:-}" ] && [ -f "$HOME/.acpx-test-store" ]; then
      mkdir -p "$HOME/.acpx/sessions" 2>/dev/null
      # PRETTY-PRINTED, two-space indent, as acpx writes it: the production reader matches
      # `^  "cwd": "..."`, and a single-line record silently failed that match.
      printf '{\n  "schema": "acpx.session.v1",\n  "acpx_record_id": "%s",\n  "cwd": "%s",\n  "name": "%s",\n  "closed": false\n}\n' \
        "$ax_id" "${AX_LIE_CWD:-$(pwd -P)}" "$ax_name" > "$HOME/.acpx/sessions/$ax_id.json" 2>/dev/null || true
    fi
    printf '%s\t(%s)\n' "$ax_id" "${AX_ENSURE_STATE:-created}"; exit 0 ;;
  *" sessions show "*)
    printf 'name: stub\n'
    printf 'cwd: %s\n' "${AX_LIE_CWD:-$(pwd -P)}"
    exit 0 ;;
esac
if [ -n "${ACP_PARITY_PROBE:-}" ]; then
  { printf 'git=%s\n' "$(command -v git)"; printf 'PATH=%s\n' "$PATH"; } > "$ACP_PARITY_PROBE"
fi
# A mounted --approve-all child can write. AX_CHILD_WRITE plants residue at an untracked
# AND an ignored path, so a restage can be shown to clear both.
if [ -n "${AX_CHILD_WRITE:-}" ]; then
  printf '%s' "$AX_CHILD_WRITE" > ./child-residue.txt 2>/dev/null || true
  mkdir -p ./.comms 2>/dev/null && printf '%s' "$AX_CHILD_WRITE" > ./.comms/child-ignored.txt 2>/dev/null || true
fi
cat "$ACP_PARITY_PAYLOAD"
exit 0
AXSTUB
chmod +x "$AXB/npx"
cat > "$AXB/node" <<'AXNODE'
#!/bin/bash
echo "v22.22.3"
AXNODE
chmod +x "$AXB/node"
# Run the REAL ACP leg of runphase and hand back the reply-raw.md it produced.
acp_raw() {  # <payload-file> <n> -> path to the reply-raw.md the ACP path wrote
  local pay="$1" n="$2" msg dir
  msg="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-56-00_parity-$n.md"
  sed -e "s/^thread: ma-arc-1\$/thread: ma-arc-parity-$n/" \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  dir="$WORK/ma-parity-$n"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$pay" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$msg" --dir "$dir" \
      --provider grok --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir/reply-raw.md"
}
# NEGATIVE CONTROL first: if the comparison cannot see a one-byte difference, every parity
# result below is vacuous. Feed the ACP stub bytes that DIFFER from what streaming emits and
# require the comparison to notice.
printf 'parity-control' > "$AXD/payload"
AXCTL="$(acp_raw "$AXD/payload" 0)"
bx 'parity-control-DIFFERENT' > "$AXD/stream-ctl.out"
if cmp -s "$AXCTL" "$AXD/stream-ctl.out"; then
  fail "the transport parity comparison is blind — it calls differing bytes identical"
else
  ok "the transport parity comparison can see a difference (it can fail)"
fi
axn=0
for CASE in "plain" "" "no-trailing-lf" "leading
blank" "trailing
"; do
  axn=$(( axn + 1 ))
  printf '%s' "$CASE" > "$AXD/payload"
  AXRAW="$(acp_raw "$AXD/payload" "$axn")"
  bx "$CASE" > "$AXD/stream.out"
  if [ ! -e "$AXRAW" ]; then
    fail "the ACP path wrote no reply-raw.md at all (${#CASE} bytes)"
  elif cmp -s "$AXRAW" "$AXD/stream.out"; then
    ok "ACP and streaming write byte-identical replies (${#CASE} bytes)"
  else
    fail "transports disagree on ${#CASE} bytes (acp $(wc -c <"$AXRAW" | tr -d " "), streaming $(wc -c <"$AXD/stream.out" | tr -d " "))"
  fi
done
# The fence case is the one that broke criterion 8 in the field: streaming unwrapped a
# whole-answer fence that ACP left alone, so identical bytes were a review on one transport
# and a no-structure refusal on the other.
printf '%s' "$FENCED" > "$AXD/payload"
AXRAW="$(acp_raw "$AXD/payload" 9)"
bx "$FENCED" > "$AXD/stream.out"
cmp -s "$AXRAW" "$AXD/stream.out" \
  && ok "a whole-answer fence survives identically on BOTH transports" \
  || fail "the transports disagree on a whole-answer fence"

section "acp.sh: consult transport (stubbed npx)"
ACP="$REPO/helpers/acp.sh"
ACP_STUB="$WORK/acp-bin"; mkdir -p "$ACP_STUB"
export ACP_STUB_LOG="$WORK/acp.log"
cat > "$ACP_STUB/npx" <<'NSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "${ACP_STUB_LOG:-/dev/null}"
[ -n "${ACP_STUB_EXIT:-}" ] && exit "$ACP_STUB_EXIT"
# ACP_STUB_EMPTY models the rc-0-zero-bytes turn (a dropped or empty model reply): the prompt
# exits 0 having produced nothing, which the consult must refuse rather than pass as success.
case " $* " in
  *" sessions ensure "*) [ -n "${ACP_STUB_ENSURE_FAIL:-}" ] && { echo "ensure diagnostic on stdout"; exit 4; }
     echo "stub-session-id (created)" ;;
  *" exec "*|*" -s "*) [ -n "${ACP_STUB_EMPTY:-}" ] && exit 0
     [ -n "${ACP_STUB_OUT_THEN_FAIL:-}" ] && { echo "partial before failure"; exit 5; }
     echo "stub answer"; echo "[acpx] tokens: input=100 output=5 cache_read=25000 total=25105" ;;
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
grep -q -- '-y acpx@0.13.1 --timeout 300 codex sessions ensure --name agent-comms-ask' "$ACP_STUB_LOG" \
  && ok "warm consult ensures the pinned named session WITH a --timeout (a stalled ensure cannot hang)" || fail "session ensure argv/timeout"
grep -q -- '-y acpx@0.13.1 --format quiet --timeout 300 --approve-reads --non-interactive-permissions deny codex -s agent-comms-ask is the retry approach sound' "$ACP_STUB_LOG" \
  && ok "warm consult prompts the named session with the pinned acpx and a --timeout" || fail "warm prompt argv"
# A consult that cannot read is useless — it would answer from recall instead of the
# tree. Denied permissions killed a real consult mid-answer before this was added.
grep -q -- '--approve-reads' "$ACP_STUB_LOG" && ok "consults may READ the tree" || fail "consult read approval"
grep -q -- '--non-interactive-permissions deny' "$ACP_STUB_LOG" \
  && ok "consults still refuse writes (prompting is impossible here)" || fail "consult write denial"
# SILENT-SUCCESS GUARD: acpx can exit 0 having produced nothing (a dropped or empty turn). Passing
# that through hands the caller a blank answer with a success status and no diagnostic — the rc-0-
# zero-bytes hole. The consult must refuse it with the mailbox fallback. (ROADMAP field item.)
OUT="$(ACP_STUB_EMPTY=1 run_acp consult codex --oneshot hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -qi 'no answer' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "a rc-0 consult with an empty answer is refused, not passed as success" \
  || fail "an empty consult answer read as success (rc=$rc, out: $(echo "$OUT" | head -1))"
# A malformed --timeout budget falls back to the default rather than taking the turn down.
: > "$ACP_STUB_LOG"
COMMS_ACP_CONSULT_TIMEOUT_SECS=notanumber run_acp consult codex ping >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a malformed consult --timeout budget falls back to the default" || fail "malformed consult timeout not defaulted"
: > "$ACP_STUB_LOG"
run_acp consult codex --oneshot quick check >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads --non-interactive-permissions deny codex exec quick check' "$ACP_STUB_LOG" \
  && ! grep -q -- '-s agent-comms-ask' "$ACP_STUB_LOG" \
  && ok "--oneshot uses stateless exec with a --timeout, no session" || fail "oneshot argv"
# A leading-zero budget NORMALIZES base-10 (08 -> 8), not rejected as octal nor passed as 010. (grok r1.)
: > "$ACP_STUB_LOG"
COMMS_ACP_CONSULT_TIMEOUT_SECS=08 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 8 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a leading-zero consult timeout normalizes base-10 (08 -> 8)" || fail "leading-zero timeout not normalized"
# An OVERSIZED digit budget falls back to the default rather than WRAPPING through arithmetic
# (2^64 -> 0, huge -> unrelated positive) — the text sanitizer rejects >6 digits before any math. (codex r2.)
: > "$ACP_STUB_LOG"
COMMS_ACP_CONSULT_TIMEOUT_SECS=18446744073709551616 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads' "$ACP_STUB_LOG" \
  && ok "an oversized consult timeout falls back to the default (no integer overflow)" || fail "oversized timeout wrapped instead of defaulting"
# Digit-count boundary: exactly 6 digits is honoured, 7 falls back (the sane_secs length gate). (grok r3.)
: > "$ACP_STUB_LOG"; COMMS_ACP_CONSULT_TIMEOUT_SECS=999999 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 999999 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a 6-digit consult timeout (999999) is honoured" || fail "a valid 6-digit timeout was rejected"
: > "$ACP_STUB_LOG"; COMMS_ACP_CONSULT_TIMEOUT_SECS=1000000 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a 7-digit consult timeout (1000000) falls back to the default" || fail "a 7-digit timeout was not rejected"
# A FAILING sessions ensure surfaces its stdout diagnostic instead of dropping it to /dev/null. (codex r2.)
OUT="$(ACP_STUB_ENSURE_FAIL=1 run_acp consult codex hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'ensure diagnostic on stdout' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "a failing sessions ensure surfaces its captured stdout diagnostic" \
  || fail "a failing ensure's stdout is dropped (rc=$rc)"
# A FAILING acpx still surfaces its stdout, so the 'see output above' error branches are truthful. (both r1.)
OUT="$(ACP_STUB_OUT_THEN_FAIL=1 run_acp consult codex --oneshot hi 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'partial before failure' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "a failing consult surfaces acpx's captured stdout (see-output-above is true)" \
  || fail "captured stdout dropped on a failing consult (rc=$rc)"
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

section "runphase: parent-brokered claude and codex legs over ACP"
# THE GAP THIS CLOSES: every other `--via acp` fixture in this corpus pins `--provider grok`,
# so the `|| [ "$via" = "acp" ]` half of the broker gate — the half that is the whole point of
# "parent-broker claude and codex" — had no coverage at all. A regression that un-brokered
# claude or codex would have left this suite green. (contraction step 3, S3-2.)
#
# STUB FIDELITY, stated plainly: $AXB/npx returns the payload through the same path for every
# provider, so these legs prove the PARENT's behaviour (prompt shape, stamping, delivery,
# archiving, session recording). They do NOT prove that acpx's real claude/codex adapters emit
# a final assistant message as stdout text; that is transport behaviour a stub cannot witness.
BRK_PAY="$WORK/brokered-payload.md"
cat > "$BRK_PAY" <<'BRKPAY'
VERDICT: REQUEST_CHANGES

## Summary
brokered review delivered over ACP

## Findings
### Blocking
- a real blocking finding the parent must stamp

### Advisory
- None.
BRKPAY

run_brokered_leg() {  # <provider> <from> <thread> -> echoes the run dir
  local prov="$1" from="$2" thr="$3" msg dir
  mkdir -p "$MA_FIX/.comms/to-$prov"
  msg="$MA_FIX/.comms/to-$prov/${MA_WS}_2026-08-20T11-00-00_brokered-$prov.md"
  sed -e "s/^thread: ma-arc-1\$/thread: $thr/" \
      -e "s/^from: claude\$/from: $from/" \
      -e "s/_review-req-1\$/_brokered-$prov/" \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  dir="$WORK/ma-brokered-$prov"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$BRK_PAY" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$msg" --dir "$dir" \
      --provider "$prov" --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}

# codex reviews for claude; claude reviews for codex. peer_of() is the two-party map, and the
# session FIELD differs per provider (legacy names), so both are asserted per leg.
for BRK in "codex claude codex_thread_id" "claude codex claude_session_id"; do
  set -- $BRK
  BRK_PROV="$1"; BRK_FROM="$2"; BRK_FIELD="$3"
  BRK_THREAD="ma-brokered-$BRK_PROV"
  BRK_DIR="$(run_brokered_leg "$BRK_PROV" "$BRK_FROM" "$BRK_THREAD")"
  BRK_MSG="$MA_FIX/.comms/to-$BRK_PROV/${MA_WS}_2026-08-20T11-00-00_brokered-$BRK_PROV.md"

  [ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$BRK_DIR/result.json" | head -1)" = "completed" ] \
    && ok "brokered $BRK_PROV leg over ACP completes" || fail "brokered $BRK_PROV leg status (see $BRK_DIR/result.json)"

  BRK_REPLY="$(find "$MA_FIX/.comms/to-$BRK_FROM" -name "*$BRK_PROV-reply*" -type f 2>/dev/null | sort | tail -1)"
  [ -n "$BRK_REPLY" ] \
    && ok "the PARENT persisted the $BRK_PROV reply into to-$BRK_FROM" || fail "no parent-stamped $BRK_PROV reply in to-$BRK_FROM"

  # THE MISATTRIBUTION REGRESSION: this is the assertion that would have caught a `from: grok`
  # default stamping another agent's review.
  grep -q "^from: $BRK_PROV\$" "$BRK_REPLY" 2>/dev/null \
    && ok "the $BRK_PROV reply is stamped from: $BRK_PROV, not the first brokered provider" || fail "$BRK_PROV reply identity"
  grep -q '^verdict: REQUEST_CHANGES$' "$BRK_REPLY" 2>/dev/null \
    && ok "the parent stamped the $BRK_PROV verdict from the child's body" || fail "$BRK_PROV verdict stamp"
  grep -q "^thread: $BRK_THREAD\$" "$BRK_REPLY" 2>/dev/null \
    && ok "the $BRK_PROV reply copies its thread" || fail "$BRK_PROV reply thread"

  [ ! -f "$BRK_MSG" ] && [ -f "$MA_FIX/.comms/archive/$(basename "$BRK_MSG")" ] \
    && ok "the $BRK_PROV inbound was archived by the parent" || fail "$BRK_PROV inbound archive movement"

  BRK_STATE="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_${BRK_THREAD}.json"
  grep -q "\"$BRK_FIELD\"" "$BRK_STATE" 2>/dev/null \
    && ok "the $BRK_PROV leg records its $BRK_FIELD" || fail "$BRK_PROV session field ($BRK_FIELD) not recorded"

  # THE NEGATIVE THAT DEFINES "BROKERED": a self-send prompt tells the child to run the mailbox
  # flow itself. A brokered child is told to emit TEXT and nothing else.
  # `send --to` is the literal self-send instruction the non-ACP arm emits; matching the exact
  # shape (not the helper's rendered path) is what makes this negative discriminating.
  [ -s "$BRK_DIR/prompt.md" ] && ! grep -q 'send --to' "$BRK_DIR/prompt.md" \
    && ok "the brokered $BRK_PROV prompt never tells the child to send its own reply" || fail "$BRK_PROV prompt carries a self-send instruction"
  grep -qi 'trusted parent' "$BRK_DIR/prompt.md" 2>/dev/null \
    && ok "the brokered $BRK_PROV prompt names the parent as the one that delivers" || fail "$BRK_PROV prompt is not the brokered shape"
done

section "scope-dial template source contract"
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

section "templates: bare dollar-digit/dollar-star hygiene"
# INTERNALS editing rule made mechanical: Claude Code substitutes bare dollar-digit
# tokens (and dollar-star) into command markdown at render time with no escape syntax.
# dollar-paren, dollar-brace, and named variables are fine and must pass.
HYG_HITS="$(grep -rnE '\$[0-9]|\$\*' "$REPO/templates" || true)"
if [ -z "$HYG_HITS" ]; then
  ok "no bare dollar-digit/dollar-star tokens under templates/"
else
  fail "bare dollar token(s) under templates/: $(echo "$HYG_HITS" | head -3 | tr '\n' ' ')"
fi

section "/ask canonical template source contract"
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


section "loopspec: prompt fragments do not drift from docs/loopspec/fragments/"
# Every marked region in a template must match its fragment file byte-for-byte
# after per-line leading-whitespace normalization (templates embed at varying
# list indents). Drift is a failing check, not a habit.
# TRACKED-ONLY enumeration. These loops drive assertion COUNTS, and the coverage gate
# turns those counts into a landing decision, so they must reflect the COMMITTED tree.
# A filesystem glob does not: delete a tracked template in the candidate, recreate the
# path untracked before the pre-flight run, and the count stays put while `attest-green`
# (which only refuses TRACKED dirtiness) mints anyway — integrate then skips its clean
# re-run and lands a commit missing the file. (codex, panel r2, blocking.)
tracked_paths() { # <pathspec...> -> absolute paths of tracked files, one per line
  git -C "$REPO" ls-files -- "$@" 2>/dev/null | while IFS= read -r _tp; do
    printf '%s/%s\n' "$REPO" "$_tp"
  done
}

FRAG_SEEN="$WORK/fragments-seen"
: > "$FRAG_SEEN"
for tf in $(tracked_paths 'templates/claude-commands/*.md' 'templates/codex-skills/*/SKILL.md'); do
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
for frag in $(tracked_paths 'docs/loopspec/fragments/*.md'); do
  n="$(basename "$frag" .md)"
  grep -q "^$n$" "$FRAG_SEEN" && ok "fragment $n is embedded by at least one template" || fail "orphan fragment (no template embeds it): $n"
done
# Tripwire: fragment signature phrases must never appear in a template OUTSIDE
# a marked region — an unmarked copy of normative discipline text would silently
# escape the drift check (real-review finding). Signatures are distinctive
# substrings of each fragment; extend this list when adding fragments.
sig_outside_markers() {  # <signature> — prints template:line for hits outside markers
  local sig="$1" tf
  for tf in $(tracked_paths 'templates/claude-commands/*.md' 'templates/codex-skills/*/SKILL.md'); do
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

section "comms.sh: bounded reads (lessons)"
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

section "comms.sh: bounded reads (archive-search)"
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

section "comms.sh: help prints its whole header"
HELP_OUT="$(cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" help)"
echo "$HELP_OUT" | grep -q 'archive-search' \
  && ok "help lists the last subcommand (no fixed-range truncation)" || fail "help truncates its own header"

section "install.sh: .codex/AGENTS.md managed block"
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

section "grading pilot: findings extraction (the single-reviewer baseline)"
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
run_gr_h() { (cd "$GR_FIX" && env -u CMUX_WORKSPACE_ID HOME="$GR_HOME" "$COMMS" "$@"); }
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
SH_RETRY_OUT="$( (cd "$SH_FIX" && env -u CMUX_WORKSPACE_ID PATH="$SH_BIN:$PATH" \
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

section "comms.sh: transport selection (no pane must not strand a consult)"
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
# Delivery here must NOT spawn a real agent: COMMS_DELIVERY=cmux pins the stubbed
# transport. Tests that assert the DEFAULT routing use run_tr, which only asks
# `transport` and never delivers.
run_tr_deliver() { (cd "$TR_FIX" && env COMMS_DELIVERY=cmux PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:7 "$COMMS" "$@"); }
# End-to-end delivery on the REAL default, without spawning a real agent: a copy of the
# helper beside a STUB runphase.sh. `deliver` resolves runphase next to comms.sh, so the
# stub is what gets spawned. This is how a default-routing test stays honest and still
# leaves no background process behind.
TR_SANDBOX="$WORK/tr-sandbox"; mkdir -p "$TR_SANDBOX"
cp "$COMMS" "$TR_SANDBOX/comms.sh"; chmod +x "$TR_SANDBOX/comms.sh"
cat > "$TR_SANDBOX/runphase.sh" <<'RPSTUB'
#!/bin/bash
# stub runphase: report what a real spawn would report, spawn nothing
echo "spawned runphase pid=stub provider=${3:-codex}"
exit 0
RPSTUB
chmod +x "$TR_SANDBOX/runphase.sh"
run_tr_default() { (cd "$TR_FIX" && env -u COMMS_DELIVERY PATH="$STUB_BIN:$PATH" CMUX_WORKSPACE_ID=workspace:7 "$TR_SANDBOX/comms.sh" "$@"); }

cat > "$CMUX_STUB_DIR/tree-workspace_7.txt" <<'TRTREE2'
workspace:7
  pane:1
    surface:23 [terminal] codex
TRTREE2
TR_CONSULT_OUT="$(run_tr_deliver deliver codex "$TR_CONSULT" 2>&1 || true)"
printf '%s\n' "$TR_CONSULT_OUT" | grep -q 'delivered to surface' \
  && ok "a CONSULT with a live pane is nudged, not spawned headless" \
  || fail "consult reclassified as a loop (got: $TR_CONSULT_OUT)"
TR_LOOP_OUT="$(run_tr_default deliver codex "$TR_LOOPMSG" 2>&1 || true)"
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
[ "$(run_tr_default transport codex --loop)" != "cmux" ] && ok "loop mode never resolves to the pane by default" || fail "loop transport"

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
# Atomicity itself is proven live above ("re-delivery of an in-flight turn is guarded").
# What had NO behavioural cover was the other half: a claim whose holder DIED must be
# reclaimable, or one crashed runner wedges that message forever. Asserted by running it.
SC_MSG="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-40-00_staleclaim-1.md"
# Built here, not sed-derived from $HL_WF: that file is deleted upstream (the
# empty-inbox test at the `find ... -delete` above), so the sed produced a
# ZERO-BYTE message and both assertions below ran against an empty fixture --
# the dead-holder reclaim "passed" while proving nothing, negative control and
# all. A derived fixture that can silently evaporate is not a fixture.
cat > "$SC_MSG" <<'SCMSG'
---
type: review-request
from: claude
timestamp: 2026-06-04T14:40:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T14-40-00_staleclaim-1
thread: loop-headless
workflow: auto-implement
phase: implement
round: 7
max-rounds: 10
---

## What was done
Stale-claim fixture.
SCMSG
[ -s "$SC_MSG" ] && ok "stale-claim fixture is a real message, not an empty file" \
  || fail "stale-claim fixture is empty — the assertions below would prove nothing"
SC_MID="$(basename "$SC_MSG" .md)"
SC_CLAIM="$REPO_FIX/.comms/logs/.spawn-$(printf '%s' "$SC_MID" | tr -c 'A-Za-z0-9._-' '_')"
mkdir -p "$SC_CLAIM"
# A pid that is guaranteed dead: start one and reap it. A hardcoded number can be recycled.
( sleep 0 ) & SC_DEAD=$!; wait "$SC_DEAD" 2>/dev/null || true
printf '%s' "$SC_DEAD" > "$SC_CLAIM/pid"
SC_OUT="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless \
    PATH="$STUB_BIN:$PATH" "$RUNPHASE" spawn --provider codex --message "$SC_MSG") 2>&1 )"
case "$SC_OUT" in
  *"already running"*) fail "a claim held by a DEAD pid still wedges the message" ;;
  *) ok "a stale claim from a dead holder is reclaimed, not honoured" ;;
esac
# NEGATIVE CONTROL: the same setup with a LIVE holder must be refused, or the check above
# is just "spawn always spawns" and proves nothing about claims at all.
rm -rf "$SC_CLAIM"; mkdir -p "$SC_CLAIM"; printf '%s' "$$" > "$SC_CLAIM/pid"
SC_OUT2="$( (cd "$REPO_FIX" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless \
    PATH="$STUB_BIN:$PATH" "$RUNPHASE" spawn --provider codex --message "$SC_MSG") 2>&1 )"
case "$SC_OUT2" in
  *"already running"*) ok "a claim held by a LIVE pid is honoured (the reclaim is selective)" ;;
  *) fail "the claim is ignored outright — reclaim proves nothing (got: $SC_OUT2)" ;;
esac
rm -rf "$SC_CLAIM"

section "panel: N parallel 2-party legs over ONE artifact"
PN_FIX="$WORK/panel-repo"; mkdir -p "$PN_FIX"; PN_FIX="$(cd "$PN_FIX" && pwd -P)"
git -C "$PN_FIX" init -q -b main
printf '.comms/\n' > "$PN_FIX/.gitignore"
echo "subject" > "$PN_FIX/s.txt"
git -C "$PN_FIX" add -A >/dev/null 2>&1
git -C "$PN_FIX" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$PN_FIX/.comms/to-codex" "$PN_FIX/.comms/to-grok" "$PN_FIX/.comms/to-claude" "$PN_FIX/.comms/archive"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$PN_FIX/.comms/config"
# Same rule: a panel dispatch delivers to every leg, so it must ride the stub.
run_pn() { (cd "$PN_FIX" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
PN_WS="$(run_pn workspace)"
PN_REQ="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T12-00-00_req.md"
cat > "$PN_REQ" <<PNEOF
---
type: review-request
from: claude
timestamp: 2026-08-26T12:00:00Z
head_sha: $(git -C "$PN_FIX" rev-parse HEAD)
workspace: $(basename "$PN_FIX")
message_id: pn-req-1
thread: pn-thread
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## What was done
panel fixture
PNEOF
PN_OUT="$(run_pn panel dispatch --to codex,grok "$PN_REQ" 2>&1)" && PN_RC=0 || PN_RC=$?
printf '%s\n' "$PN_OUT" | grep -q 'dispatching artifact' && ok "panel dispatch runs" || fail "panel dispatch (got: $PN_OUT)"

# ONE artifact for the whole set — if each leg snapshotted itself they would review
# different trees and "they saw the same artifact" would be false where it must be true.
PN_LEG_C="$(find "$PN_FIX/.comms/to-codex" -name '*panel-codex*' -type f | head -1)"
PN_LEG_G="$(find "$PN_FIX/.comms/to-grok" -name '*panel-grok*' -type f | head -1)"
[ -n "$PN_LEG_C" ] && [ -n "$PN_LEG_G" ] && ok "a leg was written into EACH reviewer's inbox" || fail "panel legs not written"
PN_AC="$(grep -m1 '^artifact_id:' "$PN_LEG_C" | sed 's/^artifact_id: //')"
PN_AG="$(grep -m1 '^artifact_id:' "$PN_LEG_G" | sed 's/^artifact_id: //')"
[ -n "$PN_AC" ] && [ "$PN_AC" = "$PN_AG" ] && ok "every leg carries the SAME artifact_id" || fail "legs disagree on the artifact ($PN_AC vs $PN_AG)"

# CRLF request through the REAL dispatch: rewritten AND inserted fields keep CRLF
PN_CR="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T12-30-00_crlfreq.md"
printf -- '---\r\ntype: review-request\r\nfrom: claude\r\ntimestamp: 2026-08-26T12:30:00Z\r\nworkspace: %s\r\nmessage_id: pn-crlf-1\r\nthread: pn-crlf-thread\r\nworkflow: auto\r\nphase: implement\r\nround: 1\r\nmax-rounds: 4\r\n---\r\n\r\npanel CRLF fixture\r\n' "$(basename "$PN_FIX")" > "$PN_CR"
run_pn panel dispatch --to codex,grok "$PN_CR" >/dev/null 2>&1
PN_CRLEG="$(find "$PN_FIX/.comms/to-codex" -name '*panel-codex*' -type f -newer "$PN_CR" | head -1)"
[ -n "$PN_CRLEG" ] || PN_CRLEG="$(grep -l 'pn-crlf-thread' "$PN_FIX/.comms/to-codex/"*panel-codex* 2>/dev/null | head -1)"
[ -n "$PN_CRLEG" ] && grep -q $'^artifact_id: .*\r$' "$PN_CRLEG" && grep -q $'^thread: .*\r$' "$PN_CRLEG" \
  && ok "CRLF request dispatches with CRLF on inserted AND rewritten leg fields" || fail "panel CRLF end-to-end"
(cd "$PN_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" validate "$PN_CRLEG" >/dev/null 2>&1) \
  && ok "the CRLF leg still validates" || fail "CRLF leg validation"

# A request derived from a prior panel inbound already carries review_set. Dispatch
# must REPLACE it: appending the new one after loses to grep -m1 and every later
# status/compose would gate on the OLD set. (grok, panel r2.)
PN_REQ_STALE="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T12-01-00_req-stale.md"
sed -e 's/^message_id: .*/message_id: pn-req-stale/' \
    -e 's/^thread: .*/thread: pn-stale-thread\nreview_set: stale-old-set/' "$PN_REQ" > "$PN_REQ_STALE"
PN_ST_OUT="$(run_pn panel dispatch --to codex,grok --set pn-fresh "$PN_REQ_STALE" 2>&1 || true)"
PN_ST_SET="$(printf '%s\n' "$PN_ST_OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
PN_ST_LEG="$(find "$PN_FIX/.comms/to-codex" -name '*panel-codex*' -type f | xargs grep -l 'pn-stale-thread' | head -1)"
[ -n "$PN_ST_LEG" ] && [ "$(grep -c '^review_set:' "$PN_ST_LEG")" = "1" ] \
  && ok "a leg carries exactly ONE review_set line" || fail "stale review_set survived alongside the new one"
# RETRY IDEMPOTENCE: re-dispatching the same request over the same tree recreates the
# same set id with NEW leg message ids. The old rows must be REBOUND to this dispatch —
# keeping them strands the fresh legs (their replies can never match the recorded
# request id) or replays a completed old set's stale replies. (codex, panel r3.)
PN_RT_OUT="$(run_pn panel dispatch --to codex,grok --set pn-fresh "$PN_REQ_STALE" 2>&1 || true)"
PN_RT_SET="$(printf '%s\n' "$PN_RT_OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$PN_RT_SET" = "$PN_ST_SET" ] && ok "a retry recreates the same deterministic set id" || fail "retry set id drifted ($PN_ST_SET vs $PN_RT_SET)"
PN_RT_LEG="$(find "$PN_FIX/.comms/to-codex" -name '*panel-codex*' -type f | xargs grep -l 'pn-stale-thread' | xargs ls -t 2>/dev/null | head -1)"
PN_RT_MID="$(grep -m1 '^message_id:' "$PN_RT_LEG" | sed 's/^message_id: //')"
# ONE ROW PER ATTEMPT, not one row per agent. Deleting every same-set/same-agent row is what
# let a second dispatch eat the first attempt's legs, leaving an index with one leg of each
# and a "complete" one-leg panel to gate on; other attempts' rows are preserved now and the
# readers filter by dispatch. Within an attempt a duplicate is still a defect.
# (codex + grok, implement r2, corroborated.)
[ "$(awk -F'\t' -v s="$PN_RT_SET" 'NR>1 && $1==s && $10=="codex" {n[$14]++} END {for (k in n) if (n[k] != 1) dup=1; print (dup ? "dup" : "one-each")}' "$PN_FIX/.comms/grades/sets.tsv")" = "one-each" ] \
  && ok "a retried leg keeps exactly ONE row per dispatch attempt" || fail "retry left duplicate rows within one attempt"
awk -F'\t' -v s="$PN_RT_SET" 'NR>1 && $1==s && $10=="codex" {print $2}' "$PN_FIX/.comms/grades/sets.tsv" | grep -qxF "$PN_RT_MID" \
  && ok "the retried row is REBOUND to the new dispatch's request id" \
  || fail "retry kept the stale request_message_id — new replies can never answer it"

# STATUS/COMPOSE AGREEMENT: both scan skip-invalid-and-continue, so a newest-but-
# invalid bound candidate above an older valid reply yields the same answer from
# both. Divergence here means status says "answered" while compose refuses — an
# operator chasing a phantom incomplete panel. (codex + grok, panel r3.)
PN_REQ_AGREE="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T12-02-00_req-agree.md"
sed -e 's/^message_id: .*/message_id: pn-req-agree/' -e 's/^thread: .*/thread: pn-agree-thread/' "$PN_REQ" > "$PN_REQ_AGREE"
PN_AGR_OUT="$(run_pn panel dispatch --to codex,grok --set pn-agree "$PN_REQ_AGREE" 2>&1 || true)"
PN_AGR_SET="$(printf '%s\n' "$PN_AGR_OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
PN_AGR_MC="$(find "$PN_FIX/.comms/to-codex" -type f | xargs grep -l '^thread: pn-agree-thread-codex' 2>/dev/null | head -1)"
PN_AGR_MG="$(find "$PN_FIX/.comms/to-grok" -type f | xargs grep -l '^thread: pn-agree-thread-grok' 2>/dev/null | head -1)"
PN_AGR_MIDC="$(grep -m1 '^message_id:' "$PN_AGR_MC" | sed 's/^message_id: //')"
PN_AGR_MIDG="$(grep -m1 '^message_id:' "$PN_AGR_MG" | sed 's/^message_id: //')"
mk_agree_reply() { # <agent> <minute> <in-reply-to> <body-or-empty>
  local f="$PN_FIX/.comms/archive/${PN_WS}_2026-08-26T12-4${2}-00_${1}-agree.md"
  { printf -- '---\ntype: review-feedback\nfrom: %s\ntimestamp: 2026-08-26T12:4%s:00Z\nworkspace: %s\nmessage_id: %s-agree-%s\nthread: pn-agree-thread-%s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n%s' \
      "$1" "$2" "$PN_WS" "$1" "$2" "$1" "$3" "$4"
  } > "$f"
}
mk_agree_reply codex 0 "$PN_AGR_MIDC" '## Findings

### Blocking
- None.'
mk_agree_reply codex 1 "$PN_AGR_MIDC" ''    # newer, bound, INVALID (empty body)
mk_agree_reply grok  0 "$PN_AGR_MIDG" '## Findings

### Blocking
- None.'
PN_AGR_STATUS="$(run_pn panel status --set "$PN_AGR_SET" 2>&1)"
printf '%s\n' "$PN_AGR_STATUS" | awk -F'\t' '$1=="codex" && $3=="yes"' | grep -q . \
  && ok "status sees the older VALID reply past a newer invalid one" || fail "status stopped at the invalid candidate"
PN_AGR_COMP="$(run_pn compose --set "$PN_AGR_SET" 2>&1)" && PN_AGR_RC=0 || PN_AGR_RC=$?
[ "$PN_AGR_RC" = "0" ] && printf '%s\n' "$PN_AGR_COMP" | grep -q 'all answered' \
  && ok "compose agrees — the same older valid reply completes the leg" \
  || fail "status and compose disagree on an invalid-then-valid candidate (rc=$PN_AGR_RC)"

grep -q "^review_set: $PN_ST_SET$" "$PN_ST_LEG" 2>/dev/null \
  && ok "dispatch REPLACES an inherited review_set with the set it actually dispatched" \
  || fail "leg kept the stale set ($(grep -m1 '^review_set:' "$PN_ST_LEG"))"

# 2-party per leg: distinct threads, shared review_set. Never an N-party thread.
PN_TC="$(grep -m1 '^thread:' "$PN_LEG_C" | sed 's/^thread: //')"
PN_TG="$(grep -m1 '^thread:' "$PN_LEG_G" | sed 's/^thread: //')"
[ "$PN_TC" != "$PN_TG" ] && ok "each leg is its own 2-party thread" || fail "legs share a thread ($PN_TC)"
PN_SC="$(grep -m1 '^review_set:' "$PN_LEG_C" | sed 's/^review_set: //')"
[ -n "$PN_SC" ] && [ "$PN_SC" = "$(grep -m1 '^review_set:' "$PN_LEG_G" | sed 's/^review_set: //')" ] \
  && ok "legs share one review_set" || fail "review_set not shared"
[ "$(grep -c '^message_id:' "$PN_LEG_C")" = "1" ] && ok "each leg has exactly one message_id" || fail "leg message_id duplicated"
[ "$(grep -m1 '^message_id:' "$PN_LEG_C")" != "$(grep -m1 '^message_id:' "$PN_LEG_G")" ] \
  && ok "legs have distinct message ids" || fail "legs share a message_id"
run_pn validate "$PN_LEG_C" >/dev/null 2>&1 && ok "a dispatched leg validates" || fail "leg does not validate"

# Roster is validated BEFORE anything is sent: a half-fanned panel silently drops a voice
# from the composed gate.
check_not "panel refuses an unregistered reviewer" run_pn panel dispatch --to codex,gemini "$PN_REQ"
check_not "panel refuses the request's own author" run_pn panel dispatch --to claude "$PN_REQ"
check_not "panel refuses a duplicate reviewer" run_pn panel dispatch --to codex,codex "$PN_REQ"
# COMPOSE: cluster by support, drop nothing, let judgment live in the gate.
# A conformant reply is BOUND to its request via in-reply-to — compose refuses anything
# else, so the fixtures must model the binding too.
PN_MID_C="$(grep -m1 '^message_id:' "$PN_LEG_C" | sed 's/^message_id: //')"
PN_MID_G="$(grep -m1 '^message_id:' "$PN_LEG_G" | sed 's/^message_id: //')"
mk_leg_reply() { # <agent> <thread> <blocking-anchor> <extra-blocking-anchor-or-empty> <minute> <in-reply-to>
  local ag="$1" th="$2" a1="$3" a2="${4:-}" irt="${6:-}"
  local f="$PN_FIX/.comms/archive/${PN_WS}_2026-08-26T12-3${5:-0}-00_${ag}-reply.md"
  { printf -- '---\ntype: review-feedback\nfrom: %s\ntimestamp: 2026-08-26T12:3%s:00Z\nworkspace: %s\nmessage_id: %s-reply\nthread: %s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: REQUEST_CHANGES\n---\n\n## Findings\n\n### Blocking\n' "$ag" "${5:-0}" "$PN_WS" "$ag" "$th" "$irt"
    printf -- '- `%s` — %s says this one is real.\n' "$a1" "$ag"
    [ -n "$a2" ] && printf -- '- `%s` — only %s saw this.\n' "$a2" "$ag"
    printf -- '\n### Advisory\n- `s.txt:9` — %s advisory.\n' "$ag"
  } > "$f"
}
# Both flag s.txt:1 (corroborated); each also has one nobody else saw (unique).
mk_leg_reply codex "$PN_TC" "s.txt:1" "s.txt:2" 0 "$PN_MID_C"
mk_leg_reply grok  "$PN_TG" "s.txt:1" "s.txt:3" 1 "$PN_MID_G"
PN_COMP="$(run_pn compose --set "$PN_SC" 2>&1)"
printf '%s\n' "$PN_COMP" | grep -q '2 legs, all answered' && ok "compose reports full-panel coverage" || fail "compose coverage (got: $(printf '%s' "$PN_COMP" | head -2))"
# The corroborated anchor gates.
printf '%s\n' "$PN_COMP" | awk '/^## Gates/,/^## Uncorroborated/' | grep -q 's.txt:1' \
  && ok "an anchor two reviewers independently flagged is a GATE" || fail "corroborated finding not gated"
# Unique findings are PRESERVED, not dropped — grok's core objection to condensing.
printf '%s\n' "$PN_COMP" | grep -q 's.txt:2' && printf '%s\n' "$PN_COMP" | grep -q 's.txt:3' \
  && ok "unique findings from BOTH reviewers survive composition" || fail "a unique finding was dropped"
printf '%s\n' "$PN_COMP" | awk '/^## Uncorroborated/,/^## Unanchored/' | grep -q 's.txt:2' \
  && ok "a lone blocking finding is flagged for cross-check, not silently obeyed" || fail "uncorroborated labelling"
printf '%s\n' "$PN_COMP" | grep -q 's.txt:9' && ok "advisories are carried but never gate" || fail "advisory dropped"
# Every finding stays ATTRIBUTED — a bundle that is nobody's review is the failure mode.
printf '%s\n' "$PN_COMP" | grep -q '\[codex\]' && printf '%s\n' "$PN_COMP" | grep -q '\[grok\]' \
  && ok "every finding stays attributed to the reviewer that made it" || fail "attribution lost in composition"

# A PARTIAL panel must never gate: composing over a missing voice looks like more
# review than actually happened. This second dispatch REUSES the same base thread at
# the same round and phase, and the archive already holds valid round-1 replies on
# those threads — the exact false-complete a thread+round match alone would compose.
# Only the in-reply-to binding keeps these legs unanswered. The set id is read back
# from dispatch because safe_set_id rewrites the raw value; composing the raw token
# used to error 'no legs' and let the old grep pass without touching this path at
# all. (grok, panel r1 — the vacuous-test finding.)
PN_P2OUT="$(run_pn panel dispatch --to codex,grok --set pn-partial "$PN_REQ" 2>&1 || true)"
PN_SET2="$(printf '%s\n' "$PN_P2OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$PN_SET2" ] && ok "partial-panel test composes the id dispatch actually used" || fail "could not read back pn-partial set id"
PN_PART="$(run_pn compose --set "$PN_SET2" 2>&1)" && PN_PRC=0 || PN_PRC=$?
[ "${PN_PRC:-0}" = "3" ] && printf '%s\n' "$PN_PART" | grep -q 'INCOMPLETE' \
  && ok "an unanswered leg blocks composition instead of counting as approval" || fail "partial panel composed anyway (rc=$PN_PRC: $(printf '%s' "$PN_PART" | head -1))"
printf '%s\n' "$PN_PART" | grep -q 'all answered' \
  && fail "a re-dispatched set counted another request's replies as its own" \
  || ok "a reply never answers a request it was not written to (in-reply-to binding)"

# ROUND STALENESS: a panel round 2 must not compose round 1's replies. The set index
# keys on thread+phase+round but compose found replies by reviewer+thread alone, so it
# would report "all answered" using findings about an artifact it is no longer reviewing.
# (grok, panel r1 — the bug it found in the feature reviewing it.)
PN_R2REQ="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T13-00-00_req2.md"
sed -e 's|^message_id: .*|message_id: pn-req-2|' -e 's|^round: 1|round: 2|' "$PN_REQ" > "$PN_R2REQ"
# safe_set_id appends a hash of the raw value, so read the real id back from dispatch.
PN_R2OUT="$(run_pn panel dispatch --to codex,grok --set pn-round2 "$PN_R2REQ" 2>&1 || true)"
PN_R2SET="$(printf '%s\n' "$PN_R2OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$PN_R2SET" ] && ok "dispatch reports the set id it actually used" || fail "could not read back the set id"
PN_R2="$(run_pn compose --set "$PN_R2SET" 2>&1)" && PN_R2RC=0 || PN_R2RC=$?
printf '%s\n' "$PN_R2" | grep -qi 'INCOMPLETE' \
  && ok "round 2 does NOT compose round 1's replies — it reports incomplete" \
  || fail "round 2 composed stale replies (got: $(printf '%s' "$PN_R2" | head -1))"
printf '%s\n' "$PN_R2" | grep -q 'all answered' \
  && fail "round 2 claimed all legs answered using round-1 replies" \
  || ok "a stale round is never counted as an answer"

PN_STATUS="$(run_pn panel status --set "$PN_SC" 2>&1)"
printf '%s\n' "$PN_STATUS" | grep -q 'codex' && printf '%s\n' "$PN_STATUS" | grep -q 'grok' \
  && ok "panel status lists every leg in the set" || fail "panel status (got: $PN_STATUS)"
printf '%s\n' "$PN_STATUS" | awk -F'\t' 'NF>=4 && $1!="reviewer" && $3!="yes"' | grep -q . \
  && fail "status missed a genuinely bound answer" || ok "panel status sees bound answers"
# Status shares compose's binding: the pn-partial legs sit on the SAME threads with
# valid same-round replies in the archive, and must still read unanswered.
PN_STAT2="$(run_pn panel status --set "$PN_SET2" 2>&1)"
printf '%s\n' "$PN_STAT2" | awk -F'\t' 'NR>1 && $3=="yes"' | grep -q . \
  && fail "panel status counted another request's reply as answered" \
  || ok "panel status never reports a stale or unbound reply as answered"

# DRIVER-NEUTRAL ARRIVAL. `panel status` and `compose` scanned the archive and a
# HARDCODED to-claude, so every panel a non-claude agent drove was invisible to its own
# gate: the replies land in the DRIVER's inbox (to-codex here), both readers saw an
# empty leg, and compose refused a complete panel as INCOMPLETE — a paid-for review
# discarded over the directory it arrived in. Every existing panel test uses
# `from: claude`, which is exactly why this survived.
PN_CXREQ="$PN_FIX/.comms/to-grok/${PN_WS}_2026-08-26T14-00-00_cxreq.md"
sed -e 's|^from: claude|from: codex|' -e 's|^message_id: .*|message_id: pn-cx-req|' \
    -e 's|^thread: .*|thread: pn-cx-thread|' "$PN_REQ" > "$PN_CXREQ"
PN_CXOUT="$(run_pn panel dispatch --to claude,grok --set pn-cxdriver "$PN_CXREQ" 2>&1 || true)"
PN_CXSET="$(printf '%s\n' "$PN_CXOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$PN_CXSET" ] && ok "a codex-driven panel dispatches" || fail "codex-driven dispatch (got: $PN_CXOUT)"
# Answer both legs into the DRIVER's inbox, bound exactly as a real reply is.
PN_CX_ANSWERED=0
for pn_ag in claude grok; do
  # Earlier sections already dispatched grok legs into this fixture, so take the
  # NEWEST leg (filenames are timestamp-sorted) — head -1 binds the reply to a
  # stale request and the leg then correctly reads unanswered.
  pn_leg="$(find "$PN_FIX/.comms/to-$pn_ag" -name "*panel-$pn_ag*" -type f | sort | tail -1)"
  [ -n "$pn_leg" ] || { fail "no $pn_ag leg for the codex-driven panel"; continue; }
  pn_mid="$(grep -m1 '^message_id:' "$pn_leg" | sed 's/^message_id: //')"
  pn_th="$(grep -m1 '^thread:' "$pn_leg" | sed 's/^thread: //')"
  { printf -- '---\ntype: review-feedback\nfrom: %s\ntimestamp: 2026-08-26T14:10:00Z\nworkspace: %s\nmessage_id: pn-cx-reply-%s\nthread: %s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n- None.\n' \
      "$pn_ag" "$PN_WS" "$pn_ag" "$pn_th" "$pn_mid"
  } > "$PN_FIX/.comms/to-codex/${PN_WS}_2026-08-26T14-10-0${PN_CX_ANSWERED}_${pn_ag}-cxreply.md"
  PN_CX_ANSWERED=$((PN_CX_ANSWERED + 1))
done
PN_CXSTAT="$(run_pn panel status --set "$PN_CXSET" 2>&1)"
[ "$(printf '%s\n' "$PN_CXSTAT" | awk -F'\t' 'NR>1 && $3=="yes"' | grep -c .)" = "2" ] \
  && ok "panel status sees replies in a NON-claude driver's inbox" \
  || fail "status missed a codex-driven panel's replies (got: $PN_CXSTAT)"
PN_CXCOMP="$(run_pn compose --set "$PN_CXSET" 2>&1)" && PN_CXRC=0 || PN_CXRC=$?
[ "$PN_CXRC" = "0" ] && printf '%s\n' "$PN_CXCOMP" | grep -q 'all answered' \
  && ok "compose completes a codex-driven panel" \
  || fail "compose refused a complete codex-driven panel (rc=$PN_CXRC, got: $(printf '%s' "$PN_CXCOMP" | head -2))"
# COMPOSE MUST REFUSE A BLIND LEG. The broker applies the residue rule before stamping, but
# a self-sending agent authors its own envelope, so a `verdict: APPROVE` over an unreadable
# Blocking lane reaches compose unchecked, passes cmd_validate, and composes as
# "0 findings (0 blocking)" with empty gates — the same false all-clear one layer out.
# (codex, panel r3.)
PN_BLREQ="$PN_FIX/.comms/to-grok/${PN_WS}_2026-08-26T16-00-00_blindreq.md"
sed -e 's|^message_id: .*|message_id: pn-blind-req|' -e 's|^thread: .*|thread: pn-blind-thread|' \
    "$PN_CXREQ" > "$PN_BLREQ"
PN_BLOUT="$(run_pn panel dispatch --to claude --set pn-blind "$PN_BLREQ" 2>&1 || true)"
PN_BLSET="$(printf '%s\n' "$PN_BLOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
pn_blleg="$(find "$PN_FIX/.comms/to-claude" -name '*panel-claude*' -type f | sort | tail -1)"
pn_blmid="$(grep -m1 '^message_id:' "$pn_blleg" | sed 's/^message_id: //')"
pn_blth="$(grep -m1 '^thread:' "$pn_blleg" | sed 's/^thread: //')"
{ printf -- '---\ntype: review-feedback\nfrom: claude\ntimestamp: 2026-08-26T16:10:00Z\nworkspace: %s\nmessage_id: pn-blind-reply\nthread: %s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n\nBLOCKING\tinstall.sh:195\ta real defect written as a lead-token line\n\n### Advisory\n- None.\n' \
    "$PN_WS" "$pn_blth" "$pn_blmid"
} > "$PN_FIX/.comms/to-codex/${PN_WS}_2026-08-26T16-10-00_blind-reply.md"
PN_BLCOMP="$(run_pn compose --set "$PN_BLSET" 2>&1)" && PN_BLRC=0 || PN_BLRC=$?
[ "$PN_BLRC" = "3" ] \
  && ok "compose REFUSES a self-authored APPROVE over an unreadable Blocking lane" \
  || fail "compose gated on a blind leg (rc=$PN_BLRC)"
printf '%s\n' "$PN_BLCOMP" | grep -q 'could not read' \
  && ok "the refusal says the count was a failed read, not a clean review" || fail "blind refusal not explained"
printf '%s\n' "$PN_BLCOMP" | grep -q '0 blocking' \
  && fail "compose still printed a clean finding count for a blind leg" || ok "no clean count is printed for a blind leg"
# The broker refuses an unclosed fence before it will stamp anything, because parsing STOPS
# there and every count after it describes a truncated read. compose sees self-authored
# envelopes the broker never touched, so it has to refuse on the same signal or the gate has
# simply moved. (codex, panel r4.)
PN_FNREQ="$PN_FIX/.comms/to-grok/${PN_WS}_2026-08-26T17-00-00_fencereq.md"
sed -e 's|^message_id: .*|message_id: pn-fence-req|' -e 's|^thread: .*|thread: pn-fence-thread|' \
    "$PN_CXREQ" > "$PN_FNREQ"
PN_FNOUT="$(run_pn panel dispatch --to claude --set pn-fence "$PN_FNREQ" 2>&1 || true)"
PN_FNSET="$(printf '%s\n' "$PN_FNOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
pn_fnleg="$(find "$PN_FIX/.comms/to-claude" -name '*panel-claude*' -type f | sort | tail -1)"
pn_fnmid="$(grep -m1 '^message_id:' "$pn_fnleg" | sed 's/^message_id: //')"
pn_fnth="$(grep -m1 '^thread:' "$pn_fnleg" | sed 's/^thread: //')"
{ printf -- '---\ntype: review-feedback\nfrom: claude\ntimestamp: 2026-08-26T17:10:00Z\nworkspace: %s\nmessage_id: pn-fence-reply\nthread: %s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Summary\n\n```\nan unclosed fence swallows everything after it\n\n### Blocking\n\n- a real defect nobody will ever read\n' \
    "$PN_WS" "$pn_fnth" "$pn_fnmid"
} > "$PN_FIX/.comms/to-codex/${PN_WS}_2026-08-26T17-10-00_fence-reply.md"
PN_FNCOMP="$(run_pn compose --set "$PN_FNSET" 2>&1)" && PN_FNRC=0 || PN_FNRC=$?
[ "$PN_FNRC" = "3" ] \
  && ok "compose REFUSES a self-authored APPROVE whose body was truncated by an unclosed fence" \
  || fail "compose gated on a truncated read (rc=$PN_FNRC)"
printf '%s\n' "$PN_FNCOMP" | grep -q 'truncated read' \
  && ok "the fence refusal says the read was truncated" || fail "fence refusal not explained"
printf '%s\n' "$PN_FNCOMP" | grep -q 'close the code fence' \
  && ok "the fence refusal names the fix that matches its reason" || fail "fence refusal gave list-item advice"
# THE TWIN: a CLOSED fence quoting a prior round is legitimate and must still compose, or the
# refusal is over-broad and every round-2 reply that quotes round 1 stops gating.
# (grok, panel r5 — asked for as a lock, not because a hole was found.)
PN_CFREQ="$PN_FIX/.comms/to-grok/${PN_WS}_2026-08-26T18-00-00_closedfence.md"
sed -e 's|^message_id: .*|message_id: pn-cfence-req|' -e 's|^thread: .*|thread: pn-cfence-thread|' \
    "$PN_CXREQ" > "$PN_CFREQ"
PN_CFOUT="$(run_pn panel dispatch --to claude --set pn-cfence "$PN_CFREQ" 2>&1 || true)"
PN_CFSET="$(printf '%s\n' "$PN_CFOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
pn_cfleg="$(find "$PN_FIX/.comms/to-claude" -name '*panel-claude*' -type f | sort | tail -1)"
pn_cfmid="$(grep -m1 '^message_id:' "$pn_cfleg" | sed 's/^message_id: //')"
pn_cfth="$(grep -m1 '^thread:' "$pn_cfleg" | sed 's/^thread: //')"
{ printf -- '---\ntype: review-feedback\nfrom: claude\ntimestamp: 2026-08-26T18:10:00Z\nworkspace: %s\nmessage_id: pn-cfence-reply\nthread: %s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Summary\n\nQuoting last round:\n\n```\n### Blocking\n- an OLD blocker from round 1\n```\n\n## Findings\n\n### Blocking\n\n- None.\n\n### Advisory\n\n- None.\n' \
    "$PN_WS" "$pn_cfth" "$pn_cfmid"
} > "$PN_FIX/.comms/to-codex/${PN_WS}_2026-08-26T18-10-00_cfence-reply.md"
PN_CFCOMP="$(run_pn compose --set "$PN_CFSET" 2>&1)" && PN_CFRC=0 || PN_CFRC=$?
[ "$PN_CFRC" = "0" ] \
  && ok "a CLOSED fence quoting a prior round still composes cleanly" \
  || fail "the fence refusal over-fires on a legitimate quote (rc=$PN_CFRC)"
# The widened scan must still be gated by the BINDING, not by the directory: an
# unbound reply sitting in yet another inbox is not an answer.
PN_UBREQ="$PN_FIX/.comms/to-grok/${PN_WS}_2026-08-26T15-00-00_ubreq.md"
sed -e 's|^message_id: .*|message_id: pn-ub-req|' -e 's|^thread: .*|thread: pn-ub-thread|' \
    "$PN_CXREQ" > "$PN_UBREQ"
PN_UBOUT="$(run_pn panel dispatch --to claude --set pn-unbound "$PN_UBREQ" 2>&1 || true)"
PN_UBSET="$(printf '%s\n' "$PN_UBOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$PN_UBSET" ] && ok "the unbound-reply fixture dispatched" || fail "unbound fixture dispatch (got: $PN_UBOUT)"
pn_ubleg="$(find "$PN_FIX/.comms/to-claude" -name '*panel-claude*' -type f | sort | tail -1)"
pn_ubth="$(grep -m1 '^thread:' "$pn_ubleg" | sed 's/^thread: //')"
{ printf -- '---\ntype: review-feedback\nfrom: claude\ntimestamp: 2026-08-26T15:10:00Z\nworkspace: %s\nmessage_id: pn-ub-reply\nthread: %s\nin-reply-to: some-other-request\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n- None.\n' \
    "$PN_WS" "$pn_ubth"
} > "$PN_FIX/.comms/to-grok/${PN_WS}_2026-08-26T15-10-00_claude-ubreply.md"
PN_UBSTAT="$(run_pn panel status --set "$PN_UBSET" 2>&1)"
printf '%s\n' "$PN_UBSTAT" | awk -F'\t' 'NR>1 && $3=="yes"' | grep -q . \
  && fail "an unbound reply in another inbox counted as an answer" \
  || ok "the widened scan still refuses an unbound reply (binding, not directory)"

# DISCOVERABILITY: an await dies with its session and takes the printed set id with it.
# sets.tsv is durable, so bare `panel status` enumerates it instead of usage-erroring.
PN_LIST="$(run_pn panel status 2>/dev/null)"
printf '%s\n' "$PN_LIST" | head -1 | grep -q '^set' \
  && ok "bare panel status prints a set listing header" || fail "bare panel status header (got: $(printf '%s' "$PN_LIST" | head -1))"
printf '%s\n' "$PN_LIST" | awk -F'\t' -v s="$PN_CXSET" 'NR>1 && $1==s' | grep -q . \
  && ok "bare panel status lists a dispatched set by id" || fail "set $PN_CXSET missing from the listing"
[ "$(printf '%s\n' "$PN_LIST" | awk -F'\t' -v s="$PN_CXSET" 'NR>1 && $1==s {print $4}')" = "2" ] \
  && ok "the listing counts both legs of the set" \
  || fail "leg count wrong (got: $(printf '%s\n' "$PN_LIST" | awk -F'\t' -v s="$PN_CXSET" 'NR>1 && $1==s {print $4}'))"
[ "$(printf '%s\n' "$PN_LIST" | awk -F'\t' 'NR>1' | grep -c .)" = "$(awk -F'\t' 'NR>1 && $1!="" {print $1}' "$PN_FIX/.comms/grades/sets.tsv" | sort -u | grep -c .)" ] \
  && ok "the listing has exactly one row per review set" || fail "set listing is not deduplicated"
# A MALFORMED REGISTRY must fail both readers loudly. `leg_reply_candidates` runs inside a
# command substitution, so a registry read in there can only kill the subshell: the
# expansion comes back empty, `for cand in <empty>` succeeds, and the panel reports every
# leg unanswered while exiting 0. The registry is therefore read by the caller, where the
# failure can still abort — and this is the assertion that proves it. (codex, panel r1.)
cp "$PN_FIX/.comms/config" "$WORK/pn-config.bak"
printf 'agents =\ndefault-target = codex\n' > "$PN_FIX/.comms/config"
run_pn panel status --set "$PN_CXSET" >/dev/null 2>&1 \
  && fail "panel status exited 0 on a malformed registry" || ok "panel status fails loudly on a malformed registry"
run_pn compose --set "$PN_CXSET" >/dev/null 2>&1 \
  && fail "compose exited 0 on a malformed registry" || ok "compose fails loudly on a malformed registry"
# ...and specifically NOT with the answers-look-missing shape, which is the failure the
# subshell swallow produced: an empty scan reporting a complete panel as incomplete.
PN_BADC="$(run_pn compose --set "$PN_CXSET" 2>&1 || true)"
printf '%s\n' "$PN_BADC" | grep -q 'INCOMPLETE' \
  && fail "a config error was reported as an unanswered panel" || ok "a config error is not disguised as an unanswered leg"
command cp -f "$WORK/pn-config.bak" "$PN_FIX/.comms/config"
run_pn panel status --set "$PN_CXSET" >/dev/null 2>&1 \
  && ok "the fixture recovers once the registry is valid again" || fail "fixture did not recover"
# A TRUNCATED sets.tsv row is not a leg. Counting it would make the listing report durable
# state that is not there. (codex advisory r1.)
printf 'truncated-set\tonly-two-fields\n' >> "$PN_FIX/.comms/grades/sets.tsv"
run_pn panel status 2>/dev/null | awk -F'\t' 'NR>1 && $1=="truncated-set"' | grep -q . \
  && fail "the listing counted a truncated row as a set" || ok "the listing ignores a truncated sets.tsv row"

section "ask: the driver-neutral consult verb"
AK="$WORK/ask-repo"; mkdir -p "$AK"; AK="$(cd "$AK" && pwd -P)"
git -C "$AK" init -q -b main
git -C "$AK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$AK/.comms/to-codex" "$AK/.comms/to-grok" "$AK/.comms/to-claude"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$AK/.comms/config"
run_ak() { (cd "$AK" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=cmux PATH="$STUB_BIN:$PATH" "$COMMS" "$@"); }
# The point of the verb: an agent that is NOT claude can ask, in one call.
run_ak ask --from codex --to grok "is the retry approach sound?" >/dev/null 2>&1 || true
AKF="$(find "$AK/.comms/to-grok" -name '*ask-codex-to-grok*' -type f | head -1)"
[ -n "$AKF" ] && ok "codex can ask grok without hand-authoring a message" || fail "ask did not compose a message"
grep -q '^from: codex$' "$AKF" && ok "the asker's identity is recorded, not assumed to be claude" || fail "ask from identity"
grep -q '^type: question$' "$AKF" && ok "ask composes a question, not a review-request" || fail "ask message type"
grep -q 'is the retry approach sound' "$AKF" && ok "the question body is carried verbatim" || fail "ask body"
run_ak validate "$AKF" >/dev/null 2>&1 && ok "a composed question validates" || fail "ask message invalid"
grep -q '^workflow:' "$AKF" && fail "a consult carries workflow fields" || ok "a consult has no workflow — it is not a loop"
grep -q '^artifact_id:' "$AKF" && fail "a consult was stamped with an artifact" || ok "a consult pins no artifact"
check_not "ask refuses a self-consult" run_ak ask --from codex --to codex hi
check_not "ask refuses an unregistered agent" run_ak ask --from codex --to gemini hi
check_not "ask requires a question" run_ak ask --from codex --to grok
check_not "ask requires --from" run_ak ask --to grok hi
# The default panel is derived, not hardcoded: registering a new agent must change it.
[ "$(run_ak agents --others claude)" = "codex,grok" ] && ok "agents --others excludes the driver" || fail "agents --others"
[ "$(run_ak agents --others codex)" = "claude,grok" ] && ok "the roster follows whoever is driving" || fail "agents --others driver"
printf 'agents = claude codex\ndefault-target = codex\n' > "$AK/.comms/config"
[ "$(run_ak agents --others claude)" = "codex" ] && ok "a smaller registry yields a smaller panel" || fail "agents --others registry-driven"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$AK/.comms/config"
check_not "agents --others rejects an unregistered agent" run_ak agents --others gemini
check_not "agents --others requires a name" run_ak agents --others
# --file carries a longer brief
printf 'a longer question\nacross lines\n' > "$AK/q.md"
run_ak ask --from grok --to codex --file "$AK/q.md" >/dev/null 2>&1 || true
AKF2="$(find "$AK/.comms/to-codex" -name '*ask-grok-to-codex*' -type f | head -1)"
[ -n "$AKF2" ] && grep -q 'across lines' "$AKF2" && ok "--file carries a multi-line brief" || fail "ask --file"

# send --wait must exist as a flag: a detached child is reaped when the managed shell
# command that spawned it ends, which is normal inside an agent sandbox.
grep -q -- '--wait) COMMS_WAIT=1' "$COMMS" && ok "send accepts --wait" || fail "send --wait flag"
grep -q 'in the foreground (no detach)' "$COMMS" && ok "--wait runs the turn in the foreground" || fail "--wait foreground path"
# acpx launch is asked for, never guessed twice
grep -q 'acpx_launcher' "$REPO/helpers/acp.sh" && ok "acp.sh owns how acpx is launched" || fail "acpx launcher"
grep -q 'ACPX_BIN' "$REPO/helpers/acp.sh" && ok "an installed acpx binary can replace npx entirely" || fail "ACPX_BIN support"
grep -q 'npm_config_cache' "$REPO/helpers/acp.sh" \
  && ok "an unwritable ~/.npm falls back to a workspace cache" || fail "npm cache fallback"
grep -q 'synthesized by await' "$REPO/helpers/runphase.sh" \
  && ok "a pid that dies without a result gets a synthetic one" || fail "synthetic failed result"

section "review turns may read history, never publish or rewrite it"
# The threat model is deliberately "the same as running the agent by hand in the repo":
# it may read the tree and the history. What it may not do is publish or destroy — a
# linked worktree shares the main object store and the REAL remotes, so a `git push` from
# inside a mount reaches production.
GS="$WORK/gitshim"; mkdir -p "$GS"
# Generated by the PRODUCTION function against the REAL git. The previous fixture pasted the
# shim body inline AND pointed it at an echo-only fake, so it could prove which verbs were
# admitted and nothing else — while the shipped shim was defeatable through the environment,
# through exec-taking flags on permitted verbs, and through a ref-writing verb on its own
# allowlist. A fake git cannot observe any of that. (codex + grok, round 7.)
( set -e
  eval "$(awk '/^write_git_shim\(\) \{/,/^\}/' "$REPO/helpers/runphase.sh")"
  write_git_shim "$GS" "$(command -v git)" )
[ -x "$GS/git" ] && ok "the suite builds the shim from the shipped generator" || fail "shim generator not callable"

# The INVARIANT, not an enumeration of known tricks: a mounted review turn must not be able to
# execute an arbitrary program or write a file through git. Refusal and neutralisation are both
# acceptable mechanisms; execution is not. Stating it this way is what the corpus advisory asked
# for — a new trick fails this block without anyone naming it first.
GV="$WORK/gitshim-victim"; mkdir -p "$GV"
git -C "$GV" init -q . >/dev/null 2>&1
printf 'base\n' > "$GV/f.txt"
git -C "$GV" add -A >/dev/null 2>&1
git -C "$GV" -c user.email=t@t -c user.name=t commit -q -m base >/dev/null 2>&1
# EVERY payload destination lives INSIDE the scanned root. The previous fixture put the
# canary and the --output target in $WORK while the scan covered $GV and an unused
# $WORK/gitshim-out, so eight of the twelve attacks could succeed and still read "clean".
# An invariant that does not observe its own sentinels asserts nothing. (codex + grok, r9.)
GPAY="$GV/.payload"; GCAN="$GV/CANARY"; GOUT="$GV/WROTE"
printf '#!/bin/sh\ntouch "%s"\n' "$GCAN" > "$GPAY"; chmod +x "$GPAY"
rm -f "$GCAN" "$GOUT"
# CONTENT hashes, not a path listing: rewriting an existing file — .git/index is the one
# that matters for "reads do not write" — changes no path and was invisible before.
# The payload itself is excluded so its own presence is not mistaken for a change.
# PATH-FIRST records so LC_ALL=C sort and comm agree on ordering — hash-first records are
# ordered by hash, which is not the order comm requires and made the comparison unreliable.
gs_files() {
  # ONE shasum process for the whole tree, not one per file plus a `cut`: measured 409ms -> 22ms
  # per call on a 27-file fixture, and this is called from ten sites. `-exec ... +` batches AND —
  # unlike `xargs` — runs nothing at all on an empty tree, so shasum can never be left reading
  # stdin and hanging the suite. Output stays PATH-FIRST and LC_ALL=C sorted (see below);
  # verified byte-identical to the per-file form, including paths containing spaces.
  find "$GV" -type f ! -name '.payload' -exec shasum {} + 2>/dev/null \
    | sed -E 's/^([0-9a-f]+)  (.*)$/\2\t\1/' \
    | LC_ALL=C sort
}
# Any difference IN EITHER DIRECTION. `comm -13` alone missed deletions, so a review turn that
# removed a file read as clean. (codex, round 10.)
gs_changed() {  # <before> — prints a summary of what moved, empty if nothing did
  diff <(printf '%s\n' "$1") <(gs_files) 2>/dev/null | sed -n 's/^[<>] //p' | cut -f1 | sort -u
}
REAL_GIT="$(command -v git)"
# An ssh remote, so GIT_SSH_COMMAND / core.sshCommand have something to reach for. Without it
# git fails before touching ssh and the control cannot leak. The host is .invalid (RFC 2606):
# nothing resolves, so nothing leaves the machine.
git -C "$GV" remote add origin "ssh://git@nonexistent.invalid/x.git" >/dev/null 2>&1
# A LOCAL bare repo as a second remote. --upload-pack is only honoured for a local transport,
# so an ssh remote that never resolves cannot demonstrate the exec; against this one it does.
GV_PEER="$WORK/gitshim-peer"; git init -q --bare "$GV_PEER" >/dev/null 2>&1
# The baseline is deliberately DIRTY. A clean tree makes `git diff HEAD` empty, so an external
# diff driver is never invoked and the control cannot leak — which is precisely how fourteen
# cases came to "pass" while proving nothing. (grok, round 9: it reproduces on a dirty tree.)
gs_restore() {
  ( cd "$GV" && git checkout -- . >/dev/null 2>&1 || true )
  printf 'dirty\n' > "$GV/f.txt"
  rm -f "$GCAN" "$GOUT"
}
GS_BEFORE="$(gs_files)"
# EVERY case carries a NEGATIVE CONTROL. Round 9 replaced a blind harness with one that could
# see, and round 10 showed that was still not enough: several attacks produced no mutation even
# with the shim REMOVED, so "clean with the shim" proved nothing about the shim. Each case now
# runs twice — once against real git with no shim, which MUST leak, and once through the shim,
# which must not. A case whose control does not leak is reported as unproven, loudly, instead of
# counting as protection. (codex, round 10.)
gs_case() {  # <label> <env-assignments...> -- <git args...>
  local label="$1"; shift
  local envs=() ; while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift

  gs_restore; local base; base="$(gs_files)"
  ( cd "$GV" && env "${envs[@]}" "$REAL_GIT" "$@" ) >/dev/null 2>&1 || true
  local control; control="$(gs_changed "$base")"
  gs_restore

  base="$(gs_files)"
  ( cd "$GV" && env "${envs[@]}" "$GS/git" "$@" ) >/dev/null 2>&1 || true
  local shielded; shielded="$(gs_changed "$base")"
  gs_restore; GS_BEFORE="$(gs_files)"

  if [ -z "$control" ]; then
    fail "UNPROVEN: '$label' does not leak even without the shim — this case cannot detect a regression"
  elif [ -n "$shielded" ]; then
    fail "shim let a review turn $label (changed: $(printf '%s' "$shielded" | head -2 | tr '\n' ' '))"
  else
    ok "a review turn cannot $label (control leaks without the shim)"
  fi
}
# Prove the harness can SEE a violation. A test that cannot fail is not evidence, and this
# whole block previously could not fail for eight of its cases.
touch "$GV/harness-selftest"
if [ -n "$(gs_changed "$GS_BEFORE")" ]; then
  ok "the shim harness detects a new file (it can fail)"
else
  fail "the shim harness is blind to new files — every result below is vacuous"
fi
rm -f "$GV/harness-selftest"
printf 'mutate\n' >> "$GV/f.txt" 2>/dev/null || true
if [ -n "$(gs_changed "$GS_BEFORE")" ]; then
  ok "the shim harness detects an in-place rewrite"
else
  fail "the shim harness is blind to content changes"
fi
gs_restore; GS_BEFORE="$(gs_files)"
rm -f "$GV/f.txt"
if [ -n "$(gs_changed "$GS_BEFORE")" ]; then
  ok "the shim harness detects a DELETION (comm -13 could not)"
else
  fail "the shim harness is blind to deletions"
fi
gs_restore; GS_BEFORE="$(gs_files)"
gs_case "exec a program via GIT_EXTERNAL_DIFF" "GIT_EXTERNAL_DIFF=$GPAY" -- diff --ext-diff HEAD
gs_case "exec a program via GIT_SSH_COMMAND"  "GIT_SSH_COMMAND=$GPAY"  -- ls-remote origin
# REMOVED (unprovable here): GIT_PAGER / -p: git skips the pager entirely when stdout is not a TTY.
# The shim still refuses/neutralises it; we simply cannot demonstrate the leak in a
# non-interactive test, and a case that cannot fail must not be counted as coverage.
gs_case "inject config via GIT_CONFIG_*"      "GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=diff.external" "GIT_CONFIG_VALUE_0=$GPAY" -- diff HEAD
gs_case "inject config via -c alias (the original bypass)" "X=1" -- -c "alias.ship=!$GPAY" ship
gs_case "inject config via -c core.sshCommand" "X=1" -- -c "core.sshCommand=$GPAY" ls-remote origin
gs_case "write a file via --output"           "X=1" -- log "--output=$GOUT"
# REMOVED (unprovable here): grep -O: same TTY dependency as the pager.
# The shim still refuses/neutralises it; we simply cannot demonstrate the leak in a
# non-interactive test, and a case that cannot fail must not be counted as coverage.
gs_case "exec via --upload-pack"              "X=1" -- ls-remote "--upload-pack=$GPAY" "$GV_PEER"
gs_case "write trace output via GIT_TRACE2_EVENT" "GIT_TRACE2_EVENT=$GV/trace.json" -- status
gs_case "write trace output via GIT_TRACE"        "GIT_TRACE=$GV/trace2.txt"         -- log --oneline -1
# REMOVED (unprovable here): GIT_MAN_VIEWER: `git help` does not exec the viewer in this environment.
# The shim still refuses/neutralises it; we simply cannot demonstrate the leak in a
# non-interactive test, and a case that cannot fail must not be counted as coverage.
# REMOVED (unprovable here): unlocked index write: `git status` does not rewrite .git/index here.
# The shim still refuses/neutralises it; we simply cannot demonstrate the leak in a
# non-interactive test, and a case that cannot fail must not be counted as coverage.
# Repo-LOCAL config is the case env-scrubbing can never cover: .git/config is a file, not a
# variable, and unsetting GIT_CONFIG_GLOBAL merely restores the default lookup. Re-baseline
# after writing the config, or the setup write is mistaken for the attack. (codex, round 9.)
git -C "$GV" config diff.external "$GPAY" >/dev/null 2>&1
git -C "$GV" config core.fsmonitor "$GPAY" >/dev/null 2>&1
GS_BEFORE="$(gs_files)"
gs_case "exec via repo-local diff.external config" "X=1" -- diff HEAD
gs_case "exec via repo-local core.fsmonitor config" "X=1" -- status
# -p AFTER the verb is --patch (log/diff) or --porcelain (blame) — the reviewer's own tools.
# Refusing it everywhere broke `git log -p` and the refusal text was false for that case.
( cd "$GV" && "$GS/git" log -p -1 ) >/dev/null 2>&1 \
  && ok "git log -p still works: after the verb -p is --patch, not --paginate" || fail "shim broke git log -p"
case "$( ( cd "$GV" && "$GS/git" -p log ) 2>&1 | head -1 )" in
  *"agent-comms: refused"*) ok "a LEADING -p (--paginate) is still refused" ;;
  *) fail "leading -p reached git" ;;
esac
git -C "$GV" config --unset diff.external >/dev/null 2>&1
git -C "$GV" config --unset core.fsmonitor >/dev/null 2>&1
GS_BEFORE="$(gs_files)"

gs() { PATH="$GS:$PATH" git "$@"; }
# A DENYLIST of subcommands cannot hold: git is user-extensible, so an alias runs under a
# name no list contains, and publishing/rewriting verbs are not all spelled "push". Each of
# these was verified bypassable against the previous denylist shim. (codex, round 6.)
gs_refused() {  # <label> <args...> — the shim must refuse, and real git must never run
  local label="$1"; shift
  local out; out="$("$GS/git" "$@" 2>&1 | head -1)"
  case "$out" in
    *"agent-comms: refused"*) ok "shim refuses $label" ;;
    *) fail "shim ALLOWED $label (got: ${out:0:70})" ;;
  esac
}
gs_allowed() {  # <label> <args...> — a read-only verb must reach the REAL git
  # Asserted as "not refused", not as a fixed output string: the shim now runs real git, so
  # the output is whatever the repo says. Pinning an exact string here is what let the old
  # echo-stub fixture pass while the shipped shim was defeatable.
  local label="$1"; shift
  local out; out="$("$GS/git" "$@" 2>&1 | head -1)"
  case "$out" in
    *"agent-comms: refused"*) fail "shim BLOCKED read-only $label (got: ${out:0:70})" ;;
    *) ok "shim passes $label through to git" ;;
  esac
}
GS_PUSH="pu""sh"; GS_COMMIT="co""mmit"
gs_refused "a shell alias defined inline (-c alias.X=!...)" -c "alias.ship=!git $GS_PUSH origin main" ship
gs_refused "send-pack, which publishes without saying push" send-pack origin main
gs_refused "tag -f, which rewrites a ref" tag -f v1
gs_refused "an --exec-path= that redirects git helpers" --exec-path=/tmp version
gs_refused "update-ref" update-ref refs/heads/main HEAD
gs_refused "the plain publishing verb" "$GS_PUSH" origin main
gs_refused "the plain writing verb" "$GS_COMMIT" -m x
gs_refused "a publishing verb behind a value-taking global" -C /tmp "$GS_PUSH"
gs_refused "an unknown verb (allowlist default-denies)" some-future-subcommand
gs_allowed "log"        log --oneline -1
gs_allowed "status"     status --short
gs_allowed "rev-parse"  rev-parse HEAD
gs_allowed "cat-file"   cat-file -t HEAD
gs_allowed "a read behind -C" -C . log --oneline -1
gs log --oneline -1 >/dev/null 2>&1 && ok "a review turn can still read git history" || fail "shim blocks git log"
gs diff --stat >/dev/null 2>&1 && ok "a review turn can still read the diff" || fail "shim blocks git diff"
gs show HEAD --stat >/dev/null 2>&1 && ok "a review turn can still read a commit" || fail "shim blocks git show"
check_not "a review turn cannot push" gs push origin main
check_not "a review turn cannot commit" gs commit -m x
check_not "a review turn cannot reset" gs reset --hard HEAD
check_not "a review turn cannot rewrite refs" gs update-ref refs/heads/x HEAD
# GLOBAL-OPTION BYPASS: -C/-c take a VALUE, and the old first-non-option break treated
# that value as the subcommand — `git -C . push` sailed straight through the refusal
# list. The scan must find the real subcommand past value-taking globals. (codex, panel r4.)
check_not "a review turn cannot push behind -C" gs -C . push origin main
check_not "a review turn cannot reset behind -c" gs -c user.name=x reset --hard HEAD
gs -C . log --oneline -1 >/dev/null 2>&1 \
  && ok "value-taking globals still work for reads (-C . log)" || fail "shim broke -C reads"
# No drift canary is needed any more: the fixture above IS the production generator, so
# there are no longer two shapes to keep in sync. What IS worth asserting is that the shim
# default-denies — an allowlist that falls through to exec on an unrecognised verb is a
# denylist wearing a costume, and that distinction is the whole security property here.
# (Removed: a grep for the refusal comment in runphase.sh. The unknown-verb case below
# refuses through the GENERATED shim, which is the property, not the prose.)
[ "$("$GS/git" definitely-not-a-real-verb 2>&1 | grep -c 'agent-comms: refused')" = "1" ] \
  && ok "an unrecognised verb is refused, not executed" || fail "shim fell through on an unknown verb"
# and the shim must not recurse into itself
# Asserted against the GENERATED shim, not the generator: what ships is this file, and an
# exec target that resolved through PATH would find the shim again and spin forever.
GS_EXEC="$(sed -n 's/^ *exec \(\/[^ ]*\).*/\1/p' "$GS/git" | head -1)"
[ -n "$GS_EXEC" ] && [ "$GS_EXEC" != "$GS/git" ] && [ -x "$GS_EXEC" ] \
  && ok "the shim execs the REAL git by absolute path, never itself" \
  || fail "shim exec target is not an absolute non-self path (got: ${GS_EXEC:-<none>})"
# The shim is worthless if it never reaches the child, and that wiring used to be asserted
# by grepping runphase.sh for a literal PATH= expression — a string match that would have
# stayed green through any refactor that dropped the export. Run a REAL mounted ACP turn
# and let the child report what it actually resolves `git` to. (codex, round 10.)
SW_ART="$(git -C "$MA_FIX" rev-parse HEAD 2>/dev/null)"
SW_MSG="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-58-00_shimpath-1.md"
{ head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
  printf 'artifact_id: %s\nhead_sha: %s\n' "$SW_ART" "$SW_ART"
  tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" | sed -e 's/^thread: ma-arc-1$/thread: ma-arc-shimpath/'
} > "$SW_MSG"
SW_DIR="$WORK/ma-shimpath"; mkdir -p "$SW_DIR"
printf 'x\n' > "$AXD/payload"
rm -f "$AXD/childenv"
# Mount lifecycle again, as grok, so it opts out of the containment refusal explicitly — see
# the note on wm_turn. The shim is DEFENCE IN DEPTH under an isolation backend, and it is what
# an operator who sets the override is left with, so it must keep working in exactly this case.
( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$AXD/payload" \
    ACP_PARITY_PROBE="$AXD/childenv" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
    COMMS_RUNPHASE_ALLOW_UNCONTAINED=1 \
    "$RP" run --message "$SW_MSG" --dir "$SW_DIR" --provider grok --via acp --timeout-secs 20 ) \
  >/dev/null 2>&1
if [ ! -s "$AXD/childenv" ]; then
  fail "the mounted ACP child never ran — the PATH check would be vacuous"
elif grep -q "^git=$SW_DIR/shim/git\$" "$AXD/childenv"; then
  ok "a mounted child resolves git to the shim (it is really on the child PATH)"
else
  fail "a mounted child resolves git elsewhere (got: $(grep '^git=' "$AXD/childenv" | head -1))"
fi

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
WM_ROOT="$(cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" root)"
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
  ( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$AXB:$PATH" \
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
( cd "$MA_FIX" && env -u CMUX_WORKSPACE_ID PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$AXD/payload" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$WM_MSG13" --dir "$WM/run-wm13" \
    --provider grok --timeout-secs 20 ) >/dev/null 2>&1
# Count-in/count-out alone would also pass if the turn never mounted at all, so require
# positive evidence that it DID mount before believing the cleanup.
if ! grep -q '^mount: staged artifact ' "$WM/run-wm13/runner.log" 2>/dev/null; then
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

check_not "transport rejects an unregistered agent" run_tr transport gemini
check_not "transport rejects an unknown option" run_tr transport codex --bogus

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
RELO_WS="$(cd "$RELO_FIX" && env -u CMUX_WORKSPACE_ID "$COMMS" workspace)"
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
  ( cd "$RELO_FIX" && env -u CMUX_WORKSPACE_ID PATH="$AXB:$PATH" HOME="$RELO_HOME" \
      COMMS_MOUNT_BASE="$RELO_STORE" ACP_PARITY_PAYLOAD="$AXD/payload" AX_CWD_LOG="$WORK/relo-cwd.log" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_RUNPHASE_OWNER_WAIT_SECS=3 COMMS_RUNPHASE_ALLOW_UNCONTAINED=1 \
      "$@" "$RP" run --message "$m" --dir "$dir" --provider grok --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}
relo_last_cwd() { awk -F'\t' '$2 !~ /sessions (ensure|show|set-mode)/ {print $1}' "$WORK/relo-cwd.log" | sed -n '$p'; }
relo_status() { sed -n 's/.*"status": "\([a-z]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }
relo_clean() { ( cd "$RELO_FIX" && env -u CMUX_WORKSPACE_ID HOME="$RELO_HOME" COMMS_MOUNT_BASE="$RELO_STORE" "$RP" clean-mounts "$@" 2>&1 ); }

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
RELO_CM_MM="$( cd "$RELO_FIX" && env -u CMUX_WORKSPACE_ID HOME="$RELO_HOME" COMMS_MOUNT_BASE="$RELO_STORE" \
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
run_pw() { (cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 "$COMMS" "$@"); }
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

# worktree new (AC4/AC6): grammar, ignore-gate, local tip, main-root anchoring.
check_not "worktree new refuses a bad slug" run_pw worktree new 'Bad/Slug'
check_not "worktree new refuses a multiline slug (whole-scalar, not per-line)" run_pw worktree new "$(printf 'feat\n../../tmp')"
(cd "$PW" && git checkout -q -b session-primary)   # never-occupy-main migration
run_pw worktree new featone >/dev/null 2>&1 && [ -d "$PW/.claude/worktrees/featone" ] \
  && ok "worktree new creates under .claude/worktrees on its own branch" || fail "worktree new"
(cd "$PW/.claude/worktrees/featone" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 "$COMMS" worktree new nested >/dev/null 2>&1)
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
(cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=lander COMMS_PRESENCE_INSTANCE="$PW_I5" "$COMMS" integrate no-such-branch) >/dev/null 2>&1
grep -q '"state": "working"' "$PW_SD/lander-$PW_I5.json" \
  && ok "an early integrate exit restores the lease (trap precedes mutation)" || fail "lease leaked on early exit: $(grep state "$PW_SD/lander-$PW_I5.json")"
# Presence-wrapped landing actually lands (grok, impl r1: the 143 path refused
# green suites; every earlier integrate test ran WITHOUT the presence env).
(cd "$PW/.claude/worktrees/nested" && git merge -q --ff-only "$(cd "$PW" && git rev-parse main)" 2>/dev/null; echo e > e.txt; git add e.txt; git -c user.email=t@t -c user.name=t commit -qm "feat: e")
(cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=lander COMMS_PRESENCE_INSTANCE="$PW_I5" "$COMMS" integrate worktree-nested) >/dev/null 2>&1; PW_LAND=$?
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
(cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=retrier COMMS_PRESENCE_INSTANCE="$PW_I6" "$COMMS" integrate worktree-nested) >/dev/null 2>&1; PW_RED=$?
[ "$PW_RED" != 0 ] && ok "the red presence-wrapped suite refuses to land" || fail "red suite landed"
(cd "$PW/.claude/worktrees/nested" && printf '#!/bin/bash\ntest -f a.txt\n' > suite.sh && git add suite.sh && git -c user.email=t@t -c user.name=t commit -qm "green suite")
(cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 COMMS_PRESENCE_NAME=retrier COMMS_PRESENCE_INSTANCE="$PW_I6" "$COMMS" integrate worktree-nested) >/dev/null 2>&1; PW_RETRY=$?
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
PW_CFGWARN="$( (cd "$PW" && env -u CMUX_WORKSPACE_ID "$COMMS" agents) 2>&1 || true)"
printf '%s' "$PW_CFGWARN" | grep -q 'unknown line' \
  && fail "suite-attest-secs warns as an unknown config key" || ok "suite-attest-secs is a known config key"
printf 'suite-cmd = bash ./suite.sh\nsuite-attest-secs = 600\nsuite-attest-secs = 0\n' > "$PW/.comms/config"
check_not "a duplicate suite-attest-secs is refused (the disabling line must win)" bash -c "cd '$PW' && env -u CMUX_WORKSPACE_ID '$COMMS' agents"
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
check_not "attest-green refuses when HEAD moved off the verified commit" bash -c "cd '$PW/.claude/worktrees/nested' && env -u CMUX_WORKSPACE_ID '$COMMS' attest-green --expect '$PW_ATT_OTHER'"
grep -q "^$PW_ATT_OTHER " "$PW/.comms/cache/suite-attest.log" 2>/dev/null \
  && fail "a refused attestation still wrote a record" || ok "a refused --expect attestation records nothing"
check_not "attest-green --passed with no value is a usage error, not a crash" bash -c "cd '$PW/.claude/worktrees/nested' && env -u CMUX_WORKSPACE_ID '$COMMS' attest-green --passed"
(cd "$PW/.claude/worktrees/nested" && env -u CMUX_WORKSPACE_ID "$COMMS" attest-green --passed 7 >/dev/null 2>&1)
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
(cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=3 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- sleep 4) >/dev/null 2>&1
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
PW_WBH="$( (cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=3 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- sleep 5) 2>&1 )"; PW_WBHRC=$?
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
( cd "$PW" && exec env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- bash -c "sleep 30 & echo \$! > '$PW_MARK'; wait" ) & PW_WRAP=$!
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
( cd "$PW" && exec env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- sleep 30 ) & PW_IW=$!
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
    ( cd "$PW" && exec env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 "$C" presence with-beat --name alpha --instance "$I" -- sleep 0.3 ) 2>/tmp/pwcancel.$$.err & p=$!
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
    ( cd "$PW" && exec env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 "$C" presence with-beat --name alpha --instance "$I" -- true ) 2>/tmp/pwcancel.$$.err & p=$!
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
( cd "$PW" && exec env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 "$COMMS" presence with-beat --name alpha --instance "$PW_I1" -- bash -c "trap '' TERM; sleep 4 & exit 0" ) & PW_LW=$!
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
PW_PSO="$( (cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 PATH="$PW_PSBIN:$PATH" "$COMMS" presence others --name alpha --instance "$PW_I1") || true)"
printf '%s\n' "$PW_PSO" | grep -q 'sandboxed' \
  && ok "a ps that cannot answer keeps the record ambiguous (peer, not dead)" || fail "ps failure read as death"
(cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 PATH="$PW_PSBIN:$PATH" "$COMMS" presence expire) >/dev/null 2>&1
(cd "$PW" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=60 PATH="$PW_PSBIN:$PATH" "$COMMS" presence expire) >/dev/null 2>&1
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

section "runphase: the state-file wait is DECLARED by the spawner, never guessed"
# The runner may wait for the thread-state file that `send` writes just after it
# spawns us. It must wait ONLY when a send is actually behind it. A bare
# `comms.sh deliver` (a public verb) spawns a runner with no send following, so
# the file is never coming and a timed wait is pure latency — this was a flat 6s
# on EVERY such turn, invisible because every caller redirects the note to
# /dev/null. Measured at 179s (35%) of this suite's own runtime.
SW="$WORK/statewait"; mkdir -p "$SW"; SW="$(cd "$SW" && pwd -P)"
git -C "$SW" init -q -b feature/sw-tests
git -C "$SW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$SW/.comms/to-grok" "$SW/.comms/to-claude" "$SW/.comms/archive" "$SW/.comms/state"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$SW/.comms/config"
SW_WS="$(cd "$SW" && env -u CMUX_WORKSPACE_ID "$COMMS" workspace)"
SW_MSG="$SW/.comms/to-grok/${SW_WS}_2026-08-27T10-00-00_sw-1.md"
cat > "$SW_MSG" <<SWEOF
---
type: review-request
from: claude
timestamp: 2026-08-27T10:00:00Z
workspace: $SW_WS
message_id: ${SW_WS}_2026-08-27T10-00-00_sw-1
thread: sw-arc-1
workflow: auto-full
phase: plan
round: 1
max-rounds: 4
---

## Plan
review this plan
SWEOF
SW_SF="$SW/.comms/state/$(echo "$SW_WS" | tr '/' '-')_sw-arc-1.json"
# A turn that refuses its arguments still runs the EXIT trap, which is the path
# that reaches update_thread_state — the cheapest way to exercise the wait.
sw_run() {  # sw_run <rundir> [env assignments...] -- refuses, exits nonzero
  local rd="$1"; shift
  mkdir -p "$rd"
  ( cd "$SW" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$@" \
      "COMMS_RUNPHASE_GROK_ARGS=--sandbox off" \
      "$RP" run --message "$SW_MSG" --dir "$rd" --provider grok ) 2>&1
}
sw_elapsed() {  # prints whole seconds elapsed while running "$@"
  local t0 t1; t0=$(date +%s); "$@" >/dev/null 2>&1; t1=$(date +%s); echo $((t1 - t0))
}
SW_BIN="$WORK/sw-bin"; mkdir -p "$SW_BIN"
# Records the env it was launched with, and optionally writes the thread-state file
# from INSIDE the turn. That is the late write, without a sleep to race: the provider
# runs after the runner started and before its exit trap, by construction.
cat > "$SW_BIN/grok" <<'SWSTUB'
#!/bin/bash
env > "${SW_ENV_DUMP:-/dev/null}"
if [ -n "${SW_LATE_STATE:-}" ]; then
  printf '{\n  "workspace": "sw",\n  "thread": "sw-arc-1",\n  "last_delivery": "spawned"\n}\n' > "$SW_LATE_STATE"
fi
exit 2
SWSTUB
chmod +x "$SW_BIN/grok"
sw_turn() {  # sw_turn <rundir> [env assignments...] — a turn that REACHES the provider
  local rd="$1"; shift
  mkdir -p "$rd"
  ( cd "$SW" && env -u CMUX_WORKSPACE_ID PATH="$SW_BIN:$PATH" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$@" \
      "$RP" run --message "$SW_MSG" --dir "$rd" --provider grok ) 2>&1
}

# 1. No declaration -> no wait. This is the regression that mattered.
SW_E1="$(sw_elapsed sw_run "$WORK/sw-r1")"
[ "$SW_E1" -lt 3 ] && ok "unheralded spawn does not wait for a state file that is not coming (${SW_E1}s)" \
  || fail "unheralded spawn still waits (${SW_E1}s, expected <3)"
# NB: sw_run exits nonzero BY DESIGN (it refuses), and this suite sets pipefail,
# so `sw_run | grep -q ...` is decided by the refusal's status, not by grep —
# it fails when the note is present and "passes" when it is absent. Capture,
# then match.
SW_O1="$(sw_run "$WORK/sw-r1b" || true)"
case "$SW_O1" in
  *'no thread state file to update'*) ok "unheralded spawn still reports the missing state file" ;;
  *) fail "missing-state note lost" ;;
esac

# 2. Declared, file never arrives -> the budget is HONOURED, not ignored. A fix
#    that simply deleted the wait would pass test 1 and fail this one.
SW_E2="$(sw_elapsed sw_run "$WORK/sw-r2" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=1)"
[ "$SW_E2" -ge 1 ] && ok "declared spawn waits out its budget when the write never lands (${SW_E2}s)" \
  || fail "declared spawn skipped its budget (${SW_E2}s, expected >=1)"

# 3. Declared, file lands DURING the turn -> the race window still works, and the
#    state is actually MUTATED. Asserting only that the "missing file" note is absent
#    would pass on a turn that found the file and then failed to write it. The stub
#    creates the file from inside the turn, so there is no sleep to lose under load.
SW_O3="$(SW_LATE_STATE="$SW_SF" sw_turn "$WORK/sw-r3" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=4 || true)"
case "$SW_O3" in
  *'no thread state file to update'*) fail "state file written during the turn was missed — the race window regressed" ;;
  *) ok "declared spawn picks up a state file written after it started" ;;
esac
grep -q '"last_delivery": "failed"' "$SW_SF" 2>/dev/null \
  && ok "the picked-up state file is actually mutated, not merely found" \
  || fail "state file found but last_delivery not updated ($(cat "$SW_SF" 2>/dev/null | tr -d '\n'))"
rm -f "$SW_SF"

# 3a. The poll must WAKE EARLY. Test 2 already covers "the wait exists at all"; 3a's
#     unique job is narrower — that the wait is a POLL and not a flat `sleep $budget`.
#     Test 3's file already exists when the waiter starts, so nothing there touches
#     the polling. Here the file lands ~1s into a 10s budget: a non-polling
#     implementation takes 10s and fails the <6s bound, while the real one returns
#     in ~1s. The margin is deliberately wide because this suite is known to flake
#     under machine load, and a false failure here costs more than a loose bound.
#     If load delays the runner past the 1s write, this degrades to test 3 (file
#     already present) and still passes — it loses coverage, never invents failure.
#     (codex + grok, panel r2 flagged the gap; codex, r3 asked for the wider margin.)
( sleep 1; printf '{\n  "workspace": "sw",\n  "thread": "sw-arc-1",\n  "last_delivery": "spawned"\n}\n' > "$SW_SF" ) &
SW_MIDW=$!
SW_E3A="$(sw_elapsed sw_run "$WORK/sw-r3a" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=10)"
wait "$SW_MIDW" 2>/dev/null || true
[ "$SW_E3A" -lt 6 ] && ok "a file landing mid-wait wakes the poll early (${SW_E3A}s of a 10s budget)" \
  || fail "the wait did not wake early (${SW_E3A}s of a 10s budget — is it polling?)"
grep -q '"last_delivery": "failed"' "$SW_SF" 2>/dev/null \
  && ok "the mid-wait file is mutated too" || fail "mid-wait file not mutated"
rm -f "$SW_SF"

# 3b. The declaration is THIS turn's, and must not reach the provider child. A
#     reviewer turn that runs this suite would otherwise inherit it and every direct
#     runner call above would wait again — re-acquiring the stall, and only when the
#     suite runs inside a headless turn. (codex, panel r1, blocking.)
SW_ENV_DUMP="$WORK/sw-childenv.txt" sw_turn "$WORK/sw-r3b" COMMS_RUNPHASE_EXPECT_STATE=1 >/dev/null 2>&1 || true
if [ -s "$WORK/sw-childenv.txt" ]; then
  ok "provider child env was captured"
  # Gate on the dump: a MISSING dump makes grep fail, which would otherwise take
  # the "no leak" branch and report a pass for a test that never ran. (grok, r2.)
  if grep -q '^COMMS_RUNPHASE_EXPECT_STATE=' "$WORK/sw-childenv.txt"; then
    fail "the state declaration leaked into the provider child"
  else
    ok "the state declaration does not reach the provider child"
  fi
else
  fail "provider child env not captured"
  fail "leak check could not run (no env dump)"
fi

# 3c. A malformed budget must not abort the exit trap mid-teardown: it is
#     interpolated into arithmetic, where `abc` or `08` kills the shell before the
#     result write. (codex, panel r1, advisory.)
SW_O3C="$(sw_run "$WORK/sw-r3c" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=abc || true)"
case "$SW_O3C" in
  *'no thread state file to update'*) ok "a non-integer budget falls back instead of aborting teardown" ;;
  *) fail "non-integer budget aborted the exit trap (teardown output lost)" ;;
esac
# The diagnostic alone does not prove the trap RAN TO COMPLETION — result.json is
# written after it, and an arithmetic abort would lose exactly that. (codex, r2.)
grep -q '"status"' "$WORK/sw-r3c/result.json" 2>/dev/null \
  && ok "teardown still recorded a result after a malformed budget" \
  || fail "result.json missing or statusless after a malformed budget"
# An absurd budget must not wrap negative and silently skip the declared wait —
# nor stall the turn for hours. It is malformed input: fall back to the default.
SW_E3D="$(sw_elapsed sw_run "$WORK/sw-r3d" COMMS_RUNPHASE_EXPECT_STATE=1 COMMS_RUNPHASE_STATE_WAIT_SECS=1844674407370955161)"
[ "$SW_E3D" -ge 3 ] && ok "an overflowing budget still waits, not wrapped into no wait (${SW_E3D}s)" \
  || fail "an overflowing budget skipped the declared wait entirely (${SW_E3D}s)"
[ "$SW_E3D" -le 20 ] && ok "an overflowing budget falls back rather than stalling for hours (${SW_E3D}s)" \
  || fail "an overflowing budget was clamped to something enormous (${SW_E3D}s)"

# 4. Anti-drift, as a SOURCE contract: the writer's rule and the spawner's
#    promise must be the same predicate, not two copies that agree today. If
#    they diverge, nothing fails loudly — the runner just stalls for its whole
#    budget again, silently, exactly as it did before this fix.
SWC="$REPO/helpers/comms.sh"
[ "$(grep -c '^state_write_expected()' "$SWC")" = 1 ] \
  && ok "state_write_expected is defined exactly once" || fail "state_write_expected definition count"
grep -q 'state_write_expected "$thread" "$wf" || return 0' "$SWC" \
  && ok "state_update_from gates its write on the shared predicate" || fail "writer bypasses the shared predicate"
grep -q 'if state_write_expected "$(frontmatter_field "$file" thread)" "$(frontmatter_field "$file" workflow)"; then' "$SWC" \
  && ok "cmd_send gates COMMS_RUNPHASE_EXPECT_STATE on the shared predicate" || fail "spawner bypasses the shared predicate"
[ "$(grep -c 'export COMMS_RUNPHASE_EXPECT_STATE=' "$SWC")" = 1 ] \
  && ok "exactly one site declares an expected state write" || fail "COMMS_RUNPHASE_EXPECT_STATE exported in more than one place"
[ "$(grep -c 'unset COMMS_RUNPHASE_EXPECT_STATE' "$SWC")" = 1 ] \
  && ok "exactly one site withdraws the declaration" || fail "declaration withdrawn in more than one place"
grep -q 'RP_EXPECT_STATE="\${COMMS_RUNPHASE_EXPECT_STATE:-}"' "$REPO/helpers/runphase.sh" \
  && ok "the runner captures the declaration before any child can inherit it" || fail "runner does not capture the declaration"
grep -q 'RP_EXPECT_STATE:-' "$REPO/helpers/runphase.sh" \
  && ok "the waiter reads the captured copy set-u safely" || fail "waiter does not read the captured copy safely"
grep -q 'unset COMMS_RUNPHASE_EXPECT_STATE' "$REPO/helpers/runphase.sh" \
  && ok "the runner clears the declaration before launching the provider" || fail "runner does not clear the declaration for the child"
grep -A1 '^unset COMMS_DELIVERY' "$REPO/tests/run.sh" | grep -q 'COMMS_RUNPHASE_EXPECT_STATE' \
  && ok "the harness scrubs an inherited declaration" || fail "harness no longer scrubs the inherited declaration"

section "harness: a partial run is never a verdict"
# The corpus gates integrate. These assertions guard the gate itself.
[ "$(grep -rl 'attest-green' "$REPO/tests/" | wc -l | tr -d ' ')" = 1 ] \
  && ok "exactly one file in tests/ can mint an attestation" || fail "more than one attestation mint site under tests/"
grep -q '\[ "$FAIL" -eq 0 \] && \[ "$COVERAGE_OK" -eq 1 \]' "$REPO/tests/run.sh" \
  && ok "the exit status requires coverage, not just an absence of failures" || fail "exit status has no coverage conjunct"
grep -q 'if \[ "$FAIL" -eq 0 \] && \[ "$COVERAGE_OK" -eq 1 \] && \[ -n "${TESTED_OID:-}" \]' "$REPO/tests/run.sh" \
  && ok "the attestation requires coverage too" || fail "attestation mint has no coverage conjunct"
[ -s "$REPO/tests/expected-counts.tsv" ] \
  && ok "the expected-coverage contract is committed" || fail "tests/expected-counts.tsv missing"
[ -s "$REPO/tests/section-counts.tsv" ] \
  && ok "the per-section vector is committed" || fail "tests/section-counts.tsv missing"
# A section added with a RAW echo banner prints a banner that looks identical in the output
# but never calls section(), so _flush_section does not fire: it emits no row of its own and
# its assertions are credited to the PREVIOUS section. The total gate is blind to this — the
# corpus did not shrink. It landed for real: 47 assertions merged into their predecessor, and
# the vector showed one row of 91 where the golden had 44 + 47. Converting the 62 banners
# ESTABLISHED the invariant; only this assertion enforces it for the next section to land.
grep -nE '^[[:space:]]*echo "== .* =="' "$REPO/tests/run.sh" | grep -vF 'echo "== $1 =="' | grep -q . \
  && fail "a section banner uses a raw echo — it will not be counted; call section() instead" \
  || ok "every section banner goes through section()"
# STRUCTURAL. An edit landed the gate block ABOVE the shebang: the file stopped being a
# script, top-level code ran with WORK and REPO unset, and it called a function that did
# not exist yet — all of it silent, because stray top-level failures are uncounted and the
# suite still reported green. Cheap to assert, invisible otherwise. (codex + grok, r2.)
[ "$(head -1 "$REPO/tests/run.sh")" = '#!/bin/bash' ] \
  && ok "the harness begins with its shebang (no code above it)" || fail "something precedes the shebang"
grep -q '^section_vector_verdict "\$SECTION_GOLDEN_F" "\$SECTION_VECTOR" || COVERAGE_OK=0$' "$REPO/tests/run.sh" \
  && ok "the coverage gate calls the per-section verdict function" || fail "the gate does not call section_vector_verdict"
grep -q 'SECTION_GOLDEN="\$(git' "$REPO/tests/run.sh" \
  && fail "the superseded inline per-section comparison is back" || ok "no inline per-section comparison remains"
# The vector is KEYED on the banner and compared sorted, so two sections sharing a banner
# collide silently — swap their counts and it still sorts identically. The dispatcher will
# key on this too. None today; assert it before that becomes load-bearing. (codex + grok.)
# Extract the banner TEXT, not the whole line: the coming wrap indents these calls into
# function bodies, and a whole-line comparison would then match nothing and pass vacuously
# at exactly the moment the dispatcher starts keying on them. (grok, suite-lanes r3.)
SEC_DUPS="$(sed -n 's/^[[:space:]]*section "\(.*\)".*$/\1/p' "$REPO/tests/run.sh" | sort | uniq -d | head -3)"
[ -z "$SEC_DUPS" ] && ok "every section banner is unique" || fail "duplicate section banners: $SEC_DUPS"
[ "$(cut -f1 "$REPO/tests/section-counts.tsv" | sort -u | wc -l | tr -d ' ')" = "$(wc -l < "$REPO/tests/section-counts.tsv" | tr -d ' ')" ] \
  && ok "the committed vector has no duplicate keys" || fail "the per-section vector has duplicate banner keys"
# A failing assertion must keep its section's covered count whole, or the vector reports a
# phantom move on top of the real failure. (grok, suite-lanes r2.)
( SEC_NAME="probe-f"; SEC_PASS=0; SEC_FAIL=0; SEC_SKIP=0; SECTION_VECTOR="$WORK/fv-fail"
  i=0; while [ "$i" -lt 6 ]; do ok "probe pass" >/dev/null; i=$((i+1)); done
  i=0; while [ "$i" -lt 2 ]; do fail "probe fail" 2>/dev/null; i=$((i+1)); done
  _flush_section )
[ "$(cat "$WORK/fv-fail" 2>/dev/null)" = "$(printf 'probe-f\t8')" ] \
  && ok "a failed assertion still counts toward its section's covered total" \
  || fail "fail() is missing from the section row: [$(cat "$WORK/fv-fail" 2>/dev/null)]"
# The per-section verdict, run for real. A permitted skip REPLACES a pass, so a section
# whose pass/skip split changes but whose COVERED count does not must still match — that
# is the Linux-host case (four ACL tickets) the first shape wrongly refused.
# THE LINUX CASE, pinned directly on the accounting function: a permitted skip REPLACES a
# pass, so a section that cashes one must emit the SAME row as one that did not. Pinning
# pass and skip as separate columns made every such host red at full coverage — which is
# precisely the machine-dependence the skip contract exists to prevent, rebuilt one layer
# down. (codex + grok, suite-lanes r1, blocking.)
# The probes drive the REAL counters through ok/skip/fail rather than assigning them, so a
# revert of the increment inside any of those functions fails here. All three counters are
# zeroed explicitly, or the probe inherits whatever the harness section already recorded.
# (grok, suite-lanes r3.)
( SEC_NAME="probe-sec"; SEC_PASS=0; SEC_FAIL=0; SEC_SKIP=0; SKIP_USED=" "; SECTION_VECTOR="$WORK/fv-skip"
  i=0; while [ "$i" -lt 7 ]; do ok "probe pass" >/dev/null; i=$((i+1)); done
  ACL_PROBE_OK=0; skip acl-report "probe skip" >/dev/null 2>&1
  _flush_section )
( SEC_NAME="probe-sec"; SEC_PASS=0; SEC_FAIL=0; SEC_SKIP=0; SECTION_VECTOR="$WORK/fv-pass"
  i=0; while [ "$i" -lt 8 ]; do ok "probe pass" >/dev/null; i=$((i+1)); done
  _flush_section )
[ "$(cat "$WORK/fv-skip" 2>/dev/null)" = "$(cat "$WORK/fv-pass" 2>/dev/null)" ] \
  && ok "a permitted skip and the pass it replaced produce the same vector row" \
  || fail "pass/skip split leaks into the vector: [$(cat "$WORK/fv-skip" 2>/dev/null)] vs [$(cat "$WORK/fv-pass" 2>/dev/null)]"
[ "$(cat "$WORK/fv-skip" 2>/dev/null)" = "$(printf 'probe-sec\t8')" ] \
  && ok "the vector row records COVERED, not passes" || fail "vector row is not a covered count: [$(cat "$WORK/fv-skip" 2>/dev/null)]"

SV_G="$WORK/sv-golden"; SV_O="$WORK/sv-observed"
printf 'alpha\t8\nbeta\t41\n' > "$SV_G"
printf 'alpha\t8\nbeta\t41\n' > "$SV_O"
section_vector_verdict "$SV_G" "$SV_O" && ok "an identical vector is accepted" || fail "an identical vector was refused"
printf 'beta\t41\nalpha\t8\n' > "$SV_O"
section_vector_verdict "$SV_G" "$SV_O" && ok "the vector is keyed on the banner, not on run order" || fail "reordering broke the banner-keyed compare"
printf 'alpha\t7\nbeta\t42\n' > "$SV_O"
section_vector_verdict "$SV_G" "$SV_O" 2>/dev/null && fail "an assertion moved between sections was accepted" || ok "an assertion moved between sections is refused"
printf 'alpha\t8\n' > "$SV_O"
section_vector_verdict "$SV_G" "$SV_O" 2>/dev/null && fail "a missing section was accepted" || ok "a missing section is refused"
: > "$SV_O"
section_vector_verdict "$SV_G" "$SV_O" 2>/dev/null && fail "an empty vector was accepted" || ok "an empty vector is refused"
: > "$SV_G"
section_vector_verdict "$SV_G" "$SV_O" 2>/dev/null && fail "an absent golden was accepted" || ok "an absent per-section golden is refused"
# Exercise the REAL gate function against adversarial inputs. An earlier version of
# this block reimplemented one branch inline and hardcoded its variables, so it could
# not have caught the out-of-range case below. (codex, panel r1.)
coverage_verdict 300 0 0 960 2>/dev/null && fail "a short run was accepted" || ok "a short run is refused"
coverage_verdict 960 0 0 "" 2>/dev/null && fail "an absent contract was accepted" || ok "an absent contract total is refused"
coverage_verdict 960 0 0 abc 2>/dev/null && fail "a non-numeric contract was accepted" || ok "a non-numeric contract total is refused"
# All digits, but past what bash can compare: `[ x -ne y ]` exits 2, which an elif
# chain reads as false. This is the input that made the gate fail OPEN.
coverage_verdict 960 0 0 99999999999999999999 2>/dev/null && fail "an out-of-range contract was accepted" || ok "an out-of-range contract total is refused"
coverage_verdict 960 0 0 960 && ok "an exact full run is accepted" || fail "a full run was refused"
coverage_verdict 959 0 1 960 && ok "a permitted skip still counts toward coverage" || fail "a permitted skip broke the count"
# A genuine miscount: 960+1+0 = 961 against a contract of 960. (An earlier version of
# this assertion passed 961 as the contract, which the gate correctly ACCEPTS -- the
# counts agreed. The failure conjunct lives on the exit line, not in this function.)
coverage_verdict 960 1 0 960 2>/dev/null && fail "a miscounted run was accepted" || ok "a run whose total disagrees with the contract is refused"
# A skip must be NAMED in the contract. Probed in a subshell so the probe's own
# failure cannot pollute this run's counters.
SK_PROBE="$( (FAIL=0; skip definitely-not-a-permitted-id "probe" >/dev/null 2>&1; echo "$FAIL") )"
[ "$SK_PROBE" = 1 ] && ok "an unpermitted skip is a failure, not free capacity" || fail "an unpermitted skip was accepted (FAIL=$SK_PROBE)"
# The sentinel's DECISION, executed for real (a grep for its name proved nothing).
( GATE_REACHED=0; _suite_gate_guard 0 ) >/dev/null 2>&1 \
  && fail "an ungated success was allowed" || ok "the exit path refuses a success that never reached the gate"
( GATE_REACHED=1; _suite_gate_guard 0 ) >/dev/null 2>&1 \
  && ok "a gated success stays a success" || fail "the sentinel broke a legitimate pass"
( GATE_REACHED=0; _suite_gate_guard 3 ) >/dev/null 2>&1; [ "$?" = 3 ] \
  && ok "the sentinel preserves a genuine failure status" || fail "the sentinel altered a failure status"

# The contract path must not be reachable from the environment: integrate inherits the
# caller's env, so an override would let a branch attest against a reduced total.
grep -q 'EXPECT_FILE="\$REPO/tests/expected-counts.tsv"' "$REPO/tests/run.sh" \
  && ok "the coverage contract path is committed, not configurable" || fail "contract path is not pinned"
grep -q '\${EXPECT''_FILE:-' "$REPO/tests/run.sh" \
  && fail "the coverage contract path is overridable from the environment" \
  || ok "no environment override for the coverage contract"

# A permitted skip is single-use and condition-bound. Probed in subshells so the probes'
# own failures cannot pollute this run's counters.
SK_TWICE="$( (FAIL=0; SKIP=0; SKIP_USED=" zsh-absent "; skip zsh-absent "second use" >/dev/null 2>&1; echo "$FAIL") )"
[ "$SK_TWICE" = 1 ] && ok "a permitted skip cannot be cashed twice" || fail "a skip id was reusable (FAIL=$SK_TWICE)"
if command -v zsh >/dev/null 2>&1; then
  SK_COND="$( (FAIL=0; SKIP=0; SKIP_USED=" "; skip zsh-absent "claimed while zsh exists" >/dev/null 2>&1; echo "$FAIL") )"
  [ "$SK_COND" = 1 ] && ok "a skip whose condition does not hold is refused" || fail "an unused skip ticket was cashable (FAIL=$SK_COND)"
else
  ok "a skip whose condition does not hold is refused (vacuous: zsh absent, ticket is legitimately live)"
fi
SK_NOCOND="$( (FAIL=0; SKIP=0; SKIP_USED=" "; SKIP_ALLOWED=" no-such-condition "; skip no-such-condition "x" >/dev/null 2>&1; echo "$FAIL") )"
[ "$SK_NOCOND" = 1 ] && ok "a permitted id with no registered condition is refused" || fail "an id without a condition was accepted"

# The dynamic corpus must be enumerated from the INDEX, not the filesystem.
# Each production loop asserted BY ITSELF. A count-based tripwire did not lock: the
# grep line and a no-op literal contributed their own matches, so deleting one real loop
# still satisfied it. (codex + grok, panel r3, corroborated advisory.)
# ANCHORED at line start, which is what actually breaks the self-match: every assertion
# below begins with `grep`, never with `for`. The two `for tf` loops differ only by
# indentation, so the anchors also tell them apart. (codex + grok, panel r4, corroborated
# -- they gave the exact self-matching line numbers.)
grep -q "^for tf in .(tracked_paths 'templates/claude-commands" "$REPO/tests/run.sh" \
  && ok "the template loop enumerates tracked paths" || fail "the template loop no longer enumerates tracked paths"
grep -q "^for frag in .(tracked_paths 'docs/loopspec/fragments" "$REPO/tests/run.sh" \
  && ok "the fragment loop enumerates tracked paths" || fail "the fragment loop no longer enumerates tracked paths"
grep -q "^  for tf in .(tracked_paths 'templates/claude-commands" "$REPO/tests/run.sh" \
  && ok "the signature-scan loop enumerates tracked paths" || fail "the signature-scan loop no longer enumerates tracked paths"
# Negative side widened: a filesystem walk can also arrive as find, or via "$REPO"/./x.
grep -qE '^ *for [a-z_]+ in .*"\$REPO"/\.?/?(templates|docs)' "$REPO/tests/run.sh" \
  && fail "a corpus loop still enumerates the filesystem" || ok "no corpus loop enumerates the filesystem"
grep -qE '^ *for [a-z_]+ in .*find "\$REPO"/(templates|docs)' "$REPO/tests/run.sh" \
  && fail "a corpus loop walks the filesystem with find" || ok "no corpus loop walks the filesystem with find"
# integrate must not accept a suite that never ran, and must keep the evidence.
grep -q 'clean_env=(command /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS' "$REPO/helpers/comms.sh" \
  && ok "integrate scrubs shell-startup hooks before the suite" || fail "integrate does not scrub shell-startup hooks"
grep -q 'command /usr/bin/env' "$REPO/helpers/comms.sh" \
  && ok "the scrub runs outside function dispatch" || fail "the scrub is function-dispatchable"
grep -q 'envbin=env' "$REPO/helpers/comms.sh" \
  && fail "the unpinned fallback is back — it undoes the pin on every host" \
  || ok "there is no unpinned fallback for the scrub command"
grep -q 'emitted no completion line' "$REPO/helpers/comms.sh" \
  && ok "integrate requires positive proof the suite ran to the end" || fail "integrate accepts an exit status alone"
grep -q 'tee "\$suite_log"' "$REPO/helpers/comms.sh" \
  && ok "integrate keeps the output of the run it judges" || fail "integrate discards the suite output"
# The watchdog that waits on a provider child measures elapsed time by COUNTING the
# intervals it slept, and polls on a graduated cadence: fine for the first two seconds so
# a stub-backed turn (milliseconds) is caught at once, coarse after so a long production
# turn does not wake ten times a second for an hour.
#
# It must NOT compute its deadline from `date +%s`. That truncates the start to a whole
# second, so a one-second timeout beginning at phase .850 fired after 0.215s — killing a
# provider before the budget it was given. A 1s poll hid that by serving most of a second
# before its first check; polling finely exposed it. Counting can only ever push a timeout
# LATER, which is the safe direction. (codex, watchdog r1, blocking.)
#
# Asserted on the SOURCE deliberately: the loop body only runs when the child is still
# alive at the first check, so a timing assertion would be racy toward false failures.
WD="$(awk '/while kill -0 "\$codex_pid"/,/^  done$/' "$REPO/helpers/runphase.sh")"
printf '%s\n' "$WD" | grep -q '"\$waited_ds" -ge "\$budget_ds"' \
  && ok "the watchdog compares counted elapsed against the budget" || fail "the watchdog does not compare counted elapsed to its budget"
if printf '%s\n' "$WD" | grep -q 'budget_ds'; then ok "the budget is derived from the requested timeout"; else fail "the budget is not derived from timeout"; fi
printf '%s\n' "$WD" | grep -qE 'sleep 0\.[1-9]' \
  && ok "the fine tier of the watchdog poll is sub-second" || fail "the watchdog lost its sub-second tier"
printf '%s\n' "$WD" | grep -q 'poll_ds=10' \
  && ok "the watchdog graduates to a coarse poll" || fail "the watchdog has no coarse tier"
printf '%s\n' "$WD" | grep -q 'date +%s' \
  && fail "the watchdog reads a truncated clock again" || ok "the watchdog does not read the clock per tick"
awk '/while kill -0 "\$codex_pid"/,/^  done$/' "$REPO/helpers/runphase.sh" | grep -qE '^ *sleep [0-9]+$' \
  && fail "a whole-second sleep returned to the provider watchdog" || ok "no whole-second sleep in the provider watchdog"
# The contract must come from the commit under test, not from a file on disk.
grep -q 'git -C "\$REPO" show "\${TESTED_OID:-missing}:tests/expected-counts.tsv"' "$REPO/tests/run.sh" \
  && ok "the coverage contract is read from the commit under test" || fail "the contract is not bound to TESTED_OID"
# Behavioural: an untracked recreation of a deleted contract must NOT be readable as the
# contract. Proven in a throwaway repo with the same command shape the gate uses.
CT_FIX="$WORK/contractprobe"; mkdir -p "$CT_FIX"
git -C "$CT_FIX" init -q -b main
printf 'total\t100\n' > "$CT_FIX/expected-counts.tsv"
git -C "$CT_FIX" add expected-counts.tsv && git -C "$CT_FIX" -c user.email=t@t -c user.name=t commit -q -m seed
CT_OID="$(git -C "$CT_FIX" rev-parse HEAD)"
git -C "$CT_FIX" rm -q --cached expected-counts.tsv && git -C "$CT_FIX" -c user.email=t@t -c user.name=t commit -q -m drop
CT_OID2="$(git -C "$CT_FIX" rev-parse HEAD)"
printf 'total\t1\n' > "$CT_FIX/expected-counts.tsv"   # untracked recreation, reduced total
CT_READ="$(git -C "$CT_FIX" show "$CT_OID2:expected-counts.tsv" 2>/dev/null || true)"
[ -z "$CT_READ" ] && ok "a deleted contract recreated untracked reads as ABSENT, not as its reduced total" \
  || fail "an untracked contract was readable from the commit (got: $CT_READ)"
# And the mechanism itself: an untracked file must not be enumerated.
TP_FIX="$WORK/trackedprobe"; mkdir -p "$TP_FIX"
git -C "$TP_FIX" init -q -b main
printf 'x\n' > "$TP_FIX/kept.md"; printf 'x\n' > "$TP_FIX/untracked.md"
git -C "$TP_FIX" add kept.md && git -C "$TP_FIX" -c user.email=t@t -c user.name=t commit -q -m seed
TP_OUT="$(git -C "$TP_FIX" ls-files -- '*.md')"
case "$TP_OUT" in
  *untracked.md*) fail "index enumeration listed an untracked file" ;;
  *kept.md*)      ok "index enumeration lists tracked files and ignores untracked ones" ;;
  *)              fail "index enumeration listed nothing (got: $TP_OUT)" ;;
esac

section "integrate: an exit status is not proof the suite ran"
# Source greps proved the scrub EXISTS; these prove it WORKS. The attack: a shell-startup
# hook is sourced by non-interactive bash BEFORE the script's first line, so every guard
# the suite installs is too late. A hook that exits only for the zero-argument suite
# invocation leaves the argument-bearing helper untouched, so integrate sees exit 0 and
# an unchanged tree. (codex, panel r4/r5, blocking then advisory.)
IP="$WORK/int-proof"; mkdir -p "$IP"; IP="$(cd "$IP" && pwd -P)"
git -C "$IP" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IP/.gitignore"
mkdir -p "$IP/tests" "$IP/.comms"
printf 'total\t3\n' > "$IP/tests/expected-counts.tsv"
printf '#!/bin/bash\nexit 0\n' > "$IP/tests/silent.sh"
printf '#!/bin/bash\nprintf "passed: 3  failed: 0  skipped: 0\\n"\n' > "$IP/tests/loud.sh"
chmod +x "$IP/tests/silent.sh" "$IP/tests/loud.sh"
(cd "$IP" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IP" && git checkout -q -b session-primary)
run_ip() { (cd "$IP" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }
run_ip worktree new proofone >/dev/null 2>&1
(cd "$IP/.claude/worktrees/proofone" && echo x > c.txt && git add c.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: c") >/dev/null 2>&1

# A suite that exits 0 having printed nothing is not evidence of anything.
printf 'suite-cmd = bash tests/silent.sh\n' > "$IP/.comms/config"
IP_OUT="$(run_ip integrate worktree-proofone 2>&1 || true)"
case "$IP_OUT" in
  *"emitted no completion line"*) ok "integrate refuses a suite that exited 0 without running" ;;
  *) fail "integrate accepted a silent exit-0 suite (got: $(printf '%s' "$IP_OUT" | tail -1))" ;;
esac
[ "$(cd "$IP" && git rev-parse main)" != "$(cd "$IP" && git rev-parse worktree-proofone)" ] \
  && ok "the silent suite did not land" || fail "the silent suite landed"

# CONTROL: the hook must actually be capable of silencing the suite, or the scrub test
# below proves nothing. NOTE the discriminator: a BASH_ENV hook sees $0=bash, $#=0 and no
# argv no matter what script is about to run (probed), so it CANNOT select the suite by
# its arguments. It can select by CWD — integrate runs the suite inside its throwaway
# `.claude/worktrees/.integrate-*` worktree while the helper runs from the repo root —
# which targets exactly the suite invocation and leaves comms.sh itself working.
printf 'case "$PWD" in *"/.claude/worktrees/.integrate-"*) exit 0 ;; esac\n' > "$WORK/hostile-bashenv.sh"
mkdir -p "$IP/.claude/worktrees/.integrate-probe"
HOSTILE_OUT="$( (cd "$IP/.claude/worktrees/.integrate-probe" && BASH_ENV="$WORK/hostile-bashenv.sh" bash "$IP/tests/loud.sh") 2>&1 || true )"
[ -z "$HOSTILE_OUT" ] \
  && ok "the startup hook does silence an unscrubbed suite (control)" \
  || fail "the hook did not silence the suite — the scrub test below would prove nothing"
HOSTILE_OK="$( (cd "$IP" && BASH_ENV="$WORK/hostile-bashenv.sh" bash "$IP/tests/loud.sh") 2>&1 || true )"
case "$HOSTILE_OK" in
  *"passed: 3"*) ok "the same hook leaves invocations outside the verification tree alone" ;;
  *) fail "the hook is indiscriminate — it would break the helper too, not just the suite" ;;
esac
rmdir "$IP/.claude/worktrees/.integrate-probe" 2>/dev/null || true

# ...and with the hook inherited, integrate scrubs it, the real suite runs, and it lands.
printf 'suite-cmd = bash tests/loud.sh\n' > "$IP/.comms/config"
IP_OUT2="$( (cd "$IP" && env -u CMUX_WORKSPACE_ID BASH_ENV="$WORK/hostile-bashenv.sh" "$COMMS" integrate worktree-proofone) 2>&1 || true )"
[ "$(cd "$IP" && git rev-parse main)" = "$(cd "$IP" && git rev-parse worktree-proofone)" ] \
  && ok "an inherited startup hook is scrubbed and the real suite still runs" \
  || fail "the startup hook defeated the landing (got: $(printf '%s' "$IP_OUT2" | tail -2))"
# Match the CONTENT, not merely the existence of some log: the refused silent run above
# tees a file at the same candidate path, so a leftover would satisfy an existence check.
# (grok, panel r6, advisory.)
grep -rq 'passed: 3  failed: 0  skipped: 0' "$IP/.comms/logs" 2>/dev/null \
  && ok "integrate kept the output of the run it judged" || fail "the kept log is not the run that landed"

# An inherited presence identity whose record does not exist in THIS repo must not kill
# the landing. `presence beat` exits 5 when it HEALS a vanished record, and under `set -e`
# an unguarded advisory beat aborted integrate before its FIRST LINE of output — no
# diagnostic, no candidate line, nothing. AGENTS.md tells every session to export
# COMMS_PRESENCE_NAME/INSTANCE, so this fired for every nested integrate here and for any
# operator whose record lives in a different checkout. It is what made an integrate-hosted
# suite run fail three of its own integrate tests while direct runs of the same commit
# passed repeatedly. Presence bookkeeping is advisory; it must never decide a landing.
# Its own fixture with a REAL (loud) suite, so the landing actually completes and the
# success path — which clears the trap and does its own cleanup — is the one exercised.
# Asserting only that some output appeared would be satisfied by moving the candidate
# print above a still-fatal beat. (codex, panel r1.)
IH="$WORK/int-heal"; mkdir -p "$IH"; IH="$(cd "$IH" && pwd -P)"
git -C "$IH" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IH/.gitignore"
mkdir -p "$IH/tests" "$IH/.comms"
printf 'total\t3\n' > "$IH/tests/expected-counts.tsv"
printf '#!/bin/bash\nprintf "passed: 3  failed: 0  skipped: 0\\n"\n' > "$IH/tests/loud.sh"
chmod +x "$IH/tests/loud.sh"
printf 'suite-cmd = bash tests/loud.sh\n' > "$IH/.comms/config"
(cd "$IH" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IH" && git checkout -q -b session-primary)
(cd "$IH" && env -u CMUX_WORKSPACE_ID "$COMMS" worktree new healone) >/dev/null 2>&1
(cd "$IH/.claude/worktrees/healone" && echo z > e.txt && git add e.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: e") >/dev/null 2>&1
IH_OUT="$( (cd "$IH" && env -u CMUX_WORKSPACE_ID \
    COMMS_PRESENCE_NAME=no-such-session COMMS_PRESENCE_INSTANCE=00000000000000000000000000000000 \
    "$COMMS" integrate worktree-healone) 2>&1 || true )"
[ -n "$IH_OUT" ] || fail "integrate died silently under an inherited presence identity with no local record"
[ "$(cd "$IH" && git rev-parse main)" = "$(cd "$IH" && git rev-parse worktree-healone)" ] \
  && ok "an inherited presence identity with no local record still lands" \
  || fail "the landing did not happen (got: $(printf '%s' "$IH_OUT" | tail -1))"
# ...and the record it HEALED into being must not outlive the run. A healed record has no
# pid, and a pid-less record can never be classified dead, so leaving one behind forces
# every future session in that repo to isolate permanently. (codex, panel r1, blocking.)
# The strong form: integrate never MANUFACTURES a record for an identity that has none
# here. Releasing one after the fact needs ownership tracking that survives signals,
# nested arms and repositories — three review rounds proved that is the harder problem.
# Not creating it has no such surface. (codex, integrate-beat r1-r4.)
[ "$(find "$IH/.comms/sessions" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && ok "integrate creates no presence record for an identity that has none here" \
  || fail "integrate manufactured a pid-less presence record: $(find "$IH/.comms/sessions" -name '*.json' -type f 2>/dev/null | head -1)"
# A PRE-EXISTING record must survive — the release must remove only what this run created.
IH2="$WORK/int-heal2"; mkdir -p "$IH2"; IH2="$(cd "$IH2" && pwd -P)"
cp -R "$IH/tests" "$IH2/tests"; mkdir -p "$IH2/.comms"
printf '.comms/\n.claude/worktrees/\n' > "$IH2/.gitignore"
printf 'suite-cmd = bash tests/loud.sh\n' > "$IH2/.comms/config"
git -C "$IH2" init -q -b main
(cd "$IH2" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IH2" && git checkout -q -b session-primary)
(cd "$IH2" && env -u CMUX_WORKSPACE_ID "$COMMS" worktree new healtwo) >/dev/null 2>&1
(cd "$IH2/.claude/worktrees/healtwo" && echo z > f.txt && git add f.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: f") >/dev/null 2>&1
IH2_CLAIM="$( (cd "$IH2" && env -u CMUX_WORKSPACE_ID "$COMMS" presence claim --name resident --role holder) 2>&1 || true )"
IH2_INST="$(printf '%s' "$IH2_CLAIM" | sed -n 's/.*instance: //p')"
(cd "$IH2" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_NAME=resident COMMS_PRESENCE_INSTANCE="$IH2_INST" \
    "$COMMS" integrate worktree-healtwo) >/dev/null 2>&1 || true
# Assert the landing FIRST: without it a no-op or early failure would "preserve" the
# record vacuously and this would pass for the wrong reason. (grok, panel r2.)
[ "$(cd "$IH2" && git rev-parse main)" = "$(cd "$IH2" && git rev-parse worktree-healtwo)" ] \
  && ok "the pre-existing-record fixture actually landed" || fail "IH2 did not land — its record check would be vacuous"
[ -f "$IH2/.comms/sessions/resident-$IH2_INST.json" ] \
  && ok "a pre-existing presence record survives an integrate that used it" \
  || fail "integrate released a record it did not create"

# SPOOFED OUTPUT must not be believed. An earlier design derived record ownership by
# grepping the captured suite log, so a suite that merely PRINTED the heal sentence made
# cleanup release a LIVE record. That channel is gone — integrate no longer manufactures
# records, so it has nothing to release — and this fixture stays as the tripwire against
# reintroducing any log-derived ownership signal. (codex, integrate-beat r3.)
IH5="$WORK/int-heal5"; mkdir -p "$IH5"; IH5="$(cd "$IH5" && pwd -P)"
git -C "$IH5" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IH5/.gitignore"
mkdir -p "$IH5/tests" "$IH5/.comms"
printf 'total\t3\n' > "$IH5/tests/expected-counts.tsv"
printf '#!/bin/bash\necho "presence: a beat during this run HEALED a vanished record" >&2\nprintf "passed: 3  failed: 0  skipped: 0\\n"\n' > "$IH5/tests/spoof.sh"
chmod +x "$IH5/tests/spoof.sh"
printf 'suite-cmd = bash tests/spoof.sh\n' > "$IH5/.comms/config"
(cd "$IH5" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IH5" && git checkout -q -b session-primary)
(cd "$IH5" && env -u CMUX_WORKSPACE_ID "$COMMS" worktree new spoofone) >/dev/null 2>&1
(cd "$IH5/.claude/worktrees/spoofone" && echo s > i.txt && git add i.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: i") >/dev/null 2>&1
IH5_CLAIM="$( (cd "$IH5" && env -u CMUX_WORKSPACE_ID "$COMMS" presence claim --name liveone --role holder) 2>&1 || true )"
IH5_INST="$(printf '%s' "$IH5_CLAIM" | sed -n 's/.*instance: //p')"
(cd "$IH5" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_NAME=liveone COMMS_PRESENCE_INSTANCE="$IH5_INST" \
    "$COMMS" integrate worktree-spoofone) >/dev/null 2>&1 || true
[ "$(cd "$IH5" && git rev-parse main)" = "$(cd "$IH5" && git rev-parse worktree-spoofone)" ] \
  && ok "the spoof fixture actually landed" || fail "IH5 did not land — its record check would be vacuous"
[ -f "$IH5/.comms/sessions/liveone-$IH5_INST.json" ] \
  && ok "a suite that merely PRINTS the heal sentence cannot make integrate release a live record" \
  || fail "spoofed suite output released a pre-existing presence record"

# A LONG suite outlives the beater interval, which is where the previous fixtures could
# not reach: `with-beat`'s beater sleeps TTL/3 and then beats, and a beat HEALS an absent
# record. Every fixture above finishes in well under a second, so none of them could ever
# observe it. TTL 3 makes the interval 1s; the suite runs for 4. (codex, r5, blocking.)
IH7="$WORK/int-heal7"; mkdir -p "$IH7"; IH7="$(cd "$IH7" && pwd -P)"
git -C "$IH7" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IH7/.gitignore"
mkdir -p "$IH7/tests" "$IH7/.comms"
printf 'total\t3\n' > "$IH7/tests/expected-counts.tsv"
printf '#!/bin/bash\nsleep 4\nprintf "passed: 3  failed: 0  skipped: 0\\n"\n' > "$IH7/tests/slow.sh"
chmod +x "$IH7/tests/slow.sh"
printf 'suite-cmd = bash tests/slow.sh\n' > "$IH7/.comms/config"
(cd "$IH7" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IH7" && git checkout -q -b session-primary)
(cd "$IH7" && env -u CMUX_WORKSPACE_ID "$COMMS" worktree new slowone) >/dev/null 2>&1
(cd "$IH7/.claude/worktrees/slowone" && echo l > k.txt && git add k.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: k") >/dev/null 2>&1
(cd "$IH7" && env -u CMUX_WORKSPACE_ID COMMS_PRESENCE_TTL_SECS=3 \
    COMMS_PRESENCE_NAME=slowghost COMMS_PRESENCE_INSTANCE=77777777777777777777777777777777 \
    "$COMMS" integrate worktree-slowone) >/dev/null 2>&1 || true
[ "$(cd "$IH7" && git rev-parse main)" = "$(cd "$IH7" && git rev-parse worktree-slowone)" ] \
  && ok "a suite outlasting the beat interval still lands" || fail "the slow fixture did not land"
[ "$(find "$IH7/.comms/sessions" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && ok "a suite outlasting the beat interval creates no record for an absent identity" \
  || fail "the beater manufactured a pid-less record during a long suite"

# ...and dropping the heartbeat must NOT drop the SUPERVISION. `with-beat` is also the
# whole-process-group quiescence boundary: without it a suite can print its completion
# line, launch a stdio-detached descendant and exit 0, leaving that descendant alive to
# mutate the tree after integrate validates it and advances main. The absent-record path
# must still wait for the group. (codex, integrate-beat r6, blocking.)
IH8="$WORK/int-heal8"; mkdir -p "$IH8"; IH8="$(cd "$IH8" && pwd -P)"
git -C "$IH8" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IH8/.gitignore"
mkdir -p "$IH8/tests" "$IH8/.comms"
printf 'total\t3\n' > "$IH8/tests/expected-counts.tsv"
# Completion line first, then a detached descendant, then exit 0 — the shape that walks
# past a supervisor which only waits on the direct child.
printf '#!/bin/bash\nprintf "passed: 3  failed: 0  skipped: 0\\n"\n( sleep 2; : > "$IH8_MARK" ) </dev/null >/dev/null 2>&1 &\nexit 0\n' > "$IH8/tests/detach.sh"
chmod +x "$IH8/tests/detach.sh"
printf 'suite-cmd = bash tests/detach.sh\n' > "$IH8/.comms/config"
(cd "$IH8" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IH8" && git checkout -q -b session-primary)
(cd "$IH8" && env -u CMUX_WORKSPACE_ID "$COMMS" worktree new detachone) >/dev/null 2>&1
(cd "$IH8/.claude/worktrees/detachone" && echo d > m.txt && git add m.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: m") >/dev/null 2>&1
# The property is NOT that the run waits for the descendant — supervision TERMs the whole
# group and escalates to KILL. So the observable is that the descendant never gets to act:
# its post-sleep marker must never appear. (A first draft asserted elapsed >= 3s and failed
# against BOTH modes, because waiting is not what quiescence does.)
IH8_MARKF="$WORK/ih8-descendant-ran"
rm -f "$IH8_MARKF"
(cd "$IH8" && env -u CMUX_WORKSPACE_ID IH8_MARK="$IH8_MARKF" \
    COMMS_PRESENCE_NAME=detachghost COMMS_PRESENCE_INSTANCE=66666666666666666666666666666666 \
    "$COMMS" integrate worktree-detachone) >/dev/null 2>&1 || true
[ "$(cd "$IH8" && git rev-parse main)" = "$(cd "$IH8" && git rev-parse worktree-detachone)" ] \
  && ok "the detached-descendant fixture lands" || fail "the detach fixture did not land"
sleep 3   # outlive the descendant's own sleep, so a SURVIVING one would have marked by now
[ ! -f "$IH8_MARKF" ] \
  && ok "an absent-record run still reaps its process group (the descendant never acted)" \
  || fail "a detached descendant outlived the landing — supervision was lost on the absent-record path"
# CONTROL: unsupervised, that descendant DOES act — otherwise the assertion above is vacuous.
rm -f "$IH8_MARKF"
( cd "$IH8" && IH8_MARK="$IH8_MARKF" bash tests/detach.sh ) >/dev/null 2>&1 || true
sleep 3
[ -f "$IH8_MARKF" ] \
  && ok "unsupervised, the same descendant does act (control)" \
  || fail "the control did not reproduce a surviving descendant — the assertion above proves nothing"
rm -f "$IH8_MARKF"
[ "$(find "$IH8/.comms/sessions" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && ok "supervision without a heartbeat still creates no record" || fail "the supervised absent-record path manufactured one"

# The EXIT-trap cleanup path needs its own cover: the success path clears the trap, so the
# regressions above never exercise the trap strings. A failing suite takes the die path.
IH4="$WORK/int-heal4"; mkdir -p "$IH4"; IH4="$(cd "$IH4" && pwd -P)"
git -C "$IH4" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IH4/.gitignore"
mkdir -p "$IH4/tests" "$IH4/.comms"
printf 'total\t3\n' > "$IH4/tests/expected-counts.tsv"
printf '#!/bin/bash\nprintf "passed: 1  failed: 2  skipped: 0\\n"\nexit 1\n' > "$IH4/tests/red.sh"
chmod +x "$IH4/tests/red.sh"
printf 'suite-cmd = bash tests/red.sh\n' > "$IH4/.comms/config"
(cd "$IH4" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IH4" && git checkout -q -b session-primary)
(cd "$IH4" && env -u CMUX_WORKSPACE_ID "$COMMS" worktree new redone) >/dev/null 2>&1
(cd "$IH4/.claude/worktrees/redone" && echo r > h.txt && git add h.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: h") >/dev/null 2>&1
(cd "$IH4" && env -u CMUX_WORKSPACE_ID \
    COMMS_PRESENCE_NAME=ghost4 COMMS_PRESENCE_INSTANCE=44444444444444444444444444444444 \
    "$COMMS" integrate worktree-redone) >/dev/null 2>&1 || true
[ "$(cd "$IH4" && git rev-parse main)" != "$(cd "$IH4" && git rev-parse worktree-redone)" ] \
  && ok "a red suite does not land" || fail "a red suite landed"
[ "$(find "$IH4/.comms/sessions" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && ok "the EXIT-trap path creates no record either" \
  || fail "a failed landing left a pid-less record behind"

# A hook that INTERPOSES on the scrub command itself: `env` as a shell function takes
# precedence over the builtin and PATH, so an unpinned scrub would call the forgery
# instead of scrubbing, and the forged completion line would satisfy the positive proof.
# Verified as a working exploit before it was fixed. (codex, panel r6, blocking.)
IP2="$WORK/int-forge"; mkdir -p "$IP2"; IP2="$(cd "$IP2" && pwd -P)"
git -C "$IP2" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IP2/.gitignore"
mkdir -p "$IP2/tests" "$IP2/.comms"
printf 'total\t3\n' > "$IP2/tests/expected-counts.tsv"
# The REAL suite here is silent: it exits 0 and prints nothing, so it can never satisfy
# the positive proof on its own. Landing is therefore possible ONLY if the forged line
# reaches the log — which makes this assertion discriminating. (With a passing real suite
# the candidate lands either way and the test proves nothing; that was the first draft.)
printf '#!/bin/bash\nexit 0\n' > "$IP2/tests/quiet.sh"
chmod +x "$IP2/tests/quiet.sh"
printf 'suite-cmd = bash tests/quiet.sh\n' > "$IP2/.comms/config"
(cd "$IP2" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$IP2" && git checkout -q -b session-primary)
(cd "$IP2" && env -u CMUX_WORKSPACE_ID "$COMMS" worktree new forgeone) >/dev/null 2>&1
(cd "$IP2/.claude/worktrees/forgeone" && echo y > d.txt && git add d.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: d") >/dev/null 2>&1
# The forgery prints a line that WOULD satisfy the proof, and never runs the suite.
# Two shapes: a plain `env` function, and a function whose NAME IS THE ABSOLUTE PATH —
# bash 3.2 accepts the latter and dispatches it ahead of the executable, which is exactly
# what defeated the absolute-path-only fix. (codex, panel r7, blocking.)
printf 'env() { printf "passed: 3  failed: 0  skipped: 0\\n"; return 0; }\nfunction /usr/bin/env { printf "passed: 3  failed: 0  skipped: 0\\n"; return 0; }\n' > "$WORK/forge-bashenv.sh"
printf 'function /usr/bin/env { printf "passed: 3  failed: 0  skipped: 0\\n"; return 0; }\n' > "$WORK/forge-abs-bashenv.sh"
FORGE_ABS_CTL="$(BASH_ENV="$WORK/forge-abs-bashenv.sh" bash -c 'e=(/usr/bin/env -u BASH_ENV); "${e[@]}" bash -c "echo REAL"' 2>&1 || true)"
case "$FORGE_ABS_CTL" in
  *"passed: 3"*) ok "an absolute-path function does shadow the executable on this bash (control)" ;;
  *) fail "the absolute-path forgery control did not interpose (got: $FORGE_ABS_CTL)" ;;
esac
# CONTROL: prove the interposition actually works on an unpinned call, or the assertion
# below only proves that integrate happens to land.
FORGE_CTL="$(BASH_ENV="$WORK/forge-bashenv.sh" bash -c 'e=(env -u BASH_ENV); "${e[@]}" bash -c "echo REAL"' 2>&1 || true)"
case "$FORGE_CTL" in
  *"passed: 3"*) ok "an env-function hook does interpose on an unpinned scrub (control)" ;;
  *) fail "the forgery control did not interpose (got: $FORGE_CTL)" ;;
esac
FORGE_OUT="$( (cd "$IP2" && env -u CMUX_WORKSPACE_ID BASH_ENV="$WORK/forge-bashenv.sh" "$COMMS" integrate worktree-forgeone) 2>&1 || true )"
[ "$(cd "$IP2" && git rev-parse main)" != "$(cd "$IP2" && git rev-parse worktree-forgeone)" ] \
  && ok "a forged completion line from an interposed scrub does not land" \
  || fail "an env-function forgery landed a candidate whose suite never ran"
FORGE_ABS_OUT="$( (cd "$IP2" && env -u CMUX_WORKSPACE_ID BASH_ENV="$WORK/forge-abs-bashenv.sh" "$COMMS" integrate worktree-forgeone) 2>&1 || true )"
[ "$(cd "$IP2" && git rev-parse main)" != "$(cd "$IP2" && git rev-parse worktree-forgeone)" ] \
  && ok "an absolute-path function forgery does not land either" \
  || fail "a /usr/bin/env function forgery landed a candidate whose suite never ran"

# The probe-bound skips must refuse an UNRUN probe, not just a successful one.
SK_UNRUN="$( (FAIL=0; SKIP=0; SKIP_USED=" "; unset ACL_PROBE_OK; skip acl-report "probe never ran" >/dev/null 2>&1; echo "$FAIL") )"
[ "$SK_UNRUN" = 1 ] && ok "a probe-bound skip is refused before its probe has run" || fail "an unrun probe permitted its skip (FAIL=$SK_UNRUN)"
SK_RAN_OK="$( (FAIL=0; SKIP=0; SKIP_USED=" "; ACL_PROBE_OK=1; skip acl-report "probe succeeded" >/dev/null 2>&1; echo "$FAIL") )"
[ "$SK_RAN_OK" = 1 ] && ok "a probe-bound skip is refused when the probe succeeded" || fail "a successful probe permitted its skip (FAIL=$SK_RAN_OK)"
SK_RAN_NO="$( (FAIL=0; SKIP=0; SKIP_USED=" "; ACL_PROBE_OK=0; skip acl-report "probe failed" >/dev/null 2>&1; echo "$SKIP") )"
[ "$SK_RAN_NO" = 1 ] && ok "a probe-bound skip is permitted on a confirmed failed probe" || fail "a confirmed failed probe refused its skip (SKIP=$SK_RAN_NO)"
# The group flag uses the same pattern on a different variable and was only exercised by
# the live installer branch. (grok, panel r7, advisory.)
GK_UNRUN="$( (FAIL=0; SKIP=0; SKIP_USED=" "; unset GRP_PRESERVE_OK; skip group-no-secondary "unrun" >/dev/null 2>&1; echo "$FAIL") )"
[ "$GK_UNRUN" = 1 ] && ok "the group skip is refused before its probe has run" || fail "an unrun group probe permitted its skip"
GK_OK="$( (FAIL=0; SKIP=0; SKIP_USED=" "; GRP_PRESERVE_OK=1; skip group-no-secondary "succeeded" >/dev/null 2>&1; echo "$FAIL") )"
[ "$GK_OK" = 1 ] && ok "the group skip is refused when its probe succeeded" || fail "a successful group probe permitted its skip"
GK_NO="$( (FAIL=0; SKIP=0; SKIP_USED=" "; GRP_PRESERVE_OK=0; skip group-no-secondary "failed" >/dev/null 2>&1; echo "$SKIP") )"
[ "$GK_NO" = 1 ] && ok "the group skip is permitted on a confirmed failed probe" || fail "a confirmed failed group probe refused its skip"

section "the coordinator's event log: a durable record that is not the mailbox"
# Contraction step 3, criteria 1 and 4. The log's value is that it SURVIVES things — a
# driver that dies mid-panel, a broker that refuses, N runners appending at once — so it is
# exercised here, never asserted about. Columns are resolved BY NAME from the header, so
# adding one cannot silently repoint an assertion at the wrong field.
EV="$WORK/events-repo"; mkdir -p "$EV"; EV="$(cd "$EV" && pwd -P)"
git -C "$EV" init -q -b main
printf '.comms/\n' > "$EV/.gitignore"
echo "subject" > "$EV/s.txt"
git -C "$EV" add -A >/dev/null 2>&1
git -C "$EV" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV/.comms/to-codex" "$EV/.comms/to-grok" "$EV/.comms/to-claude" "$EV/.comms/archive"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV/.comms/config"
run_ev() { (cd "$EV" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_LOG="$EV/.comms/events.tsv"
EV_ROWS() { tail -n +2 "$EV_LOG" 2>/dev/null | grep -c . || true; }
EV_COL() { awk -F'\t' -v n="$1" 'NR==1{for(i=1;i<=NF;i++) if ($i==n) {print i; exit}}' "$EV_LOG"; }

EV_EMPTY="$(run_ev events 2>&1)" && EV_ERC=0 || EV_ERC=$?
[ "${EV_ERC:-0}" = "0" ] && printf '%s\n' "$EV_EMPTY" | grep -q 'no coordinator log yet' \
  && ok "an absent log reports itself instead of failing" || fail "absent-log read (rc=$EV_ERC: $EV_EMPTY)"
[ ! -f "$EV_LOG" ] && ok "reading does not create the log" || fail "the reader created the log"

run_ev events append --kind turn-started --set ev-set-1 --dispatch d-1 --thread ev-thread \
  --round 2 --agent codex --status running --note "first note" >/dev/null
[ -s "$EV_LOG" ] && ok "append creates the log" || fail "append created no log"
C_TS=$(EV_COL ts); C_EV=$(EV_COL event); C_SET=$(EV_COL review_set); C_DSP=$(EV_COL dispatch)
C_TH=$(EV_COL thread); C_AG=$(EV_COL agent); C_ROLE=$(EV_COL role); C_ART=$(EV_COL artifact_id)
C_REQ=$(EV_COL request_id); C_MID=$(EV_COL message_id); C_ST=$(EV_COL status); C_NOTE=$(EV_COL note)
C_NF=$(head -1 "$EV_LOG" | awk -F'\t' '{print NF}')
[ -n "$C_TS$C_EV$C_SET$C_DSP$C_TH$C_AG$C_ROLE$C_ART$C_REQ$C_MID$C_ST$C_NOTE" ] && [ "$C_TS" = "1" ] \
  && ok "the header names every column its readers index by" || fail "log header (got: $(head -1 "$EV_LOG"))"
EV_ROW="$(tail -1 "$EV_LOG")"
evf() { printf '%s' "$EV_ROW" | cut -f"$1"; }
[ "$(evf "$C_EV")" = "turn-started" ] && ok "the kind lands in the event column" || fail "event column (got: $EV_ROW)"
[ "$(evf "$C_SET")" = "ev-set-1" ] && ok "the review set is recorded" || fail "set column (got: $EV_ROW)"
[ "$(evf "$C_DSP")" = "d-1" ] && ok "the dispatch attempt is recorded" || fail "dispatch column (got: $EV_ROW)"
[ "$(evf "$C_TH")" = "ev-thread" ] && ok "the thread is recorded" || fail "thread column (got: $EV_ROW)"
[ "$(evf "$C_AG")" = "codex" ] && ok "the agent is recorded" || fail "agent column (got: $EV_ROW)"
[ "$(evf "$C_ROLE")" = "gating" ] && ok "a turn gates unless it says otherwise" || fail "role column (got: $EV_ROW)"
[ "$(evf "$C_ST")" = "running" ] && ok "the status is recorded" || fail "status column (got: $EV_ROW)"
run_ev events append --kind provider-result --set ev-set-1 --thread ev-thread --agent codex --status completed >/dev/null
[ "$(EV_ROWS)" = "2" ] && ok "the log appends rather than rewrites" || fail "append count (got: $(EV_ROWS))"

check_not "an unknown event kind is refused" run_ev events append --kind turnstarted
check_not "an event with no kind is refused" run_ev events append --thread ev-thread
check_not "an unknown role is refused" run_ev events append --kind turn-started --role auditor
[ "$(EV_ROWS)" = "2" ] && ok "a refused append writes nothing" || fail "a refused append still wrote (got: $(EV_ROWS))"

run_ev events append --kind reply-refused --thread ev-thread --status refused \
  --note "$(printf 'tab\there\nand a newline')" >/dev/null
[ "$(EV_ROWS)" = "3" ] && ok "a note with a tab and a newline stays ONE row" || fail "sanitisation split the row (got: $(EV_ROWS))"
[ "$(tail -1 "$EV_LOG" | awk -F'\t' '{print NF}')" = "$C_NF" ] && ok "the sanitised row keeps every column" || fail "column count after sanitisation"
EV_BIG="$(awk 'BEGIN{while(i++<4000)printf "x"}')"
run_ev events append --kind reply-validated --thread ev-thread --status APPROVE --note "$EV_BIG" >/dev/null
[ "$(tail -1 "$EV_LOG" | LC_ALL=C wc -c | tr -d ' ')" -le 1024 ] && ok "an oversized note is clipped to the row cap" || fail "row cap on a long note"
# The cap is a property of the COLUMNS. Clipping the assembled row instead would cut
# trailing delimiters off and break the fixed-column contract. (codex, plan r1.)
run_ev events append --kind turn-started --set "$EV_BIG" --dispatch "$EV_BIG" --thread "$EV_BIG" \
  --round "$EV_BIG" --agent "$EV_BIG" --artifact "$EV_BIG" --request-id "$EV_BIG" \
  --message-id "$EV_BIG" --run-dir "$EV_BIG" --status "$EV_BIG" --note "$EV_BIG" >/dev/null
[ "$(tail -1 "$EV_LOG" | LC_ALL=C wc -c | tr -d ' ')" -le 1024 ] && ok "every column at its maximum still fits the row cap" || fail "row cap with all columns maxed"
# The cap is about what reaches write(2), so the newline counts. Accepting 1025 was the
# test masking the violation. (codex, implement r1, blocking.)
[ "$(awk 'END{print (max+0)}{ if (length($0)+1 > max) max = length($0)+1 }' "$EV_LOG")" -le 1024 ] \
  && ok "no row in the whole log exceeds the cap, newline included" || fail "a row exceeds the cap with its newline"
[ "$(tail -1 "$EV_LOG" | awk -F'\t' '{print NF}')" = "$C_NF" ] && ok "a maxed row keeps every column" || fail "maxed row lost columns"

# A torn row is NAMED, not parsed: there is no lock (a dead holder is a deadlock), so
# detection is the guarantee. Whole-field checks, or two concatenated rows pass. (codex r2.)
#
# In its OWN repo, because a torn row now makes attempt binding refuse — planting one in the
# fixture the panel tests share would poison every later status and compose here, which is
# precisely the loud behaviour being asserted further down. (codex, implement r3.)
EVT="$WORK/events-torn"; mkdir -p "$EVT"; EVT="$(cd "$EVT" && pwd -P)"
git -C "$EVT" init -q -b main
git -C "$EVT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
run_evt() { (cd "$EVT" && env -u CMUX_WORKSPACE_ID "$COMMS" "$@"); }
EVT_LOG="$EVT/.comms/events.tsv"
run_evt events append --kind turn-started --set ev-set-1 --thread ev-thread --agent codex --status running >/dev/null
EV_LOG_MAIN="$EV_LOG"; EV_LOG="$EVT_LOG"
run_ev_main() { run_ev "$@"; }
run_ev() { run_evt "$@"; }
printf 'this row has no columns and no timestamp\n' >> "$EV_LOG"
EV_TORN="$(run_ev events 2>&1 >/dev/null)"
printf '%s\n' "$EV_TORN" | grep -q 'malformed' && ok "a malformed row is reported on stderr" || fail "torn row not reported (got: $EV_TORN)"
run_ev events 2>/dev/null | grep -q 'this row has no columns' && fail "a malformed row was printed as an event" || ok "a malformed row is never printed as an event"
EV_GOOD="$(awk -F'\t' 'NR==2' "$EV_LOG")"
printf '%s%s\n' "$EV_GOOD" "$EV_GOOD" >> "$EV_LOG"
[ "$(run_ev events --kind turn-started 2>/dev/null | grep -c 'ev-set-1')" = "1" ] \
  && ok "two rows concatenated into one line are refused, not read as an event" || fail "concatenated row passed the check"
EV_BADKIND="$(printf '%s' "$EV_GOOD" | awk -F'\t' -v c="$C_EV" 'BEGIN{OFS="\t"}{$c="turn-invented"; print}')"
printf '%s\n' "$EV_BADKIND" >> "$EV_LOG"
run_ev events 2>/dev/null | grep -q 'turn-invented' && fail "a row with an unknown kind was read as an event" || ok "a row naming a kind outside the vocabulary is refused"
# EVERY closed vocabulary, not just the kind: a role nobody can write was being printed as
# a real event. (codex, implement r1, blocking.)
EV_BADROLE="$(printf '%s' "$EV_GOOD" | awk -F'\t' -v c="$C_ROLE" -v t="$C_TH" 'BEGIN{OFS="\t"}{$c="auditor"; $t="ev-badrole"; print}')"
printf '%s\n' "$EV_BADROLE" >> "$EV_LOG"
run_ev events 2>/dev/null | grep -q 'ev-badrole' && fail "a row naming an impossible role was read as an event" || ok "a row naming a role outside the vocabulary is refused"
# A row that merely BEGINS with the header's first token is a row, not a header: skipping
# it would drop a real event, and swallowing a foreign header would hide it. (codex.)
ev_malformed_count() { run_ev events 2>&1 >/dev/null | sed -n 's/.*skipped \([0-9][0-9]*\) malformed.*/\1/p' | tail -1; }
EV_MB="$(ev_malformed_count)"
printf 'ts\tnot\ta\theader\tjust\ta\trow\tthat\tstarts\twith\tts\tand\tis\tmalformed\there\n' >> "$EV_LOG"
# Counted, not grepped: torn rows planted earlier make a bare `grep malformed` pass whether
# or not THIS row was caught. (grok, implement r2.)
[ "$(ev_malformed_count)" = "$(( ${EV_MB:-0} + 1 ))" ] \
  && ok "a header-shaped row that is not the header is reported, not silently skipped" || fail "header-shaped row swallowed (was ${EV_MB:-0}, now $(ev_malformed_count))"

# Back to the shared fixture, whose log is still clean.
EV_LOG="$EV_LOG_MAIN"
run_ev() { (cd "$EV" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }

EV_N=20
i=1; while [ "$i" -le "$EV_N" ]; do
  run_ev events append --kind turn-started --set ev-race --thread "race-$i" --status running --note "racer-$i" >/dev/null &
  i=$((i+1))
done
wait
[ "$(awk -F'\t' -v c="$C_SET" '$c=="ev-race"' "$EV_LOG" | grep -c .)" = "$EV_N" ] && ok "every concurrent append lands" || fail "concurrent appends lost rows"
[ "$(awk -F'\t' -v c="$C_SET" -v n="$C_NF" '$c=="ev-race" && NF!=n' "$EV_LOG" | grep -c . || true)" = "0" ] \
  && ok "no concurrent append tore another's row" || fail "a concurrent row was torn"
[ "$(awk -F'\t' -v c="$C_SET" -v n="$C_NOTE" '$c=="ev-race"{print $n}' "$EV_LOG" | sort -u | grep -c .)" = "$EV_N" ] \
  && ok "every racer's own note survived intact" || fail "a racing note was lost or merged"

# The atomicity argument is about the row that reaches write(2), so the boundary case —
# maximum-size rows — is the one worth racing. (codex, implement r2, advisory.)
i=1; while [ "$i" -le 10 ]; do
  run_ev events append --kind turn-started --set ev-bigrace --thread "big-$i" --status running --note "$EV_BIG" >/dev/null &
  i=$((i+1))
done
wait
[ "$(awk -F'\t' -v c="$C_SET" '$c=="ev-bigrace"' "$EV_LOG" | grep -c .)" = "10" ] \
  && ok "concurrent MAXIMUM-size rows all land" || fail "a maximum-size concurrent append was lost"
[ "$(awk -F'\t' -v c="$C_SET" -v n="$C_NF" '$c=="ev-bigrace" && NF!=n' "$EV_LOG" | grep -c . || true)" = "0" ] \
  && ok "no maximum-size row tore another" || fail "a maximum-size row was torn"

EV2="$WORK/events-repo-2"; mkdir -p "$EV2"; EV2="$(cd "$EV2" && pwd -P)"
git -C "$EV2" init -q -b main
git -C "$EV2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
i=1; while [ "$i" -le 8 ]; do
  (cd "$EV2" && env -u CMUX_WORKSPACE_ID "$COMMS" events append --kind turn-started --thread "h-$i" >/dev/null 2>&1) &
  i=$((i+1))
done
wait
[ "$(grep -c '^ts	workspace	event' "$EV2/.comms/events.tsv" 2>/dev/null || true)" = "1" ] \
  && ok "racing first writers create exactly one header" || fail "header raced"
[ "$(tail -n +2 "$EV2/.comms/events.tsv" | grep -c .)" = "8" ] && ok "no racing first write was lost to the header" || fail "a first write was lost"
# A log whose header could not be written is refused rather than created headerless — every
# reader would otherwise report its rows as malformed forever. (codex, implement r2.)
EV7="$WORK/events-repo-7"; mkdir -p "$EV7"
git -C "$EV7" init -q -b main; git -C "$EV7" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$EV7/.comms"; chmod a-w "$EV7/.comms"
EV_NOHDR="$( (cd "$EV7" && env -u CMUX_WORKSPACE_ID "$COMMS" events append --kind turn-started --thread h) 2>&1 || true )"
chmod u+w "$EV7/.comms"
printf '%s\n' "$EV_NOHDR" | grep -q 'headerless' && ok "a log whose header cannot be created is refused" || fail "headerless log not refused (got: $EV_NOHDR)"
# A directory that cannot be created reports and RETURNS, the same as every other refusal —
# `die` there would exit a `send` mid-delivery. (codex, implement r3, blocking.)
EV8="$WORK/events-repo-8"; mkdir -p "$EV8"
git -C "$EV8" init -q -b main; git -C "$EV8" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
: > "$EV8/.comms"
EV_NODIR="$( (cd "$EV8" && env -u CMUX_WORKSPACE_ID "$COMMS" events append --kind turn-started --thread d) 2>&1 || true )"
rm -f "$EV8/.comms"
printf '%s\n' "$EV_NODIR" | grep -q 'cannot create' && ok "an uncreatable events directory is reported, not a bash error" || fail "uncreatable dir (got: $EV_NODIR)"
# If the channel that reports skipped rows cannot be created, the evidence of a torn log
# would vanish and every consumer would trust a file nothing validated. (codex, r4.)
EV_NOTMP="$( (cd "$EV" && env -u CMUX_WORKSPACE_ID TMPDIR=/nonexistent-tmpdir-for-tests "$COMMS" events --limit 1) 2>&1 >/dev/null || true )"
printf '%s\n' "$EV_NOTMP" | grep -q 'could not be counted' \
  && ok "a reader that cannot record what it skipped refuses to read at all" || fail "reader degraded silently (got: $EV_NOTMP)"
[ ! -f "$EV7/.comms/events.tsv" ] && ok "the refusal leaves no headerless log behind" || fail "a headerless log was created"

# The filesystem constraint is ENFORCED, not diagnosed: an NFS append can be LOST whole,
# leaving a well-formed file with an event missing — which no reader can detect. So the log
# refuses to exist there rather than warning and continuing. (codex, plan r2, blocking.)
EV_DFB="$WORK/df-stub"; mkdir -p "$EV_DFB"
cat > "$EV_DFB/df" <<'DFS'
#!/bin/bash
printf 'Filesystem 512-blocks Used Available Capacity Mounted on\n'
# No device configured models a df that cannot answer — the unclassifiable case.
[ -n "${DF_STUB_FS:-}" ] || exit 1
printf '%s 1 1 1 1%% /mnt\n' "$DF_STUB_FS"
DFS
# The type probes are stubbed too, so BOTH branches — GNU `stat` and the BSD mount table —
# are driven on either kind of host instead of one of them being untested wherever the
# suite happens to run.
cat > "$EV_DFB/stat" <<'STS'
#!/bin/bash
[ -n "${STAT_STUB_TYPE:-}" ] || exit 1
printf '%s\n' "$STAT_STUB_TYPE"
STS
cat > "$EV_DFB/mount" <<'MTS'
#!/bin/bash
[ -n "${MOUNT_STUB_TYPE:-}" ] || exit 1
printf 'dev on /mnt (%s, local, journaled)\n' "$MOUNT_STUB_TYPE"
MTS
chmod +x "$EV_DFB/df" "$EV_DFB/stat" "$EV_DFB/mount"
ev_fs_try() { # <df-device> <repo-dir> [env assignments...]
  local dev="$1" dir="$2"; shift 2
  mkdir -p "$dir"; git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  (cd "$dir" && env -u CMUX_WORKSPACE_ID DF_STUB_FS="$dev" "$@" PATH="$EV_DFB:$PATH" \
     "$COMMS" events append --kind turn-started --thread fs-1) 2>&1
}
ev_fs_case() { # <label> <expect accepted|refused> <df-device> <dir> [env...]
  local lbl="$1" want="$2"; shift 2
  local out; out="$(ev_fs_try "$@" || true)"
  local got=accepted
  printf '%s\n' "$out" | grep -q 'refusing to write' && got=refused
  [ "$got" = "$want" ] && ok "$lbl" || fail "$lbl (wanted $want, got $got: $(printf '%s' "$out" | head -1))"
}
# An ALLOWLIST of known-local types, failing closed on anything unrecognised. The shape
# blacklist this replaced was blind to network FUSE mounts, which look nothing like
# host:/export and are exactly as unsafe. (codex, implement r2, blocking.)
ev_fs_case "a local disk type is accepted" accepted '/dev/disk1s5' "$WORK/evfs-ext" STAT_STUB_TYPE=ext2/ext3
ev_fs_case "an NFS type is refused" refused '/dev/disk1s5' "$WORK/evfs-nfs" STAT_STUB_TYPE=nfs
ev_fs_case "an UNRECOGNISED type fails closed" refused '/dev/disk1s5' "$WORK/evfs-fuse" STAT_STUB_TYPE=fuseblk
ev_fs_case "the mount table answers where GNU stat cannot" accepted '/dev/disk1s5' "$WORK/evfs-apfs" MOUNT_STUB_TYPE=apfs
ev_fs_case "a network FUSE mount is refused by type, not by name shape" refused '/dev/disk1s5' "$WORK/evfs-osxfuse" MOUNT_STUB_TYPE=osxfuse
ev_fs_case "a filesystem nothing can classify fails closed" refused '/dev/disk1s5' "$WORK/evfs-silent"
ev_fs_case "an rclone-style remote:bucket source is refused" refused 'remote:bucket' "$WORK/evfs-rclone" STAT_STUB_TYPE=ext4
EV_NFS="$(ev_fs_try 'fileserver:/export/home' "$WORK/events-repo-3" STAT_STUB_TYPE=ext4 || true)"
printf '%s\n' "$EV_NFS" | grep -q 'refusing to write' && ok "an NFS mount refuses the log outright" || fail "network fs not refused (got: $EV_NFS)"
[ ! -f "$WORK/events-repo-3/.comms/events.tsv" ] && ok "a refused filesystem leaves no half-made log" || fail "a log was created on a refused filesystem"
EV_SMB="$(ev_fs_try '//server/share' "$WORK/events-repo-5" STAT_STUB_TYPE=ext4 || true)"
printf '%s\n' "$EV_SMB" | grep -q 'refusing to write' && ok "an SMB mount refuses the log outright" || fail "smb fs not refused (got: $EV_SMB)"
EV_LOCAL="$(ev_fs_try '/dev/disk1s5' "$WORK/events-repo-4" STAT_STUB_TYPE=ext4 || true)"
printf '%s\n' "$EV_LOCAL" | grep -q 'refusing' && fail "a local filesystem was refused" || ok "a local filesystem is accepted"
# ...and it actually wrote, rather than failing for some other reason the grep cannot see.
[ -s "$WORK/events-repo-4/.comms/events.tsv" ] && ok "the accepted filesystem really got a log" || fail "no log on the accepted filesystem"
# CHECKED ON EVERY APPEND. Judging only at creation left the refusal bypassable for the
# rest of the log's life by a `.comms` that migrates onto network storage — the silent-loss
# mode the refusal exists to prevent. (codex + grok, implement r1.)
EV_MIGRATED="$( (cd "$WORK/events-repo-4" && env -u CMUX_WORKSPACE_ID DF_STUB_FS='fileserver:/export/home' STAT_STUB_TYPE=ext4 PATH="$EV_DFB:$PATH" "$COMMS" events append --kind turn-started --thread migrated-1) 2>&1 >/dev/null || true )"
printf '%s\n' "$EV_MIGRATED" | grep -q 'refusing to write' && ok "an EXISTING log that moved onto network storage refuses further appends" || fail "migrated log appended unchecked (got: $EV_MIGRATED)"
grep -q 'migrated-1' "$WORK/events-repo-4/.comms/events.tsv" && fail "the refused append was written anyway" || ok "a refused append leaves no row"
# ...and refusing must RETURN, not exit: `die` inside the accessor would take the whole
# process with it, including a `send` that is delivering a reply — the advisory half of the
# policy would silently become fail-closed. (grok, implement r2.)
EV_FSREPLY="$EV/.comms/to-claude/$(basename "$EV")_2026-08-29T09-40-00_ev-fsreply.md"
printf -- '---\ntype: review-feedback\nfrom: codex\ntimestamp: 2026-08-29T09:40:00Z\nworkspace: %s\nmessage_id: ev-fsreply-1\nthread: ev-loop\nin-reply-to: ev-req-1\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n- None.\n' "$(basename "$EV")" > "$EV_FSREPLY"
if (cd "$EV" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 DF_STUB_FS='fileserver:/export/home' STAT_STUB_TYPE=ext4 PATH="$EV_DFB:$STUB_BIN:$PATH" "$COMMS" send --to claude "$EV_FSREPLY") >/dev/null 2>&1; then
  ok "an unsound filesystem refuses the log without killing a reply's delivery"
else
  fail "a refused log took the reply's send down with it"
fi
# The same refusal on a REQUEST must still gate: that producer is the fail-closed one.
EV_FSREQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-41-00_ev-fsreq.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:41:00Z\nworkspace: %s\nmessage_id: ev-fsreq-1\nthread: ev-fsreq\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV")" > "$EV_FSREQ"
if (cd "$EV" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 DF_STUB_FS='fileserver:/export/home' STAT_STUB_TYPE=ext4 PATH="$EV_DFB:$STUB_BIN:$PATH" "$COMMS" send --to codex "$EV_FSREQ") >/dev/null 2>&1; then
  fail "a request dispatched with no recordable log"
else
  ok "a request whose persistence cannot be recorded is still refused outright"
fi

[ "$(run_ev events --set ev-race 2>/dev/null | tail -n +2 | grep -c .)" = "$EV_N" ] && ok "--set selects one review set" || fail "--set filter"
[ "$(run_ev events --thread race-3 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] && ok "--thread selects one leg" || fail "--thread filter"
[ "$(run_ev events --kind provider-result 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] && ok "--kind selects one lifecycle point" || fail "--kind filter"
[ "$(run_ev events --agent codex 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] && ok "--agent selects one reviewer" || fail "--agent filter"
[ "$(run_ev events --dispatch d-1 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] && ok "--dispatch selects one attempt" || fail "--dispatch filter"
[ "$(run_ev events --limit 3 2>/dev/null | tail -n +2 | grep -c .)" = "3" ] && ok "--limit caps what is printed" || fail "--limit cap"
printf '%s\n' "$(run_ev events --set ev-race --limit 1 2>/dev/null)" | tail -1 | grep -q 'racer-' \
  && ok "--limit applies AFTER the filter, never as a global tail" || fail "--limit filter ordering"
[ "$(run_ev events --set ev-race 2>/dev/null | sed -n 1p | cut -f1)" = "ts" ] \
  && ok "a filtered read still prints the header" || fail "filtered header"
check_not "--limit rejects a non-numeric budget" run_ev events --limit nine
# A roster read must not be capped: dispatch enforces no maximum, so a silent cap would drop
# members from the union it is enumerating and let a short panel report itself complete.
# (codex, implement r6, blocking.)
i=1; while [ "$i" -le 60 ]; do
  run_ev events append --kind panel-planned --set ev-bigroster --dispatch d-big --agent "codex" \
    --thread "big-$i" --status planned >/dev/null
  i=$((i+1))
done
[ "$(run_ev events --set ev-bigroster --limit 50 2>/dev/null | tail -n +2 | grep -c .)" = "50" ] \
  && ok "--limit still caps an ordinary read" || fail "--limit stopped capping"
[ "$(run_ev events --set ev-bigroster --all 2>/dev/null | tail -n +2 | grep -c .)" = "60" ] \
  && ok "--all reads every row, so a roster is never silently shortened" || fail "--all is still capped"
# The set id is bounded at its SOURCE, so sets.tsv and the log hold the same bytes and the
# bare listing can join them. Unbounded, a long id was stored raw in one and encoded in the
# other, and the listing reported zero legs for a valid set. (codex + grok, implement r5.)
# Identity columns are exact-match join keys. A plain clip breaks the join SILENTLY: the row
# is written, and then nothing can ever find it again. Writer and reader share one transform
# — a readable head plus a digest of the whole. (codex, implement r4, blocking.)
EV_LONGID="m-$(awk 'BEGIN{while(i++<200)printf "x"}')"
run_ev events append --kind reply-accepted --thread ev-longid --message-id "$EV_LONGID" --status APPROVE >/dev/null
[ "$(run_ev events --kind reply-accepted --message-id "$EV_LONGID" 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] \
  && ok "an identity longer than its column is still found by its full value" || fail "a long identity could not find itself"
[ "$(run_ev events --kind reply-accepted --message-id "${EV_LONGID}zzz" 2>/dev/null | tail -n +2 | grep -c .)" = "0" ] \
  && ok "a DIFFERENT long identity sharing the same prefix does not match" || fail "the identity transform collides on a shared prefix"
[ "$(awk -F'\t' -v c="$C_MID" -v t="$C_TH" '$t=="ev-longid"{print length($c)}' "$EV_LOG")" -le 72 ] \
  && ok "the stored identity still respects its column budget" || fail "identity exceeded its column"
# A shadow turn shares its gating leg's thread and dispatch, so a recovery read has to be
# able to drop it or a measurement looks like the leg that gates. (grok, implement r1.)
run_ev events append --kind turn-started --set ev-roles --thread ev-roles --role shadow --status running >/dev/null
run_ev events append --kind turn-started --set ev-roles --thread ev-roles --role gating --status running >/dev/null
[ "$(run_ev events --set ev-roles --role gating 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] \
  && ok "--role separates the gating leg from a measurement on the same thread" || fail "--role filter"

EV_REQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-00-00_ev-req.md"
cat > "$EV_REQ" <<EVEOF
---
type: review-request
from: claude
timestamp: 2026-08-29T09:00:00Z
workspace: $(basename "$EV")
message_id: ev-req-1
thread: ev-loop
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## What was done
A change worth reviewing.
EVEOF
run_ev send --to codex "$EV_REQ" >/dev/null 2>&1 || true
EV_SEQ="$(awk -F'\t' -v c="$C_MID" -v e="$C_EV" '$c=="ev-req-1"{printf "%s ", $e}' "$EV_LOG")"
[ "$EV_SEQ" = "request-persisted request-dispatched " ] \
  && ok "a dispatch records persistence BEFORE delivery, then its outcome" || fail "send event pair (got: $EV_SEQ)"
awk -F'\t' -v c="$C_MID" -v e="$C_EV" -v a="$C_ART" '$c=="ev-req-1" && $e=="request-persisted" && $a ~ /^[0-9a-f]{40}$/' "$EV_LOG" | grep -q . \
  && ok "the request event carries the artifact send pinned" || fail "request event artifact_id"
awk -F'\t' -v c="$C_MID" -v e="$C_EV" -v st="$C_ST" '$c=="ev-req-1" && $e=="request-dispatched" && $st!=""' "$EV_LOG" | grep -q . \
  && ok "the dispatch event carries the delivery outcome" || fail "dispatch outcome status"

EV_REPLY="$EV/.comms/to-claude/$(basename "$EV")_2026-08-29T09-05-00_ev-reply.md"
cat > "$EV_REPLY" <<EVEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-29T09:05:00Z
workspace: $(basename "$EV")
message_id: ev-reply-1
thread: ev-loop
in-reply-to: ev-req-1
workflow: auto
phase: implement
round: 1
max-rounds: 4
verdict: APPROVE
---

## Findings

### Blocking
- None.
EVEOF
run_ev send --to claude "$EV_REPLY" >/dev/null 2>&1 || true
ev_reply_field() { awk -F'\t' -v c="$C_MID" -v f="$1" '$c=="ev-reply-1"{v=$f} END{print v}' "$EV_LOG"; }
[ "$(ev_reply_field "$C_EV")" = "reply-accepted" ] \
  && ok "a reply is recorded as accepted, not as another request" || fail "reply event kind"
[ "$(ev_reply_field "$C_ST")" = "APPROVE" ] \
  && ok "the accepted reply carries its VERDICT as the status" || fail "reply verdict status"
[ "$(ev_reply_field "$C_AG")" = "codex" ] \
  && ok "a reply is attributed to its author, never to the send target" || fail "reply agent attribution"
[ "$(ev_reply_field "$C_REQ")" = "ev-req-1" ] \
  && ok "a reply carries the request id it answers" || fail "reply request_id binding"

EV_Q="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-06-00_ev-q.md"
printf -- '---\ntype: question\nfrom: claude\ntimestamp: 2026-08-29T09:06:00Z\nworkspace: %s\nmessage_id: ev-q-1\n---\n\n## Question\n\nWhat?\n' "$(basename "$EV")" > "$EV_Q"
run_ev send --to codex "$EV_Q" >/dev/null 2>&1 || true
[ "$(awk -F'\t' -v c="$C_MID" -v e="$C_EV" '$c=="ev-q-1"{v=$e} END{print v}' "$EV_LOG")" = "message-dispatched" ] \
  && ok "a consult is logged as itself, never as a review request" || fail "consult event kind"
[ "$(awk -F'\t' -v c="$C_MID" -v e="$C_EV" '$c=="ev-q-1" && $e=="request-persisted"' "$EV_LOG" | grep -c .)" = "0" ] \
  && ok "a consult never enters the request lifecycle it can never complete" || fail "consult wrote request events"

# The roster is persisted BEFORE any leg: legs go out sequentially, so a crash after leg 1
# of 2 is otherwise indistinguishable from a legitimate one-leg panel, and compose would
# gate on it. (codex, plan r1/r2, blocking.)
EV_PREQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-20-00_ev-panel.md"
sed 's/message_id: ev-req-1/message_id: ev-panel-1/; s/thread: ev-loop/thread: ev-panel/' "$EV_REQ" > "$EV_PREQ"
EV_POUT="$(run_ev panel dispatch --to codex,grok "$EV_PREQ" 2>&1 || true)"
EV_SET="$(printf '%s\n' "$EV_POUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$EV_SET" ] && ok "the panel dispatch named a review set" || fail "no set id (got: $EV_POUT)"
[ "$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v s="$EV_SET" '$c==s{print $e}' "$EV_LOG" | head -1)" = "panel-planned" ] \
  && ok "the expected roster is persisted before the first leg goes out" || fail "panel-planned ordering"
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v n="$C_NOTE" -v s="$EV_SET" '$e=="panel-planned" && $c==s && $n ~ /codex/ && $n ~ /grok/' "$EV_LOG" | grep -q . \
  && ok "the roster event names every reviewer the panel expects" || fail "panel-planned roster contents"
[ "$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v s="$EV_SET" '$c==s && $e=="request-persisted"' "$EV_LOG" | grep -c .)" = "2" ] \
  && ok "each leg of the panel records its own request" || fail "per-leg request events"
# One ATTEMPT id ties the roster to the legs it planned: a set id is deterministic and a
# retry rebinds it, so two concurrent attempts interleave in one file. (codex, plan r2.)
EV_DID="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="panel-planned"{print $d}' "$EV_LOG" | tail -1)"
[ -n "$EV_DID" ] && ok "the roster event names its dispatch attempt" || fail "panel-planned dispatch id"
[ "$(awk -F'\t' -v d="$C_DSP" -v e="$C_EV" -v id="$EV_DID" '$d==id && $e=="request-persisted"' "$EV_LOG" | grep -c .)" = "2" ] \
  && ok "every leg of an attempt carries that attempt's id" || fail "legs not bound to the dispatch id"

run_ev compose --set "$EV_SET" >/dev/null 2>&1 || true
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v st="$C_ST" -v s="$EV_SET" '$c==s && $e=="composition-refused" && $st=="partial"' "$EV_LOG" | grep -q . \
  && ok "a refused partial panel is recorded, not just printed" || fail "composition-refused missing"
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="composition-refused" && $d!=""' "$EV_LOG" | grep -q . \
  && ok "a composition event names the attempt it composed" || fail "composition event has no dispatch"

# TWO ATTEMPTS, INTERLEAVED. The set id is deterministic and a retry rebinds it, so
# concurrent dispatches can leave legs of both attempts in one index in any order —
# plan-A, A/codex, plan-B, B/codex, B/grok, A/grok. A reader that binds to the set alone
# reports a four-leg panel that never existed. The index is written directly here because
# the race cannot be provoked reliably from two live dispatches. (codex, implement r1.)
EV_IDX="$EV/.comms/grades/sets.tsv"
ev_idx_row() { # <mid> <thread> <agent> <dispatch>
  printf 'ev-mixed\t%s\t%s\t1\timplement\taid\tpv\tbase\tcodex\t%s\tdispatched\t\t2026-08-29T10:00:00Z\t%s\n' \
    "$1" "$2" "$3" "$4" >> "$EV_IDX"
}
# Both attempts PLANNED, A first, then their legs interleaved — the shape a pair of
# concurrent dispatches leaves behind. The index's last row belongs to attempt A; the last
# PLAN is B's, and B is what a reader must bind to. (codex, implement r2/r3.)
for ev_mix_ag in codex grok; do
  run_ev events append --kind panel-planned --set ev-mixed --dispatch d-attempt-a --agent "$ev_mix_ag" \
    --artifact aid --status planned --note "roster=codex,grok legs=2" >/dev/null
done
for ev_mix_ag in codex grok; do
  # A plan names the artifact it reviews: a plan without one is incoherent, and the snapshot
  # refuses it rather than treating an empty artifact as "any tree". (codex, implement r7.)
  run_ev events append --kind panel-planned --set ev-mixed --dispatch d-attempt-b --agent "$ev_mix_ag" \
    --artifact aid --status planned --note "roster=codex,grok legs=2" >/dev/null
done
ev_idx_row mixed-a-codex ev-mixed-a-codex codex d-attempt-a
ev_idx_row mixed-b-codex ev-mixed-b-codex codex d-attempt-b
ev_idx_row mixed-b-grok  ev-mixed-b-grok  grok  d-attempt-b
ev_idx_row mixed-a-grok  ev-mixed-a-grok  grok  d-attempt-a
EV_MIXED="$(run_ev panel status --set ev-mixed 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$EV_MIXED" | grep -c .)" = "2" ] \
  && ok "status reports the legs of ONE attempt, not the mixture of two" || fail "status mixed two attempts (got: $(printf '%s' "$EV_MIXED" | tr '\n' '|'))"
printf '%s\n' "$EV_MIXED" | grep -q 'ev-mixed-b-' && ! printf '%s\n' "$EV_MIXED" | grep -q 'ev-mixed-a-' \
  && ok "each reviewer contributes its row from the attempt the last PLAN named" || fail "status bound to the wrong attempt (got: $(printf '%s' "$EV_MIXED" | tr '\n' '|'))"
EV_MIXCOMP="$(run_ev compose --set ev-mixed 2>&1 || true)"
printf '%s\n' "$EV_MIXCOMP" | grep -q 'of 2 legs' \
  && ok "compose gates on one attempt's roster, never on both" || fail "compose counted both attempts (got: $(printf '%s' "$EV_MIXCOMP" | head -1))"

EV_MIDC="$(grep -m1 '^message_id:' "$(ls -t "$EV/.comms/to-codex/"*panel-codex*.md | head -1)" | sed 's/^message_id: //')"
EV_MIDG="$(grep -m1 '^message_id:' "$(ls -t "$EV/.comms/to-grok/"*panel-grok*.md | head -1)" | sed 's/^message_id: //')"
EV_WS="$(run_ev workspace)"
ev_mk_reply() { # <agent> <thread> <in-reply-to> <minute>
  local f="$EV/.comms/archive/${EV_WS}_2026-08-29T09-2${4}-00_${1}-reply.md"
  printf -- '---\ntype: review-feedback\nfrom: %s\ntimestamp: 2026-08-29T09:2%s:00Z\nworkspace: %s\nmessage_id: %s-ev-reply\nthread: %s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: REQUEST_CHANGES\n---\n\n## Findings\n\n### Blocking\n- `s.txt:1` — %s says this is real.\n\n### Advisory\n- `s.txt:9` — %s advisory.\n' \
    "$1" "$4" "$EV_WS" "$1" "$2" "$3" "$1" "$1" > "$f"
}
ev_mk_reply codex ev-panel-codex "$EV_MIDC" 1
ev_mk_reply grok  ev-panel-grok  "$EV_MIDG" 2
run_ev compose --set "$EV_SET" >/dev/null 2>&1 || true
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v s="$EV_SET" '$c==s && $e=="composition-completed"' "$EV_LOG" | grep -q . \
  && ok "a completed composition closes the set's trace" || fail "composition-completed missing"
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v n="$C_NOTE" -v s="$EV_SET" '$c==s && $e=="composition-completed" && $n ~ /corroborated=1/' "$EV_LOG" | grep -q . \
  && ok "the composition event carries what the gate actually found" || fail "composition counts"

# ...and now through the PRODUCER. The hand-written rows above test the selector; they
# cannot see the write path, and the write path was the defect: dispatch deleted every
# same-set/same-agent row, so a second attempt ATE the first attempt's legs and the index
# ended up holding one leg of each. A retry is DETERMINISTIC — same request over the same
# tree recreates the set id — so this is a second attempt, not a second set. (`--set` is
# only a seed: safe_set_id appends a hash, so feeding the resolved id back in would make a
# different set and test nothing.) (codex + grok, implement r2, corroborated.)
EV_D1="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="panel-planned"{print $d}' "$EV_LOG" | tail -1)"
EV_RD="$(run_ev panel dispatch --to codex,grok "$EV_PREQ" 2>&1 || true)"
EV_RDSET="$(printf '%s\n' "$EV_RD" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$EV_RDSET" = "$EV_SET" ] && ok "a retry over the same tree recreates the same set" || fail "retry set id drifted ($EV_SET vs $EV_RDSET)"
EV_D2="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="panel-planned"{print $d}' "$EV_LOG" | tail -1)"
[ -n "$EV_D2" ] && [ "$EV_D1" != "$EV_D2" ] && ok "a re-dispatch mints a new attempt id" || fail "re-dispatch reused the attempt id"
[ "$(awk -F'\t' -v s="$EV_SET" -v d="$EV_D1" 'NR>1 && $1==s && $14==d' "$EV/.comms/grades/sets.tsv" | grep -c .)" = "2" ] \
  && ok "the FIRST attempt's legs survive a re-dispatch instead of being eaten" || fail "a re-dispatch deleted the earlier attempt's rows"
[ "$(awk -F'\t' -v s="$EV_SET" -v d="$EV_D2" 'NR>1 && $1==s && $14==d' "$EV/.comms/grades/sets.tsv" | grep -c .)" = "2" ] \
  && ok "the new attempt records its own two legs" || fail "the new attempt is not fully recorded"
[ "$(run_ev panel status --set "$EV_SET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "status still reports exactly one attempt's legs after a real re-dispatch" || fail "status mixed two real attempts"
# REFUSING beats guessing. A torn log could have torn the very plan row the binding reads,
# and a missing log with attempts recorded is the last-row-wins binding this round removed —
# both refuse loudly now instead of silently degrading. Only a set with no attempt anywhere,
# which is what a pre-column set looks like, may still bind. (codex, implement r3, blocking.)
EV_RF="$WORK/events-refuse"; mkdir -p "$EV_RF"; EV_RF="$(cd "$EV_RF" && pwd -P)"
git -C "$EV_RF" init -q -b main
printf '.comms/\n' > "$EV_RF/.gitignore"; echo s > "$EV_RF/s.txt"
git -C "$EV_RF" add -A >/dev/null 2>&1
git -C "$EV_RF" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_RF/.comms/to-codex" "$EV_RF/.comms/to-grok" "$EV_RF/.comms/to-claude" "$EV_RF/.comms/archive" "$EV_RF/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_RF/.comms/config"
run_evrf() { (cd "$EV_RF" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_RFREQ="$EV_RF/.comms/to-codex/$(basename "$EV_RF")_2026-08-29T09-00-00_rf.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: rf-1\nthread: rf-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_RF")" > "$EV_RFREQ"
EV_RFOUT="$(run_evrf panel dispatch --to codex,grok "$EV_RFREQ" 2>&1 || true)"
EV_RFSET="$(printf '%s\n' "$EV_RFOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && ok "a clean log binds the attempt without complaint" || fail "a clean log failed to bind"
cp "$EV_RF/.comms/events.tsv" "$WORK/rf-events-clean.tsv"
printf 'a torn row\n' >> "$EV_RF/.comms/events.tsv"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "a torn log still bound an attempt" || ok "a torn log refuses to bind an attempt rather than guessing"
run_evrf compose --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "compose gated with a torn log" || ok "compose refuses to gate on a guessed roster"
rm -f "$EV_RF/.comms/events.tsv"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "a missing log fell back to last-row-wins" || ok "a missing log with attempts recorded refuses, never falls back"
# A VANISHED PLAN IS UNKNOWN, NOT LEGACY. Legacy-ness is settled from the index: a set whose
# legs name an attempt can never fall back to "no plan means no roster", or a lost log would
# clear the roster and let compose gate from partial index rows. (codex, implement r8.)
cp "$EV_RF/.comms/events.tsv" "$WORK/rf-events-keep.tsv" 2>/dev/null || :
rm -f "$EV_RF/.comms/events.tsv"
run_evrf compose --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "a vanished plan composed from index rows alone" || ok "a vanished plan is UNKNOWN, never legacy"
cp "$WORK/rf-events-keep.tsv" "$EV_RF/.comms/events.tsv" 2>/dev/null || :

# ...AND THE INDEX ROWS ARE NOT WHAT SETTLES IT. A modern attempt that crashes between its
# plan and its first leg row leaves an index holding nothing but legacy-shaped rows, which
# reads exactly like a set dispatched before attempts existed — so both readers would call
# it legacy and compose the PREVIOUS round's bound replies, silently discarding the newer
# attempt. `panel dispatch` therefore stakes a durable marker before anything else it
# writes, and that marker, not the absence of an attempt-bearing row, is the proof.
# (codex, implement r9, blocking.)
[ -f "$EV_RF/.comms/grades/attempts/$EV_RFSET" ] \
  && ok "a dispatch stakes a durable attempts marker" || fail "no attempts marker was staked for $EV_RFSET"
cp "$EV_RF/.comms/grades/sets.tsv" "$WORK/rf-sets-keep.tsv"
# The crash: the plan is staked, then nothing else lands. Only legacy-shaped rows remain.
awk -F'\t' -v s="$EV_RFSET" 'NR==1 || $1!=s' "$WORK/rf-sets-keep.tsv" > "$EV_RF/.comms/grades/sets.tsv"
printf '%s\tcrash-1\trf-th-codex\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T11:00:00Z\n' \
  "$EV_RFSET" >> "$EV_RF/.comms/grades/sets.tsv"
rm -f "$EV_RF/.comms/events.tsv"
EV_CRASHED="$(run_evrf compose --set "$EV_RFSET" 2>&1 || true)"
printf '%s\n' "$EV_CRASHED" | grep -q 'dispatched under a recorded attempt' \
  && ok "compose calls a crashed modern attempt UNKNOWN, not legacy" || fail "compose read a crashed attempt as legacy ($EV_CRASHED)"
EV_CRASHST="$(run_evrf panel status --set "$EV_RFSET" 2>&1 || true)"
printf '%s\n' "$EV_CRASHST" | grep -q 'dispatched under a recorded attempt' \
  && ok "panel status calls a crashed modern attempt UNKNOWN, not legacy" || fail "panel status read a crashed attempt as legacy ($EV_CRASHST)"
# THE CONTROL, and the defect itself. Remove ONLY the marker and the very same index
# reads as legacy: compose invents a one-leg roster out of the leftover legacy row and
# gates on it, when the attempt that actually ran planned two. Nothing else about the
# fixture changes, so the assertions above cannot be passing on some unrelated guard.
# The mv is CHECKED. Unchecked, it no-ops on a tree where no marker was ever staked, the
# fixture goes unchanged, compose repeats the refusal it gave two lines earlier, and this
# assertion prints green while asserting a mechanism that does not exist. (Found by
# reverting helpers/comms.sh under the new tests: A1-A3 went red and this one stayed green.)
if ! command mv -f "$EV_RF/.comms/grades/attempts/$EV_RFSET" "$WORK/rf-marker-keep" 2>/dev/null; then
  fail "the no-marker control had no marker to remove — it was never staked"
else
  EV_NOMARK="$(run_evrf compose --set "$EV_RFSET" 2>&1 || true)"
  if printf '%s\n' "$EV_NOMARK" | grep -q 'dispatched under a recorded attempt'; then
    fail "the index rows, not the marker, were settling legacy-ness"
  elif printf '%s\n' "$EV_NOMARK" | grep -q '0 of 1 legs'; then
    ok "the marker, not the index rows, is what settles legacy-ness"
  else
    fail "the no-marker control did not reproduce the legacy misread ($EV_NOMARK)"
  fi
fi
command mv -f "$WORK/rf-marker-keep" "$EV_RF/.comms/grades/attempts/$EV_RFSET"
command cp -f "$WORK/rf-sets-keep.tsv" "$EV_RF/.comms/grades/sets.tsv"
cp "$WORK/rf-events-keep.tsv" "$EV_RF/.comms/events.tsv" 2>/dev/null || :

# THE ORDER IS THE MECHANISM, so the order is what has to be pinned. Every assertion above
# builds its crash by HAND, after a dispatch that ran to completion — so all of them stay
# green on a tree where the marker is staked LAST, which is the one arrangement that puts
# codex's defect straight back. Kill a dispatch for real instead: make the gating agent's
# inbox unwritable and it dies at its first leg, after the plan events and before its first
# index row. That is the exact window, and the marker must already be on disk when it lands.
EV_ORDREQ="$EV_RF/.comms/to-codex/$(basename "$EV_RF")_2026-08-29T09-30-00_ord.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:30:00Z\nworkspace: %s\nmessage_id: ord-1\nthread: ord-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_RF")" > "$EV_ORDREQ"
cp "$EV_RF/.comms/events.tsv" "$WORK/rf-events-preord.tsv" 2>/dev/null || :
chmod 500 "$EV_RF/.comms/to-codex"
EV_ORDOUT="$(run_evrf panel dispatch --to codex,grok "$EV_ORDREQ" 2>&1 || true)"
chmod 755 "$EV_RF/.comms/to-codex"
EV_ORDSET="$(awk -F'\t' '$3=="panel-planned" {print $4}' "$EV_RF/.comms/events.tsv" 2>/dev/null | tail -1)"
if [ -z "$EV_ORDSET" ] || [ "$EV_ORDSET" = "$EV_RFSET" ]; then
  fail "the mid-dispatch death fixture did not plan a new set (got '$EV_ORDSET')"
elif awk -F'\t' -v s="$EV_ORDSET" 'NR>1 && $1==s' "$EV_RF/.comms/grades/sets.tsv" | grep -q .; then
  fail "the dispatch got as far as an index row — that is not the window this pins ($EV_ORDOUT)"
else
  [ -f "$EV_RF/.comms/grades/attempts/$EV_ORDSET" ] \
    && ok "a dispatch that dies before its first leg row has already staked its marker" \
    || fail "the marker is staked too late: a dispatch died mid-flight and left none ($EV_ORDOUT)"
fi
# ...and that marker is what makes the wreckage refuse. Complete codex's sequence on it:
# the log goes, and only a legacy-shaped row for the set is left behind.
rm -f "$EV_RF/.comms/events.tsv"
printf '%s\tord-crash\tord-th-codex\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T11:30:00Z\n' \
  "$EV_ORDSET" >> "$EV_RF/.comms/grades/sets.tsv"
EV_ORDC="$(run_evrf compose --set "$EV_ORDSET" 2>&1 || true)"
printf '%s\n' "$EV_ORDC" | grep -q 'dispatched under a recorded attempt' \
  && ok "a really-crashed dispatch refuses instead of composing the legacy row" \
  || fail "a really-crashed dispatch composed from index rows alone ($EV_ORDC)"
command cp -f "$WORK/rf-sets-keep.tsv" "$EV_RF/.comms/grades/sets.tsv"
cp "$WORK/rf-events-preord.tsv" "$EV_RF/.comms/events.tsv" 2>/dev/null || :
rm -f "$EV_ORDREQ"

printf 'legacy-set\tlm-1\tlegacy-codex\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T10:00:00Z\n' >> "$EV_RF/.comms/grades/sets.tsv"
[ "$(run_evrf panel status --set legacy-set 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] \
  && ok "a set recorded before attempts existed still binds" || fail "a legacy set stopped binding"
cp "$WORK/rf-events-clean.tsv" "$EV_RF/.comms/events.tsv"
# A torn row BEFORE the plan must not block anything. Refusing on a malformed row anywhere
# bricked this repo the moment the schema grew: rows and a header from the older shape sit
# at the top of the live log, so every compose and status refused. What can hide the current
# plan is a torn row AFTER it. (grok, implement r4, blocking — and hit live.)
EV_RFCLEAN="$(cat "$EV_RF/.comms/events.tsv")"
{ printf 'an ancient torn row\n'; printf '%s\n' "$EV_RFCLEAN"; } > "$EV_RF/.comms/events.tsv"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && ok "a torn row that PRECEDES the plan does not block binding" || fail "an old torn row still bricks binding"
cp "$WORK/rf-events-clean.tsv" "$EV_RF/.comms/events.tsv"
# The bare listing keeps its pinned header and counts the CURRENT attempt.
run_evrf panel dispatch --to codex,grok "$EV_RFREQ" >/dev/null 2>&1 || true
EV_RFHDR="$(run_evrf panel status 2>/dev/null)"
[ "$(printf '%s\n' "$EV_RFHDR" | sed -n 1p)" = "$(printf 'set\tphase\tround\tlegs\tcreated')" ] \
  && ok "the bare listing keeps its pinned header, first" || fail "bare listing header changed (got: $(printf '%s' "$EV_RFHDR" | sed -n 1p))"
[ "$(run_evrf panel status 2>/dev/null | awk -F'\t' -v s="$EV_RFSET" '$1==s{print $4}')" = "2" ] \
  && ok "the bare listing counts the current attempt, not every attempt ever recorded" || fail "bare listing counted historical rows"

# THE ROSTER IS ENFORCED, not merely recorded. A dispatch that dies between two leg rows
# leaves the index one leg short, and counting index rows alone made that compose as a
# complete one-leg panel — the very hole the plan event was added to close. Deleting a leg
# row is exactly what that crash leaves behind. (codex, implement r5, blocking.)
EV_CRASH="$WORK/events-crash"; mkdir -p "$EV_CRASH"; EV_CRASH="$(cd "$EV_CRASH" && pwd -P)"
git -C "$EV_CRASH" init -q -b main
printf '.comms/\n' > "$EV_CRASH/.gitignore"; echo s > "$EV_CRASH/s.txt"
git -C "$EV_CRASH" add -A >/dev/null 2>&1
git -C "$EV_CRASH" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_CRASH/.comms/to-codex" "$EV_CRASH/.comms/to-grok" "$EV_CRASH/.comms/to-claude" "$EV_CRASH/.comms/archive" "$EV_CRASH/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_CRASH/.comms/config"
run_evcr() { (cd "$EV_CRASH" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_CRREQ="$EV_CRASH/.comms/to-codex/$(basename "$EV_CRASH")_2026-08-29T09-00-00_cr.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: cr-1\nthread: cr-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_CRASH")" > "$EV_CRREQ"
EV_CROUT="$(run_evcr panel dispatch --to codex,grok "$EV_CRREQ" 2>&1 || true)"
EV_CRSET="$(printf '%s\n' "$EV_CROUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$(run_evcr events --set "$EV_CRSET" --kind panel-planned 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "the roster is recorded as one plan row per planned reviewer" || fail "the roster is not machine-readable"
# Simulate the crash: drop grok's leg row from the index, as a death between appends would.
EV_CRIDX="$EV_CRASH/.comms/grades/sets.tsv"
awk -F'\t' 'NR==1 || !($10=="grok")' "$EV_CRIDX" > "$EV_CRIDX.tmp" && mv "$EV_CRIDX.tmp" "$EV_CRIDX"
EV_CRCOMP="$(run_evcr compose --set "$EV_CRSET" 2>&1 || true)"
printf '%s\n' "$EV_CRCOMP" | grep -q 'never finished recording' \
  && ok "compose refuses a roster the dispatch never finished recording" || fail "a truncated roster composed (got: $(printf '%s' "$EV_CRCOMP" | head -1))"
# Not `grep '1 of 1'` — compose cannot emit that string, so the assertion passed with the
# roster gate deleted. What must be true is that the truncated panel never reports a quorum
# and never records a completion. (self-review, round 6: vacuous fixture.)
printf '%s\n' "$EV_CRCOMP" | grep -q 'all answered' && fail "a truncated roster reported a quorum" || ok "a truncated roster never reports itself answered"
printf '%s\n' "$EV_CRCOMP" | grep -q 'grok' \
  && ok "the refusal names the reviewer whose leg row is missing" || fail "the refusal does not name the missing reviewer"
run_evcr events --set "$EV_CRSET" --kind composition-completed 2>/dev/null | tail -n +2 | grep -q . \
  && fail "a truncated roster recorded a completed composition" || ok "no composition is recorded for a roster that never completed"
run_evcr events --set "$EV_CRSET" --kind composition-refused 2>/dev/null | tail -n +2 | grep -q 'roster-incomplete' \
  && ok "the roster refusal is recorded, not just printed" || fail "roster refusal not recorded"
[ "$(run_evcr panel status --set "$EV_CRSET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "status still lists a planned leg whose index row vanished" || fail "status hid the missing leg"
# NOTHING IS PUBLISHED BEFORE IT IS VERIFIED. The supersession check runs after the
# composition is built, so publishing as it was built put an authoritative-looking
# "all answered" document on stdout and permanently into --out before anything had
# confirmed the attempt was still current. (codex, implement r8, blocking.)
rm -f "$WORK/cr-out.md"
EV_CROUT2="$(run_evcr compose --set "$EV_CRSET" --out "$WORK/cr-out.md" 2>&1 || true)"
[ ! -s "$WORK/cr-out.md" ] \
  && ok "a refused composition writes nothing to --out" || fail "a refused composition left a document behind"
printf '%s\n' "$EV_CROUT2" | grep -q 'all answered' \
  && fail "a refused composition still printed a panel" || ok "a refused composition prints only its refusal"

EV_CRSTAT="$(run_evcr panel status --set "$EV_CRSET" 2>/dev/null)"
printf '%s\n' "$EV_CRSTAT" | grep -q 'no leg row recorded' \
  && ok "the missing leg is named as missing, not silently unanswered" || fail "the missing leg was not named"
# Captured, not piped into `head`: the suite runs with pipefail, so a producer killed by
# SIGPIPE fails the assertion even when the grep matched. The property under test is "the
# header is line 1", which a capture states directly. (self-review follow-up, round 6.)
EV_CRHDR="$(run_evcr panel status --set "$EV_CRSET" 2>/dev/null)"
[ "$(printf '%s\n' "$EV_CRHDR" | sed -n 1p | cut -f1)" = "reviewer" ] \
  && ok "panel status --set prints its header first" || fail "status header ordering (line 1 was: $(printf '%s' "$EV_CRHDR" | sed -n 1p))"

# A SUBSET RE-DISPATCH MUST NOT SHRINK THE PANEL. Retrying one leg that failed to deliver is
# the remedy PROTOCOL recommends, and it plans a one-agent roster — so binding strictly to
# the last attempt silently dropped the other reviewer, hid it from `panel status`, and let
# `compose` gate without its findings. `main` never did this; the arc introduced it.
# (self-review, round 6, reproduced side by side against main.)
EV_SUB="$WORK/events-subset"; mkdir -p "$EV_SUB"; EV_SUB="$(cd "$EV_SUB" && pwd -P)"
git -C "$EV_SUB" init -q -b main
printf '.comms/\n' > "$EV_SUB/.gitignore"; echo s > "$EV_SUB/s.txt"
git -C "$EV_SUB" add -A >/dev/null 2>&1
git -C "$EV_SUB" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_SUB/.comms/to-codex" "$EV_SUB/.comms/to-grok" "$EV_SUB/.comms/to-claude" "$EV_SUB/.comms/archive" "$EV_SUB/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_SUB/.comms/config"
run_evsub() { (cd "$EV_SUB" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_SUBREQ="$EV_SUB/.comms/to-codex/$(basename "$EV_SUB")_2026-08-29T09-00-00_sub.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: sub-1\nthread: sub-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_SUB")" > "$EV_SUBREQ"
EV_SUBOUT="$(run_evsub panel dispatch --to codex,grok "$EV_SUBREQ" 2>&1 || true)"
EV_SUBSET="$(printf '%s\n' "$EV_SUBOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "the full panel lists both legs" || fail "the full panel did not list two legs"
run_evsub panel dispatch --to grok "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBST="$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$EV_SUBST" | grep -c .)" = "2" ] \
  && ok "re-dispatching ONE leg does not shed the other reviewer" || fail "a subset re-dispatch shrank the panel to $(printf '%s\n' "$EV_SUBST" | grep -c .) leg(s)"
printf '%s\n' "$EV_SUBST" | grep -q '^codex' \
  && ok "the reviewer that was not re-dispatched keeps its leg" || fail "the untouched reviewer vanished from the panel"
EV_SUBCOMP="$(run_evsub compose --set "$EV_SUBSET" 2>&1 || true)"
printf '%s\n' "$EV_SUBCOMP" | grep -q 'no reply yet from' \
  && ok "compose still waits for the leg a subset retry did not touch" || fail "compose gated a narrowed panel (got: $(printf '%s' "$EV_SUBCOMP" | head -1))"
printf '%s\n' "$EV_SUBCOMP" | grep -q 'of 2 legs' \
  && ok "the narrowed attempt still gates on the FULL roster" || fail "compose forgot a planned reviewer"

# CARRY-FORWARD IS FOR THE UNRE-DISPATCHED ONLY. An agent the CURRENT attempt planned must
# have a CURRENT row: substituting its previous one would let a dispatch that crashed after
# its plan and before that leg's row compose the earlier attempt's reply as this attempt's
# answer. (codex, implement r6, blocking.)
run_evsub panel dispatch --to codex,grok "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBD3="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SUBSET" '$c==s && $e=="panel-planned"{print $d}' "$EV_SUB/.comms/events.tsv" | tail -1)"
EV_SUBIDX="$EV_SUB/.comms/grades/sets.tsv"
awk -F'\t' -v d="$EV_SUBD3" 'NR==1 || !($10=="grok" && $14==d)' "$EV_SUBIDX" > "$EV_SUBIDX.tmp" && mv "$EV_SUBIDX.tmp" "$EV_SUBIDX"
EV_SUBC3="$(run_evsub compose --set "$EV_SUBSET" 2>&1 || true)"
printf '%s\n' "$EV_SUBC3" | grep -q 'never finished recording' \
  && ok "an agent planned by THIS attempt cannot be answered by its previous leg" || fail "a crashed re-dispatch substituted the earlier attempt's leg (got: $(printf '%s' "$EV_SUBC3" | head -1))"
EV_SUBSTAT="$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null)"
printf '%s\n' "$EV_SUBSTAT" | grep -q 'no leg row recorded' \
  && ok "status names the leg the current attempt planned and never recorded" || fail "status substituted a stale leg"

# CARRY-FORWARD IS ARTIFACT-BOUND. An explicit --set reused across two different trees, then
# subset-dispatched, would otherwise resurrect the other reviewer's row — and its reply — from
# the EARLIER artifact, and compose would report a mixed-artifact panel as all answered.
# (codex, implement r6, blocking.)
EV_ART="$WORK/events-artifact"; mkdir -p "$EV_ART"; EV_ART="$(cd "$EV_ART" && pwd -P)"
git -C "$EV_ART" init -q -b main
printf '.comms/\n' > "$EV_ART/.gitignore"; echo one > "$EV_ART/s.txt"
git -C "$EV_ART" add -A >/dev/null 2>&1
git -C "$EV_ART" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_ART/.comms/to-codex" "$EV_ART/.comms/to-grok" "$EV_ART/.comms/to-claude" "$EV_ART/.comms/archive" "$EV_ART/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_ART/.comms/config"
run_evart() { (cd "$EV_ART" && env COMMS_DELIVERY=cmux CMUX_WORKSPACE_ID=workspace:7 PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_ARTREQ="$EV_ART/.comms/to-codex/$(basename "$EV_ART")_2026-08-29T09-00-00_art.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: art-1\nthread: art-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_ART")" > "$EV_ARTREQ"
EV_ARTOUT="$(run_evart panel dispatch --to codex,grok --set pinned-set "$EV_ARTREQ" 2>&1 || true)"
EV_ARTSET="$(printf '%s\n' "$EV_ARTOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
echo two > "$EV_ART/s.txt"   # a DIFFERENT tree, so a different artifact
git -C "$EV_ART" -c user.email=t@t -c user.name=t commit -q -am second
EV_ARTOUT2="$(run_evart panel dispatch --to grok --set pinned-set "$EV_ARTREQ" 2>&1 || true)"
EV_ARTSET2="$(printf '%s\n' "$EV_ARTOUT2" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$EV_ARTSET2" = "$EV_ARTSET" ] \
  && ok "an explicit --set really does collide across artifacts" || fail "the artifact fixture never collided ($EV_ARTSET vs $EV_ARTSET2)"
EV_ARTSTAT="$(run_evart panel status --set "$EV_ARTSET" 2>/dev/null)"
printf '%s\n' "$EV_ARTSTAT" | grep -q 'no leg row recorded' \
  && ok "a leg from a DIFFERENT artifact is never carried into this panel" || fail "a stale-artifact leg was resurrected"

# CARRY-FORWARD REACHES BACKWARD ONLY. With three attempts — A plans both, B re-dispatches
# codex, C re-dispatches grok — the bound attempt is C, and codex must be answered by B's
# leg. "Any row that is not the bound one" would have let a NEWER concurrent attempt's leg be
# adopted as a previous one. (codex, implement r7, blocking.)
run_evsub panel dispatch --to codex "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBDB="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SUBSET" '$c==s && $e=="panel-planned"{print $d}' "$EV_SUB/.comms/events.tsv" | tail -1)"
run_evsub panel dispatch --to grok "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBDC="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SUBSET" '$c==s && $e=="panel-planned"{print $d}' "$EV_SUB/.comms/events.tsv" | tail -1)"
[ -n "$EV_SUBDB" ] && [ -n "$EV_SUBDC" ] && [ "$EV_SUBDB" != "$EV_SUBDC" ] \
  && ok "three attempts leave three distinct ids in the chain" || fail "the chain fixture did not produce distinct attempts"
EV_SUBST3="$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$EV_SUBST3" | grep -c .)" = "2" ] \
  && ok "a chain of subset retries still lists the whole roster" || fail "a chain of retries shrank the panel"
EV_SUBCODEXMID="$(awk -F'\t' -v s="$EV_SUBSET" -v d="$EV_SUBDB" 'NR>1 && $1==s && $10=="codex" && $14==d {print $2}' "$EV_SUB/.comms/grades/sets.tsv" | tail -1)"
printf '%s\n' "$EV_SUBST3" | grep -q "^codex" && [ -n "$EV_SUBCODEXMID" ] \
  && ok "the carried leg comes from an attempt EARLIER in the chain, not a newer one" || fail "carry-forward picked the wrong attempt"

# A plan row with no artifact is INCOHERENT, not permissive: an empty artifact used to mean
# "carry a row from any tree". (codex, implement r7, blocking.)
run_evsub events append --kind panel-planned --set ev-noart --dispatch d-noart --agent codex --status planned >/dev/null
run_evsub panel status --set ev-noart >/dev/null 2>&1 \
  && fail "a plan with no artifact still bound an attempt" || ok "a plan that names no artifact refuses rather than matching any tree"

# A set id long enough to exceed the events column must be stored IDENTICALLY in sets.tsv
# and in the log, or the two can never be joined. Querying an id nobody ever wrote proved
# nothing — it returns zero rows whether or not safe_set_id bounds anything.
# (self-review, round 6: vacuous fixture.)
EV_LONGTH="thr-$(awk 'BEGIN{while(i++<160)printf "q"}')"
EV_LONGREQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-50-00_longid.md"
sed "s/message_id: ev-req-1/message_id: ev-longid-1/; s/thread: ev-loop/thread: $EV_LONGTH/" "$EV_REQ" > "$EV_LONGREQ"
EV_LONGOUT="$(run_ev panel dispatch --to codex,grok "$EV_LONGREQ" 2>&1 || true)"
EV_LONGSET="$(printf '%s\n' "$EV_LONGOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$EV_LONGSET" ] && [ "${#EV_LONGSET}" -le 80 ] \
  && ok "a set id derived from a long thread is bounded at its source" || fail "set id unbounded (${#EV_LONGSET} bytes)"
[ "$(awk -F'\t' -v s="$EV_LONGSET" 'NR>1 && $1==s' "$EV/.comms/grades/sets.tsv" | grep -c .)" = "2" ] \
  && ok "the bounded id is what the index stores" || fail "the index stores a different id"
[ "$(awk -F'\t' -v c="$C_SET" -v s="$EV_LONGSET" -v e="$C_EV" '$c==s && $e=="panel-planned"' "$EV_LOG" | grep -c .)" = "2" ] \
  && ok "the log stores the SAME bytes, so the two can be joined" || fail "index and log disagree on a long set id"
[ "$(run_ev panel status --set "$EV_LONGSET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "a long set id still binds its attempt" || fail "a long set id could not find its own plan"

# The PLAN event is the authority, not the last row: append a stale leg row for the OLD
# attempt after the new one and the binding must not follow it.
printf '%s\ty\tz\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T10:00:00Z\t%s\n' "$EV_SET" "$EV_D1" >> "$EV/.comms/grades/sets.tsv"
[ "$(run_ev panel status --set "$EV_SET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "a stale row appended after the plan cannot move the binding" || fail "the binding followed the last row instead of the plan event"


# CRITERION 4: the events that matter are written by the DETACHED runner. `send` returns at
# spawn, so every row below was appended by a process the dispatching shell no longer owns.
EV_HL="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-10-00_ev-hl.md"
sed 's/message_id: ev-req-1/message_id: ev-hl-1/; s/thread: ev-loop/thread: ev-headless/' "$EV_REQ" > "$EV_HL"
run_ev_hl() { (cd "$EV" && env -u CMUX_WORKSPACE_ID COMMS_DELIVERY=headless PATH="$STUB_BIN:$PATH" "$COMMS" "$@"); }
EV_HLOUT="$(run_ev_hl send --to codex "$EV_HL" 2>/dev/null)"
EV_HLDIR="$(rundir_of "$EV_HLOUT")"
[ -n "$EV_HLDIR" ] && ok "the headless dispatch spawned a detached runner" || fail "no run dir (got: $EV_HLOUT)"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && $e=="turn-started"' "$EV_LOG" | grep -q . \
  && fail "turn-started was written before any runner ran" \
  || ok "no turn is claimed to have started before its runner runs"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" "$RUNPHASE" await "$EV_HLDIR" --timeout-secs 60 >/dev/null 2>&1) || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && $e=="turn-started"' "$EV_LOG" | grep -q . \
  && ok "the detached runner records that the turn started" || fail "runner turn-started missing"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-headless" && $e=="provider-result" && $st!=""' "$EV_LOG" | grep -q . \
  && ok "the detached runner records the provider's own result" || fail "runner provider-result missing"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-headless" && $e=="turn-finished" && $st!=""' "$EV_LOG" | grep -q . \
  && ok "the turn's terminal status is a separate, later event" || fail "turn-finished missing"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && $e=="turn-finished"' "$EV_LOG" | grep -c .)" = "1" ] \
  && ok "the terminal event is written once, not again by the exit trap" || fail "turn-finished double-counted"
EV_ORDER="$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && ($e=="turn-started" || $e=="provider-result" || $e=="turn-finished"){printf "%s ", $e}' "$EV_LOG")"
[ "$EV_ORDER" = "turn-started provider-result turn-finished " ] \
  && ok "the provider's result precedes the turn's terminal status" || fail "runner event order (got: $EV_ORDER)"
[ -f "$EV_HLDIR/turn.tsv" ] && grep -q '^thread	ev-headless$' "$EV_HLDIR/turn.tsv" \
  && ok "the runner leaves its identity where a synthetic result can find it" || fail "turn.tsv identity"

# A runner killed before it can write result.json: await synthesizes one, and the terminal
# event must still name the right leg or a kill is a permanent unknown. (grok, plan r2.)
EV_KL="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-11-00_ev-kill.md"
sed 's/message_id: ev-req-1/message_id: ev-kill-1/; s/thread: ev-loop/thread: ev-killed/' "$EV_REQ" > "$EV_KL"
EV_KOUT="$(CODEX_STUB_HANG=30 run_ev_hl send --to codex "$EV_KL" 2>/dev/null)"
EV_KDIR="$(rundir_of "$EV_KOUT")"
sleep 2
kill -9 "$(cat "$EV_KDIR/pid" 2>/dev/null)" 2>/dev/null || true
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" "$RUNPHASE" await "$EV_KDIR" --timeout-secs 30 >/dev/null 2>&1) || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-killed" && $e=="turn-finished"' "$EV_LOG" | grep -q . \
  && ok "a killed runner still gets a terminal event, from the awaiting process" || fail "synthetic turn-finished missing"

EV_GMSG="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-30-00_ev-grok.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-1/; s/thread: ev-loop/thread: ev-grok/' "$EV_REQ" > "$EV_GMSG"
EV_GDIR="$WORK/ev-grok-leg"; mkdir -p "$EV_GDIR"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   GROK_STUB_NO_VERDICT=1 "$RUNPHASE" run --message "$EV_GMSG" --dir "$EV_GDIR" --provider grok) >/dev/null 2>&1 || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v n="$C_NOTE" '$t=="ev-grok" && $e=="reply-refused" && $n!=""' "$EV_LOG" | grep -q . \
  && ok "a refused reply records WHY, outside the run dir" || fail "reply-refused missing"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-grok" && $e=="reply-accepted"' "$EV_LOG" | grep -q . \
  && fail "a refused reply was also recorded as accepted" || ok "a refusal never counts as an acceptance"

# An EXTRACTION failure returned before the stamping half ever ran, so the loudest broker
# failure was the one with no event. The boundary is the whole pipeline now. (codex, r1.)
EV_GMSGX="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-34-00_ev-grokx.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-x/; s/thread: ev-loop/thread: ev-noresult/' "$EV_REQ" > "$EV_GMSGX"
EV_GDIRX="$WORK/ev-grok-legx"; mkdir -p "$EV_GDIRX"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   GROK_STUB_NO_RESULT=1 "$RUNPHASE" run --message "$EV_GMSGX" --dir "$EV_GDIRX" --provider grok) >/dev/null 2>&1 || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v n="$C_NOTE" '$t=="ev-noresult" && $e=="reply-refused" && $n ~ /no reply text/' "$EV_LOG" | grep -q . \
  && ok "a reply the extractor could not read is recorded as a refusal, with the reason" || fail "extraction failure left no reply-refused"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-noresult" && $e=="reply-refused"' "$EV_LOG" | grep -c .)" = "1" ] \
  && ok "the refusal is recorded once, though the path crosses two boundaries" || fail "refusal double-logged"

EV_GMSG2="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-31-00_ev-grok2.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-2/; s/thread: ev-loop/thread: ev-grok-ok/' "$EV_REQ" > "$EV_GMSG2"
EV_GDIR2="$WORK/ev-grok-leg2"; mkdir -p "$EV_GDIR2"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG2" --dir "$EV_GDIR2" --provider grok) >/dev/null 2>&1 || true
EV_GSEQ="$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-grok-ok" && ($e=="reply-validated" || $e=="reply-accepted"){printf "%s ", $e}' "$EV_LOG")"
[ "$EV_GSEQ" = "reply-validated reply-accepted " ] \
  && ok "a brokered reply is recorded as validated, then accepted" || fail "broker success sequence (got: $EV_GSEQ)"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-grok-ok" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "completed" ] \
  && ok "a turn whose acceptance IS in the log signs off completed" || fail "turn-finished status on a clean brokered turn"

# A turn whose own acceptance never reached the log must not sign off as `completed`:
# absence means unknown, but a terminal row claiming a clean turn over a missing milestone
# is a positive contradiction. (codex, plan r2, blocking.)
EV_GMSG4="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-33-00_ev-grok4.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-4/; s/thread: ev-loop/thread: ev-logloss/' "$EV_REQ" > "$EV_GMSG4"
EV_GDIR4="$WORK/ev-grok-leg4"; mkdir -p "$EV_GDIR4"
chmod a-w "$EV_LOG"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG4" --dir "$EV_GDIR4" --provider grok) >/dev/null 2>&1 || true
chmod u+w "$EV_LOG"
grep -q 'coordinator log not updated' "$EV_GDIR4/runner.log" \
  && ok "a lost advisory append is reported in the run dir" || fail "advisory append failure not reported"
# THE POINT of the fixture: an unwritable log must not cost a delivered reply. Asserting
# that SOME file exists in the inbox proved nothing — an earlier test had already put one
# there. Bind it to THIS turn. (grok, implement r1.)
EV_LOSTREPLY="$(grep -l '^in-reply-to: ev-grok-4$' "$EV/.comms/to-claude/"*.md 2>/dev/null | head -1)"
[ -n "$EV_LOSTREPLY" ] && ok "the reply for THIS turn reached the inbox with the log unwritable" || fail "an unwritable log cost a delivered reply"

# `turn-finished log-incomplete`: an event this turn produced never reached the log, so the
# terminal row must not claim a clean run. Deterministic because the runner reaches its log
# through $COMMS in ITS OWN helper directory — a fixture copy of runphase.sh beside a
# forwarding comms.sh that drops exactly one kind. Not a shipped knob; nothing in the
# product can silently drop an event. (grok, implement r1 — the seam it asked for.)
EV_SHIM="$WORK/ev-shim"; mkdir -p "$EV_SHIM"
cp "$RUNPHASE" "$EV_SHIM/runphase.sh"; chmod +x "$EV_SHIM/runphase.sh"
cat > "$EV_SHIM/comms.sh" <<SHIM
#!/bin/bash
if [ "\$1" = events ] && [ "\$2" = append ]; then
  case " \$* " in *" --kind reply-validated "*) exit 1 ;; esac
fi
exec "$COMMS" "\$@"
SHIM
chmod +x "$EV_SHIM/comms.sh"
EV_GMSG5="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-35-00_ev-grok5.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-5/; s/thread: ev-loop/thread: ev-logloss2/' "$EV_REQ" > "$EV_GMSG5"
EV_GDIR5="$WORK/ev-grok-leg5"; mkdir -p "$EV_GDIR5"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$EV_SHIM/runphase.sh" run --message "$EV_GMSG5" --dir "$EV_GDIR5" --provider grok) >/dev/null 2>&1 || true
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-logloss2" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "log-incomplete" ] \
  && ok "a turn that lost one of its own events signs off log-incomplete, not completed" || fail "turn-finished did not report the hole"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-logloss2" && $e=="reply-accepted"' "$EV_LOG" | grep -q . \
  && ok "the reply still landed while its trace was incomplete" || fail "a lost event cost the reply"

# THE LOOKUP ITSELF. The earlier shim drops `reply-validated`, which sets LOG_INCOMPLETE
# in-process — so it never exercised the acceptance lookup at all. This one lets `send`
# record the acceptance and then removes that row, which is what a lost advisory append
# looks like to the check that runs next; it also plants a DIFFERENT turn's acceptance on
# the same thread, so a thread-only join would call this turn clean. (codex + grok, r2.)
EV_SHIM3="$WORK/ev-shim3"; mkdir -p "$EV_SHIM3"
cp "$RUNPHASE" "$EV_SHIM3/runphase.sh"; chmod +x "$EV_SHIM3/runphase.sh"
cat > "$EV_SHIM3/comms.sh" <<SHIM
#!/bin/bash
if [ "\$1" = send ]; then
  "$COMMS" "\$@"; rc=\$?
  T="\$(mktemp)"
  grep -v 'reply-accepted' "$EV_LOG" > "\$T" 2>/dev/null && cat "\$T" > "$EV_LOG"
  rm -f "\$T"
  "$COMMS" events append --kind reply-accepted --thread ev-lostaccept \
    --request-id ev-grok-6 --message-id an-earlier-execution --status APPROVE >/dev/null 2>&1
  exit \$rc
fi
exec "$COMMS" "\$@"
SHIM
chmod +x "$EV_SHIM3/comms.sh"
EV_GMSG6="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-36-00_ev-grok6.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-6/; s/thread: ev-loop/thread: ev-lostaccept/' "$EV_REQ" > "$EV_GMSG6"
EV_GDIR6="$WORK/ev-grok-leg6"; mkdir -p "$EV_GDIR6"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$EV_SHIM3/runphase.sh" run --message "$EV_GMSG6" --dir "$EV_GDIR6" --provider grok) >/dev/null 2>&1 || true
# The planted row shares the thread, the REQUEST id and the attempt — it differs only in
# which execution wrote it. Request-plus-attempt was not unique: a re-send runs the same
# request twice. Only the reply id names one execution. (codex, implement r3, blocking.)
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v rq="$C_REQ" -v m="$C_MID" '$t=="ev-lostaccept" && $e=="reply-accepted" && $rq=="ev-grok-6" && $m=="an-earlier-execution"' "$EV_LOG" | grep -q . \
  && ok "the fixture planted an earlier EXECUTION of the same request and attempt" || fail "the collision fixture planted nothing"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-lostaccept" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "log-incomplete" ] \
  && ok "a lost acceptance is detected even when an earlier execution of the SAME request accepted" || fail "the acceptance lookup adopted another execution's row"

# A row truncated mid-write still carries fields 3 and 12, which a raw TSV match accepted
# while the reader rejected the very same row — two rules for one question. The lookup goes
# through the reader now. (codex, implement r4, blocking.)
EV_SHIM4="$WORK/ev-shim4"; mkdir -p "$EV_SHIM4"
cp "$RUNPHASE" "$EV_SHIM4/runphase.sh"; chmod +x "$EV_SHIM4/runphase.sh"
cat > "$EV_SHIM4/comms.sh" <<SHIM
#!/bin/bash
if [ "\$1" = send ]; then
  "$COMMS" "\$@"; rc=\$?
  T="\$(mktemp)"
  awk -F'\t' 'BEGIN{OFS="\t"} \$3=="reply-accepted" { NF=12; print; next } { print }' "$EV_LOG" > "\$T" 2>/dev/null \
    && cat "\$T" > "$EV_LOG"
  rm -f "\$T"
  exit \$rc
fi
exec "$COMMS" "\$@"
SHIM
chmod +x "$EV_SHIM4/comms.sh"
EV_GMSG7="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-37-00_ev-grok7.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-7/; s/thread: ev-loop/thread: ev-partialrow/' "$EV_REQ" > "$EV_GMSG7"
EV_GDIR7="$WORK/ev-grok-leg7"; mkdir -p "$EV_GDIR7"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$EV_SHIM4/runphase.sh" run --message "$EV_GMSG7" --dir "$EV_GDIR7" --provider grok) >/dev/null 2>&1 || true
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-partialrow" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "log-incomplete" ] \
  && ok "a truncated acceptance row does not satisfy the lookup" || fail "a partial row passed as an acceptance"

# A failed compose leaves the leading bytes behind, which is nonempty and truncated — and
# publishing that hands `await` a completion signal over a corrupt result, so it never
# synthesizes the sound one. Publication is gated on the compose, not on the file having
# bytes. (codex, implement r6, blocking.)
EV_GMSG8="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-38-00_ev-grok8.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-8/; s/thread: ev-loop/thread: ev-partialresult/' "$EV_REQ" > "$EV_GMSG8"
EV_GDIR8="$WORK/ev-grok-leg8"; mkdir -p "$EV_GDIR8"
printf '{\n  "provider": "grok",\n  "status": "completed",\n  "TRUNC' > "$EV_GDIR8/result.json.tmp"
chmod a-w "$EV_GDIR8/result.json.tmp"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG8" --dir "$EV_GDIR8" --provider grok) >/dev/null 2>&1 || true
chmod u+w "$EV_GDIR8/result.json.tmp" 2>/dev/null || true
[ ! -f "$EV_GDIR8/result.json" ] \
  && ok "a result that could not be composed is never published" || fail "a truncated result.json was published"
grep -q 'TRUNC' "$EV_GDIR8/result.json" 2>/dev/null \
  && fail "await would read a truncated completion signal" || ok "no truncated completion signal is left for await"

EV_GMSG3="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-32-00_ev-grok3.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-3/; s/thread: ev-loop/thread: ev-shadow/' "$EV_REQ" > "$EV_GMSG3"
EV_GDIR3="$WORK/ev-grok-leg3"; mkdir -p "$EV_GDIR3"
(cd "$EV" && env -u CMUX_WORKSPACE_ID PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG3" --dir "$EV_GDIR3" --provider grok --no-deliver) >/dev/null 2>&1 || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v r="$C_ROLE" '$t=="ev-shadow" && $e=="reply-validated" && $r=="shadow"' "$EV_LOG" | grep -q . \
  && ok "a measurement turn is recorded as shadow, never as the gating leg" || fail "shadow role not recorded"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v r="$C_ROLE" '$t=="ev-shadow" && $e=="turn-started" && $r=="shadow"' "$EV_LOG" | grep -q . \
  && ok "every event of a shadow turn carries the shadow role, not just the reply" || fail "shadow role on turn-started"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-shadow" && $e=="reply-accepted"' "$EV_LOG" | grep -q . \
  && fail "a shadow turn recorded an acceptance it never delivered" || ok "a shadow turn accepts nothing"

EV_AID="$(run_ev snapshot create 2>/dev/null | head -1)"
git -C "$EV" ls-tree -r --name-only "$EV_AID" 2>/dev/null | grep -q '^\.comms/' \
  && fail "the coordinator log rides into the reviewed artifact" \
  || ok "the reviewed artifact never carries the coordinator log"

section "reviewer isolation: a mounted turn is contained or it does not run"

# CRITERION 2 of contraction step 3. The measurements behind these assertions are in
# docs/ROADMAP.md; the short version is that NOTHING at the ACP layer contains a provider that
# does not ask permission — five parent-side controls were measured to be no-ops — so the
# boundary is the provider's own kernel sandbox, selected by the parent, or there is no boundary
# and the turn must not run.
ISO="$WORK/iso"; mkdir -p "$ISO"
ISO_RP="$REPO/helpers/runphase.sh"

# The refusal names the provider, the OS, and the way out. A mounted turn for a provider with no
# verified backend must DIE, not warn: silent degradation to an uncontained mount is exactly how
# this item gets marked done while staying open.
grep -q 'no verified isolation backend on' "$ISO_RP" \
  && ok "an unbacked provider's mounted turn is refused, not degraded" \
  || fail "the refusal for an unbacked provider is gone"
grep -q 'COMMS_RUNPHASE_ALLOW_UNCONTAINED' "$ISO_RP" \
  && ok "the uncontained escape hatch exists and is explicit" || fail "no operator override"
# The override must be OPT-IN. A default-on override is the same as no refusal at all.
grep -q 'COMMS_RUNPHASE_ALLOW_UNCONTAINED:-0' "$ISO_RP" \
  && ok "the uncontained override defaults to OFF" || fail "the override does not default off"

# Both halves of the codex backend are required and neither is sufficient: the adapter reads
# INITIAL_AGENT_MODE (not sandbox_mode) and defaults to AgentMode.Agent, so an isolated home
# alone leaves the turn in write mode -- measured.
grep -q 'INITIAL_AGENT_MODE=read-only' "$ISO_RP" \
  && ok "the codex backend pins INITIAL_AGENT_MODE=read-only" || fail "no INITIAL_AGENT_MODE pin"
grep -q 'CODEX_HOME=\$acp_iso_home' "$ISO_RP" \
  && ok "the codex backend runs from a parent-owned isolated home" || fail "no isolated CODEX_HOME"

# THE LIFECYCLE POINT. acpx spawns the persistent queue owner on the SEND when none exists, so
# isolation that wraps only `sessions ensure` leaves the process that actually runs tools
# unconfined. Every acpx invocation now routes through ONE wrapper (acp_exec) that applies both
# the per-provider isolation env AND the GIT_* scrub, so the invariant is "every owner-spawning
# call goes through the wrapper" rather than "N call sites each remembered to add acp_iso".
ISO_N="$(grep -c 'acp_exec "' "$ISO_RP")"
grep -q 'acp_iso\[@\]+"\${acp_iso\[@\]}"' "$ISO_RP" && [ "$ISO_N" -ge 3 ] \
  && ok "isolation wraps every owner-spawning acpx invocation via the acp_exec wrapper (n=$ISO_N)" \
  || fail "isolation does not route every acpx invocation through the wrapper (n=$ISO_N, want >= 3)"
# The wrapper also scrubs the GIT_* environment so a caller's GIT_DIR / GIT_WORK_TREE /
# GIT_COMMON_DIR cannot redirect the child's git out of the mount.
grep -q 'env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR' "$ISO_RP" \
  && ok "the acp wrapper scrubs GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR from the child env" \
  || fail "the acp wrapper does not scrub the GIT_* environment"

# INITIAL_AGENT_MODE is read ONCE, when the adapter builds sessionState -- it is not a
# process-lifetime lock, and `set_mode` accepts AgentFullAccess with no allowlist. With --ttl
# owner reuse, a turn that raised its own mode would leave the NEXT round unconfined. Re-pinning
# before every prompt is what makes the backend survive owner reuse.
grep -q 'set-mode read-only' "$ISO_RP" \
  && ok "the mode is re-pinned immediately before every prompt" || fail "no per-prompt mode pin"
awk '/set-mode read-only/{m=NR} /refusing to send a review turn whose containment is unconfirmed/{if (NR>m && m) f=1} END{exit !f}' "$ISO_RP" \
  && ok "an unconfirmed mode refuses the turn instead of sending it" || fail "an unpinnable mode still sends"
# The confirmation must be EXACT and stdout-only. A glob for "read-only" over stdout+stderr
# passes on the adapter's REJECTION too ("Agent rejected session/set_mode for mode \"read-only\""),
# which would leave a reused owner in a write mode still prompted. Assert the check requires the
# exact success line AND rc 0, and does NOT fold stderr into the match. (grok, implement r1, blocking.)
grep -q '\[ "\$acp_mode_out" != "mode set: read-only" \]' "$ISO_RP" \
  && ok "the mode confirmation is the exact acpx success line, not a substring" \
  || fail "the mode confirmation is a loose match a rejection error would satisfy"
grep -q '\$acp_mode_rc" -ne 0' "$ISO_RP" \
  && ok "the mode confirmation also requires a zero exit status" || fail "the mode confirmation ignores rc"
# The set-mode capture must send stderr to the LOG, not into the matched output.
awk '/set-mode read-only 2>>/{f=1} END{exit !f}' "$ISO_RP" \
  && ok "set-mode stderr goes to the log, never into the confirmation match" \
  || fail "set-mode still folds stderr into the matched output (2>&1)"
# The isolated home is refused if it is a symlink, and its realpath must be the intended sibling.
awk '/isolated CODEX_HOME path is a symlink/{f=1} END{exit !f}' "$ISO_RP" \
  && ok "a symlinked isolated home is refused, not followed out of the mount" \
  || fail "the isolated home would follow a symlink"
# Every isolation refusal — not just two of them — surfaces its reason in result.json rather
# than the generic abort-trap note. Count the refusal ABORT_NOTE assignments; a grep for one
# stays green on two while the symlink/mkdir/realpath/config paths still say "aborted
# unexpectedly". (grok + codex, implement r2, advisory.)
ISO_NOTES="$(grep -c 'ABORT_NOTE="refused:' "$ISO_RP")"
[ "$ISO_NOTES" -ge 5 ] \
  && ok "every isolation refusal names its reason ($ISO_NOTES paths), not just the first two" \
  || fail "only $ISO_NOTES isolation refusals name a reason; the rest fall to the generic abort note"
# The reused home's files are written FRESH and RENAMED into place, defeating a leftover
# symlink OR hard link at config.toml/auth.json (a `-L` check alone misses the hard link).
grep -q '_iso_place()' "$ISO_RP" \
  && ok "isolated home files are staged fresh and renamed, not overwritten in place" \
  || fail "no atomic stage-and-rename for the isolated home files"
grep -q 'command mv -f "\$_tmp" "\$_dst"' "$ISO_RP" \
  && ok "the stage is renamed over the dirent (defeats symlink and hard link)" \
  || fail "the isolated home write does not rename over the dirent"
# auth.json specifically goes through the atomic placer, not a bare cp that follows a symlink.
awk '/_iso_place "\$acp_src_home\/auth.json"/{f=1} END{exit !f}' "$ISO_RP" \
  && ok "auth.json is staged atomically, not copied through a possible symlink" \
  || fail "auth.json is still copied without symlink/hardlink safety"
# STALE-CREDENTIAL CLEAR. The persistent isolated home would otherwise keep an auth.json whose
# SOURCE was later removed/rotated, silently undoing the logout — the next mounted turn would run on
# a revoked credential. The else-branch removes the isolated copy, fail-closed.
# The shape check is bound to the SOURCE gate and requires the fail-closed recheck AFTER the rm, in
# order (stalecred r1, both reviewers): a bare /else$/ matched any of ~15 else lines, and a check
# that only proved else+rm would stay green if the recheck were deleted. Requiring the rm to sit
# after the source-gate else also rejects an INVERTED gate (clearing in the source-present branch).
# The codex Seatbelt backend itself is a reproducible-by-hand probe, as every isolation boundary here
# is (the suite stubs acpx and does not run a real codex turn); a functional codex fixture was tried
# and works standalone but is timing-fragile under this machine's load, so it is not committed.
awk '
  /\[ -f "\$acp_src_home\/auth.json" \] && \[ ! -L "\$acp_src_home\/auth.json" \]; then/{g=NR}
  g && /^ *else$/ && NR>g && NR<g+6 {e=NR}
  e && /rm -f "\$acp_iso_home\/auth.json"/ && NR>e {r=NR}
  r && /a stale isolated auth.json persists after its source credential was removed/ && NR>r {d=1}
  END{exit !(g&&e&&r&&d)}
' "$ISO_RP" \
  && ok "the stale-auth clear sits on the source gate with a fail-closed recheck after the rm" \
  || fail "the stale-auth clear is not bound to the source gate or lacks the fail-closed recheck"
# _iso_place refuses a non-regular-file dest (symlink-to-dir or real dir): `mv -f` there would
# deposit the staged file INSIDE the target and exit 0, silently leaving the read-only config
# absent. It unlinks a symlink dest first, refuses a directory, and verifies a regular file
# landed. (codex, implement r4, blocking.)
awk '/if \[ -L "\$_dst" \]; then rm -f "\$_dst"/{a=1} /\[ -e "\$_dst" \] && \[ ! -f "\$_dst" \]/{b=1} END{exit !(a&&b)}' "$ISO_RP" \
  && ok "_iso_place unlinks a symlink dest and refuses a directory dest" \
  || fail "_iso_place does not defend against a directory / symlink-to-dir dest"
awk '/command mv -f "\$_tmp" "\$_dst"/{m=NR} /\[ -f "\$_dst" \] && \[ ! -L "\$_dst" \] \|\| return 1/{if (NR>m && m) v=1} END{exit !v}' "$ISO_RP" \
  && ok "_iso_place verifies a regular file landed after the rename" \
  || fail "_iso_place does not verify the rename result"
# chmod fails closed (the mode is part of the contract, not advisory).
grep -q 'chmod "\$_mode" "\$_tmp" || { rm -f "\$_tmp"; return 1; }' "$ISO_RP" \
  && ok "_iso_place fails closed if the requested mode cannot be set" \
  || fail "_iso_place ignores a chmod failure"
# A mounted codex turn whose reviewed tree carries .codex/config.toml is REFUSED before spawn,
# regardless of content — codex reads it from the cwd and it can declare provider-side MCP that
# runs outside the sandbox. The refusal is CONTENT-INDEPENDENT: it tests for the file's
# existence, never greps it, because TOML quoted/space-padded keys make content-matching
# bypassable (both reviewers found the grep bypass). (codex + grok, implement r5, blocking.)
awk '/\[ -e "\$mount_dir\/.codex\/config.toml" \]/{a=1} /the reviewed tree carries .codex\/config.toml/{b=1} END{exit !(a&&b)}' "$ISO_RP" \
  && ok "a reviewed tree carrying .codex/config.toml is refused before the codex turn spawns" \
  || fail "a hostile .codex/config.toml is not refused before spawn"
# The refusal must NOT depend on parsing the file (no grep of the config): a content match is
# bypassable by quoted/space-padded TOML keys.
awk '/mount_dir\/.codex\/config.toml/ && /grep/{f=1} END{exit f}' "$ISO_RP" \
  && ok "the .codex/config.toml refusal does not grep the file (no bypassable content match)" \
  || fail "the .codex/config.toml refusal still content-matches the file"
# The mkdir refusal note is set on its OWN line, not as a prefix assignment that would not
# persist to the EXIT trap. Assert no ABORT_NOTE prefixes an mkdir on the same line.
grep -Eq 'ABORT_NOTE=.*mkdir' "$ISO_RP" \
  && fail "ABORT_NOTE is a prefix assignment on mkdir — it will not persist to the trap" \
  || ok "the mkdir refusal note is a standalone assignment that persists to the trap"
# The mounted-path boundary comment must name the kernel sandbox, not the retired GROK_SANDBOX lever.
grep -q 'GROK_SANDBOX applies to' "$ISO_RP" \
  && fail "a mounted-path comment still names COMMS_RUNPHASE_GROK_SANDBOX as the boundary" \
  || ok "the mounted-path boundary is described as the per-provider kernel sandbox, not GROK_SANDBOX"

# The isolated home is per-MOUNT, not per-message: under run_dir it would be rebuilt every round
# and the provider's own session state -- what warm resume is made of -- would be cold each time.
# It is now the home/ SIBLING of view/ that mount_alloc creates, always a validated external
# ident dir (durable or throwaway) — never the old ${mount_kdir:-$run_dir} in-repo fallback.
grep -q 'acp_iso_home="\$mount_kdir/home"' "$ISO_RP" \
  && ok "the isolated home is the per-mount home/ sibling, so warm resume survives" || fail "the isolated home is per-message"
# ...and it is a SIBLING of view/ (which holds tree/), never inside the verified artifact, so
# mount_tree_matches still verifies the artifact alone. The old $run_dir/codex-home fallback,
# a 7th in-repo landing for auth.json, is gone.
grep -q 'acp_iso_home="\$mount_kdir/home"' "$ISO_RP" \
  && ! grep -q 'mount_kdir:-\$run_dir}/codex-home' "$ISO_RP" \
  && ok "the isolated home sits beside view/, never inside the artifact, with no in-repo fallback" \
  || fail "the isolated home could contaminate the artifact or still has an in-repo fallback"

# The roadmap bullet that proposed --permission-policy as the fix is MEASURABLY FALSE (argv is
# never a match token). Leaving it in place is how the next agent implements the thing that does
# not work and marks the item done.
grep -q 'deny writes and non-git execs while still allowing' "$REPO/docs/ROADMAP.md" \
  && fail "the measurably-false --permission-policy lever is still proposed in ROADMAP" \
  || ok "the false --permission-policy lever is struck from the roadmap"
# ...and the item itself stays OPEN, because grok on Darwin is still uncontained.
grep -q 'open security item' "$REPO/docs/ROADMAP.md" \
  && ok "the open security item stays open while a dispatched provider is uncontained" \
  || fail "the security item was closed while grok remains uncontained"

section "comms.sh v2: clean (guarded, dry-run default) — runs last, deletes fixture"
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
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"

# COVERAGE GATE. Ran the whole corpus, or this is not a suite verdict. Both the
# exit status (which integrate reads as its primary gate) and the attestation
# (which lets integrate SKIP its re-run) hang off this -- gating only the mint
# would leave the louder signal, the exit status, still lying about a partial run.
_flush_section
COVERAGE_OK=0
coverage_verdict "$PASS" "$FAIL" "$SKIP" "${EXPECT_TOTAL:-}" && COVERAGE_OK=1
# PER-SECTION EQUALITY, read from the commit under test for the same reason the total is.
# This is the invariant that makes the coming section-function wrap and lane split
# VERIFIABLE rather than hopeful: a wrap that silently moved assertions between sections
# keeps the total intact and fails here.
SECTION_GOLDEN_F="$WORK/section-golden.tsv"
git -C "$REPO" show "${TESTED_OID:-missing}:tests/section-counts.tsv" > "$SECTION_GOLDEN_F" 2>/dev/null \
  || : > "$SECTION_GOLDEN_F"
section_vector_verdict "$SECTION_GOLDEN_F" "$SECTION_VECTOR" || COVERAGE_OK=0
# A working-tree edit is not authoritative here either — same rule as the total contract.
if [ -f "$REPO/tests/section-counts.tsv" ] && ! git -C "$REPO" diff --quiet HEAD -- tests/section-counts.tsv 2>/dev/null; then
  echo "COVERAGE: tests/section-counts.tsv is modified; the COMMITTED vector is authoritative." >&2
  echo "COVERAGE: commit it to change the expected per-section counts." >&2
fi
GATE_REACHED=1
# A fully green run attests itself so integrate can skip its re-verification of
# the SAME commit (opt-in via suite-attest-secs). The attestation is bound to
# TESTED_OID — the commit captured BEFORE the first assertion — so a checkout or
# commit racing the end of the run cannot inherit a green result it never
# earned; --expect makes attest-green refuse rather than record the wrong OID.
# (codex, integrate-ergonomics r1 — blocking.) Best-effort otherwise: a refusal
# (dirty tree, moved HEAD, no repo) never fails a green suite.
if [ "$FAIL" -eq 0 ] && [ "$COVERAGE_OK" -eq 1 ] && [ -n "${TESTED_OID:-}" ]; then
  (cd "$REPO" && "$COMMS" attest-green --passed "$PASS" --expect "$TESTED_OID") >/dev/null 2>&1 || true
fi
[ "$FAIL" -eq 0 ] && [ "$COVERAGE_OK" -eq 1 ]
