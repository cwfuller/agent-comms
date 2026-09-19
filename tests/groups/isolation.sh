# Run through tests/run.sh; each group gets fresh fixtures.
section "reviewer isolation: a mounted turn is contained or it does not run"

# CRITERION 2 of contraction step 3. The measurements behind these assertions are in
# docs/ROADMAP.md; the short version is that NOTHING at the ACP layer contains a provider that
# does not ask permission — five parent-side controls were measured to be no-ops — so the
# boundary is the provider's own kernel sandbox, selected by the parent, or there is no boundary
# and the turn must not run.
ISO="$WORK/iso"; mkdir -p "$ISO"
ISO_RP="$REPO/helpers/runphase.sh"

# ---- the claude backend (S3-4b): mode-pinned, write-contained, network NOT contained ----
# Shipped on an explicit owner decision after measurement; the table is in docs/ROADMAP.md.
# These pin the SHAPE. What they cannot do is re-measure the adapter, so the residuals below are
# asserted as DOCUMENTED FACTS, which is the honest thing a source assertion can hold.
sed -n '/^        claude)/,/^          ;;/p' "$ISO_RP" | grep -q 'acp_iso_mode="plan"' \
  && ok "the claude arm pins claude's own read-only analogue (plan), not codex's mode id" || fail "claude arm does not pin plan"
# The mode is DATA. Hardcoding read-only is what made claude look uncontainable, because
# `set-mode read-only` returns `Internal error` for the claude adapter.
grep -q 'set-mode "$mode"' "$ISO_RP" && grep -q 'acp_confirm_mode "$workdir" "$acp_profile" "$acp_session" "$acp_iso_mode"' "$ISO_RP" \
  && ok "the verified re-pin uses the backend's own mode id (via acp_confirm_mode), not a hardcoded one" || fail "re-pin is still hardcoded to one provider's mode"
grep -q 'mode set: $mode' "$ISO_RP" \
  && ok "the re-pin still requires an EXACT success line, now per-mode" || fail "per-mode confirmation is not exact"
# The mode is pinned ONCE, before the canary: the live adapter returns "Internal error" on a repeat
# set-mode after any prompt, so a post-canary re-pin is impossible; the single pin holds because the
# mode is persistent owner state and a contained canary cannot move it. (live finding, 2026-09-08.)
grep -q '"pre-canary"' "$ISO_RP" && ! grep -q '"post-canary"' "$ISO_RP" && grep -q 'Internal error' "$ISO_RP" \
  && ok "the mode is pinned once before the canary (a post-canary re-pin is impossible on the live adapter)" || fail "the single pre-canary pin / live rationale is missing"
grep -q 'if \[ -n "$mount_dir" \] && \[ -n "$acp_iso_mode" \]' "$ISO_RP" \
  && ok "any backend carrying a mode is re-pinned, not just codex's" || fail "re-pin gate is still backend-specific"
# A claude turn must no longer fall through to the no-backend refusal.
sed -n '/^      case "$provider" in/,/^      esac/p' "$ISO_RP" | grep -q '^        claude)' \
  && ok "claude has its own isolation arm and no longer hits the no-backend refusal" || fail "claude still falls through to *)"
# The residual is RECORDED, not quietly dropped: this backend contains writes, not network.
sed -n '/^        claude)/,/^          ;;/p' "$ISO_RP" | grep -qi 'NETWORK IS STILL OPEN' \
  && ok "the claude arm records that network is NOT contained" || fail "the network residual is undocumented"
sed -n '/^        claude)/,/^          ;;/p' "$ISO_RP" | grep -qi 'KEYCHAIN' \
  && ok "the claude arm records why there is no credential isolation to add" || fail "the credential residual is undocumented"
# CLAUDE_CONFIG_DIR is deliberately NOT set: it isolates settings only and breaks auth.
sed -n '/^        claude)/,/^          ;;/p' "$ISO_RP" | grep -q 'CLAUDE_CONFIG_DIR' \
  && ! sed -n '/^        claude)/,/^          ;;/p' "$ISO_RP" | grep -q 'acp_iso=(env "CLAUDE_CONFIG_DIR' \
  && ok "the claude arm explains why it sets no config-home override rather than silently omitting it" || fail "CLAUDE_CONFIG_DIR omission is unexplained"

# ---- the claude analogue of the .codex/config.toml refusal ----
# It did not exist before this arm: enabling claude without it would have shipped the new
# backend with the confirmed provider-config vector still open for that provider.
for ISO_CFG in '.mcp.json' '.claude/settings.json' '.claude/settings.local.json'; do
  grep -q "$ISO_CFG" "$ISO_RP" \
    && ok "a reviewed tree carrying $ISO_CFG is refused for a mounted claude turn" || fail "$ISO_CFG is not refused"
done
grep -q 'content is not parsed' "$ISO_RP" \
  && ok "the claude config refusal is unconditional, not a bypassable content match" || fail "claude config refusal parses content"

# The refusal names the provider, the OS, and the way out. A mounted turn for a provider with no
# verified backend must DIE, not warn: silent degradation to an uncontained mount is exactly how
# this item gets marked done while staying open.
grep -q 'no verified isolation backend on' "$ISO_RP" \
  && ok "an unbacked provider's mounted turn is refused, not degraded" \
  || fail "the refusal for an unbacked provider is gone"
grep -q 'COMMS_RUNPHASE_ALLOW_UNCONTAINED' "$ISO_RP" \
  && ok "the uncontained escape hatch exists and is explicit" || fail "no operator override"
# The override must be OPT-IN. A default-on override is the same as no refusal at all.
grep -q 'COMMS_RUNPHASE_ALLOW_UNCONTAINED:-0' "$ISO_RP" \
  && ok "the uncontained override defaults to OFF" || fail "the override does not default off"

# Both halves of the codex backend are required and neither is sufficient: the adapter reads
# INITIAL_AGENT_MODE (not sandbox_mode) and defaults to AgentMode.Agent, so an isolated home
# alone leaves the turn in write mode -- measured.
grep -q 'INITIAL_AGENT_MODE=read-only' "$ISO_RP" \
  && ok "the codex backend pins INITIAL_AGENT_MODE=read-only" || fail "no INITIAL_AGENT_MODE pin"
grep -q 'CODEX_HOME=\$acp_iso_home' "$ISO_RP" \
  && ok "the codex backend runs from a parent-owned isolated home" || fail "no isolated CODEX_HOME"

# THE LIFECYCLE POINT. acpx spawns the persistent queue owner on the SEND when none exists, so
# isolation that wraps only `sessions ensure` leaves the process that actually runs tools
# unconfined. Every acpx invocation now routes through ONE wrapper (acp_exec) that applies both
# the per-provider isolation env AND the GIT_* scrub, so the invariant is "every owner-spawning
# call goes through the wrapper" rather than "N call sites each remembered to add acp_iso".
ISO_N="$(grep -c 'acp_exec "' "$ISO_RP")"
grep -q 'acp_iso\[@\]+"\${acp_iso\[@\]}"' "$ISO_RP" && [ "$ISO_N" -ge 3 ] \
  && ok "isolation wraps every owner-spawning acpx invocation via the acp_exec wrapper (n=$ISO_N)" \
  || fail "isolation does not route every acpx invocation through the wrapper (n=$ISO_N, want >= 3)"
# The wrapper also scrubs the GIT_* environment so a caller's GIT_DIR / GIT_WORK_TREE /
# GIT_COMMON_DIR cannot redirect the child's git out of the mount.
grep -q 'env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR' "$ISO_RP" \
  && ok "the acp wrapper scrubs GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR from the child env" \
  || fail "the acp wrapper does not scrub the GIT_* environment"

# INITIAL_AGENT_MODE is read ONCE, when the adapter builds sessionState -- it is not a
# process-lifetime lock, and `set_mode` accepts AgentFullAccess with no allowlist. With --ttl
# owner reuse, a turn that raised its own mode would leave the NEXT round unconfined. Re-pinning
# before every prompt is what makes the backend survive owner reuse.
grep -q 'set-mode "$mode"' "$ISO_RP" && grep -q 'acp_confirm_mode "$workdir" "$acp_profile" "$acp_session" "$acp_iso_mode".*pre-canary' "$ISO_RP" \
  && ok "the mode is re-pinned (via acp_confirm_mode) immediately before every prompt" || fail "no per-prompt mode pin"
awk '/acp_confirm_mode "\$workdir".*pre-canary/{m=NR} /acp_refuse containment-unconfirmed/{if (NR>m && m) f=1} END{exit !f}' "$ISO_RP" \
  && ok "an unconfirmed mode refuses the turn (acp_refuse) instead of sending it" || fail "an unpinnable mode still sends"
# THE PERMISSION SHAPE IS PART OF THE BOUNDARY for an in-process pin. Measured: under
# --approve-all the child was auto-approved out of `plan` via ExitPlanMode and its next write
# LANDED ON DISK; under --approve-reads + non-interactive deny, a forced ExitPlanMode call is
# rejected by the CLIENT while reads and `git log` still work.
sed -n '/if \[ "$acp_iso_backend" = "claude-plan" \]/,/fi/p' "$ISO_RP" | grep -q 'non-interactive-permissions deny' \
  && ok "a mode-pinned backend narrows the permission shape instead of --approve-all" || fail "claude-plan still runs under --approve-all"
sed -n '/if \[ "$acp_iso_backend" = "claude-plan" \]/,/fi/p' "$ISO_RP" | grep -q 'approve-reads' \
  && ok "the narrowed shape still approves reads, so the reviewer can do its job" || fail "narrowed shape blocks reads too"
# ...and the DEFAULT must stay --approve-all, or a mistaken indent would silently narrow CODEX
# too while every claude-plan grep above stayed green. (grok, implement r2, advisory.)
awk '/if \[ -n "\$mount_dir" \]; then/{f=1} f&&/acp_perm=\(--approve-all\)/{print;exit}' "$ISO_RP" | grep -q 'approve-all' \
  && ok "the mounted default is still --approve-all, so codex's shape is unchanged" || fail "the mounted default no longer grants --approve-all"
grep -qi 'ExitPlanMode' "$ISO_RP" \
  && ok "the escape that forced the narrowed shape is recorded at the site" || fail "the ExitPlanMode escape is undocumented"

# The confirmation must be EXACT and stdout-only, for WHICHEVER mode the backend pins. A glob
# over stdout+stderr passes on the adapter's REJECTION too ("Agent rejected session/set_mode for
# mode \"<id>\""), which interpolates the requested id and so contains the very string a loose
# match looks for —
# which would leave a reused owner in a write mode still prompted. Assert the check requires the
# exact success line AND rc 0, and does NOT fold stderr into the match. (grok, implement r1, blocking.)
grep -q '\[ "\$out" = "mode set: \$mode" \]' "$ISO_RP" \
  && ok "the mode confirmation is the exact acpx success line, not a substring" \
  || fail "the mode confirmation is a loose match a rejection error would satisfy"
grep -q '\[ "\$rc" -eq 0 \] && \[ "\$out" = "mode set: \$mode" \]' "$ISO_RP" \
  && ok "the mode confirmation also requires a zero exit status" || fail "the mode confirmation ignores rc"
# The set-mode capture must send stderr to the LOG, not into the matched output.
awk '/set-mode "\$mode" 2>>/{f=1} END{exit !f}' "$ISO_RP" \
  && ok "set-mode stderr goes to the log, never into the confirmation match" \
  || fail "set-mode still folds stderr into the matched output (2>&1)"
# The isolated home is refused if it is a symlink, and its realpath must be the intended sibling.
awk '/isolated CODEX_HOME path is a symlink/{f=1} END{exit !f}' "$ISO_RP" \
  && ok "a symlinked isolated home is refused, not followed out of the mount" \
  || fail "the isolated home would follow a symlink"
# Every isolation refusal — not just two of them — surfaces its reason in result.json rather
# than the generic abort-trap note. Count the refusal ABORT_NOTE assignments; a grep for one
# stays green on two while the symlink/mkdir/realpath/config paths still say "aborted
# unexpectedly". (grok + codex, implement r2, advisory.)
ISO_NOTES="$(grep -c 'ABORT_NOTE="refused:' "$ISO_RP")"
[ "$ISO_NOTES" -ge 5 ] \
  && ok "every isolation refusal names its reason ($ISO_NOTES paths), not just the first two" \
  || fail "only $ISO_NOTES isolation refusals name a reason; the rest fall to the generic abort note"
# The reused home's files are written FRESH and RENAMED into place, defeating a leftover
# symlink OR hard link at config.toml/auth.json (a `-L` check alone misses the hard link).
grep -q '_iso_place()' "$ISO_RP" \
  && ok "isolated home files are staged fresh and renamed, not overwritten in place" \
  || fail "no atomic stage-and-rename for the isolated home files"
grep -q 'command mv -f "\$_tmp" "\$_dst"' "$ISO_RP" \
  && ok "the stage is renamed over the dirent (defeats symlink and hard link)" \
  || fail "the isolated home write does not rename over the dirent"
# auth.json specifically goes through the atomic placer, not a bare cp that follows a symlink.
awk '/_iso_place "\$acp_src_home\/auth.json"/{f=1} END{exit !f}' "$ISO_RP" \
  && ok "auth.json is staged atomically, not copied through a possible symlink" \
  || fail "auth.json is still copied without symlink/hardlink safety"
# STALE-CREDENTIAL CLEAR. The persistent isolated home would otherwise keep an auth.json whose
# SOURCE was later removed/rotated, silently undoing the logout — the next mounted turn would run on
# a revoked credential. The else-branch removes the isolated copy, fail-closed.
# The shape check is bound to the SOURCE gate and requires the fail-closed recheck AFTER the rm, in
# order (stalecred r1, both reviewers): a bare /else$/ matched any of ~15 else lines, and a check
# that only proved else+rm would stay green if the recheck were deleted. Requiring the rm to sit
# after the source-gate else also rejects an INVERTED gate (clearing in the source-present branch).
# The codex Seatbelt backend itself is a reproducible-by-hand probe, as every isolation boundary here
# is (the suite stubs acpx and does not run a real codex turn); a functional codex fixture was tried
# and works standalone but is timing-fragile under this machine's load, so it is not committed.
awk '
  /\[ -f "\$acp_src_home\/auth.json" \] && \[ ! -L "\$acp_src_home\/auth.json" \]; then/{g=NR}
  g && /^ *else$/ && NR>g && NR<g+6 {e=NR}
  e && /rm -f "\$acp_iso_home\/auth.json"/ && NR>e {r=NR}
  r && /a stale isolated auth.json persists after its source credential was removed/ && NR>r {d=1}
  END{exit !(g&&e&&r&&d)}
' "$ISO_RP" \
  && ok "the stale-auth clear sits on the source gate with a fail-closed recheck after the rm" \
  || fail "the stale-auth clear is not bound to the source gate or lacks the fail-closed recheck"
# _iso_place refuses a non-regular-file dest (symlink-to-dir or real dir): `mv -f` there would
# deposit the staged file INSIDE the target and exit 0, silently leaving the read-only config
# absent. It unlinks a symlink dest first, refuses a directory, and verifies a regular file
# landed. (codex, implement r4, blocking.)
awk '/if \[ -L "\$_dst" \]; then rm -f "\$_dst"/{a=1} /\[ -e "\$_dst" \] && \[ ! -f "\$_dst" \]/{b=1} END{exit !(a&&b)}' "$ISO_RP" \
  && ok "_iso_place unlinks a symlink dest and refuses a directory dest" \
  || fail "_iso_place does not defend against a directory / symlink-to-dir dest"
awk '/command mv -f "\$_tmp" "\$_dst"/{m=NR} /\[ -f "\$_dst" \] && \[ ! -L "\$_dst" \] \|\| return 1/{if (NR>m && m) v=1} END{exit !v}' "$ISO_RP" \
  && ok "_iso_place verifies a regular file landed after the rename" \
  || fail "_iso_place does not verify the rename result"
# chmod fails closed (the mode is part of the contract, not advisory).
grep -q 'chmod "\$_mode" "\$_tmp" || { rm -f "\$_tmp"; return 1; }' "$ISO_RP" \
  && ok "_iso_place fails closed if the requested mode cannot be set" \
  || fail "_iso_place ignores a chmod failure"
# A mounted codex turn whose reviewed tree carries .codex/config.toml is REFUSED before spawn,
# regardless of content — codex reads it from the cwd and it can declare provider-side MCP that
# runs outside the sandbox. The refusal is CONTENT-INDEPENDENT: it tests for the file's
# existence, never greps it, because TOML quoted/space-padded keys make content-matching
# bypassable (both reviewers found the grep bypass). (codex + grok, implement r5, blocking.)
awk '/\[ -e "\$mount_dir\/.codex\/config.toml" \]/{a=1} /the reviewed tree carries .codex\/config.toml/{b=1} END{exit !(a&&b)}' "$ISO_RP" \
  && ok "a reviewed tree carrying .codex/config.toml is refused before the codex turn spawns" \
  || fail "a hostile .codex/config.toml is not refused before spawn"
# The refusal must NOT depend on parsing the file (no grep of the config): a content match is
# bypassable by quoted/space-padded TOML keys.
awk '/mount_dir\/.codex\/config.toml/ && /grep/{f=1} END{exit f}' "$ISO_RP" \
  && ok "the .codex/config.toml refusal does not grep the file (no bypassable content match)" \
  || fail "the .codex/config.toml refusal still content-matches the file"
# The mkdir refusal note is set on its OWN line, not as a prefix assignment that would not
# persist to the EXIT trap. Assert no ABORT_NOTE prefixes an mkdir on the same line.
grep -Eq 'ABORT_NOTE=.*mkdir' "$ISO_RP" \
  && fail "ABORT_NOTE is a prefix assignment on mkdir — it will not persist to the trap" \
  || ok "the mkdir refusal note is a standalone assignment that persists to the trap"
# The mounted-path boundary comment must name the kernel sandbox, not the retired GROK_SANDBOX lever.
grep -q 'GROK_SANDBOX applies to' "$ISO_RP" \
  && fail "a mounted-path comment still names COMMS_RUNPHASE_GROK_SANDBOX as the boundary" \
  || ok "the mounted-path boundary is described as the per-provider kernel sandbox, not GROK_SANDBOX"

# The isolated home is per-MOUNT, not per-message: under run_dir it would be rebuilt every round
# and the provider's own session state -- what warm resume is made of -- would be cold each time.
# It is now the home/ SIBLING of view/ that mount_alloc creates, always a validated external
# ident dir (durable or throwaway) — never the old ${mount_kdir:-$run_dir} in-repo fallback.
grep -q 'acp_iso_home="\$mount_kdir/home"' "$ISO_RP" \
  && ok "the isolated home is the per-mount home/ sibling, so warm resume survives" || fail "the isolated home is per-message"
# ...and it is a SIBLING of view/ (which holds tree/), never inside the verified artifact, so
# mount_tree_matches still verifies the artifact alone. The old $run_dir/codex-home fallback,
# a 7th in-repo landing for auth.json, is gone.
grep -q 'acp_iso_home="\$mount_kdir/home"' "$ISO_RP" \
  && ! grep -q 'mount_kdir:-\$run_dir}/codex-home' "$ISO_RP" \
  && ok "the isolated home sits beside view/, never inside the artifact, with no in-repo fallback" \
  || fail "the isolated home could contaminate the artifact or still has an in-repo fallback"

# The roadmap bullet that proposed --permission-policy as the fix is MEASURABLY FALSE (argv is
# never a match token). Leaving it in place is how the next agent implements the thing that does
# not work and marks the item done.
grep -q 'deny writes and non-git execs while still allowing' "$REPO/docs/ROADMAP.md" \
  && fail "the measurably-false --permission-policy lever is still proposed in ROADMAP" \
  || ok "the false --permission-policy lever is struck from the roadmap"
# ...and the item itself stays OPEN, because grok on Darwin is still uncontained.
grep -q 'open security item' "$REPO/docs/ROADMAP.md" \
  && ok "the open security item stays open while a dispatched provider is uncontained" \
  || fail "the security item was closed while grok remains uncontained"

# --- the reviewer model+effort policy gates -------------------------------------------
# THE ATTESTATION IS EXTRACTED AND RUN, not grepped. A source-shape assert cannot tell a
# working evidence reader from a broken one, and the bug this closes was invisible for three
# weeks precisely because every check was a string match.
ISO_RO="$(sed -n '/^acp_rollout_observed() {/,/^}/p' "$ISO_RP")"
ISO_RD="$WORK/rollout-probe"; rm -rf "$ISO_RD"; mkdir -p "$ISO_RD/sessions/2026/09/19"
ISO_RJ="$ISO_RD/sessions/2026/09/19/rollout-a.jsonl"
iso_ctx() { printf '{"type":"turn_context","payload":{"turn_id":"%s","root_turn_id":"%s","model":"%s","effort":"%s"}}\n' "$1" "$2" "$3" "$4"; }
iso_observed() { local _o _r; _o="$( ( eval "$ISO_RO"; acp_rollout_observed "$ISO_RD" "$1" ) 2>/dev/null )"; _r=$?; [ "$_r" -eq 0 ] || return "$_r"; printf '%s' "$_o" | cut -f1,2; }
ISO_SNAP="$(sed -n '/^acp_rollout_snapshot() {/,/^}/p' "$ISO_RP")"
iso_snapshot() { ( eval "$ISO_SNAP"; acp_rollout_snapshot "$1" "$2" ) 2>/dev/null; }

: > "$WORK/rollout-snap-empty.txt"
iso_ctx t-root t-root gpt-6-astra xhigh >> "$ISO_RJ"
[ "$(iso_observed "$WORK/rollout-snap-empty.txt")" = "$(printf 'xhigh\tgpt-6-astra')" ] \
  && ok "the attestation reads the effort and model the provider recorded for the turn" || fail "rollout read"

# B1: the record passed preflight, then the BILLABLE turn ran something else. The evidence
# must report what actually ran, not what was requested.
iso_snapshot "$ISO_RD" "$WORK/rollout-snap-b1.txt"
iso_ctx t-root2 t-root2 gpt-6-astra medium >> "$ISO_RJ"
[ "$(iso_observed "$WORK/rollout-snap-b1.txt")" = "$(printf 'medium\tgpt-6-astra')" ] \
  && ok "a replacement turn running a DIFFERENT effort is reported from the appended bytes (B1)" || fail "B1 transition not observed"

# Only the snapshot delta counts: an earlier matching context must never satisfy the gate.
iso_snapshot "$ISO_RD" "$WORK/rollout-snap-none.txt"
iso_observed "$WORK/rollout-snap-none.txt" >/dev/null 2>&1 \
  && fail "a pre-snapshot context satisfied the gate" \
  || ok "a matching context written BEFORE the prompt never counts as evidence"

# A replacement session starts a NEW jsonl; files that appeared after the snapshot count too.
ISO_RJ2="$ISO_RD/sessions/2026/09/19/rollout-b.jsonl"
iso_ctx t-new t-new gpt-6-astra low >> "$ISO_RJ2"
[ "$(iso_observed "$WORK/rollout-snap-none.txt")" = "$(printf 'low\tgpt-6-astra')" ] \
  && ok "a rollout file created after the snapshot is read (replacement session)" || fail "new-file evidence missed"

# Ambiguity and absence are UNDECIDABLE, never a pass.
iso_ctx t-new2 t-new2 gpt-6-astra xhigh >> "$ISO_RJ2"
iso_observed "$WORK/rollout-snap-none.txt" >/dev/null 2>&1 \
  && fail "two root contexts were accepted" || ok "two root turn_contexts in the window are undecidable, not a pass"
rm -f "$ISO_RJ2"
iso_snapshot "$ISO_RD" "$WORK/rollout-snap-all.txt"
iso_observed "$WORK/rollout-snap-all.txt" >/dev/null 2>&1 \
  && fail "absent evidence was accepted" || ok "no turn_context in the window is undecidable, not a pass"

# A non-root context must be ignored, or every honest turn would look ambiguous.
ISO_RJ3="$ISO_RD/sessions/2026/09/19/rollout-c.jsonl"
iso_ctx t-child t-parent gpt-6-astra xhigh >> "$ISO_RJ3"
iso_ctx t-solo  t-solo   gpt-6-astra xhigh >> "$ISO_RJ3"
[ "$(iso_observed "$WORK/rollout-snap-all.txt")" = "$(printf 'xhigh\tgpt-6-astra')" ] \
  && ok "a non-root turn_context is ignored rather than counted as a second root" || fail "non-root context miscounted"

# Missing identifiers must not compare equal to each other.
ISO_RJ4="$ISO_RD/sessions/2026/09/19/rollout-d.jsonl"
rm -f "$ISO_RJ3"
printf '{"type":"turn_context","payload":{"model":"gpt-6-astra","effort":"xhigh"}}\n' >> "$ISO_RJ4"
iso_observed "$WORK/rollout-snap-all.txt" >/dev/null 2>&1 \
  && fail "a context with no turn ids was accepted" || ok "two absent turn ids do not compare equal — the context is not treated as root"

# PLACEMENT. The attestation gates publication, so it must precede the stamp; and the
# identity write must stay where a kill -9 can still be identified.
ISO_ATT_LN="$(grep -n 'acp_rollout_observed "\$acp_iso_home"' "$ISO_RP" | head -1 | cut -d: -f1)"
ISO_STAMP_LN="$(grep -n 'broker_stamp_and_deliver "\$msg"' "$ISO_RP" | tail -1 | cut -d: -f1)"
[ -n "$ISO_ATT_LN" ] && [ -n "$ISO_STAMP_LN" ] && [ "$ISO_ATT_LN" -lt "$ISO_STAMP_LN" ] \
  && ok "the policy attestation runs BEFORE the review is published" || fail "attestation does not precede broker_stamp_and_deliver"
ISO_ID_LN="$(grep -n "printf 'provider\\\\t%s\\\\n'" "$ISO_RP" | head -1 | cut -d: -f1)"
[ -n "$ISO_ID_LN" ] && [ "$ISO_ID_LN" -lt "$ISO_ATT_LN" ] \
  && ok "the turn.tsv identity write still precedes the policy gate, so a dead runner keeps its identity" || fail "identity write moved"
awk '/turn_observe "\$run_dir"/{a=NR} /acp_refuse policy-unapplied "the review turn/{b=NR} END{exit !(a && b && a<b)}' "$ISO_RP" \
  && ok "observed columns are appended before the refusal unmounts the turn" || fail "divergence recorded after unwinding"

# B1/B2 (codex, implement r1). The snapshot was built with `find -exec stat`, whose exit
# status does NOT reflect a failing -exec (verified: `find . -exec false \;` exits 0), so the
# GNU fallback could never fire and the last resort wrote an EMPTY snapshot — under which old
# bytes read as newly appended. And the reader SKIPPED unreadable or malformed evidence rather
# than refusing it. Both are now fail-closed, and both are asserted by running the code.
ISO_SD="$WORK/snap-probe"; rm -rf "$ISO_SD"; mkdir -p "$ISO_SD/sessions/2026/09/19"
ISO_SF="$ISO_SD/sessions/2026/09/19/rollout-x.jsonl"
iso_ctx t-a t-a gpt-6-astra xhigh > "$ISO_SF"
iso_snapshot "$ISO_SD" "$WORK/snap-out.txt" \
  && [ "$(awk -F'\t' 'NF==3' "$WORK/snap-out.txt" | wc -l | tr -d ' ')" = 1 ] \
  && ok "the snapshot records path, inode and size for each rollout file" || fail "snapshot shape"
iso_snapshot "$ISO_SD" "/nonexistent-dir/snap.txt" \
  && fail "an unwritable snapshot reported success" || ok "a snapshot that cannot be written fails closed"

# A file REPLACED under us (same path, new inode) is not the continuation of what we
# snapshotted: reading it whole would let an old matching context satisfy the gate.
ISO_RD2="$WORK/rollout-identity"; rm -rf "$ISO_RD2"; mkdir -p "$ISO_RD2/sessions/2026/09/19"
ISO_RF2="$ISO_RD2/sessions/2026/09/19/rollout-y.jsonl"
iso_observed2() { local _o _r; _o="$( ( eval "$ISO_RO"; acp_rollout_observed "$ISO_RD2" "$1" ) 2>/dev/null )"; _r=$?; [ "$_r" -eq 0 ] || return "$_r"; printf '%s' "$_o" | cut -f1,2; }
iso_ctx t-old t-old gpt-6-astra xhigh > "$ISO_RF2"
iso_snapshot "$ISO_RD2" "$WORK/snap-id.txt"
rm -f "$ISO_RF2"; iso_ctx t-old t-old gpt-6-astra xhigh > "$ISO_RF2"   # new inode, same bytes
iso_observed2 "$WORK/snap-id.txt" >/dev/null 2>&1 \
  && fail "a replaced rollout file was accepted" || ok "a rollout file replaced during the turn is undecidable, not re-read whole"

# TRUNCATION likewise: the old offset no longer bounds anything.
iso_ctx t-1 t-1 gpt-6-astra xhigh > "$ISO_RF2"; iso_ctx t-2 t-2 gpt-6-astra xhigh >> "$ISO_RF2"
iso_snapshot "$ISO_RD2" "$WORK/snap-tr.txt"
iso_ctx t-3 t-3 gpt-6-astra xhigh > "$ISO_RF2"                          # shrank
iso_observed2 "$WORK/snap-tr.txt" >/dev/null 2>&1 \
  && fail "a truncated rollout file was accepted" || ok "a rollout file truncated during the turn is undecidable"

# MALFORMED evidence is refused, not skipped: skipping let a garbled record hide a divergent
# context behind an earlier matching one.
iso_ctx t-ok t-ok gpt-6-astra xhigh > "$ISO_RF2"
iso_snapshot "$ISO_RD2" "$WORK/snap-mal.txt"
iso_ctx t-good t-good gpt-6-astra xhigh >> "$ISO_RF2"; printf '{"type":"turn_context" BROKEN\n' >> "$ISO_RF2"
iso_observed2 "$WORK/snap-mal.txt" >/dev/null 2>&1 \
  && fail "malformed evidence was skipped" || ok "a malformed record in the window is undecidable, not skipped"

# A record still being written is a write in flight, not evidence.
iso_ctx t-ok2 t-ok2 gpt-6-astra xhigh > "$ISO_RF2"
iso_snapshot "$ISO_RD2" "$WORK/snap-part.txt"
printf '{"type":"turn_context","payload":{"turn_id":"t-p","root_turn_id":"t-p","effort":"xhigh"' >> "$ISO_RF2"
iso_observed2 "$WORK/snap-part.txt" >/dev/null 2>&1 \
  && fail "a partial trailing record was accepted" || ok "a rollout ending mid-record is undecidable"

# An unparseable SNAPSHOT means the window is unbounded — refuse rather than treat as empty.
printf 'garbage-with-no-tabs\n' > "$WORK/snap-bad.txt"
iso_observed2 "$WORK/snap-bad.txt" >/dev/null 2>&1 \
  && fail "an unreadable snapshot was treated as empty" || ok "an unreadable snapshot entry is undecidable, not an empty window"

# The snapshot is taken by the same python that reads it -- no find/stat whose -exec failure
# the shell cannot see.
grep -q 'find .*-exec stat' "$ISO_RP" \
  && fail "the rollout snapshot still uses find -exec stat" \
  || ok "the rollout snapshot is enumerated by the same reader, not by find -exec stat"
awk '/acp_rollout_snapshot "\$acp_iso_home"/{a=NR} /acp_refuse policy-unapplied "could not enumerate/{b=NR} END{exit !(a && b && b>a && b-a<6)}' "$ISO_RP" \
  && ok "a snapshot failure refuses BEFORE the prompt is sent" || fail "snapshot failure does not refuse pre-prompt"

# B1 (codex, implement r2): python's glob SUPPRESSES directory-scanning errors internally, so
# `except OSError` around it never fired — an unreadable subtree produced an EMPTY snapshot,
# under which pre-existing bytes read as newly appended. Verified: glob returns [] on a 0o000
# directory rather than raising. The walk must propagate instead.
ISO_PD="$WORK/perm-probe"; rm -rf "$ISO_PD"; mkdir -p "$ISO_PD/sessions/2026/09/19"
iso_ctx t-p t-p gpt-6-astra xhigh > "$ISO_PD/sessions/2026/09/19/rollout-p.jsonl"
chmod 000 "$ISO_PD/sessions/2026/09/19" 2>/dev/null
if [ "$(id -u)" = 0 ]; then
  chmod 755 "$ISO_PD/sessions/2026/09/19" 2>/dev/null
  ok "an unreadable rollout subtree fails the snapshot (skipped detail: running as root)"
else
  iso_snapshot "$ISO_PD" "$WORK/snap-perm.txt" \
    && { chmod 755 "$ISO_PD/sessions/2026/09/19" 2>/dev/null; fail "an unreadable rollout subtree produced a successful snapshot"; } \
    || { chmod 755 "$ISO_PD/sessions/2026/09/19" 2>/dev/null; ok "an unreadable rollout subtree fails the snapshot instead of yielding an empty one"; }
fi
grep -q 'onerror=_boom' "$ISO_RP" \
  && ok "rollout enumeration propagates directory-scan errors rather than suppressing them" || fail "enumeration still suppresses scan errors"

# B2 (codex, implement r2): a snapshotted file RENAMED after the snapshot reappears under a new
# pathname at offset zero, so its old context reads as newly appended.
ISO_RN="$WORK/rollout-rename"; rm -rf "$ISO_RN"; mkdir -p "$ISO_RN/sessions/2026/09/19"
iso_observed3() { ( eval "$ISO_RO"; acp_rollout_observed "$ISO_RN" "$1" ) 2>/dev/null; }
iso_ctx t-r t-r gpt-6-astra xhigh > "$ISO_RN/sessions/2026/09/19/rollout-orig.jsonl"
iso_snapshot "$ISO_RN" "$WORK/snap-rn.txt"
mv "$ISO_RN/sessions/2026/09/19/rollout-orig.jsonl" "$ISO_RN/sessions/2026/09/19/rollout-moved.jsonl"
iso_observed3 "$WORK/snap-rn.txt" >/dev/null 2>&1 \
  && fail "a renamed old rollout passed as new evidence" || ok "a snapshotted rollout that vanished (renamed) is undecidable"

# An unattributable context must be REFUSED, not skipped: skipping let a divergent context with
# no ids hide behind an earlier matching one.
ISO_UA="$WORK/rollout-unattr"; rm -rf "$ISO_UA"; mkdir -p "$ISO_UA/sessions/2026/09/19"
iso_observed4() { ( eval "$ISO_RO"; acp_rollout_observed "$ISO_UA" "$1" ) 2>/dev/null; }
: > "$WORK/snap-ua.txt"
{ iso_ctx t-m t-m gpt-6-astra xhigh
  printf '{"type":"turn_context","payload":{"model":"gpt-6-astra","effort":"medium"}}\n'
} > "$ISO_UA/sessions/2026/09/19/rollout-u.jsonl"
iso_observed4 "$WORK/snap-ua.txt" >/dev/null 2>&1 \
  && fail "a divergent context with no ids hid behind a matching one" || ok "a turn_context carrying no identifiers is refused, not skipped"

# STEP 3 — the attestation must capture ATTRIBUTION at read time. Once unmount_artifact removes
# a throwaway home the rollout is gone, so a refusal that recorded only effort/model cannot be
# reconstructed afterwards. (codex, live-proof r1.)
ISO_AT="$WORK/rollout-attrib"; rm -rf "$ISO_AT"; mkdir -p "$ISO_AT/sessions/2026/09/19"
ISO_AF="$ISO_AT/sessions/2026/09/19/rollout-attr.jsonl"
iso_observed5() { ( eval "$ISO_RO"; acp_rollout_observed "$ISO_AT" "$1" ) 2>/dev/null; }
: > "$WORK/snap-attr.txt"
iso_ctx t-attr t-attr gpt-6-astra xhigh > "$ISO_AF"
ISO_AT_OUT="$(iso_observed5 "$WORK/snap-attr.txt")"
[ "$(printf '%s' "$ISO_AT_OUT" | awk -F'\t' '{print NF}')" = 5 ] \
  && ok "the attestation returns effort, model, turn id, evidence file and byte offset" || fail "attribution fields missing (got: $ISO_AT_OUT)"
[ "$(printf '%s' "$ISO_AT_OUT" | cut -f3)" = "t-attr" ] \
  && ok "the backend turn id of the attested context is captured" || fail "turn id not captured"
[ "$(printf '%s' "$ISO_AT_OUT" | cut -f4)" = "$ISO_AF" ] \
  && ok "the rollout file the evidence came from is captured" || fail "evidence path not captured"
# turn_observe writes them, and still records unknown rather than a blank for absent evidence.
ISO_TO="$(sed -n '/^turn_observe() {/,/^}/p' "$ISO_RP")"
ISO_TD="$WORK/turnobs"; rm -rf "$ISO_TD"; mkdir -p "$ISO_TD"
( eval "$ISO_TO"; turn_observe "$ISO_TD" xhigh gpt-6-astra rec-1 t-attr /r/x.jsonl 42 )
grep -qx "observed_turn	t-attr" "$ISO_TD/turn.tsv" && grep -qx "evidence_offset	42" "$ISO_TD/turn.tsv" \
  && ok "turn.tsv records the backend turn id and the snapshot byte boundary" || fail "turn.tsv attribution columns missing"
( eval "$ISO_TO"; turn_observe "$ISO_TD" "" "" "" "" "" "" )
grep -qx "observed_turn	unknown" "$ISO_TD/turn.tsv" \
  && ok "absent attribution records unknown, never a blank column" || fail "blank attribution column"

# B1 (codex, attribution r1): the CALLER's field split, which the reader-level probes above
# bypass entirely. `IFS=$'\t' read` treats tab as IFS whitespace, so an empty column collapses
# and every later field shifts left — a context missing its effort was reported as a policy
# MISMATCH carrying the model in the effort slot, instead of missing evidence. Extract the real
# split from the source and run it, so this cannot regress to `read`.
ISO_SPLIT="$(sed -n '/att_eff="\$(printf/,/att_off="\$(printf/p' "$ISO_RP")"
iso_split() { ( att_out="$1"; eval "$ISO_SPLIT"; printf '%s|%s|%s|%s|%s' "$att_eff" "$att_mod" "$att_turn" "$att_src" "$att_off" ); }
[ "$(iso_split "$(printf 'xhigh\tgpt-6-astra\tt-1\t/r/a.jsonl\t42')")" = "xhigh|gpt-6-astra|t-1|/r/a.jsonl|42" ] \
  && ok "a complete observation splits into its five fields" || fail "complete split (got $(iso_split "$(printf 'xhigh\tgpt-6-astra\tt-1\t/r/a.jsonl\t42')"))"
[ "$(iso_split "$(printf 'xhigh\t\tt-1\t/r/a.jsonl\t42')")" = "xhigh||t-1|/r/a.jsonl|42" ] \
  && ok "an EMPTY model does not shift the remaining fields left" || fail "empty model shifted the split (got $(iso_split "$(printf 'xhigh\t\tt-1\t/r/a.jsonl\t42')"))"
[ "$(iso_split "$(printf '\tgpt-6-astra\tt-1\t/r/a.jsonl\t42')")" = "|gpt-6-astra|t-1|/r/a.jsonl|42" ] \
  && ok "an EMPTY effort does not shift the remaining fields left" || fail "empty effort shifted the split"
grep -q "IFS=\$'\\\\t' read -r att_eff" "$ISO_RP" \
  && fail "the caller split regressed to a field-collapsing read" \
  || ok "the caller does not split the observation with a whitespace-IFS read"
# ...and the shift had a SEMANTIC cost: an empty effort must stay undecidable (21), never a
# mismatch (21 vs 20 is the difference between "no evidence" and "ran the wrong depth").
AP_S="$REPO/helpers/acp.sh"
"$AP_S" policy-attest codex "$(iso_split "$(printf '\tgpt-6-astra\tt-1\t/r/a.jsonl\t42')" | cut -d'|' -f1)" \
        "$(iso_split "$(printf '\tgpt-6-astra\tt-1\t/r/a.jsonl\t42')" | cut -d'|' -f2)" >/dev/null 2>&1
[ "$?" = 21 ] && ok "a missing effort reaches the verdict as undecidable, not as a mismatch" || fail "missing effort misclassified"

# STEP 3 PROPER — REQUESTED vs OBSERVED must be separable in the ledger. Recording only what a
# turn was observed to run reproduces the blindness this whole arc exists to fix: for three weeks
# a declared depth and an executed depth were assumed equal because nothing wrote both down.
ISO_TO2="$(sed -n '/^turn_observe() {/,/^}/p' "$ISO_RP")"
ISO_RQ="$WORK/turnobs-req"; rm -rf "$ISO_RQ"; mkdir -p "$ISO_RQ"
( acp_sh="$REPO/helpers/acp.sh"; eval "$ISO_TO2"; turn_observe "$ISO_RQ" medium gpt-6-astra rec-9 t-9 /r/y.jsonl 7 )
grep -qx "requested_effort	xhigh" "$ISO_RQ/turn.tsv" \
  && ok "turn.tsv records the REQUESTED effort from the policy accessor" || fail "requested effort missing"
grep -qx "requested_model	gpt-6-astra" "$ISO_RQ/turn.tsv" \
  && ok "turn.tsv records the REQUESTED model" || fail "requested model missing"
# The divergence must be legible from the file alone, with no mount and no rollout.
grep -qx "observed_effort	medium" "$ISO_RQ/turn.tsv" && grep -qx "requested_effort	xhigh" "$ISO_RQ/turn.tsv" \
  && ok "a requested/observed divergence is readable from turn.tsv without the mount" || fail "divergence not legible"
# The requested pair must come from the ACCESSOR, not be a second literal that can drift.
mkdir -p "$ISO_RQ-ov"
( acp_sh="$REPO/helpers/acp.sh"; eval "$ISO_TO2"
  COMMS_ACP_CODEX_EFFORT=high turn_observe "$ISO_RQ-ov" xhigh gpt-6-astra r t f 0 ) 2>/dev/null
grep -qx "requested_effort	high" "$ISO_RQ-ov/turn.tsv" 2>/dev/null \
  && ok "the requested pair tracks the policy accessor, not a second hardcoded copy" || fail "requested pair does not follow the accessor"
# An unreachable accessor records unknown rather than silently claiming the default.
mkdir -p "$ISO_RQ-na"
( acp_sh=/nonexistent/acp.sh; eval "$ISO_TO2"; turn_observe "$ISO_RQ-na" xhigh gpt-6-astra r t f 0 ) 2>/dev/null
grep -qx "requested_effort	unknown" "$ISO_RQ-na/turn.tsv" 2>/dev/null \
  && ok "an unreachable policy accessor records requested=unknown, never an assumed default" || fail "unreachable accessor did not record unknown"

# A refusal must be RECOVERABLE. `acpx <profile> sessions close` alone does not retire a MOUNTED
# session: the record is keyed by (agent, cwd, name), so a hint that omits the session name and
# the workdir sends the operator to close the wrong thing, every resend refuses again, and the
# panel stays pending — a wedged loop rather than a retryable refusal. (codex, installed-path
# deployment probe.)
for _h in 'the reviewer session will not run the declared' 'the review turn did not run the declared'; do
  _line="$(grep -n "$_h" "$ISO_RP" | head -1 | cut -d: -f1)"
  _txt="$(sed -n "${_line}p" "$ISO_RP")"
  case "$_txt" in
    *'sessions close $acp_session'*) : ;;
    *) fail "a policy refusal hint omits the session name: ${_h}"; continue ;;
  esac
  # The pasted command must stand alone: an operator who copies only what is between the
  # backticks, from the main checkout, must still resolve the right (agent, cwd, name) tuple.
  # Naming the directory in surrounding prose is not enough. acpx takes --cwd as a GLOBAL
  # option, so it must precede the profile. (grok, recoverable r1.)
  case "$_txt" in
    *'acpx --cwd $_q_wd $acp_profile sessions close $acp_session'*)
      ok "the copyable retirement command carries an ESCAPED --cwd before the profile (${_h})" ;;
    *) fail "a policy refusal hint does not carry an escaped --cwd inside the command: ${_h}" ;;
  esac
done

# A directory only NAMED in prose tolerates a space; one INTERPOLATED into a command the operator
# pastes does not. The previous round moved the path into executable text and so introduced this:
# a mount base like `/private/tmp/review mounts` rendered `--cwd /private/tmp/review` plus a stray
# argument, retirement failed, and the stale session survived — the exact wedge the hint exists to
# prevent. Assert the RENDERED command, not the source line. (codex, recoverable r2 B1.)
iso_render() { local workdir="$1" acp_profile=codex acp_session=S _q_wd
  printf -v _q_wd '%q' "$workdir"
  printf 'acpx --cwd %s %s sessions close %s' "$_q_wd" "$acp_profile" "$acp_session"; }
ISO_SP="$(iso_render '/private/tmp/review mounts/x')"
printf '%s' "$ISO_SP" | grep -q 'review\\ mounts' \
  && ok "a workdir containing a space renders as ONE shell argument" || fail "space in workdir splits the pasted command (got: $ISO_SP)"
# The rendered command must parse back to the exact directory, spaces and all.
ISO_BACK="$(eval "set -- $(printf '%s' "$ISO_SP" | sed 's/^acpx //')"; printf '%s' "$2")"
[ "$ISO_BACK" = '/private/tmp/review mounts/x' ] \
  && ok "the rendered --cwd argument parses back to the exact directory" || fail "cwd did not round-trip (got: $ISO_BACK)"
ISO_QT="$(iso_render "/tmp/it's a mount")"
printf '%s' "$ISO_QT" | grep -q "it" \
  && [ "$(eval "set -- $(printf '%s' "$ISO_QT" | sed 's/^acpx //')"; printf '%s' "$2")" = "/tmp/it's a mount" ] \
  && ok "a workdir containing a quote survives rendering intact" || fail "quote in workdir broke the rendered command"
