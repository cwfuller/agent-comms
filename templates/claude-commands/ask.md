Ask a supported agent a one-off question via `.comms/` and auto-deliver it — or, with no question at all, send an informal "thoughts?" consult on the current discussion. No review framing, no autonomous loop, no verdict.

Use this when you want a second opinion — a design choice, an open question, a tradeoff, or simply "thoughts?" on what is being discussed — not a review of work you already did. For review-shaped handoffs use `/send-to-codex`. For autonomous loops use `/auto-plan`, `/auto-implement`, or `/auto-full`.

## Instructions

1. **Parse the argument — target agent, then question.**
   - Known agents: the registry — `"$COMMS_SH" agents` (resolve the shared helper per step 4 FIRST when the first word could name an agent). The default target is `"$COMMS_SH" agents default`. Adding an agent touches only `.comms/config`; this template never hardcodes the set.
   - If the FIRST whitespace-delimited word of the argument, lowercased, is a known agent name, it names the target; everything after it is the question.
   - Otherwise the target is the DEFAULT agent and the ENTIRE ORIGINAL argument — including the unrecognized first word, unmodified — is the question. (Consequence: `/ask gemini is this sound?` sends the literal text "gemini is this sound?" to the default agent, because gemini has no registered backend.)
   - Hold the target in a named variable and use it in every later step — never hardcode an agent name below:
     ```bash
     TARGET="$("$COMMS_SH" agents default)"   # or the recognized first word
     ```

2. **Detect the transport.** Parse BOTH transport modifiers out of the question text —
   neither may remain in the payload:
   - `--via acp` / `--via mailbox` — an EXPLICIT override; honour it as given.
   - `--oneshot` — optional; forwarded to the helper to skip the warm session
     (stateless exec). Without it the consult is warm.

   **With no explicit `--via`, ASK the helper rather than guessing** (resolve
   `COMMS_SH` per step 4 first):
   ```bash
   TRANSPORT="$("$COMMS_SH" transport "$TARGET")"   # cmux | acp | headless | mailbox
   ```
   - `cmux` / `headless` / `mailbox` → the mailbox path below (steps 4-8).
   - `acp` → the synchronous ACP path in this step.

   The helper prefers a live pane when there is one, and falls back to ACP when there
   is not — because the alternative is writing a message into an inbox nobody is
   watching. That is not hypothetical: a real consult was stranded exactly that way
   (`RESULT: manual`, no Codex surface running). Say which transport was used when it
   is not the pane, so an inline answer is never mistaken for a delivered message.
   Never re-implement surface detection here; one decision point lives in the helper.
   - Resolve the helper next to comms.sh: `ACP_SH="$(dirname "$COMMS_SH")/acp.sh"`
     (resolve `COMMS_SH` per step 4 first).
   - Run the consult and present the answer directly — no message file, no
     delivery, no `/read-from-codex`. Forward `--oneshot` if and only if the user
     passed it:
     ```bash
     "$ACP_SH" consult "$TARGET" --oneshot --file "<question/excerpt file>"   # user passed --oneshot
     "$ACP_SH" consult "$TARGET" --file "<question/excerpt file>"             # default: warm session
     ```
     (Bare words work too for short questions. Thoughts mode writes its excerpt to
     a temp file first — same payload contract.)
   - The consult is WARM by default (a named per-repo session), so follow-ups pay
     only the token delta. The helper prints acpx's token-usage line after the
     answer.
   - If the helper fails (Node missing, unsupported agent, timeout), it says why
     and names the fallback: rerun without `--via acp` — the mailbox path below is
     always available. Do NOT retry the ACP path on the same failure.
   - All three registered agents have ACP profiles (codex, claude, grok →
     `grok-build`). An agent without one fails closed and names the mailbox fallback.

3. **Choose the mode.** If the question (after removing the agent word, when present) is EMPTY — bare `/ask`, or `/ask codex` alone — build an informal **thoughts consult** (step 6). Otherwise build an **explicit question** (step 5).

4. **Resolve the shared helper** — handles comms root, workspace name, validation, and delivery. Local pin wins over global:
   ```bash
   COMMS_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || COMMS_SH="$HOME/.agent-comms/comms.sh"
   [ -x "$COMMS_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   COMMS_ROOT="$("$COMMS_SH" root)"
   WORKSPACE="$("$COMMS_SH" workspace)"
   echo "COMMS_ROOT=$COMMS_ROOT  WORKSPACE=$WORKSPACE"
   ```

5. **Explicit question — build the body.** Detect optional flags first:
   - `--with-diff` — attach `git diff <default-branch> --stat` (and `--name-only` if non-trivial) under `## Grounding`. Use when the question is grounded in current changes. Default: off.
   - `--with-files <path>[,<path>…]` — attach the listed file paths under `## Grounding` so the agent knows what to look at without reviewing them.

   Add a brief slug for the filename (kebab-case, ~3-5 words derived from the question; the filename component becomes `ask-<slug>`). Sections:
   - `## Question` — the user's question, verbatim
   - `## Context` — short background: relevant files, links, constraints, what's been tried, what's *not* in scope. Skip the section entirely if there's nothing useful to add — better than padding it.
   - `## Current Thinking` — your draft answer or working hypothesis so the agent can validate, refine, or push back rather than start blank. Skip if you genuinely have no take.
   - `## Grounding` — only if `--with-diff` or `--with-files` is set, or you're attaching specific evidence (command output, error messages). Inline as fenced blocks; don't paste full file contents — list paths.

6. **Thoughts consult — build the body.** The payload is a verbatim excerpt of the current discussion, assembled under this contract (precedence in this order):
   1. **Eligible pair** — the most recent COMPLETED user-message → assistant-answer exchange that occurred BEFORE this `/ask` invocation. "User message" means the user's question OR request — imperative phrasing with no question mark qualifies; select the exchange being discussed, not punctuation. The `/ask` invocation itself is never the eligible user message.
   2. **Floor — overrides the cap.** The eligible pair goes into `## Context` verbatim even when the pair alone exceeds the size cap. Never truncate mid-message; never drop either half of the pair.
   3. **Soft cap ~4 KB.** Add older COMPLETE turns (working from newest toward older) only while the total stays under the cap. Add or omit turns whole.
   4. **No eligible pair** (first-turn invocation, or no completed exchange yet): FAIL CLOSED — do not fabricate context and do not improvise a summary. Tell the user there is no prior discussion to excerpt, ask what they want to send, and send nothing.

   Sections:
   - `## Context` — the excerpt, verbatim, oldest turn first, each turn labeled (`**User:**` / `**Assistant:**`)
   - `## Question` — literally: "Thoughts? Informal take requested on the discussion above."
   - SKIP `## Current Thinking` — the assistant's take is already inside the excerpt verbatim; a second framing would re-introduce the summary bias the verbatim excerpt exists to avoid. Include it only for something genuinely new that is not in the excerpt.

   Filename slug: `thoughts` (the filename component becomes `ask-thoughts`).

7. **Write the message file — non-interpolating writer REQUIRED.**
   - Path: `$COMMS_ROOT/to-$TARGET/` — `mkdir -p` it first (registry agents each own an inbox)
   - Filename: `<workspace>_YYYY-MM-DDTHH-MM-SS_ask-<slug>-$RANDOM.md` (the `$RANDOM` suffix prevents same-second filename collisions; thoughts mode yields `ask-thoughts`)
   - Frontmatter:

```markdown
---
type: question
from: claude
timestamp: <ISO 8601>
branch: <current branch>
head_sha: <git rev-parse HEAD>
workspace: <workspace name>
cwd: <current working directory from pwd>
message_id: <the filename, without .md>
---
```

   No `workflow`, no `phase`, no `round`, no `max-rounds`, no `verdict`. Those are loop primitives — `/ask` is single-shot.

   Write the assembled message with a **non-interpolating file-write tool** (the Write tool or equivalent). This is REQUIRED, not preferred: the payload can contain arbitrary verbatim discussion, so any fixed heredoc delimiter can appear inside it on a line of its own — the heredoc closes early and the shell parses the remainder before `validate` can refuse it. (docs/advisories.md 2026-07-06 also records a live headless heredoc hang where the Write tool succeeded immediately.) A shell heredoc is permitted ONLY as a last resort with a delimiter PROVEN absent from the entire rendered message — generate a unique delimiter and check it against the full content first; never use a fixed delimiter blindly. Either way, sanity-check with `head -3` on the file before sending.

8. **Validate and deliver** — `send` refuses malformed messages and degrades to manual pickup without cmux:
   ```bash
   "$COMMS_SH" send --to "$TARGET" "<path of the message file you wrote>"
   ```
   On `RESULT: blocked`, execute the exact `RECOVER:` line once; relay only the final
   non-`delivered` result.

9. Tell the user the message was sent and where to look for the reply (`.comms/to-claude/` — replies come TO claude regardless of target). When the reply arrives, use `/read-from-codex` to surface the answer (it reads any sender). Headless-only targets (e.g. grok) answer via a detached runphase turn automatically.

## Notes

- **Headless delivery (experimental).** With `COMMS_DELIVERY=headless` set, `send` spawns the target agent's turn as a detached subprocess instead of nudging a pane.
  <!-- loopspec:fragment result-spawned-exception -->
  Exception — `RESULT: spawned` (headless mode, `COMMS_DELIVERY=headless`): the peer agent's turn is running detached; await the printed run dir as a background task (`.../runphase.sh await "<run dir>"`), then `/read-from-codex`. A non-zero await means the turn failed or timed out (check its `result.json`) — report that instead of waiting for a reply.
  <!-- /loopspec:fragment -->
- **The reply will use `type: response`** with no verdict — that's the consult-shaped answer. `/read-from-codex` already handles non-workflow messages in standard flow (parse, summarize, archive).
- **Don't stretch this command into review territory.** If you find yourself adding a "Review focus" section or asking for blocking findings, you want `/send-to-codex` instead.
- **Single round, no loop.** If the answer raises follow-up questions, fire another `/ask` — don't try to chain rounds in one exchange.
