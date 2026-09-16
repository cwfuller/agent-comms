#!/bin/bash
# Internal worker protocol. A worker can report only its own group, never attest.
set -uo pipefail
group="$1"; tested_oid="$2"; results="$3"
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
TESTED_OID="$tested_oid"
source "$REPO/tests/lib/fixtures.sh"
source "$REPO/tests/groups/$group.sh"
_flush_section
cp "$SECTION_VECTOR" "$results/$group.sections"
printf '%s\n' "$SKIP_USED" > "$results/$group.skips"
printf '%s\t%s\t%s\n%s\ncomplete\n' "$PASS" "$FAIL" "$SKIP" "$group" > "$results/$group.pending"
mv "$results/$group.pending" "$results/$group.done"
GATE_REACHED=1
[ "$FAIL" -eq 0 ]
