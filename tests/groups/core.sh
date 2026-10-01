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
[ "$RC_RC" -eq 11 ] && printf '%s' "$RC_OUT" | head -1 | grep_full -qx 'verdict: error' && printf '%s' "$RC_OUT" | grep -q 'needs a newer CLI' \
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
[ "$(env -u COMMS_ACP_CODEX_MODEL -u COMMS_ACP_CODEX_EFFORT "$INST_FIX/.agent-comms/acp.sh" policy codex 2>/dev/null)" = "$(printf 'gpt-6.1-sol\txhigh')" ] \
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
ls -A "$GHOME/agent-comms" | grep_full -q '^\.agent-comms-install\.' \
  && fail "install left a temp beside the helpers" || ok "install leaves no temp litter beside the helpers"
ls -A "$GHOME/commands" | grep_full -q '^\.agent-comms-install\.' \
  && fail "install left a temp in the commands dir" || ok "install leaves no temp litter in the commands dir"
ls -A "$INST_FIX/.agent-comms" | grep_full -q '^\.agent-comms-install\.' \
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
ls -A "$GH_GRP/commands" | grep_full -q '^\.agent-comms-install\.' \
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
run_comms state list | grep_full -q 'loop-alpha.*r2/10' && ok "state list summarizes thread" || fail "state list (got: $(run_comms state list))"
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
run_comms stalled 15 | grep_full -q 'STALLED.*loop-alpha' && ok "stalled flags threads awaiting too long" || fail "stalled detection (got: $(run_comms stalled 15))"
run_comms stalled 15 | grep_full -q 'inbox=unread' && ok "stalled distinguishes an unread persisted message" || fail "stalled unread evidence (got: $(run_comms stalled 15))"
check "state complete marks thread done" run_comms state complete loop-alpha
grep -q '"status": "complete"' "$SF" && ok "state complete persists" || fail "state complete persists"
run_comms stalled 15 | grep_full -q 'no stalled' && ok "completed thread is not stalled" || fail "completed thread is not stalled"

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

section "comms.sh: state idle/legacy (idle threads marked with evidence, never closed by age)"
# basis slice 0b / DESIGN "Nothing is closed by age". `idle` reports, `legacy` marks only the ids
# named, each re-judged at marking time, and a later send resumes the thread.
IDL_NOW="$(date +%s)"; IDL_OLD=$(( IDL_NOW - 40 * 86400 ))
IDL_SD="$REPO_FIX/.comms/state"
idl_stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }
idl_state() {  # <thread> <status> <awaiting_since_epoch> <mtime-epoch>
  local f="$IDL_SD/feature-helper-tests_$1.json"
  printf '{\n  "workspace": "feature-helper-tests",\n  "thread": "%s",\n  "workflow": "auto",\n  "phase": "implement",\n  "round": "2",\n  "max_rounds": "10",\n  "loop_rounds": "",\n  "status": "%s",\n  "awaiting_from": "codex",\n  "awaiting_since": "then",\n  "awaiting_since_epoch": "%s",\n  "last_sent": "m-%s",\n  "last_run_dir": "",\n  "last_delivery": "manual"\n}\n' \
    "$1" "$2" "$3" "$1" > "$f"
  touch -t "$(idl_stamp "$4")" "$f"
}
idl_msg() {  # <dir> <thread> <mtime-epoch>
  local f="$REPO_FIX/.comms/$1/feature-helper-tests_idl-$2-$3.md"
  printf -- '---\ntype: review-request\nfrom: claude\nthread: %s\n---\n\nbody\n' "$2" > "$f"
  touch -t "$(idl_stamp "$3")" "$f"
}
idl_status() { json_field_of "$IDL_SD/feature-helper-tests_$1.json" status; }
file_mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
json_field_of() { sed -n 's/.*"'"$2"'": "\([^"]*\)".*/\1/p' "$1" | head -1; }
idl_state idl-quiet in-progress "$IDL_OLD" "$IDL_OLD"
idl_state idl-msg in-progress "$IDL_OLD" "$IDL_OLD"; idl_msg archive idl-msg "$IDL_NOW"
idl_state idl-unread in-progress "$IDL_OLD" "$IDL_OLD"; idl_msg to-codex idl-unread "$IDL_OLD"
idl_state idl-done complete "$IDL_OLD" "$IDL_OLD"
idl_state idl-fresh in-progress "$IDL_NOW" "$IDL_NOW"
idl_state idl-epoch in-progress "$IDL_NOW" "$IDL_OLD"
IDL_BEFORE="$(cd "$IDL_SD" && ls -l *idl-* && cat *idl-*)"
IDL_OUT="$(run_comms state idle --days 30 2>&1)"; IDL_RC=$?
[ "$IDL_RC" = 0 ] && printf '%s\n' "$IDL_OUT" | grep -q '^idle id=feature-helper-tests_idl-quiet idle_days=40 .*status=in-progress awaiting=codex unread=0$' \
  && ok "state idle lists a thread with no state change and no message past N days, with its evidence" || fail "state idle quiet (rc=$IDL_RC): $IDL_OUT"
printf '%s\n' "$IDL_OUT" | grep -q '^idle id=feature-helper-tests_idl-unread .*unread=1$' \
  && ok "an OLD unread message is not activity, and the unread count is part of the evidence" || fail "state idle unread: $IDL_OUT"
! printf '%s\n' "$IDL_OUT" | grep -qE 'idl-(msg|done|fresh|epoch) ' \
  && ok "a recent message, a complete thread, a recent send and a recent send epoch each keep a thread off the list" || fail "state idle over-listed: $IDL_OUT"
[ "$(cd "$IDL_SD" && ls -l *idl-* && cat *idl-*)" = "$IDL_BEFORE" ] \
  && ok "state idle changes nothing (content and mtimes identical)" || fail "state idle wrote something"
IDL_OUT="$(run_comms state idle --days 60 2>&1)"
# Captured first, never piped into grep -q: an early grep exit SIGPIPEs the writer, and under
# pipefail that turns a match into a failure.
! printf '%s\n' "$IDL_OUT" | grep -q 'idl-quiet' \
  && ok "--days is the threshold: a 40-day-idle thread is not listed at 60" || fail "state idle --days 60 listed idl-quiet"
run_comms state idle --days 0 >/dev/null 2>&1; IDL_RC=$?
[ "$IDL_RC" = 2 ] && ok "--days 0 is a usage error" || fail "--days 0 rc=$IDL_RC"
run_comms state legacy >/dev/null 2>&1; IDL_RC=$?
[ "$IDL_RC" = 2 ] && [ "$(idl_status idl-quiet)" = in-progress ] \
  && ok "state legacy with no ids is a usage error and marks nothing (no mark by age alone)" || fail "legacy no ids rc=$IDL_RC"
run_comms state legacy '../state/feature-helper-tests_idl-quiet' >/dev/null 2>&1; IDL_RC=$?
[ "$IDL_RC" = 2 ] && [ "$(idl_status idl-quiet)" = in-progress ] \
  && ok "an id that is not one state file stem is refused before anything is read" || fail "legacy traversal id rc=$IDL_RC"
IDL_OUT="$(run_comms stalled 15 2>&1)"
printf '%s\n' "$IDL_OUT" | grep -q 'thread=idl-quiet ' && ok "before marking, the idle thread shows as stalled" || fail "stalled precondition: $IDL_OUT"
IDL_MT="$(file_mtime_of "$IDL_SD/feature-helper-tests_idl-quiet.json")"
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-quiet 2>&1)"; IDL_RC=$?
IDL_F="$IDL_SD/feature-helper-tests_idl-quiet.json"
[ "$IDL_RC" = 0 ] && [ "$(idl_status idl-quiet)" = legacy ] && [ "$(json_field_of "$IDL_F" awaiting_from)" = none ] \
  && [ "$(json_field_of "$IDL_F" legacy_prior_status)" = in-progress ] && [ "$(json_field_of "$IDL_F" legacy_prior_awaiting)" = codex ] \
  && grep -q '^idle 40d when marked: last state activity .*no message on the thread in the 30 days' <<<"$(json_field_of "$IDL_F" legacy_evidence)" \
  && ok "state legacy marks a named idle thread and writes the evidence and the prior status into it" || fail "legacy mark (rc=$IDL_RC): $IDL_OUT | $(cat "$IDL_F")"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$IDL_F" 2>/dev/null \
  && ok "the marked state file is still valid JSON" || fail "legacy JSON invalid: $(cat "$IDL_F")"
[ "$(file_mtime_of "$IDL_F")" = "$IDL_MT" ] && [ "$(sed -n '$p' "$IDL_F")" = '}' ] && grep -q '"last_delivery"' <<<"$(sed -n 'x;$p' "$IDL_F")" \
  && ok "marking keeps the mtime (not activity) and keeps last_delivery as the final field" || fail "legacy mtime/tail: $(tail -3 "$IDL_F")"
IDL_OUT="$(run_comms stalled 15 2>&1)"; IDL_OUT2="$(run_comms state idle --days 30 2>&1)"
printf '%s\n' "$IDL_OUT" | grep -q 'STALLED' && ! printf '%s\n' "$IDL_OUT" | grep -q 'thread=idl-quiet ' \
  && printf '%s\n' "$IDL_OUT2" | grep -q '^state idle: ' && ! printf '%s\n' "$IDL_OUT2" | grep -q 'idl-quiet' \
  && ok "a legacy thread leaves stalled and the idle report" || fail "legacy still reported"
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-msg 2>&1)"; IDL_RC=$?
[ "$IDL_RC" = 3 ] && [ "$(idl_status idl-msg)" = in-progress ] && printf '%s' "$IDL_OUT" | grep -q 'refused: feature-helper-tests_idl-msg: not idle' \
  && ok "naming a thread with a recent message is refused at marking time and leaves it untouched" || fail "legacy active (rc=$IDL_RC): $IDL_OUT"
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-done 2>&1)"; IDL_RC=$?
[ "$IDL_RC" = 3 ] && [ "$(idl_status idl-done)" = complete ] && printf '%s' "$IDL_OUT" | grep -q 'already complete' \
  && ok "a complete thread is refused, never re-marked" || fail "legacy complete (rc=$IDL_RC): $IDL_OUT"
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-unread feature-helper-tests_idl-fresh 2>&1)"; IDL_RC=$?
[ "$IDL_RC" = 3 ] && [ "$(idl_status idl-unread)" = legacy ] && [ "$(idl_status idl-fresh)" = in-progress ] \
  && ok "per target: the idle id is marked, the active one refused, and the exit says something was refused" || fail "legacy mixed (rc=$IDL_RC): $IDL_OUT"
# More message files than one grep batch (200): the scan must batch without losing a file, and
# the legacy path must judge it too (an IFS-joined batch once read as "could not read").
idl_state idl-many in-progress "$IDL_OLD" "$IDL_OLD"
for IDL_I in $(seq 1 450); do printf -- '---\nthread: idl-many\n---\n' > "$REPO_FIX/.comms/archive/feature-helper-tests_idl-bulk-$IDL_I.md"; done
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-many 2>&1)"; IDL_RC=$?
[ "$IDL_RC" = 3 ] && [ "$(idl_status idl-many)" = in-progress ] && printf '%s' "$IDL_OUT" | grep -q 'refused: feature-helper-tests_idl-many: not idle' \
  && ok "with more message files than one scan batch, recent activity is still seen and judged (not a read failure)" || fail "legacy many (rc=$IDL_RC): $IDL_OUT"
rm -f "$REPO_FIX"/.comms/archive/feature-helper-tests_idl-bulk-*.md
# A thread value with trailing whitespace: `send` keys the state on it verbatim (`idl-sp_`), so the
# scan must read it by the same frontmatter rule or a fresh message goes unseen. (codex, slice0b.)
printf '{\n  "workspace": "feature-helper-tests",\n  "thread": "idl-sp ",\n  "status": "in-progress",\n  "awaiting_from": "codex",\n  "awaiting_since_epoch": "%s",\n  "last_delivery": "manual"\n}\n' "$IDL_OLD" > "$IDL_SD/feature-helper-tests_idl-sp_.json"
touch -t "$(idl_stamp "$IDL_OLD")" "$IDL_SD/feature-helper-tests_idl-sp_.json"
printf -- '---\r\nthread: idl-sp \r\n---\r\n' > "$REPO_FIX/.comms/archive/feature-helper-tests_idl-sp-now.md"
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-sp_ 2>&1)"; IDL_RC=$?
[ "$IDL_RC" = 3 ] && printf '%s' "$IDL_OUT" | grep -q 'refused: feature-helper-tests_idl-sp_: not idle' \
  && grep -q '"status": "in-progress"' "$IDL_SD/feature-helper-tests_idl-sp_.json" \
  && ok "a thread with trailing whitespace (and a CRLF message) still sees its own recent message" || fail "legacy trailing-space (rc=$IDL_RC): $IDL_OUT"
# An unreadable state file is UNKNOWN: its status and send time are evidence nobody can see.
idl_state idl-locked in-progress "$IDL_OLD" "$IDL_OLD"; chmod 000 "$IDL_SD/feature-helper-tests_idl-locked.json"
IDL_OUT2="$(run_comms state idle --days 30 2>&1)"
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-locked 2>&1)"; IDL_RC=$?
chmod 644 "$IDL_SD/feature-helper-tests_idl-locked.json"
[ "$IDL_RC" = 3 ] && ! printf '%s\n' "$IDL_OUT2" | grep -q '^idle id=feature-helper-tests_idl-locked ' \
  && printf '%s\n' "$IDL_OUT2" | grep -q 'feature-helper-tests_idl-locked: last activity unreadable' && [ "$(idl_status idl-locked)" = in-progress ] \
  && ok "an unreadable state file is never listed idle and never marked" || fail "unreadable state (rc=$IDL_RC): $IDL_OUT | $IDL_OUT2"
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-nosuch 2>&1)"; IDL_RC=$?
[ "$IDL_RC" = 3 ] && printf '%s' "$IDL_OUT" | grep -q 'no such thread state' \
  && ok "an unknown id is refused by name" || fail "legacy unknown (rc=$IDL_RC): $IDL_OUT"
# Legacy is not closure: the next send on the thread resumes it as in-progress.
IDL_WF="$REPO_FIX/.comms/to-codex/feature-helper-tests_2026-06-04T13-40-00_idl-resume.md"
sed -e 's/^thread: .*/thread: idl-quiet/' -e 's/^message_id: .*/message_id: feature-helper-tests_2026-06-04T13-40-00_idl-resume/' "$OUT_WF" > "$IDL_WF"
run_comms send --to codex "$IDL_WF" >/dev/null 2>&1
[ "$(idl_status idl-quiet)" = in-progress ] && ! grep -q legacy "$IDL_F" \
  && ok "a later send on a legacy thread resumes it (legacy never blocks a thread)" || fail "legacy resume: $(cat "$IDL_F")"
# Fail closed: a message file that cannot be read is activity nobody can see.
idl_state idl-blind in-progress "$IDL_OLD" "$IDL_OLD"; idl_msg to-codex idl-blind "$IDL_OLD"
IDL_BLIND="$REPO_FIX/.comms/to-codex/feature-helper-tests_idl-idl-blind-$IDL_OLD.md"; chmod 000 "$IDL_BLIND"
run_comms state idle --days 30 >/dev/null 2>&1; IDL_RC=$?
IDL_OUT="$(run_comms state legacy --days 30 feature-helper-tests_idl-blind 2>&1)"; IDL_RC2=$?
chmod 644 "$IDL_BLIND"
[ "$IDL_RC" = 1 ] && [ "$IDL_RC2" = 3 ] && [ "$(idl_status idl-blind)" = in-progress ] \
  && ok "an unreadable message file fails the report and refuses the mark (never idle on partial evidence)" || fail "unreadable msg (idle rc=$IDL_RC legacy rc=$IDL_RC2): $IDL_OUT"
rm -f "$IDL_SD"/feature-helper-tests_idl-*.json "$REPO_FIX"/.comms/*/feature-helper-tests_idl-*.md "$IDL_WF"

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
run_rp release loop-hold | grep_full -q "released" && ok "release lifts the hold" || fail "release output"
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
run_comms stalled 15 | grep_full -q "runner DEAD without a result" && ok "watchdog flags a dead runner with no result" || fail "watchdog dead (got: $(run_comms stalled 15))"
echo '{"status": "completed"}' > "$WD_RUN/result.json"
run_comms stalled 15 | grep_full -q "turn finished: completed" && ok "watchdog reports a finished-but-unread turn" || fail "watchdog finished (got: $(run_comms stalled 15))"
rm -f "$WD_RUN/result.json"
echo "$$" > "$WD_RUN/pid"
run_comms stalled 15 | grep_full -q "runner alive" && ok "watchdog reports a live runner still working" || fail "watchdog alive (got: $(run_comms stalled 15))"
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

section "send/panel dispatch: the artifact is the tree the request names"
# FIELD REPORT 2026-09-25 (severity 3): send run from the PRIMARY for a request whose cwd:/branch:
# named a lane worktree pinned main's HEAD as the artifact and only warned about the workspace —
# the review would have judged the wrong tree. Refused now, before any durable write; the same
# request from the named worktree goes out and pins THAT worktree's HEAD; a request naming no
# tree behaves as before.
RT="$WORK/reqtree"; rm -rf "$RT" "$WORK/reqtree-lane"; mkdir -p "$RT"; RT="$(cd "$RT" && pwd -P)"
git -C "$RT" init -q -b main
printf '.comms/\n' > "$RT/.gitignore"; echo a > "$RT/a.txt"
git -C "$RT" add -A >/dev/null 2>&1
git -C "$RT" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$RT/.comms/to-codex" "$RT/.comms/to-grok" "$RT/.comms/to-claude" "$RT/.comms/archive"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$RT/.comms/config"
git -C "$RT" worktree add -q -b rt-lane "$WORK/reqtree-lane" >/dev/null 2>&1
RT_WT="$(cd "$WORK/reqtree-lane" && pwd -P)"
echo lane > "$RT_WT/lane.txt"
git -C "$RT_WT" add lane.txt >/dev/null 2>&1
git -C "$RT_WT" -c user.email=t@t -c user.name=t commit -q -m lane
RT_MAIN_HEAD="$(git -C "$RT" rev-parse HEAD)"; RT_WT_HEAD="$(git -C "$RT_WT" rev-parse HEAD)"
[ "$RT_MAIN_HEAD" != "$RT_WT_HEAD" ] && ok "fixture: the primary and the lane worktree have different HEADs" \
  || fail "fixture: the two trees share a HEAD, so no assertion below could tell them apart"
RT_W="$(cd "$WORK" && pwd -P)"
rt_fm() { awk -v k="$2:" 'NR > 1 && $0 == "---" { exit } index($0, k) == 1 { sub("^" k "[[:space:]]*", ""); print; exit }' "$1"; }
rt_in() { local d="$1"; shift; (cd "$d" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_DELIVERY=mailbox "$COMMS" "$@"); }
# rt_req <file> <id> [frontmatter lines...] — a fresh loop review-request outside every tree.
rt_req() {
  local f="$1" id="$2"; shift 2
  { printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-09-25T00:00:00Z\n'
    printf 'message_id: rt_%s\nworkspace: reqtree\nthread: rt-%s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n' "$id" "$id"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf -- '---\n\n## Intent\nrequest-tree probe\n'
  } > "$f"
}
# EVERYTHING a send or dispatch could write: the mailbox tree (entries, not only files — a
# created state directory counts), every ref (the snapshot anchors under refs/agent-comms), both
# trees' status, and the request file's own bytes (stamping edits it in place).
rt_fp() { { find "$RT/.comms" | LC_ALL=C sort; find "$RT/.comms" -type f -exec cksum {} + | LC_ALL=C sort
            git -C "$RT" for-each-ref; git -C "$RT" status --porcelain; git -C "$RT_WT" status --porcelain
            cksum "$1"; } 2>&1; }
RT_R1="$RT_W/rt-req-1.md"; rt_req "$RT_R1" one "branch: rt-lane" "cwd: $RT_WT"
RT_FP0="$(rt_fp "$RT_R1")"
RT_E1="$(rt_in "$RT" send --to codex "$RT_R1" 2>&1 >/dev/null)" && RT_RC1=0 || RT_RC1=$?
[ "$RT_RC1" = 1 ] && ok "send from the primary for a request naming the lane worktree is refused (exit 1)" \
  || fail "primary send was not refused (rc=$RT_RC1: $RT_E1)"
[ "$(rt_fp "$RT_R1")" = "$RT_FP0" ] && ok "the refused send wrote nothing: no stamp, no snapshot ref, no mailbox or state entry" \
  || fail "the refused send wrote something: $(diff <(printf '%s\n' "$RT_FP0") <(rt_fp "$RT_R1") | head -5 | tr '\n' ' ')"
grep -qF "$RT_WT" <<<"$RT_E1" && grep -qF "running in: $RT on branch main" <<<"$RT_E1" \
  && ok "the refusal names BOTH trees: the one the request names and the one send runs in" || fail "refusal does not name both trees: $RT_E1"
RT_FIX="$(sed -n 's/^  run it from the named tree:  //p' <<<"$RT_E1")"
[ -n "$RT_FIX" ] && grep -qF "cd $RT_WT" <<<"$RT_FIX" && grep -qF "send --to codex $RT_R1" <<<"$RT_FIX" \
  && ok "the refusal prints the command to run from the named worktree" || fail "no usable remedy command: $RT_E1"
RT_P1="$(rt_in "$RT" panel dispatch --to codex,grok "$RT_R1" 2>&1 >/dev/null)" && RT_PRC1=0 || RT_PRC1=$?
[ "$RT_PRC1" = 2 ] && grep -qF "panel dispatch: refused" <<<"$RT_P1" \
  && ok "panel dispatch from the primary for the same request is refused (exit 2)" || fail "primary dispatch not refused (rc=$RT_PRC1: $RT_P1)"
[ "$(rt_fp "$RT_R1")" = "$RT_FP0" ] && ok "the refused dispatch wrote nothing: no leg, event, index row, attempt marker or ref" \
  || fail "the refused dispatch wrote something: $(diff <(printf '%s\n' "$RT_FP0") <(rt_fp "$RT_R1") | head -5 | tr '\n' ' ')"

# The printed remedy is the real thing: run verbatim, it sends and pins the LANE's HEAD.
RT_FIX_OUT="$(env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_DELIVERY=mailbox bash -c "$RT_FIX" 2>&1)" && RT_FRC=0 || RT_FRC=$?
[ "$RT_FRC" = 0 ] && [ "$(rt_fm "$RT_R1" artifact_id)" = "$RT_WT_HEAD" ] && [ "$(rt_fm "$RT_R1" head_sha)" = "$RT_WT_HEAD" ] \
  && ok "the printed command, run as printed, sends and stamps the lane worktree's HEAD" \
  || fail "remedy run: rc=$RT_FRC aid=$(rt_fm "$RT_R1" artifact_id) want=$RT_WT_HEAD ($RT_FIX_OUT)"
RT_R2="$RT_W/rt-req-2.md"; rt_req "$RT_R2" two "branch: rt-lane" "cwd: $RT_WT/"
RT_P2="$(rt_in "$RT_WT" panel dispatch --to codex,grok "$RT_R2" 2>&1)" && RT_PRC2=0 || RT_PRC2=$?
RT_LEG2="$(grep -l '^thread: rt-two-codex$' "$RT/.comms/to-codex/"*panel-codex* 2>/dev/null | head -1)"
[ "$RT_PRC2" = 0 ] && [ -n "$RT_LEG2" ] && [ "$(rt_fm "$RT_LEG2" artifact_id)" = "$RT_WT_HEAD" ] \
  && ok "panel dispatch from the named worktree fans out and every leg pins the worktree's HEAD" \
  || fail "worktree dispatch: rc=$RT_PRC2 leg=${RT_LEG2:-none} aid=$( [ -z "$RT_LEG2" ] || rt_fm "$RT_LEG2" artifact_id) ($RT_P2)"
RT_R3="$RT_W/rt-req-3.md"; rt_req "$RT_R3" three "cwd: $RT_WT/sub/dir"
mkdir -p "$RT_WT/sub/dir"
rt_in "$RT_WT/sub" send --to codex "$RT_R3" >/dev/null 2>&1 \
  && [ "$(rt_fm "$RT_R3" artifact_id)" = "$RT_WT_HEAD" ] \
  && ok "a cwd: inside the tree, sent from another directory of the SAME tree, is that tree" || fail "subdirectory cwd: was not matched to its tree"

# NO cwd:/branch: — unchanged: sent from the primary it pins the primary, exactly as before.
RT_R4="$RT_W/rt-req-4.md"; rt_req "$RT_R4" four
rt_in "$RT" send --to codex "$RT_R4" >/dev/null 2>&1 && RT_RC4=0 || RT_RC4=$?
[ "$RT_RC4" = 0 ] && [ "$(rt_fm "$RT_R4" artifact_id)" = "$RT_MAIN_HEAD" ] \
  && ok "a request with no cwd:/branch: still sends and pins the tree send runs in" || fail "no-hint request changed behaviour (rc=$RT_RC4)"
RT_R5="$RT_W/rt-req-5.md"; rt_req "$RT_R5" five "branch: main" "cwd: $RT"
rt_in "$RT" send --to codex "$RT_R5" >/dev/null 2>&1 && [ "$(rt_fm "$RT_R5" artifact_id)" = "$RT_MAIN_HEAD" ] \
  && ok "a request naming the primary, sent from the primary, is unchanged" || fail "agreeing request was refused"

# branch: ALONE still names a tree, and the remedy finds the worktree that holds it.
RT_R6="$RT_W/rt-req-6.md"; rt_req "$RT_R6" six "branch: rt-lane"
RT_E6="$(rt_in "$RT" send --to codex "$RT_R6" 2>&1 >/dev/null)" && RT_RC6=0 || RT_RC6=$?
[ "$RT_RC6" = 1 ] && grep -qF "cd $RT_WT &&" <<<"$RT_E6" && [ -z "$(rt_fm "$RT_R6" artifact_id)" ] \
  && ok "branch: alone is enforced, and the remedy names the worktree holding that branch" || fail "branch-only request: rc=$RT_RC6 ($RT_E6)"
# Unverifiable or contradictory hints fail CLOSED, with no remedy that would only be refused again.
RT_R7="$RT_W/rt-req-7.md"; rt_req "$RT_R7" seven "cwd: $WORK/no-such-tree"
RT_E7="$(rt_in "$RT" send --to codex "$RT_R7" 2>&1 >/dev/null)" && RT_RC7=0 || RT_RC7=$?
[ "$RT_RC7" = 1 ] && grep -qF "not inside a git work tree" <<<"$RT_E7" \
  && ok "a cwd: that names no git tree here is refused" || fail "missing cwd: rc=$RT_RC7 ($RT_E7)"
RT_R8="$RT_W/rt-req-8.md"; rt_req "$RT_R8" eight "cwd: $RT_WT" "cwd: $RT"
RT_E8="$(rt_in "$RT_WT" send --to codex "$RT_R8" 2>&1 >/dev/null)" && RT_RC8=0 || RT_RC8=$?
[ "$RT_RC8" = 1 ] && grep -qF "no tree here matches every cwd:/branch: line" <<<"$RT_E8" \
  && ok "a second cwd: line naming another tree is judged too — refused, with no false remedy" || fail "duplicate cwd: rc=$RT_RC8 ($RT_E8)"
RT_R9="$RT_W/rt-req-9.md"; rt_req "$RT_R9" nine "branch: main" "cwd: $RT_WT"
RT_E9="$(rt_in "$RT_WT" send --to codex "$RT_R9" 2>&1 >/dev/null)" && RT_RC9=0 || RT_RC9=$?
[ "$RT_RC9" = 1 ] && grep -qF "no tree here matches" <<<"$RT_E9" \
  && ok "cwd: and branch: that name different trees are refused from either one" || fail "self-contradictory request: rc=$RT_RC9 ($RT_E9)"
# `.` sent from the primary WOULD resolve to the primary; refusing it proves relative paths are
# never resolved against wherever send happens to run.
RT_R10="$RT_W/rt-req-10.md"; rt_req "$RT_R10" ten "cwd: ."
RT_E10="$(rt_in "$RT" send --to codex "$RT_R10" 2>&1 >/dev/null)" && RT_RC10=0 || RT_RC10=$?
[ "$RT_RC10" = 1 ] && grep -qF "is not an absolute path" <<<"$RT_E10" \
  && ok "a relative cwd: is refused rather than resolved against wherever send runs" || fail "relative cwd: rc=$RT_RC10 ($RT_E10)"

section "compose: cross-severity corroboration"
# THE DETECTOR HAD NEVER FIRED. `corroborated` filtered `$13=="blocking"` BEFORE clustering, so a
# defect one reviewer filed blocking and another filed advisory at the SAME anchor contributed one
# row and never reached m>1. Filed 2026-08-27, recurred 2026-09-03 (client-app), confirmed here:
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
xs_sec '## Gates'          | grep_full -q 'gate.txt:1' && ok "a gated anchor survives one reviewer also filing advisory there" || fail "the existing gate was lost"
xs_sec '## Flagged by more' | grep_full -q 'mix.txt:1' && ok "blocking+advisory at one anchor is surfaced, not buried" || fail "cross-severity anchor still invisible"
xs_sec '## Flagged by more' | grep_full -q 'gate.txt:1' && fail "a gated anchor also appears under mixed" || ok "classification is exclusive — a gated anchor is not also mixed"
xs_sec '## Uncorroborated' | grep_full -q 'mix.txt:1' && fail "mixed anchor left under the suspicion heading" || ok "a mixed anchor leaves Uncorroborated"
xs_sec '## Uncorroborated' | grep_full -q 'solo.txt:1' && ok "a lone blocker stays Uncorroborated" || fail "lone blocker misclassified"
xs_sec '## Advisory'       | grep_full -q 'adv.txt:1' && ok "two advisories with no blocking vote stay Advisory" || fail "advisory-only anchor promoted"
xs_sec '## Advisory'       | grep_full -q 'gate.txt:1' && fail "a gated anchor's advisory row leaked into Advisory, detached from its anchor" || ok "a gated anchor prints its dissent inside Gates only"
printf '%s\n' "$XSC" | grep -q 'differing severity: 1' && ok "the dashboard counts mixed anchors" || fail "mixed count wrong (got: $(printf '%s\n' "$XSC" | grep -i 'differing severity' | head -1))"
# Rendered ESCAPED: compose's prose passes through inert_lines, and 0x1C is a line boundary for a
# splitlines() reader, so it prints as the text `\x1C`. Still whole, still under its class.
xs_sec '## Uncorroborated' | grep_full -aqF 'sub\x1Cb.txt:1' && ok "an anchor containing SUBSEP is classified, not truncated" || fail "the SUBSEP anchor lost its class"
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
[ "$(st COMMS_ACP_CODEX_PATH="$HARNESS_CODEX_RUNTIME" -- "$REPO/helpers/acp.sh" policy codex 2>/dev/null)" = "$(printf 'gpt-6.1-sol\thigh')" ] \
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
ls -l "$ST_HOME/secrets" | grep_full -q '^-rw-------' \
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
# A tab-separated current roster is written back in canonical single-space form.
printf 'agents =\tclaude\t codex\ndefault-target = codex\nsuite-cmd = bash t.sh\n' > "$ST_PROJ/.comms/config"
st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1
grep -qx 'agents = claude codex' "$ST_PROJ/.comms/config" && grep -qx 'default-target = codex' "$ST_PROJ/.comms/config" \
  && ok "a whitespace-irregular roster is normalised before it is written back" || fail "roster not normalised: $(tr '\n\t' '|^' < "$ST_PROJ/.comms/config")"
printf 'agents = claude codex\ndefault-target = claude codex\nsuite-cmd = bash t.sh\n' > "$ST_PROJ/.comms/config"
st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1
grep -qx 'default-target = codex' "$ST_PROJ/.comms/config" \
  && ok "a malformed multi-name default-target is replaced, not offered back as the fallback" || fail "multi-name default kept"
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
# THE RUNTIME HINT IS THE RESOLVER'S VERDICT, not a version written in setup: on a codex too old for
# the baseline, setup names the refusal (the minimum comes from the map's pair row) and warns that
# `bundled` refuses every baseline review too. setup.sh itself carries no version or model literal.
ST_OLD="$WORK/st-old-codex"; mkdir -p "$ST_OLD"; printf '#!/bin/sh\necho "codex-cli 0.155.1"\n' > "$ST_OLD/codex"; chmod +x "$ST_OLD/codex"
ST_BMIN="$(awk -F'\t' '$1=="pair" && $2=="codex" && $3=="acp-mounted" && $4=="gpt-6.1-sol"{print $6}' "$REPO/helpers/policy-map.tsv")"
ST_OUT="$(st PATH="$ST_OLD:$PATH" -- "$COMMS" setup --yes </dev/null 2>&1)"; A=$?
# A refused (model, effort) PAIR is not a runtime problem: the bundled note must not relabel it as
# "needs codex >= -" or advise a newer codex, since no runtime serves luna at ultra.
ST_PAIR="$(st PATH="$ST_OLD:$PATH" COMMS_ACP_CODEX_MODEL=gpt-5.6-luna COMMS_ACP_CODEX_EFFORT=ultra -- "$COMMS" setup --yes </dev/null 2>&1)"
[ "$A" = 0 ] && [ -n "$ST_BMIN" ] && printf '%s\n' "$ST_OUT" | grep -qF "auto-detected: $ST_OLD/codex (0.155.1)" \
  && ! printf '%s\n' "$ST_PAIR" | grep -qF 'needs codex >= -' \
  && ! printf '%s\n' "$ST_PAIR" | grep -qF "note: choosing 'bundled'" \
  && printf '%s\n' "$ST_PAIR" | grep -qF "does not accept effort 'ultra'" \
  && printf '%s\n' "$ST_OUT" | grep -qF "every default codex review is REFUSED: model 'gpt-6.1-sol' (baseline) needs codex >= $ST_BMIN" \
  && printf '%s\n' "$ST_OUT" | grep -qF "note: choosing 'bundled' refuses every baseline codex review (gpt-6.1-sol needs codex >= $ST_BMIN" \
  && ! printf '%s\n' "$ST_OUT" | grep -q 'falls back to GPT' \
  && ! grep -qE '[0-9]+\.[0-9]+\.[0-9]+|codex >= [0-9]|gpt-[0-9]' "$REPO/helpers/setup.sh" \
  && ok "setup names the baseline's runtime refusal and the bundled warning from the map, with no version of its own" \
  || fail "setup runtime hint (rc=$A: $(printf '%s\n' "$ST_OUT" | sed -n '/5\/5/,/^$/p' | tr '\n' ' '))"
# THE SELECTED RUNTIME IS CHECKED, not just auto-detection: with a current codex on PATH, an explicit
# path kept from an earlier setup that is too old gets the minimum-version refusal (and a current
# explicit path gets the can-run line), because what is saved is what will run.
ST_NEW="$WORK/st-new-codex"; mkdir -p "$ST_NEW"; printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$ST_NEW/codex"; chmod +x "$ST_NEW/codex"
printf 'COMMS_ACP_CODEX_PATH=%s\n' "$ST_OLD/codex" > "$ST_HOME/settings"
ST_OUT="$(st PATH="$ST_NEW:$PATH" -- "$COMMS" setup --yes </dev/null 2>&1)"; A=$?
printf 'COMMS_ACP_CODEX_PATH=%s\n' "$ST_NEW/codex" > "$ST_HOME/settings"
ST_OUT2="$(st PATH="$ST_OLD:$PATH" -- "$COMMS" setup --yes </dev/null 2>&1)"; B=$?
: > "$ST_HOME/settings"
[ "$A" = 0 ] && [ "$B" = 0 ] && printf '%s\n' "$ST_OUT" | grep -qF "auto-detected: $ST_NEW/codex (9.9.9)" \
  && printf '%s\n' "$ST_OUT" | grep -qF "selected: $ST_OLD/codex (0.155.1)" \
  && printf '%s\n' "$ST_OUT" | grep -qF "on the selected runtime, every default codex review is REFUSED: model 'gpt-6.1-sol' (baseline) needs codex >= $ST_BMIN" \
  && printf '%s\n' "$ST_OUT2" | grep -qF "selected: $ST_NEW/codex (9.9.9)" \
  && printf '%s\n' "$ST_OUT2" | grep -qF "the selected runtime can run the default codex review" \
  && ! printf '%s\n' "$ST_OUT2" | grep -qF "on the selected runtime" \
  && ok "setup checks the SELECTED runtime: a retained explicit old path is refused with the minimum, a current one is not" \
  || fail "setup selected-runtime check (rc=$A/$B: $(printf '%s\n' "$ST_OUT" | sed -n '/5\/5/,/^$/p' | tr '\n' ' '))"
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

section "review twins: setup accepts one driver and asks about its provider"
# CONTAINMENT IS A PROPERTY OF THE PROVIDER. Every driver X has a built-in review twin X-review
# that runs on X, so a grok review turn exists exactly when grok is on the agents line: setup
# asks the grok question iff grok is a driver, and no config key can add a grok reviewer beside
# it. A `review-agents` line left over from before twins is an unknown line: setup keeps it (it
# keeps every line it does not own), and the registry warns about it and registers nothing.
# Under --yes nothing is PROMPTED, so the question is observed by its ANSWER: the current value
# is the default, and answering writes it back in canonical form. A hand-written `yes` becomes
# `1` only if the question ran; the branch that skips it never touches the key. Same fixture and
# driver (`st`) as the section above.
rs_setup() { # <agents value> [extra config line] -> setup's output, then "rc=N"
  { printf 'agents = %s\n' "$1"
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    printf 'suite-cmd = bash t.sh\n'; } > "$ST_PROJ/.comms/config"
  printf 'COMMS_RUNPHASE_ALLOW_UNCONTAINED=yes\n' > "$ST_HOME/settings"
  st -- "$COMMS" setup --yes </dev/null 2>&1; printf 'rc=%s\n' "$?"
}
rs_asked() { # <setup output> — 0 when step 3 ran AND asked the grok question
  printf '%s\n' "$1" | grep -qx 'rc=0' && printf '%s\n' "$1" | grep -q '3/5 Reviewer containment' \
    && ! printf '%s\n' "$1" | grep -q 'grok is not registered here' \
    && grep -qx 'COMMS_RUNPHASE_ALLOW_UNCONTAINED=1' "$ST_HOME/settings"
}
rs_skipped() { # <setup output> — 0 when step 3 ran and said there is nothing to allow
  printf '%s\n' "$1" | grep -qx 'rc=0' && printf '%s\n' "$1" | grep -q 'grok is not registered here' \
    && grep -qx 'COMMS_RUNPHASE_ALLOW_UNCONTAINED=yes' "$ST_HOME/settings"
}
# Every refusal of the agents answer ends "— keeping: <current>". A refusal KEEPS the current
# line, so "the line still says X" alone cannot tell acceptance from rejection; this is.
rs_refused() { printf '%s\n' "$1" | grep -qF -- '— keeping:'; }
rs_reg() { (cd "$ST_PROJ" && "$COMMS" agents "$@") 2>/dev/null; }  # the registry, read from what setup published
RS_OUT="$(rs_setup 'claude codex')"
rs_skipped "$RS_OUT" \
  && ok "control: with no grok driver, setup says so and leaves the containment key untouched" \
  || fail "no-grok control (settings: $(tr '\n' '|' < "$ST_HOME/settings"); out: $(printf '%s' "$RS_OUT" | grep -m1 -i 'grok is\|rc='))"
RS_OUT="$(rs_setup 'claude codex grok')"
rs_asked "$RS_OUT" && [ "$(rs_reg --provider grok-review)" = grok ] \
  && ok "grok on the agents line makes setup ask the grok question, and its twin grok-review runs on grok" \
  || fail "grok driver not asked (settings: $(tr '\n' '|' < "$ST_HOME/settings"); out: $(printf '%s' "$RS_OUT" | grep -m1 -i 'grok is\|rc='); grok-review on: '$(rs_reg --provider grok-review)')"
# A lone grok: its only reviewer is grok-review, a grok turn, so the question matters most here.
RS_OUT="$(rs_setup grok)"
rs_asked "$RS_OUT" && ! rs_refused "$RS_OUT" && grep -qx 'agents = grok' "$ST_PROJ/.comms/config" \
  && [ "$(rs_reg --others grok)" = grok-review ] \
  && ok "a lone grok driver is accepted and asked about: its only reviewer, grok-review, is a grok turn" \
  || fail "lone grok (refusal: '$(printf '%s' "$RS_OUT" | grep -m1 -- '— keeping:')'; settings: $(tr '\n' '|' < "$ST_HOME/settings"); others: '$(rs_reg --others grok)')"
# Irregular spacing on purpose: setup re-renders the agents line, so only a line it does NOT
# re-render can prove it was kept byte-for-byte rather than rewritten into an equal form. The
# line names grok as a provider and remaps claude-review to codex; before twins both counted.
RS_LINE='review-agents =  grok-review:grok   claude-review:codex'
RS_OUT="$(rs_setup 'claude codex' "$RS_LINE")"
rs_skipped "$RS_OUT" \
  && ok "a leftover review-agents line naming grok does not make setup ask the grok question" \
  || fail "leftover review-agents drove the containment question (settings: $(tr '\n' '|' < "$ST_HOME/settings"); out: $(printf '%s' "$RS_OUT" | grep -m1 -i 'grok is\|rc='))"
# Re-run over the config the previous run PUBLISHED, not a freshly seeded one.
st -- "$COMMS" setup --yes </dev/null >/dev/null 2>&1; A=$?
[ "$A" = 0 ] && [ "$(grep -cxF "$RS_LINE" "$ST_PROJ/.comms/config")" = 1 ] \
  && [ "$(grep -c 'review-agents' "$ST_PROJ/.comms/config")" = 1 ] \
  && ok "re-running setup keeps a leftover review-agents line byte-for-byte, exactly once" \
  || fail "review-agents line not preserved (rc=$A): $(tr '\n' '|' < "$ST_PROJ/.comms/config")"
# ...and the kept line registers NOTHING: the registry names it as an unknown line, the twins are
# the drivers' own (no grok-review without a grok driver; the positive control is the grok case
# above), and claude-review still runs on claude, not the codex the line claimed.
RS_WARN="$( (cd "$ST_PROJ" && "$COMMS" agents) 2>&1 >/dev/null)"
RS_GR="$( (cd "$ST_PROJ" && "$COMMS" agents --provider grok-review) 2>&1)"; RS_GRC=$?
[ "$(rs_reg)" = "claude codex claude-review codex-review" ] && [ "$(rs_reg --provider claude-review)" = claude ] \
  && [ "$RS_GRC" = 1 ] && printf '%s\n' "$RS_GR" | grep -qF "unknown agent 'grok-review'" \
  && printf '%s\n' "$RS_WARN" | grep -qxF "warning: config: unknown line: $RS_LINE" \
  && ok "the kept review-agents line is warned about as unknown and registers no identity or remap" \
  || fail "leftover review-agents registered something: agents='$(rs_reg)' claude-review on '$(rs_reg --provider claude-review)' grok-review rc=$RS_GRC warn='$(printf '%s' "$RS_WARN" | head -1)'"
# ONE DRIVER IS ENOUGH: its twin is its reviewer, so setup must not refuse it, and its default
# panel is that twin. The refusal marker must be ABSENT here and PRESENT in the control below.
RS_OUT="$(rs_setup claude)"
printf '%s\n' "$RS_OUT" | grep -qx 'rc=0' && ! rs_refused "$RS_OUT" && ! printf '%s\n' "$RS_OUT" | grep -q 'at least' \
  && grep -qx 'agents = claude' "$ST_PROJ/.comms/config" && [ "$(rs_reg --others claude)" = claude-review ] \
  && ok "setup ACCEPTS a single driver, and its default panel is that driver's own twin" \
  || fail "single driver: refusal='$(printf '%s' "$RS_OUT" | grep -m1 -- '— keeping:\|at least')' config='$(tr '\n' '|' < "$ST_PROJ/.comms/config")' others='$( (cd "$ST_PROJ" && "$COMMS" agents --others claude) 2>&1 | head -1)'"
# Control: an unsupported agents answer is still refused. A twin's name is the pointed case —
# twins are built in, so one can never be registered on the agents line.
RS_OUT="$(rs_setup claude-review)"
rs_refused "$RS_OUT" && printf '%s\n' "$RS_OUT" | grep -qF "'claude-review' is not a supported agent" \
  && ok "control: an unsupported agents answer (a twin's name) is still refused" \
  || fail "twin name accepted on the agents line (out: $(printf '%s' "$RS_OUT" | grep -m1 -i 'agent'))"
# Leave the shared fixture as the section above left it.
printf 'agents = claude codex\ndefault-target = codex\nsuite-cmd = bash t.sh\n' > "$ST_PROJ/.comms/config"
: > "$ST_HOME/settings"

section "integrate: driver contract (classified exit codes + one result line)"
# A driver that lands work unattended must tell "retry later" from "rebase" from "fix the
# repo" without parsing prose. Every refusal class gets its own exit code, and a landing
# prints exactly one machine-readable line. Self-contained fixture; the primary checkout
# sits on a session branch so main is unoccupied except where a test occupies it.
IX="$WORK/integrate-rc"; mkdir -p "$IX"; IX="$(cd "$IX" && pwd -P)"
git -C "$IX" init -q -b main
printf '.comms/\n.claude/worktrees/\n' > "$IX/.gitignore"
echo base > "$IX/a.txt"
printf '#!/bin/bash\ntest -f a.txt\n' > "$IX/suite.sh"
git -C "$IX" add -A >/dev/null 2>&1
git -C "$IX" -c user.email=t@t -c user.name=t commit -qm init
git -C "$IX" checkout -q -b session-primary
mkdir -p "$IX/.comms"; printf 'suite-cmd = bash ./suite.sh\n' > "$IX/.comms/config"
ix() { (cd "$IX" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE COMMS_PRESENCE_TTL_SECS=60 "$COMMS" "$@"); }
ix_rc() { local rc=0; ix "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
ix_main() { git -C "$IX" rev-parse refs/heads/main; }
ix_br() { # <branch> <base> <path> <content> — one commit on a new branch, primary left on session-primary
  git -C "$IX" checkout -q -b "$1" "$2" \
    && printf '%s' "$4" > "$IX/$3" && git -C "$IX" add "$3" \
    && git -C "$IX" -c user.email=t@t -c user.name=t commit -qm "$1"
  git -C "$IX" checkout -q session-primary
}

# Landing: exit 0 and exactly one result line, AFTER the human LANDED line.
IX_M0="$(ix_main)"
ix_br land1 main b.txt $'one\n'; IX_C1="$(git -C "$IX" rev-parse land1)"
IX_OUT="$(ix integrate land1 2>/dev/null)"; IX_RC=$?
[ "$IX_RC" = 0 ] && [ "$(ix_main)" = "$IX_C1" ] \
  && ok "integrate exits 0 when it lands the candidate" || fail "landing rc=$IX_RC"
[ "$(printf '%s\n' "$IX_OUT" | grep -c '^integrate-result ')" = 1 ] \
  && [ "$(printf '%s\n' "$IX_OUT" | tail -1)" = "integrate-result v1 status=landed cand=$IX_C1 main_before=$IX_M0 main_after=$IX_C1 branch=land1 suite=ran" ] \
  && printf '%s\n' "$IX_OUT" | grep -q '^integrate: LANDED ' \
  && ok "a landing prints exactly one result line, last, naming the OIDs and suite=ran" \
  || fail "result line: $(printf '%s\n' "$IX_OUT" | grep 'integrate-result' | head -2)"
IX_M1="$(ix_main)"; ix_br docs1 main README.md $'# readme\n'; IX_D1="$(git -C "$IX" rev-parse docs1)"
IX_OUT="$(ix integrate docs1 2>/dev/null)"
printf '%s\n' "$IX_OUT" | grep -qx "integrate-result v1 status=landed cand=$IX_D1 main_before=$IX_M1 main_after=$IX_D1 branch=docs1 suite=skipped-docs" \
  && ok "a prose-only landing reports suite=skipped-docs" || fail "docs result line: $(printf '%s\n' "$IX_OUT" | grep 'integrate-result')"
printf 'suite-cmd = bash ./suite.sh\nsuite-attest-secs = 600\n' > "$IX/.comms/config"
ix_br att1 main c.txt $'c\n'
mkdir -p "$IX/.comms/cache"
printf '%s %s 0\n' "$(git -C "$IX" rev-parse att1)" "$(date +%s)" >> "$IX/.comms/cache/suite-attest.log"
IX_OUT="$(ix integrate att1 2>/dev/null)"
printf '%s\n' "$IX_OUT" | grep -qE '^integrate-result v1 status=landed cand=[0-9a-f]{40} main_before=[0-9a-f]{40} main_after=[0-9a-f]{40} branch=att1 suite=attested$' \
  && ok "an attested landing reports suite=attested" || fail "attested result line: $(printf '%s\n' "$IX_OUT" | grep 'integrate-result')"
printf 'suite-cmd = bash ./suite.sh\n' > "$IX/.comms/config"
# A branch argument is escaped so the line stays whitespace-free key=value pairs.
ix_br "feat-é" main g.txt $'g\n'
IX_OUT="$(ix integrate "feat-é" 2>/dev/null)"
printf '%s\n' "$IX_OUT" | grep -q '^integrate-result v1 .* branch=feat-%C3%A9 suite=ran$' \
  && ok "a non-ASCII branch is %-escaped in the result line" || fail "escaped branch: $(printf '%s\n' "$IX_OUT" | grep 'integrate-result')"

# Refusals: one class, one code. Each uses a candidate only that class can refuse.
IX_U1="$(ix_rc integrate)"; IX_U2="$(ix_rc integrate no-such-branch)"
[ "$IX_U1" = 2 ] && [ "$IX_U2" = 2 ] \
  && ok "usage errors exit 2 (no branch, unresolvable branch)" || fail "usage rc: missing=$IX_U1 unresolvable=$IX_U2"
ix_br cfg1 main d.txt $'d\n'
: > "$IX/.comms/config"; IX_R_EMPTY="$(ix_rc integrate cfg1)"
printf 'suite-cmd = bash ./suite.sh\nsuite-cmd = true\n' > "$IX/.comms/config"; IX_R_DUP="$(ix_rc integrate cfg1)"
printf 'suite-cmd = bash ./suite.sh\n' > "$IX/.comms/config"
[ "$IX_R_EMPTY" = 10 ] && [ "$IX_R_DUP" = 10 ] \
  && ok "a missing or duplicate suite-cmd exits 10 (configuration)" || fail "config rc: empty=$IX_R_EMPTY dup=$IX_R_DUP"
IX_LC="$(ix presence claim --name landlord --role landing --state integrating 2>/dev/null)"
IX_LI="$(printf '%s' "$IX_LC" | sed -n 's/.*instance: //p')"
IX_R_LEASE="$(ix_rc integrate cfg1)"
ix presence release --name landlord --instance "$IX_LI" >/dev/null 2>&1
[ "$IX_R_LEASE" = 11 ] && ok "a live integrating lease exits 11 (retry later)" || fail "lease rc=$IX_R_LEASE"
ix_br stale1 "$IX_M0" e.txt $'e\n'
IX_R_FF="$(ix_rc integrate stale1)"
[ "$IX_R_FF" = 12 ] && ok "a non-descendant candidate exits 12 (rebase first)" || fail "non-ff rc=$IX_R_FF"
git -C "$IX" checkout -q main && echo dirty >> "$IX/a.txt"
IX_R_OCC="$(ix_rc integrate cfg1)"
git -C "$IX" checkout -q -- a.txt && git -C "$IX" checkout -q session-primary
[ "$IX_R_OCC" = 13 ] && ok "a dirty main occupant exits 13 (main occupied)" || fail "occupied rc=$IX_R_OCC"
ix_br red1 main suite.sh $'#!/bin/bash\nexit 1\n'
IX_MR="$(ix_main)"; IX_OUT_RED="$(ix integrate red1 2>/dev/null)"; IX_R_RED=$?
[ "$IX_R_RED" = 14 ] && [ "$(ix_main)" = "$IX_MR" ] && ! printf '%s\n' "$IX_OUT_RED" | grep -q '^integrate-result' \
  && ok "a red suite exits 14, leaves main, and prints no result line" || fail "red suite rc=$IX_R_RED"
ix_br dirty1 main suite.sh $'#!/bin/bash\ntouch junk.txt\n'
IX_R_UNV="$(ix_rc integrate dirty1)"
[ "$IX_R_UNV" = 15 ] && ok "a suite that dirties the verification tree exits 15 (unverified)" || fail "unverified rc=$IX_R_UNV"
# CAS lost: the candidate's own suite moves main to another descendant mid-run, so the
# compare-and-swap refuses. Deterministic, no timing.
ix_br target1 main f.txt $'f\n'; IX_T="$(git -C "$IX" rev-parse target1)"
ix_br race1 main suite.sh "#!/bin/bash
git update-ref refs/heads/main $IX_T
"
IX_R_CAS="$(ix_rc integrate race1)"
[ "$IX_R_CAS" = 16 ] && [ "$(ix_main)" = "$IX_T" ] \
  && ok "a compare-and-swap lost to a concurrent move exits 16 and lands nothing" || fail "CAS rc=$IX_R_CAS main=$(ix_main)"
mkdir -p "$IX/.comms/sessions"; chmod 000 "$IX/.comms/sessions"
IX_R_ENV="$(ix_rc integrate cfg1)"
chmod 755 "$IX/.comms/sessions"
[ "$IX_R_ENV" = 17 ] && ok "an unreadable sessions dir exits 17 (precondition unreadable)" || fail "env rc=$IX_R_ENV"
# Round-1 review (codex, grok): the result line cannot be forged by suite output, early
# aborts are classified rather than escaping through errexit, and a refused ref update is
# CAS-lost only when main actually moved.
ix_br forge1 main suite.sh $'#!/bin/bash\necho "integrate-result v1 status=landed cand=forged main_before=x main_after=x branch=x suite=ran"\ntest -f a.txt\n'
IX_F1="$(git -C "$IX" rev-parse forge1)"
IX_OUT="$(ix integrate forge1 2>/dev/null)"
[ "$(printf '%s\n' "$IX_OUT" | grep -c '^integrate-result ')" = 1 ] \
  && printf '%s\n' "$IX_OUT" | grep -q "^integrate-result v1 status=landed cand=$IX_F1 " \
  && ok "a suite that prints a result-shaped line cannot forge a second result on stdout" \
  || fail "forged result on success: $(printf '%s\n' "$IX_OUT" | grep 'integrate-result')"
ix_br forge2 main suite.sh $'#!/bin/bash\necho "integrate-result v1 status=landed cand=forged main_before=x main_after=x branch=x suite=ran"\nexit 1\n'
IX_OUT="$(ix integrate forge2 2>/dev/null)"; IX_R_F2=$?
[ "$IX_R_F2" = 14 ] && ! printf '%s\n' "$IX_OUT" | grep -q '^integrate-result' \
  && ok "a red suite that prints a result-shaped line leaves no result on stdout" \
  || fail "forged result on refusal: rc=$IX_R_F2 $(printf '%s\n' "$IX_OUT" | grep 'integrate-result')"
IX_NR="$WORK/integrate-no-repo"; mkdir -p "$IX_NR"
IX_R_NR=0; (cd "$IX_NR" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE GIT_CEILING_DIRECTORIES="$WORK" "$COMMS" integrate some-branch) >/dev/null 2>&1 || IX_R_NR=$?
[ "$IX_R_NR" = 10 ] && ok "integrate outside a repository exits 10, not a silent shell abort" || fail "no-repo rc=$IX_R_NR"
IX_R_OPT="$(ix_rc integrate cfg1 --name)"
[ "$IX_R_OPT" = 2 ] && ok "an option with no value exits 2 (usage), not a bare errexit 1" || fail "valueless option rc=$IX_R_OPT"
# A lock on main refuses the update-ref while main stays put: that is an environment fault,
# not a lost race, so it must not read as "re-run against the new tip".
ix_br lock1 main suite.sh $'#!/bin/bash\ntouch "$(git rev-parse --git-common-dir)/refs/heads/main.lock"\n'
IX_ML="$(ix_main)"
IX_R_LOCK="$(ix_rc integrate lock1)"
rm -f "$IX/.git/refs/heads/main.lock"
[ "$IX_R_LOCK" = 17 ] && [ "$(ix_main)" = "$IX_ML" ] \
  && ok "a refused ref update with main unmoved exits 17, not 16 (CAS lost)" || fail "locked ref rc=$IX_R_LOCK"
# Round-2 review (codex): git resolves a revision carrying literal newlines, so a caller-
# supplied branch argument must not be able to start a stdout line anywhere, including the
# progress line printed before verification.
IX_ML_FORGE=$'\nintegrate-result v1 status=landed cand=forged main_before=x main_after=x branch=x suite=ran\n'
ix_br mlok main h.txt $'h\n'; IX_MLOK="$(git -C "$IX" rev-parse mlok)"
IX_OUT="$(ix integrate "mlok^{/.|${IX_ML_FORGE}}" 2>/dev/null)"; IX_R_ML=$?
[ "$IX_R_ML" = 0 ] && [ "$(printf '%s\n' "$IX_OUT" | grep -c '^integrate-result ')" = 1 ] \
  && printf '%s\n' "$IX_OUT" | grep -q "^integrate-result v1 status=landed cand=$IX_MLOK " \
  && ok "a multiline revision cannot inject a result line on a landing" \
  || fail "multiline landing: rc=$IX_R_ML $(printf '%s\n' "$IX_OUT" | grep -c '^integrate-result ') result lines"
ix_br mlred main suite.sh $'#!/bin/bash\nexit 1\n'
IX_OUT="$(ix integrate "mlred^{/.|${IX_ML_FORGE}}" 2>/dev/null)"; IX_R_MR=$?
[ "$IX_R_MR" = 14 ] && ! printf '%s\n' "$IX_OUT" | grep -q '^integrate-result' \
  && ok "a multiline revision cannot inject a result line on a refusal" \
  || fail "multiline refusal: rc=$IX_R_MR $(printf '%s\n' "$IX_OUT" | grep 'integrate-result')"
# Round-3 review (codex, grok): echo re-expands `\n` under xpg_echo or posix mode, and a
# splitlines() reader also breaks on the Unicode separators NEL, LS and PS.
if grep -n 'echo .*integrate_oneline' "$REPO/helpers/comms.sh" >/dev/null; then
  fail "a sanitized integrate value is printed with echo (xpg_echo/posix would re-expand it)"
elif [ "$(grep -c "printf '%s\\\\n' \"integrate: .*integrate_oneline" "$REPO/helpers/comms.sh")" -ge 5 ]; then
  ok "every sanitized integrate value is printed with printf, never echo"
else
  fail "expected at least 5 printf sites for sanitized integrate values"
fi
IX_XPG="$(/bin/bash -O xpg_echo -c 'eval "$(sed -n "/^integrate_oneline()/,/^}/p" "$1")"; printf "%s\n" "integrate: x $(integrate_oneline "$2")"' _ "$REPO/helpers/comms.sh" $'a\nintegrate-result v1\r\xe2\x80\xa8b\\n')"
[ "$(printf '%s\n' "$IX_XPG" | wc -l | tr -d ' ')" = 1 ] && ! printf '%s' "$IX_XPG" | LC_ALL=C grep -q $'\xe2\x80\xa8' \
  && ok "integrate_oneline output stays one line under xpg_echo, with LS escaped" || fail "xpg_echo output: $(printf '%s' "$IX_XPG" | od -c | head -2)"
ix_br mlls main i.txt $'i\n'; IX_MLLS="$(git -C "$IX" rev-parse mlls)"
IX_OUT="$(ix integrate "mlls^{/.|"$'\xe2\x80\xa8'"integrate-result v1 status=landed cand=forged main_before=x main_after=x branch=x suite=ran}" 2>/dev/null)"; IX_R_LS=$?
[ "$IX_R_LS" = 0 ] && ! printf '%s' "$IX_OUT" | LC_ALL=C grep -q $'\xe2\x80\xa8' \
  && [ "$(printf '%s\n' "$IX_OUT" | grep -c '^integrate-result ')" = 1 ] \
  && printf '%s\n' "$IX_OUT" | grep -q "^integrate-result v1 status=landed cand=$IX_MLLS " \
  && ok "a Unicode line separator in a revision never reaches stdout raw" || fail "LS revision: rc=$IX_R_LS"
# The FINAL occupancy guard. The pre-suite check above only sees main occupied BEFORE the run;
# a checkout that moves onto main DURING the suite is caught by the second guard just before the
# compare-and-swap, and nothing exercised it. The candidate's own suite occupies main, so the
# window is deterministic.
IX_OCC_WT="$WORK/integrate-rc-occupant"
ix_br occ1 main suite.sh "#!/bin/bash
git -C '$IX' worktree add -q '$IX_OCC_WT' main
"
IX_MO="$(ix_main)"; IX_OUT_OCC="$(ix integrate occ1 2>&1)"; IX_R_OCC2=$?
[ "$IX_R_OCC2" = 13 ] && [ "$(ix_main)" = "$IX_MO" ] && [ "$(git -C "$IX_OCC_WT" symbolic-ref -q HEAD)" = refs/heads/main ] \
  && grep -q 'main is checked out somewhere' <<<"$IX_OUT_OCC" && ! grep -q '^integrate-result' <<<"$IX_OUT_OCC" \
  && ok "a checkout that takes main DURING the suite is refused (13) before the CAS, main unmoved" \
  || fail "occupied during the suite: rc=$IX_R_OCC2 $(grep 'comms.sh:' <<<"$IX_OUT_OCC" | tail -1)"
git -C "$IX" worktree remove --force "$IX_OCC_WT" >/dev/null 2>&1 || true
# A FUTURE-DATED attestation is not fresh. The window test is `0 <= age <= N`, and only the upper
# bound was exercised (the stale case): a record stamped ahead of the clock — a skewed clock, or a
# hand-written line — must fall through to the real suite. The candidate's suite is red, so only
# the skip could land it; the control then shows a current record for the same OID does skip.
printf 'suite-cmd = bash ./suite.sh\nsuite-attest-secs = 600\n' > "$IX/.comms/config"
ix_br fut1 main suite.sh $'#!/bin/bash\nexit 1\n'; IX_FUT="$(git -C "$IX" rev-parse fut1)"
printf '%s %s 0\n' "$IX_FUT" "$(( $(date +%s) + 3600 ))" >> "$IX/.comms/cache/suite-attest.log"
IX_MF="$(ix_main)"; IX_R_FUT="$(ix_rc integrate fut1)"
[ "$IX_R_FUT" = 14 ] && [ "$(ix_main)" = "$IX_MF" ] \
  && ok "a future-dated attestation is not honoured: the red suite runs and refuses (14)" || fail "future attestation rc=$IX_R_FUT"
printf '%s %s 0\n' "$IX_FUT" "$(date +%s)" >> "$IX/.comms/cache/suite-attest.log"
IX_OUT="$(ix integrate fut1 2>/dev/null)"
[ "$(ix_main)" = "$IX_FUT" ] && grep -q ' suite=attested$' <<<"$IX_OUT" \
  && ok "control: a current attestation for the same OID does skip the red suite" || fail "attested control: $(grep integrate-result <<<"$IX_OUT")"
printf 'suite-cmd = bash ./suite.sh\n' > "$IX/.comms/config"

section "integrate: suite timeout (a hung suite is killed, refused, and cleaned up)"
# Live case, 2026-09-27: a suite sat at 0% CPU in integrate's verification tree for 45+ minutes
# and integrate, and the driver waiting on it, never ended. suite-timeout-secs bounds the run.
# Reuses the driver-contract fixture above. The hang stub leaves a TERM-IGNORING child in its
# process group, so only the KILL escalation can end it, and records both pids.
IT="$WORK/integrate-timeout"; mkdir -p "$IT"
it_tree_gone() { [ -z "$(git -C "$IX" worktree list --porcelain | grep '/\.integrate-')" ] && ! ls -d "$IX/.claude/worktrees/".integrate-* >/dev/null 2>&1; }
ix_br hang1 main suite.sh "#!/bin/bash
( trap '' TERM; exec sleep 300 ) &
echo \$! > '$IT/child.pid'; echo \$\$ > '$IT/leader.pid'
echo hang-started
sleep 300
"
IT_C="$(git -C "$IX" rev-parse hang1)"
printf 'suite-cmd = bash ./suite.sh\nsuite-timeout-secs = 2\n' > "$IX/.comms/config"
IT_M="$(ix_main)"; IT_T0="$(date +%s)"
IT_OUT="$(ix integrate hang1 2>"$IT/hang.err")"; IT_R=$?
IT_EL=$(( $(date +%s) - IT_T0 ))
[ "$IT_R" = 18 ] && [ "$(ix_main)" = "$IT_M" ] \
  && ok "a suite past suite-timeout-secs exits 18 (suite timeout) and main does not move" \
  || fail "timeout rc=$IT_R main=$(ix_main) expected=$IT_M"
[ "$(printf '%s\n' "$IT_OUT" | grep -c '^integrate-result ')" = 1 ] \
  && [ "$(printf '%s\n' "$IT_OUT" | tail -1)" = "integrate-result v1 status=refused reason=suite_timeout cand=$IT_C main_before=$IT_M branch=hang1 timeout_secs=2" ] \
  && ok "a timeout prints exactly one result line: status=refused reason=suite_timeout" \
  || fail "timeout result line: $(printf '%s\n' "$IT_OUT" | grep 'integrate-result')"
IT_CP="$(cat "$IT/child.pid" 2>/dev/null)"; IT_LP="$(cat "$IT/leader.pid" 2>/dev/null)"
[ -n "$IT_CP" ] && [ -n "$IT_LP" ] && ! kill -0 "$IT_CP" 2>/dev/null && ! kill -0 "$IT_LP" 2>/dev/null \
  && [ "$IT_EL" -lt 60 ] \
  && ok "the suite's whole process group is killed, a TERM-ignoring child included (KILL after the grace)" \
  || { fail "survivors: child=$IT_CP leader=$IT_LP elapsed=${IT_EL}s"; kill -KILL "$IT_CP" "$IT_LP" 2>/dev/null || true; }
it_tree_gone && grep -q '^hang-started$' "$IX/.comms/logs/integrate-$IT_C.suite.log" \
  && ! ls "$IX/.comms/logs/integrate-$IT_C.suite.log.timeout"* >/dev/null 2>&1 \
  && grep -q 'TIMED OUT after 2s' "$IT/hang.err" \
  && ok "the verification tree is removed, the suite log is kept, and stderr names the timeout" \
  || fail "cleanup: tree_gone=$(it_tree_gone && echo y || echo n) log=$(head -c 200 "$IX/.comms/logs/integrate-$IT_C.suite.log" 2>/dev/null)"
# The lease: with an identity, integrate marks its record integrating for the run and must drop
# it on a timeout exactly as on a red suite. The suite reads the record while it hangs.
IT_CL="$(ix presence claim --name timeout-lander --role landing 2>/dev/null)"
IT_I="$(printf '%s' "$IT_CL" | sed -n 's/.*instance: //p')"
IT_REC="$IX/.comms/sessions/timeout-lander-$IT_I.json"
ix_br hang2 main suite.sh "#!/bin/bash
sed -n 's/.*\"state\": \"\\([^\"]*\\)\".*/\\1/p' '$IT_REC' > '$IT/state-during'
sleep 300
"
IT_R2=0; ix integrate hang2 --name timeout-lander --instance "$IT_I" >/dev/null 2>&1 || IT_R2=$?
[ "$IT_R2" = 18 ] && [ "$(cat "$IT/state-during" 2>/dev/null)" = integrating ] \
  && [ "$(sed -n 's/.*"state": "\([^"]*\)".*/\1/p' "$IT_REC")" = working ] && it_tree_gone \
  && ok "with an identity, the integrating lease held during the suite is released on a timeout" \
  || fail "lease: rc=$IT_R2 during=$(cat "$IT/state-during" 2>/dev/null) after=$(sed -n 's/.*"state": "\([^"]*\)".*/\1/p' "$IT_REC" 2>/dev/null)"
ix presence release --name timeout-lander --instance "$IT_I" >/dev/null 2>&1
# A suite finishing INSIDE the bound lands as before, and 0 means no timeout at all.
ix_br quick1 main suite.sh $'#!/bin/bash\nsleep 1\ntest -f a.txt\n'; IT_Q="$(git -C "$IX" rev-parse quick1)"
printf 'suite-cmd = bash ./suite.sh\nsuite-timeout-secs = 60\n' > "$IX/.comms/config"
IT_OUT="$(ix integrate quick1 2>/dev/null)"; IT_R3=$?
[ "$IT_R3" = 0 ] && [ "$(ix_main)" = "$IT_Q" ] && grep -q "^integrate-result v1 status=landed cand=$IT_Q .* suite=ran$" <<<"$IT_OUT" \
  && ok "a suite that finishes inside suite-timeout-secs lands as before" || fail "inside the bound: rc=$IT_R3"
ix_br zero1 main z.txt $'z\n'; IT_Z="$(git -C "$IX" rev-parse zero1)"
printf 'suite-cmd = bash ./suite.sh\nsuite-timeout-secs = 0\n' > "$IX/.comms/config"
IT_R4="$(ix_rc integrate zero1)"
[ "$IT_R4" = 0 ] && [ "$(ix_main)" = "$IT_Z" ] \
  && ok "suite-timeout-secs = 0 (no timeout) is accepted and lands" || fail "zero timeout rc=$IT_R4"
# Bad values refuse as configuration (10) before any suite runs: a typo must never become
# "no bound" or quietly fall back to the default.
ix_br badcfg1 main y.txt $'y\n'; IT_MB="$(ix_main)"; IT_BAD=""
for IT_V in 'abc' '-1' '010' '86401' '99999999999999999999' '1.5' ''; do
  printf 'suite-cmd = bash ./suite.sh\nsuite-timeout-secs = %s\n' "$IT_V" > "$IX/.comms/config"
  IT_RB="$(ix_rc integrate badcfg1)"
  [ "$IT_RB" = 10 ] || IT_BAD="$IT_BAD '$IT_V':$IT_RB"
done
[ -z "$IT_BAD" ] && [ "$(ix_main)" = "$IT_MB" ] \
  && ok "empty, non-numeric, signed, leading-zero, fractional and out-of-range suite-timeout-secs exit 10" \
  || fail "bad timeout values:$IT_BAD"
printf 'suite-cmd = bash ./suite.sh\nsuite-timeout-secs = 60\nsuite-timeout-secs = 0\n' > "$IX/.comms/config"
IT_RD="$(ix_rc integrate badcfg1)"; IT_ERR="$(ix agents 2>&1 >/dev/null)"
[ "$IT_RD" = 10 ] && [ "$(ix_main)" = "$IT_MB" ] && grep -q "duplicate 'suite-timeout-secs'" <<<"$IT_ERR" \
  && ok "a duplicate suite-timeout-secs is refused (10), and every config reader refuses it too" \
  || fail "duplicate timeout: rc=$IT_RD err=$IT_ERR"
printf 'suite-cmd = bash ./suite.sh\nsuite-timeout-secs = 60\n' > "$IX/.comms/config"
IT_ERR="$(ix agents 2>&1 >/dev/null)"
! grep -q 'unknown line' <<<"$IT_ERR" && ok "suite-timeout-secs is a known config key (no unknown-line warning)" || fail "unknown-line warning: $IT_ERR"
# verify fresh shares the verification routine, so it shares the bound and the class.
printf 'suite-cmd = bash ./suite.sh\nsuite-timeout-secs = 1\n' > "$IX/.comms/config"
IT_R5=0; IT_OUT="$(ix verify fresh hang2 2>/dev/null)" || IT_R5=$?
[ "$IT_R5" = 18 ] && [ "$(printf '%s\n' "$IT_OUT" | tail -1)" = "verify-result v1 status=refused reason=suite_timeout cand=$(git -C "$IX" rev-parse hang2) timeout_secs=1" ] \
  && ! ls -d "$IX/.claude/worktrees/".verify-* >/dev/null 2>&1 \
  && ok "verify fresh times out with the same class (18) and a verify-result timeout line" \
  || fail "verify fresh timeout: rc=$IT_R5 out=$(printf '%s' "$IT_OUT" | tail -1)"
printf 'suite-cmd = bash ./suite.sh\n' > "$IX/.comms/config"
# with-beat owns the bound. Its exit status is the command's to forge, so the MARK is what says
# "timed out": a command exiting 124 on its own leaves none.
IT_WB=0; (cd "$IX" && "$COMMS" presence with-beat --no-heartbeat --name wb-timeout --instance 00000000000000000000000000000002 \
  --timeout-secs 1 --timeout-mark "$IT/wb.mark" -- sleep 30) >/dev/null 2>&1 || IT_WB=$?
IT_WS=0; (cd "$IX" && "$COMMS" presence with-beat --no-heartbeat --name wb-timeout --instance 00000000000000000000000000000002 \
  --timeout-secs 30 --timeout-mark "$IT/wb-self.mark" -- bash -c 'exit 124') >/dev/null 2>&1 || IT_WS=$?
[ "$IT_WB" = 124 ] && [ -e "$IT/wb.mark" ] && [ "$IT_WS" = 124 ] && ! [ -e "$IT/wb-self.mark" ] \
  && ok "with-beat --timeout-secs exits 124 and writes its mark; a command's own 124 writes none" \
  || fail "with-beat timeout: timed=$IT_WB mark=$([ -e "$IT/wb.mark" ] && echo y) self=$IT_WS selfmark=$([ -e "$IT/wb-self.mark" ] && echo y)"
# Round-1 review (codex, blocking): with a bound set, a TERM to the wrapper only ends the poll, and
# an unconditional wait on a leader that ignores TERM blocked forever. The wrapper must tear the
# group down (KILL after the grace) and return, well inside the command's own 300s.
(cd "$IX" && exec "$COMMS" presence with-beat --no-heartbeat --name wb-timeout --instance 00000000000000000000000000000002 \
  --timeout-secs 120 -- bash -c 'trap "" TERM; echo $$ > "$1"; while :; do sleep 1; done' _ "$IT/wb-leader.pid") >/dev/null 2>&1 &
IT_WBP=$!; IT_N=0
IT_READY=0; wait_until test -s "$IT/wb-leader.pid" && IT_READY=1
kill -TERM "$IT_WBP" 2>/dev/null; IT_N=0
while kill -0 "$IT_WBP" 2>/dev/null && [ "$IT_N" -lt 300 ]; do sleep 0.1; IT_N=$((IT_N + 1)); done
IT_WBL="$(cat "$IT/wb-leader.pid" 2>/dev/null)"
if kill -0 "$IT_WBP" 2>/dev/null; then
  fail "with-beat --timeout-secs: a TERM with a TERM-ignoring leader left the wrapper blocked (30s)"
  kill -KILL "$IT_WBP" 2>/dev/null; [ -n "$IT_WBL" ] && kill -KILL "$IT_WBL" 2>/dev/null
else
  IT_WBR=0; wait "$IT_WBP" || IT_WBR=$?
  [ "$IT_READY" = 1 ] && [ "$IT_WBR" != 0 ] && [ -n "$IT_WBL" ] && ! kill -0 "$IT_WBL" 2>/dev/null \
    && ok "a TERM to a bounded with-beat still tears down a TERM-ignoring leader and returns non-zero" \
    || { fail "bounded with-beat under TERM: rc=$IT_WBR leader=$IT_WBL"; [ -n "$IT_WBL" ] && kill -KILL "$IT_WBL" 2>/dev/null; }
fi
IT_U1="$(ix_rc presence with-beat --no-heartbeat --name wb-timeout --instance 00000000000000000000000000000002 --timeout-secs x -- true)"
IT_U2="$(ix_rc presence others --name wb-timeout --instance 00000000000000000000000000000002 --timeout-secs 5)"
[ "$IT_U1" = 2 ] && [ "$IT_U2" = 2 ] \
  && ok "a bad --timeout-secs, or one given to another presence verb, is a usage error (2)" \
  || fail "timeout flag usage: bad=$IT_U1 other-verb=$IT_U2"

section "verify: a landing suite for any repo (template, init, status, fresh)"
# integrate runs suite-cmd in a fresh checkout with no shell, so a repo needs a committed script
# that provisions its own dependencies and runs its checks. Every package manager here is a PATH
# stub that records its argv and creates the directory a real install would; nothing touches the
# network. A fixed node stand-in reads package.json scripts through the fixture Python.
VX="$WORK/verify"; VX_BIN="$VX/bin"; VX_TOOLS="$VX/tools"; VX_LOG="$VX/argv.log"
mkdir -p "$VX_BIN" "$VX_TOOLS" "$VX/nobin"; : > "$VX/all.out"
# Link only git; a host node can be a version-manager shim whose manager is deliberately absent
# from vx_run's restricted PATH. The node stand-in below owns the one operation this fixture needs.
ln -sf "$(command -v git)" "$VX_TOOLS/git"
vx_stub() { # <name> [extra shell line] — records "<name> <argv>"; an install makes its outputs
  { printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$1" "$VX_LOG"
    printf 'case "$1" in ci|install|sync) mkdir -p node_modules .venv ;; esac\n'
    printf '%s\n' "${2:-}"
    printf 'case "$*" in *" fail"*) exit 7 ;; esac\nexit 0\n'; } > "$VX_BIN/$1"
  chmod +x "$VX_BIN/$1"
}
for t in pnpm yarn bun uv cargo go mix corepack; do vx_stub "$t"; done
# `npm run env` reports what a step sees: whether stdin is closed, and CI/TZ.
vx_stub npm 'if [ "$1 $2" = "run env" ]; then if read -r _x; then echo "npm-stdin-open" >> "'"$VX_LOG"'"; else echo "npm-stdin-closed CI=${CI:-unset} TZ=${TZ:-unset}" >> "'"$VX_LOG"'"; fi; fi'
# python3 -m venv makes a venv of stubs; anything else goes to the real python3 unrecorded, so a
# host without node still reads package.json and comms.sh keeps its own python3.
VX_PY="$(command -v python3 || echo python3)"
cat > "$VX_BIN/python3" <<STUB
#!/bin/bash
if [ "\$1 \$2" = "-m venv" ]; then
  printf 'python3 %s\n' "\$*" >> "$VX_LOG"; mkdir -p "\$3/bin"
  printf '#!/bin/bash\nprintf "venv-pip %%s\\\\n" "\$*" >> "$VX_LOG"\n' > "\$3/bin/pip"
  printf '#!/bin/bash\nprintf "venv-python %%s\\\\n" "\$*" >> "$VX_LOG"\n' > "\$3/bin/python"
  chmod +x "\$3/bin/pip" "\$3/bin/python"; exit 0
fi
exec "$VX_PY" "\$@"
STUB
chmod +x "$VX_BIN/python3"
cat > "$VX_TOOLS/node" <<'STUB'
#!/bin/bash
# verify.sh uses node only to enumerate package.json script names.
[ "$1" = -e ] || exit 1
exec python3 -c 'import json; print("\n".join((json.load(open("package.json")).get("scripts") or {})))'
STUB
chmod +x "$VX_TOOLS/node"
vx_repo() { # <name> <gitignore> <path=content>... — a committed fixture repo
  local d="$VX/$1" ig="$2" kv; shift 2
  rm -rf "$d"; mkdir -p "$d"; git -C "$d" init -q -b main
  printf '%s' "$ig" > "$d/.gitignore"
  for kv in "$@"; do mkdir -p "$d/$(dirname "${kv%%=*}")"; printf '%s' "${kv#*=}" > "$d/${kv%%=*}"; done
  git -C "$d" add -A >/dev/null 2>&1; git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  printf '%s' "$d"
}
vx_run() { # <repo> [PATH] — run the template there; output to $VX/out (and all.out), argv to $VX_LOG
  : > "$VX_LOG"; local rc=0
  # stdin carries data, so a step that could read it would see "leak" rather than end-of-file.
  (cd "$1" && env -u CI PATH="${2:-$VX_BIN:$VX_TOOLS:/usr/bin:/bin}" bash "$REPO/helpers/verify.sh") <<<leak > "$VX/out" 2>&1 || rc=$?
  cat "$VX/out" >> "$VX/all.out"; echo "$rc"
}
vx_log() { tr '\n' '|' < "$VX_LOG"; }
VX_IG=$'node_modules/\n.venv/\n.comms/\n.claude/worktrees/\n'
VX_PJ='{"name":"x","scripts":{"check":"c","test":"t","lint":"l"}}'

# Detected Node defaults: the lockfile's own package manager, and only scripts that exist.
D="$(vx_repo npm1 "$VX_IG" package.json="$VX_PJ" package-lock.json='{}')"; R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "npm ci --no-audit --no-fund|npm run check|npm run test|" ] \
  && [ -z "$(git -C "$D" status --porcelain)" ] \
  && ok "npm: a frozen install, then check+test (check subsumes lint), leaving no git-visible dirt" \
  || fail "npm defaults: rc=$R argv=$(vx_log) dirt=$(git -C "$D" status --porcelain | head -2)"
D="$(vx_repo pnpm1 "$VX_IG" package.json='{"scripts":{"lint":"l","test":"t"}}' pnpm-lock.yaml='x')"; R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "pnpm install --frozen-lockfile|pnpm run lint|pnpm run test|" ] \
  && ok "pnpm: lint then test through pnpm, and no step for a script that does not exist" \
  || fail "pnpm defaults: rc=$R argv=$(vx_log)"
# A steps-file line runs through a real shell, with stdin closed and CI exported.
D="$(vx_repo steps1 "$VX_IG" package.json="$VX_PJ" package-lock.json='{}' ci/verify.steps=$'# checks\n\nTZ=UTC npm run env\n')"
R="$(vx_run "$D")"
[ "$R" = 0 ] && grep -qx 'npm-stdin-closed CI=true TZ=UTC' "$VX_LOG" \
  && ok "a step line runs in a shell (an env prefix works) with stdin closed and CI=true" \
  || fail "step shell: rc=$R argv=$(vx_log)"
# Failures stop the suite, carry the step's code, and cannot hide in a pipeline or behind a `;`.
D="$(vx_repo stepsfail "$VX_IG" package.json="$VX_PJ" package-lock.json='{}' ci/verify.steps=$'npm run check\nnpm run fail\nnpm run never\n')"
R="$(vx_run "$D")"
[ "$R" = 7 ] && grep -q 'step 2/3 failed (exit 7): npm run fail' "$VX/out" && ! grep -q 'npm run never' "$VX_LOG" \
  && ok "a failing step stops the suite with its own exit code, and is named" || fail "step failure: rc=$R $(tail -1 "$VX/out")"
D="$(vx_repo stepspipe "$VX_IG" package.json="$VX_PJ" package-lock.json='{}' ci/verify.steps=$'npm run fail | cat\n')"
R="$(vx_run "$D")"
[ "$R" = 7 ] && ok "a failure inside a pipeline fails the step (pipefail reaches the step's shell)" || fail "pipeline failure: rc=$R"
D="$(vx_repo stepssemi "$VX_IG" package.json="$VX_PJ" package-lock.json='{}' ci/verify.steps=$'false; true\n')"
R="$(vx_run "$D")"
[ "$R" != 0 ] && ok "\`false; true\` fails the step (errexit reaches the step's shell)" || fail "false; true passed"
# Zero checks is a failure, never a pass.
# Indented comments count as comments: counted as steps they would run as empty shells and pass.
D="$(vx_repo stepsnone "$VX_IG" package.json="$VX_PJ" package-lock.json='{}' ci/verify.steps=$'#@ provision: none\n# nothing here\n  # npm run test\n\t# tabbed\n   \n')"
R="$(vx_run "$D")"
[ "$R" != 0 ] && grep -q 'no checks found' "$VX/out" && [ ! -s "$VX_LOG" ] \
  && ok "a steps file of comments (indented by spaces or tabs) fails before installing: zero checks cannot verify" \
  || fail "empty steps: rc=$R argv=$(vx_log)"
D="$(vx_repo noscripts "$VX_IG" package.json='{"name":"x"}' package-lock.json='{}')"; R="$(vx_run "$D")"
[ "$R" != 0 ] && grep -q 'no checks found' "$VX/out" && ok "a repo with no detectable checks fails rather than passing empty" || fail "no scripts: rc=$R"
# The ignore preflight is directory-aware and runs BEFORE any install.
D="$(vx_repo unignored $'.comms/\n' package.json="$VX_PJ" package-lock.json='{}')"; R="$(vx_run "$D")"
[ "$R" != 0 ] && grep -q "'node_modules/' is not gitignored" "$VX/out" && [ ! -s "$VX_LOG" ] \
  && ok "an unignored install output is refused before installing, naming the .gitignore line" || fail "unignored: rc=$R argv=$(vx_log)"
D="$(vx_repo anchored $'/node_modules\n.comms/\n' package.json="$VX_PJ" package-lock.json='{}')"; R="$(vx_run "$D")"
[ "$R" = 0 ] && ok "an absent node_modules under a root-anchored /node_modules rule counts as ignored" || fail "anchored rule: rc=$R $(head -3 "$VX/out")"
# Two JavaScript lockfiles refuse until a directive picks one; bun's two lockfiles are one stack.
D="$(vx_repo jsboth "$VX_IG" package.json="$VX_PJ" package-lock.json='{}' pnpm-lock.yaml='x')"; R="$(vx_run "$D")"
VX_OK=""; [ "$R" != 0 ] && grep -q 'more than one JavaScript lockfile' "$VX/out" && [ ! -s "$VX_LOG" ] && VX_OK=1
mkdir -p "$D/ci"; printf '#@ provision: pnpm\npnpm run check\n' > "$D/ci/verify.steps"; R="$(vx_run "$D")"
[ -n "$VX_OK" ] && [ "$R" = 0 ] && [ "$(vx_log)" = "pnpm install --frozen-lockfile|pnpm run check|" ] \
  && ok "two JavaScript lockfiles refuse until '#@ provision:' picks one; then only that one installs" \
  || fail "js conflict: first-refused=${VX_OK:-no} directive-rc=$R argv=$(vx_log)"
D="$(vx_repo bunboth "$VX_IG" package.json="$VX_PJ" bun.lock='x' bun.lockb='x')"; R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "bun install --frozen-lockfile|bun run check|bun run test|" ] \
  && ok "bun.lock and bun.lockb are one stack, not a conflict" || fail "bun: rc=$R argv=$(vx_log)"
# A directive cannot recreate the collisions detection refuses; a repeated name installs once.
D="$(vx_repo dirboth "$VX_IG" package.json="$VX_PJ" ci/verify.steps=$'#@ provision: npm,pnpm\nnpm run check\n')"
R1="$(vx_run "$D")"; VX_OK=""; grep -q 'more than one JavaScript manager' "$VX/out" && [ ! -s "$VX_LOG" ] && VX_OK=1
printf '#@ provision: uv,pip\nnpm run check\n' > "$D/ci/verify.steps"
R2="$(vx_run "$D")"; grep -q 'names both pip and uv' "$VX/out" && [ ! -s "$VX_LOG" ] || VX_OK=""
printf '#@ provision: npm,npm\nnpm run check\n' > "$D/ci/verify.steps"; R3="$(vx_run "$D")"
[ -n "$VX_OK" ] && [ "$R1" != 0 ] && [ "$R2" != 0 ] && [ "$R3" = 0 ] && [ "$(vx_log)" = "npm ci --no-audit --no-fund|npm run check|" ] \
  && ok "a directive naming two JavaScript managers, or pip with uv, is refused; a repeated name installs once" \
  || fail "directive collisions: npm,pnpm=$R1 uv,pip=$R2 npm,npm=$R3 argv=$(vx_log)"
D="$(vx_repo native "$VX_IG"$'target/\ndeps/\n_build/\n' Cargo.lock='x' go.sum='x' mix.lock='x')"; R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "cargo fetch --locked|go mod download|mix deps.get --check-locked|cargo test --locked|go test -mod=readonly ./...|mix test|" ] \
  && ok "Cargo, Go and mix: locked fetches, then each stack's own test command" || fail "native stacks: rc=$R argv=$(vx_log) $(head -2 "$VX/out")"
D="$(vx_repo corepack1 "$VX_IG" package.json='{"packageManager":"pnpm@9.0.0","scripts":{"test":"t"}}' pnpm-lock.yaml='x')"; R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "corepack pnpm install --frozen-lockfile|corepack pnpm run test|" ] \
  && ok "a packageManager pin runs the manager through corepack, install and steps alike" || fail "corepack: rc=$R argv=$(vx_log)"
# uv.lock always wins over requirements.txt; requirements alone provisions its own venv.
D="$(vx_repo pyboth "$VX_IG" uv.lock='x' requirements.txt='x' pytest.ini='[pytest]')"; R="$(vx_run "$D")"
VX_OK=""; [ "$R" = 0 ] && [ "$(vx_log)" = "uv sync --frozen|uv run --frozen python -m pytest|" ] && VX_OK=1
mkdir -p "$D/ci"; printf '#@ provision: uv,requirements\nuv run --frozen python -m pytest\n' > "$D/ci/verify.steps"; R="$(vx_run "$D")"
[ -n "$VX_OK" ] && [ "$R" != 0 ] && grep -q 'refused while uv.lock exists' "$VX/out" && [ ! -s "$VX_LOG" ] \
  && ok "uv.lock wins: pip never runs over uv's .venv, even when a directive names requirements" \
  || fail "uv+requirements: uv-only=${VX_OK:-no} directive-rc=$R argv=$(vx_log)"
D="$(vx_repo pyreq "$VX_IG" requirements.txt='x' pytest.ini='[pytest]')"; R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "python3 -m venv .venv|venv-pip install -r requirements.txt|venv-python -m pytest|" ] \
  && ok "requirements.txt alone: a .venv, pip install -r, and pytest from that interpreter" || fail "pip stack: rc=$R argv=$(vx_log)"
# A detected stack whose tool is missing fails; `provision: none` installs and probes nothing.
D="$(vx_repo uvmissing "$VX_IG" uv.lock='x' pytest.ini='[pytest]')"; R="$(vx_run "$D" "$VX/nobin:$VX_TOOLS:/usr/bin:/bin")"
[ "$R" != 0 ] && grep -q "stack 'uv' needs 'uv' on PATH" "$VX/out" \
  && ok "a detected stack whose tool is missing fails, naming the tool" || fail "missing tool: rc=$R $(head -2 "$VX/out")"
D="$(vx_repo provnone $'.comms/\n' package.json="$VX_PJ" package-lock.json='{}' ci/verify.steps=$'#@ provision: none\nnpm run check\n')"
R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "npm run check|" ] \
  && ok "'#@ provision: none' installs nothing and skips the ignore preflight" || fail "provision none: rc=$R argv=$(vx_log)"
# Yarn berry PnP: a TRACKED zero-install loader is allowed, and the install is --immutable.
D="$(vx_repo yarnpnp $'.yarn/*\n.comms/\n' package.json="$VX_PJ" yarn.lock='x' .yarnrc.yml='nodeLinker: pnp' .pnp.cjs='//')"
R="$(vx_run "$D")"
[ "$R" = 0 ] && [ "$(vx_log)" = "yarn install --immutable|yarn run check|yarn run test|" ] \
  && ok "Yarn PnP: a tracked .pnp.cjs is allowed and the install is --immutable" || fail "yarn pnp: rc=$R argv=$(vx_log) $(head -2 "$VX/out")"
# Nothing any run above printed can be mistaken for integrate's completion-line proof.
if grep -Eq '^passed: [0-9]+ +failed: [0-9]+ +skipped: [0-9]+' "$VX/all.out"; then fail "a template line takes the completion-line shape"
else ok "template output never takes the completion-line shape integrate reads as proof"; fi

# verify status / init / fresh, through comms.sh, in a repo whose primary sits off main.
VI="$(vx_repo init1 "$VX_IG" package.json="$VX_PJ" package-lock.json='{}')"; VI="$(cd "$VI" && pwd -P)"
git -C "$VI" checkout -q -b work
mkdir -p "$VI/.comms"; printf 'agents = claude codex\nsuite-cmd = npm run check && npm run test\n' > "$VI/.comms/config"
vi() { (cd "$VI" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE -u CI PATH="$VX_BIN:$VX_TOOLS:$PATH" "$COMMS" "$@"); }
VI_S="$(vi verify status 2>/dev/null)"; VI_R=0; vi verify init </dev/null >/dev/null 2>&1 || VI_R=$?
[ "$VI_S" = "$(printf 'needs-shell\tnpm run check && npm run test')" ] && [ "$VI_R" != 0 ] && [ ! -e "$VI/ci" ] \
  && ok "status flags a shell-only suite-cmd; init with no terminal and no --yes writes nothing" \
  || fail "status/no-tty init: status=$VI_S rc=$VI_R"
VI_R=0; vi verify init --yes --replace-suite-cmd >"$VX/init.out" 2>&1 || VI_R=$?
[ "$VI_R" = 0 ] && head -2 "$VI/ci/verify.sh" | grep_full -q '^# agent-comms verify v1' && [ -x "$VI/ci/verify.sh" ] \
  && [ "$(grep -v '^#' "$VI/ci/verify.steps" | tr '\n' '|')" = "npm run check|npm run test|" ] \
  && [ "$(grep -c 'suite-cmd' "$VI/.comms/config")" = 1 ] && grep -qx 'suite-cmd = bash ci/verify.sh' "$VI/.comms/config" \
  && grep -qx 'agents = claude codex' "$VI/.comms/config" \
  && ok "init writes the template and explicit steps; --replace-suite-cmd repoints suite-cmd keeping every other line" \
  || fail "init: rc=$VI_R $(tail -3 "$VX/init.out")"
[ "$(vi verify status 2>/dev/null)" = "$(printf 'ok\tbash ci/verify.sh')" ] \
  && ok "status reports ok once suite-cmd is a plain command" || fail "status after init: $(vi verify status 2>&1)"
printf 'npm run lint\n' > "$VI/ci/verify.steps"; printf '# agent-comms verify v0\nold\n' > "$VI/ci/verify.sh"
VI_R=0; vi verify init --yes >/dev/null 2>&1 || VI_R=$?
VI_R2=0; vi verify init --update </dev/null >/dev/null 2>&1 || VI_R2=$?
VI_V0="$(head -1 "$VI/ci/verify.sh")"
VI_R3=0; vi verify init --update --yes >/dev/null 2>&1 || VI_R3=$?
[ "$VI_R" != 0 ] && [ "$VI_R2" != 0 ] && [ "$VI_V0" = '# agent-comms verify v0' ] && [ "$VI_R3" = 0 ] \
  && head -2 "$VI/ci/verify.sh" | grep_full -q 'verify v1' && [ "$(cat "$VI/ci/verify.steps")" = "npm run lint" ] \
  && ok "init refuses to overwrite ci/verify.sh; --update needs --yes or a terminal, then refreshes only the template" \
  || fail "overwrite/update: init=$VI_R update-unconfirmed=$VI_R2 ($VI_V0) update-yes=$VI_R3 steps=$(cat "$VI/ci/verify.steps")"
# An EXISTING suite-cmd is never replaced without --replace-suite-cmd, whatever the shell hint says:
# `>` and `;` are ordinary argv to grep and find -exec, and no classifier knows that grammar.
VI_KEPT=1
for VI_CMD in 'bash custom.sh' 'grep -q > helpers/verify.sh' 'find helpers -name verify.sh -exec test -x {} ;' 'npm run check && npm run test'; do
  printf 'agents = claude codex\nsuite-cmd = %s\n' "$VI_CMD" > "$VI/.comms/config"; cp "$VI/.comms/config" "$VX/config.before"; rm -f "$VI/ci/verify.sh"
  VI_R=0; vi verify init --yes >/dev/null 2>&1 || VI_R=$?
  { [ "$VI_R" = 0 ] && [ -f "$VI/ci/verify.sh" ] && cmp -s "$VX/config.before" "$VI/.comms/config"; } || { VI_KEPT=""; echo "  replaced or failed ($VI_R): $VI_CMD" >&2; }
done
[ -n "$VI_KEPT" ] && ok "init never replaces an existing suite-cmd without --replace-suite-cmd, even one the shell hint flags" \
  || fail "an existing suite-cmd was replaced without --replace-suite-cmd"
# `status` is a per-word HINT over integrate's own split: `OK|PASS` is one argument; a glued `&&`
# or a leading VAR=value is not something the no-shell split can run.
VI_HINT=""
for VI_CASE in 'ok|grep -Eq OK|PASS results.txt' 'needs-shell|TZ=UTC npm test' 'needs-shell|npm test&&npm run lint' 'ok|make test CFLAGS=-O2'; do
  printf 'suite-cmd = %s\n' "${VI_CASE#*|}" > "$VI/.comms/config"; VI_S="$(vi verify status 2>/dev/null)"
  [ "${VI_S%%$'\t'*}" = "${VI_CASE%%|*}" ] || VI_HINT="$VI_HINT [${VI_CASE#*|} -> ${VI_S%%$'\t'*}]"
done
[ -z "$VI_HINT" ] && ok "status judges per word: an operator inside an argument is not shell syntax; a glued && or a leading VAR=value is" \
  || fail "status hints:$VI_HINT"
# A config that cannot be READ is not an empty one: init stops before writing anything.
VS_BIN="$VX/sedfail"; mkdir -p "$VS_BIN"
printf '#!/bin/bash\nfor a; do l="$a"; done\ncase "$l" in */.comms/config) exit 2 ;; esac\nexec %s "$@"\n' "$(command -v sed)" > "$VS_BIN/sed"; chmod +x "$VS_BIN/sed"
printf 'agents = claude codex\nsuite-cmd = bash custom.sh\n' > "$VI/.comms/config"; cp "$VI/.comms/config" "$VX/config.before"; rm -f "$VI/ci/verify.sh"
VI_R=0; (cd "$VI" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE -u CI PATH="$VS_BIN:$VX_BIN:$VX_TOOLS:$PATH" "$COMMS" verify init --yes) >/dev/null 2>"$VX/sedfail.err" || VI_R=$?
[ "$VI_R" != 0 ] && grep -q 'refusing to treat it as empty' "$VX/sedfail.err" && [ ! -e "$VI/ci/verify.sh" ] && cmp -s "$VX/config.before" "$VI/.comms/config" \
  && ok "a config read error is not an absent suite-cmd: init stops before writing, and the config is untouched" \
  || fail "config scalar read error: rc=$VI_R $(head -2 "$VX/sedfail.err")"
# A config that cannot be READ is never rewritten: grep exit 2 used to publish only the new line.
VG_BIN="$VX/grepfail"; mkdir -p "$VG_BIN"
printf '#!/bin/bash\ncase "$1 $2" in "-v "*suite-cmd*) exit 2 ;; esac\nexec %s "$@"\n' "$(command -v grep)" > "$VG_BIN/grep"; chmod +x "$VG_BIN/grep"
printf 'agents = claude codex\nsuite-cmd = npm run check && npm run test\n' > "$VI/.comms/config"; cp "$VI/.comms/config" "$VX/config.before"
rm -f "$VI/ci/verify.sh"; VI_R=0
(cd "$VI" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE -u CI PATH="$VG_BIN:$VX_BIN:$VX_TOOLS:$PATH" "$COMMS" verify init --yes --replace-suite-cmd) >/dev/null 2>&1 || VI_R=$?
[ "$VI_R" != 0 ] && cmp -s "$VX/config.before" "$VI/.comms/config" && ! ls "$VI/.comms/config.tmp."* >/dev/null 2>&1 \
  && ok "a config read error aborts the suite-cmd rewrite and leaves .comms/config byte-for-byte intact" \
  || fail "config read error: rc=$VI_R config=$(tr '\n' '|' < "$VI/.comms/config")"
printf 'agents = claude codex\nsuite-cmd = bash ci/verify.sh\n' > "$VI/.comms/config"
printf 'npm run check\nnpm run test\n' > "$VI/ci/verify.steps"; cp "$REPO/helpers/verify.sh" "$VI/ci/verify.sh"
git -C "$VI" add ci >/dev/null 2>&1; git -C "$VI" -c user.email=t@t -c user.name=t commit -qm "chore: add verify suite"
VI_MAIN="$(git -C "$VI" rev-parse main)"; VI_HEAD="$(git -C "$VI" rev-parse HEAD)"
VI_R=0; VI_OUT="$(vi verify fresh 2>/dev/null)" || VI_R=$?
[ "$VI_R" = 0 ] && [ "$(printf '%s\n' "$VI_OUT" | tail -1)" = "verify-result v1 status=verified cand=$VI_HEAD" ] \
  && ! printf '%s\n' "$VI_OUT" | grep -q '^integrate-result' && [ "$(git -C "$VI" rev-parse main)" = "$VI_MAIN" ] \
  && [ -z "$(git -C "$VI" worktree list --porcelain | grep '/\.verify-')" ] && ! ls -d "$VI/.claude/worktrees/".verify-* >/dev/null 2>&1 \
  && ok "verify fresh proves the committed suite in its own throwaway tree, lands nothing, prints verify-result" \
  || fail "verify fresh: rc=$VI_R out=$(printf '%s' "$VI_OUT" | tail -2)"
printf 'npm run check\nnpm run fail\n' > "$VI/ci/verify.steps"
git -C "$VI" add ci >/dev/null 2>&1; git -C "$VI" -c user.email=t@t -c user.name=t commit -qm break
VI_R=0; VI_OUT="$(vi verify fresh 2>/dev/null)" || VI_R=$?
[ "$VI_R" = 14 ] && ! printf '%s\n' "$VI_OUT" | grep -q 'result v1' \
  && [ -z "$(git -C "$VI" worktree list --porcelain | grep '/\.verify-')" ] && ! ls -d "$VI/.claude/worktrees/".verify-* >/dev/null 2>&1 \
  && ok "a red suite under verify fresh exits 14 (integrate's class), prints no result line, and removes its tree" \
  || fail "verify fresh red: rc=$VI_R"
# Two preflights of ONE commit never share completion evidence. A repo with a counts contract
# takes the completion line as proof; here a silent run (exit 0, no line) is still running when a
# proving run of the same commit writes its line. Sharing a per-commit log, the silent run read
# that line and passed. Its own log gives it nothing, so it is unverified (15), and cleans up.
VF="$(vx_repo proof "$VX_IG" tests/expected-counts.tsv=$'total\t1\n' ci/suite.sh=$'#!/bin/bash\nif [ "${VF_MODE:-}" = silent ]; then\n  : > "$VF_UP"; n=0\n  until [ -e "$VF_MARK" ] || [ "$n" -gt 300 ]; do sleep 0.1; n=$((n + 1)); done\n  exit 0\nfi\necho "passed: 1  failed: 0  skipped: 0"; : > "$VF_MARK"\n')"
VF="$(cd "$VF" && pwd -P)"; git -C "$VF" checkout -q -b work
mkdir -p "$VF/.comms"; printf 'suite-cmd = bash ci/suite.sh\n' > "$VF/.comms/config"
vf() { (cd "$VF" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE VF_UP="$VX/vf-up" VF_MARK="$VX/vf-mark" "$COMMS" "$@"); }
rm -f "$VX/vf-up" "$VX/vf-mark"
(export VF_MODE=silent; vf verify fresh >/dev/null 2>&1) & VF_PID=$!
n=0; until [ -e "$VX/vf-up" ] || [ "$n" -gt 300 ]; do sleep 0.1; n=$((n + 1)); done
VF_R1=0; vf verify fresh >/dev/null 2>&1 || VF_R1=$?
VF_R2=0; wait "$VF_PID" || VF_R2=$?
[ "$VF_R1" = 0 ] && [ "$VF_R2" = 15 ] && [ "$(ls "$VF/.comms/logs/" | grep -c '^verify-.*\.suite\.log$')" = 2 ] \
  && [ -z "$(git -C "$VF" worktree list --porcelain | grep '/\.verify-')" ] && ! ls -d "$VF/.claude/worktrees/".verify-* >/dev/null 2>&1 \
  && ok "concurrent preflights of one commit keep separate logs: a silent run cannot borrow another's proof (15), and both clean up" \
  || fail "concurrent verify fresh: proving=$VF_R1 silent=$VF_R2 logs=$(ls "$VF/.comms/logs/" 2>&1 | tr '\n' ' ')"
# Called by a RELATIVE path, as AGENTS.md shows (`.agent-comms/comms.sh integrate`), with a presence
# identity: the routine re-enters comms.sh from inside the fresh checkout, where a relative "$0"
# does not resolve, and both verbs died with 127.
VR="$(vx_repo relpath "$VX_IG" ci/ok.sh=$'#!/bin/bash\necho fine\n')"; VR="$(cd "$VR" && pwd -P)"
(cd "$VR" && bash "$REPO/install.sh" --scope=local >/dev/null 2>&1)
git -C "$VR" checkout -q -b work; mkdir -p "$VR/.comms"; printf 'suite-cmd = bash ci/ok.sh\n' > "$VR/.comms/config"
git -C "$VR" checkout -q -b land main && echo more > "$VR/more.txt" && git -C "$VR" add more.txt \
  && git -C "$VR" -c user.email=t@t -c user.name=t commit -qm land && git -C "$VR" checkout -q work
vr() { (cd "$VR" && env -u CI COMMS_PRESENCE_NAME=relpath-check COMMS_PRESENCE_INSTANCE=0123456789abcdef .agent-comms/comms.sh "$@"); }
VR_R1=0; vr verify fresh land >/dev/null 2>&1 || VR_R1=$?
VR_R2=0; vr integrate land >/dev/null 2>&1 || VR_R2=$?
[ "$VR_R1" = 0 ] && [ "$VR_R2" = 0 ] && [ "$(git -C "$VR" rev-parse main)" = "$(git -C "$VR" rev-parse land)" ] \
  && ok "verify fresh and integrate work when comms.sh is called by a relative path (self re-entry uses the absolute path)" \
  || fail "relative-path self re-entry: verify fresh=$VR_R1 integrate=$VR_R2"
# An INSTALLED comms.sh scaffolds from its installed sibling: verify.sh ships with the helpers.
VU="$(vx_repo installed "$VX_IG" package.json="$VX_PJ" package-lock.json='{}')"
(cd "$VU" && bash "$REPO/install.sh" --scope=local >/dev/null 2>&1)
VU_R=0; (cd "$VU" && env -u CI PATH="$VX_BIN:$VX_TOOLS:$PATH" "$VU/.agent-comms/comms.sh" verify init --yes) >/dev/null 2>&1 || VU_R=$?
[ "$VU_R" = 0 ] && cmp -s "$REPO/helpers/verify.sh" "$VU/.agent-comms/verify.sh" && cmp -s "$REPO/helpers/verify.sh" "$VU/ci/verify.sh" \
  && ok "an installed comms.sh scaffolds ci/verify.sh from the template installed beside it" || fail "installed init: rc=$VU_R"

section "value-taking options: given last with no value, exit 2 naming the option, and write nothing"
# The bare `--name) shift; name="${1:-}"` shape, with the option LAST, left $# at 0 and the loop's
# trailing shift then failed under errexit: exit 1, nothing on stderr, nothing done (friction
# 2026-09-25, `presence claim --name`). Every value-taking option now goes through need_value.
# Each case below is the verb's own words with the option last; it must exit 2, name the option,
# and leave the fixture byte-identical — mailbox, presence records, global home, refs, worktrees.
VO_MARK="$WORK/vo-mark"
vo_state() {
  { (cd "$REPO_FIX" && find .comms -print && find .comms -type f -exec cksum {} + \
       && git status --porcelain --ignored && git for-each-ref && git worktree list --porcelain)
    (cd "$AGENT_COMMS_HOME" && find . -print && find . -type f -exec cksum {} +)
  } 2>&1 | LC_ALL=C sort | cksum
}
vo_run() { # vo_run <comms|rp> <args...> — stderr only; the exit status is the command's
  local bin="$COMMS"; [ "$1" = rp ] && bin="$RUNPHASE"; shift
  (cd "$REPO_FIX" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$bin" "$@") 2>&1 >/dev/null
}
vo_case() { # vo_case <comms|rp> <option> <args...>
  local tool="$1" opt="$2" before err rc newer; shift 2
  before="$(vo_state)"; : > "$VO_MARK"
  err="$(vo_run "$tool" "$@")"; rc=$?
  newer="$( { find "$REPO_FIX/.comms" "$AGENT_COMMS_HOME" -newer "$VO_MARK" -print; } 2>&1)"
  if [ "$rc" = 2 ] && grep -qF -- "$opt needs a value" <<<"$err" && [ "$(vo_state)" = "$before" ] && [ -z "$newer" ]; then
    ok "$tool $* — refused as usage (exit 2), names $opt, writes nothing"
  else
    fail "$tool $* — rc=$rc stderr=[$err] newer=[$newer]"
  fi
}
# CONTROL: the probe must see a write, or "writes nothing" above is vacuous.
VO_BEFORE="$(vo_state)"
VO_CLAIM="$(cd "$REPO_FIX" && env -u COMMS_PRESENCE_NAME -u COMMS_PRESENCE_INSTANCE "$COMMS" presence claim --name vo-control --role probe 2>/dev/null)"
VO_INST="$(printf '%s\n' "$VO_CLAIM" | sed -n 's/.*instance: //p' | head -1)"
[ -n "$VO_INST" ] && [ "$(vo_state)" != "$VO_BEFORE" ] \
  && ok "control: the state probe sees a real presence claim" || fail "control: probe blind to a claim (claim=[$VO_CLAIM])"
(cd "$REPO_FIX" && "$COMMS" presence release --name vo-control --instance "$VO_INST") >/dev/null 2>&1

# The filed repros, verbatim.
vo_case comms --name presence claim --name
vo_case comms --instance presence others --name x --instance
for o in --name --instance --role --state --pid --force; do vo_case comms "$o" presence claim "$o"; done
for o in --as --thread; do vo_case comms "$o" list "$o"; done
for o in --bytes --surface --file; do vo_case comms "$o" lessons "$o"; done
for o in --bytes --limit; do vo_case comms "$o" archive-search "$o"; done
for o in --out --role --review-set --artifact --reviewer-version --prompt-version --base-sha; do vo_case comms "$o" findings "$o"; done
for o in --from --to --file; do vo_case comms "$o" ask "$o"; done
vo_case comms --set panel status --set
for o in --to --set; do vo_case comms "$o" panel dispatch "$o"; done
for o in --degrade --set --out; do vo_case comms "$o" compose "$o"; done
for o in --kind --set --dispatch --thread --round --agent --role --artifact --request-id --message-id --run-dir --status --note --limit; do
  vo_case comms "$o" events append "$o"
done
for o in --thread --severity; do vo_case comms "$o" friction "$o"; done
vo_case comms --note round-note --note
for o in --to --review-set --out --timeout-secs; do vo_case comms "$o" shadow "$o"; done
vo_case comms --as archive --as
vo_case comms --as clean --as
for o in --to --archive-inbound; do vo_case comms "$o" send "$o"; done
for o in --thread --phase --leg-dispatch --leg-agent; do
  vo_case comms "$o" review-route verify rd-0123456789abcdef0123456789abcdef "$o"
done
for o in --passed --expect; do vo_case comms "$o" attest-green "$o"; done
for v in idle legacy; do vo_case comms --days state "$v" --days; done
for o in --name --instance; do vo_case comms "$o" integrate some-branch "$o"; done
for o in --message --agent --provider --sandbox --timeout-secs --via; do vo_case rp "$o" spawn "$o"; done
for o in --message --dir --agent --provider --sandbox --timeout-secs --via; do vo_case rp "$o" run "$o"; done
vo_case rp --timeout-secs await --timeout-secs
