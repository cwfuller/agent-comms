# Load-sensitive test audit (2026-09-30)

Scope: every `tests/groups/*.sh` and `tests/*.py`, checking elapsed-time
comparisons, sleeps used as readiness, and subprocess deadlines. Production
helpers and the suite coordinator's operational deadlines are unchanged.
Assertion counts and section boundaries are unchanged.

## Changed assertions and fixtures

| Source | Change and property retained |
| --- | --- |
| `statewait.sh`, undeclared/declared spawn | Declare the same 20s budget for both cases. The undeclared call must finish before half the budget; the declared negative control must consume the whole budget. This replaces the unrelated `<3s` cutoff. |
| `statewait.sh`, mid-wait write | A sleep observer creates the state file inside the first nonzero sleep. Require exactly one short poll and a mutated state file. A flat budget sleep, skipped wait, or continued polling fails without depending on scheduler speed. The observer excludes the runner's explicit zero-second startup sleep. |
| `statewait.sh`, overflowing budget | Keep the positive elapsed lower bound. Replace the 20s upper bound with evidence that the runner completed after exactly 60 short polls, the default budget. An overflow that skips the wait or a huge clamp fails. |
| `presence.sh`, heartbeat during child / after heal | The child remains blocked until it observes a changed heartbeat. For healing, record the first restored epoch and require a strictly later one. A healing write alone cannot pass. A 60s guard bounds a broken fixture. |
| `presence.sh`, TERM and INT | Wait for the child/descendant readiness marker before signaling. Require readiness in the existing status assertions; a missing descendant cannot satisfy the teardown assertion. Live children sleep 300s, well beyond readiness. |
| `presence.sh`, live and zero-exit cancellation loops | Retain the ready, stopped-supervisor, and exited-child handshakes, with 60s guards instead of 10s. The running child outlives those guards. All cancellation/status assertions remain. |
| `presence.sh`, late cancellation | The TERM-ignoring descendant sends INT from its TERM trap during the wrapper's quiescence sweep, after the zero-status leader exits. Require that event and a nonzero wrapper result. This replaces signaling after a fixed 1s sleep. |
| `harness.sh`, detached descendant and control | Block the descendant on a release file, record its PID, and require it to be stopped at landing with no action marker. Release the unsupervised control and poll for its action. This replaces two fixed 3s observation delays and retains the non-vacuity control. |
| `core.sh`, bounded wrapper cancellation | Wait for the TERM-ignoring leader's PID marker before signaling and require that readiness in the existing teardown assertion. Remove the extra fixed 1s startup delay. |
| `events.sh`, detached and killed runners | Gate the detached runner at startup while asserting no turn-started event, then release it. Wait for persisted turn identity before killing the other runner and require readiness with its synthesized terminal event. The hanging provider now outlives the readiness guard. |
| `mounts.sh`, live holder fixtures | Live holders sleep 300s instead of 30/45s, so setup and contender startup have a wide margin. Existing ownership and cleanup assertions remain. |
| `worktree.sh`, process-held retirement fixtures | Poll `lsof` readiness for up to 60s instead of 5s; holders sleep 300s instead of 30s. Retirement must still identify the actual holder and retain the worktree. |
| `acp.sh`, hanging version probes | Both probes record their PIDs and would report a valid version if allowed to finish. Allow 10s for startup versus a 300s hang. Require fallback/refusal, two started probes, and stopped processes rather than total elapsed `<15s`. Thus missing the probe deadline cannot look like a normal versionless failure. |
| `test_dispatch.py`, scheduling and cancellation | Preserve event polling, cancellation results, process inspection, coverage, and cleanup counts. Give readiness/stopped-state polling 60s, result collection 90s, and reaping 30s; live fixtures outlast these guards at 300s. The actual wrapper timeout fixture gets a 20s setup margin. Observe run.sh's queued TERM before resuming the stopped dispatcher instead of sleeping 0.5s. The synchronous mocked owner-wait timeout contract remains 15s. |

## Retained timing uses

| Source | Why retained |
| --- | --- |
| `statewait.sh`, declared wait and overflowing-budget elapsed lower bounds | Load can only lengthen these waits; there is no short upper cutoff. The undeclared upper bound is now relative to the declared budget, as requested. |
| `agents.sh`, 2s ACP stub under a 1s budget | Simulates acpx returning salvaged output or a failure after its own deadline, rather than a hung provider. Only exceeding the budget matters; load lengthens that delay. Increasing it would slow the fixture without increasing coverage. |
| `core.sh`, whole-group teardown `<60s` | Compared with a deliberately 300s hung suite and a 2s supervisor budget, not ordinary command speed. It also requires both recorded processes to be gone. The independent 30s post-signal poll is one quarter of that fixture's 120s command timeout. |
| `core.sh`, `sleep 1` suite under a 60s bound | Exercises successful completion inside a declared timeout with ample separation. No test expects completion immediately after that sleep. |
| `core.sh`, timeout stubs and proof handshakes | Intentional hangs exercise timeout classification/marks; proof-file races already poll events for at least 30s rather than sleeping then assuming readiness. |
| `mounts.sh`, `sleep 1.2` | Deliberately separates holder and contender process start times by more than ps's whole-second granularity. Load lengthens the separation; the holder lifetime is now 300s. |
| `transport.sh`, `sleep 0` | The test explicitly waits for the child to exit before using its dead PID. It does not assume exit after a delay. |
| `mountclean.sh`, `sleep 300` holders | Intentional live-process fixtures, explicitly terminated. No short wall-clock assertion. |
| `harness.sh`, slow 4s suite | Exercises a suite that outlasts the heartbeat interval, with no elapsed upper bound. The original descendant-delay fixture was changed separately. |
| `test_dispatch.py`, serial presence fixture `sleep 0.1` | Scheduling order is checked from events; no assertion assumes the sleep completed in 0.1s. All remaining 15s process-exit polls exceed the production 5s cleanup grace. |
| `test_agent_profiles.py`, 30/45/90s subprocess guards | These bound hung small stub-backed launch/resolve/run fixtures; assertions check results, identities, and arguments, with no elapsed-speed requirement or nearby fixture expiry. |
| `dispatch.py`, 5/15s cleanup and 1800s worker budget | Operational suite supervision, not test speed assertions. Changing these would change coordinator behavior; this audit changes its test observation margins instead. Mocked tests still pin the operational contract. |
| Other shell groups / Python modules | Remaining comparisons count bytes, lines, assertions, or iteration limits; epoch arithmetic constructs old/future fixture state. Those do not assert real command completion by a short wall-clock bound. |

## Verification

Run touched groups repeatedly through `tests/run.sh --group`, including overlapping
foreground suite invocations. Use a temporary clone for negative-control mutations
of the undeclared wait, flat budget sleep, and overflowing budget; restore each
mutation after proving its corresponding assertion fails. Commit the candidate
before `integrate`; its fresh complete run checks both committed count contracts.
Stopped-process observations accept an absent process or a zombie on Darwin/Linux,
and reject inspection errors; waiting for the system reaper is not a speed test.
