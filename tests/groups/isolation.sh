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
