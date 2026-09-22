# Shared counters, coverage verdicts and exit sentinel.
set -uo pipefail

# HERMETIC, FIRST: repository-selection git variables. With GIT_DIR/GIT_WORK_TREE inherited,
# `git -C <fixture>` resolves to the CALLER'S repository, so fixture `init` and
# `commit --allow-empty` would write into live git state before any test-level scrub runs —
# verified: `GIT_DIR=<repo>/.git git -C /tmp/empty rev-parse --show-toplevel` prints the repo.
# Unset at suite entry, ahead of every git operation; tests that need them set them locally.
# (codex, shadow-collector implement r7.)
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_PREFIX \
      GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE 2>/dev/null || true

# HERMETIC: scrub inherited headless-delivery env — a harness run from INSIDE a
# headless peer turn (e.g. Codex reviewing this repo) inherits these and would
# route baseline tests through headless delivery (observed live: 40
# failures). The headless-specific sections set them explicitly per invocation.
# COMMS_RUNPHASE_EXPECT_STATE joins them for the same reason: inherited from an
# outer send it makes every direct `runphase.sh run` below wait out the state-file
# budget for a write that is not coming. COMMS_RUNPHASE_STATE_WAIT_SECS too, so an
# operator's tuning cannot silently change what the timing assertions measure.
unset COMMS_DELIVERY COMMS_HEADLESS_PICKUP COMMS_RUNPHASE_VIA \
      COMMS_RUNPHASE_EXPECT_STATE COMMS_RUNPHASE_STATE_WAIT_SECS \
      COMMS_RUNPHASE_TIMEOUT_SECS 2>/dev/null || true
# Probe-result flags gate condition-bound skips, so an inherited value would let a skip be
# cashed before its probe ran. Same class as the scrub above. (grok, panel r7.)
unset ACL_PROBE_OK GRP_PRESERVE_OK 2>/dev/null || true
# The harness's OWN session pid, which `presence claim` adopts as a record's liveness
# handle. Inherited, it would make every claim below record a pid on a developer's
# machine and none in CI — the corpus would describe a different system in each. The
# section that tests adoption sets it explicitly per invocation. (Same class as the
# scrub above.)
unset CLAUDE_PID COMMS_PRESENCE_PID COMMS_SELF GROK_AGENT CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX CODEX_THREAD_ID 2>/dev/null || true
# THE REVIEWER POLICY INPUTS. An operator's pins or reviewer-routing switch, inherited, would make
# the policy assertions describe that operator's configuration instead of the committed map — and
# COMMS_REVIEW_ROUTE would silently route every send in the corpus. The sections that exercise
# them set them per invocation.
# The classifier's own switches go too: with reviewer routing on, every send and panel fixture in
# the corpus would classify, and an inherited backend would reach TypeSafe from the suite.
# THE REVIEWER RUNTIME is pinned to the adapter's bundled codex for the whole corpus: auto-detection
# would otherwise find whatever codex the developer has installed, and the routed-model assertions
# would describe that machine. The runtime cases set their own stub binaries per invocation.
export COMMS_ACP_CODEX_PATH=bundled
# The installer offers interactive setup whenever /dev/tty opens; a suite run from a terminal
# must never block on that prompt.
export AGENT_COMMS_SETUP=0
unset COMMS_REVIEW_ROUTE COMMS_REVIEW_MAX COMMS_ACP_CODEX_MODEL COMMS_ACP_CODEX_EFFORT \
      COMMS_ROUTE COMMS_ROUTE_BACKEND COMMS_ROUTE_STUB TYPESAFE_API_KEY COMMS_ROUTE_URL \
      COMMS_ROUTE_LOG COMMS_ROUTE_SHADOW_ALLOW COMMS_ROUTE_MODEL COMMS_ROUTE_TIMEOUT_SECS \
      COMMS_ACP_CANARY_SECS COMMS_ACP_RUNTIME_PROBE_SECS 2>/dev/null || true
# SETTINGS FILES ARE OFF for the corpus: the developer's ~/.agent-comms/settings (and a project
# .comms/settings) would otherwise re-set the variables unset above, and the suite would describe
# that machine. The loader skips when this is set; the settings section opts back in per case.
export AC_SETTINGS_LOADED=1

# THE DEFAULT IS `mailbox`. What the harness needs from a default is "write the file and
# nudge nobody" — no spawned child, no network. It used to get that by asking for cmux and
# stubbing the binary, which made a transport slated for DELETION load-bearing for every
# section that never cared about it; the first version of this harness sent a real keystroke
# to a live pane once (docs/INTERNALS.md). S4-1 rewired the default to `mailbox`, which is
# exactly why S4-4 could then delete cmux without unrelated sections starting to spawn real
# agents. Sections that test DEFAULT routing clear this with `env -u COMMS_DELIVERY`.
# (contraction step 4, S4-1 then S4-4.)
export COMMS_DELIVERY=mailbox

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMS="$REPO/helpers/comms.sh"
# The commit UNDER TEST, captured before the first assertion — the self-attestation
# at the end binds to this, never to whatever HEAD has become by then.
TESTED_OID="$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null || true)"
# A worker must still be on the coordinator's captured commit. Refuse a moved HEAD
# before loading any contracts; the final mint independently checks it again.
if [ -n "${tested_oid:-}" ] && [ "$TESTED_OID" != "$tested_oid" ]; then
  echo "COVERAGE: HEAD moved before worker startup" >&2
  exit 1
fi
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


WORK="$(mktemp -d)"
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
