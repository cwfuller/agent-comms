# Run through tests/run.sh; each group gets fresh fixtures.
section "any-agent driver surface"
# /auto was Claude-only: templates wrote `from: claude`, the installer copied into
# `.claude/commands/`, and a grok/codex driver had no loop verb. whoami + per-runtime
# install is the remaining half of "Any agent drives" (the consult verb already was).
WH="$WORK/whoami-repo"
mkdir -p "$WH/.comms"
git -C "$WH" init -q -b main
git -C "$WH" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
run_wh() { (cd "$WH" && env COMMS_DELIVERY=mailbox "$@"); }
[ "$(run_wh COMMS_SELF=grok "$COMMS" whoami 2>/dev/null)" = grok ] \
  && ok "whoami honours COMMS_SELF=grok" || fail "whoami COMMS_SELF=grok"
[ "$(run_wh COMMS_SELF=codex "$COMMS" whoami 2>/dev/null)" = codex ] \
  && ok "whoami honours COMMS_SELF=codex" || fail "whoami COMMS_SELF=codex"
[ "$(run_wh COMMS_SELF=claude "$COMMS" whoami 2>/dev/null)" = claude ] \
  && ok "whoami honours COMMS_SELF=claude" || fail "whoami COMMS_SELF=claude"
run_wh COMMS_SELF=nope "$COMMS" whoami >/dev/null 2>&1 \
  && fail "whoami accepted an unregistered COMMS_SELF" || ok "whoami refuses an unregistered COMMS_SELF"
WHPS="$WORK/whoami-ps"; mkdir -p "$WHPS/empty" "$WHPS/grok"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-o*args=*) echo; exit 0;; *-o*ppid=*) echo 1; exit 0;; esac; exit 1' > "$WHPS/empty/ps"
printf '%s\n' '#!/bin/sh' 'case "$*" in *-o*args=*) echo /usr/bin/grok; exit 0;; *-o*ppid=*) echo 1; exit 0;; esac; exit 1' > "$WHPS/grok/ps"
chmod +x "$WHPS/empty/ps" "$WHPS/grok/ps"
wh_env() { (cd "$WH" && env -u COMMS_SELF -u GROK_AGENT -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_PID -u CODEX_SANDBOX -u CODEX_THREAD_ID "$@"); }
[ "$(wh_env GROK_AGENT=1 PATH="$WHPS/empty:$PATH" "$COMMS" whoami 2>/dev/null)" = grok ] \
  && ok "GROK_AGENT=1 detects grok" || fail "GROK_AGENT=1 detect"
[ "$(wh_env CLAUDECODE=1 PATH="$WHPS/empty:$PATH" "$COMMS" whoami 2>/dev/null)" = claude ] \
  && ok "CLAUDECODE detects claude" || fail "CLAUDECODE detect"
[ "$(wh_env CLAUDE_CODE_ENTRYPOINT=x PATH="$WHPS/empty:$PATH" "$COMMS" whoami 2>/dev/null)" = claude ] \
  && ok "CLAUDE_CODE_ENTRYPOINT detects claude" || fail "CLAUDE_CODE_ENTRYPOINT detect"
[ "$(wh_env CLAUDE_PID=1 PATH="$WHPS/empty:$PATH" "$COMMS" whoami 2>/dev/null)" = claude ] \
  && ok "CLAUDE_PID detects claude" || fail "CLAUDE_PID detect"
[ "$(wh_env CODEX_SANDBOX=seatbelt PATH="$WHPS/empty:$PATH" "$COMMS" whoami 2>/dev/null)" = codex ] \
  && ok "CODEX_SANDBOX detects codex" || fail "CODEX_SANDBOX detect"
[ "$(wh_env GROK_AGENT=1 COMMS_SELF=codex PATH="$WHPS/empty:$PATH" "$COMMS" whoami 2>/dev/null)" = codex ] \
  && ok "COMMS_SELF wins over GROK_AGENT" || fail "COMMS_SELF override"
wh_env GROK_AGENT=1 CLAUDECODE=1 PATH="$WHPS/empty:$PATH" "$COMMS" whoami >/dev/null 2>&1 \
  && fail "whoami picked a winner between GROK_AGENT and CLAUDECODE" || ok "whoami refuses GROK_AGENT+CLAUDECODE conflict"
wh_env GROK_AGENT=1 CODEX_THREAD_ID=probe PATH="$WHPS/empty:$PATH" "$COMMS" whoami >/dev/null 2>&1 \
  && fail "whoami picked a winner between GROK_AGENT and CODEX_THREAD_ID" || ok "whoami refuses GROK_AGENT+CODEX_THREAD_ID conflict"
wh_env CLAUDECODE=1 CODEX_THREAD_ID=probe PATH="$WHPS/empty:$PATH" "$COMMS" whoami >/dev/null 2>&1 \
  && fail "whoami picked a winner between CLAUDECODE and CODEX_THREAD_ID" || ok "whoami refuses CLAUDECODE+CODEX_THREAD_ID conflict"
[ "$(wh_env GROK_AGENT=1 CLAUDECODE=1 COMMS_SELF=codex PATH="$WHPS/empty:$PATH" "$COMMS" whoami 2>/dev/null)" = codex ] \
  && ok "COMMS_SELF wins over conflicting session signals" || fail "COMMS_SELF vs conflicting env"
wh_env GROK_AGENT=codex PATH="$WHPS/empty:$PATH" "$COMMS" whoami >/dev/null 2>&1 \
  && fail "GROK_AGENT=<agent-name> was treated as the TUI flag" || ok "GROK_AGENT=<agent-name> is not the TUI flag"
wh_env PATH="$WHPS/empty:$PATH" "$COMMS" whoami >/dev/null 2>&1 \
  && fail "whoami defaulted when it had no signal" || ok "whoami fails closed with no signal"
[ "$(wh_env PATH="$WHPS/grok:$PATH" "$COMMS" whoami 2>/dev/null)" = grok ] \
  && ok "whoami reads a grok ancestor executable" || fail "whoami ancestor grok"
"$COMMS" help | grep -q whoami && ok "help lists whoami" || fail "help lists whoami"
grep -qF '"$COMMS_SH" whoami' "$REPO/templates/claude-commands/auto.md" \
  && ok "auto.md calls whoami" || fail "auto.md calls whoami"
grep -q 'SELF=claude' "$REPO/templates/claude-commands/auto.md" \
  && fail "auto.md still hardcodes SELF=claude" || ok "auto.md does not hardcode SELF=claude"
grep -q '^from: claude$' "$REPO/templates/claude-commands/auto.md" \
  && fail "auto.md still hardcodes from: claude" || ok "auto.md does not hardcode from: claude"
for tf in ask.md send-to-codex.md read-from-codex.md clean-comms.md; do
  grep -qF '"$COMMS_SH" whoami' "$REPO/templates/claude-commands/$tf" \
    && ok "$tf calls whoami" || fail "$tf calls whoami"
done
grep -q '^from: claude$' "$REPO/templates/claude-commands/ask.md" \
  && fail "ask.md still hardcodes from: claude" || ok "ask.md does not hardcode from: claude"
grep -q '^from: claude$' "$REPO/templates/claude-commands/send-to-codex.md" \
  && fail "send-to-codex.md still hardcodes from: claude" || ok "send-to-codex.md does not hardcode from: claude"
grep -q -- '--as claude' "$REPO/templates/claude-commands/read-from-codex.md" \
  && fail "read-from-codex.md still lists --as claude" || ok "read-from-codex.md does not list --as claude"
grep -q -- '--as claude' "$REPO/templates/claude-commands/clean-comms.md" \
  && fail "clean-comms.md still lists --as claude" || ok "clean-comms.md does not list --as claude"
AA="$WORK/any-agent-install"; mkdir -p "$AA"; git -C "$AA" init -q -b main
AA_G="$AA/ghome"
aa_env() { env CLAUDE_COMMANDS_DIR="$AA_G/commands" CODEX_SKILLS_DIR="$AA_G/skills" \
  GROK_COMMANDS_DIR="$AA_G/grok-commands" AGENT_COMMS_HOME="$AA_G/agent-comms" \
  CODEX_AGENTS_FILE="$AA_G/AGENTS.md" "$@"; }
(cd "$AA" && aa_env bash "$REPO/install.sh" --scope=both >/dev/null 2>&1)
cmp -s "$AA_G/grok-commands/auto.md" "$REPO/templates/claude-commands/auto.md" \
  && ok "global grok /auto matches the template" || fail "global grok /auto matches the template"
[ -f "$AA_G/grok-commands/ask.md" ] && ok "global grok /ask is installed" || fail "global grok /ask is installed"
[ -f "$AA_G/skills/auto/SKILL.md" ] && ok "global Codex auto skill is installed" || fail "global Codex auto skill is installed"
grep -q '^name: auto$' "$AA_G/skills/auto/SKILL.md" \
  && ok "Codex auto skill has name frontmatter" || fail "Codex auto skill name frontmatter"
grep -qF '"$COMMS_SH" whoami' "$AA_G/skills/auto/SKILL.md" \
  && ok "Codex auto skill carries whoami" || fail "Codex auto skill carries whoami"
[ -d "$AA/.comms/to-grok" ] && ok "project init creates to-grok" || fail "project init creates to-grok"
grep -qF '$auto' "$AA_G/AGENTS.md" && ok "Codex protocol note names \$auto" || fail "Codex protocol note names \$auto"
grep -A30 'done! installed:' "$REPO/install.sh" | grep -q 'Global Grok' \
  && ok "installer banner names Grok" || fail "installer banner names Grok"
(cd "$AA" && aa_env bash "$REPO/install.sh" --scope=local >/dev/null 2>&1)
[ -f "$AA/.grok/commands/auto.md" ] && ok "local pin installs grok /auto" || fail "local pin installs grok /auto"
[ -f "$AA/.agents/skills/auto/SKILL.md" ] && ok "local pin installs Codex auto under .agents/skills" || fail "local pin installs Codex auto under .agents/skills"
[ ! -e "$AA/.codex/skills/auto" ] && ok "local pin does not put Codex auto under .codex/skills" || fail "local pin still used .codex/skills"
