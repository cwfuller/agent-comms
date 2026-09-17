#!/bin/bash
# Classify an /auto task: plan vs not-plan, implementer effort, and an abstract
# tier (fast|balanced|strong). Policy is composed in code the way the published
# Jev routers do: atomic TypeSafe questions, then overrides / confidence /
# cache-stickiness in ordinary ifs. Never a cartesian catalog of vendor models.
#
# Always executed (never sourced), always bash. Prints a stable key: value
# block on stdout so a template can parse it with sed. Exit 0 is a decision
# (including fail-open); exit 2 is usage.
#
# Fail-open (plan=no, effort=medium, tier=balanced, source=fail-open|disabled):
#   - COMMS_ROUTE=0/false/no/off
#   - no key, no stub, and no prompt override
#   - python3 missing
#   - HTTP timeout / 4xx/5xx / body we cannot parse
#
# Never selects a reviewer, a vendor model id, or a panel roster. Human
# --plan / --no-plan in /auto skip this helper entirely. Prompt phrases
# ("use strong", "skip plan") are in-helper overrides, copied from jev-router.
#
# Env:
#   TYPESAFE_API_KEY          live TypeSafe key (not required with stub or override)
#   COMMS_ROUTE=0             disable; fail-open with source=disabled
#   COMMS_ROUTE_URL           default https://api.typesafe.ai/v1/systemone
#   COMMS_ROUTE_MODEL         default jev-latest
#   COMMS_ROUTE_TIMEOUT_SECS  default 8
#   COMMS_ROUTE_STUB          canned System One JSON body (tests)
#   COMMS_ROUTE_LOG           optional JSONL decision log (tests / calibration)
#   COMMS_ROUTE_CURRENT_TIER  fast|balanced|strong — session's current tier
#   COMMS_ROUTE_CONTEXT_TOKENS  approx conversation size; blocks downgrades past 20k
set -euo pipefail

usage_err() { echo "route.sh: $*" >&2; exit 2; }

KEYS_FAIL_OPEN() { # <reason> [source]
  local reason="$1" source="${2:-fail-open}"
  reason="$(printf '%s' "$reason" | tr '\n\r' '  ')"
  printf 'plan: no\n'
  printf 'effort: medium\n'
  printf 'complexity: standard\n'
  printf 'tier: balanced\n'
  printf 'gate: %s\n' "$source"
  printf 'plan_p: -\n'
  printf 'effort_p: -\n'
  printf 'complexity_confidence: -\n'
  printf 'source: %s\n' "$source"
  printf 'reason: %s\n' "$reason"
  exit 0
}
fail_open() { KEYS_FAIL_OPEN "$@"; }

task=""
file=""
explicit_task=0
current_tier=""
context_tokens=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task)
      [ $# -ge 2 ] || usage_err "--task needs a value"
      task="$2"; explicit_task=1; shift 2 ;;
    --file)
      [ $# -ge 2 ] || usage_err "--file needs a path"
      file="$2"; shift 2 ;;
    --current-tier)
      [ $# -ge 2 ] || usage_err "--current-tier needs fast|balanced|strong"
      current_tier="$2"; shift 2 ;;
    --context-tokens)
      [ $# -ge 2 ] || usage_err "--context-tokens needs a non-negative integer"
      context_tokens="$2"; shift 2 ;;
    --)
      shift
      task="$*"
      explicit_task=1
      break ;;
    -h|--help)
      awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0 ;;
    -*)
      usage_err "unknown option '$1'" ;;
    *)
      task="$*"
      explicit_task=1
      break ;;
  esac
done

if [ -n "$current_tier" ]; then
  case "$current_tier" in
    fast|balanced|strong) ;;
    *) usage_err "--current-tier must be fast, balanced, or strong" ;;
  esac
fi
if [ -n "$context_tokens" ]; then
  case "$context_tokens" in
    ''|*[!0-9]*) usage_err "--context-tokens must be a non-negative integer" ;;
  esac
fi

if [ -n "$file" ]; then
  [ "$explicit_task" -eq 0 ] || usage_err "pass --file or a task, not both"
  [ -f "$file" ] || usage_err "--file is not a readable file"
  task="$(cat "$file")"
elif [ "$explicit_task" -eq 0 ]; then
  if [ -t 0 ]; then
    usage_err "a task is required (--task, --file, argv, or stdin)"
  fi
  task="$(cat)"
fi

case "$(printf '%s' "$task" | tr -d ' \t\n\r')" in
  "") usage_err "task is empty" ;;
esac

case "${COMMS_ROUTE:-}" in
  0|false|no|off|FALSE|NO|OFF) fail_open "COMMS_ROUTE disables the classifier" disabled ;;
esac

stub="${COMMS_ROUTE_STUB:-}"
key="${TYPESAFE_API_KEY:-}"

if ! command -v python3 >/dev/null 2>&1; then
  fail_open "python3 is unavailable"
fi

export COMMS_ROUTE_TASK="$task"
export COMMS_ROUTE_STUB="$stub"
export COMMS_ROUTE_URL="${COMMS_ROUTE_URL:-https://api.typesafe.ai/v1/systemone}"
export COMMS_ROUTE_MODEL="${COMMS_ROUTE_MODEL:-jev-latest}"
export COMMS_ROUTE_TIMEOUT_SECS="${COMMS_ROUTE_TIMEOUT_SECS:-8}"
export COMMS_ROUTE_CURRENT_TIER="$current_tier"
export COMMS_ROUTE_CONTEXT_TOKENS="${context_tokens:-0}"
export TYPESAFE_API_KEY="$key"

python3 - <<'PY' || fail_open "classifier python exited non-zero"
import json, os, re, sys, time, urllib.request

KEYS = (
    "plan", "effort", "complexity", "tier", "gate",
    "plan_p", "effort_p", "complexity_confidence", "source", "reason",
)

def _write(fields):
    reason = " ".join(str(fields["reason"]).split())
    fields = dict(fields)
    fields["reason"] = reason
    for k in KEYS:
        sys.stdout.write(f"{k}: {fields[k]}\n")
    log_path = os.environ.get("COMMS_ROUTE_LOG") or ""
    if log_path:
        rec = {
            "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "task": (os.environ.get("COMMS_ROUTE_TASK") or "")[:110],
        }
        rec.update({k: fields[k] for k in KEYS if k != "reason"})
        rec["reason"] = reason
        try:
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except OSError:
            pass
    sys.exit(0)

def fail_open(reason, source="fail-open"):
    _write({
        "plan": "no", "effort": "medium", "complexity": "standard",
        "tier": "balanced", "gate": source,
        "plan_p": "-", "effort_p": "-", "complexity_confidence": "-",
        "source": source, "reason": reason,
    })

def emit(**fields):
    _write(fields)

LEVELS = ("mechanical", "standard", "hard", "architectural")
EFFORTS = ("low", "medium", "high", "xhigh")
TIERS = ("fast", "balanced", "strong")
TIER_OF = {
    "mechanical": "fast",
    "standard": "balanced",
    "hard": "strong",
    "architectural": "strong",
}
RANK = {"fast": 0, "balanced": 1, "strong": 2}
PLAN_NOUL_MIN = 0.7
PLAN_COMPLEXITY = {"2", "3"}
COMPLEXITY_CONFIDENCE_MIN = 0.5
EFFORT_CONFIDENCE_MIN = 0.6
DOWNGRADE_MAX_CONTEXT = 20000

# Prompt overrides — jev-router's "the human already decided" patterns, adapted
# to abstract tiers (not vendor model names). More-specific "no plan" beats "plan".
_OV_PLAN_NO = re.compile(
    r"\b(?:skip plan|no plan|without plan|don't plan|do not plan)\b", re.I)
_OV_PLAN_YES = re.compile(
    r"\b(?:use|switch to|with|on)\s+plan\b|\bplan first\b", re.I)
_OV_TIER = (
    (re.compile(r"\b(?:use|switch to|with|on)\s+(?:fast|haiku|luna)\b", re.I), "fast"),
    (re.compile(r"\b(?:use|switch to|with|on)\s+(?:balanced|sonnet|terra)\b", re.I), "balanced"),
    (re.compile(r"\b(?:use|switch to|with|on)\s+(?:strong|opus|sol)\b", re.I), "strong"),
)
_OV_EFFORT = re.compile(
    r"\b(?:use|switch to|with)\s+(low|medium|high|xhigh)\b", re.I)

def detect_overrides(text):
    ov = {}
    if _OV_PLAN_NO.search(text):
        ov["plan"] = "no"
    elif _OV_PLAN_YES.search(text):
        ov["plan"] = "yes"
    for rx, tier in _OV_TIER:
        if rx.search(text):
            ov["tier"] = tier
            break
    m = _OV_EFFORT.search(text)
    if m:
        ov["effort"] = m.group(1).lower()
    return ov

def unit_float(value, what):
    try:
        v = float(value)
    except (TypeError, ValueError):
        fail_open(f"{what} is missing or not a number")
    if v != v or v < 0.0 or v > 1.0:
        fail_open(f"{what} is out of range")
    return v

task = os.environ.get("COMMS_ROUTE_TASK", "")
if len(task) > 8000:
    task = task[:8000]
overrides = detect_overrides(task)

timeout_raw = os.environ.get("COMMS_ROUTE_TIMEOUT_SECS", "8")
try:
    timeout = int(timeout_raw)
    if timeout <= 0:
        raise ValueError
except ValueError:
    fail_open("COMMS_ROUTE_TIMEOUT_SECS is not a positive integer")

stub = os.environ.get("COMMS_ROUTE_STUB") or ""
key = os.environ.get("TYPESAFE_API_KEY") or ""

# Override-only path: a prompt like "use strong" must work without a TypeSafe key
# (jev-router: explicit request wins; the classifier is not required).
if not stub and not key:
    if not overrides:
        fail_open("TYPESAFE_API_KEY is unset")
    emit(
        plan=overrides.get("plan", "no"),
        effort=overrides.get("effort", "medium"),
        complexity="standard",
        tier=overrides.get("tier", "balanced"),
        gate="override",
        plan_p="-", effort_p="-", complexity_confidence="-",
        source="override",
        reason="prompt override; no TypeSafe call",
    )

body_text = ""
if stub:
    try:
        with open(stub, "r", encoding="utf-8") as fh:
            body_text = fh.read()
    except OSError as e:
        fail_open(f"COMMS_ROUTE_STUB unreadable ({type(e).__name__})")
else:
    payload = {
        "model": os.environ.get("COMMS_ROUTE_MODEL") or "jev-latest",
        "state": {
            "task": task,
            "kind": (
                "agent-comms /auto query. Decide whether an approach-review "
                "phase is warranted, and how much reasoning effort the "
                "implementer needs. Do not pick a reviewer or a vendor model."
            ),
        },
        "questions": {
            "needs_plan": {
                "type": "noul",
                "instructions": (
                    "Does this task have genuine ambiguity about the "
                    "implementation approach, such that writing code before "
                    "agreeing on direction would be expensive to undo?"
                ),
                "criteria": {
                    "true": (
                        "Novel architecture, high blast radius, safety-critical "
                        "work, or multiple reasonable approaches that would be "
                        "costly to reverse after implementing."
                    ),
                    "false": (
                        "The implementation path is clear: a localized fix, a "
                        "well-specified feature, a typo, tests, docs, or work "
                        "where a wrong first pass is cheap to correct in review."
                    ),
                },
            },
            "complexity": {
                "type": "score",
                "instructions": (
                    "How hard is this coding task for a competent implementer "
                    "who can read the repository? Judge the reasoning the "
                    "request demands, not the length of the reply."
                ),
                "criteria": [
                    {
                        "what": "Mechanical: trivial, purely factual, or one-file busywork.",
                        "signals": [
                            "Rename a symbol, fix a typo, reformat, add a comment",
                            "Answer a short factual question about a known file",
                            "Run one obvious command and report the output",
                        ],
                        "not_for": "Anything requiring design judgement or multi-file reasoning.",
                    },
                    {
                        "what": "Standard: ordinary bounded engineering with a clear shape.",
                        "signals": [
                            "Implement a well-specified function, endpoint, or component",
                            "Write or fix tests for existing behaviour",
                            "Localised bug fix where the cause is already understood",
                        ],
                        "not_for": "Open-ended architecture, subtle concurrency, or unknown-cause debugging.",
                    },
                    {
                        "what": "Hard: unknown-cause debugging, concurrency, security, or multi-module work.",
                        "signals": [
                            "Debug a failure whose cause is unknown",
                            "Refactor across several modules",
                            "Security, auth, concurrency, or data-migration logic",
                        ],
                        "not_for": "Work a competent mid-level engineer would finish without thinking hard.",
                    },
                    {
                        "what": "Architectural: the wrong approach would be expensive to undo.",
                        "signals": [
                            "Whole-system design or a new abstraction other code must follow",
                            "High blast radius, safety-critical, or ambiguous direction",
                        ],
                        "not_for": "A localised change whose first pass is cheap to correct in review.",
                    },
                ],
            },
            "effort": {
                "type": "choice",
                "instructions": (
                    "Pick the cheapest reasoning effort that can complete this "
                    "task in one pass. Judge the reasoning the task demands, "
                    "not the length of the reply."
                ),
                "criteria": {
                    "low": {
                        "what": "Mechanical or purely factual work.",
                        "not_for": "Design judgement or debugging an unknown cause.",
                    },
                    "medium": {
                        "what": "Ordinary bounded engineering with a clear shape.",
                        "not_for": "Open-ended architecture or subtle concurrency.",
                    },
                    "high": {
                        "what": "Hard reasoning, ambiguity, or high blast radius.",
                        "not_for": "Work a competent mid-level engineer would finish without thinking hard.",
                    },
                    "xhigh": {
                        "what": "Very hard work: long chains of constraints, novel architecture, or safety-critical design.",
                        "not_for": "Anything a single focused high-effort pass would finish.",
                    },
                },
            },
        },
    }
    url = os.environ.get("COMMS_ROUTE_URL") or "https://api.typesafe.ai/v1/systemone"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body_text = resp.read().decode("utf-8")
    except Exception as e:
        fail_open(f"request failed ({type(e).__name__})")

try:
    parsed = json.loads(body_text)
except json.JSONDecodeError:
    fail_open("response is not JSON")

if not isinstance(parsed, dict):
    fail_open("response JSON is not an object")
answers = parsed.get("answers")
if not isinstance(answers, dict):
    fail_open("response has no answers object")

noul_ans = answers.get("needs_plan")
score_ans = answers.get("complexity")
choice_ans = answers.get("effort")
if not isinstance(noul_ans, dict) or not isinstance(score_ans, dict) or not isinstance(choice_ans, dict):
    fail_open("response is missing needs_plan, complexity, or effort")

plan_p = unit_float(noul_ans.get("noul"), "needs_plan.noul")
probs = score_ans.get("probabilities")
if not isinstance(probs, dict) or not probs:
    fail_open("complexity.probabilities is missing")
cconf = unit_float(score_ans.get("confidence"), "complexity.confidence")

best_p = -1.0
best_level = "0"
for idx in ("0", "1", "2", "3"):
    raw = 0 if idx not in probs else probs[idx]
    p = unit_float(raw, f"complexity.probabilities[{idx}]")
    if p > best_p:
        best_p = p
        best_level = idx
complexity = LEVELS[int(best_level)]

choice = choice_ans.get("choice")
econf = unit_float(choice_ans.get("confidence"), "effort.confidence")
if choice not in EFFORTS:
    fail_open("effort.choice is not a known effort")
effort_p = None
eprobs = choice_ans.get("probabilities")
if isinstance(eprobs, dict) and choice in eprobs:
    effort_p = unit_float(eprobs[choice], f"effort.probabilities[{choice}]")

plan = "no"
if (
    plan_p >= PLAN_NOUL_MIN
    and best_level in PLAN_COMPLEXITY
    and cconf >= COMPLEXITY_CONFIDENCE_MIN
):
    plan = "yes"

effort = choice
if econf < EFFORT_CONFIDENCE_MIN:
    effort = "medium"
    effort_p = None

# Abstract tier is composed HERE, not asked of Jev — same shape as jev-router
# mapping a Choice onto concrete models, but we emit the abstract name so this
# helper never names a vendor model id (claude/codex/grok each map it).
tier = TIER_OF[complexity]
gate = "jev"
# jev-codex-router calibration: low confidence → middle tier, not frontier and
# not a silent downgrade to fast.
if cconf < COMPLEXITY_CONFIDENCE_MIN:
    tier = "balanced"
    gate = "low-confidence-middle"

current = os.environ.get("COMMS_ROUTE_CURRENT_TIER") or ""
try:
    ctx = int(os.environ.get("COMMS_ROUTE_CONTEXT_TOKENS") or "0")
except ValueError:
    ctx = 0
if current in RANK and ctx > DOWNGRADE_MAX_CONTEXT and RANK[tier] < RANK[current]:
    tier = current
    gate = "cache-sticky"

if overrides:
    if "plan" in overrides:
        plan = overrides["plan"]
    if "effort" in overrides:
        effort = overrides["effort"]
        effort_p = None
    if "tier" in overrides:
        tier = overrides["tier"]
    gate = "override"

plan_p_s = f"{plan_p:.3f}"
effort_p_s = f"{effort_p:.3f}" if effort_p is not None else "-"
cconf_s = f"{cconf:.3f}"
reason = (
    f"needs_plan={plan_p_s} complexity={complexity} "
    f"(level {best_level}, conf {cconf_s}) effort={choice} "
    f"(conf {econf:.3f}) tier={tier} gate={gate}"
)
src = "stub" if stub else "jev"
if overrides and src != "stub":
    src = "jev"
emit(
    plan=plan, effort=effort, complexity=complexity, tier=tier, gate=gate,
    plan_p=plan_p_s, effort_p=effort_p_s, complexity_confidence=cconf_s,
    source=src, reason=reason,
)
PY
