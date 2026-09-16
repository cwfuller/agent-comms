# Run through tests/run.sh; each group gets fresh fixtures.
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
run_pn() { (cd "$PN_FIX" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
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
(cd "$PN_FIX" && env "$COMMS" validate "$PN_CRLEG" >/dev/null 2>&1) \
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


# DEGRADATION when a reviewer cannot answer AT ALL (2026-09-04). Built against a live case:
# grok out of weekly quota exits non-zero having produced zero bytes, and says nothing about
# why — only `RUNTIME QUEUE_RUNTIME_PROMPT_FAILED Internal error`. So the roster fact is
# recorded as what was OBSERVED (`reason=no-output`), and the operator is asked, never told.
PN_DG_REQ="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T12-03-00_req-dg.md"
sed -e 's/^message_id: .*/message_id: pn-req-dg/' -e 's/^thread: .*/thread: pn-dg-thread/' "$PN_REQ" > "$PN_DG_REQ"
PN_DG_OUT="$(run_pn panel dispatch --to codex,grok --set pn-dg "$PN_DG_REQ" 2>&1 || true)"
PN_DG_SET="$(printf '%s\n' "$PN_DG_OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
PN_DG_MC="$(find "$PN_FIX/.comms/to-codex" -type f | xargs grep -l '^thread: pn-dg-thread-codex' 2>/dev/null | head -1)"
PN_DG_MIDC="$(grep -m1 '^message_id:' "$PN_DG_MC" | sed 's/^message_id: //')"
# codex answers; grok never does.
{ printf -- '---\ntype: review-feedback\nfrom: codex\ntimestamp: 2026-08-26T12:50:00Z\nworkspace: %s\nmessage_id: codex-dg-reply\nthread: pn-dg-thread-codex\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n- None.\n' \
    "$PN_WS" "$PN_DG_MIDC"; } > "$PN_FIX/.comms/archive/${PN_WS}_2026-08-26T12-50-00_codex-dg.md"
# Default: still refuses, and now points at the operator escape hatch.
PN_DG_C1="$(run_pn compose --set "$PN_DG_SET" 2>&1 || true)"
printf '%s\n' "$PN_DG_C1" | grep -q 'INCOMPLETE' \
  && printf '%s\n' "$PN_DG_C1" | grep -q -- '--degrade' \
  && ok "a partial panel still refuses, and names the operator escape hatch" || fail "compose lost its refusal or its hint"
# WITHOUT recorded evidence the drop is refused: silence alone may never reduce the roster.
PN_DG_C2="$(run_pn compose --set "$PN_DG_SET" --degrade grok 2>&1 || true)"
printf '%s\n' "$PN_DG_C2" | grep -q 'no recorded evidence' \
  && ok "--degrade is refused for a leg that merely has not answered yet" || fail "a slow leg was droppable without evidence"
# Naming a leg that is NOT missing is refused too.
PN_DG_C3="$(run_pn compose --set "$PN_DG_SET" --degrade codex 2>&1 || true)"
printf '%s\n' "$PN_DG_C3" | grep -q 'not a missing leg' \
  && ok "--degrade refuses to drop a reviewer that actually answered" || fail "an answering reviewer was droppable"
# Now record the evidence the runner would have written, and the drop becomes available.
PN_DG_DSP="$(awk -F'\t' -v s="$PN_DG_SET" '$3=="panel-planned" && $4==s {d=$5} END{print d}' "$PN_FIX/.comms/events.tsv")"
run_pn events append --kind provider-result --set "$PN_DG_SET" --dispatch "$PN_DG_DSP" --agent grok --role gating \
  --status failed --note "exit=1 elapsed=6s budget=600s via=acp reason=no-output" >/dev/null 2>&1
PN_DG_C4="$(run_pn compose --set "$PN_DG_SET" --degrade grok 2>&1 || true)"
printf '%s\n' "$PN_DG_C4" | grep -q 'DEGRADED PANEL' \
  && printf '%s\n' "$PN_DG_C4" | grep -q 'WITHOUT: grok' \
  && ok "with recorded no-output evidence the operator may compose degraded" || fail "evidence-backed degrade was refused"
printf '%s\n' "$PN_DG_C4" | grep -q 'Reviewers present: codex' \
  && ok "a degraded composition names only the reviewers who actually answered" || fail "the degraded header misnames the roster"
grep -qE "leg-unavailable.*$PN_DG_SET.*grok" "$PN_FIX/.comms/events.tsv" \
  && ok "the roster reduction is WRITTEN to the coordinator log, never inferred" || fail "no leg-unavailable event recorded"
awk -F'\t' -v s="$PN_DG_SET" '$3=="composition-completed" && $4==s && $14=="composed-degraded"' "$PN_FIX/.comms/events.tsv" | grep -q . \
  && ok "the set closes as composed-degraded, so it cannot be read as a full panel later" || fail "degraded composition closed as an ordinary one"
# A turn that SUCCEEDED is never evidence its reviewer was unavailable, whatever it produced.
# The first cut derived the marker from emptiness alone, so a clean empty result authorized
# the drop. (codex, implement r1, blocking.)
PN_DG_REQ3="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T12-05-00_req-dg3.md"
sed -e 's/^message_id: .*/message_id: pn-req-dg3/' -e 's/^thread: .*/thread: pn-dg3-thread/' "$PN_REQ" > "$PN_DG_REQ3"
PN_DG3_OUT="$(run_pn panel dispatch --to codex,grok --set pn-dg3 "$PN_DG_REQ3" 2>&1 || true)"
PN_DG3_SET="$(printf '%s\n' "$PN_DG3_OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
PN_DG3_DSP="$(awk -F'\t' -v s="$PN_DG3_SET" '$3=="panel-planned" && $4==s {d=$5} END{print d}' "$PN_FIX/.comms/events.tsv")"
# codex must ANSWER here, or a valid drop would be refused by the empty-roster guard and
# these assertions would pass for the wrong reason.
PN_DG3_MC="$(find "$PN_FIX/.comms/to-codex" -type f | xargs grep -l '^thread: pn-dg3-thread-codex' 2>/dev/null | head -1)"
PN_DG3_MIDC="$(grep -m1 '^message_id:' "$PN_DG3_MC" | sed 's/^message_id: //')"
{ printf -- '---\ntype: review-feedback\nfrom: codex\ntimestamp: 2026-08-26T12:55:00Z\nworkspace: %s\nmessage_id: codex-dg3-reply\nthread: pn-dg3-thread-codex\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n- None.\n' \
    "$PN_WS" "$PN_DG3_MIDC"; } > "$PN_FIX/.comms/archive/${PN_WS}_2026-08-26T12-55-00_codex-dg3.md"
run_pn events append --kind provider-result --set "$PN_DG3_SET" --dispatch "$PN_DG3_DSP" --agent grok --role gating \
  --status completed --note "exit=0 via=acp reason=no-output" >/dev/null 2>&1
printf '%s\n' "$(run_pn compose --set "$PN_DG3_SET" --degrade grok 2>&1 || true)" | grep -q 'no recorded evidence' \
  && ok "a COMPLETED provider-result is never evidence of an unavailable reviewer" || fail "a successful empty turn authorized a drop"
# Evidence from a DIFFERENT dispatch of the same set must not authorize this attempt: the
# leg may have been redispatched and still be running. (codex, implement r1, blocking.)
run_pn events append --kind provider-result --set "$PN_DG3_SET" --dispatch "stale-$PN_DG3_DSP" --agent grok --role gating \
  --status failed --note "exit=1 via=acp reason=no-output" >/dev/null 2>&1
printf '%s\n' "$(run_pn compose --set "$PN_DG3_SET" --degrade grok 2>&1 || true)" | grep -q 'no recorded evidence' \
  && ok "evidence from another dispatch does not authorize dropping this attempt's leg" || fail "stale cross-dispatch evidence was accepted"

# A RE-SEND KEEPS THE DISPATCH, so binding to the dispatch alone still let a stale marker drop
# a leg that was actively reviewing again. The leg's LATEST turn must be the failed one.
# (codex, implement r2, blocking.)
run_pn events append --kind turn-started --set "$PN_DG3_SET" --dispatch "$PN_DG3_DSP" --agent grok \
  --role gating --status running --note "re-sent after the failure" >/dev/null 2>&1
printf '%s\n' "$(run_pn compose --set "$PN_DG3_SET" --degrade grok 2>&1 || true)" | grep -q 'no recorded evidence' \
  && ok "a leg re-sent under the same dispatch is not droppable while its new turn runs" || fail "a running re-send was dropped on a stale marker"
# ...and once THAT turn also fails with no output, it becomes evidence again.
run_pn events append --kind provider-result --set "$PN_DG3_SET" --dispatch "$PN_DG3_DSP" --agent grok \
  --role gating --status failed --note "exit=1 via=acp reason=no-output" >/dev/null 2>&1
printf '%s\n' "$(run_pn compose --set "$PN_DG3_SET" --degrade grok 2>&1 || true)" | grep -q 'DEGRADED PANEL' \
  && ok "the re-sent turn failing the same way restores droppability" || fail "a genuinely failed re-send stayed undroppable"

# THE CONCURRENCY FORM: "latest turn" sampled once is a TOCTOU. Between accepting the drop and
# publishing, another process can re-send the leg — and the live reviewer would still be
# dropped. Forced deterministically by moving the leg's history through a compose whose
# acceptance already happened. (codex, implement r3, blocking.)
PN_DG4_REQ="$PN_FIX/.comms/to-codex/$(basename "$PN_FIX")_2026-08-26T12-06-00_req-dg4.md"
sed -e 's/^message_id: .*/message_id: pn-req-dg4/' -e 's/^thread: .*/thread: pn-dg4-thread/' "$PN_REQ" > "$PN_DG4_REQ"
PN_DG4_OUT="$(run_pn panel dispatch --to codex,grok --set pn-dg4 "$PN_DG4_REQ" 2>&1 || true)"
PN_DG4_SET="$(printf '%s\n' "$PN_DG4_OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
PN_DG4_DSP="$(awk -F'\t' -v s="$PN_DG4_SET" '$3=="panel-planned" && $4==s {d=$5} END{print d}' "$PN_FIX/.comms/events.tsv")"
PN_DG4_MC="$(find "$PN_FIX/.comms/to-codex" -type f | xargs grep -l '^thread: pn-dg4-thread-codex' 2>/dev/null | head -1)"
PN_DG4_MIDC="$(grep -m1 '^message_id:' "$PN_DG4_MC" | sed 's/^message_id: //')"
{ printf -- '---\ntype: review-feedback\nfrom: codex\ntimestamp: 2026-08-26T12:56:00Z\nworkspace: %s\nmessage_id: codex-dg4-reply\nthread: pn-dg4-thread-codex\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n- None.\n' \
    "$PN_WS" "$PN_DG4_MIDC"; } > "$PN_FIX/.comms/archive/${PN_WS}_2026-08-26T12-56-00_codex-dg4.md"
run_pn events append --kind provider-result --set "$PN_DG4_SET" --dispatch "$PN_DG4_DSP" --agent grok \
  --role gating --status failed --note "exit=1 via=acp reason=no-output" >/dev/null 2>&1
# Sanity: droppable right now.
printf '%s\n' "$(run_pn compose --set "$PN_DG4_SET" --degrade grok 2>&1 || true)" | grep -q 'DEGRADED PANEL' \
  && ok "the concurrency fixture is droppable before anything moves" || fail "dg4 fixture is not droppable — the next assertion would be vacuous"
# Now a re-send lands. The very same command must refuse instead of publishing.
run_pn events append --kind turn-started --set "$PN_DG4_SET" --dispatch "$PN_DG4_DSP" --agent grok \
  --role gating --status running --note "re-sent while composing" >/dev/null 2>&1
PN_DG4_C="$(run_pn compose --set "$PN_DG4_SET" --degrade grok 2>&1 || true)"
printf '%s\n' "$PN_DG4_C" | grep -qE 'no recorded evidence|turn history moved' \
  && ! printf '%s\n' "$PN_DG4_C" | grep -q 'DEGRADED PANEL' \
  && ok "a leg whose turn history moves is never published as dropped" || fail "a re-sent leg was still dropped"

# THE ADVISORY-EVENT HOLE. `turn-started` is written through advisory log_event: if that append
# fails the review still runs. A re-send would then leave the OLD no-output result as the latest
# visible boundary and a live reviewer would be dropped. `request-persisted` is appended
# FAIL-CLOSED before delivery, so it is the boundary that cannot be missing.
# (codex, implement r5, blocking.)
run_pn events append --kind request-persisted --set "$PN_DG4_SET" --dispatch "$PN_DG4_DSP" --agent grok \
  --role gating --status persisted --note "re-sent; turn-started never made it to the log" >/dev/null 2>&1
PN_DG6_C="$(run_pn compose --set "$PN_DG4_SET" --degrade grok 2>&1 || true)"
printf '%s\n' "$PN_DG6_C" | grep -q 'no recorded evidence' \
  && ! printf '%s\n' "$PN_DG6_C" | grep -q 'DEGRADED PANEL' \
  && ok "a re-send known only by its fail-closed request event still blocks the drop" || fail "an advisory-event gap let a live re-send be dropped"

# FINGERPRINT SATURATION. The accessor used a capped read, so a leg with 50+ boundary events
# pinned count=50 and history could move with every sampled field identical. Prove the
# unbounded read by moving history PAST the cap and then changing it. (codex, implement r4.)
PN_DG5_I=0
while [ "$PN_DG5_I" -lt 56 ]; do
  run_pn events append --kind turn-started --set "$PN_DG4_SET" --dispatch "$PN_DG4_DSP" --agent grok \
    --role gating --status running --note "churn $PN_DG5_I" >/dev/null 2>&1
  run_pn events append --kind provider-result --set "$PN_DG4_SET" --dispatch "$PN_DG4_DSP" --agent grok \
    --role gating --status failed --note "exit=1 via=acp reason=no-output churn $PN_DG5_I" >/dev/null 2>&1
  PN_DG5_I=$((PN_DG5_I + 1))
done
PN_DG5_A="$(run_pn compose --set "$PN_DG4_SET" --degrade grok >/dev/null 2>&1; echo done)"
PN_DG5_S1="$( eval "$(sed -n '/^degrade_boundary_state() {/,/^}/p' "$COMMS")"
              cmd_events() { (cd "$PN_FIX" && "$COMMS" events "$@"); }
              degrade_boundary_state "$PN_DG4_SET" "$PN_DG4_DSP" grok )"
run_pn events append --kind provider-result --set "$PN_DG4_SET" --dispatch "$PN_DG4_DSP" --agent grok \
  --role gating --status failed --note "exit=1 via=acp reason=no-output churn final" >/dev/null 2>&1
PN_DG5_S2="$( eval "$(sed -n '/^degrade_boundary_state() {/,/^}/p' "$COMMS")"
              cmd_events() { (cd "$PN_FIX" && "$COMMS" events "$@"); }
              degrade_boundary_state "$PN_DG4_SET" "$PN_DG4_DSP" grok )"
[ -n "$PN_DG5_S1" ] && [ "$PN_DG5_S1" != "$PN_DG5_S2" ] \
  && ok "the boundary fingerprint still moves past the reader's default row cap" || fail "fingerprint saturated: '$PN_DG5_S1' vs '$PN_DG5_S2'"

# A reduction that empties the roster is not a degraded panel, it is an unreviewed change.
PN_DG_REQ2="$PN_FIX/.comms/to-grok/$(basename "$PN_FIX")_2026-08-26T12-04-00_req-dg2.md"
sed -e 's/^message_id: .*/message_id: pn-req-dg2/' -e 's/^thread: .*/thread: pn-dg2-thread/' "$PN_REQ" > "$PN_DG_REQ2"
PN_DG2_OUT="$(run_pn panel dispatch --to grok --set pn-dg2 "$PN_DG_REQ2" 2>&1 || true)"
PN_DG2_SET="$(printf '%s\n' "$PN_DG2_OUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
PN_DG2_DSP="$(awk -F'\t' -v s="$PN_DG2_SET" '$3=="panel-planned" && $4==s {d=$5} END{print d}' "$PN_FIX/.comms/events.tsv")"
run_pn events append --kind provider-result --set "$PN_DG2_SET" --dispatch "$PN_DG2_DSP" --agent grok --role gating \
  --status failed --note "exit=1 via=acp reason=no-output" >/dev/null 2>&1
PN_DG_C5="$(run_pn compose --set "$PN_DG2_SET" --degrade grok 2>&1 || true)"
printf '%s\n' "$PN_DG_C5" | grep -q 'no reviewer at all' \
  && ok "dropping EVERY leg is refused — an empty roster is not a degraded panel" || fail "degrade emptied the roster"

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
# Range NARROWED to Gates -> the next heading. Mixed now sits between Gates and Uncorroborated,
# so the old `/^## Gates/,/^## Uncorroborated/` span would also match a MIXED anchor and call it
# gated. (codex, corroboration plan r3.)
printf '%s\n' "$PN_COMP" | awk '/^## Gates/{f=1;next} /^## /{f=0} f' | grep -q 's.txt:1' \
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

section "templates: the loop closes its thread state on the terminal approval"
# Field report 2026-09-08: two approved threads sat `awaiting claude` for ten hours because the
# /auto skill never said to run `state complete`; only the contributor doc (AGENTS.md) did.
grep -q 'state complete "<thread>"' "$REPO/templates/claude-commands/auto.md" \
  && ok "auto.md tells the driver to close the thread's state on the terminal APPROVE" || fail "auto.md lacks the state complete step"
grep -q 'state complete "<thread>-' "$REPO/templates/claude-commands/read-from-codex.md" \
  && ok "read-from-codex.md closes every panel LEG thread, which are the ones that carry state" || fail "read-from-codex.md lacks the per-leg state complete"

section "ask: the driver-neutral consult verb"
AK="$WORK/ask-repo"; mkdir -p "$AK"; AK="$(cd "$AK" && pwd -P)"
git -C "$AK" init -q -b main
git -C "$AK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$AK/.comms/to-codex" "$AK/.comms/to-grok" "$AK/.comms/to-claude"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$AK/.comms/config"
run_ak() { (cd "$AK" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" "$COMMS" "$@"); }
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
# Behavioral: a successful --wait must not report NOT spawned after the outbound is
# archived (the 2026-09-02 false-failure). Stub runphase next to a copied helper so
# the wait path is the real cmd_send/deliver_headless, not a grep of the source.
WAIT_H="$WORK/wait-helpers"; mkdir -p "$WAIT_H"
cp "$COMMS" "$WAIT_H/comms.sh"; chmod +x "$WAIT_H/comms.sh"
cat > "$WAIT_H/runphase.sh" <<'WAITSTUB'
#!/bin/bash
set -euo pipefail
msg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --message) shift; msg="${1:-}" ;;
  esac
  shift || true
done
if [ -n "$msg" ] && [ -f "$msg" ] && [ "${WAIT_STUB_RC:-0}" = "0" ]; then
  dest="$(cd "$(dirname "$msg")/.." && pwd)/archive"
  mkdir -p "$dest"
  mv "$msg" "$dest/"
fi
exit "${WAIT_STUB_RC:-0}"
WAITSTUB
chmod +x "$WAIT_H/runphase.sh"
WAIT_R="$WORK/wait-repo"; mkdir -p "$WAIT_R"; WAIT_R="$(cd "$WAIT_R" && pwd -P)"
git -C "$WAIT_R" init -q -b main
git -C "$WAIT_R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$WAIT_R/.comms/to-grok" "$WAIT_R/.comms/archive"
printf 'agents = claude codex grok\ndefault-target = grok\n' > "$WAIT_R/.comms/config"
WAIT_WS="$(cd "$WAIT_R" && "$WAIT_H/comms.sh" workspace)"
WAIT_MSG="$WAIT_R/.comms/to-grok/${WAIT_WS}_2026-09-02T12-00-00_wait-ask.md"
cat > "$WAIT_MSG" <<WAITEOF
---
type: question
from: claude
timestamp: 2026-09-02T12:00:00Z
workspace: $WAIT_WS
message_id: ${WAIT_WS}_2026-09-02T12-00-00_wait-ask
---

## Question
is wait status truthful
WAITEOF
WAIT_OUT="$(cd "$WAIT_R" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_DELIVERY=headless "$WAIT_H/comms.sh" send --wait --to grok "$WAIT_MSG" 2>&1)" || true
WAIT_TAIL="$(printf '%s\n' "$WAIT_OUT" | tail -1)"
case "$WAIT_TAIL" in
  "RESULT: completed"*) ok "send --wait success is RESULT: completed, not a spawn" ;;
  *) fail "send --wait success RESULT (got: $WAIT_TAIL)" ;;
esac
printf '%s\n' "$WAIT_OUT" | grep -qi 'NOT spawned' \
  && fail "send --wait success still says NOT spawned" || ok "send --wait success does not claim the peer failed to spawn"
printf '%s\n' "$WAIT_OUT" | grep -qi "can't open file" \
  && fail "send --wait still awks the archived outbound path" || ok "send --wait re-resolves a moved outbound (no awk on a gone path)"
WAIT_MSG2="$WAIT_R/.comms/to-grok/${WAIT_WS}_2026-09-02T12-01-00_wait-fail.md"
sed -e 's/wait-ask/wait-fail/g' -e 's/is wait status truthful/fail please/' "$WAIT_R/.comms/archive/$(basename "$WAIT_MSG")" > "$WAIT_MSG2" \
  || sed -e 's/wait-ask/wait-fail/g' "$WAIT_MSG" > "$WAIT_MSG2"
WAIT_FAIL="$(cd "$WAIT_R" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_DELIVERY=headless WAIT_STUB_RC=1 "$WAIT_H/comms.sh" send --wait --to grok "$WAIT_MSG2" 2>&1)" || true
WAIT_FAIL_TAIL="$(printf '%s\n' "$WAIT_FAIL" | tail -1)"
case "$WAIT_FAIL_TAIL" in
  "RESULT: failed"*) ok "send --wait failure is RESULT: failed, not NOT spawned" ;;
  *) fail "send --wait failure RESULT (got: $WAIT_FAIL_TAIL)" ;;
esac
printf '%s\n' "$WAIT_FAIL" | grep -qi 'NOT spawned' \
  && fail "send --wait failure still says NOT spawned" || ok "send --wait failure does not claim the peer was never spawned"
# acpx launch is asked for, never guessed twice
grep -q 'acpx_launcher' "$REPO/helpers/acp.sh" && ok "acp.sh owns how acpx is launched" || fail "acpx launcher"
grep -q 'ACPX_BIN' "$REPO/helpers/acp.sh" && ok "an installed acpx binary can replace npx entirely" || fail "ACPX_BIN support"
grep -q 'npm_config_cache' "$REPO/helpers/acp.sh" \
  && ok "an unwritable ~/.npm falls back to a workspace cache" || fail "npm cache fallback"
grep -q 'synthesized by await' "$REPO/helpers/runphase.sh" \
  && ok "a pid that dies without a result gets a synthetic one" || fail "synthetic failed result"
