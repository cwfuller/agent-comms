Ask Codex a one-off question via `.comms/to-codex/` and auto-deliver it. No review framing, no autonomous loop, no verdict — just "what do you think?"

Use this when you want Codex's judgment on a design choice, an open question, or a tradeoff — not a review of work you already did. For review-shaped handoffs use `/send-to-codex`. For autonomous loops use `/auto-plan`, `/auto-implement`, or `/auto-full`.

## Instructions

1. **Parse the argument as the question.** Anything after `/ask-codex` is the question text — use it verbatim as the `## Question` body. If the argument is empty, ask the user what they want to ask Codex before proceeding.

2. **Detect optional flags in the argument:**
   - `--with-diff` — attach `git diff <default-branch> --stat` (and `--name-only` if non-trivial) under `## Grounding`. Use when the question is grounded in current changes (e.g. "is this approach sound?"). Default: off.
   - `--with-files <path>[,<path>…]` — attach the listed file paths under `## Grounding` so Codex knows what to look at without reviewing them.

3. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

4. **Get the workspace name** for scoping. Run this block verbatim — cmux first, git branch second, repo dir last:
   ```bash
   WORKSPACE=""
   if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
     WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null \
       | grep -E 'workspace workspace:[0-9]+ "' \
       | head -1 \
       | sed 's/.*"\([^"]*\)".*/\1/' \
       | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   fi
   [ -n "$WORKSPACE" ] || WORKSPACE=$(git branch --show-current 2>/dev/null | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   [ -n "$WORKSPACE" ] || WORKSPACE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | sed 's#[/[:space:]]#-#g' | tr '[:upper:]' '[:lower:]')
   if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then
     case "$WORKSPACE" in
       main|master|trunk|develop)
         echo "warning: cmux is active but workspace resolved to '$WORKSPACE' — verify the cmux tree grep/sed still matches the tool's output format" >&2
         ;;
     esac
   fi
   echo "WORKSPACE=$WORKSPACE"
   ```

5. **Build the body.** Add a brief slug for the filename (kebab-case, ~3-5 words derived from the question). Sections:

   - `## Question` — the user's question, verbatim
   - `## Context` — short background: relevant files, links, constraints, what's been tried, what's *not* in scope. Skip the section entirely if there's nothing useful to add — better than padding it.
   - `## Current Thinking` — your draft answer or working hypothesis so Codex can validate, refine, or push back rather than start blank. Skip if you genuinely have no take.
   - `## Grounding` — only if `--with-diff` or `--with-files` is set, or you're attaching specific evidence (command output, error messages). Inline as fenced blocks; don't paste full file contents — list paths.

6. Write the message file to `$COMMS_ROOT/to-codex/`:
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_ask-<slug>.md`
   - Frontmatter:

```markdown
---
type: question
from: claude
timestamp: <ISO 8601>
branch: <current branch>
workspace: <workspace name>
cwd: <current working directory from pwd>
---
```

   No `workflow`, no `phase`, no `round`, no `max-rounds`, no `verdict`. Those are loop primitives — `/ask-codex` is single-shot.

7. **Verify before delivering.** Read back and confirm:
   - The `---` frontmatter delimiters are intact
   - Required fields exist: `type` (must be `question`), `from`, `timestamp`, `workspace`
   - The body has at least a non-empty `## Question` section
   If verification fails, fix the file before delivering.

8. **Auto-deliver via cmux when available.** If `cmux` or `CMUX_WORKSPACE_ID` is unavailable, skip auto-delivery and tell the user the verified file was written for manual pickup:
   ```bash
   if command -v cmux >/dev/null 2>&1 && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
     CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
     if [ -n "$CODEX_SURFACE" ]; then
       cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
     else
       echo "warning: could not find a Codex surface; message written for manual pickup"
     fi
   else
     echo "warning: cmux not available; message written for manual pickup"
   fi
   ```

9. Tell the user the question was sent and where to look for the reply (`.comms/to-claude/`). When Codex replies, use `/read-from-codex` to surface the answer.

## Notes

- **Codex's reply will use `type: response`** with no verdict — that's the consult-shaped answer. `/read-from-codex` already handles non-workflow messages in standard flow (parse, summarize, archive).
- **Don't stretch this command into review territory.** If you find yourself adding a "Review focus" section or asking Codex for blocking findings, you want `/send-to-codex` instead.
- **Single round, no loop.** If Codex's answer raises follow-up questions, fire another `/ask-codex` — don't try to chain rounds in one exchange.
