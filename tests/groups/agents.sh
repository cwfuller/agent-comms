# Run through tests/run.sh; each group gets fresh fixtures.
section "multi-agent: registry contract"
MA_FIX="$WORK/ma-repo"; mkdir -p "$MA_FIX"; MA_FIX="$(cd "$MA_FIX" && pwd -P)"
git -C "$MA_FIX" init -q -b feature/ma-tests
git -C "$MA_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$MA_FIX/.comms/to-claude" "$MA_FIX/.comms/to-codex" "$MA_FIX/.comms/archive"
run_ma() { (cd "$MA_FIX" && env "$COMMS" "$@"); }
MA_WS="$(run_ma workspace)"

[ "$(run_ma agents)" = "claude codex grok" ] && ok "zero-config agents default includes grok" || fail "zero-config agents (got: $(run_ma agents))"
[ "$(run_ma agents default)" = "codex" ] && ok "zero-config default target" || fail "zero-config default target"
run_ma agents --supported | grep -q 'grok' && ok "supported table lists grok" || fail "supported table lists grok"

printf 'agents = claude codex grok\ndefault-target = codex\n' > "$MA_FIX/.comms/config"
[ "$(run_ma agents)" = "claude codex grok" ] && ok "registry registers grok" || fail "registry registers grok (got: $(run_ma agents))"
printf 'agents = claude Codex\n' > "$MA_FIX/.comms/config"
check_not "uppercase agent name rejected" run_ma agents
printf 'agents = claude ../evil\n' > "$MA_FIX/.comms/config"
check_not "path-traversal agent name rejected" run_ma agents
printf 'agents = claude co.dex\n' > "$MA_FIX/.comms/config"
check_not "dotted agent name rejected" run_ma agents
printf 'agents = claude gemini\n' > "$MA_FIX/.comms/config"
check_not "unsupported agent (gemini) rejected at parse" run_ma agents
printf 'agents = claude codex claude\n' > "$MA_FIX/.comms/config"
check_not "duplicate agent rejected" run_ma agents
printf 'agents = claude codex\nagents = claude\n' > "$MA_FIX/.comms/config"
check_not "duplicate agents key rejected" run_ma agents
printf 'agents = claude codex grok\ndefault-target = grok claude\n' > "$MA_FIX/.comms/config"
check_not "multi-word default-target rejected" run_ma agents default
printf 'agents = claude codex\ndefault-target = grok\n' > "$MA_FIX/.comms/config"
check_not "unregistered default-target rejected" run_ma agents default
printf 'agents = claude codex\ndefault-target = gemini\n' > "$MA_FIX/.comms/config"
check_not "malformed default-target propagates through status" run_ma status
check_not "malformed default-target propagates through list" run_ma list --as claude
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$MA_FIX/.comms/config"
check_not "unknown agent dies on inbox use" run_ma list --as gemini

section "multi-agent: sender enforcement + grok inbox round-trip"
MA_TS="2026-08-20T09-00-00"
MA_MSG="$MA_FIX/.comms/to-grok/${MA_WS}_${MA_TS}_review-req-1.md"
mkdir -p "$MA_FIX/.comms/to-grok"
cat > "$MA_MSG" <<MAEOF
---
type: review-request
from: claude
timestamp: 2026-08-20T14:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_${MA_TS}_review-req-1
thread: ma-arc-1
workflow: auto-full
phase: plan
round: 1
max-rounds: 4
---

## Plan
review this plan
MAEOF
check "grok inbox lists the message" bash -c "run_ma() { (cd '$MA_FIX' && env '$COMMS' \"\$@\"); }; run_ma list --as grok | grep -q review-req-1"
BAD_FROM="$MA_FIX/.comms/to-claude/${MA_WS}_${MA_TS}_badfrom-1.md"
sed 's/^from: claude$/from: gemini/' "$MA_MSG" > "$BAD_FROM"
check_not "validate rejects unregistered from:" run_ma validate "$BAD_FROM"
rm -f "$BAD_FROM"

section "multi-agent: grok stub + full-arc runphase legs"

RP="$REPO/helpers/runphase.sh"
run_grok_leg() {  # <msg-path> <run-dir> [env overrides via caller export]
  (cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" \
     COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$1" --dir "$2" --provider grok)
}

# Leg 1: plan round 1 -> REQUEST_CHANGES reply lands for claude, inbound archived
R1="$WORK/ma-leg1"; mkdir -p "$R1"
GROK_STUB_VERDICT=REQUEST_CHANGES run_grok_leg "$MA_MSG" "$R1" >/dev/null 2>&1
[ "$(cd "$MA_FIX" && "$COMMS" root >/dev/null 2>&1; echo done)" = done ] || true
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R1/result.json" | head -1)" = "completed" ] \
  && ok "grok leg 1 completes" || fail "grok leg 1 result (see $R1/result.json)"
REPLY1="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f | head -1)"
[ -n "$REPLY1" ] && ok "grok reply persisted to claude inbox by the PARENT" || fail "grok reply persisted"
grep -q '^from: grok$' "$REPLY1" && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY1" \
  && ok "reply carries grok identity and stub verdict" || fail "reply identity/verdict"
grep -q '^thread: ma-arc-1$' "$REPLY1" && ok "reply copies the thread" || fail "reply thread copy"
[ ! -f "$MA_MSG" ] && [ -f "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" ] \
  && ok "inbound archived from to-grok by owner derivation" || fail "inbound archive movement"
STATE1="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_ma-arc-1.json"
grep -q '"awaiting_from": "claude"' "$STATE1" && ok "awaiting_from = explicit send target (claude)" || fail "awaiting_from authority (see $STATE1)"
grep -q '"grok_session_id": "stub-grok-session-1"' "$STATE1" && ok "generic grok_session_id recorded" || fail "grok session field"
grep -q -- '--sandbox read-only' "$GROK_STUB_LOG" && grep -q -- '--permission-mode dontAsk' "$GROK_STUB_LOG" \
  && grep -q -- '--output-format streaming-messages-json' "$GROK_STUB_LOG" \
  && ok "grok argv pins read-only sandbox + dontAsk + whole-message format" || fail "grok argv sandbox/mode/format"
grep -q -- "--deny Bash(rm \*) --deny Bash(git push\*)" "$GROK_STUB_LOG" \
  && ok "grok argv carries both deny rules" || fail "grok argv deny rules"
grep -qE '(^| )-p( |$)' "$GROK_STUB_LOG" && fail "grok argv must not use -p" || ok "grok argv avoids -p (prompt-file only)"

# Leg 2a: plan round 2 — built the way the READER builds it: reviewer derived
# from the round-1 reply's from:, round incremented, in-reply-to threaded.
LEG2_REVIEWER="$(sed -n '2,/^---$/p' "$REPLY1" | grep -m1 '^from:' | sed 's/^from: //')"
[ "$LEG2_REVIEWER" = "grok" ] && ok "reader-side reviewer derivation from the grok reply" || fail "reviewer derivation (got: $LEG2_REVIEWER)"
REPLY1_ID="$(sed -n '2,/^---$/p' "$REPLY1" | grep -m1 '^message_id:' | sed 's/^message_id: //')"
MA_MSG2="$MA_FIX/.comms/to-$LEG2_REVIEWER/${MA_WS}_2026-08-20T09-10-00_plan-r2-1.md"
sed -e 's/^round: 1$/round: 2/' -e "s/^message_id: .*/message_id: ${MA_WS}_2026-08-20T09-10-00_plan-r2-1/" \
    -e "s/^in-reply-to: .*/in-reply-to: $REPLY1_ID/" \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG2"
grep -q '^in-reply-to:' "$MA_MSG2" || sed -i.bak "s/^thread: ma-arc-1\$/thread: ma-arc-1\nin-reply-to: $REPLY1_ID/" "$MA_MSG2"
R2A="$WORK/ma-leg2a"; mkdir -p "$R2A"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSG2" "$R2A" >/dev/null 2>&1
REPLY2="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f ! -path "$REPLY1" | sort | tail -1)"
[ -n "$REPLY2" ] && [ "$REPLY2" != "$REPLY1" ] && grep -q '^verdict: APPROVE$' "$REPLY2" \
  && grep -q '^round: 2$' "$REPLY2" \
  && ok "plan round 2 approved by the same reviewer" || fail "plan round-2 leg"
[ -f "$MA_FIX/.comms/archive/$(basename "$MA_MSG2")" ] && ok "round-2 inbound archived exactly" || fail "round-2 archive movement"

# Leg 2b: the plan→implement CONTINUATION — implement round 1 to the reviewer
# derived from the APPROVAL (the transition the reader performs), same thread.
LEG2B_REVIEWER="$(sed -n '2,/^---$/p' "$REPLY2" | grep -m1 '^from:' | sed 's/^from: //')"
REPLY2_ID="$(sed -n '2,/^---$/p' "$REPLY2" | grep -m1 '^message_id:' | sed 's/^message_id: //')"
MA_MSG2B="$MA_FIX/.comms/to-$LEG2B_REVIEWER/${MA_WS}_2026-08-20T09-15-00_impl-r1-1.md"
sed -e 's/^phase: plan$/phase: implement/' -e 's/^round: 2$/round: 1/' \
    -e "s/^message_id: .*/message_id: ${MA_WS}_2026-08-20T09-15-00_impl-r1-1/" \
    -e "s/^in-reply-to: .*/in-reply-to: $REPLY2_ID/" \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG2")" > "$MA_MSG2B"
grep -q "^in-reply-to: $REPLY2_ID$" "$MA_MSG2B" \
  && ok "implement continuation threads to the round-2 APPROVAL" || fail "continuation in-reply-to"
R2B="$WORK/ma-leg2b"; mkdir -p "$R2B"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSG2B" "$R2B" >/dev/null 2>&1
REPLY2B="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f | sort | tail -1)"
grep -q '^phase: implement$' "$REPLY2B" && grep -q '^from: grok$' "$REPLY2B" \
  && ok "plan→implement continuation reviewed by the SAME reviewer (full arc)" || fail "implement continuation leg"
STATUS_OUT="$(run_ma status 2>/dev/null)"
echo "$STATUS_OUT" | grep -q 'pending in to-grok' && ok "status iterates the grok inbox" || fail "status grok inbox line"
# Backdate the awaiting epoch so the age is deterministically > threshold —
# a same-second run otherwise races age_s > 0 and sees nothing stalled.
STATE_ARC="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_ma-arc-1.json"
BACKDATE=$(( $(date +%s) - 120 ))
sed -i.bak "s/\"awaiting_since_epoch\": \"[0-9]*\"/\"awaiting_since_epoch\": \"$BACKDATE\"/" "$STATE_ARC" && rm -f "$STATE_ARC.bak"
STALLED_OUT="$(run_ma stalled 1 2>/dev/null)"
echo "$STALLED_OUT" | grep -q 'thread=ma-arc-1' && echo "$STALLED_OUT" | grep -q 'awaiting=claude' \
  && ok "stalled resolves the arc thread with the explicit-target awaiting" || fail "stalled arc lookup (got: $STALLED_OUT)"
MA_MSG2="$MA_MSG2B"

# Leg 3: peer-from-from — inbound from codex routes the reply to to-codex/
MA_MSG3="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-20-00_from-codex-1.md"
# leg 2 archived MA_MSG2 — build leg 3's inbound from the archived copy directly
sed -e 's/^from: claude$/from: codex/' -e 's/^thread: ma-arc-1$/thread: ma-arc-2/' \
    -e 's/_impl-r1-1$/_from-codex-1/' \
    "$MA_FIX/.comms/archive/$(basename "$MA_MSG2")" > "$MA_MSG3"
[ -s "$MA_MSG3" ] || fail "leg-3 fixture construction produced an empty file"
R3="$WORK/ma-leg3"; mkdir -p "$R3"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSG3" "$R3" >/dev/null 2>&1
find "$MA_FIX/.comms/to-codex" -name '*grok-reply*' -type f | grep -q . \
  && ok "pickup peer derives from inbound from: (reply to to-codex/)" || fail "peer-from-from derivation"

# Broker failures under the parent-stamped envelope: the model cannot author
# ANY frontmatter, so the adversarial surface is the verdict-line contract and
# body validity — each must fail with nothing persisted and nothing archived.
MA_MSG4="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-30-00_noverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-3/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG4"
R4="$WORK/ma-leg4"; mkdir -p "$R4"
PRE_CLAUDE_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
GROK_STUB_NO_VERDICT=1 run_grok_leg "$MA_MSG4" "$R4" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R4/result.json" | head -1)" = "failed" ] \
  && grep -q 'no unquoted .### Blocking. section' "$R4/result.json" && [ -f "$MA_MSG4" ] \
  && ok "a reply with neither a VERDICT line nor findings structure fails closed" || fail "missing-verdict broker path"
# A Blocking section the parser cannot read must NOT derive APPROVE. This is the end-to-end
# half of the residue counter: seven real replies in .comms/logs derived APPROVE this way,
# one of them over a genuine attestation defect. The leg must fail closed and leave the
# inbound un-archived, exactly like the unclosed-fence and no-structure paths above.
MA_MSG4B="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-32-00_leadtoken-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-3b/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG4B"
R4B="$WORK/ma-leg4b"; mkdir -p "$R4B"
PRE_RESID_CT="$(find "$MA_FIX/.comms/to-claude" -type f 2>/dev/null | grep -c . || true)"
GROK_STUB_LEAD_TOKEN=1 run_grok_leg "$MA_MSG4B" "$R4B" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R4B/result.json" | head -1)" = "failed" ] \
  && ok "an unreadable Blocking section fails closed instead of deriving APPROVE" \
  || fail "a lead-token blocking section still derived a verdict"
grep -q 'could not read as findings' "$R4B/result.json" \
  && ok "the refusal names the unread lines so the driver can act on it" || fail "refusal note missing"
[ "$PRE_RESID_CT" = "$(find "$MA_FIX/.comms/to-claude" -type f 2>/dev/null | grep -c . || true)" ] \
  && ok "no APPROVE envelope was persisted for an unread review" || fail "an envelope was stamped over unread content"
[ -f "$MA_MSG4B" ] && ok "the inbound survives a residue refusal, so the round is retryable" || fail "inbound lost on residue refusal"
MA_MSG5="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-35-00_badverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-4/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG5"
R6="$WORK/ma-leg6"; mkdir -p "$R6"
GROK_STUB_BAD_VERDICT=1 run_grok_leg "$MA_MSG5" "$R6" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R6/result.json" | head -1)" = "failed" ] && [ -f "$MA_MSG5" ] \
  && ok "nonstandard verdict value fails closed" || fail "bad-verdict broker path"
MA_MSG7="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-37-00_emptybody-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-5/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG7"
R7="$WORK/ma-leg7"; mkdir -p "$R7"
GROK_STUB_EMPTY_BODY=1 run_grok_leg "$MA_MSG7" "$R7" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R7/result.json" | head -1)" = "failed" ] \
  && grep -q 'failed validation' "$R7/result.json" && [ -f "$MA_MSG7" ] \
  && ok "verdict-only empty body refused by validate" || fail "empty-body broker path"
[ "$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')" = "$PRE_CLAUDE_CT" ] \
  && ok "all broker failures persisted nothing to the claude inbox" || fail "broker-failure persistence atomicity"
# Path-shaped / unregistered inbound from: — refused BEFORE any routing
MA_MSG8="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-39-00_evilfrom-1.md"
sed -e 's|^from: claude$|from: ../evil|' -e 's/^thread: ma-arc-1$/thread: ma-arc-6/' \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG8"
R8="$WORK/ma-leg8"; mkdir -p "$R8"
run_grok_leg "$MA_MSG8" "$R8" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R8/result.json" | head -1)" = "failed" ] \
  && grep -q 'not a registered agent' "$R8/result.json" && [ -f "$MA_MSG8" ] \
  && [ ! -d "$MA_FIX/.comms/to-../evil" ] \
  && ok "path-shaped inbound from: refused before routing" || fail "unregistered-peer refusal"
# Adversarial verdict-line shapes through the REAL broker (codex, field-report
# round 1: grep-the-source assertions cannot catch a stamp-path regression).
PRE_STAMP_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
MA_MSG9="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-43-00_dupverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-7/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG9"
R9="$WORK/ma-leg9"; mkdir -p "$R9"
GROK_STUB_DUP_VERDICT=1 run_grok_leg "$MA_MSG9" "$R9" >/dev/null 2>&1
REPLY9="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R9/prompt.md" | head -1)"
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R9/result.json" | head -1)" = "completed" ] \
  && [ -n "$REPLY9" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY9" \
  && ok "duplicate VERDICT lines stamp the DERIVED verdict, not line 1" || fail "dup-verdict broker leg"
MA_MSG10="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-45-00_lieapprove-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-8/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG10"
R10="$WORK/ma-leg10"; mkdir -p "$R10"
PRE_LIE_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
GROK_STUB_LIE_APPROVE=1 run_grok_leg "$MA_MSG10" "$R10" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R10/result.json" | head -1)" = "failed" ] \
  && grep -q 'contradicts its own body' "$R10/result.json" && [ -f "$MA_MSG10" ] \
  && [ "$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')" = "$PRE_LIE_CT" ] \
  && ok "explicit APPROVE over blocking findings is REFUSED by the live broker" || fail "lie-approve broker leg"
MA_MSG11="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-47-00_preamble-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-9/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG11"
R11="$WORK/ma-leg11"; mkdir -p "$R11"
GROK_STUB_PREAMBLE_NUMBERED=1 run_grok_leg "$MA_MSG11" "$R11" >/dev/null 2>&1
REPLY11="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R11/prompt.md" | head -1)"
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R11/result.json" | head -1)" = "completed" ] \
  && [ -n "$REPLY11" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY11" \
  && ok "preamble + numbered None.-suffix finding derives REQUEST_CHANGES live (the field incident)" || fail "preamble-numbered broker leg"
# A lowercase `### blocking` must not let an explicit APPROVE past the cross-check.
MA_MSG16="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-57-00_lielower-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-14/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG16"
R16="$WORK/ma-leg16"; mkdir -p "$R16"
PRE_LOWER_CT="$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')"
GROK_STUB_LIE_APPROVE_LOWER=1 run_grok_leg "$MA_MSG16" "$R16" >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$R16/result.json" | head -1)" = "failed" ] \
  && grep -q 'contradicts its own body' "$R16/result.json" \
  && [ "$(find "$MA_FIX/.comms/to-claude" -type f | wc -l | tr -d ' ')" = "$PRE_LOWER_CT" ] \
  && ok "a lowercase ### blocking heading cannot smuggle an APPROVE past the cross-check" \
  || fail "lowercase lie-approve broker leg"

# Verdict lines BEYOND the old 40-line scan window (codex, field-report round 2).
MA_MSG12="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-49-00_lateverdict-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-10/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG12"
R12="$WORK/ma-leg12"; mkdir -p "$R12"
GROK_STUB_LATE_VERDICT=1 run_grok_leg "$MA_MSG12" "$R12" >/dev/null 2>&1
REPLY12="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R12/prompt.md" | head -1)"
[ -n "$REPLY12" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY12" \
  && ok "a sole VERDICT past line 40 is still honoured" || fail "late-verdict broker leg"

MA_MSG13="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-51-00_dupfar-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-11/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG13"
R13="$WORK/ma-leg13"; mkdir -p "$R13"
GROK_STUB_DUP_FAR=1 run_grok_leg "$MA_MSG13" "$R13" >/dev/null 2>&1
REPLY13="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R13/prompt.md" | head -1)"
[ -n "$REPLY13" ] && grep -q '^verdict: REQUEST_CHANGES$' "$REPLY13" \
  && ok "a line-1 APPROVE contradicted past line 40 no longer wins" || fail "dup-far broker leg"

MA_MSG14="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-53-00_quoted-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-12/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG14"
R14="$WORK/ma-leg14"; mkdir -p "$R14"
GROK_STUB_QUOTED_VERDICT=1 run_grok_leg "$MA_MSG14" "$R14" >/dev/null 2>&1
REPLY14="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$R14/prompt.md" | head -1)"
[ -n "$REPLY14" ] && grep -q '^verdict: APPROVE$' "$REPLY14" \
  && ok "a fenced quote of a whole prior review neither forges a verdict nor a finding" || fail "quoted-verdict broker leg"

# An ACP turn killed by its own timeout budget must NOT be reported as an empty reply.
# Under `--format quiet` acpx exits 0 having printed nothing, so a killed-mid-work turn
# and a genuinely empty one are byte-identical; the honest-but-wrong note sent an
# operator hunting permission flags for half an hour. (agent-comms-7b, 2026-08-26.)
TO_STUB="$WORK/timeout-bin"; mkdir -p "$TO_STUB"
cat > "$TO_STUB/npx" <<'TSTUB'
#!/bin/bash
case " $* " in
  *" sessions ensure "*) echo "stub-session (created)"; exit 0 ;;
  *" sessions show "*) printf 'name: s\ncwd: %s\n' "$(pwd -P)"; exit 0 ;;
  *" set-mode "*) for tm in "$@"; do tmode="$tm"; done; printf 'mode set: %s\n' "$tmode"; exit 0 ;;
  *"single word PONG"*) printf 'PONG\n'; exit 0 ;;    # the compatibility canary passes
esac
printf '%s\n' "$*" >> "${TO_STUB_ARGV:-/dev/null}"
[ "${TO_STUB_SLEEP:-2}" != "0" ] && sleep "${TO_STUB_SLEEP:-2}"   # outlive the 1s budget below
# Default prints NOTHING -- exactly acpx --format quiet on a kill. TO_STUB_OUT makes the
# kill PARTIAL instead, which is the case the original guard could not see.
[ -n "${TO_STUB_OUT:-}" ] && printf '%s' "$TO_STUB_OUT"
exit "${TO_STUB_RC:-0}"
TSTUB
chmod +x "$TO_STUB/npx"
cat > "$TO_STUB/node" <<'TNODE'
#!/bin/bash
echo "v22.22.3"
TNODE
chmod +x "$TO_STUB/node"
MA_MSG15="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-55-00_timeout-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-13/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSG15"
R15="$WORK/ma-leg15"; mkdir -p "$R15"
( cd "$MA_FIX" && env PATH="$TO_STUB:$PATH" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$MA_MSG15" --dir "$R15" \
    --provider grok --via acp --timeout-secs 1 ) >/dev/null 2>&1
TO_NOTE="$(sed -n 's/.*"note": "\(.*\)".*/\1/p' "$R15/result.json" 2>/dev/null | head -1)"
case "$TO_NOTE" in
  *"budget"*) ok "an ACP turn killed by its timeout names the budget, not an empty reply" ;;
  *) fail "timeout note (got: ${TO_NOTE:-<none>})" ;;
esac
case "$TO_NOTE" in
  *"produced no reply text"*) fail "a timeout is still reported as an empty reply" ;;
  *) ok "a killed turn is not mislabelled as a refused or empty reply" ;;
esac
grep -q 'budget' "$R15/runner.log" 2>/dev/null \
  && ok "elapsed and budget are recorded in runner.log either way" || fail "no elapsed/budget line in runner.log"

# THE EXPENSIVE CASE: a budget-killed turn that got PARTIAL bytes out. A review opens with
# its verdict and an empty Blocking list, so a turn cut off while writing its advisories
# emits exactly this — and the parent stamps an authoritative APPROVE from a reviewer that
# never finished reading the diff. The old guard asked about the budget only when the child
# had printed nothing, so this shipped as `completed` with an EMPTY note.
run_to_leg() { # <thread-suffix> <run-dir-var> <timeout> [env already exported by caller]
  local msg="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-5${1}-00_to-${1}.md"
  sed -e "s/^thread: ma-arc-1\$/thread: ma-arc-to${1}/" "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  ( cd "$MA_FIX" && env PATH="$TO_STUB:$PATH" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$msg" --dir "$2" \
      --provider grok --via acp --timeout-secs "$3" ) >/dev/null 2>&1
}
note_of() { sed -n 's/.*"note": "\(.*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }
status_of() { sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }

R16="$WORK/ma-leg16"; mkdir -p "$R16"
TO_STUB_OUT="$(printf 'VERDICT: APPROVE\n\n## Summary\nlooks fine so far\n\n## Findings\n### Blocking\n- None.\n\n### Advisory\n- I was still writing when the bud')" \
  run_to_leg 6 "$R16" 1
[ "$(status_of "$R16")" = "completed" ] \
  && ok "a truncated-but-parseable turn is still delivered (the review is not discarded)" \
  || fail "partial reply was discarded (status $(status_of "$R16"))"
case "$(note_of "$R16")" in
  *TRUNCATED*) ok "...but it is flagged as possibly TRUNCATED rather than shipped silently" ;;
  *) fail "a budget-killed partial reply shipped with note: $(note_of "$R16")" ;;
esac

# UNSTRUCTURED partial output: the budget must be the HEADLINE, not a parenthetical tail,
# or the operator reads a formatting complaint and goes hunting the wrong bug again.
R17="$WORK/ma-leg17"; mkdir -p "$R17"
TO_STUB_OUT="I am partway through reviewing and was cut o" run_to_leg 7 "$R17" 1
case "$(note_of "$R17")" in
  "turn exceeded its"*) ok "an overrun leads with the budget, not with a parser complaint" ;;
  *) fail "budget was not the headline (got: $(note_of "$R17"))" ;;
esac
case "$(note_of "$R17")" in
  *"broker also said"*) ok "the broker's own complaint survives as the secondary detail" ;;
  *) fail "the broker detail was dropped from the overrun note" ;;
esac

# CONTROL: a turn that finishes WELL inside its budget must stay silent, or the warning is
# noise on every ACP turn and the operator learns to ignore it.
R18="$WORK/ma-leg18"; mkdir -p "$R18"
TO_STUB_SLEEP=0 TO_STUB_OUT="$(printf 'VERDICT: APPROVE\n\n## Summary\na complete review\n\n## Findings\n### Blocking\n- None.\n\n### Advisory\n- None.')" \
  run_to_leg 8 "$R18" 5
[ "$(status_of "$R18")" = "completed" ] && [ -z "$(note_of "$R18")" ] \
  && ok "control: a turn inside its budget carries no truncation warning" \
  || fail "the warning fires on a turn that did not overrun (note: $(note_of "$R18"))"

# A MALFORMED budget must not leak a bash error and must not silently revert the diagnosis.
R19="$WORK/ma-leg19"; mkdir -p "$R19"
TO_ERR="$( { ( cd "$MA_FIX" && env PATH="$TO_STUB:$PATH" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$MA_MSG15" --dir "$R19" \
    --provider grok --via acp --timeout-secs notanumber ) >/dev/null; } 2>&1 || true)"
case "$TO_ERR" in
  *"integer expression expected"*) fail "a malformed budget leaks a bash arithmetic error" ;;
  *) ok "a malformed timeout budget is handled without a bash error" ;;
esac
# ...and it must FALL BACK rather than reach acpx: the value is handed to acpx on its own
# --timeout flag, so validating it at the point of the arithmetic was already too late.
case "$TO_ERR" in
  *"not a usable budget"*) ok "a malformed budget is reported as unusable" ;;
  *) fail "a malformed budget was not reported (got: $(printf '%.120s' "$TO_ERR"))" ;;
esac
# A SLOW FAILURE IS NOT A KILL. Any failure that happened to outlast the budget was being
# relabelled "killed mid-work" with exit 124 — acpx usage, session and permission errors,
# and broker validation failures alike. A budget kill has a signature: under --format quiet
# acpx exits 0 having produced nothing usable. A non-zero exit is acpx failing, not a kill.
# (codex, panel r1.)
R20="$WORK/ma-leg20"; mkdir -p "$R20"
TO_STUB_RC=2 TO_STUB_OUT="acpx: unknown profile" run_to_leg 9 "$R20" 1
[ "$(status_of "$R20")" = "failed" ] && ok "a non-zero acpx exit still fails the turn" || fail "non-zero acpx exit not failed"
case "$(note_of "$R20")" in
  *"killed mid-work"*) fail "a non-zero acpx exit past the budget was mislabelled as a budget kill" ;;
  *) ok "a slow FAILURE is not relabelled as a budget kill" ;;
esac
case "$(note_of "$R20")" in
  *"budget"*) ok "...but the elapsed-vs-budget context is still reported" ;;
  *) fail "budget context lost on a non-zero acpx exit" ;;
esac
# THE REAL TIMEOUT EXIT CODE. Pinned acpx times the prompt then salvages: a salvaged reply
# returns 0, and a failed salvage rethrows and exits 3 — which helpers/acp.sh already
# documents as TIMEOUT. Treating rc=0 as the whole signature meant a genuine rc=3 timeout
# fell to the generic branch and was never named as a kill.
# (codex + grok, corroborated, panel r2.)
R21="$WORK/ma-leg21"; mkdir -p "$R21"
TO_STUB_RC=3 run_to_leg 1 "$R21" 1
case "$(note_of "$R21")" in
  *"killed mid-work"*) ok "an acpx exit-3 timeout is named as a budget kill" ;;
  *) fail "rc=3 timeout was not recognised (got: $(note_of "$R21"))" ;;
esac
# ...while codes that are NOT timeouts stay out of the pair.
R22="$WORK/ma-leg22"; mkdir -p "$R22"
TO_STUB_RC=5 run_to_leg 2 "$R22" 1
case "$(note_of "$R22")" in
  *"killed mid-work"*) fail "a permission failure (exit 5) was relabelled a budget kill" ;;
  *) ok "a permission failure past the budget is still not a kill" ;;
esac
# R23 is the rc=3 DEFINITE-kill case: acpx itself reported the timeout, so the broker never
# ran and there is no send-failure alternative to hedge toward. The hedge belongs to rc=0
# (leg 17), asserted just below. Do not "fix" this back to expecting a hedge.
# (grok, panel r2; codex narrowed it to rc=0, panel r3.)
R23="$WORK/ma-leg23"; mkdir -p "$R23"
TO_STUB_RC=3 TO_STUB_OUT="partial text that will not broker" run_to_leg 3 "$R23" 1
case "$(note_of "$R23")" in
  "turn exceeded its"*) ok "an overrun with output still leads with the budget" ;;
  *) fail "budget stopped being the headline (got: $(note_of "$R23"))" ;;
esac
case "$(note_of "$R23")" in
  *"probably killed"*) fail "an rc=3 timeout hedged toward a send failure that cannot have happened" ;;
  *) ok "an rc=3 timeout states the kill plainly — the broker never ran, so there is no alternative" ;;
esac
# ...and the hedge applies where it IS possible: rc=0 with output, where the broker was
# attempted and could have failed to stamp or send. Leg 17 is that shape. (codex, panel r3.)
case "$(note_of "$R17")" in
  *"probably killed"*) ok "an rc=0 overrun WITH output hedges, because the broker did run" ;;
  *) fail "rc=0 overrun-with-output did not hedge (got: $(note_of "$R17"))" ;;
esac
# BUDGET VALIDATION is about what reaches acpx, not about what the warning says. Assert the
# effective argv, or any implementation that merely utters the words passes.
# (grok, panel r2 — the tautological-assertion catch.)
BBN=0
for bbcase in "0:1800" "08:8" "9999999999999999999:1800" "notanumber:1800" "3600:3600" "01800:1800"; do
  BBN=$((BBN+1))
  badbudget="${bbcase%%:*}"; wantbudget="${bbcase##*:}"
  RB="$WORK/ma-badbudget-$BBN"; mkdir -p "$RB"
  ARGVLOG="$RB/argv.txt"; : > "$ARGVLOG"
  BB_ERR="$( { TO_STUB_ARGV="$ARGVLOG" TO_STUB_SLEEP=0 run_to_leg "b$BBN" "$RB" "$badbudget"; } 2>&1 || true)"
  case "$BB_ERR" in
    *"integer expression expected"*) fail "budget '$badbudget' leaked a bash arithmetic error" ;;
    *) ok "budget '$badbudget' produced no bash arithmetic error" ;;
  esac
  # A value that stripping made LEGAL must never be called unusable, or the message
  # contradicts the budget it then honours. (codex + grok, panel r4.)
  if [ "$wantbudget" = "8" ]; then
    case "$BB_ERR" in
      *"not a usable budget"*) fail "a normalised budget '$badbudget' was called unusable" ;;
      *) ok "a normalised budget '$badbudget' is reported as read, not as unusable" ;;
    esac
  fi
  grep -q -- "--timeout $wantbudget " "$ARGVLOG" 2>/dev/null \
    && ok "budget '$badbudget' reached acpx as ${wantbudget}s" \
    || fail "budget '$badbudget' should reach acpx as ${wantbudget}s (argv: $(head -1 "$ARGVLOG" 2>/dev/null))"
done

# Question leg (/ask grok path): the stub STILL emits a leading canonical
# VERDICT line — for a consult that line must become body text, never metadata.
MA_MSGQ="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-41-00_ask-q-1.md"
cat > "$MA_MSGQ" <<QEOF
---
type: question
from: claude
timestamp: 2026-08-20T14:41:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-20T09-41-00_ask-q-1
---

## Question
Is the retry approach sound?
QEOF
RQ="$WORK/ma-legq"; mkdir -p "$RQ"
run_grok_leg "$MA_MSGQ" "$RQ" >/dev/null 2>&1
QREPLY="$(find "$MA_FIX/.comms/to-claude" -name '*grok-reply*' -type f | sort | tail -1)"
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RQ/result.json" | head -1)" = "completed" ] \
  && ok "question leg completes" || fail "question leg status"
sed -n '2,/^---$/p' "$QREPLY" | grep -q '^type: response$' \
  && ok "question reply stamped type: response" || fail "question reply type"
[ "$(sed -n '2,/^---$/p' "$QREPLY" | grep -c '^verdict:')" = "0" ] \
  && ok "question reply carries NO verdict field" || fail "question verdict leak"
grep -q '^VERDICT: APPROVE$' "$QREPLY" \
  && ok "stray verdict line preserved as consult body text" || fail "consult body preservation"
[ ! -f "$MA_MSGQ" ] && [ -f "$MA_FIX/.comms/archive/$(basename "$MA_MSGQ")" ] \
  && ok "question inbound archived to the sender-derived owner" || fail "question archive movement"

# Prompt-shape contracts (first-live-consult findings, codex-triaged):
grep -q 'NOT a review' "$RQ/prompt.md" && ! grep -q 'Review discipline:' "$RQ/prompt.md" \
  && ! grep -q "VERDICT: APPROVE' or" "$RQ/prompt.md" && grep -q 'Grok Take' "$RQ/prompt.md" \
  && ok "consult prompt carries no reviewer framing or verdict bar" || fail "consult prompt split"
grep -q 'Review discipline:' "$R1/prompt.md" && grep -q 'completeness, architecture' "$R1/prompt.md" \
  && grep -q 'Acceptance criteria' "$R1/prompt.md" && ! grep -q 'NOT a review' "$R1/prompt.md" \
  && ok "review prompt carries the bar + plan focus + criteria pointer" || fail "review prompt round 1"
grep -q 'round 2' "$R2A/prompt.md" && grep -q 'blank checklist' "$R2A/prompt.md" \
  && grep -q 'bar does not move' "$R2A/prompt.md" \
  && ok "round-2 prompt carries holistic re-review + pinned-criteria rule" || fail "review prompt round 2 playbook"
grep -q 'entry points' "$R2B/prompt.md" && grep -q 'Phase focus (implement)' "$R2B/prompt.md" \
  && ok "implement prompt carries the checklist" || fail "implement prompt checklist"
grep -q 'rev-parse HEAD' "$R1/prompt.md" && grep -q 'THE REVIEW IS THE WORK' "$R1/prompt.md" \
  && ok "review prompt carries the inspection contract" || fail "inspection contract"

# FAIL-CLOSED: a review turn with no obtainable verdict discipline must refuse
# BEFORE the child runs; a question turn under identical conditions completes.
BARE="$WORK/bare-helpers"; mkdir -p "$BARE"
cp "$REPO/helpers/comms.sh" "$REPO/helpers/runphase.sh" "$BARE/"
chmod +x "$BARE"/*.sh
MA_MSGFC="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-45-00_failclosed-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-7/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGFC"
RFC1="$WORK/ma-legfc"; mkdir -p "$RFC1"
mkdir -p "$WORK/no-bar"
(cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" CODEX_SKILLS_DIR="$WORK/no-skills" \
   AGENT_COMMS_HOME="$WORK/no-bar" \
   COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$BARE/runphase.sh" run --message "$MA_MSGFC" --dir "$RFC1" --provider grok) >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RFC1/result.json" | head -1)" = "failed" ] \
  && grep -q 'no review bar' "$RFC1/result.json" && [ -f "$MA_MSGFC" ] && [ ! -s "$RFC1/events.ndjson" ] \
  && ok "review turn with no discipline fails closed BEFORE the child runs" || fail "discipline fail-closed"
MA_MSGFQ="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-46-00_fcq-1.md"
sed -e 's/^type: review-request$/type: question/' -e 's/^thread: ma-arc-1$/thread: ma-arc-8/' \
    -e '/^workflow:/d' -e '/^phase:/d' -e '/^round:/d' -e '/^max-rounds:/d' \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGFQ"
RFC2="$WORK/ma-legfq"; mkdir -p "$RFC2"
(cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" CODEX_SKILLS_DIR="$WORK/no-skills" \
   AGENT_COMMS_HOME="$WORK/no-bar" \
   COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$BARE/runphase.sh" run --message "$MA_MSGFQ" --dir "$RFC2" --provider grok) >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RFC2/result.json" | head -1)" = "completed" ] \
  && ok "question turn completes without the review bar (never loads it)" || fail "question turn under bare install"

# THE RESOLVER'S TIER ORDER, behaviourally. A project that pins its own review bar must keep
# winning after the bar moved out of the codex skills, and "works in this checkout" is exactly the
# failure this move could have shipped — the repo tier resolves here and would mask a broken
# installed tier. Extracted and eval'd: the tiers ARE the behaviour, so a source grep proving the
# paths are spelled out would prove nothing about precedence. (contraction step 3, S3-1.)
RB_FN="$(sed -n '/^fragment_file() {/,/^}/p' "$REPO/helpers/runphase.sh")"
RB_P="$WORK/rb-proj"; RB_G="$WORK/rb-glob"; RB_R="$WORK/rb-repo"
mkdir -p "$RB_P/.agents/loopspec-fragments" "$RB_G/loopspec-fragments" "$RB_R/docs/loopspec/fragments" "$RB_R/helpers"
printf 'PROJECT\n' > "$RB_P/.agents/loopspec-fragments/verdict-discipline.md"
printf 'GLOBAL\n'  > "$RB_G/loopspec-fragments/verdict-discipline.md"
printf 'REPO\n'    > "$RB_R/docs/loopspec/fragments/verdict-discipline.md"
rb_resolve() {  # <main-root> -> the tier's marker word, or MISS
  ( eval "$RB_FN"; HELPER_DIR="$RB_R/helpers"; AGENT_COMMS_HOME="$RB_G"
    f="$(fragment_file verdict-discipline "$1" 2>/dev/null || true)"
    [ -n "$f" ] && cat "$f" || printf 'MISS\n' )
}
[ "$(rb_resolve "$RB_P")" = "PROJECT" ] \
  && ok "a project-pinned review bar wins over the global install" || fail "project tier did not win"
[ "$(rb_resolve "$WORK/rb-absent")" = "GLOBAL" ] \
  && ok "the INSTALLED bar resolves when a project pins none — the tier a checkout-only move would break" || fail "global tier did not resolve"
[ "$( ( eval "$RB_FN"; HELPER_DIR="$RB_R/helpers"; AGENT_COMMS_HOME="$WORK/rb-none"
        f="$(fragment_file verdict-discipline "$WORK/rb-absent" 2>/dev/null || true)"
        [ -n "$f" ] && cat "$f" || printf 'MISS\n' ) )" = "REPO" ] \
  && ok "the repo checkout is the last tier, not the first" || fail "repo tier precedence wrong"
[ "$( ( eval "$RB_FN"; HELPER_DIR="$WORK/rb-none/helpers"; AGENT_COMMS_HOME="$WORK/rb-none"
        fragment_file verdict-discipline "$WORK/rb-absent" >/dev/null 2>&1 && printf 'FOUND\n' || printf 'MISS\n' ) )" = "MISS" ] \
  && ok "the resolver returns non-zero when every tier misses, so the caller can fail closed" || fail "resolver did not miss cleanly"

# Mailbox isolation: the parent assembles the prompt; the child is given NO
# mailbox path, NO helper invocation, and no way to reach another thread. An
# inherited env var was NOT a boundary (a child with shell access can unset it),
# so the guarantee is: nothing to query + kernel read-limit to CWD (strict).
SENS="$MA_FIX/.comms/archive/${MA_WS}_2026-08-19T01-00-00_other-thread-1.md"
cat > "$SENS" <<SEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-19T01:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-19T01-00-00_other-thread-1
thread: unrelated-arc-99
verdict: APPROVE
---

## Summary
SENSITIVE-UNRELATED-CONTENT lives here
SEOF
# The target thread MUST have prior history, or the context path never runs and
# the isolation assertions pass vacuously (round-3 review caught exactly that).
PRIOR="$MA_FIX/.comms/archive/${MA_WS}_2026-08-19T05-00-00_prior-round-1.md"
cat > "$PRIOR" <<PEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-19T05:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-19T05-00-00_prior-round-1
thread: ma-arc-10
workflow: auto-implement
phase: implement
round: 1
verdict: REQUEST_CHANGES
---

## Summary
LEGITIMATE-PRIOR-ROUND-CONTEXT for this very thread

### Blocking
- .comms/archive/agent-comms_2026-08-19T00-00-00_x.md — realistic review prose
  naming comms.sh and archive-search, exactly as this project's reviews do.
PEOF
# Adversarial: an UNRELATED thread whose BODY quotes the target thread id — a
# literal grep would pull it in along with its adjacent secret.
QUOTER="$MA_FIX/.comms/archive/${MA_WS}_2026-08-19T06-00-00_quoter-1.md"
cat > "$QUOTER" <<QEOF2
---
type: review-feedback
from: codex
timestamp: 2026-08-19T06:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-19T06-00-00_quoter-1
thread: unrelated-arc-98
verdict: APPROVE
---

## Summary
Cross-reference to ma-arc-10 appears here, and so does SENSITIVE-QUOTER-SECRET
QEOF2
MA_MSGISO="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-48-00_isolation-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-10/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGISO"
RISO="$WORK/ma-legiso"; mkdir -p "$RISO"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_MSGISO" "$RISO" >/dev/null 2>&1
grep -q 'LEGITIMATE-PRIOR-ROUND-CONTEXT' "$RISO/prompt.md" \
  && ok "parent context path actually ran (prior round present)" || fail "prior-context path did not run"
grep -q 'SENSITIVE-UNRELATED-CONTENT' "$RISO/prompt.md" \
  && fail "LEAK: unrelated archived thread reached the generated prompt" \
  || ok "unrelated archived threads never reach the generated prompt"
grep -q 'SENSITIVE-QUOTER-SECRET' "$RISO/prompt.md" \
  && fail "LEAK: an unrelated thread QUOTING the target id reached the prompt" \
  || ok "thread match is exact frontmatter, not a body-quote grep"
# Honest contract (round-4 escalation, user-decided): paths CAN appear inside
# quoted review prose — this project's reviews discuss .comms by nature, and
# redacting them would degrade the review. What must hold: the renderer adds no
# paths of its own, and the prompt tells the child not to act on quoted ones.
grep -q 'do not run comms helpers even' "$RISO/prompt.md" \
  && ok "prompt instructs the child not to act on quoted helper mentions" || fail "quoted-mention instruction"
grep -q 'no mailbox access' "$RISO/prompt.md" \
  && fail "prompt still makes the unattainable no-mailbox-access claim" \
  || ok "prompt makes no claim it cannot keep"
# The checkable contract: the prompt SCAFFOLDING (everything the parent writes
# itself, excluding quoted message/prior-context blocks) advertises no helper and
# no mailbox path. Quoted review prose may contain both — this project's reviews
# discuss .comms by nature — which is why the kernel deny-profile, not path
# secrecy, is the boundary.
SCAFFOLD="$WORK/prompt-scaffold.txt"
awk '/----- BEGIN (MESSAGE|PRIOR CONTEXT) -----/{skip=1} /----- END (MESSAGE|PRIOR CONTEXT) -----/{skip=0; next} !skip' \
  "$RISO/prompt.md" > "$SCAFFOLD"
grep -q 'archive-search' "$SCAFFOLD" && fail "prompt scaffolding still advertises archive-search" \
  || ok "prompt scaffolding advertises no mailbox query helper"
grep -qE '"\$COMMS"|comms\.sh ' "$SCAFFOLD" && fail "prompt scaffolding still invokes a comms helper" \
  || ok "prompt scaffolding invokes no comms helper"
grep -qE '\.comms/(archive|to-)' "$SCAFFOLD" && fail "prompt scaffolding still emits a mailbox path" \
  || ok "prompt scaffolding emits no mailbox path"
grep -q 'archive-search' "$RISO/prompt.md" \
  && ok "control: quoted review prose DOES carry helper names (the honest case)" \
  || fail "fixture is not realistic — quoted prose lacks helper names"
grep -q "$MA_FIX/.comms" "$RISO/prompt.md" && fail "prompt leaks a mailbox path" \
  || ok "no mailbox path outside quoted material"
grep -q 'BEGIN MESSAGE' "$RISO/prompt.md" && grep -q 'inlined here by the' "$RISO/prompt.md" \
  && ok "parent inlines the message the child must review" || fail "message inlining"
grep -q -- '--sandbox read-only' "$GROK_STUB_LOG" \
  && ok "grok argv defaults to the read-only sandbox" || fail "sandbox argv"
: > "$GROK_STUB_LOG"
# Fresh inbound: the isolation leg archived its own message.
MA_MSGSBX="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-49-00_sandbox-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-11/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGSBX"
mkdir -p "$WORK/ma-legsbx" "$WORK/ma-legsbx2"
(cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   COMMS_RUNPHASE_GROK_SANDBOX=agent-comms-review "$RP" run --message "$MA_MSGSBX" --dir "$WORK/ma-legsbx" --provider grok) >/dev/null 2>&1 || true
grep -q -- '--sandbox agent-comms-review' "$GROK_STUB_LOG" \
  && ok "operator custom sandbox profile is honored by the runner" || fail "custom sandbox selection"
MA_MSGSBX2="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-50-00_sandbox-2.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-12/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGSBX2"
for badsbx in off devbox workspace "not a name"; do
  cp "$MA_MSGSBX2" "$MA_MSGSBX2.keep" 2>/dev/null || true
  OUTSBX="$( (cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      COMMS_RUNPHASE_GROK_SANDBOX="$badsbx" "$RP" run --message "$MA_MSGSBX2" --dir "$WORK/ma-legsbx2" --provider grok) 2>&1 )" && rcs=0 || rcs=$?
  [ "$rcs" -ne 0 ] && echo "$OUTSBX" | grep -qi 'refuse\|must be a bare profile' \
    && ok "sandbox knob refuses '$badsbx'" || fail "sandbox knob refusal for '$badsbx' (rc=$rcs)"
  mv -f "$MA_MSGSBX2.keep" "$MA_MSGSBX2" 2>/dev/null || true
done
rm -f "$SENS" "$PRIOR" "$QUOTER"

# Fail-closed also when the fragment RESOLVES BUT IS EMPTY — the successor to the old
# "skill exists, markers absent" case. The two causes stay distinguishable: "never installed" and
# "installed but empty" need different fixes, and a refusal that says only "unavailable" makes the
# operator guess. (S3-1.)
MARKERLESS="$WORK/markerless-home"; mkdir -p "$MARKERLESS/loopspec-fragments"
: > "$MARKERLESS/loopspec-fragments/verdict-discipline.md"
MA_MSGFM="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-47-00_markerless-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-9/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_MSGFM"
RFM="$WORK/ma-legfm"; mkdir -p "$RFM"
(cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" AGENT_COMMS_HOME="$MARKERLESS" \
   COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$BARE/runphase.sh" run --message "$MA_MSGFM" --dir "$RFM" --provider grok) >/dev/null 2>&1
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$RFM/result.json" | head -1)" = "failed" ] \
  && grep -q 'resolved but is EMPTY' "$RFM/result.json" \
  && ok "an empty fragment fails closed and names THAT cause, not a generic one" || fail "markerless fail-closed"

# Parent-stamped envelope: the successful legs prove the authority — re-assert
# the stamped fields on the leg-1 reply match the INBOUND turn exactly.
grep -q '^in-reply-to: '"${MA_WS}"'_2026-08-20T09-00-00_review-req-1$' "$REPLY1" \
  && grep -q '^workflow: auto-full$' "$REPLY1" && grep -q '^round: 1$' "$REPLY1" \
  && ok "stamped envelope binds the reply to the inbound turn" || fail "envelope-binding assertion"
# Identity copy is a live broker_stamp path, on a request send already pinned. Do not
# stamp MA_MSG itself: that mounts every grok-stub leg and drops the unmounted
# inspection-contract prompt.
MA_PIN="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-58-00_pin-id-1.md"
sed -e 's/^thread: ma-arc-1$/thread: ma-arc-pin/' \
    -e "s|^message_id: .*|message_id: ${MA_WS}_2026-08-20T09-58-00_pin-id-1|" \
  "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$MA_PIN"
run_ma send --to grok "$MA_PIN" >/dev/null 2>&1 || true
MA_PIN_AID="$(sed -n '2,/^---$/p' "$MA_PIN" | grep -m1 '^artifact_id:' | sed 's/^artifact_id: //')"
MA_PIN_SHA="$(sed -n '2,/^---$/p' "$MA_PIN" | grep -m1 '^head_sha:' | sed 's/^head_sha: //')"
RPIN="$WORK/ma-leg-pin"; mkdir -p "$RPIN"
GROK_STUB_VERDICT=APPROVE run_grok_leg "$MA_PIN" "$RPIN" >/dev/null 2>&1
REPLY_PIN="$(find "$MA_FIX/.comms/to-claude" -type f -name '*grok-reply*' -newer "$RPIN/prompt.md" | head -1)"
[ -n "$MA_PIN_AID" ] && [ -n "$REPLY_PIN" ] && grep -q "^artifact_id: $MA_PIN_AID$" "$REPLY_PIN" \
  && ok "broker_stamp copies the request's artifact_id onto the reply" \
  || fail "broker_stamp artifact_id (aid=$MA_PIN_AID reply=$(grep '^artifact_id:' "$REPLY_PIN" 2>/dev/null))"
[ -n "$MA_PIN_SHA" ] && [ -n "$REPLY_PIN" ] && grep -q "^head_sha: $MA_PIN_SHA$" "$REPLY_PIN" \
  && ok "broker_stamp copies the request's head_sha onto the reply" \
  || fail "broker_stamp head_sha (sha=$MA_PIN_SHA reply=$(grep '^head_sha:' "$REPLY_PIN" 2>/dev/null))"

section "runphase: the parent-brokered prompt is provider-neutral"
# The broker gate is `provider = grok OR via = acp` (runphase.sh), so this prompt is built for
# claude and codex turns too. Anything that hardcodes grok on that path misattributes or
# mislabels another agent's review. cap_word is unit-tested by EXTRACTING the function rather
# than grepping for it, because the capitalization is the behavior the header depends on.
PB_RP="$REPO/helpers/runphase.sh"
PB_CAP="$(sed -n '/^cap_word() {/,/^}/p' "$PB_RP")"
[ -n "$PB_CAP" ] && ok "cap_word is defined as a single extractable accessor" || fail "cap_word missing"
PB_OUT="$(eval "$PB_CAP"; printf '%s|%s|%s' "$(cap_word grok)" "$(cap_word codex)" "$(cap_word claude)")"
[ "$PB_OUT" = "Grok|Codex|Claude" ] \
  && ok "cap_word title-cases each agent name (Grok|Codex|Claude)" || fail "cap_word output: $PB_OUT"
PB_EMPTY="$(eval "$PB_CAP"; cap_word "" 2>/dev/null; printf 'x')"
[ "$PB_EMPTY" = "x" ] && ok "cap_word on an empty name yields nothing, not a stray capital" || fail "cap_word empty"

# The consult header follows the agent. The grok arc above proves the rendered form
# ('Grok Take') behaviorally; these pin that no literal remains to regress to.
grep -q '## \$agent_title Take' "$PB_RP" \
  && ok "the consult header interpolates the agent, not a literal provider name" || fail "consult header not parameterized"
! grep -q '## Grok Take' "$PB_RP" \
  && ok "no hardcoded 'Grok Take' survives in the shared prompt" || fail "literal Grok Take still present"

# A missing agent REFUSES. Defaulting published another agent's review under grok's name.
# ANY `:-grok` default in non-comment code, not just the arg-5 form. The exact-form grep this
# replaces was blind to `${GROK_AGENT:-grok}` on the line that stamps `from:`, which is the one
# that actually decides whose name a published review carries. (grok, implement r1, advisory.)
PB_DEFAULTS="$(grep -vE '^[[:space:]]*#' "$PB_RP" | grep -c ':-grok' || true)"
[ "$PB_DEFAULTS" = "0" ] \
  && ok "no ':-grok' identity default survives anywhere in executable code" \
  || fail "grok identity default still present on $PB_DEFAULTS code line(s)"
grep -q 'without an agent name — refusing' "$PB_RP" \
  && ok "a brokered prompt built without an agent refuses instead of stamping a default identity" \
  || fail "no fail-closed refusal for a missing agent"
# BEHAVIORAL, not a grep: the guard runs before any dependency the function has, so the whole
# function can be extracted and called with four arguments to prove the refusal actually fires.
# (codex, implement r1, advisory — the greps above prove the default is gone, not that it refuses.)
PB_FN="$(sed -n '/^build_grok_prompt() {/,/^}/p' "$PB_RP")"
PB_PRED_FN="$(sed -n '/^agent_name_ok() {/,/^}/p' "$PB_RP")"
# Without this the two extracted-guard tests below pass because `agent_name_ok` is MISSING, not
# because the guard works — a vacuous pass that both reviewers caught in round 3.
PB_INSCOPE="$(eval "$PB_PRED_FN"; eval "$PB_FN"; type agent_name_ok >/dev/null 2>&1 && printf 'yes' || printf 'no')"
[ "$PB_INSCOPE" = "yes" ] \
  && ok "the extracted guard scope really defines agent_name_ok (no command-not-found pass)" \
  || fail "agent_name_ok absent from the extracted scope — the guard tests would pass vacuously"
PB_GUARD="$(eval "$PB_PRED_FN"; eval "$PB_FN"; GROK_PROMPT_NOTE=""; \
  if build_grok_prompt m r p main 2>/dev/null; then printf 'RETURNED_ZERO'; \
  else printf 'REFUSED|%s' "$GROK_PROMPT_NOTE"; fi)"
case "$PB_GUARD" in
  REFUSED\|*) ok "build_grok_prompt called without an agent REFUSES (behavioral, not a grep)" ;;
  *) fail "missing-agent guard did not refuse: $PB_GUARD" ;;
esac
case "$PB_GUARD" in
  *"without an agent name"*) ok "the missing-agent refusal explains itself in GROK_PROMPT_NOTE" ;;
  *) fail "missing-agent refusal set no explanatory note: $PB_GUARD" ;;
esac

# Runtime notes that reach the operator must name the provider that actually ran.
! grep -qE 'grok prompt build refused|grok broker failed|stamped grok reply failed' "$PB_RP" \
  && ok "broker failure notes name the running provider, not grok" || fail "grok-named broker notes remain"

# Per-attempt broker state is cleared at BOTH entry points; the ACP path enters at
# broker_stamp_and_deliver, which previously reset only BROKER_VALIDATED.
sed -n '/^broker_stamp_and_deliver() {/,/^}/p' "$PB_RP" | grep -q 'GROK_BROKER_NOTE=""' \
  && ok "the ACP broker entry point clears the stale note beside BROKER_VALIDATED" || fail "note not reset on the ACP path"
! grep -q 'GROK_BROKER_DERIVED' "$PB_RP" \
  && ok "the write-only GROK_BROKER_DERIVED is gone (the derivation is logged, not stored)" || fail "dead GROK_BROKER_DERIVED remains"
sed -n '/^broker_stamp_and_deliver() {/,/^}/p' "$PB_RP" | grep -q 'BROKER_REFUSAL_LOGGED=0' \
  && ok "the ACP broker entry clears all THREE per-attempt flags, not two" || fail "BROKER_REFUSAL_LOGGED not reset on the ACP path"
PB_INITS="$(grep -cE '^(BROKER_VALIDATED=0|BROKER_REFUSAL_LOGGED=0|GROK_BROKER_NOTE="")$' "$PB_RP")"
[ "$PB_INITS" = "3" ] \
  && ok "all three per-attempt broker flags are initialised at global scope" || fail "global broker-flag inits: $PB_INITS of 3"
sed -n '/^broker_stamp() {/,/^}/p' "$PB_RP" | grep -q 'no usable agent identity was set' \
  && ok "the from: stamp itself refuses without an identity, not just the prompt build" || fail "identity stamp has no fail-closed guard"
# ONE predicate, both doors. Two guards that differ is the bug shape this repo keeps finding:
# round 2 caught the prompt coercing whitespace while the stamp checked only -z.
PB_IN_PROMPT="$(sed -n '/^build_grok_prompt() {/,/^}/p' "$PB_RP" | grep -c 'agent_name_ok ')"
PB_IN_STAMP="$(sed -n '/^broker_stamp() {/,/^}/p' "$PB_RP" | grep -c 'agent_name_ok ')"
[ "$PB_IN_PROMPT" -ge 1 ] && [ "$PB_IN_STAMP" -ge 1 ] \
  && ok "one agent_name_ok predicate is CALLED inside both the prompt build and the stamp" \
  || fail "agent_name_ok call sites — prompt:$PB_IN_PROMPT stamp:$PB_IN_STAMP"
# The guard must run BEFORE any other global is read, or a bad body gets blamed for a missing
# identity — and under set -u a standalone caller aborts before reaching the refusal.
PB_GUARD_LN="$(awk '/^broker_stamp\(\) \{/{f=1} f&&/agent_name_ok/{print NR; exit}' "$PB_RP")"
PB_RTYPE_LN="$(awk '/^broker_stamp\(\) \{/{f=1} f&&/GROK_RTYPE/{print NR; exit}' "$PB_RP")"
[ -n "$PB_GUARD_LN" ] && [ -n "$PB_RTYPE_LN" ] && [ "$PB_GUARD_LN" -lt "$PB_RTYPE_LN" ] \
  && ok "the stamp identity guard runs before any other broker global is read" \
  || fail "stamp guard at $PB_GUARD_LN is not before the first global read at $PB_RTYPE_LN"
PB_PRED="$(eval "$(sed -n '/^agent_name_ok() {/,/^}/p' "$PB_RP")"; \
  for v in "" "   " "$(printf '\t')" grok; do agent_name_ok "$v" && printf 'Y' || printf 'N'; done)"
[ "$PB_PRED" = "NNNY" ] \
  && ok "agent_name_ok refuses empty, spaces and tab but accepts a real name" || fail "predicate: $PB_PRED"
PB_BLANK="$(eval "$PB_PRED_FN"; eval "$PB_FN"; GROK_PROMPT_NOTE=""; \
  if build_grok_prompt m r p main "   " 2>/dev/null; then printf 'RETURNED_ZERO'; else printf 'REFUSED'; fi)"
[ "$PB_BLANK" = "REFUSED" ] \
  && ok "a whitespace-only agent name is refused, so '##  Take' cannot render" || fail "blank agent accepted: $PB_BLANK"

section "multi-agent: grok arg refusals"
R5="$WORK/ma-leg5"; mkdir -p "$R5"
for bad in "COMMS_RUNPHASE_GROK_ARGS=--sandbox workspace" "COMMS_RUNPHASE_GROK_ARGS=--sandbox off" \
           "COMMS_RUNPHASE_GROK_ARGS=--sandbox devbox" "COMMS_RUNPHASE_GROK_ARGS=--sandbox=off" \
           "COMMS_RUNPHASE_GROK_ARGS=--sandbox=workspace" "COMMS_RUNPHASE_GROK_ARGS=--sandbox=devbox" \
           "COMMS_RUNPHASE_GROK_ARGS=--sandbox=read-only" "COMMS_RUNPHASE_GROK_ARGS=--sandbox strict" "COMMS_RUNPHASE_GROK_ARGS=--always-approve" \
           "COMMS_RUNPHASE_GROK_ARGS=$(printf -- '--sandbox\toff')" \
           "COMMS_RUNPHASE_GROK_ARGS=$(printf -- '--sandbox\nworkspace')" \
           "COMMS_RUNPHASE_GROK_ARGS=--permission-mode=bypassPermissions" \
           "COMMS_RUNPHASE_GROK_PERMISSION_MODE=bypassPermissions"; do
  OUT="$( (cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      "$bad" "$RP" run --message "$MA_MSG4" --dir "$R5" --provider grok) 2>&1 )" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && echo "$OUT" | grep -qi 'refused'; then
    ok "refused: $bad"
  else
    fail "refusal missing for: $bad (rc=$rc)"
  fi
done

section "multi-agent: archive-owner authority (comms.sh send)"
# Retry idempotency: inbound already archived -> no-op success
OUTB="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T09-40-00_r2-1.md"
cat > "$OUTB" <<MAEOF
---
type: review-request
from: claude
timestamp: 2026-08-20T14:40:00Z
workspace: $MA_WS
message_id: ${MA_WS}_2026-08-20T09-40-00_r2-1
thread: ma-arc-1
workflow: auto-full
phase: implement
round: 2
max-rounds: 4
---

body
MAEOF
IDEMP_OUT="$(cd "$MA_FIX" && env "$COMMS" send --to codex "$OUTB" --archive-inbound "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && echo "$IDEMP_OUT" | grep -q 'no-op' && ok "already-archived inbound is a no-op success (retry idempotent)" || fail "archive retry idempotency (rc=$rc)"
# Cross-inbox mismatch: outbound from: claude but inbound sits in to-codex/
STRAY="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T09-50-00_stray-1.md"
cp "$OUTB" "$STRAY"
STATE_ARC1="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_ma-arc-1.json"
STATE_BEFORE="$(cat "$STATE_ARC1" 2>/dev/null || true)"
MISMATCH_OUT="$(cd "$MA_FIX" && env "$COMMS" send --to codex "$OUTB" --archive-inbound "$STRAY" 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$MISMATCH_OUT" | grep -q 'cross-inbox mismatch' \
  && ok "cross-inbox archive mismatch refused" || fail "cross-inbox mismatch refusal (rc=$rc)"
echo "$MISMATCH_OUT" | grep -q 'delivered to' && fail "mismatch must refuse BEFORE delivery" || ok "mismatch refusal precedes delivery (nothing nudged)"
# Was "zero cmux calls", counted from the deleted stub's log — which after S4-4 compared 0 to
# 0 and could not fail. The durable invariant is that the refusal produced NO outbound record.
[ -z "$(find "$MA_FIX/.comms/archive" -name "*stray-1*" 2>/dev/null)" ] \
  && ok "a refused mismatch archives nothing" || fail "mismatch refusal left an archive record"
[ "$(cat "$STATE_ARC1" 2>/dev/null || true)" = "$STATE_BEFORE" ] \
  && ok "mismatch refusal mutates no thread state" || fail "mismatch state atomicity"
rm -f "$STRAY" "$OUTB"
