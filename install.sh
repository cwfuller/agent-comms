#!/bin/bash
set -euo pipefail

# agent-comms installer
# Sets up Claude Code <-> Codex autonomous communication over ACP
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
#   or: git clone ... && cd agent-comms && ./install.sh

REPO_RAW_DEFAULT="https://raw.githubusercontent.com/cwfuller/agent-comms/main"
REPO_RAW="${AGENT_COMMS_REPO_RAW:-$REPO_RAW_DEFAULT}"
# When piped (curl | bash) BASH_SOURCE is unset — keep SCRIPT_DIR empty so the
# templates probe below falls through to remote download instead of misreading
# an unrelated templates/ dir in the caller's cwd.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi
CLAUDE_COMMANDS_DIR="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
CLAUDE_COMMANDS="send-to-codex.md read-from-codex.md ask.md auto.md clean-comms.md"
# Commands this project used to install. An upgrade that only stops COPYING them leaves
# them on disk and callable, so the agent keeps being told to use surfaces that no longer
# exist. Removing them is part of installing. (grok, collapse round 1.)
RETIRED_COMMANDS="auto-plan.md auto-implement.md auto-full.md fleet.md ask-codex.md"
# Same rule for helpers: an upgrade that stops copying one leaves it on disk, callable and
# stale. Removing retired surface is part of installing, not a separate chore.
RETIRED_HELPERS="fleet.sh"
# The reviewer-side Codex skills were DELETED in step 4 (S4-3). Every review turn is
# parent-brokered over ACP and `build_grok_prompt` inlines what the child needs, so nothing
# resolved them any more. Listed as RETIRED so an upgrade REMOVES the copies an earlier
# install left on disk — a stale skill left callable is the same trap RETIRED_COMMANDS exists
# for. Owner decision (2026-09-02): full deletion, not retirement-in-place.
RETIRED_CODEX_SKILLS="read-from-claude send-to-claude"
# Shared helper scripts — the single source of truth both agents call.
AGENT_COMMS_HOME="${AGENT_COMMS_HOME:-$HOME/.agent-comms}"
HELPERS="comms.sh runphase.sh acp.sh"
# The reviewer's REVIEW BAR, installed as data. It used to be read out of the codex self-send
# skills at runtime, which made "delete the self-send templates" silently equal to "delete the
# reviewer's standard". Installed from docs/loopspec/fragments/ — their canonical home, and what
# the drift test measures templates against — so this adds a copy on disk, not a second origin.
LOOPSPEC_FRAGMENTS="verdict-discipline.md holistic-rereview.md"
# Resolved per source, like TEMPLATE_DIR: the checkout's docs/ when running locally, a temp dir
# when piped through curl (BASH_SOURCE is unset then, so a repo-relative path would silently miss).
FRAGMENT_SRC=""
SCOPE=""

usage() {
  cat <<USAGE
Usage: install.sh [--scope=local|global|project|both]

Scopes:
  local    Install Claude commands into the current project, plus project state.
  global   Install reusable Claude commands and helpers into your home dir.
  project  Initialize only repo-local state (.comms, .gitignore, .codex/AGENTS.md).
  both     Install global commands and initialize this project.

With curl:
  curl -fsSL $REPO_RAW/install.sh | bash -s -- --scope=both
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scope=*)
      SCOPE="${1#--scope=}"
      ;;
    --scope)
      shift
      if [ "$#" -eq 0 ]; then
        echo "error: --scope requires local, global, project, or both" >&2
        exit 1
      fi
      SCOPE="$1"
      ;;
    --local)
      SCOPE="local"
      ;;
    --global)
      SCOPE="global"
      ;;
    --project)
      SCOPE="project"
      ;;
    --both)
      SCOPE="both"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

choose_scope() {
  if [ -n "$SCOPE" ]; then
    return
  fi

  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    SCOPE="local"
    echo "  no interactive terminal detected; defaulting to --scope=local"
    echo "  pass --scope=both, --scope=global, or --scope=project for scripted installs"
    return
  fi

  cat >&3 <<'MENU'
Choose install scope:
  1) Global + project init (recommended)
  2) Global only
  3) Project init only
  4) Local pinned install
  5) Cancel
MENU

  while true; do
    printf "Enter choice [1]: " >&3
    read -r choice <&3 || choice=""
    choice="${choice:-1}"
    case "$choice" in
      1) SCOPE="both"; break ;;
      2) SCOPE="global"; break ;;
      3) SCOPE="project"; break ;;
      4) SCOPE="local"; break ;;
      5) echo "  cancelled"; exec 3>&-; exit 0 ;;
      *) echo "  choose 1, 2, 3, 4, or 5" >&3 ;;
    esac
  done
  exec 3>&-
}

validate_scope() {
  case "$SCOPE" in
    local|global|project|both) ;;
    *)
      echo "error: invalid scope '$SCOPE' (expected local, global, project, or both)" >&2
      exit 1
      ;;
  esac
}

# Detect if running from cloned repo or curl pipe
if [ -d "$SCRIPT_DIR/templates" ]; then
  SOURCE="local"
  TEMPLATE_DIR="$SCRIPT_DIR/templates"
  FRAGMENT_SRC="$SCRIPT_DIR/docs/loopspec/fragments"
  HELPER_SRC="$SCRIPT_DIR/helpers"
else
  SOURCE="remote"
  TEMPLATE_DIR=$(mktemp -d)
  FRAGMENT_SRC="$TEMPLATE_DIR/loopspec-fragments"
  HELPER_SRC="$TEMPLATE_DIR/helpers"
  trap 'rm -rf "$TEMPLATE_DIR"' EXIT
fi

echo "agent-comms: installing Claude <-> Codex communication protocol"
echo ""

choose_scope
validate_scope
echo "  scope: $SCOPE"

# Find project root (git root)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo "  project: $PROJECT_ROOT"

needs_templates() {
  case "$SCOPE" in
    local|global|both) return 0 ;;
    project) return 1 ;;
  esac
}

# Installing over a helper another session is RUNNING is not hypothetical: bash reads
# an executing script LAZILY, by byte offset, so a plain `cp` — which truncates and
# rewrites the SAME inode — shifts the bytes under a live reader, and it resumes
# mid-token. Seen three times on 2026-08-27, once as a parked `runphase.sh await`
# dying with `line 1326: l: command not found`.
#
# A sibling temp plus rename fixes it by construction: rename(2) unlinks the old NAME
# while readers already inside the old inode keep it alive and finish on the file they
# started with. The temp must be a SIBLING of the destination — rename(2) is atomic only
# within one filesystem, and a cross-device `mv` degrades to a copy-in-place that
# silently reintroduces this bug.
#
# Replacing a file by rename is NOT the same operation as writing through it, so three
# things `cp` used to do are reproduced deliberately rather than by accident:
#
#   MODE. `cp` preserved an existing destination's mode and gave a new one the source
#   mode masked by umask. Hardcoding 755 published helpers world-executable on a
#   umask-077 box (700 -> 755) and reset a command a user had tightened on purpose.
#   So: keep the destination's mode when it exists, leave `cp`'s umask-masked mode when
#   it does not, and add execute with `chmod +x` — which umask masks exactly as the old
#   call did — instead of a literal 755.
#
#   SYMLINKS. `cp` wrote THROUGH a symlink; rename replaces it, silently disconnecting a
#   dotfile-managed install. Worse, `mv` follows a symlink that points at a DIRECTORY and
#   moves the temp inside it, reporting success — and cross-device that is the
#   copy-in-place this function exists to prevent. The link is resolved first, so the
#   file it names is what gets replaced.
#
#   OWNER AND GROUP. Same reason as mode: the old inode kept them, a fresh temp does not,
#   and on BSD it inherits the parent directory's group instead. Restoring them is
#   REQUIRED, not best-effort — a `chown` that cannot be applied REFUSES the replacement,
#   because publishing the file under the directory's group instead of its own is a silent
#   permission change. The trade that buys: a destination you can write but cannot `chown`
#   (a coworker-owned group-writable file, or a `wheel`-group dest you are not in) now
#   fails where `cp` succeeded by writing through. That is deliberate — the alternative is
#   widening access quietly. An ACL is the one thing that genuinely cannot follow a new
#   inode, so it is reported rather than silently dropped.
#
#   AN UNWRITABLE DESTINATION. `cp` failed with EACCES and aborted the install under
#   `set -e`, which is the only way a user can pin a customized file. `mv` unlinks the
#   directory entry instead and would overwrite it, so the refusal has to be explicit.
#
# The symlink walk is bounded at 16 hops. That is a loop guard, not a supported depth:
# real installs are one hop or none, and a chain deeper than 16 is a configuration error
# worth stopping on.
#
# (codex + grok, panel round 1 — every case above was found in review, not in testing.)
# install_has_acl <path> — does this file carry an access control list?
#
# The obvious probe, `+` in the mode column, CANNOT answer this on Darwin: `ls(1)` prints
# `@` when extended attributes are present and `+` only *otherwise*, so a file with both
# shows `@`. Extended attributes are routine here, which makes the marker useless for the
# exact case the warning exists to catch — verified live on a destination whose mode line
# read `-rw-r--r--@` while it carried an `everyone deny read` entry. (codex + grok,
# corroborated, panel round 3.)
#
# So ask for the ACL entries themselves. `ls -lde` prints them as numbered lines on
# Darwin; on Linux `-e` is not an option, the command fails, and there the `+` marker IS
# reliable. The SYSTEM ls is used deliberately: an `ls` replacement earlier on PATH has
# different flags and a different column layout, and would be answering for the wrong
# tool — on the machine this was written, `ls` resolved to `eza`, which rejects `-e`.
install_has_acl() {
  local ls_bin=/bin/ls
  [ -x "$ls_bin" ] || ls_bin=ls
  "$ls_bin" -lde "$1" 2>/dev/null | grep -q '^[[:space:]]*[0-9][0-9]*:' && return 0
  [ "$("$ls_bin" -ld "$1" 2>/dev/null | cut -c11)" = "+" ]
}

install_file() { # install_file <src> <dest> [exec]
  local src="$1" dest="$2" want_exec="${3:-}" tmp link hops=0 destmode destown
  while [ -L "$dest" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 16 ]; then
      echo "install: too many symlink hops resolving $dest — refusing" >&2
      return 1
    fi
    link="$(readlink "$dest")"
    case "$link" in
      /*) dest="$link" ;;
      *)  dest="$(dirname "$dest")/$link" ;;
    esac
  done
  if [ -d "$dest" ]; then
    echo "install: $dest is a directory — refusing to install over it" >&2
    return 1
  fi
  if [ -e "$dest" ] && [ ! -w "$dest" ]; then
    echo "install: $dest is not writable — refusing to replace it" >&2
    return 1
  fi
  tmp="$(dirname "$dest")/.agent-comms-install.$$.$(basename "$dest")"
  cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -e "$dest" ]; then
    # OWNERSHIP FIRST. `chown` clears setuid/setgid on both Darwin and Linux — even when
    # it is a no-op chown to the values already there — so applying it after the mode
    # silently undid the special bits this block had just restored. Verified live:
    # `chown $(stat -f '%u:%g' f) f` turned 4755 into 0755. (codex + grok, panel round 3.)
    destown="$(stat -f '%u:%g' "$dest" 2>/dev/null || stat -c '%u:%g' "$dest" 2>/dev/null || true)"
    if [ -z "$destown" ]; then
      echo "install: cannot read the owner of $dest — refusing to replace it" >&2
      rm -f "$tmp"; return 1
    fi
    # FATAL, not best-effort. Publishing the file under the directory's group instead of
    # its own is a silent permission change, and it is exactly what happens by default:
    # a fresh temp inherits the parent directory's group on BSD. Warning and exiting 0
    # left the criterion unmet while the install looked successful. (codex, round 3 —
    # reproduced: a 501:0 destination was republished as 501:20.)
    if ! chown "$destown" "$tmp" 2>/dev/null; then
      echo "install: cannot restore owner/group $destown on $dest — refusing to replace it" >&2
      echo "         (a replaced file would be published under this directory's group instead)" >&2
      rm -f "$tmp"; return 1
    fi
    # %Mp%Lp, not %Lp: Darwin's %Lp drops the special nibble, so a 4755 destination would
    # come back 755 and quietly lose setuid/setgid/sticky. GNU's %a already carries it.
    destmode="$(stat -f '%Mp%Lp' "$dest" 2>/dev/null || stat -c '%a' "$dest" 2>/dev/null || true)"
    if [ -z "$destmode" ]; then
      # Preservation is the entire point of this branch. Widening the file to the temp's
      # umask-derived mode because a stat failed is the silent regression, not a fallback.
      echo "install: cannot read the mode of $dest — refusing to replace it" >&2
      rm -f "$tmp"; return 1
    fi
    chmod "$destmode" "$tmp" || { rm -f "$tmp"; return 1; }
    # An ACL cannot ride along to a new inode — inherent to replacing a file rather than
    # writing through it, and the one loss with security meaning. Losing it LOUDLY is the
    # most this design can honestly offer.
    if install_has_acl "$dest"; then
      echo "install: $dest carries an ACL, which a replaced file cannot keep — re-apply it after installing" >&2
    fi
  fi
  if [ -n "$want_exec" ]; then
    chmod +x "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

install_global_assets() {
  echo ""
  echo "  installing global Claude commands..."
  mkdir -p "$CLAUDE_COMMANDS_DIR"
  for f in $CLAUDE_COMMANDS; do
    install_file "$TEMPLATE_DIR/claude-commands/$f" "$CLAUDE_COMMANDS_DIR/$f"
  done
  for f in $RETIRED_COMMANDS; do
    [ -f "$CLAUDE_COMMANDS_DIR/$f" ] && { rm -f "$CLAUDE_COMMANDS_DIR/$f"; echo "  removed retired command /${f%.md}"; }
  done

  for skill in $RETIRED_CODEX_SKILLS; do
    [ -f "$CODEX_SKILLS_DIR/$skill/SKILL.md" ] && { rm -rf "${CODEX_SKILLS_DIR:?}/$skill"; echo "  removed retired Codex skill $skill"; }
  done

  echo "  installing shared helpers to $AGENT_COMMS_HOME..."
  mkdir -p "$AGENT_COMMS_HOME"
  for h in $HELPERS; do
    install_file "$HELPER_SRC/$h" "$AGENT_COMMS_HOME/$h" exec
  done
  for h in $RETIRED_HELPERS; do
    [ -f "$AGENT_COMMS_HOME/$h" ] && { rm -f "$AGENT_COMMS_HOME/$h"; echo "  removed retired helper $h"; }
  done
  echo "  installing loopspec fragments to $AGENT_COMMS_HOME/loopspec-fragments..."
  mkdir -p "$AGENT_COMMS_HOME/loopspec-fragments"
  for f in $LOOPSPEC_FRAGMENTS; do
    install_file "$FRAGMENT_SRC/$f" "$AGENT_COMMS_HOME/loopspec-fragments/$f"
  done
  echo "  Loops run over ACP — no pane multiplexer required."
}

install_local_assets() {
  echo ""
  echo "  installing project-local Claude commands..."
  mkdir -p "$PROJECT_ROOT/.claude/commands"
  for f in $CLAUDE_COMMANDS; do
    install_file "$TEMPLATE_DIR/claude-commands/$f" "$PROJECT_ROOT/.claude/commands/$f"
  done
  for f in $RETIRED_COMMANDS; do
    [ -f "$PROJECT_ROOT/.claude/commands/$f" ] && { rm -f "$PROJECT_ROOT/.claude/commands/$f"; echo "  removed retired command /${f%.md}"; }
  done

  for skill in $RETIRED_CODEX_SKILLS; do
    [ -f "$PROJECT_ROOT/.agents/skills/$skill/SKILL.md" ] && { rm -rf "${PROJECT_ROOT:?}/.agents/skills/$skill"; echo "  removed retired Codex skill $skill"; }
  done

  # THE REVIEW BAR, pinned locally. Without this a local-only install — which is also the
  # noninteractive default — gets the new resolver and no fragment to resolve, so every review
  # turn fails closed outside this repo. The repo tier only rescues a pin sitting next to THIS
  # checkout's docs/, so dogfooding could not see the hole. (codex + grok, S3-1 r1, blocking.)
  echo "  installing project-local loopspec fragments..."
  mkdir -p "$PROJECT_ROOT/.agents/loopspec-fragments"
  for f in $LOOPSPEC_FRAGMENTS; do
    install_file "$FRAGMENT_SRC/$f" "$PROJECT_ROOT/.agents/loopspec-fragments/$f"
  done

  echo "  installing project-local shared helpers..."
  mkdir -p "$PROJECT_ROOT/.agent-comms"
  for h in $HELPERS; do
    install_file "$HELPER_SRC/$h" "$PROJECT_ROOT/.agent-comms/$h" exec
  done
  # A local pin outranks the global install, so a retired helper surviving HERE
  # shadows its own removal everywhere else. The explicit return keeps a missing
  # retired file (the common case) from becoming the function's exit status under
  # set -e.
  for h in $RETIRED_HELPERS; do
    [ -f "$PROJECT_ROOT/.agent-comms/$h" ] && { rm -f "$PROJECT_ROOT/.agent-comms/$h"; echo "  removed retired helper $h"; }
  done
  return 0
}

warn_local_shadowing() {
  case "$SCOPE" in
    global|both|project) ;;
    *) return ;;
  esac

  # Only worth warning when there's actually a global install to shadow.
  local global_present=false
  for f in $CLAUDE_COMMANDS; do
    [ -f "$CLAUDE_COMMANDS_DIR/$f" ] && global_present=true && break
  done
  if [ "$global_present" = false ]; then
    for f in $LOOPSPEC_FRAGMENTS; do
      [ -f "$AGENT_COMMS_HOME/loopspec-fragments/$f" ] && global_present=true && break
    done
  fi
  [ "$global_present" = false ] && return

  local shadowed=""
  for f in $CLAUDE_COMMANDS; do
    [ -f "$PROJECT_ROOT/.claude/commands/$f" ] && shadowed="$shadowed .claude/commands/$f"
  done
  for h in $HELPERS; do
    [ -f "$PROJECT_ROOT/.agent-comms/$h" ] && shadowed="$shadowed .agent-comms/$h"
  done
  # A pinned review bar outranks the global one the same way a pinned skill does, so a stale
  # local fragment would silently keep serving an old standard. (grok, S3-1 r1.)
  for f in $LOOPSPEC_FRAGMENTS; do
    [ -f "$PROJECT_ROOT/.agents/loopspec-fragments/$f" ] && shadowed="$shadowed .agents/loopspec-fragments/$f"
  done

  if [ -n "$shadowed" ]; then
    echo "  warning: project-local agent-comms files exist and will shadow the global install:"
    for path in $shadowed; do
      echo "    $path"
    done
    echo "  remove these if you want global updates to apply automatically."
  fi
}

init_project_state() {
  echo ""
  echo "  creating project state..."
  mkdir -p "$PROJECT_ROOT/.comms/to-codex"
  mkdir -p "$PROJECT_ROOT/.comms/to-claude"
  mkdir -p "$PROJECT_ROOT/.comms/archive"
  mkdir -p "$PROJECT_ROOT/.codex"

  # Add .comms/ (and the installer-managed Codex protocol note) to .gitignore.
  # Whole-line match so substrings like "docs/.comms/notes" don't false-positive.
  if [ -f "$PROJECT_ROOT/.gitignore" ]; then
    MISSING=""
    grep -qxF '.comms/' "$PROJECT_ROOT/.gitignore" || MISSING=".comms/"
    grep -qxF '.codex/AGENTS.md' "$PROJECT_ROOT/.gitignore" || MISSING="$MISSING .codex/AGENTS.md"
    grep -qxF '.agent-comms/' "$PROJECT_ROOT/.gitignore" || MISSING="$MISSING .agent-comms/"
    # Session worktrees inside the checkout must be ignore-covered or they walk a
    # full second repo copy into snapshots and broad staging (panel r1 + 7dc08b4).
    grep -qxF '.claude/worktrees/' "$PROJECT_ROOT/.gitignore" || MISSING="$MISSING .claude/worktrees/"
    if [ -n "$MISSING" ]; then
      # Guard against a missing trailing newline swallowing our first appended line.
      [ -n "$(tail -c1 "$PROJECT_ROOT/.gitignore")" ] && echo "" >> "$PROJECT_ROOT/.gitignore"
      echo "" >> "$PROJECT_ROOT/.gitignore"
      echo "# Local agent communication" >> "$PROJECT_ROOT/.gitignore"
      for entry in $MISSING; do
        echo "$entry" >> "$PROJECT_ROOT/.gitignore"
      done
      echo "  added to .gitignore:$( printf ' %s' $MISSING )"
    else
      echo "  .gitignore already covers .comms/ and .codex/AGENTS.md"
    fi
  else
    {
      echo "# Local agent communication"
      echo ".comms/"
      echo ".codex/AGENTS.md"
      echo ".agent-comms/"
      echo ".claude/worktrees/"
    } > "$PROJECT_ROOT/.gitignore"
    echo "  created .gitignore with .comms/, .codex/AGENTS.md, .agent-comms/, .claude/worktrees/"
  fi

  install_agents_block "$PROJECT_ROOT/.codex/AGENTS.md"
}

# --- .codex/AGENTS.md managed block -----------------------------------------
# This file is loaded by Codex on every turn, so it pays for itself in tokens
# every round. It only needs to NAME the entry points — the skills themselves
# carry the protocol. The old block restated them (and drifted from them).
#
# Rewriting a file the user may have hand-edited is the risk here, so ownership
# is proven, never assumed: a marked block is ours, an unmarked block is ours
# only if it still matches byte-for-byte what an installer wrote, and anything
# else is left alone with a note.
AGENTS_BEGIN='<!-- agent-comms:begin -->'
AGENTS_END='<!-- agent-comms:end -->'

agents_block_body() {
  cat << 'PROTOCOL'
## Agent Communication Protocol

Local file-based message queue between Claude Code and Codex.

- **Your inbox:** `.comms/to-codex/` — read it with `$read-from-claude`
- **Your outbox:** `.comms/to-claude/` — write your findings with `$send-to-claude`

Those two skills carry the protocol itself (message format, verdicts, delivery,
recovery). This block only names the entry points.
PROTOCOL
}

# The exact text previous installers wrote. Ownership evidence — do not edit.
# FROZEN, BYTE-EXACT. This is not documentation — it is ownership EVIDENCE, compared against
# a user's existing .codex/AGENTS.md to prove a block was written by an older installer of ours
# before migrating it. Editing a word here makes every previously-installed block unrecognisable
# and the migration silently declines to touch it. It mentions cmux because older installers
# wrote cmux; that is history, not a live instruction, and S4-4 deliberately left it alone.
# (Walked into exactly this during S4-4: three words changed here reddened 3 assertions.)
legacy_block_body() {
  cat << 'PROTOCOL'
## Agent Communication Protocol

This project uses a local file-based message queue for communication between Claude Code and Codex, with optional cmux auto-delivery.

- **Your inbox:** `.comms/to-codex/` — Claude writes review requests and responses here
- **Your outbox:** `.comms/to-claude/` — Write your findings and feedback here

**Skills:**
- `$read-from-claude` — Read the latest message from Claude Code and act on it
- `$send-to-claude` — Write your findings back to Claude Code and auto-deliver via cmux when available

**Auto-delivery:** When `cmux` is available, `$send-to-claude` automatically types `/read-from-codex` into Claude's pane. Without `cmux`, messages are still written to `.comms/` for manual pickup.

When the user asks you to "check for messages from Claude" or "review what Claude did", use `$read-from-claude`. After completing a review, use `$send-to-claude` to send your findings back.
PROTOCOL
}

# Emit "B<line>" / "E<line>" for marker lines that are REAL — exact full lines
# outside any fenced code block — plus "UNCLOSED" if a fence never closes.
#
# Fence awareness is not pedantry: a marker line inside a ```markdown example is
# documentation ABOUT the block, not the block itself, and treating it as owned
# deletes the user's example (reproduced). Fences follow the CommonMark rule —
# a closing fence uses the same character, is at least as long as the opener,
# and carries no info string — so a longer outer fence wrapping a shorter inner
# one nests correctly instead of closing early.
marker_scan() {
  awk -v b="$1" -v e="$2" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (match(line, /^[ \t]*(```+|~~~+)/)) {
        m = line; sub(/^[ \t]*/, "", m)
        match(m, /^(`+|~+)/); tok = substr(m, 1, RLENGTH)
        ch = substr(tok, 1, 1); len = length(tok)
        rest = substr(m, RLENGTH + 1)
        if (!infence) { infence = 1; fch = ch; flen = len }
        else if (ch == fch && len >= flen && rest ~ /^[ \t]*$/) { infence = 0 }
        next
      }
      if (infence) next
      if (line == b) print "B" NR
      else if (line == e) print "E" NR
    }
    END { if (infence) print "UNCLOSED" }
  ' "$3"
}

# Trailing whitespace and surrounding blank lines only — never content.
norm_block() {
  sed -e 's/[[:space:]]*$//' \
    | awk '{ l[NR] = $0 }
      END { s = 1; while (s <= NR && l[s] == "") s++
            e = NR; while (e >= 1 && l[e] == "") e--
            for (i = s; i <= e; i++) print l[i] }'
}

install_agents_block() {
  local f="$1" tmp begin_n end_n start_n next_n
  mkdir -p "$(dirname "$f")"

  if [ ! -f "$f" ]; then
    { echo "$AGENTS_BEGIN"; agents_block_body; echo "$AGENTS_END"; } > "$f"
    echo "  created .codex/AGENTS.md with the managed agent-comms block"
    return 0
  fi

  # Markers are recognized as EXACT FULL LINES and counted, because neither a
  # substring match nor a first-occurrence match is evidence of ownership:
  #   - `grep -F` matches marker text quoted inside a user's Markdown example,
  #     so an unrelated file reads as owned and its content gets replaced;
  #   - taking only the first begin/end of several spans a nested or duplicated
  #     pair, deleting everything between them and orphaning the extra marker.
  # Both were reproduced as real user-content loss. Ownership therefore requires
  # exactly one begin, exactly one end, in that order; anything else is
  # ambiguous and the file is left byte-identical.
  local scan begin_ct end_ct
  scan="$(marker_scan "$AGENTS_BEGIN" "$AGENTS_END" "$f")"

  # An unclosed fence makes "inside or outside a code block" undecidable, so
  # every marker below it is ambiguous. Fail safe rather than guess.
  if printf '%s\n' "$scan" | grep -qx 'UNCLOSED'; then
    echo "  WARNING: .codex/AGENTS.md has an unclosed fenced code block — left untouched."
    echo "           Close the fence, then re-run install."
    return 0
  fi

  begin_ct="$(printf '%s\n' "$scan" | grep -c '^B' || true)"; begin_ct="${begin_ct:-0}"
  end_ct="$(printf '%s\n' "$scan" | grep -c '^E' || true)"; end_ct="${end_ct:-0}"
  begin_n="$(printf '%s\n' "$scan" | grep '^B' | head -1 | tr -d 'B' || true)"
  end_n="$(printf '%s\n' "$scan" | grep '^E' | head -1 | tr -d 'E' || true)"

  # Ours by marker → idempotent replace. A repeat install is a no-op diff.
  if [ "$begin_ct" -eq 1 ] && [ "$end_ct" -eq 1 ] && [ "$begin_n" -lt "$end_n" ]; then
    tmp="$(mktemp)"
    {
      [ "$begin_n" -gt 1 ] && sed -n "1,$((begin_n - 1))p" "$f"
      echo "$AGENTS_BEGIN"; agents_block_body; echo "$AGENTS_END"
      sed -n "$((end_n + 1)),\$p" "$f"
    } > "$tmp"
    if cmp -s "$tmp" "$f"; then
      rm -f "$tmp"; echo "  .codex/AGENTS.md block already current (no-op)"
    else
      mv "$tmp" "$f"; echo "  refreshed the managed block in .codex/AGENTS.md"
    fi
    return 0
  fi

  # Any other marker shape — one-sided, duplicated, nested, or out of order —
  # is ambiguous. Guessing eats user content, so nothing is written.
  if [ "$begin_ct" -gt 0 ] || [ "$end_ct" -gt 0 ]; then
    echo "  WARNING: .codex/AGENTS.md has an ambiguous agent-comms marker shape" \
         "(begin=$begin_ct end=$end_ct) — left untouched."
    echo "           Leave exactly one begin marker above exactly one end marker,"
    echo "           each on its own line, then re-run install."
    return 0
  fi

  # Fence-aware for the same reason as the markers: a legacy block quoted in a
  # documentation fence is an example, not the project's live instructions.
  start_n="$(marker_scan '## Agent Communication Protocol' "$(printf '\001')" "$f" | grep '^B' | head -1 | tr -d 'B' || true)"
  if [ -z "$start_n" ]; then
    { echo ""; echo "$AGENTS_BEGIN"; agents_block_body; echo "$AGENTS_END"; } >> "$f"
    echo "  added the managed agent-comms block to .codex/AGENTS.md"
    return 0
  fi

  next_n="$(awk -v s="$start_n" 'NR > s && /^## / { print NR; exit }' "$f")"
  [ -n "$next_n" ] || next_n=$(( $(wc -l < "$f") + 1 ))

  if [ "$(sed -n "${start_n},$((next_n - 1))p" "$f" | norm_block)" = "$(legacy_block_body | norm_block)" ]; then
    tmp="$(mktemp)"
    {
      [ "$start_n" -gt 1 ] && sed -n "1,$((start_n - 1))p" "$f"
      echo "$AGENTS_BEGIN"; agents_block_body; echo "$AGENTS_END"
      sed -n "${next_n},\$p" "$f"
    } > "$tmp"
    mv "$tmp" "$f"
    echo "  migrated the legacy .codex/AGENTS.md section to a managed block"
  else
    echo "  NOTE: .codex/AGENTS.md's protocol section has been hand-edited — left untouched."
    echo "        To adopt the smaller managed block, wrap or replace that section with:"
    echo "          $AGENTS_BEGIN ... $AGENTS_END"
  fi
}

# Download templates if remote and this scope installs reusable assets.
if needs_templates && [ "$SOURCE" = "remote" ]; then
  echo "  source: remote ($REPO_RAW)"
  mkdir -p "$TEMPLATE_DIR/claude-commands"

  for f in $CLAUDE_COMMANDS; do
    curl -fsSL "$REPO_RAW/templates/claude-commands/$f" -o "$TEMPLATE_DIR/claude-commands/$f"
  done
  mkdir -p "$HELPER_SRC"
  for h in $HELPERS; do
    curl -fsSL "$REPO_RAW/helpers/$h" -o "$HELPER_SRC/$h"
  done
  mkdir -p "$FRAGMENT_SRC"
  for f in $LOOPSPEC_FRAGMENTS; do
    curl -fsSL "$REPO_RAW/docs/loopspec/fragments/$f" -o "$FRAGMENT_SRC/$f"
  done
else
  if needs_templates; then
    echo "  source: local ($TEMPLATE_DIR)"
  else
    echo "  source: templates not needed for project init"
  fi
fi

note_local_pin() {
  echo ""
  echo "  note: project-local copies are pinned — they shadow any global install and"
  echo "  do NOT pick up global updates. Re-run with --scope=local to refresh them, or"
  echo "  delete the .claude/commands/, .agents/skills/, .agents/loopspec-fragments/, and"
  echo "  .agent-comms/ copies to fall back to global."
}

case "$SCOPE" in
  local)
    install_local_assets
    init_project_state
    note_local_pin
    ;;
  global)
    install_global_assets
    warn_local_shadowing
    # Global scope installs reusable assets only — it never touches a project's
    # files, so an existing .codex/AGENTS.md keeps whatever block it has.
    echo ""
    echo "  note: .codex/AGENTS.md is per-project and was not touched."
    echo "        Re-run with --scope=project (or both) inside a repo to migrate it."
    ;;
  project)
    init_project_state
    warn_local_shadowing
    ;;
  both)
    install_global_assets
    init_project_state
    warn_local_shadowing
    ;;
esac

echo ""
echo "  done! installed:"
case "$SCOPE" in
  local)
    echo "    Project Claude: /auto, /ask, /clean-comms (plus /send-to-codex and /read-from-codex, used by the loop)"
    echo "    Project Codex:  \$read-from-claude, \$send-to-claude"
    ;;
  global)
    echo "    Global Claude: /auto, /ask, /clean-comms (plus /send-to-codex and /read-from-codex, used by the loop)"
    echo "    Global Codex:  \$read-from-claude, \$send-to-claude"
    echo "    Helpers:       $AGENT_COMMS_HOME/{comms.sh,runphase.sh,acp.sh}"
    ;;
  project)
    echo "    Project state: .comms/, .gitignore, .codex/AGENTS.md"
    ;;
  both)
    echo "    Global Claude: /auto, /ask, /clean-comms (plus /send-to-codex and /read-from-codex, used by the loop)"
    echo "    Global Codex:  \$read-from-claude, \$send-to-claude"
    echo "    Helpers:       $AGENT_COMMS_HOME/{comms.sh,runphase.sh,acp.sh}"
    echo "    Project state: .comms/, .gitignore, .codex/AGENTS.md"
    ;;
esac
echo ""
echo "  usage:"
echo "    Claude: 'implement X, then /send-to-codex'"
echo "    Codex:  '\$read-from-claude'"
echo "    Auto:   '/auto build feature X'   (add --plan for a capped approach round)"
echo ""
echo "  transport: ACP (no pane multiplexer required)"
