**DEPRECATED** — `/ask-codex` is now a thin alias for `/ask codex`; it will be removed in the next release. Mention this to the user once: they should switch to `/ask`.

## Instructions

1. **Resolve the canonical `/ask` command file** — project install wins over global:
   - `.claude/commands/ask.md` under the current project root, else `~/.claude/commands/ask.md`.
2. **If NEITHER file exists, FAIL CLOSED:** report "agent-comms install is stale or partial — re-run install.sh" and stop. Do not improvise the old `/ask-codex` behavior from memory.
3. **Otherwise follow the resolved `ask.md` instructions exactly** as if the user had typed `/ask codex <the same arguments>` — target pinned to codex; an empty argument means the thoughts-consult mode.
