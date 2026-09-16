# Run through tests/run.sh; each group gets fresh fixtures.
section "install.sh: .codex/AGENTS.md managed block"
# Rewriting a file the user may have hand-edited is the risk, so ownership is
# proven rather than assumed. The load-bearing case is the hand-edited one.
AG="$WORK/agents"; mkdir -p "$AG"
AG_B='<!-- agent-comms:begin -->'
AG_E='<!-- agent-comms:end -->'
# The protocol note is now installed ONCE, into the user's global Codex instructions, so
# these fixtures sandbox that file per case instead of using a per-project one. The
# ownership logic under test is unchanged; only where it writes moved.
ag_file() { printf '%s' "$AG/$1/.codex/AGENTS.md"; }
ag_install() { (cd "$AG/$1" && env CODEX_AGENTS_FILE="$(ag_file "$1")" \
  CLAUDE_COMMANDS_DIR="$AG/$1/ghome/commands" CODEX_SKILLS_DIR="$AG/$1/ghome/skills" \
  GROK_COMMANDS_DIR="$AG/$1/ghome/grok-commands" \
  AGENT_COMMS_HOME="$AG/$1/ghome/agent-comms" \
  bash "$REPO/install.sh" --scope=global >"$WORK/ag.out" 2>&1); }
ag_repo() { mkdir -p "$AG/$1" && git -C "$AG/$1" init -q -b main && mkdir -p "$AG/$1/.codex"; }


# STAT IS NOT PORTABLE AND ITS FAILURE IS NOT CLEAN. `stat -f FMT FILE` is a BSD format read; on
# Linux -f means "filesystem status" and FMT is taken as another FILENAME, so the command exits
# non-zero AND still prints a statfs dump for FILE. A BSD-first probe therefore captured the dump
# together with the fallback's good value, and every mode/owner comparison saw garbage — which
# refused every UPGRADE on Linux while fresh installs worked, because the preservation branch
# only runs when the destination already exists. Reproduced in a container 2026-09-04.
#
# The suite only ever runs on ONE of those platforms, so both are stubbed here. This is the only
# assertion that can see the other OS's behaviour at all.
ST_BIN="$WORK/stat-stubs"; mkdir -p "$ST_BIN/linux" "$ST_BIN/macos"
cat > "$ST_BIN/linux/stat" <<'STUB'
#!/bin/sh
# BusyBox/GNU shape: -c formats; -f is statfs and prints a dump to STDOUT before failing.
case "$1" in
  -c) case "$2" in '%u:%g') echo "1234:5678";; '%a') echo "640";; *) exit 1;; esac; exit 0 ;;
  -f) echo "  File: \"$3\""; echo "    ID: deadbeef Namelen: 255"; exit 1 ;;
esac
exit 1
STUB
cat > "$ST_BIN/macos/stat" <<'STUB'
#!/bin/sh
# BSD shape: no -c at all; -f formats.
case "$1" in
  -c) echo "stat: illegal option -- c" >&2; exit 1 ;;
  -f) case "$2" in '%u:%g') echo "1234:5678";; '%Mp%Lp') echo "0640";; *) exit 1;; esac; exit 0 ;;
esac
exit 1
STUB
chmod +x "$ST_BIN/linux/stat" "$ST_BIN/macos/stat"
ST_FN="$(sed -n '/^stat_owner() {/,/^}/p' "$REPO/install.sh"; sed -n '/^stat_mode() {/,/^}/p' "$REPO/install.sh")"
ST_PROBE() { # <stub-dir> -> "owner|mode"
  ( PATH="$1:$PATH"; eval "$ST_FN"; printf '%s|%s' "$(stat_owner /etc/hosts)" "$(stat_mode /etc/hosts)" )
}
ST_L="$(ST_PROBE "$ST_BIN/linux")"
[ "$ST_L" = "1234:5678|640" ] \
  && ok "the owner/mode probes survive a stat whose BSD form prints junk THEN fails (Linux)" || fail "linux-shaped stat yielded '$ST_L'"
ST_M="$(ST_PROBE "$ST_BIN/macos")"
[ "$ST_M" = "1234:5678|0640" ] \
  && ok "the owner/mode probes survive a stat with no GNU form at all (macOS)" || fail "macos-shaped stat yielded '$ST_M'"
# A stat that answers with garbage on BOTH forms must yield EMPTY, which every caller treats as
# fatal — never a value that looks plausible enough to chown/chmod with.
mkdir -p "$ST_BIN/junk"
printf '#!/bin/sh\necho "not a mode at all"\nexit 0\n' > "$ST_BIN/junk/stat"; chmod +x "$ST_BIN/junk/stat"
ST_J="$(ST_PROBE "$ST_BIN/junk")"
[ "$ST_J" = "|" ] \
  && ok "an unrecognisable stat yields EMPTY rather than a plausible-looking wrong value" || fail "junk stat yielded '$ST_J'"
# A LIAR: shape-valid output, non-zero exit. Validating stdout alone accepted it, and `|| true`
# had erased the status that would have caught it — so a partial write would have been handed to
# chown/chmod. (codex, install-ux r1, blocking.)
mkdir -p "$ST_BIN/liar"
printf '#!/bin/sh\ncase "$1$2" in "-c%%u:%%g"|"-f%%u:%%g") echo "1234:5678";; "-c%%a"|"-f%%Mp%%Lp") echo "4755";; esac\nexit 1\n' \
  > "$ST_BIN/liar/stat"; chmod +x "$ST_BIN/liar/stat"
ST_LIAR="$(ST_PROBE "$ST_BIN/liar")"
[ "$ST_LIAR" = "|" ] \
  && ok "a stat that prints a valid-looking answer and THEN fails is rejected, not trusted" || fail "a failing stat's output was accepted: '$ST_LIAR'"
# A half-formed owner is not the documented uid:gid shape and has its own chown semantics.
mkdir -p "$ST_BIN/halfowner"
printf '#!/bin/sh\ncase "$1$2" in "-c%%u:%%g") echo ":5678";; "-c%%a") echo "640";; esac\nexit 0\n' \
  > "$ST_BIN/halfowner/stat"; chmod +x "$ST_BIN/halfowner/stat"
ST_HALF="$( ( PATH="$ST_BIN/halfowner:$PATH"; eval "$ST_FN"; stat_owner /etc/hosts ) )"
[ -z "$ST_HALF" ] \
  && ok "an owner missing its uid or gid is refused, never passed to chown" || fail "half-formed owner accepted: '$ST_HALF'"
# END TO END, which is what the regression was actually about: install_file over an EXISTING
# destination under the Linux-shaped stat. The probe tests alone would still pass if the caller
# were wired up wrong. (codex, install-ux r1, advisory.)
ST_E2E="$WORK/stat-e2e"; mkdir -p "$ST_E2E"
printf 'old\n' > "$ST_E2E/dest"; chmod 640 "$ST_E2E/dest"
printf 'new\n' > "$ST_E2E/src"
ST_E2E_OUT="$( ( PATH="$ST_BIN/linux:$PATH"
    eval "$ST_FN"
    eval "$(sed -n '/^install_has_acl() {/,/^}/p' "$REPO/install.sh")"
    # the stub reports uid:gid 1234:5678, which this test user cannot chown to — so the real
    # assertion is that it FAILS CLOSED and refuses, exactly as install_file promises, rather
    # than replacing the file under the wrong ownership.
    eval "$(sed -n '/^install_file() {/,/^}/p' "$REPO/install.sh")"
    install_file "$ST_E2E/src" "$ST_E2E/dest" 2>&1 ) || true )"
printf '%s\n' "$ST_E2E_OUT" | grep -q 'cannot restore owner/group' \
  && [ "$(cat "$ST_E2E/dest")" = old ] \
  && ok "install_file over an existing destination refuses rather than publishing wrong ownership" || fail "e2e replacement did not fail closed: $ST_E2E_OUT"
# ...and the happy path, which the refusal case cannot show: a stub reporting THIS process's own
# ids, so the chown is a no-op it is allowed to make. Without this, "fails closed" could be the
# only behaviour and the test would still be green. (codex, install-ux r2, advisory.)
ST_OK="$WORK/stat-e2e-ok"; mkdir -p "$ST_OK/bin"
printf 'old\n' > "$ST_OK/dest"; chmod 640 "$ST_OK/dest"; printf 'new\n' > "$ST_OK/src"
printf '#!/bin/sh\ncase "$1$2" in "-c%%u:%%g") echo "%s:%s";; "-c%%a") echo "640";; "-f"*) echo "  File: junk"; exit 1;; esac\nexit 0\n' \
  "$(id -u)" "$(id -g)" > "$ST_OK/bin/stat"; chmod +x "$ST_OK/bin/stat"
ST_OK_OUT="$( ( PATH="$ST_OK/bin:$PATH"
    eval "$ST_FN"
    eval "$(sed -n '/^install_has_acl() {/,/^}/p' "$REPO/install.sh")"
    eval "$(sed -n '/^install_file() {/,/^}/p' "$REPO/install.sh")"
    install_file "$ST_OK/src" "$ST_OK/dest" 2>&1 ) || true )"
[ "$(cat "$ST_OK/dest")" = new ] && [ "$(stat -f '%Lp' "$ST_OK/dest" 2>/dev/null || stat -c '%a' "$ST_OK/dest")" = 640 ] \
  && ok "a Linux-shaped stat completes the upgrade and preserves the destination's mode" || fail "e2e upgrade did not publish: $ST_OK_OUT"
# A one-digit mode is legitimate GNU output and must not read as "cannot read the mode".
mkdir -p "$ST_BIN/shortmode"
printf '#!/bin/sh\ncase "$1$2" in "-c%%u:%%g") echo "1234:5678";; "-c%%a") echo "0";; esac\nexit 0\n' \
  > "$ST_BIN/shortmode/stat"; chmod +x "$ST_BIN/shortmode/stat"
ST_SHORT="$( ( PATH="$ST_BIN/shortmode:$PATH"; eval "$ST_FN"; stat_mode /etc/hosts ) )"
[ "$ST_SHORT" = 0 ] \
  && ok "a short but valid octal mode is accepted, not refused as unreadable" || fail "short mode rejected: '$ST_SHORT'"

# THE COLLAPSE ITSELF (2026-09-04). The note used to be copied into every project, which
# made a per-repo copy of PROSE while the code stayed single-sourced — so the copies drifted
# and the oldest ones still named skills the installer had already deleted. Pin BOTH halves:
# global scope writes it, and project/local scope never does.
AGX="$WORK/agents-scope"; mkdir -p "$AGX"; git -C "$AGX" init -q -b main
(cd "$AGX" && env CODEX_AGENTS_FILE="$AGX/gh/AGENTS.md" CLAUDE_COMMANDS_DIR="$AGX/gh/commands" \
  CODEX_SKILLS_DIR="$AGX/gh/skills" GROK_COMMANDS_DIR="$AGX/gh/grok-commands" AGENT_COMMS_HOME="$AGX/gh/ac" \
  bash "$REPO/install.sh" --scope=global >/dev/null 2>&1)
grep -q 'agent-comms:begin' "$AGX/gh/AGENTS.md" 2>/dev/null \
  && ok "global scope installs the Codex protocol note once, at the global path" || fail "global scope did not write the note"
for AGX_S in project local; do
  AGX_D="$WORK/agents-$AGX_S"; mkdir -p "$AGX_D"; git -C "$AGX_D" init -q -b main
  (cd "$AGX_D" && env CODEX_AGENTS_FILE="$AGX_D/gh/AGENTS.md" CLAUDE_COMMANDS_DIR="$AGX_D/gh/commands" \
    CODEX_SKILLS_DIR="$AGX_D/gh/skills" GROK_COMMANDS_DIR="$AGX_D/gh/grok-commands" AGENT_COMMS_HOME="$AGX_D/gh/ac" \
    bash "$REPO/install.sh" --scope="$AGX_S" >/dev/null 2>&1)
  [ ! -e "$AGX_D/.codex/AGENTS.md" ] \
    && ok "--scope=$AGX_S writes no per-project Codex note" || fail "--scope=$AGX_S still wrote a per-project note"
done
# It is read in EVERY repo now, so it must say where it applies or it describes a mailbox
# that is not there.
AGX_BODY="$(awk '/^agents_block_body\(\)/,/^}/' "$REPO/install.sh")"
printf '%s' "$AGX_BODY" | grep -q '`.comms/` directory' \
  && ok "the global note scopes itself to repositories that have a mailbox" || fail "the global note claims to apply everywhere"
# The path must stay overridable, or this suite rewrites the developer's own instructions.
grep -q 'CODEX_AGENTS_FILE="${CODEX_AGENTS_FILE:-' "$REPO/install.sh" \
  && ok "the global note path is env-overridable (the suite depends on it)" || fail "CODEX_AGENTS_FILE is hardcoded"
# The block's home is now the user's OWN global instructions, which may be a dotfiles symlink
# and may carry a deliberate mode. A bare `mv` would replace the link and reset the mode —
# protections install_file already implements, which the block writer used to bypass because
# it only ever wrote a file this installer had generated. (codex, implement r1, blocking.)
AGY="$WORK/agents-meta"; mkdir -p "$AGY/repo" "$AGY/real"; git -C "$AGY/repo" init -q -b main
agy_install() { (cd "$AGY/repo" && env CODEX_AGENTS_FILE="$1" CLAUDE_COMMANDS_DIR="$AGY/gh/c" \
  CODEX_SKILLS_DIR="$AGY/gh/s" GROK_COMMANDS_DIR="$AGY/gh/g" AGENT_COMMS_HOME="$AGY/gh/a" bash "$REPO/install.sh" --scope=global >/dev/null 2>&1); }
agy_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
# Legacy text an older installer wrote — safe to migrate because it is provably ours.
AG_LEGACY='## Agent Communication Protocol

This project uses a local file-based message queue for communication between Claude Code and Codex, with optional cmux auto-delivery.

- **Your inbox:** `.comms/to-codex/` — Claude writes review requests and responses here
- **Your outbox:** `.comms/to-claude/` — Write your findings and feedback here

**Skills:**
- `$read-from-claude` — Read the latest message from Claude Code and act on it
- `$send-to-claude` — Write your findings back to Claude Code and auto-deliver via cmux when available

**Auto-delivery:** When `cmux` is available, `$send-to-claude` automatically types `/read-from-codex` into Claude'"'"'s pane. Without `cmux`, messages are still written to `.comms/` for manual pickup.

When the user asks you to "check for messages from Claude" or "review what Claude did", use `$read-from-claude`. After completing a review, use `$send-to-claude` to send your findings back.'

# SEED THE REPLACEMENT PATHS, not the append one. An unmarked file appends, and appending
# already wrote through a symlink and kept its mode — so testing that shape would pass even
# with the bare `mv` restored in the two branches that actually REPLACE the file. Marked
# refresh and legacy migration are those branches. (codex, implement r2, advisory.)
{ printf 'my own global notes\n\n'; echo '<!-- agent-comms:begin -->'
  echo '## Agent Communication Protocol'; echo 'stale body an older installer wrote'
  echo '<!-- agent-comms:end -->'; } > "$AGY/real/AGENTS.md"
ln -s "$AGY/real/AGENTS.md" "$AGY/link.md"
agy_install "$AGY/link.md"
[ -L "$AGY/link.md" ] && grep -q 'parent-brokered' "$AGY/real/AGENTS.md" \
  && grep -q 'my own global notes' "$AGY/real/AGENTS.md" \
  && ok "a marked-block REFRESH writes through a symlink instead of replacing it" || fail "the symlink was clobbered on the refresh path"
printf '%s\n' "$AG_LEGACY" > "$AGY/mode.md"; chmod 640 "$AGY/mode.md"; agy_install "$AGY/mode.md"
[ "$(agy_mode "$AGY/mode.md")" = 640 ] && grep -q 'agent-comms:begin' "$AGY/mode.md" \
  && ok "a legacy MIGRATION preserves the file's deliberate mode" || fail "migration reset the mode to $(agy_mode "$AGY/mode.md")"
# LOST UPDATE. The installer reads, decides, then writes back; an editor saving in between
# would be silently overwritten. Deterministic here by publishing against a stale signature.
eval "$(sed -n '/^agents_publish() {/,/^}/p' "$REPO/install.sh")"
eval "$(sed -n '/^agents_sig() {/,/^}/p' "$REPO/install.sh")"
eval "$(sed -n '/^install_file() {/,/^}/p' "$REPO/install.sh")"
eval "$(sed -n '/^install_has_acl() {/,/^}/p' "$REPO/install.sh")"
printf 'v1\n' > "$AGY/race.md"; AGY_SIG="$(agents_sig "$AGY/race.md")"
printf 'v2 saved by the user\n' > "$AGY/race.md"          # the editor wins the race
printf 'installer output\n' > "$AGY/race.tmp"
agents_publish "$AGY/race.tmp" "$AGY/race.md" "$AGY_SIG" >/dev/null 2>&1; AGY_RC=$?
[ "$AGY_RC" != 0 ] && grep -q 'v2 saved by the user' "$AGY/race.md" \
  && ok "a file edited between read and write is refused, never clobbered" || fail "lost update went through (rc=$AGY_RC)"
# HASHING MUST FAIL CLOSED. With no hash command on PATH the first cut returned empty on both
# sides, compared equal, and published over the user's save. (codex, implement r2, blocking.)
AGY_NOHASH="$WORK/agents-nohash-bin"; mkdir -p "$AGY_NOHASH"
for AGY_C in awk sed cat cp mv rm chmod chown stat dirname basename mkdir ls printf grep; do
  AGY_P="$(command -v "$AGY_C" 2>/dev/null)" && ln -sf "$AGY_P" "$AGY_NOHASH/$AGY_C"
done
printf 'v1\n' > "$AGY/nohash.md"
AGY_HRC=0
( PATH="$AGY_NOHASH"; AGY_S="$(agents_sig "$AGY/nohash.md")" || AGY_S=""
  printf 'new\n' > "$AGY/nohash.tmp"
  agents_publish "$AGY/nohash.tmp" "$AGY/nohash.md" "$AGY_S" ) >/dev/null 2>&1 || AGY_HRC=$?
[ "$AGY_HRC" != 0 ] && grep -q '^v1$' "$AGY/nohash.md" \
  && ok "a host with no usable hash command refuses to publish, rather than assuming unchanged" || fail "publication proceeded without a signature (rc=$AGY_HRC)"
ag_repo fresh; ag_install fresh
grep -q 'agent-comms:begin' "$AG/fresh/.codex/AGENTS.md" \
  && ok "AGENTS.md is created with a marked managed block" || fail "AGENTS.md created marked"
AG_SUM="$(cat "$AG/fresh/.codex/AGENTS.md")"
ag_install fresh
[ "$AG_SUM" = "$(cat "$AG/fresh/.codex/AGENTS.md")" ] \
  && ok "a repeat install leaves AGENTS.md byte-identical (no-op diff)" || fail "AGENTS.md repeat install no-op"


ag_repo legacy; printf '%s\n' "$AG_LEGACY" > "$AG/legacy/.codex/AGENTS.md"
AG_BEFORE="$(wc -c <"$AG/legacy/.codex/AGENTS.md")"
ag_install legacy
grep -q 'agent-comms:begin' "$AG/legacy/.codex/AGENTS.md" \
  && ok "an exact legacy block is migrated to a managed block" || fail "legacy migration"
[ "$(wc -c <"$AG/legacy/.codex/AGENTS.md")" -lt "$AG_BEFORE" ] \
  && ok "the migrated AGENTS.md block is smaller than the legacy one" || fail "AGENTS.md shrinks"

# THE one that must never regress: a hand-edited section carries the user's own
# rules, so it is left completely alone rather than rewritten from under them.
ag_repo handedited
{ printf '%s\n' "$AG_LEGACY"; echo; echo '- MY OWN RULE: always run the full suite before replying'; } \
  > "$AG/handedited/.codex/AGENTS.md"
cp "$AG/handedited/.codex/AGENTS.md" "$WORK/handedited.bak"
ag_install handedited
cmp -s "$AG/handedited/.codex/AGENTS.md" "$WORK/handedited.bak" \
  && ok "a HAND-EDITED protocol section is left byte-identical (no data loss)" || fail "hand-edited AGENTS.md was rewritten"
grep -qi 'hand-edited' "$WORK/ag.out" \
  && ok "install explains why it skipped the hand-edited block" || fail "install explains the skip"

# Every marker shape that is NOT exactly one begin above one end must leave the
# file byte-identical. Nested and duplicated pairs, and marker text quoted inside
# a user's Markdown, both destroyed user content before these fixtures existed.
ag_marker_safe() { # ag_marker_safe <name> <must-survive-string>
  local name="$1" keep="$2"
  cp "$AG/$name/.codex/AGENTS.md" "$WORK/$name.bak"
  ag_install "$name"
  if cmp -s "$AG/$name/.codex/AGENTS.md" "$WORK/$name.bak"; then
    ok "AGENTS.md $name marker shape is fail-safe (byte-identical)"
  else
    fail "AGENTS.md $name marker shape rewrote the file"
  fi
  grep -qF "$keep" "$AG/$name/.codex/AGENTS.md" \
    && ok "AGENTS.md $name keeps user content" || fail "AGENTS.md $name LOST user content"
}

ag_repo onesided
{ echo '<!-- agent-comms:begin -->'; echo '## Agent Communication Protocol'; echo 'USER KEEP onesided'; } \
  > "$AG/onesided/.codex/AGENTS.md"
ag_marker_safe onesided 'USER KEEP onesided'

ag_repo nested
{ echo '<!-- agent-comms:begin -->'; echo '- USER KEEP nested A'
  echo '<!-- agent-comms:begin -->'; echo '- rule B'
  echo '<!-- agent-comms:end -->';   echo '- rule C'
  echo '<!-- agent-comms:end -->'; } > "$AG/nested/.codex/AGENTS.md"
ag_marker_safe nested 'USER KEEP nested A'

ag_repo dupends
{ echo '<!-- agent-comms:begin -->'; echo '- USER KEEP dupends'
  echo '<!-- agent-comms:end -->';   echo '<!-- agent-comms:end -->'; } > "$AG/dupends/.codex/AGENTS.md"
ag_marker_safe dupends 'USER KEEP dupends'

ag_repo outoforder
{ echo '<!-- agent-comms:end -->'; echo '- USER KEEP outoforder'
  echo '<!-- agent-comms:begin -->'; } > "$AG/outoforder/.codex/AGENTS.md"
ag_marker_safe outoforder 'USER KEEP outoforder'

# Marker text quoted inside prose is documentation, not ownership: recognizing it
# as a block replaced the user's example AND the private rule between the quotes.
ag_repo inline
{ echo '# My AGENTS'
  echo 'Example: `<!-- agent-comms:begin -->` opens the block.'
  echo '- USER KEEP inline private rule'
  echo 'Example: `<!-- agent-comms:end -->` closes it.'; } > "$AG/inline/.codex/AGENTS.md"
ag_install inline
grep -qF 'USER KEEP inline private rule' "$AG/inline/.codex/AGENTS.md" \
  && ok "AGENTS.md inline marker EXAMPLES never count as ownership" || fail "AGENTS.md inline example destroyed user content"
grep -qF 'Example: `<!-- agent-comms:begin -->` opens the block.' "$AG/inline/.codex/AGENTS.md" \
  && ok "AGENTS.md inline marker example text is preserved verbatim" || fail "AGENTS.md inline example text lost"

# Markers on their own lines INSIDE a fenced code block are documentation about
# the block, not the block itself. Treating them as owned rewrote the fence's
# contents in place (reproduced). Every original line must survive verbatim —
# asserted as a prefix check, not just a sentinel grep.
ag_fenced() { # ag_fenced <name> <sentinel>
  local name="$1" keep="$2" orig
  orig="$(wc -l <"$AG/$name/.codex/AGENTS.md")"
  cp "$AG/$name/.codex/AGENTS.md" "$WORK/$name.bak"
  ag_install "$name"
  if head -n "$orig" "$AG/$name/.codex/AGENTS.md" | cmp -s - "$WORK/$name.bak"; then
    ok "AGENTS.md $name fence: every original line survives verbatim"
  else
    fail "AGENTS.md $name fence: original content was modified"
  fi
  grep -qF "$keep" "$AG/$name/.codex/AGENTS.md" \
    && ok "AGENTS.md $name fence keeps the user sentinel" || fail "AGENTS.md $name fence LOST the sentinel"
}

ag_repo fencedbt
{ echo '# Documentation'; echo '```markdown'; echo "$AG_B"; echo 'USER KEEP fenced backtick'
  echo "$AG_E"; echo '```'; echo '- private rule after example'; } > "$AG/fencedbt/.codex/AGENTS.md"
ag_fenced fencedbt 'USER KEEP fenced backtick'

ag_repo fencedtilde
{ echo '# Documentation'; echo '~~~markdown'; echo "$AG_B"; echo 'USER KEEP fenced tilde'
  echo "$AG_E"; echo '~~~'; } > "$AG/fencedtilde/.codex/AGENTS.md"
ag_fenced fencedtilde 'USER KEEP fenced tilde'

# A longer outer fence wrapping a shorter inner one must nest, not close early.
ag_repo fencednested
{ echo '# Documentation'; echo '````text'; echo '```markdown'; echo "$AG_B"
  echo 'USER KEEP nested fence'; echo "$AG_E"; echo '```'; echo '````'; } > "$AG/fencednested/.codex/AGENTS.md"
ag_fenced fencednested 'USER KEEP nested fence'

# A legacy heading quoted in a fence is an example too.
ag_repo fencedlegacy
{ echo '# Documentation'; echo '```markdown'; echo '## Agent Communication Protocol'
  echo 'USER KEEP fenced legacy'; echo '```'; } > "$AG/fencedlegacy/.codex/AGENTS.md"
ag_fenced fencedlegacy 'USER KEEP fenced legacy'

# An unclosed fence makes inside/outside undecidable — fail safe, write nothing.
ag_repo fenceunclosed
{ echo '# Documentation'; echo '```markdown'; echo "$AG_B"; echo 'USER KEEP unclosed fence'; } \
  > "$AG/fenceunclosed/.codex/AGENTS.md"
cp "$AG/fenceunclosed/.codex/AGENTS.md" "$WORK/fenceunclosed.bak"
ag_install fenceunclosed
cmp -s "$AG/fenceunclosed/.codex/AGENTS.md" "$WORK/fenceunclosed.bak" \
  && ok "AGENTS.md an unclosed fence is fail-safe (byte-identical)" || fail "AGENTS.md unclosed fence rewrote the file"
grep -qi 'unclosed' "$WORK/ag.out" \
  && ok "install explains the unclosed-fence skip" || fail "install explains unclosed fence"

# After appending alongside a fenced example the file holds TWO begin markers —
# one documentation, one live. A second install must resolve to the live one and
# be a no-op, or fence awareness has merely moved the ambiguity.
cp "$AG/fencedbt/.codex/AGENTS.md" "$WORK/fencedbt.after1"
ag_install fencedbt
cmp -s "$AG/fencedbt/.codex/AGENTS.md" "$WORK/fencedbt.after1" \
  && ok "AGENTS.md stays idempotent when a fenced marker example sits beside the live block" \
  || fail "AGENTS.md second install changed the file next to a fenced example"
grep -qF 'USER KEEP fenced backtick' "$AG/fencedbt/.codex/AGENTS.md" \
  && ok "AGENTS.md fenced example survives the second install too" || fail "AGENTS.md fenced example lost on second pass"

# Fence awareness must not break the real thing.
ag_repo realblock
{ echo "$AG_B"; echo 'stale generated text'; echo "$AG_E"; } > "$AG/realblock/.codex/AGENTS.md"
ag_install realblock
grep -q 'Local file-based message queue' "$AG/realblock/.codex/AGENTS.md" \
  && ok "a genuine marked block is still refreshed after the fence fix" || fail "fence fix broke real block management"

ag_repo mixed
{ echo '# Project AGENTS'; echo; echo '## House rules'; echo '- run mix format'; echo;
  printf '%s\n' "$AG_LEGACY"; echo; echo '## Deploy'; echo '- fly deploy'; } \
  > "$AG/mixed/.codex/AGENTS.md"
ag_install mixed
if grep -q 'House rules' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'run mix format' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'Deploy' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'fly deploy' "$AG/mixed/.codex/AGENTS.md" \
   && grep -q 'agent-comms:begin' "$AG/mixed/.codex/AGENTS.md"; then
  ok "migration preserves unrelated content on both sides of the legacy block"
else
  fail "migration lost unrelated AGENTS.md content"
fi
