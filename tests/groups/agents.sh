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

section "review identities: registry, roles and send"
# A REVIEW IDENTITY (`review-agents = claude-review:claude`) runs on a provider under its own
# name, so a claude driver can be reviewed by claude without the two sharing an inbox, a thread
# or awaiting_from. It is review-only. Most rules here are refusals, and a refusal passes
# vacuously when the command could not have succeeded anyway — so each one sits next to a
# CONTROL showing the legitimate neighbour succeeds, and each is judged on its own refusal text
# or on durable state, never on a bare non-zero exit. Every assertion was checked against a
# helper with its rule deliberately broken, and went red.
#
# Its OWN fixture repo: the MA fixture above is pinned to `agents = claude codex grok` by a
# dozen legs, and this section rewrites the config on nearly every assertion.
RI_FIX="$WORK/ri-repo"; mkdir -p "$RI_FIX"; RI_FIX="$(cd "$RI_FIX" && pwd -P)"
git -C "$RI_FIX" init -q -b feature/ri-tests
git -C "$RI_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# to-grok and every review inbox are deliberately NOT created: the missing-inbox scan below
# needs a registered inbox that has never existed, which is the shape install.sh leaves.
mkdir -p "$RI_FIX/.comms/to-claude" "$RI_FIX/.comms/to-codex" "$RI_FIX/.comms/archive"
RI_WS="$(cd "$RI_FIX" && "$COMMS" workspace)"
RI_HEAD="$(git -C "$RI_FIX" rev-parse HEAD)"
RI_MSGS="$WORK/ri-msgs"; mkdir -p "$RI_MSGS"
RI_CFG='agents = claude codex grok\ndefault-target = codex\nreview-agents = claude-review:claude grok-review:grok\n'
ri_cfg() { printf '%b' "$1" > "$RI_FIX/.comms/config"; }
# ri_try <env-args...> — run in the fixture, keep stdout+stderr in RI_OUT and the status in RI_RC.
ri_try() { RI_OUT="$( (cd "$RI_FIX" && env "$@") 2>&1)" && RI_RC=0 || RI_RC=$?; }
# ri_expect <desc> <rc|nonzero> <ERE> — judge the last ri_try on its status AND its words. 126/127
# are "could not execute", never a refusal, so they fail even under `nonzero`.
ri_expect() {
  local rc_ok=0
  case "$RI_RC" in 126|127) rc_ok=0 ;;
    *) case "$2" in nonzero) [ "$RI_RC" -ne 0 ] && rc_ok=1 ;; *) [ "$RI_RC" = "$2" ] && rc_ok=1 ;; esac ;;
  esac
  if [ "$rc_ok" = 1 ] && printf '%s\n' "$RI_OUT" | grep -qE -- "$3"; then ok "$1"
  else fail "$1 (rc=$RI_RC, wanted $2 and /$3/; got: $(printf '%s' "$RI_OUT" | head -3 | tr '\n' ' ' | cut -c1-240))"; fi
}
# ri_msg <path> <type> <from> [frontmatter-line...] — a minimal valid message.
ri_msg() {
  local p="$1" t="$2" fr="$3" l; shift 3
  { printf -- '---\ntype: %s\nfrom: %s\ntimestamp: 2026-09-24T12:00:00Z\nworkspace: %s\nmessage_id: %s\n' \
      "$t" "$fr" "$RI_WS" "$(basename "$p" .md)"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n\n## Summary\nreview identity fixture\n'
  } > "$p"
}
ri_fm_count() { sed -n '2,/^---$/p' "$1" | grep -c "$2" || true; }   # <file> <BRE> — frontmatter hits

# --- the registry: one parse, one accessor per concern ---------------------------------------
# Zero-config first: it is the baseline every "unchanged" assertion below compares against.
ri_try "$COMMS" agents
[ "$RI_RC" = 0 ] && [ "$RI_OUT" = "claude codex grok" ] \
  && ok "zero-config: bare agents is unchanged by the review-identity split" || fail "zero-config agents (rc=$RI_RC got: $RI_OUT)"
ri_try "$COMMS" agents --others claude; RI_ZC_OTHERS="$RI_OUT"
ri_try "$COMMS" agents --review
[ "$RI_RC" = 0 ] && [ -z "$RI_OUT" ] \
  && ok "zero-config declares no review identity (--review is empty, not an error)" || fail "zero-config --review (rc=$RI_RC got: $RI_OUT)"

ri_cfg "$RI_CFG"
ri_try "$COMMS" agents
[ "$RI_RC" = 0 ] && [ "$RI_OUT" = "claude codex grok claude-review grok-review" ] \
  && ok "bare agents lists every identity, drivers first" || fail "agents with review identities (rc=$RI_RC got: $RI_OUT)"
ri_try "$COMMS" agents --drivers
[ "$RI_OUT" = "claude codex grok" ] && ok "agents --drivers lists only the agents= line" || fail "agents --drivers (got: $RI_OUT)"
ri_try "$COMMS" agents --review
[ "$RI_OUT" = "claude-review grok-review" ] && ok "agents --review lists only the review identities" || fail "agents --review (got: $RI_OUT)"
RI_P1="$(cd "$RI_FIX" && "$COMMS" agents --provider claude-review 2>&1)"
RI_P2="$(cd "$RI_FIX" && "$COMMS" agents --provider grok-review 2>&1)"
[ "$RI_P1" = "claude" ] && [ "$RI_P2" = "grok" ] \
  && ok "agents --provider maps each review identity to its declared provider" || fail "--provider review (got: $RI_P1 / $RI_P2)"
RI_P3="$(cd "$RI_FIX" && "$COMMS" agents --provider codex 2>&1)"
[ "$RI_P3" = "codex" ] && ok "agents --provider maps a driver to itself" || fail "--provider driver (got: $RI_P3)"
# An unknown identity must not answer with an empty provider: every spawn resolves through this.
ri_try "$COMMS" agents --provider claude-rev
ri_expect "agents --provider refuses an unregistered name (a prefix of a review identity included)" 1 "unknown agent 'claude-rev'"
ri_try "$COMMS" agents default
[ "$RI_OUT" = "codex" ] && ok "default target is unchanged by declaring review identities" || fail "default target (got: $RI_OUT)"
ri_try "$COMMS" agents --supported
[ "$RI_RC" = 0 ] && printf '%s\n' "$RI_OUT" | grep -q '^claude	' \
  && ! printf '%s\n' "$RI_OUT" | grep -q -- '-review' \
  && ok "--supported stays a provider table with no identity rows" || fail "--supported gained identity rows (got: $RI_OUT)"

# --- every parse refusal, one assertion each ---------------------------------------------------
ri_parse_refuses() {  # <desc> <ERE> <config> — the whole parse is refused, exit 1, with its reason
  ri_cfg "$3"; ri_try "$COMMS" agents; ri_expect "$1" 1 "$2"
}
ri_parse_refuses "a review name equal to its own provider is refused" \
  "config: review agent 'claude' in .* is a provider name" 'agents = claude codex grok\nreview-agents = claude:claude\n'
# The sharper case: a name that is ANOTHER provider. A check of name == own-provider misses it.
ri_parse_refuses "a review name equal to a different provider is refused" \
  "config: review agent 'codex' in .* is a provider name" 'agents = claude codex grok\nreview-agents = codex:claude\n'
ri_parse_refuses "a review identity on an unsupported provider is refused" \
  "config: review agent 'claude-review' in .* names unsupported provider 'gemini'" 'agents = claude codex grok\nreview-agents = claude-review:gemini\n'
ri_parse_refuses "a review entry with no colon is refused, never inferred from its name" \
  "config: malformed review-agents entry 'claude-review' in" 'agents = claude codex grok\nreview-agents = claude-review\n'
ri_parse_refuses "a review entry with two colons is refused" \
  "config: malformed review-agents entry 'claude-review:claude:x'" 'agents = claude codex grok\nreview-agents = claude-review:claude:x\n'
ri_parse_refuses "a review entry with an empty name is refused" \
  "config: malformed review-agents entry ':claude'" 'agents = claude codex grok\nreview-agents = :claude\n'
ri_parse_refuses "a review entry with an empty provider is refused" \
  "config: malformed review-agents entry 'claude-review:' in" 'agents = claude codex grok\nreview-agents = claude-review:\n'
# Same name, DIFFERENT provider: last-wins would silently remap a live identity.
ri_parse_refuses "a duplicate review name is refused even on another provider" \
  "config: duplicate review agent 'claude-review'" 'agents = claude codex grok\nreview-agents = claude-review:claude claude-review:codex\n'
ri_parse_refuses "an empty review-agents key is refused" \
  "config: 'review-agents' key present but empty" 'agents = claude codex grok\nreview-agents =\n'
ri_parse_refuses "a duplicate review-agents key is refused, not resolved by precedence" \
  "config: duplicate 'review-agents' key" 'agents = claude codex grok\nreview-agents = claude-review:claude\nreview-agents = grok-review:grok\n'
ri_parse_refuses "a review name outside the agent-name grammar is refused" \
  "config: invalid agent name 'Claude-Review'" 'agents = claude codex grok\nreview-agents = Claude-Review:claude\n'
ri_parse_refuses "a default-target naming a review identity is refused" \
  "config: default-target 'claude-review' is a review-only identity" 'agents = claude codex grok\ndefault-target = claude-review\nreview-agents = claude-review:claude\n'
ri_parse_refuses "a bare claude-review on the agents line stays an unsupported agent" \
  "config: unsupported agent 'claude-review'" 'agents = claude codex claude-review\n'
# Every reader parses the WHOLE config, so a bad review line cannot hide behind a command that
# never asks about review identities.
ri_cfg 'agents = claude codex grok\nreview-agents = claude-review:claude claude-review:codex\n'
ri_try "$COMMS" status
ri_expect "a malformed review-agents line fails status closed too, not only agents" nonzero "config: duplicate review agent 'claude-review'"

# --- the default panel -------------------------------------------------------------------------
ri_cfg "$RI_CFG"
ri_try "$COMMS" agents --others claude
[ "$RI_RC" = 0 ] && [ "$RI_OUT" = "codex,grok" ] && [ "$RI_OUT" = "$RI_ZC_OTHERS" ] \
  && ok "with two or more drivers a review identity never joins the default panel (same as zero-config)" \
  || fail "--others with review identities (rc=$RI_RC got: $RI_OUT, zero-config: $RI_ZC_OTHERS)"
# ONE per provider, first declared: b-review would give dispatch two claude legs to refuse.
ri_cfg 'agents = claude\ndefault-target = claude\nreview-agents = a-review:claude b-review:claude g-review:grok\n'
ri_try "$COMMS" agents --others claude
[ "$RI_RC" = 0 ] && [ "$RI_OUT" = "a-review,g-review" ] \
  && ok "a lone driver falls back to one review identity per provider, first declared" \
  || fail "--others single-driver fallback (rc=$RI_RC got: $RI_OUT)"
ri_cfg 'agents = claude\ndefault-target = claude\n'
ri_try "$COMMS" agents --others claude
ri_expect "a lone driver with no review identity gets exit 2 naming review-agents, not empty output" 2 "review-agents = <name>:<provider>"
ri_cfg "$RI_CFG"
ri_try "$COMMS" agents --others claude-review
ri_expect "--others refuses a review identity: it never drives a loop" 1 "'claude-review' is a review-only identity"

# --- whoami ------------------------------------------------------------------------------------
ri_try COMMS_SELF=claude "$COMMS" whoami
[ "$RI_RC" = 0 ] && [ "$RI_OUT" = "claude" ] && ok "control: whoami resolves a driver named by COMMS_SELF" || fail "whoami control (rc=$RI_RC got: $RI_OUT)"
ri_try COMMS_SELF=claude-review "$COMMS" whoami
ri_expect "whoami refuses COMMS_SELF naming a review identity" 1 "whoami: 'claude-review' is a review-only identity"
# The marker beats every other signal: a same-provider reviewer child carries exactly its
# driver's signals, so without it whoami would answer "claude" from inside claude-review's turn.
ri_try COMMS_REVIEW_TURN=claude-review COMMS_SELF=claude "$COMMS" whoami
ri_expect "whoami fails closed inside a review turn even when COMMS_SELF names a driver" 1 "inside a review turn for 'claude-review'"

# --- validate: who may author what, and what review_provider means by direction ---------------
ri_msg "$RI_MSGS/fb-noprov.md" review-feedback claude-review 'verdict: APPROVE'
ri_try "$COMMS" validate "$RI_MSGS/fb-noprov.md"
ri_expect "a review identity's reply without review_provider is refused" 1 "carries no valid review_provider \(got '<none>'\)"
ri_msg "$RI_MSGS/fb-prov.md" review-feedback claude-review 'verdict: APPROVE' 'review_provider: claude'
ri_try "$COMMS" validate "$RI_MSGS/fb-prov.md"
[ "$RI_RC" = 0 ] && ok "control: the same reply stamped review_provider: claude validates" || fail "stamped review-identity reply (got: $RI_OUT)"
ri_msg "$RI_MSGS/fb-badprov.md" review-feedback claude-review 'verdict: APPROVE' 'review_provider: gemini'
ri_try "$COMMS" validate "$RI_MSGS/fb-badprov.md"
ri_expect "a review identity's reply stamped with an unsupported provider is refused" 1 "carries no valid review_provider \(got 'gemini'\)"
ri_msg "$RI_MSGS/rr-byrev.md" review-request claude-review
ri_try "$COMMS" validate "$RI_MSGS/rr-byrev.md"
ri_expect "a review identity may not author a review-request" 1 "from 'claude-review' is a review-only identity .* not 'review-request'"
ri_msg "$RI_MSGS/rr-bydrv.md" review-request claude
ri_try "$COMMS" validate "$RI_MSGS/rr-bydrv.md"
[ "$RI_RC" = 0 ] && ok "control: the same review-request from a driver validates" || fail "driver review-request (got: $RI_OUT)"
ri_msg "$RI_MSGS/fb-drv-conflict.md" review-feedback codex 'verdict: APPROVE' 'review_provider: claude'
ri_try "$COMMS" validate "$RI_MSGS/fb-drv-conflict.md"
ri_expect "a driver reply claiming another provider is refused (compose could count it twice)" 1 "from driver 'codex' claims review_provider 'claude'"
ri_msg "$RI_MSGS/fb-drv-match.md" review-feedback codex 'verdict: APPROVE' 'review_provider: codex'
ri_msg "$RI_MSGS/fb-drv-none.md" review-feedback codex 'verdict: APPROVE'
RI_V1="$(cd "$RI_FIX" && "$COMMS" validate "$RI_MSGS/fb-drv-match.md" >/dev/null 2>&1 && echo y)"
RI_V2="$(cd "$RI_FIX" && "$COMMS" validate "$RI_MSGS/fb-drv-none.md" >/dev/null 2>&1 && echo y)"
[ "$RI_V1" = y ] && [ "$RI_V2" = y ] \
  && ok "control: a driver reply with its own name or no review_provider validates" || fail "driver reply stamps (match=$RI_V1 none=$RI_V2)"
# On a REQUEST the stamp names the RECIPIENT's provider, so a codex author with a claude stamp is
# the legitimate codex -> claude-review shape, not a contradiction.
ri_msg "$RI_MSGS/rr-cross.md" review-request codex 'review_provider: claude'
ri_try "$COMMS" validate "$RI_MSGS/rr-cross.md"
[ "$RI_RC" = 0 ] && ok "a codex-authored request stamped for claude-review (claude) validates" || fail "cross-provider request stamp (got: $RI_OUT)"
ri_msg "$RI_MSGS/rr-gemini.md" review-request claude 'review_provider: gemini'
ri_try "$COMMS" validate "$RI_MSGS/rr-gemini.md"
ri_expect "a request stamp that is not a supported provider is refused" 1 "review_provider 'gemini' is not a supported provider"
# Membership is EXACT, one name: "claude codex" contains two providers as substrings, and compose
# would otherwise count it as a third provider of its own.
ri_msg "$RI_MSGS/rr-multi.md" review-request claude 'review_provider: claude codex'
ri_try "$COMMS" validate "$RI_MSGS/rr-multi.md"
ri_expect "a multi-word request stamp is refused, not matched as a substring" 1 "review_provider 'claude codex' is not a supported provider"
ri_msg "$RI_MSGS/fb-rev-multi.md" review-feedback claude-review 'verdict: APPROVE' 'review_provider: claude codex'
ri_try "$COMMS" validate "$RI_MSGS/fb-rev-multi.md"
ri_expect "a review identity's reply with a multi-word review_provider is refused" 1 "carries no valid review_provider \\(got 'claude codex'\\)"

# --- a registered inbox that was never created -------------------------------------------------
# BEFORE any send below: send and list both mkdir their target inbox, which would destroy the
# shape under test. to-claude-review, to-grok-review and to-grok have never existed here.
RI_PEND="$RI_FIX/.comms/to-claude/${RI_WS}_2026-09-24T12-10-00_pending-1.md"
ri_msg "$RI_PEND" review-feedback codex 'verdict: APPROVE' 'thread: ri-pending'
ri_try "$COMMS" list --as claude
[ "$RI_RC" = 0 ] && printf '%s\n' "$RI_OUT" | grep -qF "$RI_PEND" \
  && ok "a never-created review inbox does not hide a driver's pending message from list" || fail "list --as claude (rc=$RI_RC got: $RI_OUT)"
ri_try "$COMMS" status
[ "$RI_RC" = 0 ] && printf '%s\n' "$RI_OUT" | grep -qx 'pending in to-claude: 1' \
  && printf '%s\n' "$RI_OUT" | grep -qx 'pending in to-claude-review: 0' \
  && printf '%s\n' "$RI_OUT" | grep -qx 'pending in to-grok-review: 0' \
  && ok "status walks every registered inbox, including never-created review ones, to the last" \
  || fail "status over missing review inboxes (rc=$RI_RC got: $(printf '%s' "$RI_OUT" | tr '\n' '|'))"
# list and status cannot show the hazard on bash 3.2: list mkdirs its own inbox and status wraps
# the scan in `|| true` (verified by deleting the guard: both stay green). The walk that CAN lose
# a reply is leg_reply_candidates, which panel status and compose run over EVERY registered inbox.
# So run the real accessor chain, extracted, under errexit, with a never-created inbox listed
# FIRST (the ROADMAP shape): the reply sitting in to-claude after it must still be found.
RI_SCAN_FNS="$(sed -n -e '/^frontmatter_field() {/,/^}/p' -e '/^file_mtime() {/,/^}/p' -e '/^mtime_iso() {/,/^}/p' \
  -e '/^sort_paths_by_timestamp() {/,/^}/p' -e '/^sorted_message_files() {/,/^}/p' -e '/^leg_reply_candidates() {/,/^}/p' "$COMMS")"
RI_SCAN="$(bash -c 'set -euo pipefail; eval "$1"; leg_reply_candidates "$2" "$3" codex ri-pending "claude-review claude"' \
  _ "$RI_SCAN_FNS" "$RI_FIX" "$RI_WS" 2>&1)" && RI_SCAN_RC=0 || RI_SCAN_RC=$?
[ "$RI_SCAN_RC" = 0 ] && [ "$RI_SCAN" = "$RI_PEND" ] \
  && ok "a leg scan with a never-created inbox listed first still finds the reply behind it" \
  || fail "leg scan over a missing inbox (rc=$RI_SCAN_RC got: $RI_SCAN)"
# Without this the assertions above could pass against inboxes some earlier step created.
[ ! -e "$RI_FIX/.comms/to-claude-review" ] && [ ! -e "$RI_FIX/.comms/to-grok-review" ] \
  && ok "the scans really ran against never-created inboxes (list and status created none)" \
  || fail "a review inbox exists, so the missing-inbox assertions proved nothing"

# --- transport follows the PROVIDER --------------------------------------------------------------
# Real node on a developer's PATH would decide the ACP rung, so both answers are pinned with stub
# nodes: fixture_acp's (a supported version) and one too old to run ACP. The old one moves claude
# to mailbox and grok to headless, so the two identities are compared where the answers differ.
fixture_acp
RI_OLDNODE="$WORK/ri-oldnode"; mkdir -p "$RI_OLDNODE"
printf '#!/bin/bash\necho v10.0.0\n' > "$RI_OLDNODE/node"; chmod +x "$RI_OLDNODE/node"
ri_transport() { (cd "$RI_FIX" && env -u COMMS_DELIVERY PATH="$1:$PATH" "$COMMS" transport "$2" --loop 2>&1); }
RI_T_C="$(ri_transport "$AXB" claude)"; RI_T_CR="$(ri_transport "$AXB" claude-review)"
[ "$RI_T_C" = "acp" ] && [ "$RI_T_CR" = "$RI_T_C" ] \
  && ok "transport claude-review --loop answers exactly what claude does (acp with a usable node)" \
  || fail "transport with ACP available (claude=$RI_T_C claude-review=$RI_T_CR)"
RI_T_C2="$(ri_transport "$RI_OLDNODE" claude)"; RI_T_CR2="$(ri_transport "$RI_OLDNODE" claude-review)"
[ "$RI_T_C2" = "mailbox" ] && [ "$RI_T_CR2" = "$RI_T_C2" ] \
  && ok "...and still matches claude when ACP is unavailable (mailbox)" \
  || fail "transport without ACP (claude=$RI_T_C2 claude-review=$RI_T_CR2)"
RI_T_G2="$(ri_transport "$RI_OLDNODE" grok)"; RI_T_GR2="$(ri_transport "$RI_OLDNODE" grok-review)"
[ "$RI_T_G2" = "headless" ] && [ "$RI_T_GR2" = "$RI_T_G2" ] \
  && ok "a grok-backed review identity routes as grok (headless), not as claude" \
  || fail "grok-review transport (grok=$RI_T_G2 grok-review=$RI_T_GR2)"

# --- the reader's reviewer derivation, executed from the template -------------------------------
# read-from-codex.md derives REVIEWER from the reply's from: and registry-checks it with an
# anchored grep over bare `agents`. Run the template's OWN two lines: a review identity's reply
# must route back to it, and a prefix of its name must not pass the anchored check.
RI_RFC="$REPO/templates/claude-commands/read-from-codex.md"
RI_EXTRACT="$(grep -m1 'REVIEWER=\$(awk' "$RI_RFC" | sed 's/^ *//')"
RI_REGCHK="$(grep -m1 'agents | tr ' "$RI_RFC" | sed 's/^ *//')"
ri_reader() {  # <reply> — the template's extractor + registry check, verbatim, in the fixture
  ( cd "$RI_FIX" && COMMS_SH="$COMMS"; REVIEWER=""
    eval "${RI_EXTRACT/\"<message file>\"/\"$1\"}"; eval "$RI_REGCHK"; printf '%s' "$REVIEWER" )
}
ri_msg "$RI_MSGS/reply-rev.md" review-feedback claude-review 'verdict: APPROVE' 'review_provider: claude'
ri_msg "$RI_MSGS/reply-prefix.md" review-feedback claude-rev 'verdict: APPROVE'
RI_R1="$(ri_reader "$RI_MSGS/reply-rev.md")"
[ -n "$RI_EXTRACT" ] && printf '%s' "$RI_REGCHK" | grep -q 'grep -qx' && [ "$RI_R1" = "claude-review" ] \
  && ok "the reader's extractor and registry check accept a from: claude-review reply" \
  || fail "reader derivation for a review identity (got: '$RI_R1')"
RI_R2="$(ri_reader "$RI_MSGS/reply-prefix.md")"
[ -z "$RI_R2" ] && ok "control: an unregistered prefix of claude-review fails the anchored check" || fail "reader accepted '$RI_R2'"

# --- send: the role rules that need the TARGET -----------------------------------------------
# Every request below is pinned to the fixture HEAD (artifact_id), so send takes the resend path
# and never snapshots: the bytes of two sends can then be compared exactly.
ri_req() {  # <path> <type> <from> <thread> [frontmatter-line...] — a loop message pinned to HEAD
  local p="$1" t="$2" fr="$3" th="$4"; shift 4
  ri_msg "$p" "$t" "$fr" "thread: $th" "workflow: auto" "phase: plan" "round: 1" "max-rounds: 4" "artifact_id: $RI_HEAD" "$@"
}
ri_state() { find "$RI_FIX/.comms/state" -name "*_$1.json" 2>/dev/null | grep -c . || true; }   # <thread>
ri_event() {  # <message_id> — event rows naming it; an absent log counts as none, never as ""
  local n; n="$(grep -cF "$1" "$RI_FIX/.comms/events.tsv" 2>/dev/null)"; printf '%s' "${n:-0}"
}

# Control FIRST, so the durable-write probes are shown to see a real send before they are
# trusted to see a refused one.
RI_OK_REQ="$RI_FIX/.comms/to-claude-review/${RI_WS}_2026-09-24T12-20-00_rq-ok-1.md"
mkdir -p "$(dirname "$RI_OK_REQ")"
ri_req "$RI_OK_REQ" review-request claude ri-rq-ok
ri_try "$COMMS" send --to claude-review "$RI_OK_REQ"
[ "$RI_RC" = 0 ] && [ "$(ri_event "$(basename "$RI_OK_REQ" .md)")" -ge 1 ] && [ "$(ri_state ri-rq-ok)" = 1 ] \
  && ok "claude -> claude-review review-request is accepted (event row and thread state written)" \
  || fail "send to a review identity (rc=$RI_RC events=$(ri_event "$(basename "$RI_OK_REQ" .md)") state=$(ri_state ri-rq-ok) out: $RI_OUT)"
[ "$(ri_fm_count "$RI_OK_REQ" '^review_provider:')" = 1 ] && [ "$(ri_fm_count "$RI_OK_REQ" '^review_provider: claude$')" = 1 ] \
  && ok "send stamps exactly one review_provider: claude on a request to claude-review" \
  || fail "review_provider stamp ($(sed -n '2,/^---$/p' "$RI_OK_REQ" | grep '^review_provider' | tr '\n' '|'))"

RI_SELF="$RI_FIX/.comms/to-claude/${RI_WS}_2026-09-24T12-21-00_self-1.md"
ri_req "$RI_SELF" review-request claude ri-self
ri_try "$COMMS" send --to claude "$RI_SELF"
ri_expect "a claude review-request sent --to claude is refused" 1 "'claude' authored this review-request .* cannot review or answer its own request"
printf '%s\n' "$RI_OUT" | grep -qF -- "--to claude-review" && printf '%s\n' "$RI_OUT" | grep -qF "$RI_SELF" \
  && ok "the self-address refusal names the stranded file and suggests claude-review" || fail "self-address message (got: $RI_OUT)"
[ "$(ri_event "$(basename "$RI_SELF" .md)")" = 0 ] && [ "$(ri_state ri-self)" = 0 ] \
  && ok "the self-address refusal lands before any durable write (no event row, no thread state)" \
  || fail "self-address refusal wrote state (events=$(ri_event "$(basename "$RI_SELF" .md)") state=$(ri_state ri-self))"
# The hint names the review identity FOR THAT PROVIDER: codex has none, so claude-review (a
# claude-backed reviewer) must not be offered as codex's same-model review.
RI_SELF2="$RI_FIX/.comms/to-codex/${RI_WS}_2026-09-24T12-22-00_self-2.md"
ri_req "$RI_SELF2" review-request codex ri-self2
ri_try "$COMMS" send --to codex "$RI_SELF2"
[ "$RI_RC" = 1 ] && printf '%s\n' "$RI_OUT" | grep -qF "'codex' authored this review-request" \
  && ! printf '%s\n' "$RI_OUT" | grep -qF -- "--to claude-review" \
  && ok "a codex self-send is refused without suggesting another provider's review identity" \
  || fail "codex self-address hint (rc=$RI_RC got: $RI_OUT)"
RI_SELFQ="$RI_FIX/.comms/to-claude/${RI_WS}_2026-09-24T12-23-00_selfq-1.md"
ri_msg "$RI_SELFQ" question claude
ri_try "$COMMS" send --to claude "$RI_SELFQ"
ri_expect "a claude question sent --to claude is refused too" 1 "'claude' authored this question"
# ...and its remedy is another DRIVER: a review identity refuses consults, so suggesting one
# would send the caller from one refusal straight into another.
printf '%s\n' "$RI_OUT" | grep -qF "Consult another driver" && ! printf '%s\n' "$RI_OUT" | grep -q -- '-review' \
  && ok "a self-addressed question points at another driver, never at a review identity" \
  || fail "self-addressed question remedy (got: $RI_OUT)"

# A review identity receives exactly what a review turn consumes: requests and the error lane.
RI_Q="$RI_FIX/.comms/to-claude-review/${RI_WS}_2026-09-24T12-24-00_q-1.md"
ri_msg "$RI_Q" question claude
ri_try "$COMMS" send --to claude-review "$RI_Q"
ri_expect "a question to claude-review is refused (it never answers a consult)" 1 "'claude-review' is a review-only identity .* not 'question'"
RI_PING="$RI_FIX/.comms/to-claude-review/${RI_WS}_2026-09-24T12-25-00_ping-1.md"
ri_msg "$RI_PING" ping claude
ri_try "$COMMS" send --to claude-review "$RI_PING"
ri_expect "any other type (ping) to claude-review is refused" 1 "'claude-review' is a review-only identity .* not 'ping'"
RI_ERR="$RI_FIX/.comms/to-claude-review/${RI_WS}_2026-09-24T12-26-00_err-1.md"
ri_msg "$RI_ERR" error claude "thread: ri-rq-ok" "workflow: auto" "phase: plan" "round: 1" "max-rounds: 4" \
  "in-reply-to: ${RI_WS}_2026-09-24T12-20-00_rq-ok-1"
ri_try "$COMMS" send --to claude-review "$RI_ERR"
[ "$RI_RC" = 0 ] && ok "control: an error to claude-review is accepted (the per-leg error lane)" || fail "error to a review identity (rc=$RI_RC out: $RI_OUT)"
# ...and it carries the same binding a request does: the error lane starts a review turn there,
# and runphase refuses any review-identity turn whose inbound names no provider.
[ "$(ri_fm_count "$RI_ERR" '^review_provider: claude$')" = 1 ] \
  && ok "the error lane to claude-review is stamped review_provider: claude, like a request" \
  || fail "error to a review identity carries no binding ($(sed -n '2,/^---$/p' "$RI_ERR" | grep '^review_provider' | tr '\n' '|'))"

# The stamp is helper-owned in BOTH directions: a forged value is replaced by the registry's,
# and a request to a driver carries none at all.
RI_FORGE="$RI_FIX/.comms/to-claude-review/${RI_WS}_2026-09-24T12-27-00_forge-1.md"
ri_req "$RI_FORGE" review-request claude ri-forge "review_provider: codex"
ri_try "$COMMS" send --to claude-review "$RI_FORGE"
[ "$RI_RC" = 0 ] && [ "$(ri_fm_count "$RI_FORGE" '^review_provider:')" = 1 ] \
  && [ "$(ri_fm_count "$RI_FORGE" '^review_provider: claude$')" = 1 ] \
  && ok "a hand-typed review_provider on a request to claude-review is replaced by the registry's" \
  || fail "forged request stamp survived (rc=$RI_RC; $(sed -n '2,/^---$/p' "$RI_FORGE" | grep '^review_provider' | tr '\n' '|'))"
RI_STRIP="$RI_FIX/.comms/to-codex/${RI_WS}_2026-09-24T12-28-00_strip-1.md"
ri_req "$RI_STRIP" review-request claude ri-strip "review_provider: grok"
ri_try "$COMMS" send --to codex "$RI_STRIP"
[ "$RI_RC" = 0 ] && [ "$(ri_fm_count "$RI_STRIP" '^review_provider:')" = 0 ] \
  && ok "a hand-typed review_provider on a request to a driver is stripped" \
  || fail "driver-target stamp not stripped (rc=$RI_RC; $(sed -n '2,/^---$/p' "$RI_STRIP" | grep '^review_provider' | tr '\n' '|'))"

# ZERO-CONFIG BYTES: an ordinary claude -> codex request must come out of send exactly as it did
# before review identities existed. Two checks, because either alone has a blind spot:
#  - send adds nothing but the stamps that predate review identities (artifact_id, head_sha).
#    A comparison between two configs cannot see a stamp added to BOTH -- verified: stamping
#    every request, driver targets included, left that comparison green.
#  - with review-agents absent vs declared, the outputs match once the two lines this fixture
#    varies (thread, message_id) are removed.
RI_PLAIN_A="$RI_FIX/.comms/to-codex/${RI_WS}_2026-09-24T12-29-00_plain-a.md"
RI_PLAIN_B="$RI_FIX/.comms/to-codex/${RI_WS}_2026-09-24T12-29-00_plain-b.md"
ri_req "$RI_PLAIN_A" review-request claude ri-plain-a
ri_req "$RI_PLAIN_B" review-request claude ri-plain-b
cp "$RI_PLAIN_B" "$RI_MSGS/plain-b.before"
ri_cfg 'agents = claude codex grok\ndefault-target = codex\n'
ri_try "$COMMS" send --to codex "$RI_PLAIN_A"; RI_RC_A="$RI_RC"
ri_cfg "$RI_CFG"
ri_try "$COMMS" send --to codex "$RI_PLAIN_B"; RI_RC_B="$RI_RC"
ri_unstamp() { sed -e '/^artifact_id: /d' -e '/^head_sha: /d' "$1"; }
[ "$RI_RC_B" = 0 ] && grep -q '^head_sha: ' "$RI_PLAIN_B" \
  && [ "$(ri_unstamp "$RI_PLAIN_B")" = "$(ri_unstamp "$RI_MSGS/plain-b.before")" ] \
  && ok "with review-agents declared, send adds nothing to a driver request but artifact_id/head_sha" \
  || fail "driver request gained bytes (rc=$RI_RC_B; diff: $(diff <(ri_unstamp "$RI_MSGS/plain-b.before") <(ri_unstamp "$RI_PLAIN_B") | tr '\n' '|'))"
ri_norm() { sed -e '/^message_id: /d' -e '/^thread: /d' "$1"; }
[ "$RI_RC_A" = 0 ] && [ "$RI_RC_B" = 0 ] \
  && [ "$(ri_norm "$RI_PLAIN_A")" = "$(ri_norm "$RI_PLAIN_B")" ] \
  && ok "an ordinary claude -> codex request is byte-identical with and without review-agents declared" \
  || fail "driver request bytes changed (rc A=$RI_RC_A B=$RI_RC_B; diff: $(diff <(ri_norm "$RI_PLAIN_A") <(ri_norm "$RI_PLAIN_B") | tr '\n' '|'))"

# --- ask: an operator verb, drivers only on both ends --------------------------------------------
ri_try "$COMMS" ask --from claude --to codex "is the retry approach sound?"
[ "$RI_RC" = 0 ] && [ -n "$(find "$RI_FIX/.comms/to-codex" -name "${RI_WS}_*_ask-claude-to-codex-*" 2>/dev/null)" ] \
  && ok "control: ask --from claude --to codex writes and sends the question" || fail "ask control (rc=$RI_RC out: $RI_OUT)"
ri_try "$COMMS" ask --from claude-review --to codex "may a reviewer consult?"
ri_expect "ask --from a review identity is refused" nonzero "ask: 'claude-review' is a review-only identity"
[ -z "$(find "$RI_FIX/.comms" -name "*_ask-claude-review-to-*" 2>/dev/null)" ] \
  && ok "...and no question from claude-review was written anywhere" || fail "ask --from claude-review wrote a question"
ri_try "$COMMS" ask --from claude --to claude-review "will you answer a consult?"
ri_expect "ask --to a review identity is a usage error (exit 2)" 2 "ask: 'claude-review' is a review-only identity .* consult a driver"
[ -z "$(find "$RI_FIX/.comms" -name "*_ask-claude-to-claude-review-*" 2>/dev/null)" ] \
  && ok "...and no question was written into claude-review's inbox" || fail "ask --to claude-review wrote a question"

# --- a config value is DATA: never glob-expanded against the caller's cwd ---------------------
# With globbing on, `review-agents = *` expanded to whatever the cwd held — here a file named
# like a valid pair — and silently registered an identity nobody declared.
: > "$RI_FIX/zz-rev:codex"
ri_cfg 'agents = claude codex grok\nreview-agents = *\n'
ri_try "$COMMS" agents
ri_expect "review-agents = * is refused as the literal '*', never expanded to a file name in cwd" 1 \
  "malformed review-agents entry '\\*'"
rm -f "$RI_FIX/zz-rev:codex"
ri_cfg "$RI_CFG"

# --- a from-less inbound to a DRIVER keeps its old reason --------------------------------------
# The review-identity wording ("refusing to guess who reads its reply") is for review identities,
# which have no complement by design. A driver with no complement (grok) was never told it was one.
RI_NOFROM="$MA_FIX/.comms/to-grok/${MA_WS}_2026-09-24T12-40-00_nofrom-1.md"
mkdir -p "$MA_FIX/.comms/to-grok"
sed -e '/^from: /d' -e 's/^thread: .*/thread: ri-nofrom/' "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$RI_NOFROM"
RI_NF_DIR="$WORK/ri-nofrom"; mkdir -p "$RI_NF_DIR"
run_grok_leg "$RI_NOFROM" "$RI_NF_DIR" >/dev/null 2>&1
grep -q "inbound from: '<absent>' is not a registered agent" "$RI_NF_DIR/result.json" 2>/dev/null \
  && ! grep -q 'is a review identity' "$RI_NF_DIR/result.json" \
  && ok "a from-less inbound to a grok driver is refused with the driver wording, not the review-identity one" \
  || fail "from-less grok driver refusal (got: $(sed -n 's/.*"note": "\(.*\)".*/\1/p' "$RI_NF_DIR/result.json" 2>/dev/null))"
rm -f "$RI_NOFROM"
