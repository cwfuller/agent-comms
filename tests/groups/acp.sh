# Run through tests/run.sh; each group gets fresh fixtures.
fixture_ma_archive
# The installer assertion needs an installed fixture, not the earlier installer tests.
INST_FIX="$WORK/install-repo"
mkdir -p "$INST_FIX"
git -C "$INST_FIX" init -q -b main
(cd "$INST_FIX" && bash "$REPO/install.sh" --scope=local >/dev/null 2>&1)
section "transports emit the child\'s bytes, verbatim and identically"
# Criterion 8 by construction. The streaming extractor is a python block inside runphase.sh;
# ACP redirects acpx stdout with no transformation at all. So the extractor must be a pure
# pass-through of the result string — a single appended LF made an empty reply a one-byte file
# on one transport and an empty file on the other, which are DIFFERENT failure paths.
# (codex, round 8.)
BX="$WORK/byte-extract"; mkdir -p "$BX"
python3 - "$REPO/helpers/runphase.sh" "$BX/extract.py" <<'PYX'
import io, sys, re
src = io.open(sys.argv[1], encoding="utf-8").read()
i = src.index("import json")
j = src.index("PYX", i)
io.open(sys.argv[2], "w", encoding="utf-8").write(src[i:j])
PYX
bx() {  # <result-string> -> the bytes the streaming path would write
  # The extractor reads an events file as argv[1], the same way the runner invokes it.
  python3 -c "
import json,subprocess,sys
ev = json.dumps({'type':'result','subtype':'success','is_error':False,'result':sys.argv[1]})
open(sys.argv[3],'w').write(ev+chr(10))
r = subprocess.run([sys.executable, sys.argv[2], sys.argv[3]], capture_output=True, text=True)
sys.stdout.write(r.stdout)
" "$1" "$BX/extract.py" "$BX/events.ndjson"
}
for CASE in "plain" "" "no-trailing-lf" "leading
blank" "trailing
"; do
  GOT="$(bx "$CASE"; printf X)"; GOT="${GOT%X}"
  [ "$GOT" = "$CASE" ] && ok "streaming emits the result verbatim (${#CASE} bytes)" \
    || fail "streaming altered the bytes (in ${#CASE}, out ${#GOT})"
done
FENCED='```
### Blocking
- x
```'
GOT="$(bx "$FENCED"; printf X)"; GOT="${GOT%X}"
[ "$GOT" = "$FENCED" ] && ok "a whole-answer fence reaches the lexer intact on streaming" \
  || fail "streaming still unwraps a whole-answer fence"

# Criterion 8 was only HALF proven. Everything above exercises the STREAMING extractor and
# then asserted parity with a transport it never ran — the ACP path was asserted about, not
# invoked. ACP redirects acpx stdout straight into reply-raw.md, so the only way to know the
# two agree is to run the real path with a stub that emits chosen bytes and compare what
# lands on disk against what streaming emits for the same result string. (codex, round 10.)
fixture_acp
# Run the REAL ACP leg of runphase and hand back the reply-raw.md it produced.
acp_raw() {  # <payload-file> <n> -> path to the reply-raw.md the ACP path wrote
  local pay="$1" n="$2" msg dir
  msg="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T09-56-00_parity-$n.md"
  sed -e "s/^thread: ma-arc-1\$/thread: ma-arc-parity-$n/" \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  dir="$WORK/ma-parity-$n"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$pay" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$msg" --dir "$dir" \
      --provider grok --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir/reply-raw.md"
}
# NEGATIVE CONTROL first: if the comparison cannot see a one-byte difference, every parity
# result below is vacuous. Feed the ACP stub bytes that DIFFER from what streaming emits and
# require the comparison to notice.
printf 'parity-control' > "$AXD/payload"
AXCTL="$(acp_raw "$AXD/payload" 0)"
bx 'parity-control-DIFFERENT' > "$AXD/stream-ctl.out"
if cmp -s "$AXCTL" "$AXD/stream-ctl.out"; then
  fail "the transport parity comparison is blind — it calls differing bytes identical"
else
  ok "the transport parity comparison can see a difference (it can fail)"
fi
axn=0
for CASE in "plain" "" "no-trailing-lf" "leading
blank" "trailing
"; do
  axn=$(( axn + 1 ))
  printf '%s' "$CASE" > "$AXD/payload"
  AXRAW="$(acp_raw "$AXD/payload" "$axn")"
  bx "$CASE" > "$AXD/stream.out"
  if [ ! -e "$AXRAW" ]; then
    fail "the ACP path wrote no reply-raw.md at all (${#CASE} bytes)"
  elif cmp -s "$AXRAW" "$AXD/stream.out"; then
    ok "ACP and streaming write byte-identical replies (${#CASE} bytes)"
  else
    fail "transports disagree on ${#CASE} bytes (acp $(wc -c <"$AXRAW" | tr -d " "), streaming $(wc -c <"$AXD/stream.out" | tr -d " "))"
  fi
done
# The fence case is the one that broke criterion 8 in the field: streaming unwrapped a
# whole-answer fence that ACP left alone, so identical bytes were a review on one transport
# and a no-structure refusal on the other.
printf '%s' "$FENCED" > "$AXD/payload"
AXRAW="$(acp_raw "$AXD/payload" 9)"
bx "$FENCED" > "$AXD/stream.out"
cmp -s "$AXRAW" "$AXD/stream.out" \
  && ok "a whole-answer fence survives identically on BOTH transports" \
  || fail "the transports disagree on a whole-answer fence"

section "acp.sh: consult transport (stubbed npx)"
ACP="$REPO/helpers/acp.sh"
ACP_STUB="$WORK/acp-bin"; mkdir -p "$ACP_STUB"
export ACP_STUB_LOG="$WORK/acp.log"
cat > "$ACP_STUB/npx" <<'NSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "${ACP_STUB_LOG:-/dev/null}"
[ -n "${ACP_STUB_EXIT:-}" ] && exit "$ACP_STUB_EXIT"
# ACP_STUB_EMPTY models the rc-0-zero-bytes turn (a dropped or empty model reply): the prompt
# exits 0 having produced nothing, which the consult must refuse rather than pass as success.
case " $* " in
  *" sessions ensure "*) [ -n "${ACP_STUB_ENSURE_FAIL:-}" ] && { echo "ensure diagnostic on stdout"; exit 4; }
     echo "stub-session-id (created)" ;;
  *" exec "*|*" -s "*) [ -n "${ACP_STUB_EMPTY:-}" ] && exit 0
     # ACP_STUB_API_ERROR is the live 2026-09-08 shape: a rejected model, exit 0, the API error
     # as the whole answer. ACP_STUB_ERRORISH is its negative control — prose that QUOTES one.
     [ -n "${ACP_STUB_API_ERROR:-}" ] && { printf 'Warning: Model metadata for `gpt-6-astra` not found.\n\n{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The model requires a newer version of Codex."}}\n\n'; exit 0; }
     [ -n "${ACP_STUB_ERRORISH:-}" ] && { echo 'stub answer: what you saw was {"error":{"message":"x"}} - a config problem'; echo "[acpx] tokens: input=1 output=1 cache_read=0 total=2"; exit 0; }
     [ -n "${ACP_STUB_OUT_THEN_FAIL:-}" ] && { echo "partial before failure"; exit 5; }
     echo "stub answer"; echo "[acpx] tokens: input=100 output=5 cache_read=25000 total=25105" ;;
  *) echo "stub answer"; echo "[acpx] tokens: input=100 output=5 cache_read=25000 total=25105" ;;
esac
NSTUB
chmod +x "$ACP_STUB/npx"
cat > "$ACP_STUB/node" <<'NODESTUB'
#!/bin/bash
echo "${ACP_STUB_NODE_V:-v22.22.3}"
NODESTUB
chmod +x "$ACP_STUB/node"

run_acp() { PATH="$ACP_STUB:$PATH" bash "$ACP" "$@"; }
OUT="$(run_acp consult codex is the retry approach sound 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'stub answer' && ok "consult passes the answer through" || fail "consult happy path (rc=$rc)"
grep -q -- '-y acpx@0.13.1 --timeout 300 codex sessions ensure --name agent-comms-ask' "$ACP_STUB_LOG" \
  && ok "warm consult ensures the pinned named session WITH a --timeout (a stalled ensure cannot hang)" || fail "session ensure argv/timeout"
grep -q -- '-y acpx@0.13.1 --format quiet --timeout 300 --approve-reads --non-interactive-permissions deny codex -s agent-comms-ask is the retry approach sound' "$ACP_STUB_LOG" \
  && ok "warm consult prompts the named session with the pinned acpx and a --timeout" || fail "warm prompt argv"
# A consult that cannot read is useless — it would answer from recall instead of the
# tree. Denied permissions killed a real consult mid-answer before this was added.
grep -q -- '--approve-reads' "$ACP_STUB_LOG" && ok "consults may READ the tree" || fail "consult read approval"
grep -q -- '--non-interactive-permissions deny' "$ACP_STUB_LOG" \
  && ok "consults still refuse writes (prompting is impossible here)" || fail "consult write denial"
# SILENT-SUCCESS GUARD: acpx can exit 0 having produced nothing (a dropped or empty turn). Passing
# that through hands the caller a blank answer with a success status and no diagnostic — the rc-0-
# zero-bytes hole. The consult must refuse it with the mailbox fallback. (ROADMAP field item.)
OUT="$(ACP_STUB_EMPTY=1 run_acp consult codex --oneshot hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -qi 'no answer' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "a rc-0 consult with an empty answer is refused, not passed as success" \
  || fail "an empty consult answer read as success (rc=$rc, out: $(echo "$OUT" | head -1))"
# rc 0 with the provider's API ERROR as the whole answer — the same hole one layer up (field
# report 2026-09-08). Refused with the provider's message and the fallback; and because the
# predicate is structural, an answer that merely quotes such an envelope still passes.
OUT="$(ACP_STUB_API_ERROR=1 run_acp consult codex --oneshot hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'provider API error' && echo "$OUT" | grep -q 'newer version of Codex' \
  && echo "$OUT" | grep -qi 'mailbox' \
  && ok "a rc-0 consult whose answer is the provider's API error is refused, naming the error" \
  || fail "an API-error consult answer read as success (rc=$rc, out: $(echo "$OUT" | head -1))"
OUT="$(ACP_STUB_ERRORISH=1 run_acp consult codex --oneshot hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'config problem' \
  && ok "an answer that merely quotes an error envelope passes through" || fail "error-quoting answer refused (rc=$rc)"
# The reply-check DIAGNOSTIC temp file is best-effort: if its allocation fails (an unwritable TMPDIR),
# the consult must STILL refuse an API-error answer with the mailbox fallback — never abort silently
# before die_fb under set -e. (codex, impl r2, blocking.)
OUT="$(TMPDIR=/no/such/dir/for/consult ACP_STUB_API_ERROR=1 run_acp consult codex --oneshot hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'provider API error' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "an API-error consult still refuses (with fallback) when the diagnostic temp file cannot be allocated" \
  || fail "an unwritable TMPDIR aborted the consult before its refusal (rc=$rc, out: $(echo "$OUT" | head -1))"
# A malformed --timeout budget falls back to the default rather than taking the turn down.
: > "$ACP_STUB_LOG"
COMMS_ACP_CONSULT_TIMEOUT_SECS=notanumber run_acp consult codex ping >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a malformed consult --timeout budget falls back to the default" || fail "malformed consult timeout not defaulted"
: > "$ACP_STUB_LOG"
run_acp consult codex --oneshot quick check >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads --non-interactive-permissions deny codex exec quick check' "$ACP_STUB_LOG" \
  && ! grep -q -- '-s agent-comms-ask' "$ACP_STUB_LOG" \
  && ok "--oneshot uses stateless exec with a --timeout, no session" || fail "oneshot argv"
# A leading-zero budget NORMALIZES base-10 (08 -> 8), not rejected as octal nor passed as 010. (grok r1.)
: > "$ACP_STUB_LOG"
COMMS_ACP_CONSULT_TIMEOUT_SECS=08 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 8 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a leading-zero consult timeout normalizes base-10 (08 -> 8)" || fail "leading-zero timeout not normalized"
# An OVERSIZED digit budget falls back to the default rather than WRAPPING through arithmetic
# (2^64 -> 0, huge -> unrelated positive) — the text sanitizer rejects >6 digits before any math. (codex r2.)
: > "$ACP_STUB_LOG"
COMMS_ACP_CONSULT_TIMEOUT_SECS=18446744073709551616 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads' "$ACP_STUB_LOG" \
  && ok "an oversized consult timeout falls back to the default (no integer overflow)" || fail "oversized timeout wrapped instead of defaulting"
# Digit-count boundary: exactly 6 digits is honoured, 7 falls back (the sane_secs length gate). (grok r3.)
: > "$ACP_STUB_LOG"; COMMS_ACP_CONSULT_TIMEOUT_SECS=999999 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 999999 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a 6-digit consult timeout (999999) is honoured" || fail "a valid 6-digit timeout was rejected"
: > "$ACP_STUB_LOG"; COMMS_ACP_CONSULT_TIMEOUT_SECS=1000000 run_acp consult codex --oneshot z >/dev/null 2>&1
grep -q -- '--timeout 300 --approve-reads' "$ACP_STUB_LOG" \
  && ok "a 7-digit consult timeout (1000000) falls back to the default" || fail "a 7-digit timeout was not rejected"
# A FAILING sessions ensure surfaces its stdout diagnostic instead of dropping it to /dev/null. (codex r2.)
OUT="$(ACP_STUB_ENSURE_FAIL=1 run_acp consult codex hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'ensure diagnostic on stdout' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "a failing sessions ensure surfaces its captured stdout diagnostic" \
  || fail "a failing ensure's stdout is dropped (rc=$rc)"
# A FAILING acpx still surfaces its stdout, so the 'see output above' error branches are truthful. (both r1.)
OUT="$(ACP_STUB_OUT_THEN_FAIL=1 run_acp consult codex --oneshot hi 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'partial before failure' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "a failing consult surfaces acpx's captured stdout (see-output-above is true)" \
  || fail "captured stdout dropped on a failing consult (rc=$rc)"
QF="$WORK/acp-q.md"; printf 'excerpted discussion\n' > "$QF"
: > "$ACP_STUB_LOG"
run_acp consult codex --file "$QF" >/dev/null 2>&1
grep -q -- "--file $QF" "$ACP_STUB_LOG" && ok "file-form payload passes through" || fail "file-form argv"
for code in 2 3 4 5 130 7; do
  OUT="$(ACP_STUB_EXIT=$code run_acp consult codex hello 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && echo "$OUT" | grep -qi 'mailbox' && ! echo "$OUT" | grep -qi 'retry'; then
    ok "exit-$code maps: nonzero + mailbox fallback + no retry advice"
  else
    fail "exit-$code contract (rc=$rc, out: $(echo "$OUT" | head -1))"
  fi
done
OUT="$(run_acp consult codex hello --file 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q -- '--file requires a path' && echo "$OUT" | grep -qi 'mailbox' \
  && ok "trailing --file dies with diagnostic + fallback" || fail "trailing --file guard (rc=$rc)"
pf_check() {  # pf_check <desc> <args...> — nonzero + mailbox + no retry advice
  local desc="$1"; shift
  local out rc=0
  out="$(run_acp "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && echo "$out" | grep -qi 'mailbox' && ! echo "$out" | grep -qi 'retry'; then
    ok "preflight failure carries fallback: $desc"
  else
    fail "preflight fallback missing: $desc (rc=$rc, out: $(echo "$out" | head -1))"
  fi
}
pf_check "missing agent" consult
pf_check "missing question" consult codex
pf_check "empty --file value" consult codex --file "" hello
pf_check "nonexistent --file path" consult codex --file "$WORK/does-not-exist.md"
# Measurement consistency: one arithmetic, stated identically on every surface.
if grep -rn '134x' "$REPO/helpers" "$REPO/docs" "$REPO/templates" >/dev/null 2>&1; then
  fail "stale 134x ratio still published somewhere"
else
  ok "no stale measurement ratio published"
fi
for mf in "$REPO/helpers/acp.sh" "$REPO/docs/INTERNALS.md" "$REPO/docs/COMMANDS.md"; do
  grep -q '18,562' "$mf" && grep -q '127x' "$mf" \
    && ok "measurement consistent in $(basename "$mf")" || fail "measurement surfaces in $(basename "$mf")"
done
OUT="$(ACP_STUB_NODE_V=v18.0.0 run_acp consult codex hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'Node >= 22.13' && ok "node version gate fails closed with guidance" || fail "node gate"
OUT="$(ACP_STUB_NODE_V=v18.0.0 run_acp doctor 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 3 ] && ok "doctor exits 3 without a usable node" || fail "doctor node gate (rc=$rc)"
: > "$ACP_STUB_LOG"
# gemini has no ACP profile here; grok DOES since 2026-08-25 (acpx `grok-build`,
# verified against `acpx --help` and one live consult).
OUT="$(run_acp consult gemini hello 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'mailbox path' && [ ! -s "$ACP_STUB_LOG" ] \
  && ok "an agent with no ACP profile fails closed before any acpx call" || fail "unsupported-agent refusal"
for acp_a in codex claude grok; do
  bash "$REPO/helpers/acp.sh" supports "$acp_a" >/dev/null 2>&1 \
    && ok "acp supports $acp_a" || fail "acp supports $acp_a"
done
bash "$REPO/helpers/acp.sh" supports gemini >/dev/null 2>&1 \
  && fail "acp claims to support an unprofiled agent" || ok "acp supports probe is machine-readable and refuses gemini"
grep -q 'ACPX_VERSION="0.13.1"' "$ACP" && ok "acpx version is pinned in one place" || fail "acpx pin"
[ -x "$INST_FIX/.agent-comms/acp.sh" ] && ok "local install ships an executable acp.sh" || fail "local install acp.sh"
grep -qF '"$ACP_SH" consult' "$REPO/templates/claude-commands/ask.md" \
  && grep -q -- '--via acp' "$REPO/templates/claude-commands/ask.md" \
  && grep -q 'Do NOT retry the ACP path' "$REPO/templates/claude-commands/ask.md" \
  && ok "ask.md carries the ACP transport with fallback discipline" || fail "ask.md ACP source contract"
grep -q 'Parse BOTH transport modifiers out' "$REPO/templates/claude-commands/ask.md" \
  && grep -qF 'consult "$TARGET" --oneshot --file' "$REPO/templates/claude-commands/ask.md" \
  && grep -q 'if and only if the user' "$REPO/templates/claude-commands/ask.md" \
  && ok "ask.md parses and conditionally forwards --oneshot" || fail "ask.md oneshot forwarding contract"
grep -q 'acp.sh' "$REPO/install.sh" && ok "installer ships acp.sh" || fail "installer acp.sh"

section "runphase: the compatibility canary gates every ACP turn"
# A canary — a bare `Reply with PONG` prompt into the SAME session, same argv shape — must run and
# pass before the real prompt is spent. It proves the session runtime can serve its model, catching
# a stale bundled adapter (the 2026-09-08 field cause) BEFORE the expensive review turn. grok has no
# isolation mode, so these turns exercise the canary WITHOUT the mode-confirm noise; a codex turn
# below adds the double mode-confirm. All turns are mounted under the suite throwaway store.
CANARY_PAY="$WORK/canary-payload.md"
cat > "$CANARY_PAY" <<'CPAY'
VERDICT: APPROVE

## Summary
the real review turn ran because the canary passed

## Findings
### Blocking
- None.

### Advisory
- None.
CPAY
run_canary_turn() {  # <tag> <AX_CANARY value> [extra env kv...] -> echoes the run dir
  local tag="$1" canary="$2"; shift 2
  local msg dir
  mkdir -p "$MA_FIX/.comms/to-grok"
  msg="$MA_FIX/.comms/to-grok/${MA_WS}_2026-08-20T12-00-00_canary-$tag.md"
  sed -e "s/^thread: ma-arc-1\$/thread: ma-canary-$tag/" \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  dir="$WORK/canary-$tag"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$CANARY_PAY" \
      AX_CANARY="$canary" COMMS_RUNPHASE_ALLOW_UNCONTAINED=1 \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$@" \
      "$RP" run --message "$msg" --dir "$dir" --provider grok --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}
cn_status() { sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }
cn_reason() { sed -n 's/.*"reason": "\([^"]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }

# PASS: a healthy runtime answers PONG, the canary passes, and the real review turn runs.
CN_OK="$(run_canary_turn pong pong)"
[ "$(cn_status "$CN_OK")" = "completed" ] && grep -q 'the real review turn ran' "$CN_OK/reply-raw.md" 2>/dev/null \
  && ok "a passing canary lets the real review turn run" || fail "healthy canary blocked the turn (status=$(cn_status "$CN_OK"))"
grep -q '^canary: rc=0' "$CN_OK/runner.log" 2>/dev/null \
  && ok "the canary actually ran before the prompt (recorded in runner.log)" || fail "no canary was recorded"

# ERROR: the runtime returns a provider API error for the canary -> refuse BEFORE the prompt.
CN_ERR="$(run_canary_turn err error)"
[ "$(cn_status "$CN_ERR")" = "failed" ] && [ "$(cn_reason "$CN_ERR")" = "runtime-incompatible" ] \
  && ok "an API-error canary fails the turn with reason=runtime-incompatible" || fail "error canary status=$(cn_status "$CN_ERR") reason=$(cn_reason "$CN_ERR")"
grep -q 'cannot serve the configured model' "$CN_ERR/result.json" 2>/dev/null \
  && ok "the refusal note names the runtime as unable to serve the model" || fail "note lacks the compatibility cause"
[ ! -s "$CN_ERR/reply-raw.md" ] || ! grep -q 'the real review turn ran' "$CN_ERR/reply-raw.md" 2>/dev/null \
  && ok "the real review prompt never ran after an incompatible canary" || fail "the review prompt ran despite a failed canary"

# THE PATH-CLI DIAGNOSTIC IS BEST-EFFORT: an incompatible canary whose provider has no CLI on PATH
# must STILL record runtime-incompatible. An unguarded `$provider --version` under set -euo pipefail
# would abort the runner before acp_refuse, replacing the reason with a generic note. Force the CLI
# absent with a minimal PATH (node/npx live in $AXB). (codex, impl r1, blocking.)
CN_MINPATH="$AXB:$(dirname "$(command -v git)"):/usr/bin:/bin"
CN_ERR2="$(run_canary_turn err_nopath error PATH="$CN_MINPATH")"
[ "$(cn_status "$CN_ERR2")" = "failed" ] && [ "$(cn_reason "$CN_ERR2")" = "runtime-incompatible" ] \
  && ok "an incompatible canary still records runtime-incompatible when the provider CLI is absent from PATH" || fail "runtime-incompatible lost when PATH CLI absent (status=$(cn_status "$CN_ERR2") reason=$(cn_reason "$CN_ERR2"))"

# TIMEOUT: acpx exit 3 on the canary is a timeout, distinct from incompatibility, and makes NO claim.
CN_TO="$(run_canary_turn to timeout)"
[ "$(cn_status "$CN_TO")" = "failed" ] && [ "$(cn_reason "$CN_TO")" = "canary-timeout" ] \
  && ok "a canary timeout fails with reason=canary-timeout, not runtime-incompatible" || fail "timeout canary reason=$(cn_reason "$CN_TO")"
grep -q 'no compatibility claim is made' "$CN_TO/result.json" 2>/dev/null \
  && ok "a timeout makes no compatibility claim" || fail "timeout note overclaims"

# UNEXPECTED: a non-PONG answer refuses, and the whole normalized answer must equal PONG.
CN_JUNK="$(run_canary_turn junk junk)"
[ "$(cn_status "$CN_JUNK")" = "failed" ] && [ "$(cn_reason "$CN_JUNK")" = "canary-unexpected" ] \
  && ok "an off-script canary answer fails with reason=canary-unexpected" || fail "junk canary reason=$(cn_reason "$CN_JUNK")"

# CRLF: a compliant `PONG\r\n` answer must PASS (line endings normalized). (codex, impl r2 advisory.)
CN_CRLF="$(run_canary_turn crlf crlf)"
[ "$(cn_status "$CN_CRLF")" = "completed" ] \
  && ok "a PONG answer with CRLF line endings passes the canary" || fail "CRLF PONG refused (status=$(cn_status "$CN_CRLF"))"
# TRAILING FRAMING: `PONG` followed by a Warning line is off-script — framing is stripped only at the
# boundaries, so a mid-body warning does NOT rescue it. (codex, impl r2 advisory.)
CN_TW="$(run_canary_turn tw trailwarn)"
[ "$(cn_status "$CN_TW")" = "failed" ] && [ "$(cn_reason "$CN_TW")" = "canary-unexpected" ] \
  && ok "PONG followed by a trailing Warning line is canary-unexpected (framing stripped only at boundaries)" || fail "trailing-warning PONG wrongly accepted (status=$(cn_status "$CN_TW") reason=$(cn_reason "$CN_TW"))"

# NONZERO EXIT WITH PONG IN STDOUT: a transport failure refuses even when the body contains PONG.
CN_EX="$(run_canary_turn ex exit AX_CANARY_EXIT=5)"
[ "$(cn_status "$CN_EX")" = "failed" ] && case "$(cn_reason "$CN_EX")" in canary-exit-*) true;; *) false;; esac \
  && ok "a nonzero canary transport exit refuses even with PONG in stdout" || fail "exit-with-pong reason=$(cn_reason "$CN_EX")"

# UNVERIFIABLE CHECK MUST NOT PASS A PONG: if reply-check cannot classify the canary reply (here its
# python3 is unavailable, so it returns 12), the canary refuses reply-unverifiable EVEN THOUGH the
# body is exactly PONG. Before the fix only statuses 11/12 were handled and every other status fell
# through to the PONG check, qualifying an unverified reply. (codex, impl r1, blocking.)
CN_NOPY="$WORK/canary-nopy-bin"; mkdir -p "$CN_NOPY"
printf '#!/bin/sh\nexit 127\n' > "$CN_NOPY/python3"; chmod +x "$CN_NOPY/python3"
CN_UVLOG="$WORK/canary-uv.argv"
CN_UV="$(run_canary_turn uv pong PATH="$CN_NOPY:$AXB:$PATH" AX_CWD_LOG="$CN_UVLOG")"
[ "$(cn_status "$CN_UV")" = "failed" ] && [ "$(cn_reason "$CN_UV")" = "reply-unverifiable" ] \
  && ok "a PONG canary whose reply-check cannot run refuses reply-unverifiable, never passes" || fail "unverifiable canary status=$(cn_status "$CN_UV") reason=$(cn_reason "$CN_UV")"
# NO REAL PROMPT was sent: the canary ran (its bare prompt is logged) but the --file review prompt was
# never reached. (codex, impl r2 advisory — assert the real prompt was not sent.)
awk -F'\t' '$2 ~ / --file /' "$CN_UVLOG" 2>/dev/null | grep -q . \
  && fail "the real review prompt was sent after an unverifiable canary" || ok "no real review prompt was sent after an unverifiable canary"
# The classifier proceeds ONLY on status 10, and EVERY other status hits an explicit reply-unverifiable
# refusal — asserted on the catch-all arm itself, so deleting that arm fails this test. (codex r2.)
# LIMITATION (codex r3, acknowledged): reply-check always normalizes to 10/11/12, so the behavioural
# fixture above drives the reachable unverifiable case (12 with PONG present). A genuinely
# noncontractual status (126/127/signal) arises only if reply-check fails to EXECUTE, which a working
# comms.sh cannot be made to do from here; the catch-all covers it, proven structurally not behaviourally.
awk '/^acp_canary\(\)/{f=1} f&&/case "\$crc" in/{c=1} c&&/^    10\) ;;/{ten=1} c&&/^    \*\)  *ACP_CANARY_REASON="reply-unverifiable"/{star=1} c&&/esac/{exit} END{exit !(ten && star)}' "$RP" \
  && ok "the canary switch passes only on status 10 and refuses every other status via an explicit catch-all" || fail "the canary switch lacks the status-10-only / catch-all-refuse shape"

# ARGV PARITY: the canary and the real prompt share the option vector, INCLUDING the owner --ttl,
# so a canary cannot spawn an owner under a different lifetime than the round expects. Recorded via
# AX_CWD_LOG's argv column: both a `-s ... PONG` line and a `-s ... --file` line must carry --ttl.
CN_PAR="$WORK/canary-parity.log"
run_canary_turn parity pong AX_CWD_LOG="$CN_PAR" >/dev/null
# The option vector = the argv up to the profile name, minus --timeout (which legitimately differs).
cn_opts() { awk -F'\t' -v pat="$1" '$2 ~ pat {print $2}' "$CN_PAR" | head -1 \
    | sed -E 's/ --timeout [0-9]+//; s/ (grok-build|codex|claude) .*$//'; }
CN_CANOPT="$(cn_opts 'Reply with exactly')"; CN_PROMPTOPT="$(cn_opts ' --file ')"
[ -n "$CN_CANOPT" ] && ok "the canary invocation was recorded" || fail "no canary invocation logged"
[ -n "$CN_CANOPT" ] && [ "$CN_CANOPT" = "$CN_PROMPTOPT" ] \
  && ok "the canary and the real prompt share ONE option vector (perm shape and any --ttl), differing only in --timeout" \
  || fail "canary/prompt option vectors differ (canary=[$CN_CANOPT] prompt=[$CN_PROMPTOPT])"

# CODEX SINGLE MODE-PIN, before the canary. A rejected pin blocks the turn before any prompt runs.
# (The plan asked for a second pin after the canary, but the live adapter returns "Internal error"
# on a repeat set-mode; the single pre-canary pin holds because the mode is persistent owner state a
# contained canary cannot move — live finding, 2026-09-08.) A codex turn must be CONTAINED (mounted)
# for set-mode to run, so it gets a dedicated external mount base and a test acpx HOME store.
CN_CT="$WORK/setmode.ct"; rm -f "$CN_CT"
CN_MHOME="$WORK/canary-home"; mkdir -p "$CN_MHOME/.acpx/sessions" "$CN_MHOME/.acpx/queues"; : > "$CN_MHOME/.acpx-test-store"
CN_MBASE="$WORK/canary-mbase"; mkdir -p "$CN_MBASE"; CN_MBASE="$(cd "$CN_MBASE" && pwd -P)"
CN_MHEAD="$(git -C "$MA_FIX" rev-parse HEAD)"
CN_MODE_DIR="$WORK/canary-modeflip"; mkdir -p "$CN_MODE_DIR"
CN_MODE_MSG="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T12-10-00_canary-modeflip.md"
mkdir -p "$MA_FIX/.comms/to-codex"
{ head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
  printf 'artifact_id: %s\nhead_sha: %s\n' "$CN_MHEAD" "$CN_MHEAD"
  tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" \
    | sed -e "s/^thread: ma-arc-1\$/thread: ma-canary-modeflip/" -e "s/^from: claude\$/from: grok/"
} > "$CN_MODE_MSG"
CN_FLOG="$WORK/canary-modeflip.argv"
( cd "$MA_FIX" && env PATH="$AXB:$PATH" HOME="$CN_MHOME" COMMS_MOUNT_BASE="$CN_MBASE" AX_CWD_LOG="$CN_FLOG" \
    ACP_PARITY_PAYLOAD="$CANARY_PAY" AX_CANARY=pong AX_SETMODE_CT="$CN_CT" AX_SETMODE_FAIL_ON=1 \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$CN_MODE_MSG" --dir "$CN_MODE_DIR" \
    --provider codex --via acp --timeout-secs 20 ) >/dev/null 2>&1
# Prove the turn MOUNTED and pinned the mode EXACTLY ONCE (no impossible post-canary re-pin), before
# the canary — a rejected pin here blocks the turn before any prompt runs. (single-pin, live finding.)
CN_SETMODE_N=0; [ -f "$CN_CT" ] && CN_SETMODE_N="$(cat "$CN_CT" 2>/dev/null || echo 0)"
[ "$CN_SETMODE_N" = "1" ] \
  && ok "a contained codex turn pins the mode exactly once, before the canary (no repeat set-mode)" || fail "the codex turn did not pin exactly once (calls=$CN_SETMODE_N; mounted?)"
[ "$(cn_status "$CN_MODE_DIR")" = "failed" ] \
  && ok "a mode that fails to pin before the canary blocks the turn" || fail "pre-canary mode failure did not block (status=$(cn_status "$CN_MODE_DIR"))"
grep -q 'before the canary' "$CN_MODE_DIR/result.json" 2>/dev/null \
  && ok "the containment refusal names the pre-canary confirmation" || fail "refusal note does not say 'before the canary'"
# INSPECT INVOCATION RECORDS, not the reply file: a blocked pin means NO prompt (canary or real) was
# ever sent. (codex, impl r1 advisory — reply-raw.md cannot prove the canary never ran.)
awk -F'\t' '$2 ~ /Reply with exactly/ || $2 ~ / --file /' "$CN_FLOG" 2>/dev/null | grep -q . \
  && fail "a prompt was sent despite the pre-canary pin failing" || ok "no prompt (canary or review) was sent after the pin was rejected"

# POSITIVE SEQUENCING: a contained codex turn whose pin holds must pin ONCE, then send the canary,
# then the real prompt — in that order — and complete. A double-pin implementation could pass the
# rejection test above (it exits before a 2nd pin); only this proves the successful single-pin path.
# (codex, impl r1 advisory.)
CN_CT2="$WORK/setmode.ct2"; rm -f "$CN_CT2"
CN_OK_LOG="$WORK/canary-ok.argv"; CN_OK_DIR="$WORK/canary-modeok"; mkdir -p "$CN_OK_DIR"
CN_OK_MSG="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T12-12-00_canary-modeok.md"
{ head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
  printf 'artifact_id: %s\nhead_sha: %s\n' "$CN_MHEAD" "$CN_MHEAD"
  tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" \
    | sed -e "s/^thread: ma-arc-1\$/thread: ma-canary-modeok/" -e "s/^from: claude\$/from: grok/"
} > "$CN_OK_MSG"
( cd "$MA_FIX" && env PATH="$AXB:$PATH" HOME="$CN_MHOME" COMMS_MOUNT_BASE="$CN_MBASE" AX_CWD_LOG="$CN_OK_LOG" \
    ACP_PARITY_PAYLOAD="$CANARY_PAY" AX_CANARY=pong AX_SETMODE_CT="$CN_CT2" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$CN_OK_MSG" --dir "$CN_OK_DIR" \
    --provider codex --via acp --timeout-secs 20 ) >/dev/null 2>&1
CN_OK_N=0; [ -f "$CN_CT2" ] && CN_OK_N="$(cat "$CN_CT2" 2>/dev/null || echo 0)"
[ "$(cn_status "$CN_OK_DIR")" = "completed" ] && [ "$CN_OK_N" = "1" ] \
  && ok "a contained codex turn whose pin holds completes with exactly one set-mode" || fail "successful single-pin turn: status=$(cn_status "$CN_OK_DIR") setmode=$CN_OK_N"
# Order: the (only) set-mode precedes the canary, which precedes the real --file prompt.
CN_ORDER="$(awk -F'\t' '$2 ~ / set-mode /{print "M"} $2 ~ /Reply with exactly/{print "C"} $2 ~ / --file /{print "P"}' "$CN_OK_LOG" 2>/dev/null | tr -d '\n')"
[ "$CN_ORDER" = "MCP" ] \
  && ok "the successful sequence is set-mode -> canary -> real prompt, in that order" || fail "canary sequence order wrong (got: $CN_ORDER)"

# NOT DEGRADE EVIDENCE: a canary refusal must never let compose drop the leg. reason=runtime-
# incompatible / canary-* is a DISTINCT token from reason=no-output, which is the only reason
# compose accepts as evidence a reviewer could not speak. Assert none of them equals no-output.
CN_LEAK=0
for CN_D in "$CN_ERR" "$CN_TO" "$CN_JUNK" "$CN_EX"; do
  [ "$(cn_reason "$CN_D")" = "no-output" ] && CN_LEAK=1
done
[ "$CN_LEAK" -eq 0 ]   && ok "no canary refusal is recorded as no-output (so compose cannot read one as degrade evidence)" || fail "a canary refusal used the degrade-evidence reason"

section "runphase: parent-brokered claude and codex legs over ACP"
# THE GAP THIS CLOSES: every other `--via acp` fixture in this corpus pins `--provider grok`,
# so the `|| [ "$via" = "acp" ]` half of the broker gate — the half that is the whole point of
# "parent-broker claude and codex" — had no coverage at all. A regression that un-brokered
# claude or codex would have left this suite green. (contraction step 3, S3-2.)
#
# VERIFIED BY CONTROL (2026-09-01), because a first-try green section proves nothing on its own:
# hardcoding `printf 'from: %s' "grok"` back into broker_stamp turned this section RED with 8
# failures — 4 per provider. Those four are NOT four independent probes, and the section must not
# be read as 18 fault-isolation witnesses: `send` preflights archive-owner, so a cross-inbox
# `from:` kills the send, and leg-status + archive + session-field all fall out of that one death.
# Exactly ONE per provider (reply identity) is an independent stamp witness; persist, verdict,
# thread and both prompt asserts stay GREEN under the control. Every site still runs, but three
# share the end-to-end success path rather than naming a distinct parent behaviour.
# (codex + grok r1, corroborated.)
#
# STUB FIDELITY, stated plainly: $AXB/npx returns the payload through the same path for every
# provider, so these legs prove the PARENT's behaviour (prompt shape, stamping, delivery,
# archiving, session recording). They do NOT prove that acpx's real claude/codex adapters emit
# a final assistant message as stdout text; that is transport behaviour a stub cannot witness.
BRK_PAY="$WORK/brokered-payload.md"
cat > "$BRK_PAY" <<'BRKPAY'
VERDICT: REQUEST_CHANGES

## Summary
brokered review delivered over ACP

## Findings
### Blocking
- a real blocking finding the parent must stamp

### Advisory
- None.
BRKPAY

run_brokered_leg() {  # <provider> <from> <thread> -> echoes the run dir
  local prov="$1" from="$2" thr="$3" msg dir
  mkdir -p "$MA_FIX/.comms/to-$prov"
  msg="$MA_FIX/.comms/to-$prov/${MA_WS}_2026-08-20T11-00-00_brokered-$prov.md"
  sed -e "s/^thread: ma-arc-1\$/thread: $thr/" \
      -e "s/^from: claude\$/from: $from/" \
      -e "s/_review-req-1\$/_brokered-$prov/" \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  dir="$WORK/ma-brokered-$prov"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$BRK_PAY" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$msg" --dir "$dir" \
      --provider "$prov" --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}

# codex reviews for claude; claude reviews for codex. Pickup routes on the inbound `from:` —
# NOT peer_of(), which is only the fallback when `from:` is absent — so these legs do not depend
# on the two-party complement. Iteration 1 (provider=codex, from=claude) is the real panel shape;
# iteration 2 exercises claude-as-provider, which a claude-authored panel would not run. The
# session FIELD name differs per provider (legacy names), so it is asserted per leg. (grok r1.)
for BRK in "codex claude codex_thread_id" "claude codex claude_session_id"; do
  set -- $BRK
  BRK_PROV="$1"; BRK_FROM="$2"; BRK_FIELD="$3"
  BRK_THREAD="ma-brokered-$BRK_PROV"
  BRK_DIR="$(run_brokered_leg "$BRK_PROV" "$BRK_FROM" "$BRK_THREAD")"
  BRK_MSG="$MA_FIX/.comms/to-$BRK_PROV/${MA_WS}_2026-08-20T11-00-00_brokered-$BRK_PROV.md"

  [ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$BRK_DIR/result.json" | head -1)" = "completed" ] \
    && ok "brokered $BRK_PROV leg over ACP completes" || fail "brokered $BRK_PROV leg status (see $BRK_DIR/result.json)"

  BRK_REPLY="$(find "$MA_FIX/.comms/to-$BRK_FROM" -name "*$BRK_PROV-reply*" -type f 2>/dev/null | sort | tail -1)"
  [ -n "$BRK_REPLY" ] \
    && ok "the PARENT persisted the $BRK_PROV reply into to-$BRK_FROM" || fail "no parent-stamped $BRK_PROV reply in to-$BRK_FROM"

  # THE MISATTRIBUTION REGRESSION: this is the assertion that would have caught a `from: grok`
  # default stamping another agent's review.
  grep -q "^from: $BRK_PROV\$" "$BRK_REPLY" 2>/dev/null \
    && ok "the $BRK_PROV reply is stamped from: $BRK_PROV, not the first brokered provider" || fail "$BRK_PROV reply identity"
  grep -q '^verdict: REQUEST_CHANGES$' "$BRK_REPLY" 2>/dev/null \
    && ok "the parent stamped the $BRK_PROV verdict from the child's body" || fail "$BRK_PROV verdict stamp"
  grep -q "^thread: $BRK_THREAD\$" "$BRK_REPLY" 2>/dev/null \
    && ok "the $BRK_PROV reply copies its thread" || fail "$BRK_PROV reply thread"

  [ ! -f "$BRK_MSG" ] && [ -f "$MA_FIX/.comms/archive/$(basename "$BRK_MSG")" ] \
    && ok "the $BRK_PROV inbound was archived by the parent" || fail "$BRK_PROV inbound archive movement"

  BRK_STATE="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_${BRK_THREAD}.json"
  grep -q "\"$BRK_FIELD\"" "$BRK_STATE" 2>/dev/null \
    && ok "the $BRK_PROV leg records its $BRK_FIELD" || fail "$BRK_PROV session field ($BRK_FIELD) not recorded"

  # THE NEGATIVE THAT DEFINES "BROKERED": a self-send prompt tells the child to run the mailbox
  # flow itself. A brokered child is told to emit TEXT and nothing else.
  # `send --to` is the literal self-send instruction the non-ACP arm emits; matching the exact
  # shape (not the helper's rendered path) is what makes this negative discriminating.
  [ -s "$BRK_DIR/prompt.md" ] && ! grep -q 'send --to' "$BRK_DIR/prompt.md" \
    && ok "the brokered $BRK_PROV prompt never tells the child to send its own reply" || fail "$BRK_PROV prompt carries a self-send instruction"
  grep -qi 'trusted parent' "$BRK_DIR/prompt.md" 2>/dev/null \
    && ok "the brokered $BRK_PROV prompt names the parent as the one that delivers" || fail "$BRK_PROV prompt is not the brokered shape"
  # POSITIVE form of the same contract: asserting what the child IS told survives a rewording of
  # what it is NOT told. The `send --to` negative silently weakens if that heredoc line ever
  # wraps. (codex r1, advisory.)
  grep -q 'OUTPUT the reply as your final message' "$BRK_DIR/prompt.md" 2>/dev/null \
    && ok "the brokered $BRK_PROV prompt tells the child to emit its reply as text" || fail "$BRK_PROV prompt lacks the emit-as-text instruction"
  # PER-RUN transport witness. Only the ACP arm writes session_id as `acp:<session>`, so this
  # cannot be satisfied by the direct path — and unlike an events.tsv grep it cannot be answered
  # by an earlier section's grok ACP rows. (codex r1 asked for the witness; grok r1 supplied the
  # non-vacuous form.)
  grep -q '"session_id": "acp:' "$BRK_DIR/result.json" 2>/dev/null \
    && ok "the $BRK_PROV leg records an acp: session id, proving the ACP arm ran" || fail "$BRK_PROV result.json carries no acp: session id"
done

# ---- EVERY PUBLIC ENTRANCE, negatively ---- (codex, S4-2 implement r1, blocking + process)
# Removing the artifact suppression was necessary but not sufficient: `run`/`spawn` are public,
# so a review with no artifact_id would still have read the LIVE TREE. And the ACP-only rule is
# only real if no entrance can start a non-ACP claude/codex turn.
MA_MSG_ARCH="$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
for BRK_E in codex claude; do
  BRK_EDIR="$WORK/ma-acponly-$BRK_E"; mkdir -p "$BRK_EDIR"
  BRK_EOUT="$( (cd "$MA_FIX" && env PATH="$STUB_BIN:$PATH" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$MA_MSG_ARCH" --dir "$BRK_EDIR" --provider "$BRK_E" ) 2>&1 || true )"
  printf '%s\n' "$BRK_EOUT" | grep -q 'ACP-only' \
    && ok "a direct (non-ACP) $BRK_E run is refused at the entrance" || fail "$BRK_E direct run was not refused (got: $(printf '%.90s' "$BRK_EOUT"))"
done

# ---- ACP FAILURE EQUIVALENTS (S4-2 precondition) ----
# The headless sections are the ONLY place claude/codex failure reporting is exercised today, and
# step 4 deletes them. These are the ACP equivalents, added BEFORE the removal so the coverage
# never lapses — the order codex made blocking in the plan round.
for BRK_F in codex claude; do
  BRK_FFROM=codex; [ "$BRK_F" = claude ] || BRK_FFROM=claude
  BRK_FTHREAD="ma-brokfail-$BRK_F"
  mkdir -p "$MA_FIX/.comms/to-$BRK_F"
  BRK_FMSG="$MA_FIX/.comms/to-$BRK_F/${MA_WS}_2026-08-20T12-00-00_brokfail-$BRK_F.md"
  sed -e "s/^thread: ma-arc-1\$/thread: $BRK_FTHREAD/" -e "s/^from: claude\$/from: $BRK_FFROM/" \
      -e "s/_review-req-1\$/_brokfail-$BRK_F/" \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$BRK_FMSG"
  # `send` first, exactly as a real loop does: it writes the state record before any runner
  # exists. With the suite's mailbox default this nudges nobody, so the ACP turn below is still
  # the only thing that runs.
  ( cd "$MA_FIX" && env "$COMMS" send --to "$BRK_F" "$BRK_FMSG" ) >/dev/null 2>&1 || true
  BRK_FDIR="$WORK/ma-brokfail-$BRK_F"; mkdir -p "$BRK_FDIR"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$BRK_PAY" \
      AX_FAIL_RC=7 COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$BRK_FMSG" \
      --dir "$BRK_FDIR" --provider "$BRK_F" --via acp --timeout-secs 20 ) >/dev/null 2>&1
  grep -q '"status": "failed"' "$BRK_FDIR/result.json" 2>/dev/null \
    && ok "a failed $BRK_F ACP turn records status=failed" || fail "$BRK_F ACP failure status (got: $(head -c 120 "$BRK_FDIR/result.json" 2>/dev/null))"
  grep -q "\"provider\": \"$BRK_F\"" "$BRK_FDIR/result.json" 2>/dev/null \
    && ok "the failed $BRK_F ACP result names the provider that actually ran" || fail "$BRK_F ACP failure provider"
  # THREAD STATE, with a REALISTIC precondition. I first dropped this, reasoning that a failed
  # turn writes no state — but that absence was an artifact of driving runphase directly and
  # bypassing `cmd_send`, which in production creates the state record BEFORE the runner spawns.
  # The headless tests pin that a failure is mirrored into state and therefore surfaced by
  # `status`; dropping it would have lost that. Create the record the way production does, then
  # assert the ACP failure patches it. (codex, S4-2 precondition r1, blocking.)
  BRK_FSTATE="$MA_FIX/.comms/state/$(echo "$MA_WS" | tr -c 'A-Za-z0-9._-\n' '_')_${BRK_FTHREAD}.json"
  grep -q '"last_delivery": "failed"' "$BRK_FSTATE" 2>/dev/null \
    && ok "a failed $BRK_F ACP turn patches thread state, so status still shows it" || fail "$BRK_F ACP failure state (got: $(head -c 120 "$BRK_FSTATE" 2>/dev/null))"
  # DISCRIMINATE BY TIME, NOT BY NAME. Reply files are `{ws}_{ts}_{agent}-reply-{pid}.md`; the
  # `brokfail` token lives on the REQUEST, so a name-glob for it could never match a leaked reply
  # and the assertion was vacuous — it passed whether or not a failed turn published. `-newer` the
  # prompt is the discriminator that actually separates this turn's output from the happy-path
  # replies already sitting in the same inbox. (codex + grok, S4-2 precondition r1, corroborated.)
  BRK_FLEAK="$(find "$MA_FIX/.comms/to-$BRK_FFROM" -type f -name "*$BRK_F-reply*" -newer "$BRK_FDIR/prompt.md" 2>/dev/null | head -1)"
  [ -z "$BRK_FLEAK" ] && [ ! -f "$BRK_FDIR/reply.md" ] \
    && ok "a failed $BRK_F ACP turn stamps no reply — nothing to mistake for a review" || fail "$BRK_F ACP failure leaked a reply: ${BRK_FLEAK:-$BRK_FDIR/reply.md}"
done

# A CONSULT TURN WHOSE ANSWER IS THE PROVIDER'S API ERROR. Field report 2026-09-08: a rejected
# `model` made acpx exit 0 with the error JSON as the whole reply; `type: response` has no
# structure check, so the parent stamped it, delivered it and recorded `completed`. The
# question-type fixture below is the shape that hit the field, through the real ACP leg.
BRK_ERR_PAY="$WORK/brokered-error-payload.txt"
printf 'Warning: Model metadata for `gpt-6-astra` not found. Defaulting to fallback metadata.\n\n{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The gpt-6-astra model requires a newer version of Codex."}}\n\n' > "$BRK_ERR_PAY"
run_brokered_question() {  # <provider> <from> <thread> <payload> -> echoes the run dir
  local prov="$1" from="$2" thr="$3" pay="$4" msg dir
  mkdir -p "$MA_FIX/.comms/to-$prov"
  msg="$MA_FIX/.comms/to-$prov/${MA_WS}_2026-08-20T11-05-00_$thr.md"
  sed -e "s/^thread: ma-arc-1\$/thread: $thr/" -e "s/^from: claude\$/from: $from/" \
      -e "s/_review-req-1\$/_$thr/" -e 's/^type: review-request$/type: question/' \
      -e '/^workflow:/d' -e '/^phase:/d' -e '/^round:/d' -e '/^max-rounds:/d' \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" > "$msg"
  dir="$WORK/$thr"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" ACP_PARITY_PAYLOAD="$pay" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$RP" run --message "$msg" --dir "$dir" \
      --provider "$prov" --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}
BRK_REPLIES_BEFORE="$(find "$MA_FIX/.comms/to-claude" -name "*codex-reply*" -type f 2>/dev/null | wc -l | tr -d ' ')"
BRK_ERR_DIR="$(run_brokered_question codex claude ma-consult-apierror "$BRK_ERR_PAY")"
BRK_ERR_MSG="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T11-05-00_ma-consult-apierror.md"
BRK_ERR_ST="$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$BRK_ERR_DIR/result.json" 2>/dev/null | head -1)"
[ "$BRK_ERR_ST" = "failed" ] \
  && ok "a consult turn whose reply is the provider's API error is recorded FAILED, not completed" \
  || fail "API-error consult recorded as '${BRK_ERR_ST:-none}' (see $BRK_ERR_DIR/result.json)"
grep -q 'requires a newer version of Codex' "$BRK_ERR_DIR/result.json" 2>/dev/null \
  && ok "the result note carries the provider's own error message" || fail "result note lacks the provider message"
[ "$(find "$MA_FIX/.comms/to-claude" -name "*codex-reply*" -type f 2>/dev/null | wc -l | tr -d ' ')" = "$BRK_REPLIES_BEFORE" ] \
  && ok "no reply was persisted into the driver's inbox for the error" || fail "an error envelope reached to-claude as a reply"
[ -f "$BRK_ERR_MSG" ] && ok "the inbound stays unarchived so the consult can be re-sent" || fail "the inbound was archived under a refused reply"
# POSITIVE CONTROL: a consult whose prose merely talks about an error still completes.
printf '## Summary\nthe failure was a config error, not a bug\n\n## Codex Take\ncheck the model line in config.toml; the {"error":{"message":"..."}} you saw is the provider refusing the model\n' > "$WORK/brokered-prose-payload.txt"
BRK_OK_DIR="$(run_brokered_question codex claude ma-consult-prose "$WORK/brokered-prose-payload.txt")"
[ "$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$BRK_OK_DIR/result.json" 2>/dev/null | head -1)" = "completed" ] \
  && ok "a consult whose answer merely talks about an error completes (the check is structural)" \
  || fail "prose consult refused (see $BRK_OK_DIR/result.json)"
# PROVIDER-CONTROLLED TEXT REACHES result.json. A message with `\t` / `\r` / `\n` escapes
# decodes to real control characters; the old json_escape handled only backslash and quote,
# so the note wrote INVALID JSON. Parse the file, do not grep it. (codex, r1, blocking.)
BRK_CTRL_PAY="$WORK/brokered-ctrl-payload.txt"
printf '{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"bad\\tmodel\\r\\n\\"quoted\\" here"}}\n' > "$BRK_CTRL_PAY"
BRK_CTRL_DIR="$(run_brokered_question codex claude ma-consult-ctrl "$BRK_CTRL_PAY")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["status"]=="failed" else 1)' "$BRK_CTRL_DIR/result.json" 2>/dev/null \
  && ok "result.json stays valid JSON when the provider's message carries control characters and quotes" \
  || fail "result.json corrupted by a provider message (see $BRK_CTRL_DIR/result.json)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "bad model \"quoted\" here" in d["note"] else 1)' "$BRK_CTRL_DIR/result.json" 2>/dev/null \
  && ok "the note carries the message as one clean line" || fail "note text mangled (see $BRK_CTRL_DIR/result.json)"
# The escaper itself, extracted and run: a literal tab, CR, LF and quote must yield a value
# python can decode back to the input. And the two helpers carry the SAME definition — a
# fix that lands in one file and not the other is exactly how this bug would come back.
JE_RP="$(sed -n '/^json_escape() {/,/^}/p' "$REPO/helpers/runphase.sh")"
JE_CS="$(sed -n '/^json_escape() {/,/^}/p' "$REPO/helpers/comms.sh")"
JE_IN="$(printf 'a\tb\rc\nd"e\\f')"
JE_OUT="$(eval "$JE_RP"; json_escape "$JE_IN")"
python3 -c 'import json,sys; sys.exit(0 if json.loads("\"%s\"" % sys.argv[1]) == sys.argv[2] else 1)' "$JE_OUT" "$JE_IN" 2>/dev/null \
  && ok "json_escape round-trips tab, CR, LF, quote and backslash through a JSON decoder" || fail "json_escape output does not decode (got: $(printf '%q' "$JE_OUT"))"
[ -n "$JE_RP" ] && [ "$JE_RP" = "$JE_CS" ] \
  && ok "runphase.sh and comms.sh carry byte-identical json_escape definitions" || fail "json_escape drifted between helpers"

section "review identities: a claude-review turn over ACP"
# A REVIEW IDENTITY runs on its PROVIDER's runtime under its OWN name. Every other ACP fixture in
# this group runs a driver, whose identity IS its provider, so a runphase that put the identity
# where the provider belongs -- or the provider where the identity belongs -- was byte-identical
# there and could not fail. Here the two differ, and each site is asserted on the side it belongs
# to: the acpx profile, result `provider` and the reply's `review_provider` are the PROVIDER
# (claude); from:, the inbox, turn.tsv/result `agent`, the coordinator log and the unmounted
# session namespace are the IDENTITY (claude-review).
#
# STUB FIDELITY, as in the brokered section above: $AXB/npx proves what the PARENT sends and
# stamps, not that a real claude adapter behaves. What the stub can witness from inside the child
# (AX_IDENT_LOG) is the environment the parent handed it, which is the boundary under test.
#
# The registry is rewritten for this section only and RESTORED at its end: every later section
# assumes the fixture's three-driver config.
RID_CFG="$MA_FIX/.comms/config"; RID_CFG_SAVED="$WORK/rid-config.saved"
cp "$RID_CFG" "$RID_CFG_SAVED"
rid_map() {  # <provider> — the fixture's drivers plus claude-review mapped onto <provider>
  { cat "$RID_CFG_SAVED"; printf 'review-agents = claude-review:%s\n' "$1"; } > "$RID_CFG"
}
rid_map claude
# A marked store, so the stub may persist session records here and never in a real ~/.acpx.
RID_HOME="$WORK/rid-home"; mkdir -p "$RID_HOME/.acpx/sessions" "$RID_HOME/.acpx/queues"; : > "$RID_HOME/.acpx-test-store"
# A review-request written straight into an inbox, as `send` leaves it (its file name IS its
# message_id). `-` omits a field: a request to a review identity carries the provider its send
# resolved (`review_provider`), and the binding and peer cases below need it absent or wrong.
rid_msg() {  # <inbox> <tag> <from|-> <review_provider|-> -> echoes the inbound's path
  local inbox="$1" tag="$2" from="$3" rp="$4" m
  mkdir -p "$MA_FIX/.comms/to-$inbox"
  m="$MA_FIX/.comms/to-$inbox/${MA_WS}_${MA_TS}_rid-$tag.md"
  sed -e "s/^thread: ma-arc-1\$/thread: ma-rid-$tag/" -e "s/_review-req-1\$/_rid-$tag/" \
      "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" \
    | awk -v from="$from" -v rp="$rp" '
        /^from: / && !body { if (from != "-") print "from: " from; next }
        NR > 1 && $0 == "---" && !body { if (rp != "-") print "review_provider: " rp; body = 1 }
        { print }' > "$m"
  printf '%s' "$m"
}
# BOTH HOPS a turn can take. `spawn` is the detached path every real dispatch uses: it must
# FORWARD the identity to `run`, never the provider it resolved, or the turn silently runs as
# `claude`. `run` is the foreground path (`send --wait`); it deliberately KEEPS the driver's
# presence/identity environment, so it is the hop on which only the child-launch scrub stands
# between that environment and the reviewer. RID_LAUNCH lets the boundary case interpose a probe.
rid_spawn() {  # <agent> <inbound> <tag> -> spawn's stdout (the run dir is on its `run dir:` line)
  local agent="$1" msg="$2" tag="$3"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" HOME="$RID_HOME" ACP_PARITY_PAYLOAD="$BRK_PAY" \
      AX_CWD_LOG="$WORK/rid-$tag.argv" AX_IDENT_LOG="$WORK/rid-$tag.ident" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      "$RP" spawn --agent "$agent" --message "$msg" --via acp --timeout-secs 20 ) 2>&1
}
rid_await() { ( cd "$MA_FIX" && "$RP" await "$1" --timeout-secs 120 ) >/dev/null 2>&1; }
rid_run() {  # <agent> <inbound> <tag> [env assignments...] -> the run dir
  local agent="$1" msg="$2" tag="$3" dir; shift 3
  dir="$WORK/rid-$tag"; mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" HOME="$RID_HOME" ACP_PARITY_PAYLOAD="$BRK_PAY" \
      AX_CWD_LOG="$WORK/rid-$tag.argv" AX_IDENT_LOG="$WORK/rid-$tag.ident" \
      COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$@" \
      "${RID_LAUNCH:-$RP}" run --message "$msg" --dir "$dir" --agent "$agent" --via acp --timeout-secs 20 ) >/dev/null 2>&1
  printf '%s' "$dir"
}
rid_json() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1/result.json" "$2" 2>/dev/null; }
rid_tv() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/turn.tsv" 2>/dev/null; }
# EVERY published reply answering an inbound, in ANY inbox, found by ENVELOPE. Reply files are
# named after the reviewer, never the request, so a name glob could not see a leak; and a
# `*claude-reply*` glob would conflate claude with claude-review. The e2e below must find exactly
# one, which is what gives every "published nothing" assertion after it its teeth.
rid_answers() { grep -lxF "in-reply-to: $1" "$MA_FIX/.comms"/to-*/*.md 2>/dev/null; }
rid_answers_n() { rid_answers "$1" | grep -c . | tr -d ' '; }
# The distinct acpx (P)rofile and (S)ession tokens across every invocation the stub saw: the
# profile is what the provider resolved to, the session name is the identity's namespace.
rid_sessions() {
  awk -F'\t' '{ n = split($2, a, " ")
    for (i = 1; i <= n; i++) {
      if (a[i] == "-s" || a[i] == "--name" || (a[i] == "show" && a[i-1] == "sessions")) print "S " a[i+1]
      if (a[i] == "-s" || a[i] == "sessions") print "P " a[i-1]
    } }' "$1" 2>/dev/null | sort -u | tr '\n' ' '
}
rid_ident_all() {  # <ident log> <VAR> <value> — every child launch saw exactly VAR=value, and there was one
  local n bad
  n="$(grep -c "^$2=" "$1" 2>/dev/null)"
  bad="$(grep "^$2=" "$1" 2>/dev/null | grep -vxF "$2=$3" | head -1)"
  [ "${n:-0}" -gt 0 ] && [ -z "$bad" ]
}

# PRECONDITION: the registry this section runs against. Without it every failure below would read
# as a runphase defect when the fixture simply never declared the identity.
[ "$( (cd "$MA_FIX" && "$COMMS" agents --provider claude-review) 2>/dev/null)" = claude ] \
  && ok "the fixture registry maps review identity claude-review onto provider claude" \
  || fail "claude-review is not registered on claude (config: $(tr '\n' ';' < "$RID_CFG"))"

# ---- (1) THE REAL spawn -> run HOP, from a claude driver to its own model's review identity ----
RID_E2E_MSG="$(rid_msg claude-review e2e claude claude)"; RID_E2E_MID="$(basename "$RID_E2E_MSG" .md)"
RID_E2E_OUT="$(rid_spawn claude-review "$RID_E2E_MSG" e2e)"
RID_E2E_DIR="$(rundir_of "$RID_E2E_OUT")"
[ -n "$RID_E2E_DIR" ] && rid_await "$RID_E2E_DIR"
printf '%s\n' "$RID_E2E_OUT" | grep '^spawned runphase ' | grep -q ' provider=claude via=acp agent=claude-review$' \
  && ok "spawn names both the provider it resolved and the identity it runs as" \
  || fail "spawned line lacks provider=claude/agent=claude-review (got: $(printf '%s' "$RID_E2E_OUT" | head -3 | tr '\n' ' '))"
[ "$(rid_json "$RID_E2E_DIR" status)" = completed ] && [ "$(rid_json "$RID_E2E_DIR" provider)" = claude ] \
  && [ "$(rid_json "$RID_E2E_DIR" agent)" = claude-review ] \
  && ok "the detached claude-review turn completes; result.json says provider claude, agent claude-review" \
  || fail "e2e result: status=$(rid_json "$RID_E2E_DIR" status) provider=$(rid_json "$RID_E2E_DIR" provider) agent=$(rid_json "$RID_E2E_DIR" agent) note=$(rid_json "$RID_E2E_DIR" note | cut -c1-200)"
[ "$(rid_tv "$RID_E2E_DIR" agent)" = claude-review ] && [ "$(rid_tv "$RID_E2E_DIR" provider)" = claude ] \
  && ok "turn.tsv records the identity and the provider as separate facts" \
  || fail "turn.tsv agent=$(rid_tv "$RID_E2E_DIR" agent) provider=$(rid_tv "$RID_E2E_DIR" provider)"
RID_E2E_REPLY="$(rid_answers "$RID_E2E_MID")"
[ "$(rid_answers_n "$RID_E2E_MID")" = 1 ] && [ "$(dirname "$RID_E2E_REPLY")" = "$MA_FIX/.comms/to-claude" ] \
  && ok "exactly one reply answers the request, and it lands in the DRIVER's inbox (to-claude)" \
  || fail "e2e reply placement (found: $(rid_answers "$RID_E2E_MID" | tr '\n' ' '))"
# THE MISATTRIBUTION REGRESSION for identities: a broker that stamped the provider would publish
# `from: claude` into to-claude -- the driver reading its own name as its reviewer.
grep -qx 'type: review-feedback' "$RID_E2E_REPLY" 2>/dev/null && grep -qx 'from: claude-review' "$RID_E2E_REPLY" 2>/dev/null \
  && grep -qx 'review_provider: claude' "$RID_E2E_REPLY" 2>/dev/null \
  && ok "the reply is from: claude-review and names the provider that produced it (review_provider: claude)" \
  || fail "e2e reply envelope ($(sed -n '2,6p' "$RID_E2E_REPLY" 2>/dev/null | tr '\n' ' '))"
[ ! -f "$RID_E2E_MSG" ] && [ -f "$MA_FIX/.comms/archive/$(basename "$RID_E2E_MSG")" ] \
  && ok "the inbound was archived out of to-claude-review by the parent" || fail "claude-review inbound archive movement"
# PROVIDER at the profile, IDENTITY in the session name. Unmounted, acpx keys a session on
# (profile, cwd, name): without `+as+` this turn would resume a plain `claude` reviewer's warm
# session on the same thread and inherit its context.
RID_E2E_SESS="agent-comms-ma-rid-e2e+as+claude-review"
[ "$(rid_sessions "$WORK/rid-e2e.argv")" = "P claude S $RID_E2E_SESS " ] \
  && awk -F'\t' '$2 ~ / --file /' "$WORK/rid-e2e.argv" 2>/dev/null | grep -q . \
  && [ "$(rid_tv "$RID_E2E_DIR" acp_session)" = "$RID_E2E_SESS" ] \
  && ok "every acpx call used profile claude and the disjoint session $RID_E2E_SESS, and the prompt went out" \
  || fail "e2e acpx argv (tokens: $(rid_sessions "$WORK/rid-e2e.argv"); turn.tsv session: $(rid_tv "$RID_E2E_DIR" acp_session))"
rid_ident_all "$WORK/rid-e2e.ident" COMMS_REVIEW_TURN claude-review \
  && ok "the review-turn marker rides the detached hop into every acpx child" \
  || fail "COMMS_REVIEW_TURN in the e2e children: $(grep '^COMMS_REVIEW_TURN=' "$WORK/rid-e2e.ident" 2>/dev/null | sort -u | tr '\n' ' ')"
# THE COORDINATOR LOG is identity-keyed: `--degrade`, the leg fingerprint and `events --set` find
# a leg by the name its request was sent to. A row under `claude` would be a second, phantom leg.
RID_EV="$( (cd "$MA_FIX" && "$COMMS" events --thread ma-rid-e2e --all) 2>/dev/null | tail -n +2 )"
rid_ev_has() { printf '%s\n' "$RID_EV" | awk -F'\t' -v k="$1" '$3 == k' | grep -q .; }
[ "$(printf '%s\n' "$RID_EV" | awk -F'\t' 'NF > 1 {print $8}' | sort -u | tr '\n' ' ')" = "claude-review " ] \
  && rid_ev_has turn-started && rid_ev_has reply-accepted && rid_ev_has turn-finished \
  && printf '%s\n' "$RID_EV" | awk -F'\t' '$3 == "turn-started" {print $15}' | grep -q 'provider=claude agent=claude-review' \
  && ok "every coordinator event for the turn carries agent claude-review, and turn-started names both" \
  || fail "e2e events (agents: $(printf '%s\n' "$RID_EV" | awk -F'\t' 'NF > 1 {print $3 "=" $8}' | tr '\n' ' '))"

# ---- (2) THE ENVIRONMENT BOUNDARY, on the foreground hop that keeps the driver's env ----
# A claude reviewer launched from a claude driver's shell inherits Claude Code's session variables
# and the driver's comms identity; unscrubbed, the child reads as a nested copy of the driving
# session and can beat the driver's presence record. Injected into runphase ITSELF, so only the
# child-launch scrub can remove them. All eight scrubbed names are injected, not a sample.
RID_WRAP="$WORK/rid-runphase-wrap"; RID_WRAP_LOG="$WORK/rid-runphase.env"
cat > "$RID_WRAP" <<RIDWRAP
#!/bin/bash
# The CONTROL: record what runphase itself is started with, then become runphase.
for v in COMMS_SELF COMMS_PRESENCE_NAME COMMS_PRESENCE_INSTANCE COMMS_PRESENCE_PID \\
         CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID; do
  printf '%s=%s\n' "\$v" "\$(printenv "\$v" 2>/dev/null || printf '<unset>')"
done > "$RID_WRAP_LOG"
exec "$RP" "\$@"
RIDWRAP
chmod +x "$RID_WRAP"
RID_ENV_MSG="$(rid_msg claude-review envb claude claude)"
RID_ENV_DIR="$(RID_LAUNCH="$RID_WRAP" rid_run claude-review "$RID_ENV_MSG" envb \
  COMMS_SELF=claude COMMS_PRESENCE_NAME=x COMMS_PRESENCE_INSTANCE=y COMMS_PRESENCE_PID=$$ \
  CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=z)"
# Without this control, "absent in the child" could mean the injection never reached runphase.
[ "$(cat "$RID_WRAP_LOG" 2>/dev/null)" = "$(printf '%s\n' COMMS_SELF=claude COMMS_PRESENCE_NAME=x COMMS_PRESENCE_INSTANCE=y \
      "COMMS_PRESENCE_PID=$$" CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=z)" ] \
  && ok "CONTROL: runphase itself was started with all eight driver identity variables set" \
  || fail "the injection did not reach runphase ($(tr '\n' ' ' < "$RID_WRAP_LOG" 2>/dev/null))"
RID_LEAK=""
for RID_V in COMMS_SELF COMMS_PRESENCE_NAME COMMS_PRESENCE_INSTANCE COMMS_PRESENCE_PID \
             CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID; do
  rid_ident_all "$WORK/rid-envb.ident" "$RID_V" '<unset>' || RID_LEAK="$RID_LEAK $RID_V"
done
[ -z "$RID_LEAK" ] \
  && ok "every acpx child of the turn saw none of them (the reviewer boundary scrubs each one)" \
  || fail "driver identity reached the reviewer child:$RID_LEAK"
# The stub prints this marker's VALUE through the same loop that printed `<unset>` above, so its
# presence also proves the probe can see a variable that IS set -- the absences are observations.
[ "$(rid_json "$RID_ENV_DIR" status)" = completed ] && rid_ident_all "$WORK/rid-envb.ident" COMMS_REVIEW_TURN claude-review \
  && ok "the review-turn marker survives the scrub (COMMS_REVIEW_TURN=claude-review in every child)" \
  || fail "marker in the scrubbed children: status=$(rid_json "$RID_ENV_DIR" status) $(grep '^COMMS_REVIEW_TURN=' "$WORK/rid-envb.ident" 2>/dev/null | sort -u | tr '\n' ' ')"

# ---- (3) EXECUTION BINDING: a request runs only on the provider it was sent to ----
# The send stamped `review_provider: claude`; the map then moved claude-review onto codex. Running
# it would publish a codex review under a name compose counts as claude -- so it must fail closed
# before any acpx call, and the leg reads unanswered rather than as a different model.
RID_STALE_MSG="$(rid_msg claude-review stale claude claude)"; RID_STALE_MID="$(basename "$RID_STALE_MSG" .md)"
rid_map codex
RID_STALE_DIR="$(rid_run claude-review "$RID_STALE_MSG" stale)"
[ "$(rid_json "$RID_STALE_DIR" status)" = failed ] \
  && rid_json "$RID_STALE_DIR" note | grep -qF "was bound to provider 'claude'" \
  && rid_json "$RID_STALE_DIR" note | grep -qF "now resolves to 'codex'" \
  && ok "a request bound to claude is refused when claude-review now resolves to codex" \
  || fail "remap not refused: status=$(rid_json "$RID_STALE_DIR" status) note=$(rid_json "$RID_STALE_DIR" note | cut -c1-200)"
[ "$(rid_answers_n "$RID_STALE_MID")" = 0 ] && [ -f "$RID_STALE_MSG" ] && [ ! -s "$WORK/rid-stale.argv" ] \
  && ok "the remapped turn published nothing, left the inbound in place, and never launched acpx" \
  || fail "remapped turn side effects (replies=$(rid_answers_n "$RID_STALE_MID") inbound=$([ -f "$RID_STALE_MSG" ] && echo kept || echo gone) acpx-calls=$(grep -c . "$WORK/rid-stale.argv" 2>/dev/null))"
# PAIRED CONTROL: the SAME file, with only the map put back, runs and publishes. So the refusal
# above was the binding, not anything else about the request.
rid_map claude
RID_REBIND_DIR="$(rid_run claude-review "$RID_STALE_MSG" rebind)"
[ "$(rid_json "$RID_REBIND_DIR" status)" = completed ] && [ "$(rid_answers_n "$RID_STALE_MID")" = 1 ] \
  && ok "CONTROL: the same request completes once claude-review maps back to the provider it was bound to" \
  || fail "rebound control: status=$(rid_json "$RID_REBIND_DIR" status) replies=$(rid_answers_n "$RID_STALE_MID") note=$(rid_json "$RID_REBIND_DIR" note | cut -c1-200)"
# An UNSTAMPED request (hand-placed, or from a send before identities) has no binding to honour.
RID_NOBIND_MSG="$(rid_msg claude-review nobind claude -)"; RID_NOBIND_MID="$(basename "$RID_NOBIND_MSG" .md)"
RID_NOBIND_DIR="$(rid_run claude-review "$RID_NOBIND_MSG" nobind)"
[ "$(rid_json "$RID_NOBIND_DIR" status)" = failed ] \
  && rid_json "$RID_NOBIND_DIR" note | grep -qF "was bound to provider '<none>'" \
  && [ "$(rid_answers_n "$RID_NOBIND_MID")" = 0 ] && [ ! -s "$WORK/rid-nobind.argv" ] \
  && ok "a request to a review identity with no review_provider is refused before acpx, unpublished" \
  || fail "unstamped request: status=$(rid_json "$RID_NOBIND_DIR" status) replies=$(rid_answers_n "$RID_NOBIND_MID") note=$(rid_json "$RID_NOBIND_DIR" note | cut -c1-200)"

# ---- (4) PEER RULES: who may author the request a turn answers ----
# runphase is public, so these are reachable without `send` having validated anything. The
# positive controls are (1) above (claude -> claude-review) and (5) below (codex -> claude).
# A review identity never AUTHORS: answering one would route review-feedback into to-claude-review.
RID_RA_MSG="$(rid_msg claude revauthor claude-review -)"; RID_RA_MID="$(basename "$RID_RA_MSG" .md)"
RID_RA_DIR="$(rid_run claude "$RID_RA_MSG" revauthor)"
[ "$(rid_json "$RID_RA_DIR" status)" = failed ] && rid_json "$RID_RA_DIR" note | grep -qF 'is a review-only identity' \
  && [ "$(rid_answers_n "$RID_RA_MID")" = 0 ] && [ -f "$RID_RA_MSG" ] && [ ! -s "$WORK/rid-revauthor.argv" ] \
  && ok "a request authored by a review identity is refused as review-only, before acpx, unpublished" \
  || fail "review-identity author: status=$(rid_json "$RID_RA_DIR" status) replies=$(rid_answers_n "$RID_RA_MID") note=$(rid_json "$RID_RA_DIR" note | cut -c1-200)"
# Identity == peer: claude reviewing claude's own request would share one inbox, thread and
# awaiting_from with itself. Same-model review is what claude-review is for.
RID_SELF_MSG="$(rid_msg claude selfrev claude -)"; RID_SELF_MID="$(basename "$RID_SELF_MSG" .md)"
RID_SELF_DIR="$(rid_run claude "$RID_SELF_MSG" selfrev)"
[ "$(rid_json "$RID_SELF_DIR" status)" = failed ] && rid_json "$RID_SELF_DIR" note | grep -qF "this turn's own identity" \
  && [ "$(rid_answers_n "$RID_SELF_MID")" = 0 ] && [ -f "$RID_SELF_MSG" ] && [ ! -s "$WORK/rid-selfrev.argv" ] \
  && ok "a claude turn answering claude's own request is refused (own identity), before acpx, unpublished" \
  || fail "self-review: status=$(rid_json "$RID_SELF_DIR" status) replies=$(rid_answers_n "$RID_SELF_MID") note=$(rid_json "$RID_SELF_DIR" note | cut -c1-200)"
# A driver with no from: falls back to its two-party complement; a review identity has none (its
# driver may share its provider), so guessing would be a guess about who reads the reply.
RID_NF_MSG="$(rid_msg claude-review nofrom - claude)"; RID_NF_MID="$(basename "$RID_NF_MSG" .md)"
RID_NF_DIR="$(rid_run claude-review "$RID_NF_MSG" nofrom)"
[ "$(rid_json "$RID_NF_DIR" status)" = failed ] && rid_json "$RID_NF_DIR" note | grep -qF 'inbound has no from:' \
  && [ "$(rid_answers_n "$RID_NF_MID")" = 0 ] && [ ! -s "$WORK/rid-nofrom.argv" ] \
  && ok "a review-identity turn whose inbound has no from: is refused rather than guessing a peer" \
  || fail "from-less review-identity inbound: status=$(rid_json "$RID_NF_DIR" status) note=$(rid_json "$RID_NF_DIR" note | cut -c1-200)"

# ---- (5) STABILITY: a DRIVER identity is byte-identical to before identities existed ----
# Same registry, same hop: a claude turn answering codex keeps its historic session name (and so
# its warm session), announces no separate identity, and stamps no review_provider.
RID_DRV_MSG="$(rid_msg claude drv codex -)"; RID_DRV_MID="$(basename "$RID_DRV_MSG" .md)"
RID_DRV_OUT="$(rid_spawn claude "$RID_DRV_MSG" drv)"
RID_DRV_DIR="$(rundir_of "$RID_DRV_OUT")"
[ -n "$RID_DRV_DIR" ] && rid_await "$RID_DRV_DIR"
printf '%s\n' "$RID_DRV_OUT" | grep '^spawned runphase ' | grep -q ' provider=claude via=acp$' \
  && [ "$(rid_json "$RID_DRV_DIR" status)" = completed ] && [ "$(rid_json "$RID_DRV_DIR" agent)" = claude ] \
  && ok "a driver turn's spawn line and result are unchanged (no separate agent=, agent == provider)" \
  || fail "driver turn: spawned=[$(printf '%s' "$RID_DRV_OUT" | head -3 | tr '\n' ' ')] status=$(rid_json "$RID_DRV_DIR" status) agent=$(rid_json "$RID_DRV_DIR" agent)"
[ "$(rid_sessions "$WORK/rid-drv.argv")" = "P claude S agent-comms-ma-rid-drv " ] \
  && ok "a driver turn keeps the historic session name agent-comms-<thread>, with no +as+ suffix" \
  || fail "driver session namespace changed (tokens: $(rid_sessions "$WORK/rid-drv.argv"))"
RID_DRV_REPLY="$(rid_answers "$RID_DRV_MID")"
[ "$(rid_answers_n "$RID_DRV_MID")" = 1 ] && [ "$(dirname "$RID_DRV_REPLY")" = "$MA_FIX/.comms/to-codex" ] \
  && grep -qx 'from: claude' "$RID_DRV_REPLY" 2>/dev/null && ! grep -q '^review_provider:' "$RID_DRV_REPLY" 2>/dev/null \
  && ok "the driver's reply lands in to-codex from: claude and carries NO review_provider line" \
  || fail "driver reply (found: $(rid_answers "$RID_DRV_MID" | tr '\n' ' '); envelope: $(sed -n '2,6p' "$RID_DRV_REPLY" 2>/dev/null | tr '\n' ' '))"

# ---- (6) THE DETACHED RUNNER DOES NOT CARRY THE DRIVER'S PRESENCE ----
# A detached runner outlives its driver, and its broker's `send` beats whatever presence record
# the environment names — HEALING one the driver has already released, as a pid-less record no
# reaper can collect. So spawn drops COMMS_PRESENCE_* / COMMS_SELF; the foreground run (the driver
# is alive and waiting on it) keeps them. The control proves the injected pair really would beat.
RID_PN=rid-driver; RID_PI=0123456789abcdef0123456789abcdef
RID_PR="$MA_FIX/.comms/sessions/$RID_PN-$RID_PI.json"
rm -f "$RID_PR"
RID_PC_MSG="$(rid_msg claude-review pctl claude claude)"
RID_PC_DIR="$(rid_run claude-review "$RID_PC_MSG" pctl COMMS_PRESENCE_NAME="$RID_PN" COMMS_PRESENCE_INSTANCE="$RID_PI")"
[ "$(rid_json "$RID_PC_DIR" status)" = completed ] && [ -f "$RID_PR" ] \
  && ok "control: a foreground run keeps the driver's presence env, and its broker's send beats that record" \
  || fail "presence control (status=$(rid_json "$RID_PC_DIR" status) record=$(ls "$MA_FIX/.comms/sessions" 2>/dev/null | tr '\n' ' '))"
rm -f "$RID_PR"
RID_PS_MSG="$(rid_msg claude-review pspawn claude claude)"
RID_PS_OUT="$( (cd "$MA_FIX" && env PATH="$AXB:$PATH" HOME="$RID_HOME" ACP_PARITY_PAYLOAD="$BRK_PAY" \
    COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 COMMS_PRESENCE_NAME="$RID_PN" COMMS_PRESENCE_INSTANCE="$RID_PI" COMMS_SELF=claude \
    "$RP" spawn --agent claude-review --message "$RID_PS_MSG" --via acp --timeout-secs 20 ) 2>&1)"
RID_PS_DIR="$(rundir_of "$RID_PS_OUT")"
[ -n "$RID_PS_DIR" ] && rid_await "$RID_PS_DIR"
[ "$(rid_json "$RID_PS_DIR" status)" = completed ] && [ ! -f "$RID_PR" ] \
  && ok "a detached spawn's broker never beats (or heals) the driver's presence record" \
  || fail "detached runner carried the driver's presence (status=$(rid_json "$RID_PS_DIR" status) record present=$([ -f "$RID_PR" ] && echo yes || echo no))"
rm -f "$RID_PR"

cp "$RID_CFG_SAVED" "$RID_CFG"

section "acp.sh: the reviewer model+effort policy"
# THE POLICY IS DECLARED ONCE, VALIDATED AT THE ACCESSOR, AND ASSERTED ON BYTES.
# The predecessor of these assertions grepped templates/claude-commands/auto.md for the
# sentence "Effort and tier are advisory" -- which is how a router whose decision nothing
# consumed passed three double-APPROVE arcs. Assert what is WRITTEN and what is REFUSED.
AP="$REPO/helpers/acp.sh"

POL="$("$AP" policy codex)"
[ "$POL" = "$(printf 'gpt-6-astra\txhigh')" ] \
  && ok "policy codex prints the declared model and effort, tab-separated" || fail "policy codex (got: $(printf '%q' "$POL"))"

PCFG="$("$AP" provider-config codex)"
printf '%s\n' "$PCFG" | grep -qx 'model_reasoning_effort = "xhigh"' \
  && ok "provider-config writes the effort key the codex binary reads" || fail "provider-config effort key"
printf '%s\n' "$PCFG" | grep -qx 'model = "gpt-6-astra"' \
  && ok "provider-config writes the model key" || fail "provider-config model key"
[ "$(printf '%s\n' "$PCFG" | wc -l | tr -d ' ')" = 4 ] \
  && ok "provider-config emits exactly four keys — no stray or duplicated line" || fail "provider-config line count"
printf '%s\n' "$PCFG" | grep -qx 'sandbox_mode = "read-only"' \
  && ok "provider-config keeps approval/sandbox as literals beside the policy" || fail "provider-config literals"

COMMS_ACP_CODEX_EFFORT=high "$AP" provider-config codex | grep -qx 'model_reasoning_effort = "high"' \
  && ok "COMMS_ACP_CODEX_EFFORT overrides the written effort" || fail "effort env override"

# TOML INJECTION. The values are interpolated into the file that governs the reviewer's
# sandbox, so a quote or newline must be refused at the accessor -- by ALLOWLIST, never by
# enumerating bad characters (docs/advisories.md:363).
INJ='xhigh"
sandbox_mode = "danger-full-access'
COMMS_ACP_CODEX_EFFORT="$INJ" "$AP" provider-config codex >/dev/null 2>&1 \
  && fail "an injected effort was accepted" \
  || ok "an effort carrying a quote and a newline is refused before any config is emitted"
COMMS_ACP_CODEX_MODEL='a b' "$AP" policy codex >/dev/null 2>&1 \
  && fail "a model with a space was accepted" || ok "a model that is not a bare identifier is refused"

"$AP" provider-config claude >/dev/null 2>&1 \
  && fail "claude was given a provider config" \
  || ok "provider-config is empty and nonzero where no isolated home exists (claude)"

# policy-check: the PREFLIGHT record read. 0 match / 20 mismatch / 21 undecidable, and
# undecidable is never "model matched, effort optional".
pc() { printf '%s' "$1" | "$AP" policy-check codex - >/dev/null 2>&1; printf '%s' "$?"; }
[ "$(pc '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-6-astra"},{"id":"reasoning_effort","currentValue":"xhigh"}]}}')" = 0 ] \
  && ok "policy-check accepts a record matching the policy" || fail "policy-check match"
[ "$(pc '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-6-astra"},{"id":"reasoning_effort","currentValue":"medium"}]}}')" = 20 ] \
  && ok "policy-check rejects the effort this bug actually produced (medium)" || fail "policy-check effort mismatch"
[ "$(pc '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-5.6-sol"},{"id":"reasoning_effort","currentValue":"xhigh"}]}}')" = 20 ] \
  && ok "policy-check rejects a model float against the id we wrote" || fail "policy-check model mismatch"
[ "$(pc '{"acpx":{"acpx_record_id":"x"}}')" = 21 ] \
  && ok "an absent config_options list is UNDECIDABLE, not a pass (the JetBrains-client shape)" || fail "policy-check absent options"
[ "$(pc 'not json')" = 21 ] \
  && ok "an unparseable session record is UNDECIDABLE, not a pass" || fail "policy-check unparseable"

# policy-attest shares ONE verdict function with policy-check, so the pre- and post-turn
# gates cannot drift into disagreeing about what the policy is.
"$AP" policy-attest codex xhigh gpt-6-astra >/dev/null 2>&1 \
  && ok "policy-attest accepts an observed turn that ran the policy" || fail "policy-attest match"
"$AP" policy-attest codex medium gpt-6-astra >/dev/null 2>&1; [ "$?" = 20 ] \
  && ok "policy-attest rejects an observed turn that ran shallower than declared" || fail "policy-attest mismatch"
"$AP" policy-attest codex "" >/dev/null 2>&1; [ "$?" = 21 ] \
  && ok "policy-attest treats missing evidence as undecidable" || fail "policy-attest undecidable"
grep -q 'policy_verdict' "$AP" && [ "$(grep -c 'policy_verdict "\$' "$AP")" -ge 2 ] \
  && ok "both gates route through the same policy_verdict accessor" || fail "the two gates do not share one verdict function"

# runphase must hold NO policy literal: the config comes from the accessor, so a second copy
# cannot drift out of sync with the one that is validated.
# CODE only: a model id inside a COMMENT is documentation, not a second source of truth that
# can drift. Stripping comments keeps the check on the thing that matters. (Tripped by a
# comment describing a live rollout, 2026-09-21.)
sed 's/[[:space:]]*#.*$//' "$REPO/helpers/runphase.sh" | grep -qE 'gpt-6-astra|model_reasoning_effort' \
  && fail "runphase.sh carries a literal model or effort value in CODE" \
  || ok "runphase.sh holds no model or effort literal in code — it asks acp.sh"
# B3 (codex, implement r1): BOTH keys are policy, so missing model evidence is undecidable.
# It previously returned 0 and printed model=unknown — half the contract unverified.
"$AP" policy-attest codex xhigh "" >/dev/null 2>&1; [ "$?" = 21 ] \
  && ok "an observation with no model is undecidable, not a pass" || fail "missing observed model passed"
[ "$(pc '{"acpx":{"config_options":[{"id":"reasoning_effort","currentValue":"xhigh"}]}}')" = 21 ] \
  && ok "a preflight record missing the model is undecidable, not a pass" || fail "preflight missing model passed"
# B4 (codex, implement r1): the refuse-and-retire control was commented but NOT implemented —
# the parser read only config_options, so a saved preference that acpx would replay onto a
# replacement session was never seen.
[ "$(pc '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-6-astra"},{"id":"reasoning_effort","currentValue":"xhigh"}],"desired_config_options":{"reasoning_effort":"low"}}}')" = 20 ] \
  && ok "a saved effort preference conflicting with the policy is refused before the canary" || fail "conflicting desired preference accepted"
[ "$(pc '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-6-astra"},{"id":"reasoning_effort","currentValue":"xhigh"}],"desired_config_options":{"reasoning_effort":"xhigh"}}}')" = 0 ] \
  && ok "a saved preference matching the policy is accepted" || fail "matching desired preference refused"
[ "$(pc '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-6-astra"},{"id":"reasoning_effort","currentValue":"xhigh"}],"desired_config_options":[{"id":"reasoning_effort","currentValue":"low"}]}}')" = 20 ] \
  && ok "a conflicting saved preference in LIST shape is refused too" || fail "list-shaped desired preference missed"
[ "$(pc '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-6-astra"},{"id":"reasoning_effort","currentValue":"xhigh"}],"desired_config_options":"weird"}}')" = 21 ] \
  && ok "a saved-preference shape we do not understand is undecidable, not ignored" || fail "unknown desired shape ignored"

section "acp.sh: the reviewer policy resolver"
# ONE RESOLVER, ONE VERSIONED MAP. An abstract candidate (tier fast|balanced|strong, effort
# low..xhigh) becomes a concrete pair only through helpers/policy-map.tsv; the operator's pins
# win per dimension; everything else keeps the concrete baseline. Every case RUNS the resolver
# and reads the record it prints — the record is what runphase persists and every later gate reads.
AP="$REPO/helpers/acp.sh"
rv() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2; exit}'; }
res() { env -u COMMS_ACP_CODEX_MODEL -u COMMS_ACP_CODEX_EFFORT "$@"; }
MAPV="$(awk -F'\t' '$1=="version"{print $2; exit}' "$REPO/helpers/policy-map.tsv")"

R="$(res "$AP" resolve codex)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" effort)" = xhigh ] \
  && [ "$(rv "$R" model_source)" = baseline ] && [ "$(rv "$R" pair)" = validated ] \
  && [ "$(rv "$R" verify)" = "model,effort" ] && [ "$(rv "$R" map_version)" = "$MAPV" ] \
  && ok "no candidate resolves to the map's baseline, validated, stamped with the map version" || fail "baseline resolution ($R)"
R="$(res "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-5.6-luna ] && [ "$(rv "$R" effort)" = low ] \
  && [ "$(rv "$R" model_source)" = route ] && [ "$(rv "$R" effort_source)" = route ] \
  && [ "$(rv "$R" effective_tier)" = fast ] && [ "$(rv "$R" fallback)" = runtime-lacks:gpt-6-luna ] \
  && [ "$(rv "$R" runtime)" = bundled ] \
  && ok "a fast/low candidate reaches a cheap pair; on the bundled runtime the tier falls back to its servable model, recorded" || fail "fast/low not reachable ($R)"
R="$(res "$AP" resolve codex --tier balanced --effort medium --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-5.6-terra ] && [ "$(rv "$R" effort)" = medium ] \
  && ok "tier and effort are SEPARATE dimensions (balanced -> terra, medium -> medium)" || fail "balanced/medium ($R)"
R="$(res "$AP" resolve codex --tier fast --effort low --decision rd-a --routing off)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" effort)" = xhigh ] && [ "$(rv "$R" fallback)" = routing-disabled ] \
  && ok "routing disabled keeps the concrete baseline and says why" || fail "routing off ($R)"
R="$(res "$AP" resolve codex --tier fast --effort low --routing on)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" fallback)" = no-decision ] \
  && ok "routing on with no decision keeps the baseline (never the abstract fail-open values)" || fail "no decision ($R)"
R="$(res "$AP" resolve codex --tier none --effort none --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" effort)" = xhigh ] \
  && [ "$(rv "$R" fallback)" = "no-candidate-tier;no-candidate-effort" ] \
  && ok "a low-confidence (none) candidate selects the baseline once, recorded per dimension" || fail "none candidate ($R)"
R="$(res COMMS_ACP_CODEX_MODEL=gpt-5.6-sol "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-5.6-sol ] && [ "$(rv "$R" model_source)" = pin ] \
  && [ "$(rv "$R" effort)" = low ] && [ "$(rv "$R" effort_source)" = route ] \
  && ok "an operator model pin beats the route for THAT dimension only" || fail "model pin precedence ($R)"
R="$(res COMMS_ACP_CODEX_EFFORT=high "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" effort)" = high ] && [ "$(rv "$R" effort_source)" = pin ] && [ "$(rv "$R" model)" = gpt-5.6-luna ] \
  && ok "an operator effort pin beats the route for that dimension only" || fail "effort pin precedence ($R)"
OUT="$(res COMMS_ACP_CODEX_MODEL=gpt-5.6-luna COMMS_ACP_CODEX_EFFORT=ultra "$AP" resolve codex 2>/dev/null)"; RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] \
  && ok "an explicitly pinned pair the model rejects is REFUSED, never substituted" || fail "invalid pinned pair (rc=$RC out=$OUT)"
R="$(res COMMS_ACP_CODEX_EFFORT=ultra "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" effort)" = ultra ] && [ "$(rv "$R" fallback)" = "runtime-lacks:gpt-6-luna;unsupported-pair" ] \
  && ok "a routed dimension that makes an invalid pair falls back to the baseline once, recorded" || fail "routed invalid pair ($R)"
R="$(res COMMS_ACP_CODEX_MODEL=gpt-9-preview "$AP" resolve codex)"
[ "$(rv "$R" model)" = gpt-9-preview ] && [ "$(rv "$R" pair)" = unverified-pin ] \
  && ok "a pinned model the map does not know is honoured and labelled unverified (the attestation still gates)" || fail "unknown pinned model ($R)"
R="$(res "$AP" resolve claude --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" capability)" = unsupported ] && [ "$(rv "$R" model)" = n/a ] && [ "$(rv "$R" verify)" = none ] \
  && [ "$(rv "$R" fallback)" = capability-unsupported ] \
  && ok "an unsupported provider claims no model, no effort and no verification" || fail "claude unsupported ($R)"
R="$(res "$AP" resolve codex --transport acp --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" capability)" = unsupported ] && [ "$(rv "$R" model)" = n/a ] \
  && ok "an UNMOUNTED codex turn is unsupported: nothing there applies or attests a policy" || fail "unmounted codex ($R)"
res "$AP" resolve nosuch >/dev/null 2>&1; A=$?
res "$AP" resolve codex --tier turbo >/dev/null 2>&1; B=$?
res "$AP" resolve codex --transport pigeon >/dev/null 2>&1; C=$?
res "$AP" resolve codex --decision ../x >/dev/null 2>&1; D=$?
[ "$A$B$C$D" = 2222 ] \
  && ok "unknown agent, tier, transport and a path-shaped decision id are usage errors, never read as none" || fail "usage errors ($A$B$C$D)"

# PHASE: only an implement review is routed; an approach review keeps the baseline, so reviewer
# depth can never change what a plan is judged by.
R="$(res "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase plan)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" fallback)" = phase-excluded ] \
  && ok "a routed decision on a plan-phase turn keeps the baseline (phase-excluded)" || fail "plan phase routed ($R)"
# EXPLICIT IS STRICT: an operator decision the map cannot honour is refused, never substituted.
OUT="$(res COMMS_ACP_CODEX_EFFORT=ultra "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on \
        --phase implement --candidate-source explicit 2>/dev/null)"; RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] \
  && ok "an explicit decision that forms an invalid pair is refused, where a classified one falls back" || fail "explicit invalid pair (rc=$RC)"
# THE CONCRETE POLICY'S IDENTITY (runphase names a mounted session after it).
D1="$(rv "$(res "$AP" resolve codex)" policy_digest)"
D2="$(rv "$(res "$AP" resolve codex --tier strong --effort xhigh --decision rd-a --routing on --phase implement)" policy_digest)"
D3="$(rv "$(res "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)" policy_digest)"
D4="$(rv "$(res "$AP" resolve claude)" policy_digest)"
[ -n "$D1" ] && [ "$D1" = "$D2" ] && [ "$D1" != "$D3" ] && [ "$D4" = none ] \
  && printf '%s' "$D1" | grep -qE '^[0-9a-f]{12}$' \
  && ok "the policy digest names the concrete pair: same pair same digest, a changed pair a new one, none where nothing applies" || fail "policy digest ($D1/$D2/$D3/$D4)"
# A pinned model the map does not know may not be combined with a ROUTED effort.
R="$(res COMMS_ACP_CODEX_MODEL=gpt-9-preview "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-9-preview ] && [ "$(rv "$R" effort)" = xhigh ] && [ "$(rv "$R" effort_source)" = baseline ] \
  && [ "$(rv "$R" fallback)" = unverified-pin ] \
  && ok "a routed effort is dropped rather than paired with an unverified pinned model" || fail "unverified pin + route ($R)"
PCO="$(printf '%s' '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-reserve"}]}}' \
        | res "$AP" policy-check codex - 2>/dev/null)"; RC=$?
[ "$RC" = 21 ] && printf '%s\n' "$PCO" | grep -q 'no reasoning_effort option for model gpt-reserve' \
  && ok "a session exposing no effort option for its model is undecidable with the specific cause" || fail "missing effort option message (rc=$RC $PCO)"

# THE REVIEWER RUNTIME decides which mapped models exist. Stub binaries stand in for installed
# codex builds; the harness pins the corpus to `bundled`, so every case names its runtime.
RTD="$WORK/rt-stubs"; mkdir -p "$RTD/new" "$RTD/cmux-cli-shims/x" "$RTD/old"
printf '#!/bin/sh\necho "codex-cli 0.155.1"\n' > "$RTD/new/codex"
printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$RTD/cmux-cli-shims/x/codex"
printf '#!/bin/sh\necho "codex-cli 0.150.0"\n' > "$RTD/old/codex"
chmod +x "$RTD/new/codex" "$RTD/cmux-cli-shims/x/codex" "$RTD/old/codex"
R="$(res COMMS_ACP_CODEX_PATH="$RTD/new/codex" "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-6-luna ] && [ "$(rv "$R" fallback)" = none ] && [ "$(rv "$R" runtime)" = "$RTD/new/codex" ] \
  && [ "$(rv "$R" runtime_version)" = 0.155.1 ] \
  && ok "a runtime new enough for the tier's first preference serves it (fast -> gpt-6-luna), recorded with its version" || fail "new runtime ($R)"
R="$(res COMMS_ACP_CODEX_PATH="$RTD/old/codex" "$AP" resolve codex --tier balanced --effort medium --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-5.6-terra ] && [ "$(rv "$R" fallback)" = runtime-lacks:gpt-6-sol ] \
  && ok "a runtime too old for gpt-6-sol falls back to the tier's next model, gracefully and recorded" || fail "old runtime ($R)"
R="$(cd "$WORK" && env -u COMMS_ACP_CODEX_PATH -u COMMS_ACP_CODEX_MODEL -u COMMS_ACP_CODEX_EFFORT PATH="$RTD/cmux-cli-shims/x:$RTD/new:$PATH" "$AP" resolve codex)"
[ "$(rv "$R" runtime)" = "$RTD/new/codex" ] && [ "$(rv "$R" runtime_version)" = 0.155.1 ] \
  && ok "unset, the installed codex is auto-detected on PATH, skipping per-session wrapper shims" || fail "auto-detect ($R)"
D_B="$(rv "$(res "$AP" resolve codex)" policy_digest)"; D_N="$(rv "$(res COMMS_ACP_CODEX_PATH="$RTD/new/codex" "$AP" resolve codex)" policy_digest)"
[ -n "$D_B" ] && [ -n "$D_N" ] && [ "$D_B" != "$D_N" ] \
  && ok "the same pair on a different runtime is a different policy (a runtime change is a fresh session)" || fail "runtime not in digest"
# A RUNTIME THAT HANGS on --version is killed at the probe deadline: auto-detection stays on the
# bundled runtime (recorded), an explicit path is refused — neither stalls the turn.
mkdir -p "$RTD/hang"; printf '#!/bin/sh
sleep 30
' > "$RTD/hang/codex"; chmod +x "$RTD/hang/codex"
RT_T0="$(date +%s)"
R="$(cd "$WORK" && env -u COMMS_ACP_CODEX_PATH -u COMMS_ACP_CODEX_MODEL -u COMMS_ACP_CODEX_EFFORT COMMS_ACP_RUNTIME_PROBE_SECS=1 PATH="$RTD/hang:$PATH" "$AP" resolve codex)"
res COMMS_ACP_RUNTIME_PROBE_SECS=1 COMMS_ACP_CODEX_PATH="$RTD/hang/codex" "$AP" resolve codex >/dev/null 2>&1; A=$?
RT_EL=$(( $(date +%s) - RT_T0 ))
[ "$(rv "$R" runtime)" = bundled ] && [ "$(rv "$R" fallback)" = runtime-probe-failed ] && [ "$A" = 1 ] && [ "$RT_EL" -lt 15 ] \
  && ok "a runtime hanging on --version is cut off at the deadline: auto stays bundled (recorded), explicit is refused" || fail "hanging runtime (el=${RT_EL}s rc=$A $R)"
res COMMS_ACP_CODEX_PATH="$RTD/new" "$AP" resolve codex >/dev/null 2>&1; A=$?
res COMMS_ACP_CODEX_MODEL=gpt-6-sol "$AP" resolve codex >/dev/null 2>&1; B=$?
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok "an unusable explicit runtime, or a pinned model the runtime cannot serve, is refused — never swapped" || fail "runtime refusals ($A/$B)"
res COMMS_ACP_CODEX_PATH="$RTD/new/codex" "$AP" resolve codex > "$WORK/rt-rec.tsv"
sed "s|^runtime	.*|runtime	relative/codex|" "$WORK/rt-rec.tsv" > "$WORK/rt-bad.tsv"
[ "$(res "$AP" runtime codex --policy-file "$WORK/rt-rec.tsv")" = "$RTD/new/codex" ] \
  && ! res "$AP" runtime codex --policy-file "$WORK/rt-bad.tsv" >/dev/null 2>&1 \
  && ok "the runtime accessor returns the record's validated binary and refuses a tampered one" || fail "runtime accessor"
# "USE MAX": the operator's ceiling outranks routing, the baseline and the phase exclusion;
# explicit pins outrank it; it is strict; it claims nothing where nothing applies.
R="$(res COMMS_REVIEW_MAX=1 "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
R2="$(res COMMS_REVIEW_MAX=1 "$AP" resolve codex --phase plan)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" effort)" = ultra ] && [ "$(rv "$R" model_source)" = max ] \
  && [ "$(rv "$R" fallback)" = max-override ] && [ "$(rv "$R2" effort)" = ultra ] \
  && ok "COMMS_REVIEW_MAX runs the map's ceiling over any route, baseline or phase" || fail "use max ($R)"
R="$(res COMMS_REVIEW_MAX=1 COMMS_ACP_CODEX_EFFORT=high "$AP" resolve codex)"
res COMMS_REVIEW_MAX=1 COMMS_ACP_CODEX_MODEL=gpt-5.6-luna "$AP" resolve codex >/dev/null 2>&1; A=$?
R3="$(res COMMS_REVIEW_MAX=1 "$AP" resolve claude)"
[ "$(rv "$R" effort)" = high ] && [ "$(rv "$R" effort_source)" = pin ] && [ "$(rv "$R" model_source)" = max ] && [ "$A" = 1 ] \
  && [ "$(rv "$R3" fallback)" = "max-unsupported;capability-unsupported" ] \
  && ok "a pin outranks max per dimension, an invalid max pair is refused, and max claims nothing where nothing applies" || fail "use max precedence ($R / $A / $R3)"
PM="$WORK/policy-map-probe"; rm -rf "$PM"; mkdir -p "$PM"; cp "$AP" "$PM/acp.sh"; chmod +x "$PM/acp.sh"
# A MAP ROW cannot make a combination with no apply-and-attest code claim a policy.
{ grep -v '^capability	claude	acp-mounted	' "$REPO/helpers/policy-map.tsv"
  printf 'capability\tclaude\tacp-mounted\tfixed\tm\te\tv\tn\nbaseline\tclaude\tacp-mounted\topus\thigh\npair\tclaude\tacp-mounted\topus\thigh\n'; } > "$PM/policy-map.tsv"
R="$(res "$PM/acp.sh" resolve claude)"
[ "$(rv "$R" capability)" = unsupported ] && [ "$(rv "$R" verify)" = none ] && [ "$(rv "$R" fallback)" = "capability-unimplemented;capability-unsupported" ] \
  && ok "a map row marking a combination with no apply/attest path fixed or eligible is downgraded, not believed" || fail "capability-unimplemented ($R)"

# THE MAP IS THE ONLY TABLE and it is validated whole. A bare copy of acp.sh with a crafted
# sibling map stands in for a broken install.
PM="$WORK/policy-map-probe"; rm -rf "$PM"; mkdir -p "$PM"; cp "$AP" "$PM/acp.sh"; chmod +x "$PM/acp.sh"
res "$PM/acp.sh" resolve codex >/dev/null 2>&1; A=$?
res "$PM/acp.sh" policy codex >/dev/null 2>&1; B=$?
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok "a missing map refuses resolution and the policy accessor (fail closed, no literal fallback)" || fail "missing map ($A/$B)"
sed 's/^baseline	codex	acp-mounted	gpt-6-astra	xhigh$/baseline	codex	acp-mounted	gpt-6-astra"	xhigh/' "$REPO/helpers/policy-map.tsv" > "$PM/policy-map.tsv"
res "$PM/acp.sh" provider-config codex >/dev/null 2>&1 && fail "a map value carrying a quote reached the config" \
  || ok "a map value that is not a bare identifier refuses the whole map"
{ cat "$REPO/helpers/policy-map.tsv"; printf 'version\t9\n'; } > "$PM/policy-map.tsv"
res "$PM/acp.sh" resolve codex >/dev/null 2>&1 && fail "a map with two versions was accepted" \
  || ok "a map with a duplicated version row is refused"
grep -v '^pair	codex	acp-mounted	gpt-5.6-luna	' "$REPO/helpers/policy-map.tsv" > "$PM/policy-map.tsv"
R="$(res "$PM/acp.sh" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" effort)" = xhigh ] && [ "$(rv "$R" fallback)" = "runtime-lacks:gpt-6-luna;unsupported-pair" ] \
  && ok "a routed model the map lists no accepted efforts for is never run unvalidated" || fail "unpaired routed model ($R)"

# FIXED: the baseline (plus pins) is applied and attested, routing is ignored.
sed 's/^\(capability	codex	acp-mounted	\)eligible	/\1fixed	/' "$REPO/helpers/policy-map.tsv" > "$PM/policy-map.tsv"
R="$(res "$PM/acp.sh" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement)"
[ "$(rv "$R" capability)" = fixed ] && [ "$(rv "$R" model)" = gpt-6-astra ] && [ "$(rv "$R" verify)" = "model,effort" ] \
  && [ "$(rv "$R" fallback)" = capability-fixed ] \
  && printf '%s\n' "$R" > "$PM/fixed.tsv" \
  && res "$PM/acp.sh" provider-config codex --policy-file "$PM/fixed.tsv" | grep -qx 'model_reasoning_effort = "xhigh"' \
  && ok "a fixed combination still applies and attests its baseline, and ignores the route" || fail "fixed capability ($R)"
# An explicit tier the map does not define is refused, not replaced.
grep -v '^tier	codex	acp-mounted	fast	' "$REPO/helpers/policy-map.tsv" > "$PM/policy-map.tsv"
res "$PM/acp.sh" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement \
  --candidate-source explicit >/dev/null 2>&1; A=$?
R="$(res "$PM/acp.sh" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement --candidate-source typesafe)"
[ "$A" = 1 ] && [ "$(rv "$R" fallback)" = unmapped-tier ] && [ "$(rv "$R" model)" = gpt-6-astra ] \
  && ok "an unmapped tier refuses an explicit decision and falls back (recorded) for a classified one" || fail "unmapped tier ($A / $R)"

# --policy-file: every accessor reads the PERSISTED record and never re-resolves.
PR="$WORK/policy-rec"; mkdir -p "$PR"
res "$AP" resolve codex --tier fast --effort low --decision rd-a --routing on --phase implement > "$PR/luna.tsv"
res COMMS_ACP_CODEX_EFFORT=high "$AP" provider-config codex --policy-file "$PR/luna.tsv" > "$PR/luna.toml"
grep -qx 'model = "gpt-5.6-luna"' "$PR/luna.toml" && grep -qx 'model_reasoning_effort = "low"' "$PR/luna.toml" \
  && grep -qx 'sandbox_mode = "read-only"' "$PR/luna.toml" \
  && ok "provider-config writes the persisted pair, not a pin set AFTER resolution" || fail "provider-config --policy-file"
[ "$(res COMMS_ACP_CODEX_MODEL=gpt-5.6-sol "$AP" policy codex --policy-file "$PR/luna.tsv")" = "$(printf 'gpt-5.6-luna\tlow')" ] \
  && ok "policy --policy-file returns the persisted pair" || fail "policy --policy-file"
res "$AP" policy-attest codex low gpt-5.6-luna --policy-file "$PR/luna.tsv" >/dev/null 2>&1; A=$?
res "$AP" policy-attest codex xhigh gpt-6-astra --policy-file "$PR/luna.tsv" >/dev/null 2>&1; B=$?
[ "$A" = 0 ] && [ "$B" = 20 ] \
  && ok "the attestation's expectation is the persisted record: a baseline turn is a MISMATCH for a routed one" || fail "attest --policy-file ($A/$B)"
[ "$(printf '%s' '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-5.6-luna"},{"id":"reasoning_effort","currentValue":"low"}]}}' \
     | res "$AP" policy-check codex - --policy-file "$PR/luna.tsv" >/dev/null 2>&1; echo $?)" = 0 ] \
  && [ "$(printf '%s' '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-6-astra"},{"id":"reasoning_effort","currentValue":"xhigh"}]}}' \
     | res "$AP" policy-check codex - --policy-file "$PR/luna.tsv" >/dev/null 2>&1; echo $?)" = 20 ] \
  && ok "the preflight compares a session against the persisted record (a warm baseline session is refused)" || fail "policy-check --policy-file"
# A saved MODEL preference acpx would replay onto a replacement session is read too, now that a
# routed turn may run a model other than the baseline.
[ "$(printf '%s' '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-5.6-luna"},{"id":"reasoning_effort","currentValue":"low"}],"session_options":{"model":"gpt-6-astra"}}}' \
     | res "$AP" policy-check codex - --policy-file "$PR/luna.tsv" >/dev/null 2>&1; echo $?)" = 20 ] \
  && [ "$(printf '%s' '{"acpx":{"config_options":[{"id":"model","currentValue":"gpt-5.6-luna"},{"id":"reasoning_effort","currentValue":"low"}],"session_options":"odd"}}' \
     | res "$AP" policy-check codex - --policy-file "$PR/luna.tsv" >/dev/null 2>&1; echo $?)" = 21 ] \
  && ok "a conflicting saved model preference is refused; an unreadable one is undecidable" || fail "session_options.model not read"
# A tampered or foreign record is refused, never trusted because the runner wrote it.
sed 's/^model	gpt-5.6-luna$/model	gpt-5.6-luna"x/' "$PR/luna.tsv" > "$PR/bad.tsv"
res "$AP" provider-config codex --policy-file "$PR/bad.tsv" >/dev/null 2>&1; A=$?
{ cat "$PR/luna.tsv"; printf 'model\tgpt-6-astra\n'; } > "$PR/dup.tsv"
res "$AP" provider-config codex --policy-file "$PR/dup.tsv" >/dev/null 2>&1; B=$?
res "$AP" resolve claude > "$PR/claude.tsv"
res "$AP" provider-config codex --policy-file "$PR/claude.tsv" >/dev/null 2>&1; C=$?
res "$AP" policy-attest codex low gpt-5.6-luna --policy-file "$PR/absent.tsv" >/dev/null 2>&1; D=$?
[ "$A" = 1 ] && [ "$B" = 1 ] && [ "$C" = 1 ] && [ "$D" = 21 ] \
  && ok "an injected, doubled-key, foreign-provider or missing record is refused (attestation: undecidable)" || fail "record validation ($A/$B/$C/$D)"
CAPS="$(res "$AP" capabilities)"
printf '%s\n' "$CAPS" | grep -q "^map_version: $MAPV" && printf '%s\n' "$CAPS" | grep -q '^codex/acp-mounted: eligible' \
  && printf '%s\n' "$CAPS" | grep -q '^claude/acp-mounted: unsupported' \
  && ok "capabilities shows the map version and which combinations are routing-eligible" || fail "capabilities output"
# THE MAP IS THE ONLY PLACE A VENDOR MODEL ID LIVES IN CODE. Comments may describe history.
MID_HITS="$(for f in acp.sh comms.sh runphase.sh route.sh route_backend.py route_review.py route_shadow.py; do
  sed 's/[[:space:]]*#.*$//' "$REPO/helpers/$f" | grep -nE 'gpt-[0-9]' | sed "s|^|$f:|"; done)"
[ -z "$MID_HITS" ] \
  && ok "no helper carries a vendor model id in code — the versioned map is the one table" || fail "model ids outside the map: $MID_HITS"

section "reviewer policy: a wrong-depth review is never published"
# RUNNER-LEVEL, through the real mounted codex path — not an extracted function and not a
# line-order grep. The guarantee under test is that a turn which did not run the declared
# model+effort produces NO published review-feedback, so compose can never gate on it.
# Reuses the mounted-codex setup above (artifact metadata, isolated HOME, external mount base),
# because only a mounted turn has an isolated home and therefore a policy. (codex, implement r2 B3.)
pol_msg() {  # <thread> -> writes a mounted review-request and echoes its path
  local thr="$1" m="$MA_FIX/.comms/to-codex/${MA_WS}_2026-08-20T13-00-00_$thr.md"
  { head -1 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")"
    printf 'artifact_id: %s\nhead_sha: %s\n' "$CN_MHEAD" "$CN_MHEAD"
    tail -n +2 "$MA_FIX/.comms/archive/$(basename "$MA_MSG")" \
      | sed -e "s/^thread: ma-arc-1\$/thread: $thr/" -e "s/^from: claude\$/from: grok/"
  } > "$m"; printf '%s' "$m"
}
# COUNT PUBLISHED FEEDBACK BY ENVELOPE, NOT BY FILENAME. Replies are named
# ${workspace}_${ts}_${agent}-reply-$$ (runphase.sh:542, :1078) -- the thread token appears
# INSIDE the message, never in the path. A filename glob therefore returned 0 whether or not
# the review was published, so the "nothing was published" assertions could not fail. The
# honest control below must find EXACTLY ONE, which is what gives the negative controls teeth.
# (codex + grok, implement r3, blocking.)
pol_inbox_n() {
  grep -l "^thread: $1\$" "$MA_FIX/.comms/to-grok"/*.md 2>/dev/null | wc -l | tr -d ' '
}
pol_run() {  # <thread> <dir> [extra env assignments...]
  local thr="$1" dir="$2"; shift 2
  mkdir -p "$dir"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" HOME="$CN_MHOME" COMMS_MOUNT_BASE="$CN_MBASE" \
      ACP_PARITY_PAYLOAD="$CANARY_PAY" AX_CANARY=pong COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      "$@" "$RP" run --message "$(pol_msg "$thr")" --dir "$dir" \
      --provider codex --via acp --timeout-secs 20 ) >/dev/null 2>&1
}

# CONTROL: honest turn. The policy holds end to end, so the review publishes.
POL_OK="$WORK/pol-ok"; POL_CFG="$WORK/pol-ok.cfg"
pol_run pol-ok "$POL_OK" AX_CFG_LOG="$POL_CFG"
[ "$(cn_status "$POL_OK")" = "completed" ] \
  && ok "a mounted turn that runs the declared policy completes" || fail "honest turn: status=$(cn_status "$POL_OK")"
# THE POSITIVE CONTROL. Without this, every "published nothing" assertion below could be
# passing because the lookup is blind rather than because nothing was published.
[ "$(pol_inbox_n pol-ok)" = 1 ] \
  && ok "the honest turn publishes exactly one review-feedback the lookup can see" || fail "the publication lookup is blind (honest control found $(pol_inbox_n pol-ok))"
# Read from the CHILD's view: the mount is torn down when the turn ends, so asserting on the
# parent's own write would prove less and be impossible here anyway.
grep -q 'model_reasoning_effort = "xhigh"' "$POL_CFG" 2>/dev/null \
  && ok "the config the provider actually read carries the declared effort" || fail "provider-visible config lacks the effort key"
grep -q 'model = "gpt-6-astra"' "$POL_CFG" 2>/dev/null \
  && ok "the config the provider actually read carries the declared model" || fail "provider-visible config lacks the model key"

# THE BUG ITSELF: preflight is clean, but the turn RAN at medium. Must refuse, unpublished.
POL_DIV="$WORK/pol-divergent"; pol_run pol-divergent "$POL_DIV" AX_ROLLOUT_EFFORT=medium
[ "$(cn_status "$POL_DIV")" = "failed" ] \
  && ok "a turn that ran shallower than the policy fails" || fail "divergent turn: status=$(cn_status "$POL_DIV")"
grep -q 'policy-unapplied' "$POL_DIV/result.json" 2>/dev/null \
  && ok "the divergent turn is refused with reason policy-unapplied" || fail "reason is not policy-unapplied"
[ "$(pol_inbox_n pol-divergent)" = 0 ] \
  && ok "NO review-feedback is published for a wrong-depth turn — compose can never gate on it" || fail "a wrong-depth review reached the inbox"

# MISSING EVIDENCE is undecidable, and equally unpublished.
POL_NONE="$WORK/pol-noevidence"; pol_run pol-noevidence "$POL_NONE" AX_ROLLOUT_NONE=1
[ "$(cn_status "$POL_NONE")" = "failed" ] && [ "$(pol_inbox_n pol-noevidence)" = 0 ] \
  && ok "a turn whose depth cannot be attested is refused and unpublished" || fail "unattestable turn published or passed"

# PRE-CANARY refusal: a conflicting saved preference stops the turn before any prompt is spent.
POL_PRE="$WORK/pol-preflight"; POL_PRE_LOG="$WORK/pol-preflight.argv"
pol_run pol-preflight "$POL_PRE" AX_EFFORT=medium AX_CWD_LOG="$POL_PRE_LOG"
[ "$(cn_status "$POL_PRE")" = "failed" ] \
  && ok "a session that will not serve the policy is refused before the canary" || fail "preflight refusal: status=$(cn_status "$POL_PRE")"
awk -F'\t' '$2 ~ / --file / || $2 ~ /Reply with exactly/' "$POL_PRE_LOG" 2>/dev/null | grep -q . \
  && fail "a prompt was sent after the preflight refusal" \
  || ok "no prompt — canary or review — is sent after a preflight policy refusal"
[ "$(pol_inbox_n pol-preflight)" = 0 ] \
  && ok "the preflight refusal publishes nothing" || fail "preflight refusal published feedback"
# A SAVED preference acpx would replay is refused pre-canary — distinct from the current
# options the previous case exercised. (codex, implement r3 advisory.)
POL_DES="$WORK/pol-desired"; POL_DES_LOG="$WORK/pol-desired.argv"
pol_run pol-desired "$POL_DES" AX_DESIRED_EFFORT=low AX_CWD_LOG="$POL_DES_LOG"
[ "$(cn_status "$POL_DES")" = "failed" ] && [ "$(pol_inbox_n pol-desired)" = 0 ] \
  && ok "a saved effort preference that would be replayed refuses the turn, unpublished" || fail "saved-preference refusal: status=$(cn_status "$POL_DES") inbox=$(pol_inbox_n pol-desired)"
awk -F'\t' '$2 ~ / --file /' "$POL_DES_LOG" 2>/dev/null | grep -q . \
  && fail "the review prompt was sent despite a conflicting saved preference" \
  || ok "no review prompt is sent when a saved preference would be replayed"
# THE CANARY NOW WRITES ROLLOUT EVIDENCE, so the snapshot has pre-prompt bytes to exclude.
# The honest control passing proves the window genuinely excludes them: if the snapshot were
# empty or unbounded, the canary root plus the review root would read as two and refuse.
POL_CAN="$WORK/pol-canary"; pol_run pol-canary "$POL_CAN"
[ "$(cn_status "$POL_CAN")" = "completed" ] && [ "$(pol_inbox_n pol-canary)" = 1 ] \
  && ok "pre-prompt canary rollout bytes are excluded from the window, not counted as ambiguity" || fail "canary evidence broke the honest path: status=$(cn_status "$POL_CAN")"

# THE STUB AUTHORIZES ITS DESTINATION, not some other directory. A marked fixture HOME with a
# FOREIGN CODEX_HOME previously still wrote synthetic rollout records into that foreign home —
# the guard read $HOME while the write targeted $CODEX_HOME. Runs here because this is where
# fixture_acp builds the stub; the same control in the route group silently exercised nothing.
# (codex, shadow-collector implement r8.)
# GENUINELY OUTSIDE the suite work root — a path under $WORK is legitimately authorised, so
# using one would have tested nothing. This stands in for the developer's real ~/.codex.
AXD_FOREIGN="$(mktemp -d "${TMPDIR:-/tmp}/acp-foreign-home.XXXXXX")"
AXD_MARKED="$WORK/marked-home"; mkdir -p "$AXD_MARKED/.acpx/sessions"; : > "$AXD_MARKED/.acpx-test-store"
AXD_PAY="$WORK/foreign-payload.md"; printf 'x\n' > "$AXD_PAY"
( cd "$WORK" && env PATH="$AXB:$PATH" HOME="$AXD_MARKED" CODEX_HOME="$AXD_FOREIGN" \
    ACP_PARITY_PAYLOAD="$AXD_PAY" "$AXB/npx" -y acpx@0.13.1 codex -s sess --file "$AXD_PAY" ) >/dev/null 2>&1 || true
[ -z "$(find "$AXD_FOREIGN" -name 'rollout-*.jsonl' 2>/dev/null)" ] \
  && ok "a marked HOME does not authorise rollout evidence into a CODEX_HOME outside the suite root" || fail "the stub wrote into a CODEX_HOME outside the suite root"
rm -rf "$AXD_FOREIGN"
# ...and the legitimate case still writes, so the guard is not simply off.
AXD_OK="$WORK/acp-parity/legit-home"; rm -rf "$AXD_OK"; mkdir -p "$AXD_OK"
( cd "$WORK" && env PATH="$AXB:$PATH" HOME="$AXD_MARKED" CODEX_HOME="$AXD_OK" \
    ACP_PARITY_PAYLOAD="$AXD_PAY" "$AXB/npx" -y acpx@0.13.1 codex -s sess --file "$AXD_PAY" ) >/dev/null 2>&1 || true
[ -n "$(find "$AXD_OK" -name 'rollout-*.jsonl' 2>/dev/null)" ] \
  && ok "a CODEX_HOME inside the suite work root still receives its rollout evidence" || fail "the guard blocked a legitimate fixture home"

section "reviewer routing: a routed decision reaches the mounted codex turn"
# END TO END through the real mounted codex path, with explicit decisions (no classifier, no
# network). The acpx stub fixes model/effort when a session is CREATED from the isolated config and
# reports the captured pair on every later show/prompt, as codex does — so a warm session does NOT
# silently adopt a changed policy here; only a fresh one (a new policy digest) does.
rr_decide() {  # <thread> <tier> <effort> [--replace] -> decision id
  ( cd "$MA_FIX" && env -u COMMS_ROUTE "$COMMS" review-route decide --thread "$1" --phase implement \
      --tier "$2" --effort "$3" ${4:+"$4"} 2>/dev/null ) | sed -n 's/^decision: //p'
}
rr_msg() {  # <thread> <decision-id-or-empty> -> an implement-phase mounted request carrying the id
  local thr="$1" rid="$2" m
  m="$(pol_msg "$thr")"
  sed -i.bak -e 's/^phase: plan$/phase: implement/' "$m" && rm -f "$m.bak"
  if [ -n "$rid" ]; then
    awk -v rid="$rid" -v leg="${RR_LEG:-}" 'NR==1{print; next} !done && $0=="---"{print "route_decision: " rid; if (leg != "") print "dispatch: " leg; done=1} {print}' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  fi
  printf '%s' "$m"
}
rr_run() {  # <thread> <decision-id-or-empty> <dir> [extra env...]
  local thr="$1" rid="$2" dir="$3" m; shift 3
  mkdir -p "$dir"; m="$(rr_msg "$thr" "$rid")"
  ( cd "$MA_FIX" && env PATH="$AXB:$PATH" HOME="$CN_MHOME" COMMS_MOUNT_BASE="$CN_MBASE" \
      ACP_PARITY_PAYLOAD="$CANARY_PAY" AX_CANARY=pong COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
      "$@" "$RP" run --message "$m" --dir "$dir" --provider codex --via acp --timeout-secs 20 ) >/dev/null 2>&1
}
tv() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$1/turn.tsv" 2>/dev/null; }

RR1="$(rr_decide rr-arc fast low)"
RR_D1="$WORK/rr-1"; RR_CFG="$WORK/rr-1.cfg"
rr_run rr-arc "$RR1" "$RR_D1" COMMS_REVIEW_ROUTE=1 AX_CFG_LOG="$RR_CFG"
[ -n "$RR1" ] && [ "$(cn_status "$RR_D1")" = completed ] && [ "$(pol_inbox_n rr-arc)" = 1 ] \
  && ok "a routed fast/low turn completes and publishes exactly one review" || fail "routed turn: status=$(cn_status "$RR_D1") inbox=$(pol_inbox_n rr-arc) id=$RR1"
grep -q 'model = "gpt-5.6-luna"' "$RR_CFG" 2>/dev/null && grep -q 'model_reasoning_effort = "low"' "$RR_CFG" 2>/dev/null \
  && ok "the config the provider actually read carries the ROUTED pair" || fail "provider-visible config lacks the routed pair"
[ "$(tv "$RR_D1" requested_model)" = gpt-5.6-luna ] && [ "$(tv "$RR_D1" requested_effort)" = low ] \
  && [ "$(tv "$RR_D1" observed_model)" = gpt-5.6-luna ] && [ "$(tv "$RR_D1" observed_effort)" = low ] \
  && [ "$(tv "$RR_D1" route_decision)" = "$RR1" ] && [ "$(tv "$RR_D1" policy_model_source)" = route ] \
  && [ "$(tv "$RR_D1" adapter_check)" = match ] && [ "$(tv "$RR_D1" evidence_source)" = provider-rollout ] \
  && ok "turn.tsv keeps requested, adapter-reported and provider-observed values apart, with the decision id" || fail "routed ledger ($(tr '\t\n' '= ' < "$RR_D1/turn.tsv"))"
RR_S1="$(tv "$RR_D1" acp_session)"; RR_P1="$(tv "$RR_D1" policy_digest)"
printf '%s' "$RR_P1" | grep -qE '^[0-9a-f]{12}$' && [ "${RR_S1%+p"$RR_P1"}" != "$RR_S1" ] \
  && ok "the mounted session is named after the concrete policy's digest" || fail "session not policy-named ($RR_S1 / $RR_P1)"
grep -q 'route_decision' "$RR_D1/prompt.md" 2>/dev/null \
  && fail "the reviewer's prompt carries the routing id" || ok "the reviewer's prompt does not carry the routing id"

# WARM RESUME under the same decision: same session, still the routed pair.
RR_D2="$WORK/rr-2"; rr_run rr-arc "$RR1" "$RR_D2" COMMS_REVIEW_ROUTE=1
[ "$(cn_status "$RR_D2")" = completed ] && [ "$(tv "$RR_D2" acp_session)" = "$RR_S1" ] \
  && [ "$(tv "$RR_D2" observed_model)" = gpt-5.6-luna ] \
  && ok "round 2 under the same decision resumes the SAME session at the routed pair" || fail "warm resume: status=$(cn_status "$RR_D2") session=$(tv "$RR_D2" acp_session)"
# DELIBERATE CHANGE: a new decision id and a new concrete pair is a FRESH session, verified.
RR2="$(rr_decide rr-arc balanced medium --replace)"
RR_D3="$WORK/rr-3"; rr_run rr-arc "$RR2" "$RR_D3" COMMS_REVIEW_ROUTE=1
[ -n "$RR2" ] && [ "$RR2" != "$RR1" ] && [ "$(cn_status "$RR_D3")" = completed ] \
  && [ "$(tv "$RR_D3" acp_session)" != "$RR_S1" ] && [ "$(tv "$RR_D3" observed_model)" = gpt-5.6-terra ] \
  && [ "$(tv "$RR_D3" observed_effort)" = medium ] \
  && ok "a replaced decision runs in a fresh session under the new pair, never the warm old one" || fail "deliberate change: status=$(cn_status "$RR_D3") reason=$(cn_reason "$RR_D3") session=$(tv "$RR_D3" acp_session) obs=$(tv "$RR_D3" observed_model) log=$(grep -E 'policy|canary|refus|timed' "$RR_D3/runner.log" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
# THE OLD ID after a replace is not the decision in force: refused before any prompt, unpublished.
RR_D4="$WORK/rr-4"; RR_L4="$WORK/rr-4.argv"; rr_run rr-arc "$RR1" "$RR_D4" COMMS_REVIEW_ROUTE=1 AX_CWD_LOG="$RR_L4"
[ "$(cn_status "$RR_D4")" = failed ] \
  && ! awk -F'\t' '$2 ~ / --file / || $2 ~ /Reply with exactly/' "$RR_L4" 2>/dev/null | grep -q . \
  && ok "a stale (replaced) routing id refuses the turn before any prompt" || fail "stale id: status=$(cn_status "$RR_D4")"
# A PLANTED id for another thread refuses too.
RRX="$(rr_decide rr-other fast low)"
RR_D5="$WORK/rr-5"; rr_run rr-arc "$RRX" "$RR_D5" COMMS_REVIEW_ROUTE=1
[ "$(cn_status "$RR_D5")" = failed ] && [ "$(pol_inbox_n rr-arc)" = 3 ] \
  && ok "a decision belonging to another thread never routes this one" || fail "foreign id: status=$(cn_status "$RR_D5") inbox=$(pol_inbox_n rr-arc)"
# ROUTING OFF: a stamped id is ignored, never a reason to refuse; the baseline runs and says why.
RR_D6="$WORK/rr-6"; rr_run rr-off "$RRX" "$RR_D6"
[ "$(cn_status "$RR_D6")" = completed ] && [ "$(tv "$RR_D6" requested_model)" = gpt-6-astra ] \
  && [ "$(tv "$RR_D6" requested_effort)" = xhigh ] && [ "$(tv "$RR_D6" policy_fallback)" = routing-disabled ] \
  && ok "with routing off the baseline runs, recorded as routing-disabled" || fail "routing off: status=$(cn_status "$RR_D6") fb=$(tv "$RR_D6" policy_fallback)"
# THE EXPECTATION IS NEVER RELABELLED: a routed turn that ran the baseline pair is a mismatch.
RRY="$(rr_decide rr-div fast low)"
RR_D7="$WORK/rr-7"; rr_run rr-div "$RRY" "$RR_D7" COMMS_REVIEW_ROUTE=1 AX_ROLLOUT_MODEL=gpt-6-astra AX_ROLLOUT_EFFORT=xhigh
[ "$(cn_status "$RR_D7")" = failed ] && [ "$(pol_inbox_n rr-div)" = 0 ] \
  && [ "$(tv "$RR_D7" requested_model)" = gpt-5.6-luna ] && [ "$(tv "$RR_D7" observed_model)" = gpt-6-astra ] \
  && ok "a routed turn whose rollout shows the baseline is refused unpublished, requested vs observed legible" || fail "routed divergence: status=$(cn_status "$RR_D7")"
# A SESSION THAT WILL NOT SERVE the routed pair (a stale preference) is refused before the canary.
RRZ="$(rr_decide rr-stale fast low)"
RR_D8="$WORK/rr-8"; RR_L8="$WORK/rr-8.argv"
rr_run rr-stale "$RRZ" "$RR_D8" COMMS_REVIEW_ROUTE=1 AX_MODEL=gpt-6-astra AX_EFFORT=xhigh AX_CWD_LOG="$RR_L8"
[ "$(cn_status "$RR_D8")" = failed ] && [ "$(tv "$RR_D8" adapter_check)" = mismatch ] \
  && ! awk -F'\t' '$2 ~ / --file / || $2 ~ /Reply with exactly/' "$RR_L8" 2>/dev/null | grep -q . \
  && ok "a session reporting the baseline for a routed turn is refused before any prompt" || fail "stale session: status=$(cn_status "$RR_D8") adapter=$(tv "$RR_D8" adapter_check)"
# A PANEL LEG (`<base>-codex`) routes on its base thread's decision ONLY when its panel recorded it
# (dispatch, the stamped decision, raw base thread, agent). A lookalike thread
# — with no dispatch, or with a dispatch the author typed — never borrows another thread's decision.
RRP="$(rr_decide rr-panel fast low)"
RR_PF="$MA_FIX/.comms/route-decisions/legs/$(printf '%s' d-rr-test | shasum -a 256 | cut -c1-12)"
mkdir -p "$(dirname "$RR_PF")"
printf 'dispatch	d-rr-test
decision	%s
base	rr-panel
agent	codex
agent	grok
' "$RRP" > "$RR_PF"
RR_D9="$WORK/rr-9"; RR_LEG=d-rr-test rr_run rr-panel-codex "$RRP" "$RR_D9" COMMS_REVIEW_ROUTE=1
RR_D10="$WORK/rr-10"; rr_run rr-panel-codex "$RRP" "$RR_D10" COMMS_REVIEW_ROUTE=1
RR_D10b="$WORK/rr-10b"; RR_LEG=d-typed-by-author rr_run rr-panel-codex "$RRP" "$RR_D10b" COMMS_REVIEW_ROUTE=1
# ...and a real leg carrying a DIFFERENT current decision (one that belongs to a thread literally
# named rr-panel-codex) is refused rather than judged by the standalone rule. (codex, implement r3.)
RRPC="$(rr_decide rr-panel-codex fast low)"
RR_D10c="$WORK/rr-10c"; RR_LEG=d-rr-test rr_run rr-panel-codex "$RRPC" "$RR_D10c" COMMS_REVIEW_ROUTE=1
[ "$(cn_status "$RR_D9")" = completed ] && [ "$(tv "$RR_D9" observed_model)" = gpt-5.6-luna ] \
  && [ "$(cn_status "$RR_D10")" = failed ] && [ "$(cn_status "$RR_D10b")" = failed ] && [ "$(cn_status "$RR_D10c")" = failed ] \
  && ok "a recorded panel leg carries its base decision; a lookalike (bare or typed dispatch) or a substituted decision does not" || fail "panel leg: leg=$(cn_status "$RR_D9") lookalike=$(cn_status "$RR_D10") fabricated=$(cn_status "$RR_D10b") substituted=$(cn_status "$RR_D10c")"
# THE LEG'S OWNER IS BOUND BY IDENTITY; A SHADOW IS NOT. A delivering codex turn on the GROK leg's
# thread is not that leg and is refused. A --no-deliver shadow of the grok leg by codex (what
# `comms.sh shadow --to codex` runs on the leg's private copy) measures another reviewer on the SAME
# routed request, so it still verifies on the thread alone and runs at the leg's routed pair.
RR_D10d="$WORK/rr-10d"; RR_LEG=d-rr-test rr_run rr-panel-grok "$RRP" "$RR_D10d" COMMS_REVIEW_ROUTE=1
[ "$(cn_status "$RR_D10d")" = failed ] \
  && ok "a delivering codex turn on the grok leg's thread is refused: the leg decision is bound to its owner" \
  || fail "codex delivered on grok's leg decision (status=$(cn_status "$RR_D10d"))"
RR_D10e="$WORK/rr-10e"; RR_LEG=d-rr-test rr_run rr-panel-grok "$RRP" "$RR_D10e" COMMS_REVIEW_ROUTE=1 RUNPHASE_NO_DELIVER=1
[ "$(cn_status "$RR_D10e")" = completed ] && [ "$(tv "$RR_D10e" observed_model)" = gpt-5.6-luna ] \
  && ok "a codex shadow of the routed grok leg still runs at the leg's routed pair" \
  || fail "routed shadow of another leg: status=$(cn_status "$RR_D10e") observed=$(tv "$RR_D10e" observed_model)"
# THE RUNTIME REACHES THE CHILD: the resolved binary is the adapter's CODEX_PATH, and `bundled`
# removes an inherited one, so the ledger always names what launched.
RRN="$(rr_decide rr-rt fast low)"
RR_D11="$WORK/rr-11"; RR_CFG11="$WORK/rr-11.cfg"; RR_ENV11="$WORK/rr-11.env"
rr_run rr-rt "$RRN" "$RR_D11" COMMS_REVIEW_ROUTE=1 COMMS_ACP_CODEX_PATH="$RTD/new/codex" AX_CFG_LOG="$RR_CFG11" AX_ENV_LOG="$RR_ENV11"
RR_D12="$WORK/rr-12"; RR_ENV12="$WORK/rr-12.env"
rr_run rr-rt2 "" "$RR_D12" CODEX_PATH=/bogus/codex AX_ENV_LOG="$RR_ENV12"
[ "$(cn_status "$RR_D11")" = completed ] && grep -q 'model = "gpt-6-luna"' "$RR_CFG11" \
  && grep -qx "CODEX_PATH=$RTD/new/codex" "$RR_ENV11" && ! grep -qv "CODEX_PATH=$RTD/new/codex" "$RR_ENV11" \
  && [ "$(cn_status "$RR_D12")" = completed ] && grep -qx 'CODEX_PATH=<unset>' "$RR_ENV12" && ! grep -q 'bogus' "$RR_ENV12" \
  && [ -n "$(tv "$RR_D11" acpx_launcher)" ] \
  && ok "the resolved runtime is the child's CODEX_PATH, and a bundled turn unsets an inherited one" || fail "runtime to child: s11=$(cn_status "$RR_D11") s12=$(cn_status "$RR_D12")"
RR_D13="$WORK/rr-13"; RR_CFG13="$WORK/rr-13.cfg"
rr_run rr-max "" "$RR_D13" COMMS_REVIEW_MAX=1 AX_CFG_LOG="$RR_CFG13"
[ "$(cn_status "$RR_D13")" = completed ] && grep -q 'model_reasoning_effort = "ultra"' "$RR_CFG13" \
  && [ "$(tv "$RR_D13" policy_model_source)" = max ] && [ "$(tv "$RR_D13" observed_effort)" = ultra ] \
  && ok "a use-max turn runs and attests the ceiling pair" || fail "use-max turn: status=$(cn_status "$RR_D13")"
