#!/bin/bash
set -euo pipefail

# agent-comms installer
# Sets up Claude Code <-> Codex autonomous communication via cmux
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
#   or: git clone ... && cd agent-comms && ./install.sh

REPO_RAW_DEFAULT="https://raw.githubusercontent.com/cwfuller/agent-comms/main"
REPO_RAW="${AGENT_COMMS_REPO_RAW:-$REPO_RAW_DEFAULT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null || echo "")"
CLAUDE_COMMANDS_DIR="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
CLAUDE_COMMANDS="send-to-codex.md read-from-codex.md ask-codex.md auto-plan.md auto-implement.md auto-full.md clean-comms.md fleet.md"
CODEX_SKILLS="read-from-claude send-to-claude"
SCOPE=""

usage() {
  cat <<USAGE
Usage: install.sh [--scope=local|global|project|both]

Scopes:
  local    Install commands/skills into the current project, plus project state.
  global   Install reusable Claude commands and Codex skills into your home dir.
  project  Initialize only repo-local state (.comms, .gitignore, .codex/AGENTS.md).
  both     Install global commands/skills and initialize this project.

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
else
  SOURCE="remote"
  TEMPLATE_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMPLATE_DIR"' EXIT
fi

echo "agent-comms: installing Claude <-> Codex communication protocol"
echo ""

choose_scope
validate_scope
echo "  scope: $SCOPE"

# Check prerequisites
if ! command -v cmux &>/dev/null; then
  echo "  warning: cmux not found. Install from https://cmux.com"
  echo "  (comms files will be installed, but auto-delivery requires cmux)"
  echo ""
fi

# Find project root (git root)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo "  project: $PROJECT_ROOT"

needs_templates() {
  case "$SCOPE" in
    local|global|both) return 0 ;;
    project) return 1 ;;
  esac
}

install_global_assets() {
  echo ""
  echo "  installing global Claude commands..."
  mkdir -p "$CLAUDE_COMMANDS_DIR"
  for f in $CLAUDE_COMMANDS; do
    cp "$TEMPLATE_DIR/claude-commands/$f" "$CLAUDE_COMMANDS_DIR/$f"
  done

  echo "  installing global Codex skills..."
  for skill in $CODEX_SKILLS; do
    mkdir -p "$CODEX_SKILLS_DIR/$skill"
    cp "$TEMPLATE_DIR/codex-skills/$skill/SKILL.md" "$CODEX_SKILLS_DIR/$skill/SKILL.md"
  done
}

install_local_assets() {
  echo ""
  echo "  installing project-local Claude commands..."
  mkdir -p "$PROJECT_ROOT/.claude/commands"
  for f in $CLAUDE_COMMANDS; do
    cp "$TEMPLATE_DIR/claude-commands/$f" "$PROJECT_ROOT/.claude/commands/$f"
  done

  echo "  installing project-local Codex skills..."
  for skill in $CODEX_SKILLS; do
    mkdir -p "$PROJECT_ROOT/.agents/skills/$skill"
    cp "$TEMPLATE_DIR/codex-skills/$skill/SKILL.md" "$PROJECT_ROOT/.agents/skills/$skill/SKILL.md"
  done
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
    for skill in $CODEX_SKILLS; do
      [ -f "$CODEX_SKILLS_DIR/$skill/SKILL.md" ] && global_present=true && break
    done
  fi
  [ "$global_present" = false ] && return

  local shadowed=""
  for f in $CLAUDE_COMMANDS; do
    [ -f "$PROJECT_ROOT/.claude/commands/$f" ] && shadowed="$shadowed .claude/commands/$f"
  done
  for skill in $CODEX_SKILLS; do
    [ -f "$PROJECT_ROOT/.agents/skills/$skill/SKILL.md" ] && shadowed="$shadowed .agents/skills/$skill/SKILL.md"
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

  # Add .comms/ to .gitignore if not already present
  if [ -f "$PROJECT_ROOT/.gitignore" ]; then
    if ! grep -qF '.comms/' "$PROJECT_ROOT/.gitignore"; then
      echo "" >> "$PROJECT_ROOT/.gitignore"
      echo "# Local agent communication" >> "$PROJECT_ROOT/.gitignore"
      echo ".comms/" >> "$PROJECT_ROOT/.gitignore"
      echo "  added .comms/ to .gitignore"
    else
      echo "  .gitignore already has .comms/"
    fi
  else
    echo "# Local agent communication" > "$PROJECT_ROOT/.gitignore"
    echo ".comms/" >> "$PROJECT_ROOT/.gitignore"
    echo "  created .gitignore with .comms/"
  fi

  # Add protocol section to .codex/AGENTS.md if not already present
  AGENTS_MD="$PROJECT_ROOT/.codex/AGENTS.md"
  if [ -f "$AGENTS_MD" ]; then
    if ! grep -qF 'Agent Communication Protocol' "$AGENTS_MD"; then
      cat >> "$AGENTS_MD" << 'PROTOCOL'

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
      echo "  added protocol section to .codex/AGENTS.md"
    else
      echo "  .codex/AGENTS.md already has protocol section"
    fi
  else
    cat > "$AGENTS_MD" << 'PROTOCOL'
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
    echo "  created .codex/AGENTS.md with protocol section"
  fi
}

# Download templates if remote and this scope installs reusable assets.
if needs_templates && [ "$SOURCE" = "remote" ]; then
  echo "  source: remote ($REPO_RAW)"
  mkdir -p "$TEMPLATE_DIR/claude-commands" "$TEMPLATE_DIR/codex-skills/read-from-claude" "$TEMPLATE_DIR/codex-skills/send-to-claude"

  for f in $CLAUDE_COMMANDS; do
    curl -fsSL "$REPO_RAW/templates/claude-commands/$f" -o "$TEMPLATE_DIR/claude-commands/$f"
  done
  for skill in $CODEX_SKILLS; do
    curl -fsSL "$REPO_RAW/templates/codex-skills/$skill/SKILL.md" -o "$TEMPLATE_DIR/codex-skills/$skill/SKILL.md"
  done
else
  if needs_templates; then
    echo "  source: local ($TEMPLATE_DIR)"
  else
    echo "  source: templates not needed for project init"
  fi
fi

case "$SCOPE" in
  local)
    install_local_assets
    init_project_state
    ;;
  global)
    install_global_assets
    warn_local_shadowing
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
    echo "    Project Claude: /send-to-codex, /read-from-codex, /ask-codex, /auto-plan, /auto-implement, /auto-full, /clean-comms, /fleet"
    echo "    Project Codex:  \$read-from-claude, \$send-to-claude"
    ;;
  global)
    echo "    Global Claude: /send-to-codex, /read-from-codex, /ask-codex, /auto-plan, /auto-implement, /auto-full, /clean-comms, /fleet"
    echo "    Global Codex:  \$read-from-claude, \$send-to-claude"
    ;;
  project)
    echo "    Project state: .comms/, .gitignore, .codex/AGENTS.md"
    ;;
  both)
    echo "    Global Claude: /send-to-codex, /read-from-codex, /ask-codex, /auto-plan, /auto-implement, /auto-full, /clean-comms, /fleet"
    echo "    Global Codex:  \$read-from-claude, \$send-to-claude"
    echo "    Project state: .comms/, .gitignore, .codex/AGENTS.md"
    ;;
esac
echo ""
echo "  usage:"
echo "    Claude: 'implement X, then /send-to-codex'"
echo "    Codex:  '\$read-from-claude'"
echo "    Auto:   '/auto-plan build feature X'"
echo ""
echo "  optional: cmux (https://cmux.com) for auto-delivery between panes"
