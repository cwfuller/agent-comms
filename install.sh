#!/bin/bash
set -euo pipefail

# agent-comms installer
# Sets up Claude Code <-> Codex autonomous communication via cmux
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash
#   or: git clone ... && cd agent-comms && ./install.sh

REPO_RAW_DEFAULT="https://raw.githubusercontent.com/cwfuller/agent-comms/main"
REPO_RAW="${AGENT_COMMS_REPO_RAW:-$REPO_RAW_DEFAULT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null || echo "")"

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

# Check prerequisites
if ! command -v cmux &>/dev/null; then
  echo "  warning: cmux not found. Install from https://cmux.com"
  echo "  (comms files will be installed, but auto-delivery requires cmux)"
  echo ""
fi

# Find project root (git root)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo "  project: $PROJECT_ROOT"

# Download templates if remote
if [ "$SOURCE" = "remote" ]; then
  echo "  source: remote ($REPO_RAW)"
  mkdir -p "$TEMPLATE_DIR/claude-commands" "$TEMPLATE_DIR/codex-skills/read-from-claude" "$TEMPLATE_DIR/codex-skills/send-to-claude"

  for f in send-to-codex.md read-from-codex.md auto-plan.md auto-implement.md auto-full.md clean-comms.md; do
    curl -fsSL "$REPO_RAW/templates/claude-commands/$f" -o "$TEMPLATE_DIR/claude-commands/$f"
  done
  curl -fsSL "$REPO_RAW/templates/codex-skills/read-from-claude/SKILL.md" -o "$TEMPLATE_DIR/codex-skills/read-from-claude/SKILL.md"
  curl -fsSL "$REPO_RAW/templates/codex-skills/send-to-claude/SKILL.md" -o "$TEMPLATE_DIR/codex-skills/send-to-claude/SKILL.md"
else
  echo "  source: local ($TEMPLATE_DIR)"
fi

# Create directories
echo ""
echo "  creating directories..."
mkdir -p "$PROJECT_ROOT/.comms/to-codex"
mkdir -p "$PROJECT_ROOT/.comms/to-claude"
mkdir -p "$PROJECT_ROOT/.comms/archive"
mkdir -p "$PROJECT_ROOT/.claude/commands"
mkdir -p "$PROJECT_ROOT/.agents/skills/read-from-claude"
mkdir -p "$PROJECT_ROOT/.agents/skills/send-to-claude"
mkdir -p "$PROJECT_ROOT/.codex"

# Copy Claude commands
echo "  installing claude commands..."
for f in send-to-codex.md read-from-codex.md auto-plan.md auto-implement.md auto-full.md clean-comms.md; do
  cp "$TEMPLATE_DIR/claude-commands/$f" "$PROJECT_ROOT/.claude/commands/$f"
done

# Copy Codex skills
echo "  installing codex skills..."
cp "$TEMPLATE_DIR/codex-skills/read-from-claude/SKILL.md" "$PROJECT_ROOT/.agents/skills/read-from-claude/SKILL.md"
cp "$TEMPLATE_DIR/codex-skills/send-to-claude/SKILL.md" "$PROJECT_ROOT/.agents/skills/send-to-claude/SKILL.md"

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

echo ""
echo "  done! installed:"
echo "    Claude: /send-to-codex, /read-from-codex, /auto-plan, /auto-implement, /auto-full, /clean-comms"
echo "    Codex:  \$read-from-claude, \$send-to-claude"
echo ""
echo "  usage:"
echo "    Claude: 'implement X, then /send-to-codex'"
echo "    Codex:  '\$read-from-claude'"
echo "    Auto:   '/auto-plan build feature X'"
echo ""
echo "  optional: cmux (https://cmux.com) for auto-delivery between panes"
