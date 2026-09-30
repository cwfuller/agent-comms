# Exercise the real report parser against incomplete and conflicting evidence.
section "harness: complete parallel worker reports"
if PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tests/test_dispatch.py" ReportContract CompleteRunner WorkerLifecycle > "$WORK/coordinator.log" 2>&1; then
  ok "coordinator rejects incomplete workers, duplicate coverage and reused skip allowances"
else
  cat "$WORK/coordinator.log" >&2
  fail "coordinator report contract regressed"
fi
if python3 "$REPO/tests/test_dispatch.py" RunnerOwnership.test_killing_run_sh_stops_all_worker_session_members > "$WORK/cancellation.log" 2>&1; then
  ok "killing run.sh with INT, TERM or KILL leaves no worker session members"
else
  cat "$WORK/cancellation.log" >&2
  fail "run.sh cancellation left worker sessions running"
fi
if python3 "$REPO/tests/test_dispatch.py" RunnerOwnership.test_leftover_orphan_cannot_reduce_later_run_coverage > "$WORK/orphan.log" 2>&1; then
  ok "live leftover orphan cannot reduce coverage of later runs with distinct worker instances"
else
  cat "$WORK/orphan.log" >&2
  fail "worker instances collided across runs"
fi
