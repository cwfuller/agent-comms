# Run through tests/run.sh; each group gets fresh fixtures.
section "comms.sh: transport selection (no pane must not strand a consult)"
TR_FIX="$WORK/transport-repo"; mkdir -p "$TR_FIX"; TR_FIX="$(cd "$TR_FIX" && pwd -P)"
git -C "$TR_FIX" init -q -b main
git -C "$TR_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
mkdir -p "$TR_FIX/.comms"
run_tr() { (cd "$TR_FIX" && env -u COMMS_DELIVERY "$COMMS" "$@"); }
run_tr_mailbox() { (cd "$TR_FIX" && env COMMS_DELIVERY=mailbox "$COMMS" "$@"); }

# AN ASKED-FOR MAILBOX IS A SUCCESS. Making `mailbox` requestable put it through a branch that was
# the catch-all for "nothing could deliver", so a caller who got exactly what they asked for was
# told their install was broken and to retry. Pinned END-TO-END through deliver AND send — the two
# consumers this increment fixes — not via the suite-wide default. status is a THIRD consumer and
# is deliberately NOT fixed here: it reads a durable state-file fact, so the correct change is to
# what deliver WRITES (a distinct outcome token), not an env-keyed branch in status. The harness now RUNS on this path, so a
# regression here would be invisible in every other section while quietly telling users to fix
# nothing. A generic `^RESULT: manual` grep is NOT enough: it matches the old
# "NOT spawned … fix and retry" copy too, which is how the send half stayed unpinned in r1.
# (codex r1 blocking; codex + grok r2, corroborated.)
[ "$(run_tr_mailbox transport codex)" = "mailbox" ] \
  && ok "an explicit COMMS_DELIVERY=mailbox is honoured as a transport" || fail "mailbox is not an accepted transport request"
mkdir -p "$TR_FIX/.comms/to-codex"
printf -- '---\ntype: question\nfrom: claude\ntimestamp: 2026-09-01T00:00:00Z\nmessage_id: mbx1\nworkspace: transport-repo\nthread: mbx\n---\n\nhi\n' \
  > "$TR_FIX/.comms/to-codex/transport-repo_2026-09-01T00-00-00_mbx1.md"
TR_MBX="$(run_tr_mailbox deliver codex 2>&1)"
printf '%s\n' "$TR_MBX" | grep -qi 'manual pickup' \
  && ! printf '%s\n' "$TR_MBX" | grep -qi 're-run install.sh' \
  && ok "a deliberate mailbox delivery reports intent, not a broken install" || fail "mailbox delivery still reports a missing capability: $TR_MBX"
printf '%s\n' "$TR_MBX" | grep -qi 'no headless runner' \
  && fail "mailbox delivery still blames a missing headless runner" || ok "mailbox delivery does not blame a missing runner"
# SEND, driven directly. A generic `^RESULT: manual` grep matches the OLD copy too, which is how
# this half stayed unpinned in r1. (codex + grok, S4-1 r2, corroborated.)
printf -- '---\ntype: question\nfrom: claude\ntimestamp: 2026-09-01T00:00:00Z\nmessage_id: mbx2\nworkspace: transport-repo\nthread: mbx2\n---\n\nhi\n' \
  > "$WORK/tr-mbx-send.md"
TR_MBXS="$(run_tr_mailbox send --to codex "$WORK/tr-mbx-send.md" 2>&1 || true)"
printf '%s\n' "$TR_MBXS" | grep -q 'Nothing to fix' \
  && ok "a mailbox SEND reports deliberate pickup, not a retry instruction" || fail "mailbox send still instructs a retry: $(printf '%.90s' "$TR_MBXS")"
printf '%s\n' "$TR_MBXS" | grep -qi 'NOT spawned' \
  && fail "mailbox send still says NOT spawned" || ok "mailbox send does not claim the peer failed to spawn"
# THE CMUX WINDOWS ARE PROCESS-GLOBAL EXPORTS, not section-scoped: a section inserted between a
# `COMMS_DELIVERY=mailbox` and its restore would silently inherit the pane transport — the exact way
# these five sections once inherited the suite default. Pin WHICH banners may appear inside a cmux
# window, so the next harness or group edit fails here instead of using the wrong transport.
# (grok, S4-1 r1, advisory.)
# NOTE the ^export anchor: this line itself starts with TR_WINDOW=, so the pattern cannot
# match its own source. (It briefly did match the harness default after a global cmux->mailbox
# rewrite edited this pattern too — the assertion caught that immediately, which is the point.)
TR_SOURCES=()
while IFS= read -r source_path; do TR_SOURCES+=("$REPO/$source_path"); done < <(git -C "$REPO" ls-files -- 'tests/*.sh' 'tests/lib/*.sh' 'tests/groups/*.sh')
TR_WINDOW="$(grep -h '^export COMMS_DELIVERY=cmux$' "${TR_SOURCES[@]}" | wc -l | tr -d ' ' )"
[ "$TR_WINDOW" = "0" ] \
  && ok "no cmux transport window survives anywhere in the corpus" || fail "$TR_WINDOW cmux window(s) remain after S4-4"

# No cmux surface anywhere: an interactive agent must NOT fall to the mailbox while a
# synchronous transport is available — that is the case that stranded a real consult.
TR_CODEX="$(run_tr transport codex 2>/dev/null)"
[ "$TR_CODEX" = "acp" ] || [ "$TR_CODEX" = "mailbox" ] && ok "transport resolves for codex with no pane (got: $TR_CODEX)" || fail "transport codex (got: $TR_CODEX)"
if bash "$REPO/helpers/acp.sh" supports codex >/dev/null 2>&1; then
  [ "$TR_CODEX" = "acp" ] && ok "with ACP available, no pane routes to acp, never mailbox" || fail "no-pane consult fell to $TR_CODEX despite ACP"
else
  [ "$TR_CODEX" = "mailbox" ] && ok "without ACP, no pane honestly reports mailbox" || fail "no-ACP fallback"
fi

# grok has no interactive surface by definition, so it can never reach a pane.
TR_GROK="$(run_tr transport grok 2>/dev/null)"
if bash "$REPO/helpers/acp.sh" supports grok >/dev/null 2>&1; then
  [ "$TR_GROK" = "acp" ] && ok "a headless-only agent prefers acp for a consult" || fail "grok consult (got: $TR_GROK)"
else
  [ "$TR_GROK" = "headless" ] && ok "a headless-only agent reports headless" || fail "grok consult (got: $TR_GROK)"
fi
# Loops DO route to acp now (2026-08-26): the reviewer permission profile turned out
# to exist — --approve-reads plus --non-interactive-permissions deny — and one live
# loop delivered a stamped reply into the inbox. What a loop must never do is take a
# pane it was not asked for.
[ "$(run_tr transport grok --loop 2>/dev/null)" != "cmux" ] \
  && ok "a headless-only agent's loop never resolves to a pane" || fail "grok loop transport"

# An explicit COMMS_DELIVERY=headless override beats everything — FOR A PROVIDER THAT STILL HAS
# THE HEADLESS PATH. Since step 4 deleted self-send, that is grok only; codex must be refused
# rather than handed a route runphase will reject. (S4-2.)
[ "$( (cd "$TR_FIX" && env COMMS_DELIVERY=headless "$COMMS" transport grok) 2>/dev/null)" = "headless" ] \
  && ok "COMMS_DELIVERY=headless overrides transport selection for a brokered-without-ACP agent" || fail "headless override"
( cd "$TR_FIX" && env COMMS_DELIVERY=headless "$COMMS" transport codex ) >/dev/null 2>&1 \
  && fail "headless was still offered to a provider whose self-send path is gone" \
  || ok "headless is refused for codex — transport never promises a route runphase would reject"

# A LOOP is unattended work: it must not require a pane to be open.
TR_LOOP_DEFAULT="$(run_tr transport codex --loop 2>/dev/null)"
if bash "$REPO/helpers/acp.sh" supports codex >/dev/null 2>&1; then
  [ "$TR_LOOP_DEFAULT" = "acp" ] && ok "a loop defaults to acp — the cheapest measured transport" || fail "loop default (got: $TR_LOOP_DEFAULT)"
else
  # codex is ACP-ONLY since step 4, so with no ACP there is nowhere honest to go but mailbox —
  # NOT headless (its self-send path is gone) and NOT a pane (that is self-send under another
  # name). This branch is idle where ACP works and would have gone red where it does not.
  # (grok, S4-2 implement r1, advisory.)
  [ "$TR_LOOP_DEFAULT" = "mailbox" ] && ok "with no ACP, an ACP-only provider's loop says mailbox" || fail "loop default (got: $TR_LOOP_DEFAULT)"
fi
# A REQUEST for the deleted transport is REFUSED, not silently substituted. This assertion
# previously set COMMS_DELIVERY=mailbox while claiming to test cmux, so it never touched the
# path at all — deleting the special case entirely would have left the suite green. It now
# passes the real value and requires a non-zero exit naming cmux. (codex + grok, S4-4 r1.)
TR_CMUX_OUT="$( (cd "$TR_FIX" && env COMMS_DELIVERY=cmux "$COMMS" transport codex --loop) 2>&1 )" && TR_CMUX_RC=0 || TR_CMUX_RC=$?
[ "$TR_CMUX_RC" != "0" ] && printf '%s\n' "$TR_CMUX_OUT" | grep -q 'cmux pane transport was REMOVED' \
  && ok "a request for the deleted cmux transport is refused, never silently substituted" \
  || fail "cmux request not refused (rc=$TR_CMUX_RC, got: $TR_CMUX_OUT)"
# ...and the refusal is not cmux-specific special-casing: any unknown transport is refused,
# which is the hole that let COMMS_DELIVERY=foo silently take the default ladder. (grok, r1.)
# `ask` is gated at the ROUTER because it WRITES a question file before it ever calls cmd_send.
# The placement was reviewed as correct but untested: prove the refusal happens before the write.
# (codex, followups r1, advisory.)
TR_ASK_BEFORE="$(find "$TR_FIX/.comms" -type f 2>/dev/null | wc -l | tr -d ' ')"
TR_ASK_OUT="$( (cd "$TR_FIX" && env COMMS_DELIVERY=cmux /bin/bash "$COMMS" ask --from claude --to codex "probe") 2>&1 )" && TR_ASK_RC=0 || TR_ASK_RC=$?
[ "$TR_ASK_RC" != "0" ] && printf '%s\n' "$TR_ASK_OUT" | grep -q 'cmux pane transport was REMOVED' \
  && ok "ask refuses an unknown transport" || fail "ask did not refuse (rc=$TR_ASK_RC, got: $TR_ASK_OUT)"
[ "$(find "$TR_FIX/.comms" -type f 2>/dev/null | wc -l | tr -d ' ')" = "$TR_ASK_BEFORE" ] \
  && ok "a refused ask writes no question file" || fail "ask wrote a question file before refusing"

TR_FOO_OUT="$( (cd "$TR_FIX" && env COMMS_DELIVERY=foo "$COMMS" transport codex --loop) 2>&1 )" && TR_FOO_RC=0 || TR_FOO_RC=$?
[ "$TR_FOO_RC" != "0" ] && printf '%s\n' "$TR_FOO_OUT" | grep -q "not a known transport" \
  && ok "an unknown COMMS_DELIVERY value is refused, not silently defaulted" \
  || fail "unknown transport not refused (rc=$TR_FOO_RC, got: $TR_FOO_OUT)"

# END-TO-END, not just the selector. `deliver` used to hardcode --loop, so every send
# was reclassified as a loop and a live-pane CONSULT spawned headless instead of nudging
# the pane. The suite-wide COMMS_DELIVERY=mailbox masked it, so these run with it cleared.
# (codex, transport-flip round 1.)
mkdir -p "$TR_FIX/.comms/to-codex"
TR_CONSULT="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-25T10-00-00_q-1.md"
cat > "$TR_CONSULT" <<TRQ
---
type: question
from: claude
timestamp: 2026-08-25T10:00:00Z
workspace: $(basename "$TR_FIX")
message_id: $(basename "$TR_FIX")_2026-08-25T10-00-00_q-1
---

## Question
does a consult still classify as a consult?
TRQ

# THE REFUSAL MUST HOLD AT EVERY ENTRY POINT, not just `transport`. `cmd_send` runs
# `del_out="$(cmd_deliver …)"` and `cmd_deliver` runs `route="$(cmd_transport …)"`; on bash 3.2
# — the macOS default and the shell these helpers claim to support — a `die` in that position
# is SWALLOWED. Before the router/function gates, `send` printed the refusal on stderr and then
# continued to "message written for manual pickup" / "RESULT: manual … fix and retry", exit 0.
#
# THESE ASSERTIONS WERE WRONG WHEN FIRST ADDED: they ran eighteen lines ABOVE the fixture, so
# `$TR_CONSULT` was unbound and every one passed on `TR_CONSULT: unbound variable` with rc=1 —
# never invoking the helper. `rc != 0` was satisfied by the bash error. They now run below the
# fixture and require the REFUSAL TEXT, not merely a non-zero status. (grok, S4-4 r3.)
[ "${BASH_VERSINFO[0]}" -eq 3 ] && TR_SWALLOW_SHELL="bash 3.2 (the swallow is live here)" || TR_SWALLOW_SHELL="bash ${BASH_VERSINFO[0]} (3.2 swallow not reproducible on this host)"
TR_SEND_OUT="$( (cd "$TR_FIX" && env COMMS_DELIVERY=cmux /bin/bash "$COMMS" send --to codex "$TR_CONSULT") 2>&1 )" && TR_SEND_RC=0 || TR_SEND_RC=$?
[ "$TR_SEND_RC" != "0" ] && printf '%s\n' "$TR_SEND_OUT" | grep -q 'cmux pane transport was REMOVED' \
  && ok "send refuses an unknown transport — the die is not swallowed by command substitution [$TR_SWALLOW_SHELL]" \
  || fail "send did not refuse with the removal message (rc=$TR_SEND_RC, got: $TR_SEND_OUT)"
printf '%s\n' "$TR_SEND_OUT" | grep -q 'fix and retry' \
  && fail "send still tells the caller to fix and retry after a refused transport" \
  || ok "a refused transport does not produce the fix-and-retry lie"
TR_DEL_OUT="$( (cd "$TR_FIX" && env COMMS_DELIVERY=cmux /bin/bash "$COMMS" deliver codex "$TR_CONSULT") 2>&1 )" && TR_DEL_RC=0 || TR_DEL_RC=$?
[ "$TR_DEL_RC" != "0" ] && printf '%s\n' "$TR_DEL_OUT" | grep -q 'cmux pane transport was REMOVED' \
  && ok "deliver refuses an unknown transport too" || fail "deliver did not refuse (rc=$TR_DEL_RC, got: $TR_DEL_OUT)"
# panel dispatch reaches delivery by calling cmd_send as a FUNCTION, so an argv-only gate misses
# it — and it writes attempt markers, roster events and leg files BEFORE delivering. Refusal must
# happen before any of that exists. (codex, S4-4 r3, blocking.)
# The fixture MUST be a review-request. With the `type: question` used at first, `cmd_panel`
# usage_errs at its own review-request check and writes nothing regardless of the transport —
# so the file count would have passed with no gate at all, and only the text match pinned
# anything. A review-request reaches snapshot/events/legs if the gate ever stops firing.
# (grok, S4-4 r4, advisory — my own "no partial state" proof was weaker than I claimed.)
TR_PANELREQ="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-25T11-00-00_pr-1.md"
cat > "$TR_PANELREQ" <<TRPR
---
type: review-request
from: claude
timestamp: 2026-08-25T11:00:00Z
message_id: $(basename "$TR_FIX")_2026-08-25T11-00-00_pr-1
workspace: $(basename "$TR_FIX")
thread: tr-panel
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## Intent
panel refusal fixture
TRPR
TR_PANEL_BEFORE="$(find "$TR_FIX/.comms" -type f 2>/dev/null | wc -l | tr -d ' ')"
TR_PANEL_OUT="$( (cd "$TR_FIX" && env COMMS_DELIVERY=cmux /bin/bash "$COMMS" panel dispatch --to codex "$TR_PANELREQ") 2>&1 )" && TR_PANEL_RC=0 || TR_PANEL_RC=$?
[ "$TR_PANEL_RC" != "0" ] && printf '%s\n' "$TR_PANEL_OUT" | grep -q 'cmux pane transport was REMOVED' \
  && ok "panel dispatch refuses an unknown transport" || fail "panel dispatch did not refuse (rc=$TR_PANEL_RC, got: $TR_PANEL_OUT)"
[ "$(find "$TR_FIX/.comms" -type f 2>/dev/null | wc -l | tr -d ' ')" = "$TR_PANEL_BEFORE" ] \
  && ok "a refused panel dispatch writes no partial dispatch state" || fail "panel dispatch left durable state behind after refusing"
TR_LOOPMSG="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-25T10-01-00_wf-1.md"
cat > "$TR_LOOPMSG" <<TRW
---
type: review-request
from: claude
timestamp: 2026-08-25T10:01:00Z
workspace: $(basename "$TR_FIX")
message_id: $(basename "$TR_FIX")_2026-08-25T10-01-00_wf-1
thread: tr-loop-1
workflow: auto-implement
phase: implement
round: 1
max-rounds: 4
---

## What was done
loop message
TRW
TR_WS="$(basename "$TR_FIX")"
# Delivery here must NOT spawn a real agent: COMMS_DELIVERY=mailbox pins the stubbed
# transport. Tests that assert the DEFAULT routing use run_tr, which only asks
# `transport` and never delivers.
run_tr_deliver() { (cd "$TR_FIX" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" "$COMMS" "$@"); }
# End-to-end delivery on the REAL default, without spawning a real agent: a copy of the
# helper beside a STUB runphase.sh. `deliver` resolves runphase next to comms.sh, so the
# stub is what gets spawned. This is how a default-routing test stays honest and still
# leaves no background process behind.
TR_SANDBOX="$WORK/tr-sandbox"; mkdir -p "$TR_SANDBOX"
cp "$COMMS" "$TR_SANDBOX/comms.sh"; chmod +x "$TR_SANDBOX/comms.sh"
cat > "$TR_SANDBOX/runphase.sh" <<'RPSTUB'
#!/bin/bash
# stub runphase: report what a real spawn would report, spawn nothing
echo "spawned runphase pid=stub provider=${3:-codex}"
exit 0
RPSTUB
chmod +x "$TR_SANDBOX/runphase.sh"
run_tr_default() { (cd "$TR_FIX" && env -u COMMS_DELIVERY PATH="$STUB_BIN:$PATH" "$TR_SANDBOX/comms.sh" "$@"); }

# The old assertion here required a live pane ("delivered to surface"). cmux is deleted (S4-4),
# so there is no surface to nudge and the scenario cannot be rebuilt. The rule it protected —
# deliver classifies from the MESSAGE, not a hardcoded --loop — is still covered by the
# `run_tr_default transport codex --loop` assertion below and by the workflow-classification
# assertions in this section. Removed rather than re-pointed at something it does not prove.
# The old negative here grepped for 'delivered to surface', which cannot appear now that the
# pane arm is gone — it could not fail. Assert the POSITIVE outcome a loop must actually
# produce instead. (grok, S4-4 r1: "the third is still vacuous".)
TR_LOOP_OUT="$(run_tr_default deliver codex "$TR_LOOPMSG" 2>&1 || true)"
# Narrowed to what THIS fixture produces. The wider alternation was not a tautology but was
# looser than the setup warrants: `deliver` never prints `RESULT: spawned` (that is `send`),
# `note: COMMS_DELIVERY=mailbox` cannot match because the helper unsets the env, and
# `written for pickup` would have accepted a wrong pickup short-circuit. With no acp.sh beside
# the sandboxed helper, a codex loop must report manual pickup. (grok, S4-4 r2.)
printf '%s\n' "$TR_LOOP_OUT" | grep -q 'manual pickup' \
  && ok "a LOOP message with no runner reports an honest manual pickup" \
  || fail "loop delivery produced no recognised outcome (got: $TR_LOOP_OUT)"
# "did not reach a surface" is also true of manual pickup and of a spawn failure, so
# assert the POSITIVE signal. (codex, transport-flip round 2.)
# The old positive ("it actually spawned headless") needed an agent with BOTH a pane and the
# headless transport. After step 4 no provider has both, so the surviving guarantee is the
# NEGATIVE above: a loop never takes a pane. Asserting a spawn here would only re-pin the
# scenario the removal deleted.
printf '%s\n' "$TR_LOOP_OUT" | grep -qE 'manual pickup|mailbox' \
  && ok "a loop with no runner and no ACP says mailbox rather than nudging a pane" \
  || fail "loop fallback (got: $TR_LOOP_OUT)"

# The set -u regression codex asked for survives the transport it was found in: deliver must
# not trip `set -u` on an absent identity. The picker-reason and pane-preference assertions
# died with cmux (S4-4) — there is no picker and no pane.
TR_NOWS="$( (cd "$TR_FIX" && env COMMS_DELIVERY=mailbox "$COMMS" deliver codex "$TR_CONSULT") 2>&1 || true)"
printf '%s\n' "$TR_NOWS" | grep -q 'unbound variable' \
  && fail "deliver trips set -u with no workspace identity" || ok "deliver does not trip set -u with no workspace identity"
# The mode still comes from the MESSAGE, so `transport` agrees with what deliver did.
[ "$(run_tr_default transport codex --loop)" != "cmux" ] && ok "loop mode never resolves to a deleted transport" || fail "loop transport"

# Criterion 3: with runphase.sh genuinely absent, a loop must not strand. It falls back to
# MAILBOX, never to a pane — cmux is gone (S4-4) and the assertions below reject a pane
# outcome. A bare copy of the helper (no runphase.sh beside it) simulates a partial install.
TR_BARE="$WORK/bare-install"; mkdir -p "$TR_BARE"
cp "$COMMS" "$TR_BARE/comms.sh"; chmod +x "$TR_BARE/comms.sh"
[ ! -e "$TR_BARE/runphase.sh" ] && ok "fixture: a helper install with no runphase.sh" || fail "bare fixture"
TR_BARE_LOOP="$( (cd "$TR_FIX" && env -u COMMS_DELIVERY PATH="$STUB_BIN:$PATH" "$TR_BARE/comms.sh" transport codex --loop) 2>/dev/null)"
[ "$TR_BARE_LOOP" = "mailbox" ] \
  && ok "no headless runner does NOT fall back to a pane — that is self-send by another name" \
  || fail "missing-runner fallback (got: $TR_BARE_LOOP)"
TR_BARE_NOPANE="$( (cd "$TR_FIX" && env -u COMMS_DELIVERY "$TR_BARE/comms.sh" transport codex --loop) 2>/dev/null)"
[ "$TR_BARE_NOPANE" = "mailbox" ] \
  && ok "no runner and no pane reports mailbox honestly" || fail "bare no-pane (got: $TR_BARE_NOPANE)"

# round-note: counts are DERIVED so a later reader can trust them; the prose is required
# so a round is never recorded without an assessment.
TR_RN="$TR_FIX/.comms/archive/rn-1.md"
mkdir -p "$TR_FIX/.comms/archive"
cat > "$TR_RN" <<'RNEOF'
---
type: review-feedback
from: codex
timestamp: 2026-08-25T12:00:00Z
workspace: tr
thread: rn-thread
phase: implement
round: 3
verdict: REQUEST_CHANGES
---

## Findings

### Blocking
- `a.sh:1` — one blocking thing.
- `b.sh:2` — another blocking thing.

### Advisory
- `c.sh:3` — one advisory thing.

### Process
- process noise that must not be counted
RNEOF
run_tr round-note "$TR_RN" --note "caught the real one, missed nothing" >/dev/null 2>&1
RN_TSV="$TR_FIX/.comms/grades/rounds.tsv"
[ -s "$RN_TSV" ] && ok "round-note writes a rounds ledger" || fail "rounds.tsv"
awk -F'\t' 'NR>1 && $7=="2" && $8=="1"' "$RN_TSV" | grep -q . \
  && ok "round-note DERIVES the counts (2 blocking, 1 advisory) rather than trusting input" || fail "derived counts"
awk -F'\t' 'NR>1 && $5=="codex" && $6=="REQUEST_CHANGES" && $4=="3"' "$RN_TSV" | grep -q . \
  && ok "round-note carries reviewer, verdict and round from the reply" || fail "round-note provenance"
grep -q 'process noise' "$RN_TSV" && fail "### Process leaked into the round ledger" || ok "### Process is not counted as a finding"
awk -F'\t' 'NR>1 && $9!=""' "$RN_TSV" | grep -q . \
  && ok "round-note stamps prompt_version so rounds are comparable only within one" || fail "prompt_version missing"
check_not "round-note requires an assessment" run_tr round-note "$TR_RN"
check_not "round-note rejects a missing file" run_tr round-note "$TR_FIX/nope.md" --note x

# SNAPSHOT ON SEND. Without a pinned artifact the reviewer reads whatever the author
# happens to be typing, and two reviewers on one request race each other — "they read
# the same artifact" is unprovable. Loops only; a consult reviews nothing.
TR_WF2="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-26T10-00-00_wf-2.md"
sed -e 's|^message_id: .*|message_id: wf-2|' -e 's|^thread: .*|thread: tr-stamp|' "$TR_LOOPMSG" > "$TR_WF2"
grep -q '^artifact_id:' "$TR_WF2" && fail "fixture already stamped" || ok "fixture: a loop message with no artifact_id"
run_tr_deliver send --to codex "$TR_WF2" >/dev/null 2>&1 || true
grep -q '^artifact_id:' "$TR_WF2" && ok "send stamps the retained artifact onto a loop message" || fail "send did not stamp artifact_id"
TR_AID="$(grep -m1 '^artifact_id:' "$TR_WF2" | sed 's/^artifact_id: //')"
git -C "$TR_FIX" cat-file -e "${TR_AID}^{commit}" 2>/dev/null \
  && ok "the stamped artifact is a real, resolvable object" || fail "stamped artifact does not resolve"
# Re-sending must not re-stamp: the artifact is pinned at dispatch, not at every retry.
run_tr_deliver send --to codex "$TR_WF2" >/dev/null 2>&1 || true
[ "$(grep -c '^artifact_id:' "$TR_WF2")" = "1" ] && ok "re-sending does not re-stamp or duplicate the field" || fail "artifact_id duplicated on resend"
[ "$(grep -m1 '^artifact_id:' "$TR_WF2" | sed 's/^artifact_id: //')" = "$TR_AID" ] \
  && ok "the pinned artifact does not move on resend" || fail "artifact_id changed on resend"
# A consult has nothing under review.
TR_Q2="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-26T10-01-00_q-2.md"
sed -e 's|^message_id: .*|message_id: q-2|' "$TR_CONSULT" > "$TR_Q2"
run_tr_deliver send --to codex "$TR_Q2" >/dev/null 2>&1 || true
grep -q '^artifact_id:' "$TR_Q2" && fail "a consult was stamped with an artifact" || ok "consults are never stamped — they review nothing"
run_tr_deliver validate "$TR_WF2" >/dev/null 2>&1 && ok "a stamped message still validates" || fail "stamping broke validation"

# Artifact retention FAILS CLOSED: dispatching a loop against an unpinned tree would
# review whatever the working tree holds while the message implies a pinned artifact —
# invisible afterwards. (codex, transport-flip round 4.)
TR_NOGIT="$WORK/not-a-repo"; mkdir -p "$TR_NOGIT/.comms/to-codex"
cp "$TR_LOOPMSG" "$TR_NOGIT/.comms/to-codex/wf.md" 2>/dev/null || true
TR_FC="$( (cd "$TR_NOGIT" && env -u COMMS_DELIVERY "$COMMS" send --to codex "$TR_NOGIT/.comms/to-codex/wf.md") 2>&1 )" && TR_FCRC=0 || TR_FCRC=$?
[ "$TR_FCRC" != "0" ] && ok "a loop outside a git repo is refused, not dispatched unpinned" || fail "unpinned dispatch was allowed"

# CRLF frontmatter must still get stamped, and must stay CRLF.
TR_CRLF="$TR_FIX/.comms/to-codex/$(basename "$TR_FIX")_2026-08-26T11-00-00_crlf.md"
sed -e 's|^message_id: .*|message_id: crlf-1|' -e 's|^thread: .*|thread: tr-crlf|' "$TR_LOOPMSG" | sed 's/$/\r/' > "$TR_CRLF"
run_tr_deliver send --to codex "$TR_CRLF" >/dev/null 2>&1 || true
grep -q '^artifact_id:' "$TR_CRLF" && ok "a CRLF message still gets stamped" || fail "CRLF message not stamped"
grep -q $'\r' "$TR_CRLF" && ok "stamping leaves CRLF line endings intact" || fail "stamping rewrote line endings"

# The spawn guard must be ATOMIC: scan-then-create lets two concurrent deliveries both
# spawn, which under panel fan-out is a phantom extra reviewer.
# Atomicity itself is proven live above ("re-delivery of an in-flight turn is guarded").
# What had NO behavioural cover was the other half: a claim whose holder DIED must be
# reclaimable, or one crashed runner wedges that message forever. Asserted by running it.
SC_MSG="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T14-40-00_staleclaim-1.md"
# Built here, not sed-derived from $HL_WF: that file is deleted upstream (the
# empty-inbox test at the `find ... -delete` above), so the sed produced a
# ZERO-BYTE message and both assertions below ran against an empty fixture --
# the dead-holder reclaim "passed" while proving nothing, negative control and
# all. A derived fixture that can silently evaporate is not a fixture.
cat > "$SC_MSG" <<'SCMSG'
---
type: review-request
from: claude
timestamp: 2026-06-04T14:40:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T14-40-00_staleclaim-1
thread: loop-headless
workflow: auto-implement
phase: implement
round: 7
max-rounds: 10
---

## What was done
Stale-claim fixture.
SCMSG
[ -s "$SC_MSG" ] && ok "stale-claim fixture is a real message, not an empty file" \
  || fail "stale-claim fixture is empty — the assertions below would prove nothing"
SC_MID="$(basename "$SC_MSG" .md)"
SC_CLAIM="$REPO_FIX/.comms/logs/.spawn-$(printf '%s' "$SC_MID" | tr -c 'A-Za-z0-9._-' '_')"
mkdir -p "$SC_CLAIM"
# A pid that is guaranteed dead: start one and reap it. A hardcoded number can be recycled.
( sleep 0 ) & SC_DEAD=$!; wait "$SC_DEAD" 2>/dev/null || true
printf '%s' "$SC_DEAD" > "$SC_CLAIM/pid"
# Driven by GROK. The CLAIM mechanism is transport-agnostic, but codex is ACP-only since
# step 4, so a non-ACP codex spawn is refused before it ever reaches the claim — which made
# the reclaim arm below pass VACUOUSLY (a refusal contains no "already running" either).
# The live-holder negative control caught it. Re-pointed, not deleted.
SC_OUT="$( (cd "$REPO_FIX" && env COMMS_DELIVERY=headless \
    PATH="$STUB_BIN:$PATH" "$RUNPHASE" spawn --provider grok --message "$SC_MSG") 2>&1 )"
case "$SC_OUT" in
  *"already running"*) fail "a claim held by a DEAD pid still wedges the message" ;;
  *"spawned runphase"*) ok "a stale claim from a dead holder is reclaimed, not honoured" ;;
  *) fail "spawn neither reclaimed nor refused — it died for an unrelated reason (got: $SC_OUT)" ;;
esac
# NEGATIVE CONTROL: the same setup with a LIVE holder must be refused, or the check above
# is just "spawn always spawns" and proves nothing about claims at all.
rm -rf "$SC_CLAIM"; mkdir -p "$SC_CLAIM"; printf '%s' "$$" > "$SC_CLAIM/pid"
SC_OUT2="$( (cd "$REPO_FIX" && env COMMS_DELIVERY=headless \
    PATH="$STUB_BIN:$PATH" "$RUNPHASE" spawn --provider grok --message "$SC_MSG") 2>&1 )"
case "$SC_OUT2" in
  *"already running"*) ok "a claim held by a LIVE pid is honoured (the reclaim is selective)" ;;
  *) fail "the claim is ignored outright — reclaim proves nothing (got: $SC_OUT2)" ;;
esac
rm -rf "$SC_CLAIM"
