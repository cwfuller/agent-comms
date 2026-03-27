Read and act on messages from Codex in `.comms/to-claude/`.

## Instructions

1. **Resolve the comms root** to the main repo (not a worktree):
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms"
   ```

2. **Get the workspace name** for filtering:
   ```bash
   WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
   ```

3. **List matching messages** using this exact command:
   ```bash
   COMMS_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')/.comms" && WORKSPACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'workspace:' | head -1 | sed 's/.*"\(.*\)".*/\1/' | tr ' ' '-' | tr '[:upper:]' '[:lower:]') && find "$COMMS_ROOT/to-claude" -maxdepth 1 -type f -name "${WORKSPACE}_*" | sort -r
   ```
   If no files are returned, tell the user there are no messages from Codex for this workspace.

4. Read the most recent matching message (or all if user asks).

5. **Validate the message.** Before acting on it, check:
   - The file starts with `---` and has a closing `---` (valid frontmatter)
   - Required fields are present: `type`, `from`, `timestamp`
   - If `workflow` is present: `phase`, `round`, `max-rounds`, `verdict` must also be present
   - The body below frontmatter is not empty
   If validation fails, **do not archive** the message. Tell the user: "Received a malformed message from Codex: [describe what's wrong]. File: [filename]". In autonomous mode, send an error reply back to Codex requesting a clean resend.

6. **Check for worktree context.** If the message has a `cwd:` field that differs from your current directory, `cd` to that path before reading or modifying any files. This ensures you're working in the correct worktree.

7. **Check for autonomous workflow mode.** Parse the `workflow` field from frontmatter. If it exists, follow the autonomous rules below. If not, follow the standard (manual) flow.

---

### Standard (manual) flow — no `workflow` field

1. Parse the message and summarize what Codex is saying
2. **Auto-archive:** Move processed message(s) to `$COMMS_ROOT/archive/`
3. Ask the user how to proceed:
   - "Address all findings" — work through each item
   - "Address specific items" — let user pick
   - "Acknowledge only" — just mark as read
4. After addressing feedback, optionally `/send-to-codex`

---

### Autonomous flow — `workflow` field present

**Check termination conditions first:**

1. **If verdict is `APPROVE`:**
   - Treat `APPROVE` as ship-ready. Codex may still include advisory notes; those do not reopen the loop.
   - If `workflow: auto-full` and `phase: plan` → **Transition to implement phase:**
     - Notify user: "Plan approved after N rounds. Starting implementation..."
     - Implement the approved plan
     - Send to Codex with updated frontmatter: `phase: implement`, `round: 1`, same `workflow` and `max-rounds`
     - Auto-deliver via cmux
   - Otherwise → **Stop. Notify user:** "Approved after N rounds." Archive the message.

2. **If `round >= max-rounds`:**
   - **Stop. Escalate to user:** "Max rounds (N) reached. Remaining blocking issues from Codex:" then list the unresolved blocking findings.
   - Archive the message.

3. **If verdict is `REQUEST_CHANGES` and round < max-rounds:**
   - **Auto-address all blocking findings** from Codex's message
   - Advisory findings are optional. Fix them when they are cheap, clearly correct, or naturally part of the same change, but do not extend the loop just to polish non-blocking issues.
   - For plan workflows: refine the plan based on findings
   - For implement workflows: fix the code based on findings
   - **Send back to Codex** to `$COMMS_ROOT/to-codex/`:
     - Filename: `${WORKSPACE}_YYYY-MM-DDTHH-MM-SS_round-N.md` (use the workspace name from step 2 and current round number)
     - Increment `round` by 1
     - Keep same `workflow`, `phase`, `max-rounds`
     - **Keep the message body focused on stable context, not fix narration.** Do NOT narrate what you fixed per finding — that anchors the reviewer on verification instead of re-review. Instead include:
       - The latest Codex findings bundle from the prior round under a clear heading like `## Prior review context`, framed as stable context rather than an exhaustive checklist
       - For plan: the full updated plan content (so Codex can re-read it fresh)
       - For implement: `git diff --stat` showing changed files
       - **Stable metadata** (always include): what validation ran (typecheck, tests, lint), whether they passed, and any non-obvious constraints or gotchas
       - Brief one-line note: "Addressed N findings from round X. Please re-review holistically."
   - **Auto-deliver via cmux:**
     ```bash
     CODEX_SURFACE=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" | grep 'surface:' | grep '\[terminal\]' | grep -v '◀ here' | head -1 | sed 's/.*\(surface:[0-9]*\).*/\1/')
     cmux send --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" '$read-from-claude' && sleep 0.5 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" escape && sleep 0.3 && cmux send-key --surface "$CODEX_SURFACE" --workspace "$CMUX_WORKSPACE_ID" enter
     ```
   - **Auto-archive** the incoming message to `$COMMS_ROOT/archive/`

**Review protocol for autonomous loops:**
- Default to a pass-oriented loop. `REQUEST_CHANGES` means blocking issues only.
- Advisory notes can appear with `APPROVE`; they should not force another round by themselves.
- Stable review context is useful. Fix narration is not.

---

**If an argument is provided**, treat it as a filter (e.g., "only the latest", "all messages", a specific filename).
