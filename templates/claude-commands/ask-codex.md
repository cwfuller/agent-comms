Ask Codex a one-off question via `.comms/to-codex/` and auto-deliver it. No review framing, no autonomous loop, no verdict — just "what do you think?"

Use this when you want Codex's judgment on a design choice, an open question, or a tradeoff — not a review of work you already did. For review-shaped handoffs use `/send-to-codex`. For autonomous loops use `/auto-plan`, `/auto-implement`, or `/auto-full`.

## Instructions

1. **Parse the argument as the question.** Anything after `/ask-codex` is the question text — use it verbatim as the `## Question` body. If the argument is empty, ask the user what they want to ask Codex before proceeding.

2. **Detect optional flags in the argument:**
   - `--with-diff` — attach `git diff <default-branch> --stat` (and `--name-only` if non-trivial) under `## Grounding`. Use when the question is grounded in current changes (e.g. "is this approach sound?"). Default: off.
   - `--with-files <path>[,<path>…]` — attach the listed file paths under `## Grounding` so Codex knows what to look at without reviewing them.

3. **Resolve the shared helper** — handles comms root, workspace name, validation, and delivery. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```

4. **Build the body.** Add a brief slug for the filename (kebab-case, ~3-5 words derived from the question). Sections:

   - `## Question` — the user's question, verbatim
   - `## Context` — short background: relevant files, links, constraints, what's been tried, what's *not* in scope. Skip the section entirely if there's nothing useful to add — better than padding it.
   - `## Current Thinking` — your draft answer or working hypothesis so Codex can validate, refine, or push back rather than start blank. Skip if you genuinely have no take.
   - `## Grounding` — only if `--with-diff` or `--with-files` is set, or you're attaching specific evidence (command output, error messages). Inline as fenced blocks; don't paste full file contents — list paths.

5. **Write the message file** to `$COMMS_ROOT/to-codex/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_ask-<slug>-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions)
   - Write with a quoted heredoc (`<<'EOF'`) or a non-interpolating tool
   - Frontmatter:

```markdown
---
type: question
from: claude
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace name>
cwd: <current working directory from pwd>
message_id: <the filename, without .md>
---
```

   No `workflow`, no `phase`, no `round`, no `max-rounds`, no `verdict`. Those are loop primitives — `/ask-codex` is single-shot.

6. **Validate and deliver** — `send` refuses malformed messages and degrades to manual pickup without cmux:
   ```bash
   "$COMMS_SH" send --to codex "<path of the message file you wrote>"
   ```
   Relay the final `RESULT:` line to the user verbatim whenever it is not `delivered`.

7. Tell the user the question was sent and where to look for the reply (`.comms/to-claude/`). When Codex replies, use `/read-from-codex` to surface the answer.

## Notes

- **Codex's reply will use `type: response`** with no verdict — that's the consult-shaped answer. `/read-from-codex` already handles non-workflow messages in standard flow (parse, summarize, archive).
- **Don't stretch this command into review territory.** If you find yourself adding a "Review focus" section or asking Codex for blocking findings, you want `/send-to-codex` instead.
- **Single round, no loop.** If Codex's answer raises follow-up questions, fire another `/ask-codex` — don't try to chain rounds in one exchange.
