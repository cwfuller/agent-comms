#!/bin/bash
# Classify an /auto task: whether to run an approach-review phase, and how much
# reasoning effort the implementer should use.
#
# Always executed (never sourced), always bash. Prints a stable key: value
# block on stdout so a template can parse it with sed. Exit 0 is a decision
# (including fail-open); exit 2 is usage.
#
# Fail-open (plan=no, effort=medium, source=fail-open|disabled) when:
#   - COMMS_ROUTE=0/false/no/off
#   - TYPESAFE_API_KEY is unset and no COMMS_ROUTE_STUB is set
#   - python3 is missing
#   - the HTTP call times out, 4xx/5xx, or returns a body we cannot parse
#
# Never selects a reviewer, a model, or a panel roster. Human --plan / --no-plan
# in /auto skip this helper entirely.
#
# Env:
#   TYPESAFE_API_KEY          live TypeSafe key (not required with COMMS_ROUTE_STUB)
#   COMMS_ROUTE=0             disable; fail-open with source=disabled
#   COMMS_ROUTE_URL           default https://api.typesafe.ai/v1/systemone
#   COMMS_ROUTE_MODEL         default jev-latest
#   COMMS_ROUTE_TIMEOUT_SECS  default 8
#   COMMS_ROUTE_STUB          path to a canned System One JSON body (tests)
set -euo pipefail

usage_err() { echo "route.sh: $*" >&2; exit 2; }

fail_open() { # <reason> [source]
  local reason="$1" source="${2:-fail-open}"
  reason="$(printf '%s' "$reason" | tr '\n\r' '  ')"
  printf 'plan: no\n'
  printf 'effort: medium\n'
  printf 'complexity: standard\n'
  printf 'plan_p: -\n'
  printf 'effort_p: -\n'
  printf 'complexity_confidence: -\n'
  printf 'source: %s\n' "$source"
  printf 'reason: %s\n' "$reason"
  exit 0
}

task=""
file=""
explicit_task=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task)
      [ $# -ge 2 ] || usage_err "--task needs a value"
      task="$2"; explicit_task=1; shift 2 ;;
    --file)
      [ $# -ge 2 ] || usage_err "--file needs a path"
      file="$2"; shift 2 ;;
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

# Whitespace-only is not a query we can classify.
case "$(printf '%s' "$task" | tr -d ' \t\n\r')" in
  "") usage_err "task is empty" ;;
esac

case "${COMMS_ROUTE:-}" in
  0|false|no|off|FALSE|NO|OFF) fail_open "COMMS_ROUTE disables the classifier" disabled ;;
esac

stub="${COMMS_ROUTE_STUB:-}"
key="${TYPESAFE_API_KEY:-}"
if [ -z "$stub" ] && [ -z "$key" ]; then
  fail_open "TYPESAFE_API_KEY is unset"
fi

if ! command -v python3 >/dev/null 2>&1; then
  fail_open "python3 is unavailable"
fi

# Pass the task through the environment so the heredoc cannot interpolate it.
export COMMS_ROUTE_TASK="$task"
export COMMS_ROUTE_STUB="$stub"
export COMMS_ROUTE_URL="${COMMS_ROUTE_URL:-https://api.typesafe.ai/v1/systemone}"
export COMMS_ROUTE_MODEL="${COMMS_ROUTE_MODEL:-jev-latest}"
export COMMS_ROUTE_TIMEOUT_SECS="${COMMS_ROUTE_TIMEOUT_SECS:-8}"
export TYPESAFE_API_KEY="$key"

python3 - <<'PY' || fail_open "classifier python exited non-zero"
import json, os, sys, urllib.error, urllib.request

def fail_open(reason, source="fail-open"):
    reason = " ".join(str(reason).split())
    sys.stdout.write(
        "plan: no\n"
        "effort: medium\n"
        "complexity: standard\n"
        "plan_p: -\n"
        "effort_p: -\n"
        "complexity_confidence: -\n"
        f"source: {source}\n"
        f"reason: {reason}\n"
    )
    sys.exit(0)

def emit(plan, effort, complexity, plan_p, effort_p, cconf, source, reason):
    reason = " ".join(str(reason).split())
    sys.stdout.write(
        f"plan: {plan}\n"
        f"effort: {effort}\n"
        f"complexity: {complexity}\n"
        f"plan_p: {plan_p}\n"
        f"effort_p: {effort_p}\n"
        f"complexity_confidence: {cconf}\n"
        f"source: {source}\n"
        f"reason: {reason}\n"
    )
    sys.exit(0)

LEVELS = ("mechanical", "standard", "hard", "architectural")
EFFORTS = ("low", "medium", "high", "xhigh")
PLAN_NOUL_MIN = 0.7
PLAN_COMPLEXITY = {"2", "3"}  # hard, architectural
COMPLEXITY_CONFIDENCE_MIN = 0.5
EFFORT_CONFIDENCE_MIN = 0.6

task = os.environ.get("COMMS_ROUTE_TASK", "")
if len(task) > 8000:
    task = task[:8000]

timeout_raw = os.environ.get("COMMS_ROUTE_TIMEOUT_SECS", "8")
try:
    timeout = int(timeout_raw)
    if timeout <= 0:
        raise ValueError
except ValueError:
    fail_open("COMMS_ROUTE_TIMEOUT_SECS is not a positive integer")

stub = os.environ.get("COMMS_ROUTE_STUB") or ""
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
                "implementer needs. Do not pick a reviewer or a model."
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
                    "who can read the repository?"
                ),
                "criteria": [
                    "Mechanical: rename, typo, reformat, comment, one obvious command, a factual question about a known file.",
                    "Standard: implement a well-specified function, endpoint, or component; write or fix tests; a localized bug whose cause is already understood.",
                    "Hard: unknown-cause debugging, concurrency, security, multi-module refactor, or data migration.",
                    "Architectural: the wrong approach would be expensive; whole-system design; a new abstraction other code must follow.",
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
    key = os.environ.get("TYPESAFE_API_KEY") or ""
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

def unit_float(value, what):
    try:
        v = float(value)
    except (TypeError, ValueError):
        fail_open(f"{what} is missing or not a number")
    if v != v or v < 0.0 or v > 1.0:
        fail_open(f"{what} is out of range")
    return v

plan_p = unit_float(noul_ans.get("noul"), "needs_plan.noul")
probs = score_ans.get("probabilities")
if not isinstance(probs, dict) or not probs:
    fail_open("complexity.probabilities is missing")
cconf = unit_float(score_ans.get("confidence"), "complexity.confidence")

# Argmax over declared levels. On a tie keep the cheaper (lower) level.
# Do not interpolate the weighted score — jev-1.13 is weak at that.
# A non-unit probability must fail-open: treating 2 or Inf as a winner would
# enable plan: yes from a malformed body.
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

# Policy lives in code, not in the model.
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

plan_p_s = f"{plan_p:.3f}"
effort_p_s = f"{effort_p:.3f}" if effort_p is not None else "-"
cconf_s = f"{cconf:.3f}"
reason = (
    f"needs_plan={plan_p_s} complexity={complexity} "
    f"(level {best_level}, conf {cconf_s}) effort={choice} "
    f"(conf {econf:.3f})"
)
src = "stub" if os.environ.get("COMMS_ROUTE_STUB") else "jev"
emit(plan, effort, complexity, plan_p_s, effort_p_s, cconf_s, src, reason)
PY
