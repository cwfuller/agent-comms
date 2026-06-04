Orchestrate a fleet of cmux execution workspaces (`ws-1`, `ws-2`, …) from a control workspace (`ws-ctrl`). All shell logic lives in the installed `fleet.sh` helper — this command routes subcommands to it and interprets the output for the user.

## Assumptions

- Execution workspaces follow the pattern `<prefix>-<N>` (e.g. `ws-1`, `ws-2`). The prefix defaults to `ws` and is overridable via `FLEET_PREFIX=tide` in the environment. Each execution workspace has **two terminal panes**: pane 1 runs Claude Code (dispatch target), pane 2 runs Codex (review target). Pane ordering in `cmux tree` reflects setup order — position, not title text, identifies panes.
- The control workspace is the one invoking `/fleet` and is named `<prefix>-ctrl` by convention (not enforced — the fleet scan only matches `<prefix>-<N>` names).
- Comms use the repo-root `.comms/` directory with workspace-scoped filenames. Auto-loop replies carry `verdict: APPROVE | REQUEST_CHANGES` in their frontmatter — APPROVE is the protocol's only completion signal.
- Brief paths can be absolute or repo-relative.

## Instructions

1. **Resolve the fleet helper.** Local pin wins over global:
   ```bash
   FLEET_SH="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')/.agent-comms/fleet.sh"
   [ -x "$FLEET_SH" ] || FLEET_SH="$HOME/.agent-comms/fleet.sh"
   [ -x "$FLEET_SH" ] || echo "warning: agent-comms helpers not installed — re-run install.sh (global or local scope)" >&2
   ```

2. **Route the subcommand** — pass the user's arguments through to the helper. Supported: `status` (default), `dispatch <ws> <brief> [--plan-first] [--force]`, `dispatch-all <brief...> [--plan-first] [--force] [--yes]`, `harvest`, `clear <ws>`, `help`. Examples:
   ```bash
   "$FLEET_SH" status
   "$FLEET_SH" dispatch ws-2 docs/plans/caching.md
   "$FLEET_SH" dispatch-all brief1.md brief2.md            # dry-run: prints mapping only
   "$FLEET_SH" dispatch-all brief1.md brief2.md --yes      # fires the mapping (--force overrides cap/busy-check)
   "$FLEET_SH" harvest
   "$FLEET_SH" clear ws-2
   ```

3. **Interpret the output for the user** (don't just dump it).

### Reading `status`

- `claude=active codex=active` = full loop in flight (Claude rendering, Codex reviewing)
- `claude=active codex=idle` = Claude working, review not sent yet
- `claude=idle codex=idle` + recent archive `APPROVE` = **ready to harvest** (fire next brief here)
- `claude=idle codex=idle` + no archive = freshly-cleared or never-dispatched workspace
- `claude=stale codex=idle` = pane 1 has a `✳ <task>` title but no braille spinner and the latest
  archive is >10 min old. The label is residue from a finished loop — workspace is *probably* free.
  Two confounders to verify before dispatching:
  1. **Long shell await.** Claude may be sitting in a multi-hour subprocess (e.g. `godot --headless
     --baseline`) that doesn't render braille. The title shows the agent's last task name, not the
     bash command it's waiting on. Cross-check recent commits or ask the user.
  2. **Just-fired loop.** A loop fired in the last few seconds shows ✳+task before braille starts.
     Should resolve on the next status read.
- `in=N` > 0 means N message(s) from Codex waiting for Claude to read — `/read-from-codex` hasn't run
- `out=N` > 0 similar for outbound
- `owes=<agent> <N>m` (when present) = protocol-v2 thread state: who owes the next message and for how long. A large age with `claude=idle codex=idle` means a delivery nudge was likely dropped — check `comms.sh stalled` and re-deliver.

Report the table + a one-line verdict (e.g. "ws-2 and ws-5 are free; ws-1/3/4 in flight"). When
reporting `stale`, name the verification step rather than asserting idle.

### Dispatch safety (enforced by the helper — know what it does)

- **Per-target busy-check:** dispatch refuses to `/new` a workspace whose Claude pane shows a braille
  spinner (in-flight loop) unless `--force` is passed.
- **Fleet-wide preflight:** concurrency cap (`FLEET_MAX`, default 3) plus warnings for staged files
  and `.git/index.lock` in the shared worktree. The cap protects a shared on-disk working tree; if
  each workspace has its own `git worktree add`, bump `FLEET_MAX` or use `--force`.
- **dispatch-all is two-phase:** without `--yes` it only prints the brief→workspace mapping
  (workspaces with unread mail newer than their archive are excluded and reported). Show the
  mapping to the user and get explicit confirmation before re-running with `--yes`. At fire
  time each target is re-validated, so a workspace that went busy since the scan is skipped and
  reported, not clobbered. `--force` forwards to each per-target dispatch (cap/busy override).

## Notes

- **Pane ordering is load-bearing.** pane 1 = Claude, pane 2 = Codex in every `<prefix>-N` workspace. If a workspace was set up differently, dispatch will send the auto-* command to the wrong pane. Run `cmux tree --workspace <ref>` to verify if unsure.
- **No queue.** `/fleet` tracks current state but does not queue work. The user (or the agent in auto mode) decides what fires next based on `status` + `harvest` output.
- **Completion detection is inference, not ground truth.** The helper reads `cmux tree` titles + archive mtimes. If a loop wedges in a weird state (Claude responded but never sent; Codex approved but the file is still in `to-claude/`), `status` shows the symptoms but won't auto-diagnose. For wedged workspaces: inspect manually, then `clear <ws>` if needed.
- **Requirements:** cmux and python3 (the helper exits with a clear error if either is missing).
