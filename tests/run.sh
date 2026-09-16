#!/bin/bash
# Complete suite by default. --group is focused and can never attest.
set -uo pipefail
unset tested_oid
export PYTHONDONTWRITEBYTECODE=1
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
python3 "$REPO/tests/dispatch.py" "$REPO" "$TESTED_OID" "$WORK" "$@"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "SUITE: worker failure; no complete verdict (exit $rc)." >&2
  exit "$rc"
fi
if [ -f "$WORK/focused" ]; then
  GATE_REACHED=1
  exit 0
fi
IFS=$'\t' read -r PASS FAIL SKIP < "$WORK/counts" || exit 1
SECTION_VECTOR="$WORK/sections"
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
# COVERAGE GATE. Ran the whole corpus, or this is not a suite verdict. Both the
# exit status (which integrate reads as its primary gate) and the attestation
# (which lets integrate SKIP its re-run) hang off this -- gating only the mint
# would leave the louder signal, the exit status, still lying about a partial run.
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
  (cd "$REPO" && "$COMMS" attest-green --passed "$PASS" --expect "$TESTED_OID") >"$WORK/attestation.log" 2>&1
  att_rc=$?
  if [ "$att_rc" -eq 0 ]; then
    echo "ATTESTATION: recorded for $TESTED_OID; integrate can reuse it within suite-attest-secs."
  else
    echo "ATTESTATION: not recorded (exit $att_rc); integrate will rerun the suite." >&2
    cat "$WORK/attestation.log" >&2
  fi
fi
[ "$FAIL" -eq 0 ] && [ "$COVERAGE_OK" -eq 1 ]
