# Exercise the real report parser against incomplete and conflicting evidence.
section "harness: complete parallel worker reports"
if PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tests/test_dispatch.py" > "$WORK/coordinator.log" 2>&1; then
  ok "coordinator rejects incomplete workers, duplicate coverage and reused skip allowances"
else
  cat "$WORK/coordinator.log" >&2
  fail "coordinator report contract regressed"
fi
