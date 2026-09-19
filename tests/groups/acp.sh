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
grep -qE 'gpt-6-astra|model_reasoning_effort' "$REPO/helpers/runphase.sh" \
  && fail "runphase.sh carries a literal model or effort value" \
  || ok "runphase.sh holds no model or effort literal — it asks acp.sh"
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
pol_inbox_n() { find "$MA_FIX/.comms/to-grok" -name "*$1*" -type f 2>/dev/null | wc -l | tr -d ' '; }
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
