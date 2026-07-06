#!/bin/bash
# loopspec conformance checker — runs an implementation against the golden fixtures.
#
# Usage (agent-comms): check.sh --comms <path-to-comms.sh>
#
# Self-contained by design: no cmux, no git repo, no network — the whole loopspec/
# directory can be vendored into another consumer and re-run there. Other consumers
# implement their own thin reader against the same fixture data; this script is the
# agent-comms reader.
#
# Exit: 0 iff every conformance check passes. One line per check.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
COMMS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --comms) shift; COMMS="${1:-}" ;;
    *) echo "check.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$COMMS" ] && [ -x "$COMMS" ] || { echo "check.sh: --comms <executable comms.sh> is required" >&2; exit 2; }
# Absolutize: checks run from a neutral temp dir, so a relative path would break.
case "$COMMS" in
  /*) ;;
  *) COMMS="$(cd "$(dirname "$COMMS")" && pwd)/$(basename "$COMMS")" ;;
esac

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: loopspec: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: loopspec: $1" >&2; }

# Fixtures reference no repo — run the helper from a neutral temp dir so nothing
# about the caller's cwd (or a surrounding repo) leaks into validation.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- valid fixtures must validate ----
for f in "$DIR/fixtures/valid/"*.md; do
  if (cd "$WORK" && "$COMMS" validate "$f" >/dev/null 2>&1); then
    ok "valid fixture accepted: $(basename "$f")"
  else
    bad "valid fixture rejected: $(basename "$f") — $( (cd "$WORK" && "$COMMS" validate "$f") 2>&1 | tr '\n' ' ')"
  fi
done

# ---- invalid fixtures must be rejected, with the expected reason ----
while IFS=$'\t' read -r name expect; do
  [ -n "$name" ] || continue
  f="$DIR/fixtures/invalid/$name"
  if [ ! -f "$f" ]; then
    bad "MANIFEST names a missing fixture: $name"
    continue
  fi
  out="$( (cd "$WORK" && "$COMMS" validate "$f") 2>&1 )"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "invalid fixture accepted: $name"
  # Strip the fixture's own path from the output before grepping — otherwise an
  # expect token like 'type' matches missing-type.md's echoed filename and a
  # validator that rejects for entirely wrong reasons still conforms.
  elif printf '%s' "$out" | sed "s|$f||g" | grep -qi -- "$expect"; then
    ok "invalid fixture rejected for '$expect': $name"
  else
    bad "invalid fixture rejected but reason lacks '$expect': $name (got: $(printf '%s' "$out" | tr '\n' ' '))"
  fi
done < "$DIR/fixtures/invalid/MANIFEST.tsv"

# ---- verdict normalization table ----
while IFS=$'\t' read -r raw want; do
  [ -n "$raw" ] || continue
  tmp="$WORK/verdict-fixture.md"
  printf -- '---\ntype: review-feedback\nfrom: codex\ntimestamp: 2026-06-04T12:00:00Z\nverdict: %s\n---\n\nbody\n' "$raw" > "$tmp"
  got="$( (cd "$WORK" && "$COMMS" verdict "$tmp") 2>/dev/null )"
  if [ "$got" = "$want" ]; then
    ok "verdict '$raw' normalizes to $want"
  else
    bad "verdict '$raw' normalized to '$got', expected '$want'"
  fi
done < "$DIR/fixtures/verdicts.tsv"

# ---- schema smoke: required fields present in the JSON fixtures ----
# (No jq by design — mirror each schema's `required` list as greps.)
for field in workspace thread workflow status awaiting_from last_delivery; do
  if grep -q "\"$field\":" "$DIR/fixtures/thread-state.json"; then
    ok "thread-state fixture has required field: $field"
  else
    bad "thread-state fixture missing required field: $field"
  fi
done
for field in provider status exit_code run_dir; do
  if grep -q "\"$field\":" "$DIR/fixtures/result.json"; then
    ok "result fixture has required field: $field"
  else
    bad "result fixture missing required field: $field"
  fi
done
# The greps above must not drift from the schemas' own required lists.
for pair in "thread-state.schema.json:awaiting_from" "result.schema.json:exit_code" "verdict.schema.json:status"; do
  s="${pair%%:*}"; f="${pair##*:}"
  if grep -q "\"$f\"" "$DIR/$s"; then
    ok "schema $s mentions $f (grep list consistent)"
  else
    bad "schema $s does not mention $f — update check.sh's grep lists"
  fi
done

echo "loopspec: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
