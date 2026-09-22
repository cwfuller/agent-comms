# Minimal, per-worker fixtures. Builders never run prerequisite assertions.
# NOTHING in this suite may write the developer's REAL external mount store. Mounts now live
# outside the repo under ${XDG_STATE_HOME:-$HOME/.local/state}/agent-comms/mounts by default, so
# any mounted turn that does not set COMMS_MOUNT_BASE (the acp-parity, MA-fixture and shadow turns)
# would land in ~/.local/state. Point the whole suite at a throwaway under $WORK; the warm-mount,
# relocation and the explicit accessor tests still override this per-turn in the child env, and the
# default-base test also overrides HOME, so those keep exercising the real code paths.
export COMMS_MOUNT_BASE="$WORK/suite-mounts/agent-comms/mounts"
# NOTHING in this suite may touch the real global rollup. `friction` appends to
# ${AGENT_COMMS_HOME:-$HOME/.agent-comms}/friction.tsv, and the fixture calls below were
# writing straight into the developer's own ledger: 74 of 86 rows in it were this suite's
# "compose reported a false all-clear" fixture note, drowning the real reports the seam
# exists to collect. Suite-wide default; individual tests still override it explicitly.
export AGENT_COMMS_HOME="$WORK/global-home"
mkdir -p "$AGENT_COMMS_HOME"
# The Codex protocol note is now a GLOBAL asset, so an unsandboxed --scope=global run in this
# corpus would rewrite the developer's own ~/.codex/AGENTS.md. Suite-wide default, set beside
# the other global-asset redirections; the block section still overrides it per fixture.
export CODEX_AGENTS_FILE="$WORK/global-home/codex-AGENTS.md"
# THE REVIEW BAR IS AN INSTALLED ASSET, so the suite must PROVIDE it rather than inherit whatever
# the developer happens to have installed. Every fixture that runs a review turn through a copied
# or shimmed runphase.sh resolves the bar through this home: the repo tier is
# $HELPER_DIR/../docs/..., which does not exist for a shim, and before the bar moved these turns
# were silently satisfied by the developer's real ~/.codex/skills. That made the suite's result
# depend on the machine — green here, red on a clean checkout or CI. Staging it here is the fix,
# and the fragments come from their canonical home so this cannot drift. (S3-1.)
# NAMED, not globbed: this suite forbids enumerating the filesystem for corpus paths (a glob lets
# a candidate delete a tracked file, recreate it untracked, and keep the counts stable). Naming
# the two fragments the RUNTIME actually reads is also the more honest fixture — it states the
# dependency instead of hoovering up whatever happens to be on disk.
mkdir -p "$AGENT_COMMS_HOME/loopspec-fragments"
for _f in verdict-discipline holistic-rereview; do
  cp "$REPO/docs/loopspec/fragments/$_f.md" "$AGENT_COMMS_HOME/loopspec-fragments/$_f.md" 2>/dev/null || true
done
unset _f
# Canonicalize (pwd -P) so comparisons survive macOS /var -> /private/var.
REPO_FIX="$WORK/fixture-repo"
mkdir -p "$REPO_FIX"
REPO_FIX="$(cd "$REPO_FIX" && pwd -P)"
git -C "$REPO_FIX" init -q -b feature/helper-tests
git -C "$REPO_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$REPO_FIX/.comms/to-claude" "$REPO_FIX/.comms/to-codex" "$REPO_FIX/.comms/archive"

# cmux stub: serves canned output, logs every invocation
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
# cmux stub DELETED (S4-4). STUB_BIN above survives: the grok stub and the ACP fixtures
# still live there. The canned tree/list fixtures and CMUX_STUB_* levers went with the
# transport they served.
run_comms() { (cd "$REPO_FIX" && env "$COMMS" "$@"); }
export CODEX_STUB_LOG="$WORK/codex.log"
RUNPHASE="$REPO/helpers/runphase.sh"

rundir_of() { echo "$1" | sed -n 's/^ *run dir: //p' | head -1; }
run_rp() { (cd "$REPO_FIX" && env COMMS_DELIVERY=headless COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 PATH="$STUB_BIN:$PATH" "$RUNPHASE" "$@"); }
run_headless() { (cd "$REPO_FIX" && env COMMS_DELIVERY=headless PATH="$STUB_BIN:$PATH" "$COMMS" "$@"); }

# The grok stub is hoisted ABOVE step 2 (step 4, S4-2): headless is now grok-only, so the
# hold/release coverage below needs a provider that can still spawn on that transport.

export GROK_STUB_LOG="$WORK/grok.log"
cat > "$STUB_BIN/grok" <<'GSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "${GROK_STUB_LOG:-/dev/null}"
# GROK_STUB_HANG mirrors CODEX_STUB_HANG: the killed-runner fixture needs a child that outlives
# its budget. It moved to grok when codex lost the headless path in step 4 (S4-2).
[ -n "${GROK_STUB_HANG:-}" ] && sleep "$GROK_STUB_HANG"
pf=""; prev=""
for a in "$@"; do [ "$prev" = "--prompt-file" ] && pf="$a"; prev="$a"; done
[ -n "$pf" ] && [ -f "$pf" ] || { echo "stub: no prompt file" >&2; exit 2; }
# streaming-messages-json shape (live 1.0.5): init event carries session_id and
# the final result event carries the COMPLETE reply text. Under the
# parent-stamped envelope the child emits ONLY a VERDICT line (reviews) + body.
esc() { printf '%s' "$1" | awk '{gsub(/\t/, "\\t"); printf "%s\\n", $0}'; }
printf '{"type":"system","subtype":"init","session_id":"stub-grok-session-1"}\n'
# A turn that emits no result event at all: the extractor finds no reply text, which is the
# loudest broker failure there is and the one that used to leave no durable record.
[ -n "${GROK_STUB_NO_RESULT:-}" ] && exit 0
printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"narration to ignore"}]}}\n'
if [ -n "${GROK_STUB_NO_VERDICT:-}" ]; then
  REPLY="$(printf -- '## Summary\nreview without any verdict line')"
elif [ -n "${GROK_STUB_BAD_VERDICT:-}" ]; then
  REPLY="$(printf -- 'VERDICT: SHIP_IT\n\n## Summary\nnonstandard verdict value')"
elif [ -n "${GROK_STUB_EMPTY_BODY:-}" ]; then
  REPLY="$(printf -- 'VERDICT: APPROVE')"
elif [ -n "${GROK_STUB_DUP_VERDICT:-}" ]; then
  # line-1 APPROVE + a later REQUEST_CHANGES: ambiguous, derivation must decide
  REPLY="$(printf -- 'VERDICT: APPROVE\nnarration\nVERDICT: REQUEST_CHANGES\n\n## Findings\n### Blocking\n- a real blocking finding\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_LEAD_TOKEN:-}" ]; then
  # No VERDICT line, and a Blocking section whose finding is a lead-token line rather than a
  # list item — byte-for-byte the shape of the real codex reply that DERIVED APPROVE over a
  # genuine attestation defect on 2026-08-27.
  REPLY="$(printf -- '## Summary\nreview with an unreadable blocking section\n\n## Findings\n### Blocking\n\nblocking\ttests/run.sh:4948\tattestation is not bound to the tested commit\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_LIE_APPROVE:-}" ]; then
  # unique explicit APPROVE that contradicts its own findings
  REPLY="$(printf -- 'VERDICT: APPROVE\n\n## Findings\n### Blocking\n1. a real blocking finding the verdict ignores\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_LIE_APPROVE_LOWER:-}" ]; then
  # The canonical-cased lie-approve stub could not see this: the cross-check gate was a
  # case-sensitive grep while the parser was case-tolerant, so `### blocking` skipped the
  # check entirely and stamped APPROVE over a real finding.
  REPLY="$(printf -- 'VERDICT: APPROVE\n\n## Findings\n### blocking\n- a real blocking finding the verdict ignores\n\n### advisory\n- None.')"
elif [ -n "${GROK_STUB_LATE_VERDICT:-}" ]; then
  # A SOLE, valid verdict pushed past line 40 by a long preamble. The old scan
  # window stopped at 40, so this reply read as having no verdict at all.
  REPLY="$(printf -- 'thinking out loud\n%s\nVERDICT: REQUEST_CHANGES\n\n## Findings\n### Blocking\n- a real blocking finding\n\n### Advisory\n- None.' "$(i=0; while [ $i -lt 45 ]; do printf 'preamble line %s\n' "$i"; i=$((i+1)); done)")"
elif [ -n "${GROK_STUB_DUP_FAR:-}" ]; then
  # line-1 APPROVE with the contradicting REQUEST_CHANGES beyond line 40. Under the
  # window only the line-1 APPROVE was visible, so vcount==1 and the broker trusted
  # it -- a false all-clear that a long enough reply could always produce.
  REPLY="$(printf -- 'VERDICT: APPROVE\n%s\nVERDICT: REQUEST_CHANGES\n\n## Findings\n### Blocking\n- a real blocking finding\n\n### Advisory\n- None.' "$(i=0; while [ $i -lt 45 ]; do printf 'narration line %s\n' "$i"; i=$((i+1)); done)")"
elif [ -n "${GROK_STUB_QUOTED_VERDICT:-}" ]; then
  # A round-N reply QUOTING round N-1 inside a fenced block. Scanning the whole file
  # without skipping fences would read the quote as a second verdict and go ambiguous.
  # Quotes a COMPLETE prior review, not just its verdict line. Quoting only the verdict
  # masked the real path: the verdict scan skipped the fence but the findings parser did
  # not, so the quoted blocker failed the body cross-check and killed a clean round.
  REPLY="$(printf -- 'VERDICT: APPROVE\n\n## Prior round\n```\nVERDICT: REQUEST_CHANGES\n### Blocking\n- an OLD blocker from the round before\n```\n\n## Findings\n### Blocking\n- None.\n\n### Advisory\n- None.')"
elif [ -n "${GROK_STUB_PREAMBLE_NUMBERED:-}" ]; then
  # the field incident, end to end: preamble pushes the (absent) verdict off
  # line 1, findings are NUMBERED, and one real item ENDS in "None."
  REPLY="$(printf -- 'Skill descriptions were shortened to fit context.\nReviewing the handoff now.\n\n## Findings\n### Blocking\n1. helper.sh can incorrectly return None.\n\n### Advisory\n- None.')"
else
  REPLY="$(printf -- 'VERDICT: %s\n\n## Summary\nstub review of the handoff\n\n## Findings\n### Blocking\n- none' "${GROK_STUB_VERDICT:-APPROVE}")"
fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$(esc "$REPLY")"
GSTUB
chmod +x "$STUB_BIN/grok"


RP="$REPO/helpers/runphase.sh"

fixture_ma() {
MA_FIX="$WORK/ma-repo"; mkdir -p "$MA_FIX"; MA_FIX="$(cd "$MA_FIX" && pwd -P)"
git -C "$MA_FIX" init -q -b feature/ma-tests
git -C "$MA_FIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$MA_FIX/.comms/to-claude" "$MA_FIX/.comms/to-codex" "$MA_FIX/.comms/archive"
run_ma() { (cd "$MA_FIX" && env "$COMMS" "$@"); }
MA_WS="$(run_ma workspace)"

printf 'agents = claude codex grok\ndefault-target = codex\n' > "$MA_FIX/.comms/config"
MA_TS="2026-08-20T09-00-00"
MA_MSG="$MA_FIX/.comms/to-grok/${MA_WS}_${MA_TS}_review-req-1.md"
mkdir -p "$MA_FIX/.comms/to-grok"
cat > "$MA_MSG" <<MAEOF
---
type: review-request
from: claude
timestamp: 2026-08-20T14:00:00Z
workspace: $MA_WS
message_id: ${MA_WS}_${MA_TS}_review-req-1
thread: ma-arc-1
workflow: auto-full
phase: plan
round: 1
max-rounds: 4
---

## Plan
review this plan
MAEOF
}

fixture_ma_archive() {
  fixture_ma
  mv "$MA_MSG" "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
}
fixture_acp() {
AXD="$WORK/acp-parity"; AXB="$AXD/bin"; mkdir -p "$AXB"
cat > "$AXB/npx" <<'AXSTUB'
#!/bin/bash
# The acpx surface runphase's --via acp branch actually calls. `sessions show` MUST emit a
# cwd line: a mounted turn asserts that the bound record's cwd is the mount, and a stub
# that stays silent fails that assert closed on every mounted suite turn. cwd is reported
# as `pwd -P`, because acpx records process.cwd() (physical) and $WORK is a logical
# mktemp path -- a $PWD stub would refuse every legitimate turn on macOS.
# AX_CWD_LOG records every invocation's cwd so a test can observe the CHILD's directory
# rather than grepping runphase.sh for a path expression.
ax_test_root="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P)"
ax_rollout_ok() {  # the DESTINATION must be inside the suite work root
  [ -n "${CODEX_HOME:-}" ] || return 1
  [ -n "$ax_test_root" ] || return 1
  case "$(cd "$CODEX_HOME" 2>/dev/null && pwd -P)" in
    "$ax_test_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}
if [ -n "${AX_CWD_LOG:-}" ]; then
  printf '%s\t%s\n' "$(pwd -P)" "$*" >> "$AX_CWD_LOG"
fi
# AX_CFG_LOG captures the isolated config THE PROVIDER ACTUALLY SAW. The mount is unmounted
# when the turn ends, so a test cannot read config.toml afterwards; recording it from inside
# the child is both possible and stronger evidence than the parent re-reading its own write.
if [ -n "${AX_CFG_LOG:-}" ] && [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/config.toml" ]; then
  cat "$CODEX_HOME/config.toml" >> "$AX_CFG_LOG" 2>/dev/null || true
fi
# THE PROVIDER FIXES ITS POLICY WHEN A SESSION IS CREATED. Real codex reads model/effort from the
# isolated config.toml at thread start and then sends its OWN in-memory values on every prompt; a
# resumed session is NOT known to adopt a changed config. The stub models exactly that: `sessions
# ensure` of a NEW record captures the config into the record, and every later show/prompt of that
# session reports the CAPTURED pair. AX_RESUME_ADOPTS=1 models the other possibility (a resume
# that re-reads the config). Explicit AX_MODEL / AX_EFFORT still win, for divergence tests; with no
# config at all the historic gpt-6-astra/xhigh defaults apply.
ax_cfg_model=""; ax_cfg_effort=""
if [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/config.toml" ]; then
  ax_cfg_model="$(sed -n 's/^model = "\(.*\)"$/\1/p' "$CODEX_HOME/config.toml" | head -1)"
  ax_cfg_effort="$(sed -n 's/^model_reasoning_effort = "\(.*\)"$/\1/p' "$CODEX_HOME/config.toml" | head -1)"
fi
ax_sname=""; ax_prev=""
for ax_a in "$@"; do
  { [ "$ax_prev" = "-s" ] || [ "$ax_prev" = "show" ] || [ "$ax_prev" = "--name" ]; } && ax_sname="$ax_a"
  ax_prev="$ax_a"
done
ax_rec=""
if [ -n "$ax_sname" ] && [ -n "${HOME:-}" ] && [ -f "$HOME/.acpx-test-store" ]; then
  if [ -n "${AX_RECORD_ID:-}" ]; then ax_rec="$HOME/.acpx/sessions/$AX_RECORD_ID.json"
  else ax_rec="$HOME/.acpx/sessions/stub-$(printf '%s' "$ax_sname" | shasum -a 256 2>/dev/null | cut -c1-12).json"; fi
fi
ax_cap_model=""; ax_cap_effort=""
if [ -n "$ax_rec" ] && [ -f "$ax_rec" ] && [ -z "${AX_RESUME_ADOPTS:-}" ]; then
  ax_cap_model="$(sed -n 's/^  "stub_model": "\(.*\)",$/\1/p' "$ax_rec" | head -1)"
  ax_cap_effort="$(sed -n 's/^  "stub_effort": "\(.*\)",$/\1/p' "$ax_rec" | head -1)"
fi
[ -n "${AX_MODEL:-}" ] || AX_MODEL="${ax_cap_model:-$ax_cfg_model}"
[ -n "${AX_EFFORT:-}" ] || AX_EFFORT="${ax_cap_effort:-$ax_cfg_effort}"
[ -n "$AX_MODEL" ] || unset AX_MODEL
[ -n "$AX_EFFORT" ] || unset AX_EFFORT
case " $* " in
  *" sessions ensure "*)
    # The session NAME drives the record id below, so it must be parsed before it is used.
    ax_name=""; ax_prev=""
    for ax_a in "$@"; do [ "$ax_prev" = "--name" ] && ax_name="$ax_a"; ax_prev="$ax_a"; done
    # Real acpx PERSISTS the record under $HOME/.acpx/sessions/<id>.json, and runphase now
    # uses that file's presence to prove a record belongs to the store it is about to probe
    # for a queue lease. A stub that only printed an id would make every same-home legacy
    # record look foreign, so model the write too.
    # Derive the id from the session NAME, as acpx does per (agent, cwd, name). A single
    # shared id would leave one record whose cwd is whatever ran last, so every other
    # session would fail corroboration and degrade.
    if [ -n "${AX_RECORD_ID:-}" ]; then ax_id="$AX_RECORD_ID"
    else ax_id="stub-$(printf '%s' "$ax_name" | shasum -a 256 2>/dev/null | cut -c1-12)"; fi
    [ -n "$ax_id" ] || ax_id=stub-record-1
    # ONLY into a store the suite marked as its own. Without this the stub wrote into the
    # user's real ~/.acpx/sessions whenever a turn did not override HOME.
    if [ -n "${HOME:-}" ] && [ -f "$HOME/.acpx-test-store" ]; then
      mkdir -p "$HOME/.acpx/sessions" 2>/dev/null
      # A RESUMED record keeps the pair it was created with; only a new record captures the
      # config the parent just wrote. (See the capture note at the top of this stub.)
      ax_keep_m=""; ax_keep_e=""
      if [ -f "$HOME/.acpx/sessions/$ax_id.json" ]; then
        ax_keep_m="$(sed -n 's/^  "stub_model": "\(.*\)",$/\1/p' "$HOME/.acpx/sessions/$ax_id.json" | head -1)"
        ax_keep_e="$(sed -n 's/^  "stub_effort": "\(.*\)",$/\1/p' "$HOME/.acpx/sessions/$ax_id.json" | head -1)"
      fi
      # PRETTY-PRINTED, two-space indent, as acpx writes it: the production reader matches
      # `^  "cwd": "..."`, and a single-line record silently failed that match.
      printf '{\n  "schema": "acpx.session.v1",\n  "acpx_record_id": "%s",\n  "cwd": "%s",\n  "name": "%s",\n  "stub_model": "%s",\n  "stub_effort": "%s",\n  "closed": false\n}\n' \
        "$ax_id" "${AX_LIE_CWD:-$(pwd -P)}" "$ax_name" "${ax_keep_m:-${ax_cfg_model:-gpt-6-astra}}" "${ax_keep_e:-${ax_cfg_effort:-xhigh}}" \
        > "$HOME/.acpx/sessions/$ax_id.json" 2>/dev/null || true
    fi
    printf '%s\t(%s)\n' "$ax_id" "${AX_ENSURE_STATE:-created}"; exit 0 ;;
  *" sessions show "*)
    # --format json is a GLOBAL flag and precedes the profile, so it is matched on the whole
    # argv. The policy preflight reads this shape; the text shape below stays for the cwd
    # binding assert. AX_MODEL/AX_EFFORT drive the reported config_options, AX_SHOW_NO_OPTS
    # omits the list (the JetBrains-client shape), AX_SHOW_JSON_GARBAGE emits unparseable
    # bytes -- both must land as UNDECIDABLE, never as a pass.
    case " $* " in
      *" --format json "*)
        if [ -n "${AX_SHOW_JSON_GARBAGE:-}" ]; then printf 'not json at all\n'; exit 0; fi
        if [ -n "${AX_SHOW_NO_OPTS:-}" ]; then
          printf '{"acpx":{"acpx_record_id":"stub"},"cwd":"%s"}\n' "${AX_LIE_CWD:-$(pwd -P)}"; exit 0
        fi
        # AX_DESIRED_EFFORT models a SAVED preference acpx would replay onto a replacement
        # session -- distinct from the current options, and the thing the pre-canary
        # refuse-and-retire check exists for. (codex, implement r3 advisory.)
        if [ -n "${AX_DESIRED_EFFORT:-}" ]; then
          printf '{"cwd":"%s","acpx":{"acpx_record_id":"stub","config_options":[{"id":"model","currentValue":"%s"},{"id":"reasoning_effort","currentValue":"%s"}],"desired_config_options":{"reasoning_effort":"%s"}}}\n' \
            "${AX_LIE_CWD:-$(pwd -P)}" "${AX_MODEL:-gpt-6-astra}" "${AX_EFFORT:-xhigh}" "$AX_DESIRED_EFFORT"
          exit 0
        fi
        printf '{"cwd":"%s","acpx":{"acpx_record_id":"stub","config_options":[{"id":"model","currentValue":"%s"},{"id":"reasoning_effort","currentValue":"%s"}]}}\n' \
          "${AX_LIE_CWD:-$(pwd -P)}" "${AX_MODEL:-gpt-6-astra}" "${AX_EFFORT:-xhigh}"
        exit 0 ;;
    esac
    printf 'name: stub\n'
    printf 'cwd: %s\n' "${AX_LIE_CWD:-$(pwd -P)}"
    exit 0 ;;
  *" set-mode "*)
    # set-mode <mode> — echo acpx's success line. AX_SETMODE_CT counts calls; AX_SETMODE_FAIL_ON
    # names the 1-based call that must REJECT (2 = the post-canary re-pin), and a rejection
    # interpolates the requested id exactly as acpx does, so a loose stdout match would pass on it.
    ax_mode=""; for ax_a in "$@"; do ax_mode="$ax_a"; done
    if [ -n "${AX_SETMODE_CT:-}" ]; then
      ax_c=0; [ -f "$AX_SETMODE_CT" ] && ax_c="$(cat "$AX_SETMODE_CT" 2>/dev/null || echo 0)"
      ax_c=$((ax_c + 1)); printf '%s' "$ax_c" > "$AX_SETMODE_CT"
      if [ -n "${AX_SETMODE_FAIL_ON:-}" ] && [ "$ax_c" = "$AX_SETMODE_FAIL_ON" ]; then
        printf 'Agent rejected session/set_mode for mode "%s": denied\n' "$ax_mode"; exit 1
      fi
    fi
    printf 'mode set: %s\n' "$ax_mode"; exit 0 ;;
esac
# --- compatibility canary: a bare -s prompt (no --file). The real prompt has --file and falls
# through to the payload below. AX_CANARY selects the outcome. (compat-gate tests.)
case " $* " in
  *" --file "*) : ;;                       # real prompt -> payload
  *" -s "*)
    case "${AX_CANARY:-pong}" in
      pong)    printf 'PONG\n' ;;
      crlf)    printf 'PONG\r\n' ;;                       # a compliant answer with CRLF line endings
      trailwarn) printf 'PONG\nWarning: ignore me\n' ;;   # framing AFTER the answer must NOT be stripped
      error)   printf 'Warning: stale\n\n{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"the runtime cannot serve this model"}}\n' ;;
      timeout) exit 3 ;;
      exit)    printf 'PONG\n'; printf '[acpx] tokens: input=1 output=1 cache_read=0 total=2\n'; exit "${AX_CANARY_EXIT:-5}" ;;
      junk)    printf 'I cannot return just PONG.\n' ;;
    esac
    # THE CANARY IS A PROMPT TOO, so real codex records a turn_context for it. Emitting one
    # here means the snapshot has pre-prompt bytes to exclude: an empty or broken snapshot now
    # shows TWO roots and refuses, instead of looking honest. (codex + grok, implement r3.)
    if ax_rollout_ok && [ -z "${AX_ROLLOUT_NONE:-}" ] && [ -z "${AX_NO_CANARY_ROLLOUT:-}" ]; then
      ax_cd="$CODEX_HOME/sessions/2026/09/19"; mkdir -p "$ax_cd" 2>/dev/null
      printf '{"type":"turn_context","payload":{"turn_id":"t-canary","root_turn_id":"t-canary","model":"%s","effort":"%s"}}\n' \
        "${AX_MODEL:-gpt-6-astra}" "${AX_EFFORT:-xhigh}" >> "$ax_cd/rollout-stub.jsonl" 2>/dev/null || true
    fi
    printf '[acpx] tokens: input=1 output=1 cache_read=0 total=2\n'
    exit 0 ;;
esac
if [ -n "${ACP_PARITY_PROBE:-}" ]; then
  { printf 'git=%s\n' "$(command -v git)"; printf 'PATH=%s\n' "$PATH"; } > "$ACP_PARITY_PROBE"
fi
# THE PROVIDER'S OWN ROLLOUT. Real codex appends a turn_context per prompt under
# $CODEX_HOME/sessions/<Y>/<M>/<D>/rollout-*.jsonl carrying the model and effort it actually
# ran; the post-turn attestation reads the bytes appended during THIS prompt. The stub models
# that so the gate is exercised against the real shape rather than a convenient one.
#   AX_ROLLOUT_EFFORT / AX_ROLLOUT_MODEL — what the turn "really" ran (default: the preflight
#     values, i.e. the honest case). Setting only these two reproduces B1: preflight passes
#     from the record while the billable turn runs something else.
#   AX_ROLLOUT_NEW_FILE — append to a NEW jsonl, as a replacement session does.
#   AX_ROLLOUT_NONE     — write nothing (evidence missing -> undecidable).
#   AX_ROLLOUT_DOUBLE   — two root contexts (ambiguous -> undecidable).
if ax_rollout_ok && [ -z "${AX_ROLLOUT_NONE:-}" ]; then
  ax_rd="$CODEX_HOME/sessions/2026/09/19"; mkdir -p "$ax_rd" 2>/dev/null
  ax_rf="$ax_rd/rollout-stub.jsonl"
  [ -n "${AX_ROLLOUT_NEW_FILE:-}" ] && ax_rf="$ax_rd/rollout-stub-replacement.jsonl"
  ax_re="${AX_ROLLOUT_EFFORT:-${AX_EFFORT:-xhigh}}"
  ax_rm="${AX_ROLLOUT_MODEL:-${AX_MODEL:-gpt-6-astra}}"
  # A non-root context (turn_id != root_turn_id) must be IGNORED by the reader, so emit one
  # every time: a gate that counted it would see ambiguity on every honest turn.
  printf '{"type":"turn_context","payload":{"turn_id":"t-child","root_turn_id":"t-root","model":"%s","effort":"%s"}}\n' \
    "$ax_rm" "$ax_re" >> "$ax_rf" 2>/dev/null || true
  printf '{"type":"turn_context","payload":{"turn_id":"t-root","root_turn_id":"t-root","model":"%s","effort":"%s"}}\n' \
    "$ax_rm" "$ax_re" >> "$ax_rf" 2>/dev/null || true
  [ -n "${AX_ROLLOUT_DOUBLE:-}" ] && printf '{"type":"turn_context","payload":{"turn_id":"t-root2","root_turn_id":"t-root2","model":"%s","effort":"%s"}}\n' \
    "$ax_rm" "$ax_re" >> "$ax_rf" 2>/dev/null
fi
# A mounted --approve-all child can write. AX_CHILD_WRITE plants residue at an untracked
# AND an ignored path, so a restage can be shown to clear both.
if [ -n "${AX_CHILD_WRITE:-}" ]; then
  printf '%s' "$AX_CHILD_WRITE" > ./child-residue.txt 2>/dev/null || true
  mkdir -p ./.comms 2>/dev/null && printf '%s' "$AX_CHILD_WRITE" > ./.comms/child-ignored.txt 2>/dev/null || true
fi
# AX_FAIL_RC drives a FAILED acp turn. Without it the ACP path had only happy-path coverage for
# claude/codex, so deleting the headless arm would have removed the ONLY tests of provider-aware
# failure reporting for those two. (contraction step 4, S4-2: add the ACP equivalent BEFORE the
# removal — codex, plan r1, blocking.)
[ -n "${AX_FAIL_RC:-}" ] && { printf 'stub acpx failure\n' >&2; exit "$AX_FAIL_RC"; }
cat "$ACP_PARITY_PAYLOAD"
exit 0
AXSTUB
chmod +x "$AXB/npx"
cat > "$AXB/node" <<'AXNODE'
#!/bin/bash
echo "v22.22.3"
AXNODE
chmod +x "$AXB/node"
}
