# Run through tests/run.sh; each group gets fresh fixtures.
section "scope-dial template source contract"
# Scope-dial trio: the load-bearing new prose, pinned mechanically.
FRAGVD="$REPO/docs/loopspec/fragments/verdict-discipline.md"
grep -q 'Pre-existing defects in code the change did not touch are Advisory by default' "$FRAGVD" \
  && ok "verdict-discipline fragment carries the pre-existing-defects rule" || fail "fragment pre-existing-defects rule"
AIF="$REPO/templates/claude-commands/auto.md"
grep -q '## Acceptance criteria' "$AIF" && grep -q 'PINNED at round 1' "$AIF" \
  && ok "auto.md pins acceptance criteria at round 1" || fail "auto acceptance criteria"
RFC="$REPO/templates/claude-commands/read-from-codex.md"
grep -q 'pinned `## Acceptance criteria`' "$RFC" \
  && ok "auto-full implement handoff pins acceptance criteria" || fail "read-from-codex criteria handoff"
grep -q '### Scope additions' "$RFC" && grep -q 'Copy the ledger forward verbatim' "$RFC" \
  && ok "reply spec carries the scope-additions ledger forward" || fail "read-from-codex scope ledger"
grep -q 'copied forward VERBATIM' "$RFC" && grep -q 'amended round N' "$RFC" \
  && ok "reply spec copies acceptance criteria forward with explicit amendments" || fail "read-from-codex criteria lifecycle"
grep -q 'amendment proposal alone' "$RFC" && grep -c 'amended round N' "$RFC" | grep -q '2' \
  && ok "amendment rule present in reply spec AND auto-full handoff" || fail "amendment rule in both handoff paths"
# These two rules used to live ONLY in the deleted read-from-claude SKILL. Re-pointed at their
# surviving homes rather than dropped: the pinned-criteria rule is in the prompt builder, and
# the amendment rule was MOVED into verdict-discipline.md — the fragment runphase inlines into
# every reviewer prompt — because deleting the skill would otherwise have silently removed a
# review-bar rule that nothing else carried. (S4-3.)
grep -q 'Judge against the pinned' "$REPO/helpers/runphase.sh" \
  && ok "reviewer judges against pinned criteria" || fail "pinned-criteria rule lost"
grep -q 'amendment proposal alone is non-blocking' "$REPO/docs/loopspec/fragments/verdict-discipline.md" \
  && ok "reviewer treats amendment proposals as non-blocking" || fail "amendment rule lost with the deleted skill"
# Also carried only by the deleted skill, and restored on the path the child reads. Pinned as a
# CONDITIONAL: it must be gated on the final round, not pasted into every prompt. (S4-3 r1.)
grep -q 'FINAL round: add a broad quality sweep' "$REPO/helpers/runphase.sh" \
  && ok "the final-round quality sweep survives the skill deletion" || fail "final-round sweep lost"
grep -q 'GROK_ROUND" -ge "\$GROK_MAXR' "$REPO/helpers/runphase.sh" \
  && ok "the final-round sweep is gated on the final round, not every round" || fail "final-round sweep is ungated"
# The installer-generated Codex contract is loaded on EVERY codex turn. It must not name a
# surface this installer deletes — the same trap RETIRED_COMMANDS exists to prevent.
# (codex + grok, S4-3 r1, corroborated blocking.)
AGB="$(awk '/^agents_block_body\(\)/,/^}/' "$REPO/install.sh")"
printf '%s' "$AGB" | grep -q 'read-from-claude\|send-to-claude' \
  && fail "the live AGENTS.md block still tells Codex to call a deleted skill" \
  || ok "the live AGENTS.md block names no deleted skill"
printf '%s' "$AGB" | grep -q 'parent-brokered' \
  && ok "the live AGENTS.md block describes the parent-brokered model" || fail "AGENTS.md block does not describe the surviving workflow"
# The success banner is a second surface that advertised the skills; grep it too. (codex, r2.)
grep -A24 'done! installed:' "$REPO/install.sh" | grep -q 'read-from-claude\|send-to-claude' \
  && fail "the installer banner still claims it installed a deleted skill" \
  || ok "the installer banner claims no deleted skill"
# THE BAR-BLINDNESS LOCK. prompt-version must move when the verdict discipline moves; without
# this, reverting the fragment loop in prompt_surface_files leaves the suite green while grades
# pool across different review standards. Proven by construction: edit, compare, restore.
# (codex + grok, S4-3 r2, corroborated advisory — it protects this round's blocker.)
# Edit the copy the RESOLVER SELECTS, not a hardcoded path. The three-tier order is project
# pin -> AGENT_COMMS_HOME -> repo docs/, and earlier sections export AGENT_COMMS_HOME at a temp
# install, so a hardcoded docs/ path is invisible to the hash and this "lock" would report
# BAR-BLIND against a working implementation. `--list` prints exactly what gets hashed.
# (Found by this assertion failing on its own first run.)
PV_FRAG="$( (cd "$REPO" && "$COMMS" prompt-version --list 2>/dev/null) | grep 'verdict-discipline\.md$' | head -1)"
[ -n "$PV_FRAG" ] && [ -f "$PV_FRAG" ] || fail "prompt-version does not resolve verdict-discipline at all (got: $PV_FRAG)"
PV_BAK="$WORK/verdict-discipline.bak"; cp "$PV_FRAG" "$PV_BAK"
PV_BEFORE="$(cd "$REPO" && "$COMMS" prompt-version 2>/dev/null)"
printf '\n<!-- prompt-version probe -->\n' >> "$PV_FRAG"
PV_AFTER="$(cd "$REPO" && "$COMMS" prompt-version 2>/dev/null)"
cp "$PV_BAK" "$PV_FRAG"
PV_RESTORED="$(cd "$REPO" && "$COMMS" prompt-version 2>/dev/null)"
[ -n "$PV_BEFORE" ] && [ "$PV_BEFORE" != "$PV_AFTER" ] \
  && ok "editing the verdict discipline shifts prompt-version (the bar is hashed)" \
  || fail "prompt-version is BAR-BLIND: a verdict-discipline edit did not move it ($PV_BEFORE -> $PV_AFTER)"
[ "$PV_BEFORE" = "$PV_RESTORED" ] \
  && ok "reverting the fragment restores prompt-version (the probe is not a one-way change)" \
  || fail "prompt-version did not restore after reverting the probe ($PV_BEFORE -> $PV_RESTORED)"

section "templates: bare dollar-digit/dollar-star hygiene"
# INTERNALS editing rule made mechanical: Claude Code substitutes bare dollar-digit
# tokens (and dollar-star) into command markdown at render time with no escape syntax.
# dollar-paren, dollar-brace, and named variables are fine and must pass.
HYG_HITS="$(grep -rnE '\$[0-9]|\$\*' "$REPO/templates" || true)"
if [ -z "$HYG_HITS" ]; then
  ok "no bare dollar-digit/dollar-star tokens under templates/"
else
  fail "bare dollar token(s) under templates/: $(echo "$HYG_HITS" | head -3 | tr '\n' ' ')"
fi

section "/ask canonical template source contract"
# Prompt templates ARE the executable surface — these pin the load-bearing rules.
ASKF="$REPO/templates/claude-commands/ask.md"
[ -f "$ASKF" ] && ok "ask.md exists" || fail "ask.md exists"
grep -q 'type: question' "$ASKF" && ok "ask.md message skeleton is type: question" || fail "ask.md type: question"
grep -q 'Eligible pair' "$ASKF" && grep -q 'overrides the cap' "$ASKF" \
  && ok "ask.md pins the eligible-pair floor over the soft cap" || fail "ask.md floor-over-cap contract"
grep -q 'question OR request' "$ASKF" && ok "ask.md pair selector covers imperative asks" || fail "ask.md request-or-question wording"
grep -q 'FAIL CLOSED' "$ASKF" && grep -q 'send nothing' "$ASKF" \
  && ok "ask.md fails closed with no eligible pair" || fail "ask.md fail-closed branch"
grep -q 'ENTIRE ORIGINAL argument' "$ASKF" && ok "ask.md preserves full argument on unknown first word" || fail "ask.md unknown-agent fallback"
grep -q 'non-interpolating file-write tool' "$ASKF" && grep -q 'PROVEN absent' "$ASKF" \
  && ok "ask.md requires collision-safe writer" || fail "ask.md write-safety contract"
# Delimiter-agnostic: ANY heredoc operator in ask.md reintroduces the early-close
# risk regardless of the delimiter word chosen, so reject the operator itself.
grep -qE '<<' "$ASKF" && fail "ask.md contains a heredoc operator — the write contract requires a non-interpolating writer" \
  || ok "ask.md carries no heredoc operator at all (delimiter-agnostic guard)"
grep -qF 'send --to "$TARGET"' "$ASKF" && ok "ask.md sends to a variable target" || fail "ask.md variable-target send"
grep -q 'loopspec:fragment result-spawned-exception' "$ASKF" \
  && ok "ask.md embeds the result-spawned-exception fragment" || fail "ask.md fragment embed present"


section "loopspec: prompt fragments do not drift from docs/loopspec/fragments/"
# Every marked region in a template must match its fragment file byte-for-byte
# after per-line leading-whitespace normalization (templates embed at varying
# list indents). Drift is a failing check, not a habit.
# TRACKED-ONLY enumeration. These loops drive assertion COUNTS, and the coverage gate
# turns those counts into a landing decision, so they must reflect the COMMITTED tree.
# A filesystem glob does not: delete a tracked template in the candidate, recreate the
# path untracked before the pre-flight run, and the count stays put while `attest-green`
# (which only refuses TRACKED dirtiness) mints anyway — integrate then skips its clean
# re-run and lands a commit missing the file. (codex, panel r2, blocking.)
tracked_paths() { # <pathspec...> -> absolute paths of tracked files, one per line
  git -C "$REPO" ls-files -- "$@" 2>/dev/null | while IFS= read -r _tp; do
    printf '%s/%s\n' "$REPO" "$_tp"
  done
}

FRAG_SEEN="$WORK/fragments-seen"
: > "$FRAG_SEEN"
for tf in $(tracked_paths 'templates/claude-commands/*.md' 'templates/codex-skills/*/SKILL.md'); do
  for name in $(sed -n 's/.*<!-- loopspec:fragment \([a-z0-9-]*\) -->.*/\1/p' "$tf" | sort -u); do
    echo "$name" >> "$FRAG_SEEN"
    frag="$REPO/docs/loopspec/fragments/$name.md"
    if [ ! -f "$frag" ]; then
      fail "template $(basename "$tf") references missing fragment: $name"
      continue
    fi
    want="$(sed 's/^[[:space:]]*//' "$frag")"
    # Compare EVERY marked region — a second embed of the same fragment in one
    # file must be drift-checked too, not just the first.
    count="$(grep -c "<!-- loopspec:fragment $name -->" "$tf" || true)"
    occ=1
    while [ "$occ" -le "$count" ]; do
      got="$(awk -v marker="<!-- loopspec:fragment $name -->" -v occ="$occ" '
        index($0, marker) {n++; if (n==occ) {c=1; next}}
        c && /<!-- \/loopspec:fragment -->/ {exit}
        c {sub(/^[[:space:]]+/, ""); print}' "$tf")"
      if [ "$got" = "$want" ]; then
        ok "fragment $name matches in $(basename "$tf") (region $occ/$count)"
      else
        fail "fragment DRIFT: $name in $(basename "$tf") region $occ — edit docs/loopspec/fragments/$name.md (the normative home) and re-embed"
      fi
      occ=$((occ+1))
    done
  done
done
for frag in $(tracked_paths 'docs/loopspec/fragments/*.md'); do
  n="$(basename "$frag" .md)"
  # A fragment is USED if a template embeds it OR a helper RESOLVES it at runtime. Checking only
  # for template embedding would call the live review bar an orphan and invite deleting it (S4-3).
  # Two holes both reviewers named, now closed: (a) COMMENTS no longer count — the call must be
  # on a non-comment line; (b) the resolving function must ITSELF be called somewhere non-comment,
  # so a wholly dead resolver cannot bless a fragment. `skill_file` was exactly that: zero callers,
  # yet shaped like a live resolver. Residual, accepted: a `fragment_text "$var"` refactor would
  # read as unused — which is why this stays a usage hint, not a deletion trigger. (grok, S4-3 r2.)
  FRAG_LIVE=false
  while IFS=: read -r _f _l _rest; do
    case "$_rest" in *"#"*) case "${_rest%%#*}" in *"fragment_"*) ;; *) continue ;; esac ;; esac
    _fn="$(awk -v L="$_l" 'NR<=L && /^[a-z_]+\(\) \{/{f=$1} END{print f}' "$_f")"
    [ -n "$_fn" ] || continue
    _fnname="${_fn%%(*}"
    if grep -rn "\b$_fnname\b" "$REPO/helpers/" | grep -v "^$_f:$_l:" | grep -vE ':[0-9]+: *#' | grep -qv "$_fnname() {"; then
      FRAG_LIVE=true; break
    fi
  done <<< "$(grep -rn "fragment_text $n\|fragment_file $n" "$REPO/helpers/" | grep -vE ':[0-9]+: *#')"
  if grep -q "^$n$" "$FRAG_SEEN" || [ "$FRAG_LIVE" = true ]; then
    ok "fragment $n is used (embedded by a template or resolved at runtime)"
  else
    fail "orphan fragment (nothing embeds or resolves it): $n"
  fi
done
# Tripwire: fragment signature phrases must never appear in a template OUTSIDE
# a marked region — an unmarked copy of normative discipline text would silently
# escape the drift check (real-review finding). Signatures are distinctive
# substrings of each fragment; extend this list when adding fragments.
sig_outside_markers() {  # <signature> — prints template:line for hits outside markers
  local sig="$1" tf
  for tf in $(tracked_paths 'templates/claude-commands/*.md' 'templates/codex-skills/*/SKILL.md'); do
    awk -v sig="$sig" -v f="$(basename "$tf")" '
      /<!-- loopspec:fragment / {inm=1}
      /<!-- \/loopspec:fragment -->/ {inm=0; next}
      !inm && index($0, sig) {print f ":" NR}' "$tf"
  done
}
while IFS='|' read -r sig label; do
  [ -n "$sig" ] || continue
  HITS="$(sig_outside_markers "$sig")"
  if [ -z "$HITS" ]; then
    ok "no unmarked copies of $label discipline in templates"
  else
    fail "unmarked $label discipline text in templates (wrap in loopspec:fragment markers): $(echo "$HITS" | tr '\n' ' ')"
  fi
done <<'SIGS'
RESULT: spawned|result-spawned
truly ship-stopping|verdict-discipline
blank checklist|holistic-rereview
SIGS

section "comms.sh: bounded reads (lessons)"
# The whole point of these subcommands is a cap that holds no matter how large
# the log grows OR how hostile the arguments are, so the invariant is asserted
# as a byte measurement of stdout AND stderr together — tools return both.
LES="$WORK/lessons"; mkdir -p "$LES"
DIAG_MAX=256
cat > "$LES/adv.md" <<'ADV'
# Advisory carry-over

## 2026-01-01 — oldest dated
old body line

## 2026-05-05 — middle dated
mid body line

## No date in this heading
undated body line

## 2026-09-09 — appended at the BOTTOM, and newest
newest body line
ADV
les() { (cd "$REPO_FIX" && env "$COMMS" lessons "$@" >"$WORK/l.out" 2>"$WORK/l.err"); }
les_total() { echo $(( $(wc -c <"$WORK/l.out") + $(wc -c <"$WORK/l.err") )); }

les --file "$LES/adv.md" --bytes 4000; LES_RC=$?
[ "$LES_RC" = 0 ] && ok "lessons exits 0 when everything fits" || fail "lessons exit 0 when it fits (got $LES_RC)"
ORDER="$(grep '^## ' "$WORK/l.out" | head -4 | tr '\n' '|')"
case "$ORDER" in
  "## 2026-09-09"*"## 2026-05-05"*"## 2026-01-01"*"## No date"*)
    ok "lessons sorts newest-first by heading date; a BOTTOM-appended entry still comes first" ;;
  *) fail "lessons ordering (got: $ORDER)" ;;
esac
grep -q "^## No date in this heading" "$WORK/l.out" \
  && ok "lessons sorts an undated heading LAST but never drops it" || fail "lessons keeps undated sections"
grep -q "without a date sort last" "$WORK/l.err" \
  && ok "lessons warns about undated sections" || fail "lessons warns about undated sections"

# A tight budget must truncate by whole sections and still report what it left.
# Sections are padded past the budget so this exercises real truncation rather
# than a fixture that happens to fit.
{
  for d in 2026-01-01 2026-05-05 2026-09-09; do
    echo "## $d — padded section"
    for i in 1 2 3 4 5 6; do echo "- padded body line $i for $d, long enough to matter"; done
    echo
  done
} > "$LES/big.md"
les --file "$LES/big.md" --bytes 512; LES_RC=$?
[ "$LES_RC" = 3 ] && ok "lessons exits 3 when truncated" || fail "lessons exit 3 on truncation (got $LES_RC)"
[ "$(wc -c <"$WORK/l.out")" -le 512 ] && ok "lessons stdout respects --bytes exactly" || fail "lessons stdout <= --bytes"
[ "$(les_total)" -le $((512 + DIAG_MAX)) ] \
  && ok "lessons combined stdout+stderr <= --bytes + DIAGNOSTIC_MAX" || fail "lessons combined output bound"
grep -q "omitted" "$WORK/l.out" && ok "lessons names what it omitted in stdout" || fail "lessons names omissions"
# Truncation must never hand back half a bullet that reads like a whole instruction:
# the oldest section is dropped or named, never partially emitted.
check_not "lessons never emits a partial section body" grep -q "padded body line 6 for 2026-01-01" "$WORK/l.out"

# The bound is only a constant if caller-controlled values are clipped first —
# this is the exact hole a plan review caught: --file and --surface are inputs.
LONG_PATH="/tmp/$(printf 'z%.0s' $(seq 1 5000))"
LONG_PAT="$(printf 'q%.0s' $(seq 1 5000))"
les --file "$LONG_PATH"
[ "$(les_total)" -le $((4000 + DIAG_MAX)) ] \
  && ok "lessons clips a pathological --file so the diagnostic stays constant" || fail "lessons clips --file"
les --file "$LES/adv.md" --surface "$LONG_PAT"
[ "$(les_total)" -le $((4000 + DIAG_MAX)) ] \
  && ok "lessons clips a pathological --surface so the diagnostic stays constant" || fail "lessons clips --surface"

les --file "$LES/adv.md" --bytes 511;   [ $? = 2 ] && ok "lessons rejects --bytes below the floor" || fail "lessons --bytes floor"
les --file "$LES/adv.md" --bytes abc;   [ $? = 2 ] && ok "lessons rejects a non-numeric --bytes" || fail "lessons --bytes numeric"
les --file "$LES/adv.md" --surface "";  [ $? = 2 ] && ok "lessons rejects an empty --surface" || fail "lessons empty --surface"
les --badflag;                          [ $? = 2 ] && ok "lessons rejects an unknown flag" || fail "lessons unknown flag"
les --file "$LES/nope.md";              [ $? = 0 ] && ok "lessons is a no-op when the log is absent" || fail "lessons missing file"
les --file "$LES/adv.md" --surface middle
grep -q "2026-05-05" "$WORK/l.out" && ! grep -q "2026-09-09" "$WORK/l.out" \
  && ok "lessons --surface filters to matching sections" || fail "lessons --surface filters"
les --file "$LES/adv.md" --surface ZZnotpresent
[ ! -s "$WORK/l.out" ] && ok "lessons emits nothing when --surface matches nothing" || fail "lessons no-match is empty"

# Project docs belong to the tree under review; .comms stays main-anchored. A
# review running in a linked worktree must not silently read main's lessons.
WT_MAIN="$WORK/wt-main"; mkdir -p "$WT_MAIN"; WT_MAIN="$(cd "$WT_MAIN" && pwd -P)"
git -C "$WT_MAIN" init -q -b main
mkdir -p "$WT_MAIN/docs"; echo '## 2026-01-01 — MAIN tree lesson' > "$WT_MAIN/docs/advisories.md"
git -C "$WT_MAIN" add -A >/dev/null 2>&1
git -C "$WT_MAIN" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$WT_MAIN" worktree add -q -b feat "$WORK/wt-linked" 2>/dev/null
mkdir -p "$WORK/wt-linked/docs"; echo '## 2026-02-02 — WORKTREE lesson' > "$WORK/wt-linked/docs/advisories.md"
WT_OUT="$(cd "$WORK/wt-linked" && env "$COMMS" lessons 2>/dev/null | head -1)"
[ "$WT_OUT" = "## 2026-02-02 — WORKTREE lesson" ] \
  && ok "lessons reads the CURRENT worktree's advisories, not the main tree's" || fail "lessons worktree resolution (got: $WT_OUT)"
WT_ROOT="$(cd "$WORK/wt-linked" && env "$COMMS" root)"
[ "$WT_ROOT" = "$WT_MAIN/.comms" ] \
  && ok "comms root stays anchored to the MAIN repo from a linked worktree" || fail "root stays main-anchored (got: $WT_ROOT)"

section "comms.sh: bounded reads (archive-search)"
# Ordering across workspaces is the trap: filenames are <workspace>_<ISO>_<slug>,
# so any lexical shortcut sorts by WORKSPACE first and returns the wrong "newest"
# exactly in the multi-workspace case fleet.sh ships.
AS_ARCH="$REPO_FIX/.comms/archive"
mk_arch() { # mk_arch <file> <ts> <thread> <body>
  cat > "$AS_ARCH/$1" <<MSG
---
type: review-feedback
from: codex
timestamp: $2
thread: $3
round: 1
verdict: APPROVE
---

$4
MSG
}
mk_arch "zzz-workspace_2026-01-01T00-00-00_old.md"  "2026-01-01T00:00:00Z" "old-thread"  "widget handling notes"
mk_arch "aaa-workspace_2026-12-31T00-00-00_new.md"  "2026-12-31T00:00:00Z" "new-thread"  "widget handling notes"
ars() { (cd "$REPO_FIX" && env "$COMMS" archive-search "$@" >"$WORK/a.out" 2>"$WORK/a.err"); }
ars widget
FIRST_HIT="$(head -1 "$WORK/a.out")"
case "$FIRST_HIT" in
  new-thread*) ok "archive-search returns the globally newest match across workspaces" ;;
  *) fail "archive-search cross-workspace ordering (got: $FIRST_HIT)" ;;
esac
grep -q '\.comms/archive/' "$WORK/a.out" \
  && ok "archive-search prints a repo-relative path so the follow-up read is actionable" || fail "archive-search path"
ars widget --limit 1
[ "$(grep -c 'thread' "$WORK/a.out")" -ge 1 ] && ok "archive-search honours --limit" || fail "archive-search --limit"
head -1 "$WORK/a.out" | grep -q '^new-thread' \
  && ok "archive-search applies --limit AFTER the global sort, not before" || fail "archive-search limit-after-sort"
ars widget --bytes 600
[ "$(( $(wc -c <"$WORK/a.out") + $(wc -c <"$WORK/a.err") ))" -le $((600 + DIAG_MAX)) ] \
  && ok "archive-search combined output <= --bytes + DIAGNOSTIC_MAX" || fail "archive-search combined bound"
ars ZZnotpresent; [ $? = 0 ] && ok "archive-search is a no-op when nothing matches" || fail "archive-search no-match"
# Flags and shell options are among the most useful things to search this archive
# for, so a literal pattern starting with '-' must be reachable.
mk_arch "aaa-workspace_2026-12-30T00-00-00_flag.md" "2026-12-30T00:00:00Z" "flag-thread" "used --archive-inbound here"
ars -- --archive-inbound
if [ $? = 0 ] && grep -q 'flag-thread' "$WORK/a.out"; then
  ok "archive-search finds a literal pattern starting with '-' after a -- terminator"
else
  fail "archive-search -- <dash-pattern>"
fi
ars --archive-inbound; [ $? = 2 ] \
  && ok "archive-search still rejects an unknown option without --" || fail "archive-search unknown option"
rm -f "$AS_ARCH/aaa-workspace_2026-12-30T00-00-00_flag.md"
ars; [ $? = 2 ] && ok "archive-search requires a pattern" || fail "archive-search requires pattern"
ars widget --limit 0; [ $? = 2 ] && ok "archive-search rejects --limit 0" || fail "archive-search --limit 0"
rm -f "$AS_ARCH/zzz-workspace_2026-01-01T00-00-00_old.md" "$AS_ARCH/aaa-workspace_2026-12-31T00-00-00_new.md"

section "comms.sh: help prints its whole header"
HELP_OUT="$(cd "$REPO_FIX" && env "$COMMS" help)"
echo "$HELP_OUT" | grep -q 'archive-search' \
  && ok "help lists the last subcommand (no fixed-range truncation)" || fail "help truncates its own header"
