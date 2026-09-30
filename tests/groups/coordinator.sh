# Exercise the real report parser against incomplete and conflicting evidence.
section "harness: complete parallel worker reports"
if PYTHONDONTWRITEBYTECODE=1 python3 -B "$REPO/tests/test_dispatch.py" > "$WORK/coordinator.log" 2>&1; then
  ok "all coordinator tests pass, including group KILL, overlapping INT/TERM and orphan coverage"
else
  cat "$WORK/coordinator.log" >&2
  fail "coordinator report contract regressed"
fi
