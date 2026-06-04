Orchestrate a fleet of cmux execution workspaces (`ws-1`, `ws-2`, …) from a control workspace (`ws-ctrl`). Wraps `cmux tree` + filesystem reads + `cmux send` so a single slash command dispatches briefs, reports status, and harvests completed loops without manual pane-hopping.

## Assumptions

- Execution workspaces follow the pattern `<prefix>-<N>` (e.g. `ws-1`, `ws-2`). The prefix defaults to `ws` and is overridable via `FLEET_PREFIX=tide` (or whatever) in the environment. Each execution workspace has **two terminal panes**: pane 1 runs Claude Code (dispatch target), pane 2 runs Codex (review target). Pane ordering in `cmux tree` reflects setup order — this skill uses position, not title text, to identify panes.
- The control workspace is the one invoking `/fleet` and is named `<prefix>-ctrl` by convention (not enforced — `/fleet` simply skips itself when scanning for executors).
- Comms use the repo-root `.comms/` directory, with workspace-scoped filenames (e.g. `ws-1_2026-04-21T22-41-25_auto-implement.md`). Archive at `.comms/archive/`. Auto-loop replies carry `verdict: APPROVE | REQUEST_CHANGES` in their frontmatter.
- Brief paths can be absolute or repo-relative. `/fleet` doesn't impose a directory convention.

## Instructions

1. **Parse the subcommand** from the first argument word. Supported: `status`, `dispatch`, `dispatch-all`, `harvest`, `clear`, `help`. If no arg, default to `status`. Capture the raw argument text once for the blocks below:

   ```bash
   # Claude Code replaces the ARGUMENTS placeholder on the next line with the raw /fleet
   # argument text at render time.
   # EDITOR NOTE: never write bare dollar-digit tokens (dollar-zero through dollar-nine)
   # or dollar-star in this file's code blocks — slash-command argument substitution
   # clobbers them at render time. awk fields are written $(0)/$(2); bash functions take
   # input via named FLEET_* variables instead of positional params.
   FLEET_ARGS="$ARGUMENTS"
   ```

2. **Resolve shared vars** up front — every subcommand needs these. **Shell state does not persist across separate tool calls:** when executing a subcommand, paste this block (plus the Preflight block for dispatch paths) into the *same* shell invocation as the subcommand's block.

   ```bash
   FLEET_PREFIX="${FLEET_PREFIX:-ws}"
   REPO_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
   COMMS_ROOT="$REPO_ROOT/.comms"
   REPO_NAME="$(basename "$REPO_ROOT")"
   # Build a workspace-name → workspace:ref map for all <prefix>-N workspaces.
   # list-workspaces output: "* workspace:88  ws-ctrl  [selected]"
   #                         "  workspace:79  ws-1"
   FLEET_LIST="$(cmux list-workspaces 2>/dev/null \
     | sed 's/^\* //' \
     | awk -v pfx="$FLEET_PREFIX" '$(0) ~ "workspace:[0-9]+[[:space:]]+" pfx "-[0-9]+" {print $(2), $(1)}' \
     | sort -V)"
   # FLEET_LIST is now lines like: "ws-1 workspace:79"
   echo "$FLEET_LIST"
   ```

3. **Route to subcommand**. Each subcommand section below describes the work; run its bash block and produce the reported output to the user.

---

### `/fleet status`

Produce a table of what each `<prefix>-N` workspace is doing right now. Parse `cmux tree --workspace <ref>` for each workspace; extract surface titles for pane 1 (Claude) and pane 2 (Codex); detect spinner prefixes (braille range `U+2800`–`U+28FF`) to distinguish active vs idle; cross-reference `.comms/archive/<workspace>_*.md` for the latest round + workflow metadata.

```bash
echo "$FLEET_LIST" | while read -r name ref; do
  [ -z "$name" ] && continue
  TREE="$(cmux tree --workspace "$ref" 2>/dev/null)"
  # Extract the Nth surface line by pane order. Pane 1 surface = Claude.
  CLAUDE_LINE="$(echo "$TREE" | awk '/├── pane|└── pane/{n++} n==1 && /surface surface:/{print; exit}')"
  CODEX_LINE="$(echo "$TREE"  | awk '/├── pane|└── pane/{n++} n==2 && /surface surface:/{print; exit}')"
  CLAUDE_TITLE="$(echo "$CLAUDE_LINE" | sed -n 's/.*\[terminal\] "\([^"]*\)".*/\1/p')"
  CODEX_TITLE="$( echo "$CODEX_LINE"  | sed -n 's/.*\[terminal\] "\([^"]*\)".*/\1/p')"

  # Active detection — classify by LEADING GLYPH first, then text. Rules:
  #   * Braille-range prefix (U+2800–U+28FF): ALWAYS active — Claude Code /
  #     Codex render a braille spinner whenever the app is processing.
  #   * Bare "Claude Code" / repo-name / empty: idle.
  #   * Other prefix glyph (`✳`, `•`, etc.) + task name: AMBIGUOUS — the title
  #     may be stale residue from a finished loop. Returns "task" here; the
  #     call site corroborates against archive mtime + Codex pane state to
  #     decide whether this is `active` (mid-loop) or `stale` (label leftover).
  # Input via FLEET_TITLE (named var, not positional — see EDITOR NOTE in step 1).
  classify_title() {
    python3 -c 'import sys, re
s = sys.argv[1].lstrip()
repo = sys.argv[2]
if not s:
    print("bare"); sys.exit()
if 0x2800 <= ord(s[0]) <= 0x28FF:
    print("spin"); sys.exit()
s = re.sub(r"^[^\w\s]+\s+", "", s)
print("bare" if s in ("", "Claude Code", repo) else "task")' "$FLEET_TITLE" "$REPO_NAME" 2>/dev/null
  }
  FLEET_TITLE="$CLAUDE_TITLE"; CLAUDE_TYPE="$(classify_title)"
  FLEET_TITLE="$CODEX_TITLE";  CODEX_TYPE="$(classify_title)"

  # Composite state — one of: active | idle | stale.
  # ✳+task only counts as `active` if corroborated by braille on Codex OR
  # an archive mtime within the last 10 min. Otherwise it's `stale` (the
  # title is residue; the workspace is likely free, but verify before
  # dispatching — could also be Claude in a long shell await with no
  # spinner, e.g. a multi-hour `godot --headless --baseline`).
  NOW=$(date +%s)
  # Inputs via FLEET_PANE_TYPE / FLEET_ARCHIVE_MT / FLEET_OTHER_TYPE (named vars).
  resolve_state() {
    case "$FLEET_PANE_TYPE" in
      spin) echo active ;;
      bare) echo idle ;;
      task)
        local age=$(( NOW - ${FLEET_ARCHIVE_MT:-0} ))
        if [ "$FLEET_OTHER_TYPE" = spin ] || [ "$age" -lt 600 ]; then
          echo active
        else
          echo stale
        fi
        ;;
    esac
  }

  # Latest archive entry — surfaces round + workflow + verdict.
  LATEST="$(find "$COMMS_ROOT/archive" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null | sort | tail -1)"
  if [ -n "$LATEST" ]; then
    ROUND="$(grep -m1 '^round:'      "$LATEST" | awk '{print $(2)}')"
    MAXR=" $(grep -m1 '^max-rounds:' "$LATEST" | awk '{print $(2)}')"
    WFLOW="$(grep -m1 '^workflow:'   "$LATEST" | awk '{print $(2)}')"
    PHASE="$(grep -m1 '^phase:'      "$LATEST" | awk '{print $(2)}')"
    VERDICT="$(grep -m1 '^verdict:'  "$LATEST" | awk '{print $(2)}')"
    ARCHIVE_SUMMARY="$WFLOW/$PHASE r${ROUND}${MAXR} ${VERDICT:-in-progress}"
  else
    ARCHIVE_SUMMARY="(no archive yet)"
  fi

  # Pending-message count: files in to-claude/ (or to-codex/) whose mtime is
  # newer than this workspace's latest archive file. Older files are stale
  # orphans — the read step got interrupted or the workspace was cleared
  # before processing. Don't report those as "pending"; they're dead.
  if [ -n "$LATEST" ]; then
    LATEST_MTIME=$(stat -f %m "$LATEST" 2>/dev/null || stat -c %Y "$LATEST" 2>/dev/null)
  else
    LATEST_MTIME=0
  fi

  # Resolve composite state now that LATEST_MTIME is known.
  FLEET_ARCHIVE_MT="$LATEST_MTIME"
  FLEET_PANE_TYPE="$CLAUDE_TYPE"; FLEET_OTHER_TYPE="$CODEX_TYPE";  CLAUDE_STATE="$(resolve_state)"
  FLEET_PANE_TYPE="$CODEX_TYPE";  FLEET_OTHER_TYPE="$CLAUDE_TYPE"; CODEX_STATE="$(resolve_state)"

  # Input via FLEET_DIR (named var).
  count_fresh() {
    find "$FLEET_DIR" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null \
      | while read -r f; do
          local m
          m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
          [ "$m" -gt "$LATEST_MTIME" ] && echo x
        done \
      | wc -l | tr -d ' '
  }
  # Only report in/out when Claude is not actively running. When active,
  # pending files are either in-flight or stale orphans — the count is
  # ambiguous noise. When stale, surface the count: it helps the user
  # decide whether the workspace is actually free or has unread mail.
  if [ "$CLAUDE_STATE" = active ]; then
    PENDING_IN="-"
    PENDING_OUT="-"
  else
    FLEET_DIR="$COMMS_ROOT/to-claude"; PENDING_IN="$(count_fresh)"
    FLEET_DIR="$COMMS_ROOT/to-codex";  PENDING_OUT="$(count_fresh)"
  fi

  printf "%-8s  claude=%-6s  codex=%-6s  %-45s  in=%s out=%s\n" \
    "$name" "$CLAUDE_STATE" "$CODEX_STATE" "$ARCHIVE_SUMMARY" "$PENDING_IN" "$PENDING_OUT"
done
```

**Interpret the output** and summarize for the user:

- `claude=active codex=active` = full loop in flight (Claude rendering, Codex reviewing)
- `claude=active codex=idle` = Claude working, review not sent yet
- `claude=idle codex=idle` + recent archive `APPROVE` = **ready to harvest** (fire next brief here)
- `claude=idle codex=idle` + no archive = freshly-cleared or never-dispatched workspace
- `claude=stale codex=idle` = pane 1 has a `✳ <task>` title but no braille spinner and the latest
  archive is >10 min old. The label is residue from a finished loop — workspace is *probably* free.
  Two confounders to verify before dispatching:
  1. **Long shell await.** Claude may be sitting in a multi-hour subprocess (e.g. `godot --headless
     --baseline`) that doesn't render braille. The title shows the agent's last task name, not the
     bash command it's waiting on. Cross-check by looking at recent commits or asking the user.
  2. **Just-fired loop.** A loop that fired in the last few seconds will have ✳+task before braille
     starts. Should resolve on the next status read once braille kicks in.
- `in=N` > 0 means N message(s) from Codex waiting for Claude to read — `/read-from-codex` hasn't run
- `out=N` > 0 similar for outbound

Report the table + a one-line verdict (e.g. "ws-2 and ws-5 are free; ws-1/3/4 in flight"). When
reporting `stale`, name the verification step rather than asserting idle.

---

### Preflight — shared function every dispatch must call

Every dispatch path **must** call `fleet_preflight` before any `cmux send`. Failures abort with a clear message; `--force` (passed in the original args) overrides the rejection-level checks. This block defines the function — paste it (after the step-1 and step-2 blocks) into the same shell invocation as any dispatch block:

Why: by default, all `<prefix>-N` panes operate on one on-disk working tree (the same `.git/index`, the same lock files). Too many concurrent briefs = `index.lock` collisions, cross-sweeping of staged files, and merge conflicts on hot files. If you've given each workspace its own `git worktree add`, the cap is unnecessary — bump `FLEET_MAX` or use `--force`.

```bash
FLEET_MAX="${FLEET_MAX:-3}"
case " $FLEET_ARGS " in *" --force "*) FLEET_FORCE=true ;; *) FLEET_FORCE=false ;; esac

# fleet_preflight — returns 0 if dispatch should proceed, 1 to abort.
# Always prints WARNINGs to stderr; prints REJECT and exits non-zero unless --force.
# Project-specific resource locks (game-engine project files, exclusive DB
# fixtures, long-held headless-browser sessions) can be added below as extra
# checks: set REJECT to abort, append to WARNINGS to inform without blocking.
fleet_preflight() {
  local REJECT="" WARNINGS="" ACTIVE_COUNT=0 ACTIVE_NAMES=""

  # Count currently-active Claude panes across the fleet. For the cap check
  # we want braille-only — ✳+task without a spinner is "stale label"
  # (workspace is idle or in a long shell await), not a slot consumer.
  local tmp; tmp="$(mktemp)"
  echo "$FLEET_LIST" | while read -r pf_name pf_ref; do
    [ -z "$pf_name" ] && continue
    local pf_tree pf_title pf_state
    pf_tree="$(cmux tree --workspace "$pf_ref" 2>/dev/null)"
    pf_title="$(echo "$pf_tree" | awk '/├── pane|└── pane/{n++} n==1 && /surface surface:/{print; exit}' | sed -n 's/.*\[terminal\] "\([^"]*\)".*/\1/p')"
    # Spinner-only classifier: braille = active, everything else = idle.
    pf_state="$(python3 -c 'import sys
s = sys.argv[1].lstrip()
if s and 0x2800 <= ord(s[0]) <= 0x28FF: print("active")
else: print("idle")' "$pf_title" 2>/dev/null)"
    [ "$pf_state" = active ] && echo "$pf_name"
  done > "$tmp"
  ACTIVE_COUNT="$(wc -l < "$tmp" | tr -d ' ')"
  ACTIVE_NAMES="$(tr '\n' ' ' < "$tmp")"
  rm -f "$tmp"

  # Check 1: concurrency cap
  if [ "$ACTIVE_COUNT" -ge "$FLEET_MAX" ]; then
    REJECT="concurrency cap: $ACTIVE_COUNT/$FLEET_MAX active (${ACTIVE_NAMES}) — wait for one to finish, bump FLEET_MAX, or pass --force"
  fi

  # Check 2: control workspace's staging area should be clean
  if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
    WARNINGS="${WARNINGS}WARNING: staged files exist in this worktree — another agent may have files ready to commit. Inspect with 'git diff --cached --stat' before any commits.\n"
  fi

  # Check 3: .git/index.lock currently held?
  if [ -e "$REPO_ROOT/.git/index.lock" ]; then
    WARNINGS="${WARNINGS}WARNING: .git/index.lock exists — another commit is in flight.\n"
  fi

  [ -n "$WARNINGS" ] && printf '%b' "$WARNINGS" >&2
  if [ -n "$REJECT" ]; then
    if [ "$FLEET_FORCE" = true ]; then
      printf 'preflight WARNING (forced): %s\n' "$REJECT" >&2
    else
      printf 'preflight REJECTED: %s\n(pass --force to override)\n' "$REJECT" >&2
      return 1
    fi
  fi
  return 0
}
```

`/fleet dispatch` calls `fleet_preflight` once after `ABS_BRIEF` is resolved; `/fleet dispatch-all` calls it once per brief inside the dispatch loop, so if the cap kicks in mid-sequence the remaining briefs are naturally serialized.

---

### `/fleet dispatch <workspace> <brief-path>` [`--plan-first`] [`--force`]

Dispatch a brief to a specific workspace. Default mode runs `/auto-implement <brief-path>` (the brief is already a plan). Passing `--plan-first` switches to `/auto-full <brief-path>` — use when the "brief" is a freeform feature description rather than a pre-drafted plan. Passing `--force` skips preflight (concurrency cap) — use rarely and with intent.

```bash
# Shell-portable token parse: awk does the word-splitting (bash splits unquoted
# scalars in for-loops, zsh does not — never rely on ambient splitting). Flags
# match only as whole tokens, so a brief path containing "--plan-first" or
# "--force" as a substring is never corrupted.
MODE="auto-implement"
case " $FLEET_ARGS " in *" --plan-first "*) MODE="auto-full" ;; esac
CLEAN="$(echo "$FLEET_ARGS" | awk '{out=""; for(i=1;i<=NF;i++) if ($(i)!="--plan-first" && $(i)!="--force") out=out $(i) " "; print out}')"
SUBCOMMAND="$( echo "$CLEAN" | awk '{print $(1)}')"
TARGET_NAME="$(echo "$CLEAN" | awk '{print $(2)}')"
BRIEF_PATH="$( echo "$CLEAN" | awk '{for(i=3;i<=NF;i++) printf "%s%s", $(i), (i<NF?" ":"")}')"
TARGET_REF="$(echo "$FLEET_LIST" | awk -v n="$TARGET_NAME" '$(1)==n {print $(2)}')"
if [ -z "$TARGET_REF" ]; then
  echo "unknown workspace: $TARGET_NAME — known: $(echo "$FLEET_LIST" | awk '{print $(1)}' | tr '\n' ' ')"
  exit 1
fi
if [ -z "$BRIEF_PATH" ]; then
  echo "missing brief path — usage: /fleet dispatch <workspace> <brief-path> [--plan-first]"
  exit 1
fi
# Normalize brief path: if relative, resolve from REPO_ROOT
case "$BRIEF_PATH" in
  /*) ABS_BRIEF="$BRIEF_PATH" ;;
  *)  ABS_BRIEF="$REPO_ROOT/$BRIEF_PATH" ;;
esac
if [ ! -f "$ABS_BRIEF" ]; then
  echo "brief not found at: $ABS_BRIEF"
  exit 1
fi

# Resolve pane surfaces in the target workspace (pane 1 = Claude, pane 2 = Codex)
TREE="$(cmux tree --workspace "$TARGET_REF" 2>/dev/null)"
CLAUDE_SURF="$(echo "$TREE" | awk '/├── pane|└── pane/{n++} n==1 && /surface surface:/{match($(0), /surface:[0-9]+/); print substr($(0), RSTART, RLENGTH); exit}')"
CODEX_SURF="$( echo "$TREE" | awk '/├── pane|└── pane/{n++} n==2 && /surface surface:/{match($(0), /surface:[0-9]+/); print substr($(0), RSTART, RLENGTH); exit}')"

if [ -z "$CLAUDE_SURF" ] || [ -z "$CODEX_SURF" ]; then
  echo "could not resolve both panes in $TARGET_NAME (claude=$CLAUDE_SURF, codex=$CODEX_SURF)"
  exit 1
fi

# Target busy-check: never /new a workspace whose Claude pane is actively
# running (braille spinner) — that would destroy an in-flight loop. The
# fleet-wide preflight cap below does NOT check the specific target.
TARGET_TITLE="$(echo "$TREE" | awk '/├── pane|└── pane/{n++} n==1 && /surface surface:/{print; exit}' | sed -n 's/.*\[terminal\] "\([^"]*\)".*/\1/p')"
TARGET_BUSY="$(python3 -c 'import sys
s = sys.argv[1].lstrip()
if s and 0x2800 <= ord(s[0]) <= 0x28FF: print("active")
else: print("idle")' "$TARGET_TITLE" 2>/dev/null)"
if [ "$TARGET_BUSY" = active ] && [ "$FLEET_FORCE" != true ]; then
  echo "REJECTED: $TARGET_NAME's Claude pane is actively running — dispatching would clobber the in-flight loop. Wait, /fleet clear $TARGET_NAME deliberately, or pass --force."
  exit 1
fi

# Preflight — concurrency cap, staged-file warning, index.lock warning.
# Defined in the Preflight section; aborts unless --force.
fleet_preflight || exit 1

echo "dispatching: $TARGET_NAME ($TARGET_REF)  claude=$CLAUDE_SURF  codex=$CODEX_SURF  mode=/$MODE"
echo "brief: $BRIEF_PATH"

# Step 1: clear both panes with /new
cmux send     --surface "$CLAUDE_SURF" --workspace "$TARGET_REF" '/new' && sleep 0.4
cmux send-key --surface "$CLAUDE_SURF" --workspace "$TARGET_REF" escape && sleep 0.2
cmux send-key --surface "$CLAUDE_SURF" --workspace "$TARGET_REF" enter  && sleep 0.6

cmux send     --surface "$CODEX_SURF"  --workspace "$TARGET_REF" '/new' && sleep 0.4
cmux send-key --surface "$CODEX_SURF"  --workspace "$TARGET_REF" escape && sleep 0.2
cmux send-key --surface "$CODEX_SURF"  --workspace "$TARGET_REF" enter  && sleep 0.8

# Step 2: fire the auto-* command in the Claude pane
cmux send     --surface "$CLAUDE_SURF" --workspace "$TARGET_REF" "/$MODE $BRIEF_PATH" && sleep 0.5
cmux send-key --surface "$CLAUDE_SURF" --workspace "$TARGET_REF" escape && sleep 0.3
cmux send-key --surface "$CLAUDE_SURF" --workspace "$TARGET_REF" enter

echo "dispatched — watch $TARGET_NAME for progress, or run /fleet status later."
```

---

### `/fleet dispatch-all <brief1> <brief2> ...` [`--plan-first`]

Auto-assign briefs to free workspaces. Finds workspaces whose Claude pane is idle (no spinner) AND whose latest archive entry either does not exist or has `verdict: APPROVE`. Assigns briefs in order.

```bash
# Shell-portable token parse — awk splits (zsh doesn't split unquoted scalars),
# flags match whole tokens only, brief paths are never mutated. First non-flag
# token is the subcommand; the rest are briefs, one per line.
MODE="auto-implement"
case " $FLEET_ARGS " in *" --plan-first "*) MODE="auto-full" ;; esac
BRIEFS="$(echo "$FLEET_ARGS" | awk '{n=0; for(i=1;i<=NF;i++) if ($(i)!="--plan-first" && $(i)!="--force") {n++; if (n>1) print $(i)}}')"

# Build list of free workspaces: Claude pane idle AND latest archive
# missing OR verdict=APPROVE. We deliberately exclude REQUEST_CHANGES,
# in-progress, and max-rounds-stop verdicts — those workspaces have
# unresolved state that the user should look at before reusing.
FREE_LIST="$(mktemp)"
trap 'rm -f "$FREE_LIST"' EXIT
echo "$FLEET_LIST" | while read -r name ref; do
  [ -z "$name" ] && continue
  TREE="$(cmux tree --workspace "$ref" 2>/dev/null)"
  CLAUDE_LINE="$(echo "$TREE" | awk '/├── pane|└── pane/{n++} n==1 && /surface surface:/{print; exit}')"
  CLAUDE_TITLE="$(echo "$CLAUDE_LINE" | sed -n 's/.*\[terminal\] "\([^"]*\)".*/\1/p')"
  # Spinner-only: braille = busy, anything else = candidate. ✳+task without
  # a spinner is stale label OR long shell await — both fine for dispatch
  # because /fleet dispatch /new's the panes first. The archive verdict
  # check below is the real gate.
  STATE="$(python3 -c 'import sys
s = sys.argv[1].lstrip()
if s and 0x2800 <= ord(s[0]) <= 0x28FF: print("active")
else: print("idle")' "$CLAUDE_TITLE" 2>/dev/null)"
  [ "$STATE" = idle ] || continue
  LATEST="$(find "$COMMS_ROOT/archive" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null | sort | tail -1)"
  if [ -z "$LATEST" ]; then
    echo "$name"
    continue
  fi
  # verdict=APPROVE is the protocol's only completion signal (nothing ever
  # writes status:complete — don't reintroduce checks for it).
  VERDICT="$(grep -m1 '^verdict:' "$LATEST" | awk '{print $(2)}')"
  if [ "$VERDICT" = APPROVE ]; then
    echo "$name"
  fi
done > "$FREE_LIST"

FREE_COUNT=$(wc -l < "$FREE_LIST" | tr -d ' ')
BRIEF_COUNT=$(echo "$BRIEFS" | grep -c .)
echo "free workspaces: $FREE_COUNT / briefs to dispatch: $BRIEF_COUNT / mode: /$MODE"

if [ "$BRIEF_COUNT" -gt "$FREE_COUNT" ]; then
  echo "not enough free workspaces — clear some with /fleet clear <workspace> first, or run /fleet status"
  cat "$FREE_LIST"
  exit 1
fi

# Report the assignment mapping before firing
paste <(echo "$BRIEFS") <(cat "$FREE_LIST") | head -"$BRIEF_COUNT"
```

After producing the assignment mapping, **do not fire automatically** — print the mapping and ask the user to confirm with explicit `/fleet dispatch <ws> <brief>` calls, OR with a single follow-up "yes fire all". Rationale: `dispatch-all` is high-blast-radius (multiple panes start churning at once); the confirmation step is cheap insurance against a typoed brief path.

If the user confirms "fire all" / "yes" / "go", loop the paste output and invoke the dispatch block above for each pair in sequence (with ~2s sleep between dispatches so cmux has time to cycle). **The free-list above is a snapshot taken before the confirmation round-trip — a workspace can go busy in the window.** The dispatch block's target busy-check re-validates each workspace at fire time; when it rejects one, skip that pair, report it, and continue with the remaining pairs.

---

### `/fleet harvest`

Identify workspaces ready for the next brief: Claude pane idle + latest archive message has `verdict: APPROVE` + newer than the latest `to-claude/` or `to-codex/` pending message for that workspace.

```bash
echo "$FLEET_LIST" | while read -r name ref; do
  [ -z "$name" ] && continue
  TREE="$(cmux tree --workspace "$ref" 2>/dev/null)"
  CLAUDE_TITLE="$(echo "$TREE" | awk '/├── pane|└── pane/{n++} n==1 && /surface surface:/{print; exit}' | sed -n 's/.*\[terminal\] "\([^"]*\)".*/\1/p')"
  # Spinner-only: braille = busy, anything else = harvest candidate.
  STATE="$(python3 -c 'import sys
s = sys.argv[1].lstrip()
if s and 0x2800 <= ord(s[0]) <= 0x28FF: print("active")
else: print("idle")' "$CLAUDE_TITLE" 2>/dev/null)"
  [ "$STATE" = idle ] || continue
  LATEST="$(find "$COMMS_ROOT/archive" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null | sort | tail -1)"
  if [ -z "$LATEST" ]; then
    echo "$name: idle, no archive (never dispatched or freshly cleared)"
    continue
  fi
  VERDICT="$(grep -m1 '^verdict:' "$LATEST" | awk '{print $(2)}')"
  PHASE="$(  grep -m1 '^phase:'   "$LATEST" | awk '{print $(2)}')"
  WFLOW="$(  grep -m1 '^workflow:' "$LATEST" | awk '{print $(2)}')"
  ROUND="$(  grep -m1 '^round:'   "$LATEST" | awk '{print $(2)}')"
  LATEST_MTIME=$(stat -f %m "$LATEST" 2>/dev/null || stat -c %Y "$LATEST" 2>/dev/null)

  # Pending check: if any to-claude/ or to-codex/ file for this workspace is
  # newer than the archive, the loop has unread messages — not truly free.
  PENDING_MSG=""
  for dir in "$COMMS_ROOT/to-claude" "$COMMS_ROOT/to-codex"; do
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
      if [ "$m" -gt "$LATEST_MTIME" ]; then
        PENDING_MSG="$(basename "$f")"
        break 2
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name "${name}_*.md" 2>/dev/null)
  done

  if [ -n "$PENDING_MSG" ]; then
    echo "$name: idle but PENDING — unread message $PENDING_MSG (run /read-from-codex or /clean-comms)"
    continue
  fi

  # verdict=APPROVE is the protocol's only completion signal (nothing ever
  # writes status:complete — don't reintroduce checks for it).
  case "$VERDICT" in
    APPROVE) echo "$name: READY — $WFLOW/$PHASE approved at round $ROUND (archive: $(basename "$LATEST"))" ; continue ;;
  esac
  echo "$name: idle but not approved — last archive: $WFLOW/$PHASE r$ROUND verdict=${VERDICT:-none}"
done
```

Report the ready list. If the user asks "fire next" with a brief path, invoke `/fleet dispatch` on the first ready workspace.

---

### `/fleet clear <workspace>`

Reset a workspace's Claude + Codex panes with `/new`. Useful after harvesting or if a loop wedged and needs a hard reset. Does NOT touch `.comms/`; use `/clean-comms` for that.

```bash
# Second token of the argument text is the workspace name (first is "clear").
TARGET_NAME="$(echo "$FLEET_ARGS" | awk '{print $(2)}')"
TARGET_REF="$(echo "$FLEET_LIST" | awk -v n="$TARGET_NAME" '$(1)==n {print $(2)}')"
if [ -z "$TARGET_REF" ]; then
  echo "unknown workspace: $TARGET_NAME"
  exit 1
fi
TREE="$(cmux tree --workspace "$TARGET_REF" 2>/dev/null)"
CLAUDE_SURF="$(echo "$TREE" | awk '/├── pane|└── pane/{n++} n==1 && /surface surface:/{match($(0), /surface:[0-9]+/); print substr($(0), RSTART, RLENGTH); exit}')"
CODEX_SURF="$( echo "$TREE" | awk '/├── pane|└── pane/{n++} n==2 && /surface surface:/{match($(0), /surface:[0-9]+/); print substr($(0), RSTART, RLENGTH); exit}')"
for SURF in "$CLAUDE_SURF" "$CODEX_SURF"; do
  [ -z "$SURF" ] && continue
  cmux send     --surface "$SURF" --workspace "$TARGET_REF" '/new' && sleep 0.4
  cmux send-key --surface "$SURF" --workspace "$TARGET_REF" escape && sleep 0.2
  cmux send-key --surface "$SURF" --workspace "$TARGET_REF" enter  && sleep 0.5
done
echo "cleared $TARGET_NAME (claude=$CLAUDE_SURF, codex=$CODEX_SURF)"
```

---

### `/fleet help`

Print this usage summary:

```
/fleet status                                         — table of what every <prefix>-N is doing
/fleet dispatch <workspace> <brief-path>              — clear + fire /auto-implement
/fleet dispatch <workspace> <brief-path> --plan-first — clear + fire /auto-full instead
/fleet dispatch-all <brief1> <brief2> …               — auto-assign to free workspaces
/fleet harvest                                        — list workspaces idle + approved
/fleet clear <workspace>                              — /new both panes
/fleet help                                           — this

Env:
  FLEET_PREFIX  workspace name prefix to scan for (default: ws)
  FLEET_MAX     concurrency cap (default: 3) — bypass with --force
```

## Notes

- **Pane ordering is load-bearing.** `/fleet` assumes pane 1 = Claude, pane 2 = Codex in every `<prefix>-N` workspace. If a workspace was set up differently, dispatch will send the auto-* command to the wrong pane. Run `cmux tree --workspace <ref>` to verify if unsure.
- **Concurrency cap defaults to 3.** This is a guard against shared-worktree pain (cross-staged commits, `index.lock` collisions) when multiple `<prefix>-N` workspaces operate on one on-disk repo. If each workspace has its own `git worktree add`, the cap is unnecessary — set `FLEET_MAX=99` or use `--force`. The Preflight section is the place to add project-specific resource locks (e.g. exclusive game-engine project files, headless-browser sessions, slow database fixtures).
- **`/auto-implement` is the default** because the typical workflow drafts briefs (which ARE the plans) before firing. Use `--plan-first` for freeform tasks where the executing agent should draft its own plan first.
- **No queue.** `/fleet` tracks current state but does not queue work. The user (or the agent in auto mode) decides what fires next based on `/fleet status` + `/fleet harvest` output.
- **Safety on dispatch-all.** Reports the assignment mapping and asks for confirmation before firing multiple panes at once. Auto mode can confirm through it, but the step is intentional. `dispatch-all` also runs preflight + the per-target busy-check per brief at fire time — if the cap kicks in or a snapshotted-free workspace went busy mid-sequence, those briefs are rejected/skipped and the user decides whether to wait or `--force`.
- **Argument substitution is load-bearing for editors.** Claude Code substitutes bare dollar-digit tokens (and the ARGUMENTS placeholder) in this file at render time. All awk field refs are written `$(0)`/`$(2)` and bash functions take `FLEET_*` named vars instead of positional params so rendered code stays valid. Keep that convention when editing.
- **Completion detection is inference, not ground truth.** `/fleet` reads `cmux tree` titles + archive mtimes. If a loop wedges in a weird state (Claude responded but never sent to Codex; Codex approved but the file is still in `to-claude/`), `/fleet status` will show the symptoms but won't auto-diagnose. For wedged workspaces: manually inspect, then `/fleet clear <ws>` if needed.
