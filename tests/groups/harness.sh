# Run through tests/run.sh; each group gets fresh fixtures.
section "harness: a partial run is never a verdict"
# The corpus gates integrate. These assertions guard the gate itself.
TEST_SOURCES=()
while IFS= read -r source_path; do TEST_SOURCES+=("$REPO/$source_path"); done < <(git -C "$REPO" ls-files -- 'tests/*.sh' 'tests/lib/*.sh' 'tests/groups/*.sh')
# Fixture attestations exercise temporary repositories. Only the complete runner may
# mint for REPO itself; moving those fixture tests into files must not confuse this guard.
[ "$(grep -lE '^ *\(cd "\$REPO" && "\$COMMS" attest-green ' "${TEST_SOURCES[@]}")" = "$REPO/tests/run.sh" ] \
  && ok "only the complete runner can mint for the repository under test" || fail "the suite attestation owner changed"
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
grep -nE '^[[:space:]]*echo "== .* =="' "${TEST_SOURCES[@]}" | grep -vF 'echo "== $1 =="' | grep -q . \
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
SEC_DUPS="$(sed -n 's/^[[:space:]]*section "\(.*\)".*$/\1/p' "${TEST_SOURCES[@]}" | sort | uniq -d | head -3)"
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
grep -q 'EXPECT_FILE="\$REPO/tests/expected-counts.tsv"' "$REPO/tests/lib/harness.sh" \
  && ok "the coverage contract path is committed, not configurable" || fail "contract path is not pinned"
grep -q '\${EXPECT''_FILE:-' "$REPO/tests/lib/harness.sh" \
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
grep -q "^for tf in .(tracked_paths 'templates/claude-commands" "${TEST_SOURCES[@]}" \
  && ok "the template loop enumerates tracked paths" || fail "the template loop no longer enumerates tracked paths"
grep -q "^for frag in .(tracked_paths 'docs/loopspec/fragments" "${TEST_SOURCES[@]}" \
  && ok "the fragment loop enumerates tracked paths" || fail "the fragment loop no longer enumerates tracked paths"
grep -q "^  for tf in .(tracked_paths 'templates/claude-commands" "${TEST_SOURCES[@]}" \
  && ok "the signature-scan loop enumerates tracked paths" || fail "the signature-scan loop no longer enumerates tracked paths"
# Negative side widened: a filesystem walk can also arrive as find, or via "$REPO"/./x.
grep -qE '^ *for [a-z_]+ in .*"\$REPO"/\.?/?(templates|docs)' "${TEST_SOURCES[@]}" \
  && fail "a corpus loop still enumerates the filesystem" || ok "no corpus loop enumerates the filesystem"
grep -qE '^ *for [a-z_]+ in .*find "\$REPO"/(templates|docs)' "${TEST_SOURCES[@]}" \
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
grep -q 'git -C "\$REPO" show "\${TESTED_OID:-missing}:tests/expected-counts.tsv"' "$REPO/tests/lib/harness.sh" \
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
run_ip() { (cd "$IP" && env "$COMMS" "$@"); }
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
IP_OUT2="$( (cd "$IP" && env BASH_ENV="$WORK/hostile-bashenv.sh" "$COMMS" integrate worktree-proofone) 2>&1 || true )"
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
(cd "$IH" && env "$COMMS" worktree new healone) >/dev/null 2>&1
(cd "$IH/.claude/worktrees/healone" && echo z > e.txt && git add e.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: e") >/dev/null 2>&1
IH_OUT="$( (cd "$IH" && env \
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
(cd "$IH2" && env "$COMMS" worktree new healtwo) >/dev/null 2>&1
(cd "$IH2/.claude/worktrees/healtwo" && echo z > f.txt && git add f.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: f") >/dev/null 2>&1
IH2_CLAIM="$( (cd "$IH2" && env "$COMMS" presence claim --name resident --role holder) 2>&1 || true )"
IH2_INST="$(printf '%s' "$IH2_CLAIM" | sed -n 's/.*instance: //p')"
(cd "$IH2" && env COMMS_PRESENCE_NAME=resident COMMS_PRESENCE_INSTANCE="$IH2_INST" \
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
(cd "$IH5" && env "$COMMS" worktree new spoofone) >/dev/null 2>&1
(cd "$IH5/.claude/worktrees/spoofone" && echo s > i.txt && git add i.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: i") >/dev/null 2>&1
IH5_CLAIM="$( (cd "$IH5" && env "$COMMS" presence claim --name liveone --role holder) 2>&1 || true )"
IH5_INST="$(printf '%s' "$IH5_CLAIM" | sed -n 's/.*instance: //p')"
(cd "$IH5" && env COMMS_PRESENCE_NAME=liveone COMMS_PRESENCE_INSTANCE="$IH5_INST" \
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
(cd "$IH7" && env "$COMMS" worktree new slowone) >/dev/null 2>&1
(cd "$IH7/.claude/worktrees/slowone" && echo l > k.txt && git add k.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: k") >/dev/null 2>&1
(cd "$IH7" && env COMMS_PRESENCE_TTL_SECS=3 \
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
(cd "$IH8" && env "$COMMS" worktree new detachone) >/dev/null 2>&1
(cd "$IH8/.claude/worktrees/detachone" && echo d > m.txt && git add m.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: m") >/dev/null 2>&1
# The property is NOT that the run waits for the descendant — supervision TERMs the whole
# group and escalates to KILL. So the observable is that the descendant never gets to act:
# its post-sleep marker must never appear. (A first draft asserted elapsed >= 3s and failed
# against BOTH modes, because waiting is not what quiescence does.)
IH8_MARKF="$WORK/ih8-descendant-ran"
rm -f "$IH8_MARKF"
(cd "$IH8" && env IH8_MARK="$IH8_MARKF" \
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
(cd "$IH4" && env "$COMMS" worktree new redone) >/dev/null 2>&1
(cd "$IH4/.claude/worktrees/redone" && echo r > h.txt && git add h.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: h") >/dev/null 2>&1
(cd "$IH4" && env \
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
(cd "$IP2" && env "$COMMS" worktree new forgeone) >/dev/null 2>&1
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
FORGE_OUT="$( (cd "$IP2" && env BASH_ENV="$WORK/forge-bashenv.sh" "$COMMS" integrate worktree-forgeone) 2>&1 || true )"
[ "$(cd "$IP2" && git rev-parse main)" != "$(cd "$IP2" && git rev-parse worktree-forgeone)" ] \
  && ok "a forged completion line from an interposed scrub does not land" \
  || fail "an env-function forgery landed a candidate whose suite never ran"
FORGE_ABS_OUT="$( (cd "$IP2" && env BASH_ENV="$WORK/forge-abs-bashenv.sh" "$COMMS" integrate worktree-forgeone) 2>&1 || true )"
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

section "integrate: the verification tree is a FRESH checkout"
# THE 2026-09-03 FIELD REPORT (fwh-platform, sev 4) read as "integrate cannot verify a
# non-hoisted monorepo". Measured: it can. `git worktree add` materializes TRACKED CONTENT
# ONLY, so a suite-cmd depending on a gitignored install passes in the operator's checkout and
# fails in the verification tree — and the tool's own error (TS2307 there) gives no reason to
# suspect the TREE. A suite-cmd that provisions first lands today with no change to the gate.
#
# Four directions, because two would teach a wrapper that then fails for a DIFFERENT reason:
# the post-suite cleanliness check refuses git-visible dirt, and that refusal had NO corpus
# coverage at all before this section. (grok, plan r1.)
FC="$WORK/freshco"; mkdir -p "$FC"; FC="$(cd "$FC" && pwd -P)"
git -C "$FC" init -q -b main
printf '.comms/\n.claude/worktrees/\nvendor/\n' > "$FC/.gitignore"
mkdir -p "$FC/.comms" "$FC/ci"
# stands in for a typecheck against a dependency that is NOT hoisted and IS gitignored
printf '#!/bin/bash\ntest -f vendor/dep.js || { echo "E_NO_MODULE: cannot find vendor/dep"; exit 2; }\necho ok\n' > "$FC/ci/check.sh"
printf '#!/bin/bash\nmkdir -p vendor && printf x > vendor/dep.js\nexec bash ci/check.sh\n' > "$FC/ci/provision.sh"
# a wrapper whose output is git-VISIBLE: passes, then dirties the tree
printf '#!/bin/bash\nprintf x > untracked-artifact.txt\necho ok\n' > "$FC/ci/dirty.sh"
chmod +x "$FC/ci/check.sh" "$FC/ci/provision.sh" "$FC/ci/dirty.sh"
printf 'suite-cmd = bash ci/check.sh\n' > "$FC/.comms/config"
(cd "$FC" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
# the ignored dependency exists ONLY in the primary checkout — exactly the reported shape
mkdir -p "$FC/vendor" && printf 'primary\n' > "$FC/vendor/dep.js"
(cd "$FC" && git checkout -q -b session-fc && printf 'x\n' > s.txt && git add s.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: s") >/dev/null 2>&1
(cd "$FC" && git checkout -q main)
run_fc() { (cd "$FC" && env "$COMMS" "$@"); }
fc_main() { git -C "$FC" rev-parse --verify refs/heads/main; }

# The premise: it really does pass where the operator runs it.
(cd "$FC" && bash ci/check.sh >/dev/null 2>&1) \
  && ok "the suite passes in the primary checkout, where the ignored dep exists" \
  || fail "fixture premise broken — the suite must pass in the primary checkout"

# (1) ignored dep, no provisioning -> REFUSED. This is the field report.
FC_BEFORE="$(fc_main)"
FC_OUT="$(run_fc integrate session-fc 2>&1 || true)"
[ "$(fc_main)" = "$FC_BEFORE" ] \
  && ok "a suite-cmd depending on an ignored file cannot land — main untouched" \
  || fail "a fresh-checkout suite failure still moved main"
printf '%s\n' "$FC_OUT" | grep -q 'FRESH checkout of the candidate' \
  && ok "the refusal explains that the verification tree is a fresh checkout" \
  || fail "no fresh-checkout diagnostic (got: $(printf '%s\n' "$FC_OUT" | tail -1))"
printf '%s\n' "$FC_OUT" | grep -q 'provision its own prerequisites' \
  && ok "the refusal names the fix rather than only the symptom" \
  || fail "the diagnostic does not say suite-cmd must provision"

# (2) a wrapper that provisions into an IGNORED path -> LANDS.
# Pinned on main == THE CANDIDATE, plus the success line — not merely "main moved". `!=` would
# stay true if a future edit put `suite-attest-secs` in this config and the landing came from a
# recorded attestation rather than from the wrapper actually working in the fresh tree, which is
# the only thing this direction exists to prove. (codex + grok, implement r1.)
printf 'suite-cmd = bash ci/provision.sh\n' > "$FC/.comms/config"
FC_CAND="$(git -C "$FC" rev-parse --verify session-fc)"
FC_OUT2="$(run_fc integrate session-fc 2>&1 || true)"
[ "$(fc_main)" = "$FC_CAND" ] \
  && ok "a self-contained suite-cmd provisions in the fresh tree and LANDS at the candidate" \
  || fail "a provisioning suite-cmd still could not land (got: $(printf '%s\n' "$FC_OUT2" | tail -1))"
printf '%s\n' "$FC_OUT2" | grep -q 'suite green at the landed OID' \
  && ok "the landing was earned by the suite running, not by a recorded attestation" \
  || fail "no 'suite green at the landed OID' line — the landing may not have run the suite"

# (3) a PASSING suite that leaves git-visible output -> still REFUSED. Ignored output is the
# intended shape; untracked-but-unignored is not, and this is the wrapper an operator writes
# next after acting on the hint from (1).
(cd "$FC" && git checkout -q session-fc && printf 'y\n' > s2.txt && git add s2.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "feat: s2" && git checkout -q main) >/dev/null 2>&1
printf 'suite-cmd = bash ci/dirty.sh\n' > "$FC/.comms/config"
FC_AT="$(fc_main)"
FC_OUT3="$(run_fc integrate session-fc 2>&1 || true)"
[ "$(fc_main)" = "$FC_AT" ] \
  && ok "a green suite that dirties the verification tree still cannot land" \
  || fail "git-visible dirt landed anyway"
printf '%s\n' "$FC_OUT3" | grep -q 'MAY create IGNORED files' \
  && ok "the dirty-tree refusal distinguishes ignored output from git-visible output" \
  || fail "no ignored-vs-visible guidance (got: $(printf '%s\n' "$FC_OUT3" | tail -1))"
printf '%s\n' "$FC_OUT3" | grep -q 'untracked-artifact.txt' \
  && ok "the dirty-tree refusal names what actually dirtied the tree" \
  || fail "the refusal does not print the offending path"

# (3b) MODIFIED TRACKED file, the shape a real package manager produces when it rewrites a
# lockfile. Same non-empty-porcelain branch as (3) today, so this is insurance, not new
# coverage. It is the DUAL of (3): the regression it pins is a future check that looks only at
# UNTRACKED files (`git ls-files --others`, `grep '^??'`), under which a rewritten tracked
# lockfile would land silently while (3) kept refusing.
#
# An earlier version of this comment named `attest-green`'s `-uno` as the hazard and had it
# exactly backwards: `-uno` HIDES untracked and still reports tracked, so that narrowing is the
# one (3) catches, not (3b). (codex + grok, implement r2 — corroborated.)
printf '#!/bin/bash\nprintf mutated > s.txt\necho ok\n' > "$FC/ci/lockfile.sh"
chmod +x "$FC/ci/lockfile.sh"
(cd "$FC" && git checkout -q session-fc && git add ci/lockfile.sh \
  && git -c user.email=t@t -c user.name=t commit -qm "ci: lockfile rewriter" \
  && git checkout -q main) >/dev/null 2>&1
printf 'suite-cmd = bash ci/lockfile.sh\n' > "$FC/.comms/config"
FC_AT2="$(fc_main)"
FC_OUT4="$(run_fc integrate session-fc 2>&1 || true)"
[ "$(fc_main)" = "$FC_AT2" ] \
  && ok "a green suite that rewrites a TRACKED file cannot land either" \
  || fail "a modified tracked file landed anyway"
# WITHOUT this, the assertion above is satisfied by any refusal at all — a suite that FAILED
# because the script was missing from the candidate leaves main untouched too, and the fixture
# would count as insurance while proving nothing. Grep the offending path, as (3) does.
# (grok, implement r2.)
printf '%s\n' "$FC_OUT4" | grep -q ' M s.txt' \
  && ok "the tracked-file refusal is the DIRTY-TREE one, not an unrelated failure" \
  || fail "main was untouched for some other reason (got: $(printf '%s\n' "$FC_OUT4" | tail -1))"

section "integrate: docs-only skip"
# A red suite-cmd proves the skip is the only way these landings succeed.
# Nested docs (the review bar) and AGENTS.md still pay the suite.
DO="$WORK/int-docs"; mkdir -p "$DO"; DO="$(cd "$DO" && pwd -P)"
git -C "$DO" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$DO/.gitignore"
mkdir -p "$DO/.comms" "$DO/docs/loopspec" "$DO/helpers"
printf 'hello\n' > "$DO/README.md"
printf 'mit\n' > "$DO/LICENSE"
printf 'install\n' > "$DO/docs/INSTALL.md"
printf 'bar\n' > "$DO/docs/loopspec/SPEC.md"
printf 'fn\n' > "$DO/helpers/x.sh"
printf 'agents\n' > "$DO/AGENTS.md"
printf '#!/bin/bash\nexit 1\n' > "$DO/suite.sh"
chmod +x "$DO/suite.sh"
printf 'suite-cmd = bash ./suite.sh\n' > "$DO/.comms/config"
(cd "$DO" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
(cd "$DO" && git checkout -q -b session-primary)
run_do() { (cd "$DO" && env "$COMMS" "$@"); }
run_do worktree new docskip >/dev/null 2>&1
do_reset() { git -C "$DO/.claude/worktrees/docskip" reset --hard "$(git -C "$DO" rev-parse main)" >/dev/null 2>&1; }
do_commit() { # usage: do_commit "msg" <file>
  local msg="$1" f="$2"
  do_reset
  (cd "$DO/.claude/worktrees/docskip" && printf 'x\n' >> "$f" && mkdir -p "$(dirname "$f")" && git add -- "$f" \
    && git -c user.email=t@t -c user.name=t commit -qm "$msg") >/dev/null 2>&1
}

do_commit "docs: readme" README.md
DO_OUT="$(run_do integrate worktree-docskip 2>&1 || true)"
printf '%s\n' "$DO_OUT" | grep -q 'docs-only candidate — skipping the suite' \
  && ok "a README-only candidate skips the suite" || fail "README-only did not skip (got: $(printf '%s' "$DO_OUT" | tail -2))"
[ "$(git -C "$DO" rev-parse main)" = "$(git -C "$DO" rev-parse worktree-docskip)" ] \
  && ok "the README-only candidate landed" || fail "README-only did not land"

do_commit "fix: helper" helpers/x.sh
DO_MAIN="$(git -C "$DO" rev-parse main)"
DO_OUT2="$(run_do integrate worktree-docskip 2>&1 || true)"
printf '%s\n' "$DO_OUT2" | grep -q 'docs-only candidate' \
  && fail "a helper change took the docs-only skip" || ok "a helper change does not take the docs-only skip"
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a helper change with a red suite does not land" || fail "helper change landed"

do_commit "docs: agents" AGENTS.md
DO_MAIN="$(git -C "$DO" rev-parse main)"
run_do integrate worktree-docskip >/dev/null 2>&1 || true
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "an AGENTS.md change still pays the suite and does not land on a red suite" || fail "AGENTS.md change landed"

do_commit "docs: loopspec" docs/loopspec/SPEC.md
DO_MAIN="$(git -C "$DO" rev-parse main)"
run_do integrate worktree-docskip >/dev/null 2>&1 || true
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a docs/loopspec change still pays the suite" || fail "loopspec change landed"

do_commit "docs: install" docs/INSTALL.md
DO_OUT3="$(run_do integrate worktree-docskip 2>&1 || true)"
[ "$(git -C "$DO" rev-parse main)" = "$(git -C "$DO" rev-parse worktree-docskip)" ] \
  && ok "a top-level docs/*.md candidate lands via the skip" || fail "docs/INSTALL.md did not land (got: $(printf '%s' "$DO_OUT3" | tail -2))"

do_reset
(cd "$DO/.claude/worktrees/docskip" && printf 'x\n' >> README.md && printf 'y\n' >> helpers/x.sh \
  && git add README.md helpers/x.sh && git -c user.email=t@t -c user.name=t commit -qm "mixed") >/dev/null 2>&1
DO_MAIN="$(git -C "$DO" rev-parse main)"
run_do integrate worktree-docskip >/dev/null 2>&1 || true
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a mixed prose+helper diff still pays the suite" || fail "mixed diff landed"

mkdir -p "$DO/.claude/worktrees/docskip/docs/extra"
do_reset
(cd "$DO/.claude/worktrees/docskip" && mkdir -p docs/extra && printf 'n\n' > docs/extra/nested.md \
  && git add docs/extra/nested.md && git -c user.email=t@t -c user.name=t commit -qm "docs: nested") >/dev/null 2>&1
DO_MAIN="$(git -C "$DO" rev-parse main)"
run_do integrate worktree-docskip >/dev/null 2>&1 || true
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a nested docs/ path is not treated as prose" || fail "nested docs path landed"

# Rename detection must not hide a non-prose source path behind a docs/*.md dest.
do_reset
(cd "$DO/.claude/worktrees/docskip" && git mv helpers/x.sh docs/x.md \
  && git -c user.email=t@t -c user.name=t commit -qm "rename: helper to docs") >/dev/null 2>&1
DO_MAIN="$(git -C "$DO" rev-parse main)"
DO_OUT4="$(run_do integrate worktree-docskip 2>&1 || true)"
printf '%s\n' "$DO_OUT4" | grep -q 'docs-only candidate' \
  && fail "a helper→docs rename took the docs-only skip" || ok "a helper→docs rename does not take the docs-only skip"
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a helper→docs rename with a red suite does not land" || fail "helper→docs rename landed"

# Same for nested docs → top-level docs: source is still load-bearing.
do_reset
(cd "$DO/.claude/worktrees/docskip" && git mv docs/loopspec/SPEC.md docs/SPEC.md \
  && git -c user.email=t@t -c user.name=t commit -qm "rename: nested to top") >/dev/null 2>&1
DO_MAIN="$(git -C "$DO" rev-parse main)"
DO_OUT5="$(run_do integrate worktree-docskip 2>&1 || true)"
printf '%s\n' "$DO_OUT5" | grep -q 'docs-only candidate' \
  && fail "a nested→top-level docs rename took the docs-only skip" || ok "a nested→top-level docs rename does not take the docs-only skip"
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a nested→top-level docs rename with a red suite does not land" || fail "nested→top rename landed"

# Non-md top-level docs files are not prose (allowlist is docs/*.md only).
do_reset
(cd "$DO/.claude/worktrees/docskip" && printf '#!/bin/bash\necho x\n' > docs/foo.sh \
  && git add docs/foo.sh && git -c user.email=t@t -c user.name=t commit -qm "docs: script") >/dev/null 2>&1
DO_MAIN="$(git -C "$DO" rev-parse main)"
DO_OUT6="$(run_do integrate worktree-docskip 2>&1 || true)"
printf '%s\n' "$DO_OUT6" | grep -q 'docs-only candidate' \
  && fail "a docs/*.sh change took the docs-only skip" || ok "a docs/*.sh change does not take the docs-only skip"
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a docs/*.sh change with a red suite does not land" || fail "docs/*.sh change landed"

do_commit "docs: license" LICENSE
DO_OUT7="$(run_do integrate worktree-docskip 2>&1 || true)"
printf '%s\n' "$DO_OUT7" | grep -q 'docs-only candidate — skipping the suite' \
  && ok "a LICENSE-only candidate skips the suite" || fail "LICENSE-only did not skip (got: $(printf '%s' "$DO_OUT7" | tail -2))"
[ "$(git -C "$DO" rev-parse main)" = "$(git -C "$DO" rev-parse worktree-docskip)" ] \
  && ok "the LICENSE-only candidate landed" || fail "LICENSE-only did not land"

# Submodule-suppression config must not hide a changed gitlink behind prose.
# $DO's checkout is session-primary (never occupy main). Put the submodule on
# fixture main via update-ref after committing it on the worktree, then reset
# so the candidate delta is only README + gitlink (no .gitmodules).
DO_SUB="$WORK/docskip-sub"; mkdir -p "$DO_SUB"
git -C "$DO_SUB" init -q
(cd "$DO_SUB" && echo s > f && git add f && git -c user.email=t@t -c user.name=t commit -qm s) >/dev/null 2>&1
do_reset
(cd "$DO/.claude/worktrees/docskip" && git -c protocol.file.allow=always submodule add --quiet "$DO_SUB" submod >/dev/null 2>&1 \
  && git -c user.email=t@t -c user.name=t commit -qm "add submod") >/dev/null 2>&1
git -C "$DO" update-ref refs/heads/main "$(git -C "$DO/.claude/worktrees/docskip" rev-parse HEAD)"
do_reset
git -C "$DO/.claude/worktrees/docskip" submodule update --init --quiet >/dev/null 2>&1 \
  || fail "gitlink fixture: submodule did not initialize on main"
[ -f "$DO/.claude/worktrees/docskip/submod/f" ] \
  || fail "gitlink fixture: submod/f missing after reset onto main"
(cd "$DO/.claude/worktrees/docskip" && (cd submod && echo t >> f && git add f && git -c user.email=t@t -c user.name=t commit -qm t) \
  && git add submod && echo x >> README.md && git add README.md \
  && git -c user.email=t@t -c user.name=t commit -qm "readme+sub") >/dev/null 2>&1 \
  || fail "gitlink fixture: could not commit README+gitlink bump"
DO_DELTA="$(git -C "$DO/.claude/worktrees/docskip" diff --name-only --no-renames --ignore-submodules=none "$(git -C "$DO" rev-parse main)" HEAD | sort | tr '\n' ' ')"
[ "$DO_DELTA" = "README.md submod " ] \
  || fail "gitlink fixture: candidate delta was '$DO_DELTA' (want README.md + submod)"
DO_MAIN="$(git -C "$DO" rev-parse main)"
git -C "$DO" config diff.ignoreSubmodules all
git -C "$DO/.claude/worktrees/docskip" config diff.ignoreSubmodules all
DO_OUT8="$(run_do integrate worktree-docskip 2>&1 || true)"
git -C "$DO" config --unset diff.ignoreSubmodules >/dev/null 2>&1 || true
git -C "$DO/.claude/worktrees/docskip" config --unset diff.ignoreSubmodules >/dev/null 2>&1 || true
printf '%s\n' "$DO_OUT8" | grep -q 'docs-only candidate' \
  && fail "a README+gitlink change under ignoreSubmodules=all took the docs-only skip" \
  || ok "a README+gitlink change under ignoreSubmodules=all does not take the docs-only skip"
[ "$(git -C "$DO" rev-parse main)" = "$DO_MAIN" ] \
  && ok "a README+gitlink change with a red suite does not land" || fail "README+gitlink landed"
