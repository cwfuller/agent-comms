# Run through tests/run.sh; each group gets fresh fixtures.
section "comms.sh: root/workspace"
[ "$(run_comms root)" = "$REPO_FIX/.comms" ] && ok "root resolves main repo .comms" || fail "root resolves main repo .comms"
[ "$(run_comms workspace)" = "feature-helper-tests" ] && ok "workspace resolves from the branch name" || fail "workspace falls back to branch (got $(run_comms workspace))"
if command -v zsh >/dev/null 2>&1; then
  WS_ZSH="$(cd "$REPO_FIX" && env zsh -c "\"$COMMS\" workspace")"
  [ "$WS_ZSH" = "feature-helper-tests" ] && ok "helper is caller-shell agnostic (zsh)" || fail "helper under zsh (got $WS_ZSH)"
else
  # Recorded, not dropped: without this the suite silently reports 953 of 954 on a
  # box with no zsh and still attests as a full green run.
  skip zsh-absent "helper is caller-shell agnostic (zsh) — zsh not installed"
fi

section "comms.sh: validate"
GOOD="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T12-00-00_test-1.md"
cat > "$GOOD" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-06-04T12:00:00Z
workspace: feature-helper-tests
workflow: auto-implement
phase: implement
round: 1
max-rounds: 10
---

## What was done
Things.
MSG
check "valid claude workflow message (no verdict needed)" run_comms validate "$GOOD"

BAD_NOVERDICT="$WORK/codex-noverdict.md"
sed 's/from: claude/from: codex/; s/type: review-request/type: review-feedback/' "$GOOD" > "$BAD_NOVERDICT"
check_not "workflow review-feedback without verdict is rejected" run_comms validate "$BAD_NOVERDICT"
# The verdict rule binds by TYPE, not sender: a reverse-topology review-request
# FROM codex needs no verdict.
REV_REQ="$WORK/codex-request.md"
sed 's/from: claude/from: codex/' "$GOOD" > "$REV_REQ"
check "reverse-topology review-request from codex validates without verdict" run_comms validate "$REV_REQ"

BAD_NOTYPE="$WORK/notype.md"
grep -v '^type:' "$GOOD" > "$BAD_NOTYPE"
check_not "missing type is rejected" run_comms validate "$BAD_NOTYPE"

BAD_EMPTY="$WORK/empty-body.md"
awk '/^## /{exit} {print}' "$GOOD" > "$BAD_EMPTY"
check_not "empty body is rejected" run_comms validate "$BAD_EMPTY"

section "comms.sh: error-envelope (a provider API error is not an answer)"
# The LIVE shape (codex-cli 0.153.4 rejecting the configured model over acpx, 2026-09-08): a
# Warning preamble, a blank line, one compact JSON object, exit 0. It reached a driver as a
# `type: response` reply recorded `status: completed`.
ENV_D="$WORK/envelope"; mkdir -p "$ENV_D"
cat > "$ENV_D/live.txt" <<'ENVLIVE'
Warning: Model metadata for `gpt-6-astra` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.

{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-6-astra' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}

ENVLIVE
ENV_OUT="$("$COMMS" error-envelope "$ENV_D/live.txt" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && echo "$ENV_OUT" | grep -q "requires a newer version of Codex" \
  && ok "the live codex error envelope is recognised and its message surfaced" || fail "live envelope (rc=$rc, out: $ENV_OUT)"
# The generic OpenAI shape, pretty-printed: no `type` member, several lines.
printf '{\n  "error": {\n    "message": "quota exceeded",\n    "type": "insufficient_quota"\n  }\n}\n' > "$ENV_D/bare.txt"
"$COMMS" error-envelope "$ENV_D/bare.txt" >/dev/null 2>&1 \
  && ok "a bare pretty-printed {error:{message}} envelope is recognised" || fail "bare envelope"
# STRUCTURAL, NOT A SUBSTRING: an answer that QUOTES the same error is an answer.
{ echo "Codex returned this when I asked:"; cat "$ENV_D/live.txt"; } > "$ENV_D/quoted.txt"
"$COMMS" error-envelope "$ENV_D/quoted.txt" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 1 ] && ok "prose that quotes an error envelope is an answer (rc 1)" || fail "quoted envelope misread as an error (rc=$rc)"
printf '{"answer":"yes","error":null}\n' > "$ENV_D/json.txt"
"$COMMS" error-envelope "$ENV_D/json.txt" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 1 ] && ok "a JSON answer whose error member is not an object is an answer" || fail "non-error JSON misread (rc=$rc)"
# `-` reads the payload from stdin. The first cut read sys.stdin AFTER the interpreter had
# consumed its own heredoc script from it, so every piped body was "an answer" and the
# negative controls above passed vacuously. The POSITIVE stdin case is what catches that.
"$COMMS" error-envelope - < "$ENV_D/live.txt" >/dev/null 2>&1 \
  && ok "the stdin form (-) sees the piped body" || fail "stdin form is blind to its input"
# A stamped message is checked at its BODY, so one file reads the same on both sides of the broker.
printf -- '---\ntype: response\nfrom: codex\n---\n\n' > "$ENV_D/stamped.md"; cat "$ENV_D/live.txt" >> "$ENV_D/stamped.md"
"$COMMS" error-envelope "$ENV_D/stamped.md" >/dev/null 2>&1 \
  && ok "a stamped reply is checked at its body, past the frontmatter" || fail "stamped envelope missed"
{ cat "$ENV_D/live.txt"; echo "[acpx] tokens: input=1 output=1 cache_read=0 total=2"; } > "$ENV_D/tokens.txt"
"$COMMS" error-envelope "$ENV_D/tokens.txt" >/dev/null 2>&1 \
  && ok "acpx's trailing token-usage line does not hide the envelope" || fail "tokens line hid the envelope"
"$COMMS" error-envelope "$ENV_D/absent.txt" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 2 ] && ok "an unreadable file is a usage failure (rc 2), never an answer" || fail "unreadable file rc=$rc"
# The message is printed as ONE clean line: json.loads decodes `\t`, `\r`, `\n` and ``
# into real control characters, which would otherwise flow into a per-line JSON note.
printf '{"type":"error","status":400,"error":{"type":"x","message":"bad\\tmodel\\r\\nnamed\\u0001here"}}\n' > "$ENV_D/ctrl.txt"
ENV_OUT="$("$COMMS" error-envelope "$ENV_D/ctrl.txt" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ "$ENV_OUT" = "x: bad model named here" ] \
  && ok "decoded control characters in the message collapse to single spaces" || fail "control chars leaked (rc=$rc, out: $(printf '%q' "$ENV_OUT"))"

section "comms.sh: reply-check (completion-evidence contract: 10 answer / 11 error / 12 undecidable)"
# reply-check is the ONE decoder the broker, the consult, and the compatibility canary share, with a
# PAIRED exit-status/sentinel so a crashed or truncated classifier can never read as a clean answer.
RC_D="$WORK/replycheck"; mkdir -p "$RC_D"
printf 'Warning: x\n\n{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"needs a newer CLI"}}\n' > "$RC_D/err.txt"
RC_OUT="$("$COMMS" reply-check "$RC_D/err.txt")"; RC_RC=$?
[ "$RC_RC" -eq 11 ] && printf '%s' "$RC_OUT" | head -1 | grep -qx 'verdict: error' && printf '%s' "$RC_OUT" | grep -q 'needs a newer CLI' \
  && ok "a provider API error is exit 11 with a 'verdict: error' sentinel and the message" || fail "reply-check error contract (rc=$RC_RC)"
printf 'a normal answer\n' | "$COMMS" reply-check - >/dev/null 2>&1; RC_RC=$?
[ "$RC_RC" -eq 10 ] && ok "a plain answer is exit 10 (completion via exit status; no error message emitted)" || fail "reply-check answer contract (rc=$RC_RC)"
{ echo "codex said:"; cat "$RC_D/err.txt"; } | "$COMMS" reply-check - >/dev/null 2>&1
[ "$?" -eq 10 ] && ok "prose that QUOTES an error envelope is an answer (structural, not a substring)" || fail "quoted error misread"
# The stdin form must SEE its input (the classifier reads a materialised temp, not the heredoc-fed stdin).
printf 'answer via stdin\n' | "$COMMS" reply-check - >/dev/null 2>&1
[ "$?" -eq 10 ] && ok "the stdin form (-) sees the piped body" || fail "stdin form blind to its input"
# COMPLETION EVIDENCE: a python3 that is missing, or runs but does not honour the exit/sentinel
# pairing, is UNDECIDABLE (12), never a trusted answer. (codex, plan r2 A1.)
RC_STUB="$WORK/rc-nopy"; mkdir -p "$RC_STUB"
printf '#!/bin/sh\nexit 1\n' > "$RC_STUB/python3"; chmod +x "$RC_STUB/python3"
printf 'x\n' | PATH="$RC_STUB:$PATH" "$COMMS" reply-check - >/dev/null 2>&1
[ "$?" -eq 12 ] && ok "an executable python3 that exits 1 without the sentinel is undecidable (12), not an answer" || fail "silent python exit-1 was trusted"
printf '#!/bin/sh\necho garbage; exit 10\n' > "$RC_STUB/python3"; chmod +x "$RC_STUB/python3"
printf 'x\n' | PATH="$RC_STUB:$PATH" "$COMMS" reply-check - >/dev/null 2>&1
[ "$?" -eq 12 ] && ok "exit 10 without the matching sentinel is undecidable (the pair must agree)" || fail "exit/sentinel mismatch trusted"

section "comms.sh: archive (idempotent, own inbox only)"
IN1="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T12-01-00_reply-1.md"
sed 's/from: claude/from: codex/; s/^---$/---/; ' "$GOOD" > "$IN1"
echo "verdict: APPROVE" >> /dev/null # (verdict not needed for archive test)
check "archive own inbox file" run_comms archive --as claude "$IN1"
[ -f "$REPO_FIX/.comms/archive/$(basename "$IN1")" ] && ok "file landed in archive/" || fail "file landed in archive/"
check "re-archive is a no-op (idempotent)" run_comms archive --as claude "$IN1"
check_not "archiving a file from the OTHER inbox is refused" run_comms archive --as claude "$GOOD"

section "comms.sh: list"
check_not "list exits non-zero on empty inbox" run_comms list --as claude
LIST_ERR="$( (cd "$REPO_FIX" && env "$COMMS" list --as claude) 2>&1 1>/dev/null || true)"
echo "$LIST_ERR" | grep -q "latest archived" && ok "empty inbox reports latest archived (late-nudge UX)" || fail "empty inbox reports latest archived (got: $LIST_ERR)"
UNMATCHED="$REPO_FIX/.comms/to-claude/other-workspace_pending.md"
printf '%s\n' pending > "$UNMATCHED"
LIST_MISMATCH="$( (cd "$REPO_FIX" && env "$COMMS" list --as claude) 2>&1 1>/dev/null || true)"
echo "$LIST_MISMATCH" | grep -q "OTHER workspace identities" && echo "$LIST_MISMATCH" | grep -q "other-workspace(1)" \
  && ok "empty scoped list NAMES the unmatched identities" || fail "unmatched inbox warning (got: $LIST_MISMATCH)"
rm -f "$UNMATCHED"

section "comms.sh: latest archive is direction/thread/time aware"
ARCH_OLD="$REPO_FIX/.comms/archive/feature-helper-tests_z-round-6.md"
ARCH_NEW="$REPO_FIX/.comms/archive/feature-helper-tests_a-round-7.md"
ARCH_WRONG_DIRECTION="$REPO_FIX/.comms/archive/feature-helper-tests_zz-wrong-direction.md"
cat > "$ARCH_OLD" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-07-28T10:00:00Z
workspace: feature-helper-tests
thread: archive-order
workflow: auto-implement
phase: implement
round: 6
max-rounds: 10
---
old
MSG
cat > "$ARCH_NEW" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-07-28T11:00:00Z
workspace: feature-helper-tests
thread: archive-order
workflow: auto-implement
phase: implement
round: 7
max-rounds: 10
---
new
MSG
cat > "$ARCH_WRONG_DIRECTION" <<'MSG'
---
type: review-feedback
from: codex
timestamp: 2026-07-28T12:00:00Z
workspace: feature-helper-tests
thread: archive-order
workflow: auto-implement
phase: implement
round: 8
max-rounds: 10
verdict: APPROVE
---
wrong direction
MSG
ARCH_HINT="$( (cd "$REPO_FIX" && env "$COMMS" list --as codex --thread archive-order) 2>&1 1>/dev/null || true)"
echo "$ARCH_HINT" | grep -q "$(basename "$ARCH_NEW")" && ok "latest archive uses protocol time, not filename order" || fail "protocol-time archive order (got: $ARCH_HINT)"
echo "$ARCH_HINT" | grep -q "$(basename "$ARCH_WRONG_DIRECTION")" && fail "latest archive crossed reader direction" || ok "latest archive is reader-direction aware"
# Direction awareness must survive a THIRD agent: the old rule derived the sender
# as "the other one of exactly two", so registering grok silently turned the hint
# unfiltered and it started reporting the reader's own message back at it.
printf 'agents = claude codex grok\n' > "$REPO_FIX/.comms/config"
ARCH_HINT3="$( (cd "$REPO_FIX" && env "$COMMS" list --as codex --thread archive-order) 2>&1 1>/dev/null || true)"
rm -f "$REPO_FIX/.comms/config"
echo "$ARCH_HINT3" | grep -q "$(basename "$ARCH_NEW")" \
  && ok "archive hint stays direction-aware with three agents registered" || fail "3-agent archive hint (got: $ARCH_HINT3)"
echo "$ARCH_HINT3" | grep -q "$(basename "$ARCH_WRONG_DIRECTION")" \
  && fail "3-agent hint crossed reader direction" || ok "3-agent hint excludes the reader's own messages"

section "comms.sh: send (atomicity guard)"
IN2="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T12-02-00_reply-2.md"
cp "$REPO_FIX/.comms/archive/$(basename "$IN1")" "$IN2"
BADOUT="$WORK/malformed-out.md"
echo "not a message" > "$BADOUT"
check_not "send refuses malformed outbound" run_comms send --to codex "$BADOUT" --archive-inbound "$IN2"
[ -f "$IN2" ] && ok "inbound NOT archived when outbound malformed" || fail "inbound NOT archived when outbound malformed"
check "send valid outbound (manual pickup) archives inbound" run_comms send --to codex "$GOOD" --archive-inbound "$IN2"
[ ! -f "$IN2" ] && ok "inbound archived after successful send" || fail "inbound archived after successful send"

section "install.sh: scopes"
INST_FIX="$WORK/install-repo"
mkdir -p "$INST_FIX"
git -C "$INST_FIX" init -q -b main
(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=project >/dev/null 2>&1)
[ -d "$INST_FIX/.comms/to-codex" ] && ok "project scope creates .comms" || fail "project scope creates .comms"
grep -qxF '.comms/' "$INST_FIX/.gitignore" && ok "project scope gitignores .comms/" || fail "project scope gitignores .comms/"
SUM1="$(cat "$INST_FIX/.gitignore")"
(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=project >/dev/null 2>&1)
[ "$SUM1" = "$(cat "$INST_FIX/.gitignore")" ] && ok "project scope is idempotent" || fail "project scope is idempotent"
LOCAL_OUT="$(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=local 2>&1)"
[ -x "$INST_FIX/.agent-comms/comms.sh" ] && ok "local scope installs executable helpers" || fail "local scope installs executable helpers"
[ -x "$INST_FIX/.agent-comms/route.sh" ] && ok "local scope installs route.sh" || fail "local scope installs route.sh"
[ -f "$INST_FIX/.agent-comms/route_backend.py" ] && ok "local scope installs route_backend.py" || fail "local scope installs route_backend.py"
[ -f "$INST_FIX/.agent-comms/route_review.py" ] && [ -f "$INST_FIX/.agent-comms/policy-map.tsv" ] \
  && ok "local scope installs the reviewer decider and the policy map" || fail "local scope misses route_review.py / policy-map.tsv"
# THE INSTALLED accessor resolves through the map installed BESIDE it (sibling resolution is the
# only lookup), so a local pin carries its own table rather than borrowing the source tree's.
[ "$(env -u COMMS_ACP_CODEX_MODEL -u COMMS_ACP_CODEX_EFFORT "$INST_FIX/.agent-comms/acp.sh" policy codex 2>/dev/null)" = "$(printf 'gpt-6-astra\txhigh')" ] \
  && ok "the locally installed acp.sh resolves the baseline from its own sibling map" || fail "installed acp.sh cannot resolve"
[ -f "$INST_FIX/.claude/commands/auto.md" ] && ok "local scope installs commands" || fail "local scope installs commands"
[ -f "$INST_FIX/.claude/commands/ask.md" ] && ok "local scope installs /ask" || fail "local scope installs ask.md"
# THE BLOCKING DEFECT r1 FOUND, pinned two ways. A local-only install — also the noninteractive
# default — was getting the new resolver with NO fragment to resolve, so review turns fail closed
# everywhere except a pin sitting next to THIS checkout's docs/. Dogfooding could not see it, and
# the suite's own $AGENT_COMMS_HOME staging was MASKING it. (codex + grok, S3-1 r1, blocking.)
for RB_LF in verdict-discipline holistic-rereview; do
  # BYTE-COMPARED, mirroring the global-scope coverage: "a non-empty file exists" would pass on
  # valid-looking but WRONG data, and a review bar that differs from canonical is a silently
  # different standard. (codex, S3-1 r2, advisory.)
  cmp -s "$INST_FIX/.agents/loopspec-fragments/$RB_LF.md" "$REPO/docs/loopspec/fragments/$RB_LF.md" \
    && ok "local scope pins the $RB_LF fragment, byte-identical to canonical" || fail "local scope did not pin $RB_LF faithfully"
done
# The unpin recipe must name EVERY pinned path, or following it leaves the bar shadowing the
# global one and updates to the standard never arrive. (codex + grok, S3-1 r2, corroborated.)
printf '%s\n' "$LOCAL_OUT" | grep -q 'loopspec-fragments' \
  && ok "the local-pin note tells the operator to remove the pinned review bar too" || fail "unpin recipe omits the pinned bar"
# BEHAVIOURAL, with every other tier removed: no global home, and a helper whose ../docs does not
# exist. This is the only arrangement that proves the PROJECT PIN alone is sufficient.
# Extract in THIS shell, not inside a nested `bash -c` — the sed range braces do not survive that
# quoting, and the first cut of this probe reported MISS because sed had been mangled rather than
# because the pin was absent. A test that fails for the wrong reason is as useless as one that
# passes for the wrong reason.
RB_FF="$(sed -n '/^fragment_file() {/,/^}/p' "$REPO/helpers/runphase.sh")"
RB_LOCAL_RUN="$( eval "$RB_FF"
  HELPER_DIR="$INST_FIX/.agent-comms"; AGENT_COMMS_HOME="$WORK/rb-empty-home"
  f="$(fragment_file verdict-discipline "$INST_FIX" 2>/dev/null || true)"
  [ -n "$f" ] && [ -s "$f" ] && printf 'PINNED' || printf 'MISS' )"
[ "$RB_LOCAL_RUN" = "PINNED" ] \
  && ok "a local-only install resolves the bar from its project pin, with no global or repo tier" \
  || fail "local-only install cannot resolve the review bar (got: $RB_LOCAL_RUN)"
# The collapse deleted five commands; installing a removed one would resurrect it.
for dead in auto-plan.md auto-full.md auto-implement.md fleet.md ask-codex.md; do
  [ -f "$INST_FIX/.claude/commands/$dead" ] && fail "removed command $dead was installed" || ok "removed command $dead stays removed"
done
echo "$LOCAL_OUT" | grep -qi "shadow" && ok "local scope prints pin/shadow note" || fail "local scope prints pin/shadow note"
# BEHAVIORAL delete-on-upgrade: a clean install not copying retired files proves
# nothing about an upgrade — plant a pre-existing retired command AND a retired
# local-pin helper, re-run the installer, and require both GONE. The local pin
# outranks the global install, so a fleet.sh surviving here shadows its own
# removal everywhere else. (codex + grok, panel r1: the old test was clean-install-only.)
touch "$INST_FIX/.claude/commands/auto-plan.md" "$INST_FIX/.agent-comms/fleet.sh"
(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=local >/dev/null 2>&1)
[ ! -f "$INST_FIX/.claude/commands/auto-plan.md" ] \
  && ok "an upgrade DELETES a pre-existing retired command" || fail "retired auto-plan.md survived the upgrade"
[ ! -f "$INST_FIX/.agent-comms/fleet.sh" ] \
  && ok "an upgrade DELETES a pre-existing retired local-pin helper" || fail "retired fleet.sh survived the local upgrade"

section "comms.sh: status smoke"
ST="$(run_comms status)"
echo "$ST" | grep -q "workspace: feature-helper-tests" && ok "status prints workspace" || fail "status prints workspace"
echo "$ST" | grep -q "latest archived:" && ok "status prints latest archived" || fail "status prints latest archived"
echo "$ST" | grep -q "pending in to-claude:" && ok "status prints pending counts" || fail "status prints pending counts"

section "install.sh: local pin gitignored + global scope (overridden HOME dirs)"
grep -qxF '.agent-comms/' "$INST_FIX/.gitignore" && ok "local install gitignores .agent-comms/" || fail "local install gitignores .agent-comms/"
GHOME="$WORK/ghome"
GH_OUT="$(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" GROK_COMMANDS_DIR="$GHOME/grok-commands" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global 2>&1)"
[ -x "$GHOME/agent-comms/comms.sh" ] && ok "global scope installs executable helpers (env-overridden)" || fail "global scope installs executable helpers"
[ -f "$GHOME/commands/auto.md" ] && ok "global scope installs commands (env-overridden)" || fail "global scope installs commands"
[ -f "$GHOME/commands/ask.md" ] && ok "global scope installs /ask" || fail "global scope installs ask.md"
# The reviewer-side Codex skills were DELETED in step 4 (S4-3). Installing must now REMOVE a
# copy an earlier install left behind — a stale skill left callable is exactly what the
# RETIRED_* mechanism exists to prevent. Seed one first, or this proves nothing. (S4-3.)
mkdir -p "$GHOME/skills/read-from-claude" && printf 'stale\n' > "$GHOME/skills/read-from-claude/SKILL.md"
mkdir -p "$GHOME/skills/send-to-claude" && printf 'stale\n' > "$GHOME/skills/send-to-claude/SKILL.md"
(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" GROK_COMMANDS_DIR="$GHOME/grok-commands" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global >/dev/null 2>&1) || true
[ ! -e "$GHOME/skills/read-from-claude" ] && [ ! -e "$GHOME/skills/send-to-claude" ] \
  && ok "installing REMOVES both retired Codex skills left by an earlier install" || fail "a retired Codex skill survived an install"
# The PROJECT-LOCAL pin is a different rm than the global one ($PROJECT_ROOT/.agents/skills vs
# $CODEX_SKILLS_DIR), it is the noninteractive default, and it is the copy that used to win the
# old resolver. Hand-verified during S4-3; pinned here so the upgrade guarantee is durable.
# (codex + grok, S4-3 r2, advisory.)
mkdir -p "$INST_FIX/.agents/skills/read-from-claude" && printf 'stale\n' > "$INST_FIX/.agents/skills/read-from-claude/SKILL.md"
(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" GROK_COMMANDS_DIR="$GHOME/grok-commands" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=local >/dev/null 2>&1) || true
[ ! -e "$INST_FIX/.agents/skills/read-from-claude" ] \
  && ok "a local-scope install removes a project-local pin of a retired skill" || fail "project-local retired pin survived --scope=local"
# THE REVIEW BAR IS NOW INSTALLED DATA. It used to be read out of the codex self-send SKILL files
# at runtime, so step 4's deletion of those templates would have silently removed the reviewer's
# standard — a diff that reads like cleanup. Installed from docs/loopspec/fragments/, which is
# their canonical home and what the drift test measures templates against, so this is a copy on
# disk rather than a second origin. (contraction step 3, S3-1.)
for RB_F in verdict-discipline holistic-rereview; do
  [ -s "$GHOME/agent-comms/loopspec-fragments/$RB_F.md" ] \
    && ok "global scope installs the $RB_F fragment as data" || fail "$RB_F fragment not installed"
  cmp -s "$GHOME/agent-comms/loopspec-fragments/$RB_F.md" "$REPO/docs/loopspec/fragments/$RB_F.md" \
    && ok "the installed $RB_F fragment is byte-identical to its canonical origin" || fail "$RB_F drifted from docs/loopspec/fragments"
done

# ATOMIC INSTALL. A plain `cp` over an installed helper truncates and rewrites the SAME
# inode, and bash reads an executing script lazily by byte offset — which is how three
# separate sessions on 2026-08-27 killed a parked `runphase.sh await` mid-run by
# reinstalling under it. The observable is inode identity: temp+rename gives the
# destination a NEW inode, so a reader already inside the old one finishes on it.
INO1="$(command ls -di "$GHOME/agent-comms/comms.sh" | awk '{print $1}')"
printf '#x\n' >> "$GHOME/agent-comms/comms.sh"   # differ from source, so no content-skip can hide the write
(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" GROK_COMMANDS_DIR="$GHOME/grok-commands" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global >/dev/null 2>&1)
INO2="$(command ls -di "$GHOME/agent-comms/comms.sh" | awk '{print $1}')"
[ "$INO1" != "$INO2" ] \
  && ok "reinstall replaces the helper inode (a running reader survives)" || fail "reinstall replaces the helper inode"
# A new inode alone is not enough — the content and mode must actually land.
cmp -s "$GHOME/agent-comms/comms.sh" "$REPO/helpers/comms.sh" \
  && ok "reinstalled helper matches its source" || fail "reinstalled helper matches its source"
[ -x "$GHOME/agent-comms/comms.sh" ] && ok "reinstalled helper stays executable" || fail "reinstalled helper stays executable"
# Commands are rewritten the same way; a stale command file is the same failure class.
CINO1="$(command ls -di "$GHOME/commands/auto.md" | awk '{print $1}')"
printf '\n' >> "$GHOME/commands/auto.md"
(cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GHOME/commands" CODEX_SKILLS_DIR="$GHOME/skills" GROK_COMMANDS_DIR="$GHOME/grok-commands" AGENT_COMMS_HOME="$GHOME/agent-comms" bash "$REPO/install.sh" --scope=global >/dev/null 2>&1)
CINO2="$(command ls -di "$GHOME/commands/auto.md" | awk '{print $1}')"
[ "$CINO1" != "$CINO2" ] && ok "reinstall replaces the command inode too" || fail "reinstall replaces the command inode too"
# NEGATIVE CONTROL: the inode assertions above are evidence only if they CAN fail.
# Prove that a plain cp keeps the inode on this filesystem, so a regression back to
# `cp` would be observed rather than passing vacuously.
ICTL="$WORK/inode-control"; mkdir -p "$ICTL"
printf 'a\n' > "$ICTL/src"; printf 'bb\n' > "$ICTL/dst"
XINO1="$(command ls -di "$ICTL/dst" | awk '{print $1}')"
cp "$ICTL/src" "$ICTL/dst"
XINO2="$(command ls -di "$ICTL/dst" | awk '{print $1}')"
[ "$XINO1" = "$XINO2" ] \
  && ok "control: plain cp keeps the inode, so the assertion can fail" || fail "control: plain cp keeps the inode"
# The temp is a sibling of the destination (a cross-device temp would make `mv` a
# non-atomic copy) and must not survive a SUCCESSFUL install: a stray file in the helper
# or command dir is install surface that nothing owns. This is deliberately not a claim
# about every failure path — a hard kill between the copy and the rename leaves the
# predictable dot-temp behind, and no trap can be relied on for that. (codex advisory r1.)
ls -A "$GHOME/agent-comms" | grep -q '^\.agent-comms-install\.' \
  && fail "install left a temp beside the helpers" || ok "install leaves no temp litter beside the helpers"
ls -A "$GHOME/commands" | grep -q '^\.agent-comms-install\.' \
  && fail "install left a temp in the commands dir" || ok "install leaves no temp litter in the commands dir"
ls -A "$INST_FIX/.agent-comms" | grep -q '^\.agent-comms-install\.' \
  && fail "local install left a temp beside the pinned helpers" || ok "local install leaves no temp litter"

# Replacing a file by rename is not the same operation as writing through it, so the
# three things `cp` did incidentally are now reproduced on purpose. Each was found by
# review, not by the round-1 tests, which only checked that the file was executable.
# %Mp%Lp, not %Lp: Darwin's %Lp drops setuid/setgid/sticky, so a preservation bug in the
# special nibble would be invisible to every assertion below. The leading 0 of an ordinary
# file is trimmed so both platforms read as three digits. (grok, panel r2.)
mode_of() { local m; m="$(stat -f '%Mp%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null)"; printf '%s' "${m#0}"; }
gh_install() { # gh_install <home> [extra-env...]  — a global install into an arbitrary home
  local gh="$1"; shift
  (cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$gh/commands" CODEX_SKILLS_DIR="$gh/skills" \
     GROK_COMMANDS_DIR="$gh/grok-commands" \
     AGENT_COMMS_HOME="$gh/agent-comms" "$@" bash "$REPO/install.sh" --scope=global 2>&1)
}
# MODE, UPGRADE: an existing destination kept its own mode under `cp`. A literal 755
# would reset a helper a user tightened, and a fresh-temp mode would reset a command
# they tightened. (codex blocking r1; grok r1 named the exact 700 -> 711 transition.)
chmod 640 "$GHOME/commands/auto.md"
chmod 700 "$GHOME/agent-comms/comms.sh"
# umask is pinned: `chmod +x` is masked by it, so 700 becomes 711 under 022 but 700 under
# 077 — an unpinned expectation fails on a hardened box while the code is correct.
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$(mode_of "$GHOME/commands/auto.md")" = "640" ] \
  && ok "an upgrade preserves a command's tightened mode" \
  || fail "command mode reset to $(mode_of "$GHOME/commands/auto.md") (want 640)"
[ "$(mode_of "$GHOME/agent-comms/comms.sh")" = "711" ] \
  && ok "an upgrade keeps a helper's mode and only adds +x (700 -> 711)" \
  || fail "helper mode became $(mode_of "$GHOME/agent-comms/comms.sh") (want 711)"
# MODE, FRESH INSTALL under a restrictive umask: `cp` masked the SOURCE mode by umask and
# `chmod +x` was masked too, so a umask-077 box never published a world-executable
# helper. A hardcoded 755 did exactly that.
GH_UM="$WORK/ghome-umask"
(umask 077; gh_install "$GH_UM" >/dev/null 2>&1)
[ "$(mode_of "$GH_UM/agent-comms/comms.sh")" = "700" ] \
  && ok "a fresh install under umask 077 leaves the helper private (700)" \
  || fail "umask-077 helper installed as $(mode_of "$GH_UM/agent-comms/comms.sh") (want 700)"
[ "$(mode_of "$GH_UM/commands/auto.md")" = "600" ] \
  && ok "a fresh install under umask 077 leaves the command private (600)" \
  || fail "umask-077 command installed as $(mode_of "$GH_UM/commands/auto.md") (want 600)"
# SYMLINK to a regular file: `cp` wrote THROUGH it. A bare rename would replace the link
# and silently disconnect a dotfile-managed install, so the link is resolved and its
# TARGET is what gets atomically replaced.
GH_SL="$WORK/ghome-symlink"
gh_install "$GH_SL" >/dev/null 2>&1
SL_REAL="$WORK/symlink-target"; mkdir -p "$SL_REAL"
mv "$GH_SL/commands/auto.md" "$SL_REAL/real-auto.md"
ln -s "$SL_REAL/real-auto.md" "$GH_SL/commands/auto.md"
printf '\n' >> "$SL_REAL/real-auto.md"
SL_INO1="$(command ls -di "$SL_REAL/real-auto.md" | awk '{print $1}')"
gh_install "$GH_SL" >/dev/null 2>&1
[ -L "$GH_SL/commands/auto.md" ] \
  && ok "a symlinked destination survives the install as a symlink" || fail "install replaced the symlink itself"
SL_INO2="$(command ls -di "$SL_REAL/real-auto.md" | awk '{print $1}')"
[ "$SL_INO1" != "$SL_INO2" ] && cmp -s "$SL_REAL/real-auto.md" "$REPO/templates/claude-commands/auto.md" \
  && ok "the symlink's TARGET is replaced, atomically" \
  || fail "symlink target not atomically replaced (ino $SL_INO1 -> $SL_INO2)"
# SYMLINK to a DIRECTORY is the silently non-atomic case: macOS `mv` follows it and moves
# the temp INSIDE the directory, reporting success — and cross-device that is a
# copy-in-place. Refuse loudly instead. (codex blocking r1.)
GH_SD="$WORK/ghome-symdir"
gh_install "$GH_SD" >/dev/null 2>&1
SD_DIR="$WORK/symlink-dir"; mkdir -p "$SD_DIR"
rm -f "$GH_SD/commands/ask.md"; ln -s "$SD_DIR" "$GH_SD/commands/ask.md"
SD_OUT="$(gh_install "$GH_SD" 2>&1 || true)"
[ -z "$(ls -A "$SD_DIR" 2>/dev/null)" ] \
  && ok "a symlink-to-directory destination never swallows the installed file" \
  || fail "install moved a file inside the linked directory ($(ls -A "$SD_DIR"))"
printf '%s\n' "$SD_OUT" | grep -q 'is a directory' \
  && ok "the directory destination is refused LOUDLY" || fail "directory refusal was silent (got: $SD_OUT)"
# AN UNWRITABLE DESTINATION used to make `cp` fail and abort the install — the only way a
# user can pin a customized file. `mv -f` unlinks the entry regardless, so the refusal
# has to be explicit or the pin silently stops working. (grok r1.)
GH_RO="$WORK/ghome-readonly"
gh_install "$GH_RO" >/dev/null 2>&1
chmod 444 "$GH_RO/commands/auto.md"
RO_BEFORE="$(command ls -di "$GH_RO/commands/auto.md" | awk '{print $1}')"
RO_OUT="$(gh_install "$GH_RO" 2>&1 || true)"
printf '%s\n' "$RO_OUT" | grep -q 'not writable' \
  && ok "a read-only destination is refused loudly, not silently replaced" || fail "read-only dest not refused (got: $RO_OUT)"
[ "$RO_BEFORE" = "$(command ls -di "$GH_RO/commands/auto.md" | awk '{print $1}')" ] \
  && ok "the pinned file is still the same file" || fail "the read-only destination was replaced anyway"
# The refusals must also FAIL the install the way the old `cp` did — printing a warning
# and exiting 0 would let a scripted upgrade march on. (codex advisory r2.)
gh_install "$GH_RO" >/dev/null 2>&1 && fail "a read-only destination did not fail the install" \
  || ok "a refused destination exits non-zero"
gh_install "$GH_SD" >/dev/null 2>&1 && fail "a directory destination did not fail the install" \
  || ok "a directory destination exits non-zero"
# SPECIAL MODE BITS survive an upgrade: Darwin's %Lp would silently drop them, so this
# fails if either the installer or mode_of stops carrying the nibble. (grok r2.)
# SETUID specifically, not just sticky: `chown` clears setuid/setgid and leaves sticky
# alone, so a sticky-only assertion cannot see the chown-after-chmod ordering bug at all.
# (grok r3: `chown` of the SAME uid:gid turned 4755 into 0755.)
chmod 4750 "$GHOME/commands/ask.md"
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$(mode_of "$GHOME/commands/ask.md")" = "4750" ] \
  && ok "an upgrade preserves the setuid bit through the ownership step" \
  || fail "setuid lost: $(mode_of "$GHOME/commands/ask.md") (want 4750)"
chmod 1640 "$GHOME/commands/ask.md"
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$(mode_of "$GHOME/commands/ask.md")" = "1640" ] \
  && ok "an upgrade preserves the sticky bit" \
  || fail "sticky lost: $(mode_of "$GHOME/commands/ask.md") (want 1640)"
# OWNER AND GROUP: writing through the old inode kept them; a fresh temp inherits the
# parent directory's group on BSD. The group is the half a non-root user can actually
# assert, so it is the half asserted here. (codex blocking r2.)
GRP_BEFORE="$(stat -f '%g' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%g' "$GHOME/agent-comms/comms.sh")"
OWN_BEFORE="$(stat -f '%u' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%u' "$GHOME/agent-comms/comms.sh")"
(umask 022; gh_install "$GHOME" >/dev/null 2>&1)
[ "$GRP_BEFORE" = "$(stat -f '%g' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%g' "$GHOME/agent-comms/comms.sh")" ] \
  && ok "an upgrade preserves the destination's group" || fail "group changed across the upgrade"
[ "$OWN_BEFORE" = "$(stat -f '%u' "$GHOME/agent-comms/comms.sh" 2>/dev/null || stat -c '%u' "$GHOME/agent-comms/comms.sh")" ] \
  && ok "an upgrade preserves the destination's owner" || fail "owner changed across the upgrade"
# SYMLINK CHAINS: a relative link to a relative link, resolved by concatenating dirname at
# each hop. Round 2 only covered a single absolute hop. (codex advisory r2.)
GH_SC="$WORK/ghome-symchain"
gh_install "$GH_SC" >/dev/null 2>&1
SC_REAL="$WORK/symchain-target"; mkdir -p "$SC_REAL"
mv "$GH_SC/commands/auto.md" "$SC_REAL/final.md"
ln -s "../../symchain-target/final.md" "$GH_SC/commands/hop1.md"
ln -s "hop1.md" "$GH_SC/commands/auto.md"
printf '\n' >> "$SC_REAL/final.md"
SC_INO1="$(command ls -di "$SC_REAL/final.md" | awk '{print $1}')"
gh_install "$GH_SC" >/dev/null 2>&1
[ -L "$GH_SC/commands/auto.md" ] && [ -L "$GH_SC/commands/hop1.md" ] \
  && ok "a relative symlink CHAIN is followed, not replaced" || fail "a link in the chain was replaced"
[ "$SC_INO1" != "$(command ls -di "$SC_REAL/final.md" | awk '{print $1}')" ] \
  && cmp -s "$SC_REAL/final.md" "$REPO/templates/claude-commands/auto.md" \
  && ok "the chain's final target is the file that gets replaced" || fail "chain target not replaced"
# A DANGLING link is -L true / -e false. `cp` wrote through it and created the target;
# the resolver must do the same rather than replacing the link or refusing.
GH_DL="$WORK/ghome-dangling"
gh_install "$GH_DL" >/dev/null 2>&1
DL_REAL="$WORK/dangling-target"; mkdir -p "$DL_REAL"
rm -f "$GH_DL/commands/auto.md"
ln -s "$DL_REAL/not-there-yet.md" "$GH_DL/commands/auto.md"
gh_install "$GH_DL" >/dev/null 2>&1
[ -L "$GH_DL/commands/auto.md" ] && [ -f "$DL_REAL/not-there-yet.md" ] \
  && cmp -s "$DL_REAL/not-there-yet.md" "$REPO/templates/claude-commands/auto.md" \
  && ok "a dangling symlink is written through, creating its target" \
  || fail "dangling symlink not written through"
# A GROUP THE TEMP CANNOT INHERIT. The round-3 assertions compared the destination's group
# to itself in a directory of the same group, so they passed against an implementation
# that preserved nothing. Give the destination a secondary group of this user that differs
# from its parent directory's, which a fresh temp provably cannot pick up. (codex r3.)
GH_GRP="$WORK/ghome-group"
gh_install "$GH_GRP" >/dev/null 2>&1
grp_of() { stat -f '%g' "$1" 2>/dev/null || stat -c '%g' "$1" 2>/dev/null; }
PARENT_G="$(grp_of "$GH_GRP/commands")"
ALT_G="$(id -G | tr ' ' '\n' | grep -v "^${PARENT_G}$" | head -1)"
if [ -n "$ALT_G" ] && chgrp "$ALT_G" "$GH_GRP/commands/auto.md" 2>/dev/null; then
  GRP_PRESERVE_OK=1
  (umask 022; gh_install "$GH_GRP" >/dev/null 2>&1)
  [ "$(grp_of "$GH_GRP/commands/auto.md")" = "$ALT_G" ] \
    && ok "an upgrade preserves a group the temp could not have inherited" \
    || fail "group fell back to the directory's ($(grp_of "$GH_GRP/commands/auto.md"), want $ALT_G)"
else
  # An uncounted `note` here made the corpus size machine-dependent, so a fixed contract
  # would refuse forever on any host without a usable secondary group. Accounted, not
  # narrated. (codex, panel r5, blocking.)
  GRP_PRESERVE_OK=0
  skip group-no-secondary "an upgrade preserves a group the temp could not have inherited — no usable secondary group here"
fi
# ...and when ownership CANNOT be restored, the install must FAIL rather than publish the
# file under the wrong group and exit 0. A privileged group cannot be created hermetically,
# so `chown` is stubbed to fail, which is the same branch. (codex r3: warn-and-exit-0 left
# criterion 9 unmet while the install looked successful.)
# Read the install order from install.sh rather than restating it here: a second copy of
# that list is a thing that silently stops matching.
CLAUDE_COMMANDS_LIST="$(sed -n 's/^CLAUDE_COMMANDS="\(.*\)"$/\1/p' "$REPO/install.sh" | head -1)"
[ -n "$CLAUDE_COMMANDS_LIST" ] || fail "could not read CLAUDE_COMMANDS from install.sh"
FAILBIN="$WORK/failbin"; mkdir -p "$FAILBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAILBIN/chown"; chmod +x "$FAILBIN/chown"
# The installer aborts on the FIRST destination it processes, so the unchanged-destination
# assertion has to name that one. Anchoring it on a later file examined something the run
# never reached, which made the assertion vacuous. (codex, panel round 4.)
CHOWN_FIRST="$GH_GRP/commands/$(printf '%s\n' $CLAUDE_COMMANDS_LIST | head -1)"
CHOWN_INO1="$(command ls -di "$CHOWN_FIRST" | awk '{print $1}')"
CHOWN_OUT="$( (cd "$INST_FIX" && CLAUDE_COMMANDS_DIR="$GH_GRP/commands" CODEX_SKILLS_DIR="$GH_GRP/skills" \
   GROK_COMMANDS_DIR="$GH_GRP/grok-commands" \
   AGENT_COMMS_HOME="$GH_GRP/agent-comms" PATH="$FAILBIN:$PATH" bash "$REPO/install.sh" --scope=global 2>&1) || true)"
printf '%s\n' "$CHOWN_OUT" | grep -q 'cannot restore owner/group' \
  && ok "an unrestorable owner/group refuses the replacement loudly" || fail "chown failure was not fatal (got: $(printf '%s' "$CHOWN_OUT" | tail -2))"
[ "$CHOWN_INO1" = "$(command ls -di "$CHOWN_FIRST" | awk '{print $1}')" ] \
  && ok "the first destination is untouched when ownership cannot be restored" || fail "destination replaced despite a failed chown"
ls -A "$GH_GRP/commands" | grep -q '^\.agent-comms-install\.' \
  && fail "the failed-chown path left its temp behind" || ok "the failed-chown path cleans up its temp"
# ACL DETECTION must not rely on the mode column: Darwin prints `@` INSTEAD of `+` when
# extended attributes are present, and they are routine here, so a file with BOTH shows
# `@` and the old probe stayed silent for exactly the case it was written to catch.
# (codex + grok, corroborated r3.)
GH_ACL="$WORK/ghome-acl"
gh_install "$GH_ACL" >/dev/null 2>&1
if chmod +a "everyone deny read" "$GH_ACL/commands/auto.md" 2>/dev/null; then
  ACL_PROBE_OK=1
  ACL_OUT="$(gh_install "$GH_ACL" 2>&1 || true)"
  printf '%s\n' "$ACL_OUT" | grep -q 'carries an ACL' \
    && ok "an ACL-only destination is reported" || fail "ACL not reported (got: $(printf '%s' "$ACL_OUT" | tail -2))"
  chmod +a "everyone deny read" "$GH_ACL/commands/ask.md" 2>/dev/null
  xattr -w com.agent-comms.test 1 "$GH_ACL/commands/ask.md" 2>/dev/null
  # This is the regression: with an xattr present the mode column reads `@`, so a
  # column-11 probe reports no ACL.
  [ "$(/bin/ls -ld "$GH_ACL/commands/ask.md" | cut -c11)" = "@" ] \
    && ok "the xattr+ACL destination really does mask the + marker" \
    || fail "fixture did not reproduce the @-masks-+ case"
  ACL2_OUT="$(gh_install "$GH_ACL" 2>&1 || true)"
  printf '%s\n' "$ACL2_OUT" | grep -q "ask.md carries an ACL" \
    && ok "an ACL is still reported when extended attributes mask the marker" \
    || fail "ACL missed behind an xattr (got: $(printf '%s' "$ACL2_OUT" | tail -2))"
  # ...and a file with xattrs but NO ACL must stay quiet, or the warning is noise.
  xattr -w com.agent-comms.test 1 "$GH_ACL/commands/clean-comms.md" 2>/dev/null
  ACL3_OUT="$(gh_install "$GH_ACL" 2>&1 || true)"
  printf '%s\n' "$ACL3_OUT" | grep -q "clean-comms.md carries an ACL" \
    && fail "extended attributes alone were reported as an ACL" \
    || ok "extended attributes alone are not reported as an ACL"
else
  # Four assertions live in the branch above. On a host without Darwin-style `chmod +a`
  # (every Linux box) an uncounted note dropped all four, and the fixed contract would
  # then refuse every run there. One named skip per omitted assertion.
  # (codex, panel r5, blocking.)
  ACL_PROBE_OK=0
  skip acl-report "an ACL-only destination is reported — ACLs unsupported here"
  skip acl-xattr-fixture "the xattr+ACL destination really does mask the + marker — ACLs unsupported here"
  skip acl-behind-xattr "an ACL is still reported when extended attributes mask the marker — ACLs unsupported here"
  skip acl-xattr-only "extended attributes alone are not reported as an ACL — ACLs unsupported here"
fi

section "comms.sh v2: thread filter + verdict normalization + error lane"
TA="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-00-00_alpha-1.md"
TB="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-00-01_beta-1.md"
cat > "$TA" <<'MSG'
---
type: review-feedback
from: codex
timestamp: 2026-06-04T13:00:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T13-00-00_alpha-1
thread: loop-alpha
workflow: auto-implement
phase: implement
round: 1
max-rounds: 10
verdict:  approve
---

## Summary
Alpha reply.
MSG
sed 's/alpha/beta/g; s/loop-beta/loop-beta/' "$TA" > "$TB"
LIST_T="$(run_comms list --as claude --thread loop-alpha)"
[ "$(echo "$LIST_T" | grep -c .)" = "1" ] && echo "$LIST_T" | grep -q alpha-1 && ok "list --thread isolates one loop's messages" || fail "list --thread isolation (got: $LIST_T)"
[ "$(run_comms verdict "$TA")" = "APPROVE" ] && ok "verdict normalizes ' approve ' -> APPROVE" || fail "verdict normalization (got: $(run_comms verdict "$TA"))"
ERRMSG="$WORK/error-lane.md"
sed 's/type: review-feedback/type: error/; /^verdict:/d' "$TA" > "$ERRMSG"
check "type: error from codex passes without verdict" run_comms validate "$ERRMSG"
NOTHREAD="$WORK/nothread.md"
grep -v '^thread:' "$TA" > "$NOTHREAD"
WARN="$( (cd "$REPO_FIX" && env "$COMMS" validate "$NOTHREAD") 2>&1 1>/dev/null )"
echo "$WARN" | grep -q "no thread field" && ok "workflow message without thread warns (soft, non-fatal)" || fail "thread soft warning (got: $WARN)"

section "comms.sh v2: state lifecycle"
OUT_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-05-00_round-2-777.md"
cat > "$OUT_WF" <<'MSG'
---
type: review-request
from: claude
timestamp: 2026-06-04T13:05:00Z
workspace: feature-helper-tests
message_id: feature-helper-tests_2026-06-04T13-05-00_round-2-777
thread: loop-alpha
workflow: auto-implement
phase: implement
round: 2
max-rounds: 10
---

## What was done
Round two.
MSG
check "send (manual pickup) succeeds" run_comms send --to codex "$OUT_WF"
SF="$REPO_FIX/.comms/state/feature-helper-tests_loop-alpha.json"
[ -f "$SF" ] && ok "send writes thread state file" || fail "send writes thread state file"
grep -q '"awaiting_from": "codex"' "$SF" && ok "state records who owes the next message" || fail "state awaiting_from"
grep -q '"last_delivery": "manual"' "$SF" && ok "state records delivery outcome (manual)" || fail "state last_delivery manual"
run_comms state list | grep -q 'loop-alpha.*r2/10' && ok "state list summarizes thread" || fail "state list (got: $(run_comms state list))"
# loop-rounds is the loop's REAL budget riding through the capped plan phase; state
# must keep a NON-DEFAULT value durably or a restart falls back to the default —
# the exact starvation the field exists to prevent. (codex, panel r1: the restore
# instruction existed but nothing mechanical preserved its source.)
OUT_LR="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-06-00_plan-lr7.md"
sed -e 's/^message_id: .*/message_id: feature-helper-tests_2026-06-04T13-06-00_plan-lr7/' \
    -e 's/^thread: .*/thread: loop-lr7/' \
    -e 's/^phase: implement/phase: plan/' -e 's/^round: 2/round: 1/' \
    -e 's/^max-rounds: 10/max-rounds: 2\nloop-rounds: 7/' "$OUT_WF" > "$OUT_LR"
check "send accepts a plan message carrying loop-rounds" run_comms send --to codex "$OUT_LR"
SF_LR="$REPO_FIX/.comms/state/feature-helper-tests_loop-lr7.json"
grep -q '"loop_rounds": "7"' "$SF_LR" \
  && ok "a non-default loop-rounds (7) survives into thread state" || fail "state loop_rounds (got: $(cat "$SF_LR" 2>/dev/null | head -8))"
grep -q '"max_rounds": "2"' "$SF_LR" \
  && ok "the plan cap and the loop budget are DISTINCT state fields" || fail "plan cap vs loop budget conflated"
# stalled: backdate the awaiting epoch by an hour
perl -pi -e 's/"awaiting_since_epoch": "\d+"/"awaiting_since_epoch": "'"$(( $(date +%s) - 3600 ))"'"/' "$SF"
run_comms stalled 15 | grep -q 'STALLED.*loop-alpha' && ok "stalled flags threads awaiting too long" || fail "stalled detection (got: $(run_comms stalled 15))"
run_comms stalled 15 | grep -q 'inbox=unread' && ok "stalled distinguishes an unread persisted message" || fail "stalled unread evidence (got: $(run_comms stalled 15))"
check "state complete marks thread done" run_comms state complete loop-alpha
grep -q '"status": "complete"' "$SF" && ok "state complete persists" || fail "state complete persists"
run_comms stalled 15 | grep -q 'no stalled' && ok "completed thread is not stalled" || fail "completed thread is not stalled"

section "comms.sh v2: state hardening (slash thread, garbage epoch, quotes)"
SLASH_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-10-00_slash-1.md"
SLASH_IN="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-09-00_slashin.md"
sed 's/thread: loop-alpha/thread: fix-auth\/login-99/; s/round: 2/round: 3/' "$OUT_WF" > "$SLASH_WF"
cp "$TA" "$SLASH_IN"
check "send survives a thread containing a slash" run_comms send --to codex "$SLASH_WF" --archive-inbound "$SLASH_IN"
[ ! -f "$SLASH_IN" ] && ok "inbound archived despite slash thread (no desync)" || fail "inbound archived despite slash thread"
[ -f "$REPO_FIX/.comms/state/feature-helper-tests_fix-auth_login-99.json" ] && ok "slash thread sanitized into state filename" || fail "slash thread sanitized (state dir: $(ls "$REPO_FIX/.comms/state/" 2>/dev/null))"
# garbage epoch must not crash stalled or fleet status
perl -pi -e 's/"awaiting_since_epoch": "\d+"/"awaiting_since_epoch": "garbage"/' "$REPO_FIX/.comms/state/feature-helper-tests_fix-auth_login-99.json"
check "stalled survives a garbage epoch" run_comms stalled 15
QUOTE_WF="$WORK/quote-wf.md"
sed 's/phase: implement/phase: fix "login" bug/' "$OUT_WF" > "$QUOTE_WF"
(cd "$REPO_FIX" && env "$COMMS" send --to codex "$QUOTE_WF") >/dev/null 2>&1
grep -q '\\"login\\"' "$REPO_FIX/.comms/state/feature-helper-tests_loop-alpha.json" && ok "embedded quotes escaped in state JSON" || fail "embedded quotes escaped (got: $(grep phase "$REPO_FIX/.comms/state/feature-helper-tests_loop-alpha.json"))"

section "comms.sh v2: state dir blocked as a FILE must not break send/archive"
mv "$REPO_FIX/.comms/state" "$REPO_FIX/.comms/state.bak"
touch "$REPO_FIX/.comms/state"
BLOCK_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-20-00_blocked-1.md"
BLOCK_IN="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-19-00_blockedin.md"
sed 's/round: 2/round: 4/' "$OUT_WF" > "$BLOCK_WF"
cp "$TA" "$BLOCK_IN"
BLOCK_OUT="$( (cd "$REPO_FIX" && env "$COMMS" send --to codex "$BLOCK_WF" --archive-inbound "$BLOCK_IN") 2>&1 )"
BLOCK_RC=$?
[ "$BLOCK_RC" -eq 0 ] && ok "send succeeds when state dir is blocked (rc=0)" || fail "send succeeds when state dir is blocked (rc=$BLOCK_RC; out: $BLOCK_OUT)"
[ ! -f "$BLOCK_IN" ] && ok "inbound archived despite blocked state dir (no desync)" || fail "inbound archived despite blocked state dir"
echo "$BLOCK_OUT" | grep -q "cannot create state dir" && ok "blocked state dir produces explicit warning" || fail "blocked state dir warning (got: $BLOCK_OUT)"
rm -f "$REPO_FIX/.comms/state"
mv "$REPO_FIX/.comms/state.bak" "$REPO_FIX/.comms/state"

section "comms.sh v2.1.1: status shouts when a loop stalled undelivered"
perl -pi -e 's/"last_delivery": "[^"]*"/"last_delivery": "manual"/; s/"status": "[^"]*"/"status": "in-progress"/' "$SF"
ST_OUT="$(run_comms status)"
echo "$ST_OUT" | grep -q "ACTION NEEDED" && ok "status prints ACTION NEEDED on undelivered last send" || fail "status ACTION line (got: $(echo "$ST_OUT" | tail -2))"
perl -pi -e 's/"status": "in-progress"/"status": "complete"/' "$SF"
ST_OUT="$(run_comms status)"
echo "$ST_OUT" | grep -q "ACTION NEEDED" && fail "completed thread must not shout" || ok "completed thread does not shout"

section "comms.sh v2.1: send emits a loud RESULT line — and it is the FINAL line"
RES_OUT="$( (cd "$REPO_FIX" && env "$COMMS" send --to codex "$OUT_WF") 2>/dev/null )"
echo "$RES_OUT" | grep -q "^RESULT: manual" && ok "manual outcome includes RESULT: manual" || fail "RESULT line (got: $(echo "$RES_OUT" | tail -1))"
# The autonomous path (--archive-inbound) must ALSO end with RESULT, not "archived:".
RES_IN="$REPO_FIX/.comms/to-claude/feature-helper-tests_2026-06-04T13-30-00_resin.md"
cp "$TA" "$RES_IN"
RES_TAIL="$( (cd "$REPO_FIX" && env "$COMMS" send --to codex "$OUT_WF" --archive-inbound "$RES_IN") 2>/dev/null | tail -1 )"
case "$RES_TAIL" in RESULT:*) ok "tail -1 of send --archive-inbound is the RESULT line" ;; *) fail "final line on archive path (got: $RES_TAIL)" ;; esac
[ ! -f "$RES_IN" ] && ok "inbound still archived on the RESULT-last path" || fail "inbound archived on RESULT-last path"

# `runphase v0: headless delivery via stubbed codex` was DELETED in step 4 (S4-2). Its subject
# was codex self-send over the headless transport, and that path no longer exists: claude and
# codex review turns are ACP-only. Every assertion in it either failed outright or passed
# VACUOUSLY once the path was gone (a "never touched cmux" or "await exits non-zero" that holds
# because nothing ran at all is not coverage). The headless transport itself survives for grok,
# and is exercised by the grok leg sections; the ACP equivalents for claude/codex failure
# reporting were added BEFORE this deletion, in the same branch.

# These two outlive that section: step 2 below still needs a headless driver and the claude stub's
# argv log. headless is now grok-only.
# These outlive the deleted section because later sections still use them. RUNPHASE and rundir_of
# are transport-neutral; run_headless/run_rp pin headless, which is now grok-only.
export CODEX_STUB_LOG="$WORK/codex.log"
RUNPHASE="$REPO/helpers/runphase.sh"
section "runphase step 2: hold, release, and the stalled watchdog"
# claude stub: mirrors the codex stub — init event carries session_id, result
# event ends the turn. Toggles: CLAUDE_STUB_FAIL, CLAUDE_STUB_HANG.
cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/bash
{ echo "claude-argv: $*"; echo "claude-env: CLAUDECODE=${CLAUDECODE:-unset}"; } >> "$CODEX_STUB_LOG"
cat > /dev/null
# Real claude emits init promptly, then works — hang AFTER init so a timeout
# still has a session id to capture.
echo '{"type":"system","subtype":"init","session_id":"stub-claude-session-7"}'
[ -n "${CLAUDE_STUB_HANG:-}" ] && sleep "$CLAUDE_STUB_HANG"
if [ -n "${CLAUDE_STUB_FAIL:-}" ]; then
  echo '{"type":"result","subtype":"error","is_error":true}'
  exit 1
fi
echo '{"type":"result","subtype":"success","is_error":false}'
exit 0
STUB
chmod +x "$STUB_BIN/claude"

# The claude-backend blocks that stood here (reverse direction, failed turn, timeout) were
# deleted in step 4 (S4-2): claude review turns are ACP-only now, and their ACP equivalents
# — status=failed, provider-named result, no leaked reply — live in the brokered-legs section.

# -- hold: pause at the turn boundary; release resumes. Driven by GROK, because headless is
# grok-only after step 4 (S4-2) and this coverage is about the HOLD MECHANISM, which is
# transport-agnostic. It lives nowhere else in the corpus, so it is re-pointed, not deleted.
HRV="$REPO_FIX/.comms/to-grok/feature-helper-tests_2026-06-04T15-00-00_hold-1.md"
mkdir -p "$REPO_FIX/.comms/to-grok"
cat > "$HRV" <<'HOLDEOF'
---
type: review-request
from: claude
timestamp: 2026-06-04T15:00:00Z
message_id: feature-helper-tests_2026-06-04T15-00-00_hold-1
workspace: feature-helper-tests
thread: loop-hold
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## Plan
hold fixture
HOLDEOF
HRV_OUT="$(run_headless send --to grok "$HRV" 2>/dev/null)"
case "$(echo "$HRV_OUT" | tail -1)" in "RESULT: spawned"*) ok "a grok loop spawns on the headless transport" ;; *) fail "hold fixture did not spawn (got: $(echo "$HRV_OUT" | tail -1))" ;; esac
run_rp await "$(rundir_of "$HRV_OUT")" --timeout-secs 30 >/dev/null 2>&1 || true
HRV_SF="$REPO_FIX/.comms/state/feature-helper-tests_loop-hold.json"
HOLD_OUT="$(run_rp hold loop-hold)"
echo "$HOLD_OUT" | grep -q "held: loop-hold" && ok "hold sets a thread marker" || fail "hold output (got: $HOLD_OUT)"
# Written fresh, NOT sed'd from $HRV: the first send ARCHIVES its inbound, so the source file is
# already gone by the time this runs.
HRV2="$REPO_FIX/.comms/to-grok/feature-helper-tests_2026-06-04T15-05-00_hold-2.md"
cat > "$HRV2" <<'HOLD2EOF'
---
type: review-request
from: claude
timestamp: 2026-06-04T15:05:00Z
message_id: feature-helper-tests_2026-06-04T15-05-00_hold-2
workspace: feature-helper-tests
thread: loop-hold
workflow: auto
phase: implement
round: 2
max-rounds: 4
---

## Plan
hold fixture round 2
HOLD2EOF
HELD_OUT="$(run_headless send --to grok "$HRV2" 2>/dev/null)"
case "$(echo "$HELD_OUT" | tail -1)" in "RESULT: held"*) ok "send on a held thread reports RESULT: held" ;; *) fail "held RESULT (got: $(echo "$HELD_OUT" | tail -1))" ;; esac
echo "$HELD_OUT" | grep -q "spawned runphase" && fail "held send must not spawn" || ok "held send spawns nothing"
grep -q '"last_delivery": "held"' "$HRV_SF" && ok "state records held" || fail "state held (got: $(cat "$HRV_SF" 2>/dev/null | head -c 120))"
ST_HELD="$(run_headless status)"
echo "$ST_HELD" | grep -q "ACTION NEEDED" && fail "held thread must not shout ACTION NEEDED" || ok "a held thread is a deliberate pause, not an alarm"
run_rp release loop-hold | grep -q "released" && ok "release lifts the hold" || fail "release output"
RES_OUT2="$(run_headless send --to grok "$HRV2" 2>/dev/null)"
case "$(echo "$RES_OUT2" | tail -1)" in "RESULT: spawned"*) ok "released thread spawns again" ;; *) fail "post-release send (got: $(echo "$RES_OUT2" | tail -1))" ;; esac
run_rp await "$(rundir_of "$RES_OUT2")" --timeout-secs 30 >/dev/null 2>&1 || true

# -- global hold blocks everything --
# A pending message is a PRECONDITION: `deliver` with an empty inbox warns and returns before it
# ever consults the hold marker, so without this the assertion would pass or fail on inbox state
# rather than on the hold. The earlier sends archived theirs.
GH_MSG="$REPO_FIX/.comms/to-grok/feature-helper-tests_2026-06-04T15-09-00_ghold-1.md"
cat > "$GH_MSG" <<'GHOLDEOF'
---
type: review-request
from: claude
timestamp: 2026-06-04T15:09:00Z
message_id: feature-helper-tests_2026-06-04T15-09-00_ghold-1
workspace: feature-helper-tests
thread: loop-ghold
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## Plan
global hold fixture
GHOLDEOF
run_rp hold >/dev/null
GH_OUT="$(run_headless deliver grok)"
echo "$GH_OUT" | grep -q "HELD:" && ok "global hold blocks all spawns" || fail "global hold (got: $GH_OUT)"
run_rp release >/dev/null

WD_RUN="$WORK/wd-run"
mkdir -p "$WD_RUN"
echo "999999" > "$WD_RUN/pid"
cat > "$REPO_FIX/.comms/state/feature-helper-tests_loop-watchdog.json" <<JSON
{
  "workspace": "feature-helper-tests",
  "thread": "loop-watchdog",
  "workflow": "auto-implement",
  "phase": "implement",
  "round": "1",
  "max_rounds": "10",
  "status": "in-progress",
  "awaiting_from": "codex",
  "awaiting_since": "2026-06-04T15:00:00Z",
  "awaiting_since_epoch": "$(( $(date +%s) - 3600 ))",
  "last_sent": "x",
  "last_run_dir": "$WD_RUN",
  "last_delivery": "spawned"
}
JSON
run_comms stalled 15 | grep -q "runner DEAD without a result" && ok "watchdog flags a dead runner with no result" || fail "watchdog dead (got: $(run_comms stalled 15))"
echo '{"status": "completed"}' > "$WD_RUN/result.json"
run_comms stalled 15 | grep -q "turn finished: completed" && ok "watchdog reports a finished-but-unread turn" || fail "watchdog finished (got: $(run_comms stalled 15))"
rm -f "$WD_RUN/result.json"
echo "$$" > "$WD_RUN/pid"
run_comms stalled 15 | grep -q "runner alive" && ok "watchdog reports a live runner still working" || fail "watchdog alive (got: $(run_comms stalled 15))"
rm -f "$REPO_FIX/.comms/state/feature-helper-tests_loop-watchdog.json"

section "headless delivery: self-pickup suppression and a missing runner"
# RESTORED from the deleted `runphase v0` section and re-pointed at GROK, the only provider
# still on the headless transport after step 4. My tombstone claimed every assertion in that
# section was dead or vacuous once codex self-send went away. That was TOO BROAD: all three
# behaviours below still live in `deliver_headless`, and deleting them left the SELF-NUDGE
# RECURSION GUARD uncovered anywhere in the corpus — a grok peer that nudged itself would
# spawn turns forever. (grok, S4-2 implement r1, advisory.)
# Each pair asserts the POSITIVE first: a lone "does not warn X" passes vacuously when
# delivery failed outright for an unrelated reason.
PICKV="$REPO_FIX/.comms/to-grok/feature-helper-tests_2026-06-04T18-00-00_pickup-1.md"
mkdir -p "$REPO_FIX/.comms/to-grok"
cat > "$PICKV" <<'PICKEOF'
---
type: review-request
from: claude
timestamp: 2026-06-04T18:00:00Z
message_id: feature-helper-tests_2026-06-04T18-00-00_pickup-1
workspace: feature-helper-tests
thread: loop-pickup
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## Plan
pickup fixture
PICKEOF

GPICK="$( (cd "$REPO_FIX" && env COMMS_DELIVERY=headless COMMS_HEADLESS_PICKUP=grok PATH="$STUB_BIN:$PATH" "$COMMS" deliver grok) 2>&1 )"
echo "$GPICK" | grep -q "written for pickup" && ok "a headless peer leaves its reply for pickup instead of nudging itself" || fail "self-pickup suppression (got: $GPICK)"
echo "$GPICK" | grep -q "NOT spawned" && fail "deliberate pickup must not warn NOT spawned" || ok "deliberate pickup is not reported as a failed spawn"

GLONELY="$WORK/lonely-grok"
mkdir -p "$GLONELY"
cp "$COMMS" "$GLONELY/comms.sh" && chmod +x "$GLONELY/comms.sh"
# GROK r3 BLOCKER, pinned behaviourally. On the grok-headless path the DRIVER exports
# COMMS_DELIVERY=headless; the parent's broker then sends the reply to claude/codex. Pickup
# used to be consulted INSIDE deliver_headless, i.e. AFTER cmd_transport had already died on
# headless_ok — so the send failed while broker_stamp's copy made the turn look answered.
# The reply-to-driver direction must be a no-op, never a refusal and never a "re-run
# install.sh" lie. The control below proves this is pickup, not a blanket exemption.
GPB="$( (cd "$REPO_FIX" && env COMMS_DELIVERY=headless COMMS_HEADLESS_PICKUP=claude PATH="$STUB_BIN:$PATH" "$COMMS" deliver claude) 2>&1 )"
echo "$GPB" | grep -q "written for pickup" && ok "a reply to the driving session is pickup even under COMMS_DELIVERY=headless" || fail "pickup before transport (got: $GPB)"
# COUPLED to non-empty output: a bare `grep && fail || ok` passes on empty stdout, which is
# the same vacuous family this section exists to catch. (grok, S4-2 r4, advisory — found in
# the very assertion added to guard against it.)
{ [ -n "$GPB" ] && ! printf '%s\n' "$GPB" | grep -qi "re-run install.sh"; } \
  && ok "no re-run-install.sh lie on the reply-to-driver path" \
  || fail "the inherited headless flag still produces the install.sh lie (got: $GPB)"
GPB_CTL="$( (cd "$REPO_FIX" && env COMMS_DELIVERY=headless COMMS_HEADLESS_PICKUP=grok PATH="$STUB_BIN:$PATH" "$COMMS" deliver claude) 2>&1 )"
echo "$GPB_CTL" | grep -q "not available for 'claude'" && ok "a non-pickup claude target still refuses headless (pickup is not a blanket exemption)" || fail "pickup control (got: $GPB_CTL)"

GLONE="$( (cd "$REPO_FIX" && env COMMS_DELIVERY=headless "$GLONELY/comms.sh" deliver grok) 2>&1 )"
echo "$GLONE" | grep -q "runphase.sh was not found" && ok "a missing headless runner degrades with an explicit warning" || fail "missing runphase warning (got: $GLONE)"
# The warning must not blame an env var the operator never set — headless is the default now.
echo "$GLONE" | grep -q "COMMS_DELIVERY=headless but" && fail "warning blames an unset env var" || ok "the missing-runner warning does not blame an unset env var"

section "comms.sh: workspace identity (no cmux)"
# The cmux title/cache/backoff sections are gone with the transport. What SURVIVES is
# repo_workspace_name, and its `main` case was never covered: the corpus runs on branch
# `feature-helper-tests`. Deleting the cmux guard around the `main -> <repo-name>` substitution
# is behaviour-preserving ONLY because `${ws:-$root_name}` still prints a non-empty `$ws`.
# Making that substitution unconditional would flip every unpinned repo on `main` to the repo
# name, changing the message-filename prefix and hiding pending messages behind the glob
# (field report #3). This pins it. (S4-4.)
WSI="$WORK/wsid/some-repo-name"
mkdir -p "$WSI" && ( cd "$WSI" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) 2>/dev/null
WSI_MAIN="$( cd "$WSI" && "$COMMS" workspace 2>/dev/null )"
[ "$WSI_MAIN" = "main" ] && ok "on 'main' with no pin the workspace stays 'main', not the repo directory name" || fail "main-branch workspace (got: $WSI_MAIN)"
( cd "$WSI" && git checkout -q -b feature/some-work ) 2>/dev/null
WSI_BR="$( cd "$WSI" && "$COMMS" workspace 2>/dev/null )"
[ "$WSI_BR" = "feature-some-work" ] && ok "a branch name still sanitises into the workspace identity" || fail "branch workspace (got: $WSI_BR)"
# A STALE CMUX_WORKSPACE_ID must change nothing. Old and new repo_workspace_name disagree on
# exactly this input — the old code substituted the repo directory name on a generic default
# branch when that env was set. Restoring the guard "to be safe" would flip the mailbox prefix
# and hide pending mail behind the glob (field report #3). (grok, S4-4 r2, cheap insurance.)
( cd "$WSI" && git checkout -q main ) 2>/dev/null
WSI_STALE="$( cd "$WSI" && env CMUX_WORKSPACE_ID=workspace:99 "$COMMS" workspace 2>/dev/null )"
[ "$WSI_STALE" = "main" ] && ok "a leftover CMUX_WORKSPACE_ID cannot rename the workspace" || fail "stale cmux env changed identity (got: $WSI_STALE)"

section "panel dispatch: synthetic-snapshot warning"
# THE MECHANICAL GUARD a doc rule could not provide. Ownership of a dirty file is unknowable,
# but "was the dispatched snapshot SYNTHETIC" is not: cmd_snapshot returns artifact == base for
# a clean tree and artifact != base when it had to wrap a dirty one. Warn, never refuse.
# Both arms asserted, because a warning that always fires is worth nothing.
# (codex + grok, staging-safety r1 — they overturned my "no mechanical guard exists" claim.)
SNAPW="$WORK/snapw"; rm -rf "$SNAPW"; mkdir -p "$SNAPW/.comms/to-codex"
( cd "$SNAPW" && git init -q -b main . && printf 'a\n' > a.txt && printf '.comms/\n' > .gitignore
  cat > r.md <<'SNAPR'
---
type: review-request
from: claude
timestamp: 2026-09-02T00:00:00Z
message_id: snapw_2026-09-02T00-00-00_r-1
workspace: snapw
thread: snapw
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## Intent
snapshot dirt probe
SNAPR
  git add -A && git -c user.email=t@t -c user.name=t commit -q -m init ) >/dev/null 2>&1
# STREAMS SPLIT. Grepping `2>&1` could not tell the stdout marker from the stderr warning, so it
# would have passed with `synthetic_note` never set — the exact weakness these tests exist to
# catch. stdout and stderr are captured separately and asserted separately.
# (codex + grok, staging-safety r3, corroborated.)
SNAP_CLEAN_O="$( (cd "$SNAPW" && env COMMS_DELIVERY=mailbox "$COMMS" panel dispatch --to codex r.md) 2>/dev/null | grep -c 'SYNTHETIC' )"
printf 'FOREIGN\n' > "$SNAPW/someone-elses.txt"
SNAP_DIRTY_O="$( (cd "$SNAPW" && env COMMS_DELIVERY=mailbox "$COMMS" panel dispatch --to codex r.md) 2>/dev/null | grep -c 'SYNTHETIC' )"
SNAP_DIRTY_E="$( (cd "$SNAPW" && env COMMS_DELIVERY=mailbox "$COMMS" panel dispatch --to codex r.md) 2>&1 >/dev/null | grep -c 'SYNTHETIC' )"
[ "$SNAP_CLEAN_O" = "0" ] && ok "a clean-tree dispatch emits no synthetic-snapshot marker" || fail "synthetic marker on a clean tree (always-on warnings are worthless)"
[ "$SNAP_DIRTY_O" != "0" ] && ok "a dirty-tree dispatch marks STDOUT so a stdout-capturing caller sees it" || fail "no stdout marker on a dirty tree (the S4-4 stderr-only shape)"
[ "$SNAP_DIRTY_E" != "0" ] && ok "a dirty-tree dispatch also warns on stderr with the paths" || fail "no stderr warning on a dirty tree"
# THE ACTUAL r2 REGRESSION: dispatching from a LINKED WORKTREE must report THAT worktree's dirt,
# not the main checkout's. The original fixture was its own toplevel, which is why the wrong-tree
# bug survived my verification. (codex, r3: "the suite does not pin the two round-2 cases".)
SNAP_WT="$WORK/snapw-linked"
( cd "$SNAPW" && git worktree add -q -b snapw-probe "$SNAP_WT" ) >/dev/null 2>&1
printf 'ONLY-IN-WORKTREE\n' > "$SNAP_WT/wt-only.txt"
SNAP_WT_E="$( (cd "$SNAP_WT" && env COMMS_DELIVERY=mailbox "$COMMS" panel dispatch --to codex r.md) 2>&1 >/dev/null )"
printf '%s\n' "$SNAP_WT_E" | grep -q 'wt-only.txt' \
  && ok "a dispatch from a linked worktree reports THAT worktree's dirty paths" \
  || fail "worktree dispatch reported the wrong tree (got: $(printf '%s' "$SNAP_WT_E" | head -3 | tr '\n' ' '))"

section "compose: cross-severity corroboration"
# THE DETECTOR HAD NEVER FIRED. `corroborated` filtered `$13=="blocking"` BEFORE clustering, so a
# defect one reviewer filed blocking and another filed advisory at the SAME anchor contributed one
# row and never reached m>1. Filed 2026-08-27, recurred 2026-09-03 (fwh-platform), confirmed here:
# 8 consecutive warm-acp-mount panels and every panel of 2026-09-02/03 reported 0.
#
# The fixture DISPATCHES A REAL PANEL rather than dropping replies in the archive. compose reads
# the findings-set index and the plan snapshot, so a set that was never dispatched composes to
# nothing at all — and every "does not appear" assertion then passes on empty output. An earlier
# revision of this section did exactly that: 5 assertions failed and the 3 that "passed" were
# vacuous. Control-checked against the pre-fix helper: assertions 2, 4, 7 and 8 below FLIP (they
# fail on the old code); 1, 5 and 6 are regression guards that must stay green in both.
XS="$WORK/xsev"; mkdir -p "$XS"; XS="$(cd "$XS" && pwd -P)"
git -C "$XS" init -q -b main
printf '.comms/\n' > "$XS/.gitignore"; echo subject > "$XS/s.txt"
git -C "$XS" add -A >/dev/null 2>&1
git -C "$XS" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$XS/.comms/to-codex" "$XS/.comms/to-grok" "$XS/.comms/to-claude" "$XS/.comms/archive"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$XS/.comms/config"
run_xs() { (cd "$XS" && env COMMS_DELIVERY=mailbox COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
XS_WS="$(run_xs workspace)"
XS_REQ="$XS/.comms/to-codex/${XS_WS}_2026-08-26T12-00-00_req.md"
cat > "$XS_REQ" <<XSEOF
---
type: review-request
from: claude
timestamp: 2026-08-26T12:00:00Z
head_sha: $(git -C "$XS" rev-parse HEAD)
workspace: $XS_WS
message_id: xs-req-1
thread: xs-thread
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## What was done
cross-severity fixture
XSEOF
run_xs panel dispatch --to codex,grok --set xsev-set "$XS_REQ" >/dev/null 2>&1
XS_LEG_C="$(find "$XS/.comms/to-codex" -name '*panel-codex*' -type f | head -1)"
XS_SET="$(grep -m1 '^review_set:' "$XS_LEG_C" 2>/dev/null | sed 's/^review_set: //')"
[ -n "$XS_SET" ] && ok "the cross-severity fixture dispatched a real set to compose against" \
  || fail "no set dispatched — every assertion below would pass on empty compose output"
xs_reply() { # <agent> <minute> <blocking csv|-> <advisory csv|->
  # TWO statements: bash expands every argument to `local` BEFORE any assignment takes effect,
  # so `f=...${mi}...` on the same line reads an unbound `mi` under `set -u`.
  local ag="$1" mi="$2" bl="$3" ad="$4"
  local leg th rid f a
  leg="$(find "$XS/.comms/to-$ag" -name "*panel-$ag*" -type f | head -1)"
  th="$(grep -m1 '^thread:' "$leg" | sed 's/^thread: //')"
  rid="$(grep -m1 '^message_id:' "$leg" | sed 's/^message_id: //')"
  f="$XS/.comms/archive/${XS_WS}_2026-08-26T12-3${mi}-00_${ag}-reply.md"
  { printf -- '---\ntype: review-feedback\nfrom: %s\ntimestamp: 2026-08-26T12:3%s:00Z\nworkspace: %s\nmessage_id: xsev-%s-reply\nthread: %s\nin-reply-to: %s\nreview_set: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: REQUEST_CHANGES\n---\n\n### Blocking\n' "$ag" "$mi" "$XS_WS" "$ag" "$th" "$rid" "$XS_SET"
    # A leading '~' emits an UNANCHORED finding — no backticked span, so `findings_extract`
    # records an empty anchor. That is the input the `$14!=""` guard exists for.
    [ "$bl" = "-" ] || { IFS=,; for a in $bl; do
        case "$a" in
          '~'*) printf -- '- %s prose blocker with no anchor.\n' "$ag" ;;
          *)    printf -- '- `%s` — %s blocking.\n' "$a" "$ag" ;;
        esac
      done; unset IFS; }
    printf -- '\n### Advisory\n'
    [ "$ad" = "-" ] || { IFS=,; for a in $ad; do printf -- '- `%s` — %s advisory.\n' "$a" "$ag"; done; unset IFS; }
  } > "$f"
}
# gate.txt:1 — both reviewers blocking, and codex ALSO files advisory there. The advisory row must
#   not demote a gated anchor. (Only claude/codex/grok are registerable and claude drives, so two
#   reviewers is the ceiling; this is the 2-reviewer expression of "a third advisory vote must not
#   remove an existing gate".)
# mix.txt:1  — codex blocking, grok advisory -> Mixed. This is the anchor the detector never saw.
# solo.txt:1 — codex alone, blocking -> Uncorroborated.
# adv.txt:1  — both advisory, no blocking vote -> Advisory.
# sub<FS>.txt:1 carries awk's SUBSEP byte (0x1c). `findings_extract` strips tabs but permits
# this one inside a backticked anchor, and an anchor is attacker-adjacent text: it comes from
# whatever the reviewer typed. The classifier must not recover anchors by splitting a composite
# key. (codex, implement r1, blocking — pre-fix this row was DROPPED: 9 findings in, 8 out.)
XS_FS="sub$(printf '\034')b.txt:1"
# Each reviewer also files an UNANCHORED blocker. They are UNRELATED defects and must never
# corroborate each other: without `$14!=""` on the classifier they would both group under the
# empty key and manufacture a gate nobody voted for — a false POSITIVE, which is worse than
# the false negative this whole change fixes. grok blocked plan r1 for dropping that guard,
# and flagged at implement r2 that the guard had no fixture. It has one now.
xs_reply codex 0 "mix.txt:1,gate.txt:1,solo.txt:1,$XS_FS,~c" "gate.txt:1,adv.txt:1"
xs_reply grok  1 "gate.txt:1,~g"                   "mix.txt:1,adv.txt:1"
XSC="$(run_xs compose --set "$XS_SET" 2>&1 || true)"
xs_sec() { printf '%s\n' "$XSC" | awk -v h="$1" 'index($0,h)==1{f=1;next} /^## /{f=0} f'; }
xs_sec '## Gates'          | grep -q 'gate.txt:1' && ok "a gated anchor survives one reviewer also filing advisory there" || fail "the existing gate was lost"
xs_sec '## Flagged by more' | grep -q 'mix.txt:1' && ok "blocking+advisory at one anchor is surfaced, not buried" || fail "cross-severity anchor still invisible"
xs_sec '## Flagged by more' | grep -q 'gate.txt:1' && fail "a gated anchor also appears under mixed" || ok "classification is exclusive — a gated anchor is not also mixed"
xs_sec '## Uncorroborated' | grep -q 'mix.txt:1' && fail "mixed anchor left under the suspicion heading" || ok "a mixed anchor leaves Uncorroborated"
xs_sec '## Uncorroborated' | grep -q 'solo.txt:1' && ok "a lone blocker stays Uncorroborated" || fail "lone blocker misclassified"
xs_sec '## Advisory'       | grep -q 'adv.txt:1' && ok "two advisories with no blocking vote stay Advisory" || fail "advisory-only anchor promoted"
xs_sec '## Advisory'       | grep -q 'gate.txt:1' && fail "a gated anchor's advisory row leaked into Advisory, detached from its anchor" || ok "a gated anchor prints its dissent inside Gates only"
printf '%s\n' "$XSC" | grep -q 'differing severity: 1' && ok "the dashboard counts mixed anchors" || fail "mixed count wrong (got: $(printf '%s\n' "$XSC" | grep -i 'differing severity' | head -1))"
xs_sec '## Uncorroborated' | grep -aq "$XS_FS" && ok "an anchor containing SUBSEP is classified, not truncated" || fail "the SUBSEP anchor lost its class"
# The general invariant the SUBSEP bug violated: composition MOVES findings between sections,
# it never removes one. Counting rendered rows against the parsed finding count catches the
# whole family, not just the one byte that exposed it.
XS_IN="$(printf '%s\n' "$XSC" | sed -n 's/.*all answered\. \([0-9][0-9]*\) findings.*/\1/p' | head -1)"
XS_OUT="$(printf '%s\n' "$XSC" | grep -ac '^- \[' || true)"
[ -n "$XS_IN" ] && [ "$XS_IN" = "$XS_OUT" ] \
  && ok "every parsed finding is rendered somewhere — composition drops nothing ($XS_OUT/$XS_IN)" \
  || fail "composition dropped findings (parsed $XS_IN, rendered $XS_OUT)"
[ "$(xs_sec '## Unanchored' | grep -c '^- \[')" = "2" ] \
  && ok "both unanchored blockers are carried, not discarded" \
  || fail "unanchored blockers lost (got $(xs_sec '## Unanchored' | grep -c '^- \['))"
printf '%s\n' "$XSC" | grep -q 'MORE THAN ONE reviewer: 1' \
  && ok "two UNRELATED unanchored blockers do not manufacture a gate" \
  || fail "the empty anchor clustered — false gate (got: $(printf '%s\n' "$XSC" | grep -i 'MORE THAN ONE' | head -1))"

section "loopspec: conformance fixtures"
if bash "$REPO/docs/loopspec/check.sh" --comms "$COMMS" > "$WORK/loopspec.out" 2>&1; then
  ok "loopspec conformance: $(tail -1 "$WORK/loopspec.out")"
else
  fail "loopspec conformance failed: $(grep '^FAIL' "$WORK/loopspec.out" | head -5 | tr '\n' ' ')"
fi

section "comms.sh v2: clean (guarded, dry-run default) — runs last, deletes fixture"
PRE_COUNT="$(find "$REPO_FIX/.comms/to-claude" "$REPO_FIX/.comms/to-codex" "$REPO_FIX/.comms/archive" -type f | wc -l | tr -d ' ')"
DRY="$(run_comms clean --as claude workspace)"
echo "$DRY" | grep -q "would delete" && ok "clean dry-runs without --yes" || fail "clean dry-run (got: $DRY)"
POST_COUNT="$(find "$REPO_FIX/.comms/to-claude" "$REPO_FIX/.comms/to-codex" "$REPO_FIX/.comms/archive" -type f | wc -l | tr -d ' ')"
[ "$PRE_COUNT" = "$POST_COUNT" ] && ok "dry-run deleted nothing" || fail "dry-run deleted nothing ($PRE_COUNT -> $POST_COUNT)"
run_comms clean --as claude workspace --yes >/dev/null
[ -z "$(find "$REPO_FIX/.comms/to-claude" -name 'feature-helper-tests_*' -type f 2>/dev/null)" ] && ok "clean --yes empties own inbox" || fail "clean --yes empties own inbox"
[ -n "$(find "$REPO_FIX/.comms/to-codex" -name 'feature-helper-tests_*' -type f 2>/dev/null)" ] && ok "clean workspace mode never touches the other inbox" || fail "clean spares other inbox"
run_comms clean --as claude all --yes >/dev/null
[ -z "$(find "$REPO_FIX/.comms/to-codex" -type f 2>/dev/null)" ] && ok "clean all --yes wipes both inboxes" || fail "clean all wipes"

echo ""

section "comms.sh: settings and setup"
# SETTINGS REACH EVERY HELPER WITHOUT THE SHELL RC. Agent tool shells often never read
# ~/.zshrc, so a routing switch exported there silently did nothing (field, 2026-09-22).
# Each case runs the real helpers against its own AGENT_COMMS_HOME and project.
ST_HOME="$WORK/st-home"; ST_PROJ="$WORK/st-proj"; mkdir -p "$ST_HOME" "$ST_PROJ/.comms"
git -C "$ST_PROJ" init -q; git -C "$ST_PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
printf 'agents = claude codex\ndefault-target = codex\nsuite-cmd = bash t.sh\n' > "$ST_PROJ/.comms/config"
st() {  # st [VAR=val...] -- <helper> <args...> : run from the project with an isolated home
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  ( cd "$ST_PROJ" && env -u AC_SETTINGS_LOADED -u COMMS_REVIEW_ROUTE -u COMMS_ROUTE -u COMMS_ROUTE_BACKEND \
      -u COMMS_ACP_CODEX_EFFORT -u TYPESAFE_API_KEY -u COMMS_ACP_CODEX_PATH AGENT_COMMS_HOME="$ST_HOME" ${envs[@]+"${envs[@]}"} "$@" )
}
printf 'COMMS_REVIEW_ROUTE=1\n' > "$ST_HOME/settings"
st -- "$COMMS" review-route enabled >/dev/null 2>&1; A=$?
st COMMS_REVIEW_ROUTE=0 -- "$COMMS" review-route enabled >/dev/null 2>&1; B=$?
[ "$A" = 0 ] && [ "$B" = 1 ] && ok "a user setting applies with no env var, and the environment overrides it" || fail "user settings / env precedence ($A$B)"
printf 'COMMS_REVIEW_ROUTE=0\n' > "$ST_PROJ/.comms/settings"
st -- "$COMMS" review-route enabled >/dev/null 2>&1; A=$?; rm -f "$ST_PROJ/.comms/settings"
[ "$A" = 1 ] && ok "a project .comms/settings value beats the user setting" || fail "project settings precedence"
printf 'COMMS_ROUTE=$(touch %s/st-pwned)\nBOGUS_KEY=1\nCOMMS_REVIEW_ROUTE=1\n' "$WORK" > "$ST_HOME/settings"
ERR="$(st -- "$COMMS" review-route enabled 2>&1 >/dev/null)"
[ ! -e "$WORK/st-pwned" ] && printf '%s' "$ERR" | grep -q "unknown setting 'BOGUS_KEY'" \
  && ok "settings are parsed, never evaluated, and an unknown key is reported and ignored" || fail "settings evaluated or unknown key silent"
printf 'COMMS_ROUTE=0\n' > "$ST_HOME/settings"
[ "$(st -- "$COMMS" route -- 'rename a typo' 2>/dev/null | sed -n 's/^source: //p')" = disabled ] \
  && ok "python-backed helpers see settings too (route: disabled from the settings file)" || fail "route did not see settings"
printf 'COMMS_ACP_CODEX_EFFORT=high\n' > "$ST_HOME/settings"
[ "$(st COMMS_ACP_CODEX_PATH=bundled -- "$REPO/helpers/acp.sh" policy codex 2>/dev/null)" = "$(printf 'gpt-6-astra\thigh')" ] \
  && ok "acp.sh reads settings when run directly (reviewer effort pin)" || fail "acp.sh did not read settings"
: > "$ST_HOME/settings"
# ISOLATION: under the harness env (AC_SETTINGS_LOADED=1) a settings file is never read, so the
# developer's own settings cannot make the corpus machine-dependent.
printf 'COMMS_REVIEW_ROUTE=1\n' > "$ST_HOME/settings"
( cd "$ST_PROJ" && env -u COMMS_REVIEW_ROUTE AGENT_COMMS_HOME="$ST_HOME" "$COMMS" review-route enabled >/dev/null 2>&1 ); A=$?
[ "$A" = 1 ] && ok "the suite's own environment never reads a settings file" || fail "settings leak into the suite"
: > "$ST_HOME/settings"
# PROJECT TRUST: a project file is repository content, so it may tune depth and time but never
# name a binary, lift containment, or switch classification ON. COMMS_ROUTE=0 (opting out) is kept.
printf 'ACPX_BIN=/tmp/evil\nCOMMS_RUNPHASE_ALLOW_UNCONTAINED=1\nCOMMS_ACP_CODEX_PATH=/tmp/evil\nCOMMS_ROUTE_BACKEND=typesafe\nCOMMS_ROUTE=1\nCOMMS_RUNPHASE_TIMEOUT_SECS=77\n' > "$ST_PROJ/.comms/settings"
PSHOW="$(st -- "$COMMS" setup --show 2>&1)"
printf 'COMMS_ROUTE=0\n' > "$ST_PROJ/.comms/settings"
PSHOW0="$(st -- "$COMMS" setup --show 2>&1)"; rm -f "$ST_PROJ/.comms/settings"
N=0; for k in ACPX_BIN COMMS_RUNPHASE_ALLOW_UNCONTAINED COMMS_ACP_CODEX_PATH COMMS_ROUTE_BACKEND COMMS_ROUTE; do
  printf '%s\n' "$PSHOW" | grep -qE "^  $k +\(unset\)" && N=$((N+1)); done
[ "$N" = 5 ] && printf '%s\n' "$PSHOW" | grep -qE '^  COMMS_RUNPHASE_TIMEOUT_SECS +77 ' \
  && printf '%s' "$PSHOW" | grep -q "honoured only in" && printf '%s\n' "$PSHOW0" | grep -qE '^  COMMS_ROUTE +0 ' \
  && ok "a project file cannot set a binary, containment or turn routing on; it can tune time and opt out" || fail "project settings trust ($N/5)"
# PROVENANCE: an environment override is attributed to the environment, not to a file holding the key.
printf 'COMMS_REVIEW_ROUTE=1\n' > "$ST_HOME/settings"
PSHOW="$(st COMMS_REVIEW_ROUTE=0 -- "$COMMS" setup --show 2>&1)"
printf '%s\n' "$PSHOW" | grep -qE '^  COMMS_REVIEW_ROUTE +0 +environment$' \
  && ok "--show attributes an environment override to the environment" || fail "--show provenance"
: > "$ST_HOME/settings"
# GNU stat: `stat -f FMT` is a filesystem query there that prints a dump AND fails. A stub with
# exactly that behaviour must still yield mode 600, or a correct secrets file is refused on Linux.
mkdir -p "$WORK/st-gnu"; printf '#!/bin/sh\ncase "$1" in -c) echo 600 ;; *) echo "  File: \\"$2\\" ID: 0 Namelen: 255"; exit 1 ;; esac\n' > "$WORK/st-gnu/stat"; chmod +x "$WORK/st-gnu/stat"
printf 'TYPESAFE_API_KEY=k-gnu\n' > "$ST_HOME/secrets"; chmod 600 "$ST_HOME/secrets"
PSHOW="$(st PATH="$WORK/st-gnu:$PATH" -- "$COMMS" setup --show 2>&1)"
printf '%s\n' "$PSHOW" | grep -q 'TYPESAFE_API_KEY *(set, 5 chars)' \
  && ok "the secrets mode check works with GNU stat semantics" || fail "GNU stat mode probe"
rm -f "$ST_HOME/secrets"
# SECRETS: loaded only at mode 600.
printf 'TYPESAFE_API_KEY=k-secret\n' > "$ST_HOME/secrets"; chmod 600 "$ST_HOME/secrets"
SHOW600="$(st -- "$COMMS" setup --show 2>&1)"
chmod 644 "$ST_HOME/secrets"; SHOW644="$(st -- "$COMMS" setup --show 2>&1)"
printf '%s' "$SHOW600" | grep -q 'TYPESAFE_API_KEY *(set, 8 chars)' && ! printf '%s' "$SHOW600" | grep -q k-secret \
  && printf '%s' "$SHOW644" | grep -q 'must be 600' && printf '%s' "$SHOW644" | grep -q 'TYPESAFE_API_KEY *(unset)' \
  && ok "the secrets file loads only at mode 600, and --show never prints the key" || fail "secrets mode / masking"
rm -f "$ST_HOME/secrets"
# setup --set: writes, preserves foreign lines, removes on empty, refuses unknown keys.
printf '# mine\nCOMMS_ROUTE_BACKEND=typesafe\nCOMMS_RUNPHASE_TIMEOUT_SECS=900\n' > "$ST_HOME/settings"
st -- "$COMMS" setup --set COMMS_REVIEW_ROUTE=1 --set COMMS_RUNPHASE_TIMEOUT_SECS= >/dev/null 2>&1; A=$?
cp "$ST_HOME/settings" "$WORK/st-before"
st -- "$COMMS" setup --set NOT_A_SETTING=1 >/dev/null 2>&1; B=$?
[ "$A" = 0 ] && [ "$B" = 2 ] && grep -qx '# mine' "$ST_HOME/settings" && grep -qx 'COMMS_ROUTE_BACKEND=typesafe' "$ST_HOME/settings" \
  && grep -qx 'COMMS_REVIEW_ROUTE=1' "$ST_HOME/settings" && ! grep -q TIMEOUT "$ST_HOME/settings" && cmp -s "$WORK/st-before" "$ST_HOME/settings" \
  && ok "setup --set rewrites only the named keys, an empty value removes one, an unknown key is refused unchanged" || fail "setup --set ($A/$B)"
st -- "$COMMS" setup --set TYPESAFE_API_KEY=k2 >/dev/null 2>&1
ls -l "$ST_HOME/secrets" | grep -q '^-rw-------' \
  && grep -qx 'TYPESAFE_API_KEY=k2' "$ST_HOME/secrets" && ! grep -q TYPESAFE "$ST_HOME/settings" \
  && ok "the API key goes only to the 0600 secrets file" || fail "secret written wrongly"
# Replacement matches the loader's key grammar: an indented old assignment (live to the loader,
# which trims the name) is removed, not left ahead of the new one. Other lines survive.
printf '# mine\n  TYPESAFE_API_KEY = old\n' > "$ST_HOME/secrets"; chmod 600 "$ST_HOME/secrets"
st -- "$COMMS" setup --set TYPESAFE_API_KEY=k3 >/dev/null 2>&1
[ "$(grep -c TYPESAFE_API_KEY "$ST_HOME/secrets")" = 1 ] && grep -qx 'TYPESAFE_API_KEY=k3' "$ST_HOME/secrets" && grep -qx '# mine' "$ST_HOME/secrets" \
  && ok "replacing the key removes every live assignment of it and keeps other lines" || fail "old key left live: $(tr '\n' '|' < "$ST_HOME/secrets" | sed 's/k[0-9]*/K/g')"
# An UNREADABLE secrets file is not replaced: the write fails and the file is untouched.
chmod 000 "$ST_HOME/secrets"; st -- "$COMMS" setup --set TYPESAFE_API_KEY=k4 >/dev/null 2>&1; A=$?; chmod 600 "$ST_HOME/secrets"
[ "$A" != 0 ] && grep -qx '# mine' "$ST_HOME/secrets" && grep -qx 'TYPESAFE_API_KEY=k3' "$ST_HOME/secrets" \
  && ok "an unreadable secrets file fails the write instead of being replaced" || fail "unreadable secrets replaced (rc=$A)"
# FRESH PROJECT (no default-target line): the default reviewer is derived, not shell text. This is
# the path a first install takes, and bash 3.2 once turned it into a syntax error written to config.
printf 'agents = claude codex\nsuite-cmd = bash t.sh\n' > "$ST_PROJ/.comms/config"
st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1
grep -qx 'default-target = codex' "$ST_PROJ/.comms/config" && [ "$(grep -c . "$ST_PROJ/.comms/config")" = 3 ] \
  && ok "a fresh project gets a real default reviewer" || fail "fresh default-target: $(tr '\n' '|' < "$ST_PROJ/.comms/config")"
printf 'agents = claude codex\ndefault-target = codex\nsuite-cmd = bash t.sh\n' > "$ST_PROJ/.comms/config"
# An explicit COMMS_ROUTE=0 beside a named backend is OFF; accepting defaults must keep it off.
printf 'COMMS_ROUTE_BACKEND=typesafe\nCOMMS_ROUTE=0\n' > "$ST_HOME/settings"; st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1
OFF_F="$(cat "$ST_HOME/settings")"; : > "$ST_HOME/settings"
! printf '%s' "$OFF_F" | grep -q '^COMMS_ROUTE_BACKEND=typesafe' \
  && ok "setup --yes keeps routing off when the master switch disabled it" || fail "setup --yes re-enabled routing"
# An UNREADABLE settings file is not an absent one: the write fails and the file is untouched.
printf '# keep\nCOMMS_RUNPHASE_TIMEOUT_SECS=900\n' > "$ST_HOME/settings"; chmod 000 "$ST_HOME/settings"
st -- "$COMMS" setup --set COMMS_REVIEW_ROUTE=1 >/dev/null 2>&1; A=$?; chmod 600 "$ST_HOME/settings"
[ "$A" != 0 ] && grep -qx 'COMMS_RUNPHASE_TIMEOUT_SECS=900' "$ST_HOME/settings" \
  && ok "an unreadable settings file fails the write instead of being replaced" || fail "unreadable settings replaced (rc=$A)"
: > "$ST_HOME/settings"
# An unreadable project config is not replaced by just the agent lines: setup fails and it is intact.
chmod 000 "$ST_PROJ/.comms/config"; st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1; A=$?; chmod 644 "$ST_PROJ/.comms/config"
[ "$A" != 0 ] && grep -qx 'suite-cmd = bash t.sh' "$ST_PROJ/.comms/config" \
  && ok "an unreadable project config fails setup instead of losing its other lines" || fail "unreadable config replaced (rc=$A)"
# The master switch follows the routing answer both ways: a stale COMMS_ROUTE in the user file
# would otherwise keep classification ON after "no", or OFF after "yes". --yes takes the current
# state as the answer, so =1 exercises the yes branch and =0 the no branch.
printf 'COMMS_ROUTE=1\n' > "$ST_HOME/settings"; st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1
YES_F="$(cat "$ST_HOME/settings")"
printf 'COMMS_ROUTE=0\nCOMMS_ROUTE_BACKEND=\n' > "$ST_HOME/settings"; st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1
NO_F="$(cat "$ST_HOME/settings")"; : > "$ST_HOME/settings"
! printf '%s' "$YES_F" | grep -q '^COMMS_ROUTE=' && printf '%s' "$YES_F" | grep -qx 'COMMS_ROUTE_BACKEND=typesafe' \
  && ! printf '%s' "$NO_F" | grep -q '^COMMS_ROUTE' \
  && ok "the routing answer owns COMMS_ROUTE: it is cleared on both yes and no" || fail "routing master switch left stale"
# A failed publish is a failure: with the rename refused, --set must not report success.
mkdir -p "$WORK/st-nomv"; printf '#!/bin/sh\nexit 1\n' > "$WORK/st-nomv/mv"; chmod +x "$WORK/st-nomv/mv"
SOUT="$(st PATH="$WORK/st-nomv:$PATH" -- "$COMMS" setup --set COMMS_REVIEW_ROUTE=1 2>&1)"; A=$?
[ "$A" != 0 ] && ! printf '%s' "$SOUT" | grep -q 'wrote' && ! grep -q COMMS_REVIEW_ROUTE "$ST_HOME/settings" \
  && ok "a settings write that cannot be published fails instead of reporting saved" || fail "failed write reported success (rc=$A)"
# The corpus scrubs every settable key it could have inherited (integrate runs it from comms.sh,
# which already exported the operator's settings); only the pinned runtime remains.
N=0; for k in $(sed -n 's/^AC_SETTINGS_KEYS="\(.*\)"$/\1/p' "$REPO/helpers/settings.sh") TYPESAFE_API_KEY; do
  [ "$k" = COMMS_ACP_CODEX_PATH ] && continue; eval "[ -n \"\${$k+x}\" ]" && N=$((N+1)); done
grep -q 'unset \$AC_SETTINGS_KEYS \$AC_SECRET_KEYS' "$REPO/tests/lib/harness.sh" && [ "$N" = 0 ] \
  && ok "the harness scrubs every settable key, from the loader's own list" || fail "inherited settings reach the corpus ($N)"
# setup --yes: no terminal, no prompts, keeps the project's non-agent config.
ST_OUT="$(st -- "$COMMS" setup --yes </dev/null 2>&1)"; A=$?
[ "$A" = 0 ] && grep -qx 'suite-cmd = bash t.sh' "$ST_PROJ/.comms/config" && grep -qx 'agents = claude codex' "$ST_PROJ/.comms/config" \
  && printf '%s' "$ST_OUT" | grep -q '5/5 Codex reviewer runtime' \
  && ok "setup --yes runs every section unattended and keeps unrelated project config" || fail "setup --yes (rc=$A)"
# Wiring: every entry helper loads settings, and the installer ships and offers them.
N=0; for h in comms.sh runphase.sh acp.sh route.sh; do grep -q 'settings.sh" \] && \.' "$REPO/helpers/$h" && N=$((N+1)); done
grep -q '^HELPERS=.*settings\.sh.*setup\.sh' "$REPO/install.sh" && [ "$N" = 4 ] \
  && ok "all four entry helpers load settings, and install.sh ships settings.sh and setup.sh" || fail "settings wiring ($N/4)"
ST_INST="$WORK/st-inst"; mkdir -p "$ST_INST"; git -C "$ST_INST" init -q -b main
# AGENT_COMMS_SETUP is UNSET here: the predicate itself (scripted --scope, stdin not a terminal)
# must decline to prompt even where /dev/tty would open. The alarm turns a regression into a
# failure instead of a hung suite.
INST_OUT="$(cd "$ST_INST" && echo | env -u AGENT_COMMS_SETUP perl -e 'alarm shift; exec @ARGV' 120 bash "$REPO/install.sh" --scope=local 2>&1)"
printf '%s' "$INST_OUT" | grep -q 'next: .*comms.sh setup' && [ -f "$ST_INST/.agent-comms/settings.sh" ] \
  && ok "a non-interactive install points at comms.sh setup instead of prompting" || fail "installer setup hand-off"
