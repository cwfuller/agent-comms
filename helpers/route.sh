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
#   - no backend, and no prompt override
#   - python3 missing
#   - HTTP timeout / 4xx/5xx / body we cannot parse, unless a prompt override applies
#
# Never selects a reviewer, a vendor model id, or a panel roster. Human
# --plan / --no-plan in /auto skip this helper entirely. Prompt phrases
# ("use strong", "skip plan") are in-helper overrides, copied from jev-router.
# They still win when an enabled backend errors. A live classification raises
# effort and tier one step (low→medium→high→xhigh, fast→balanced→strong);
# fail-open stays medium/balanced. That bumped mapping is the NAMED policy
# variant `implementer-bump-v1` (recorded in `reason:`, the decision log and
# shadow records): it is an ADVISORY implementer hint, and it is never the
# candidate that routes a reviewer. Reviewer routing uses its own rubric and
# its own un-bumped policy (`reviewer-v1`, helpers/route_review.py).
#
# --shadow --reviewer --file <review-request> [--thread T] records what the
# REVIEWER rubric would decide for a request, through the same state builder
# and questions as the live reviewer decider. Like every shadow call it prints
# only `shadow-decision <id>` and writes nothing a loop reads.
#
# Env:
#   COMMS_ROUTE_BACKEND       typesafe|jev|stub — opt-in decision backend
#   COMMS_ROUTE=1             enable the typesafe backend (same as BACKEND=typesafe)
#   COMMS_ROUTE=0             disable; fail-open with source=disabled
#   TYPESAFE_API_KEY          live TypeSafe key (typesafe backend only)
#   COMMS_ROUTE_URL           default https://api.typesafe.ai/v1/systemone
#   COMMS_ROUTE_MODEL         default jev-latest
#   COMMS_ROUTE_TIMEOUT_SECS  default 8
#   COMMS_ROUTE_STUB          canned System One JSON (selects the stub backend)
#   COMMS_ROUTE_LOG           optional JSONL decision log (tests / calibration)
#
# RECORDS. Every classification python makes (typesafe, stub, override, fail-open) is also written
# to <main repo>/.comms/route-decisions/implementer/<route_id>.json — UTC time, workspace, the
# bounded state, whether anything was sent, the raw answers, and the ten keys — and the id is
# printed as an eleventh line, `route_id: <id>`, which /auto stamps on its review request so a
# decision joins to the loop it sized. The directory is NOT env-settable (the same rule as the
# shadow records: a settable destination could be a tracked path). Outside a git repo there is
# nowhere to record; a failed write warns on stderr and never changes the decision.
#   COMMS_ROUTE_CURRENT_TIER  fast|balanced|strong — session's current tier
#                             (honoured when --current-tier is omitted)
#   COMMS_ROUTE_CONTEXT_TOKENS  approx conversation size; blocks downgrades past 20k
#                             (honoured when --context-tokens is omitted)
#
# A TypeSafe key alone does NOT enable classification. Set COMMS_ROUTE_BACKEND
# or COMMS_ROUTE=1. Prompt overrides still work with no backend.
set -euo pipefail

# User/project SETTINGS (helpers/settings.sh): fills unset variables from the settings files, so
# a setting works in every shell — including agent tool shells that never read the shell rc.
# Absent next to this script (an old install, a bare copy) it is simply skipped: env still works.
[ -f "$(dirname "$0")/settings.sh" ] && . "$(dirname "$0")/settings.sh"

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

# ---------------------------------------------------------------------------
# SHADOW COLLECTOR — observes what Jev would decide, and CANNOT tell /auto anything.
#
# Isolation is a property of the OUTPUT CONTRACT, not of caller discipline: this path never
# prints the ten-key block that /auto seds for `plan:` / `effort:` / `tier:` / `source:`, so a
# real loop has nothing to read even by accident. It also never reaches `fail_open`/`_write`,
# because route.sh:154 turns any python failure into a SUCCESSFUL keys block and `_write`
# swallows OSError — reusing either would defeat both the isolation and the loud failures.
# (codex + grok, plan r1.)
#
# The collector must also never be implemented by exporting COMMS_ROUTE_BACKEND / COMMS_ROUTE /
# COMMS_ROUTE_STUB into the environment /auto inherits: resolve() treats those as the on-switch,
# so that would silently arm the live classify path. They are set for THIS python call only.
shadow_repo_key() {  # -> 64-hex sha256 of the canonical MAIN repo root
  # The main checkout, not `pwd` and not --show-toplevel: a session worktree and each review
  # mount have different toplevels, so hashing those turns one clone into several projects and
  # a permit granted where the operator works would not match where the loop runs. Same input
  # as runphase's mount_repo_key. (codex + grok, plan r1.)
  local root
  root="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
      -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_CEILING_DIRECTORIES \
      git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || return 1
  [ -n "$root" ] || return 1
  root="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
  printf '%s' "$root" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256
      elif command -v sha256sum >/dev/null 2>&1; then sha256sum; else printf ''; fi; } | cut -c1-64
}
shadow_main_root() {
  local root
  root="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
      -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_CEILING_DIRECTORIES \
      git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || return 1
  [ -n "$root" ] || return 1
  (cd "$root" 2>/dev/null && pwd -P)
}
# The operator allowlist lives OUTSIDE the tree, keyed by repo hash, and is ABSENT by default.
# A tracked permit would be present in every worktree and carried into the mounted review
# artifact; and sending task text to a third-party API is a different act from reading local
# files, so client projects must not be transmittable by accident. (grok, plan r1.)
SHADOW_ALLOW="${COMMS_ROUTE_SHADOW_ALLOW:-${AGENT_COMMS_HOME:-$HOME/.agent-comms}/route-shadow-allow}"
SHADOW_PY="$(cd "$(dirname "$0")" && pwd)/route_shadow.py"
shadow_die() { echo "route.sh: shadow: $*" >&2; exit 1; }
shadow_run() {
  local key root dir id
  key="$(shadow_repo_key)" || shadow_die "cannot compute the project key (not a git repo, or no sha256 utility)"
  # PERMISSION BEFORE ANY SOCKET. Default is refusal, and the refusal happens before the task
  # text could leave the machine.
  shadow_permitted "$key" \
    || shadow_die "project $key is not permitted to transmit task text (add the key to $SHADOW_ALLOW)"
  root="$(shadow_main_root)" || shadow_die "cannot resolve the main repo root"
  # Records live under the MAIN repo's .comms/, which is gitignored AND stripped by cmd_snapshot
  # before `git add -A`. A file anywhere else in the worktree would be snapshotted into the
  # review artifact, so a reviewer would read the task text and the mapped decision — a path
  # into a live loop that sits outside the stdout contract. (grok, plan r1.)
  # The record root is ALWAYS the main repo's gitignored .comms/, which cmd_snapshot strips
  # before `git add -A`. NOT overridable: an env-settable destination could be pointed at a
  # tracked directory and would sweep task text into a live review artifact, which is exactly
  # the path out of the stdout contract this design closes. The suite isolates itself by
  # running against its own temporary repository instead. (codex P2, implement r3.)
  dir="$root/.comms/route-shadow"
  mkdir -p "$dir" || shadow_die "cannot create $dir"
  id="$(shadow_decision_id)" || shadow_die "cannot mint a decision id"
  COMMS_ROUTE_SHADOW_ID="$id" \
  COMMS_ROUTE_SHADOW_DIR="$dir" \
  COMMS_ROUTE_SHADOW_KEY="$key" \
  COMMS_ROUTE_SHADOW_THREAD="$shadow_thread" \
  COMMS_ROUTE_SHADOW_CURRENT_TIER="$current_tier" \
  COMMS_ROUTE_SHADOW_CONTEXT_TOKENS="$context_tokens" \
  COMMS_ROUTE_SHADOW_WORKSPACE="${COMMS_WORKSPACE:-}" \
  COMMS_ROUTE_SHADOW_ROLE="$shadow_role" \
  COMMS_ROUTE_TASK="$task" \
  COMMS_ROUTE_BACKEND="${COMMS_ROUTE_SHADOW_BACKEND:-typesafe}" \
    python3 "$SHADOW_PY" || shadow_die "the collector failed (see stderr above)"
  # The ONLY stdout this path produces. Deliberately not parseable as plan/effort/tier/source.
  printf 'shadow-decision %s\n' "$id"
  exit 0
}
shadow_decision_id() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; return; fi
  python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null
}
shadow_permitted() {
  local key="$1"
  [ -n "$key" ] || return 1
  [ -f "$SHADOW_ALLOW" ] || return 1
  grep -qxF "$key" "$SHADOW_ALLOW" 2>/dev/null
}

task=""
file=""
shadow_mode=0
shadow_role=implementer
shadow_thread=""
explicit_task=0
current_tier=""
context_tokens=""
tier_from_cli=0
tokens_from_cli=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shadow) shadow_mode=1; shift ;;
    --reviewer)
      [ "$shadow_mode" -eq 1 ] || usage_err "--reviewer is only valid with --shadow (live reviewer decisions are made by comms.sh review-route)"
      shadow_role=reviewer; shift ;;
    --thread)
      [ "$shadow_mode" -eq 1 ] || usage_err "--thread is only valid with --shadow"
      [ $# -ge 2 ] || usage_err "--thread needs a value"
      shadow_thread="$2"; shift 2 ;;
    --task)
      [ $# -ge 2 ] || usage_err "--task needs a value"
      task="$2"; explicit_task=1; shift 2 ;;
    --file)
      [ $# -ge 2 ] || usage_err "--file needs a path"
      file="$2"; shift 2 ;;
    --current-tier)
      [ $# -ge 2 ] || usage_err "--current-tier needs fast|balanced|strong"
      current_tier="$2"; tier_from_cli=1; shift 2 ;;
    --context-tokens)
      [ $# -ge 2 ] || usage_err "--context-tokens needs a non-negative integer"
      context_tokens="$2"; tokens_from_cli=1; shift 2 ;;
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

# CLI flags win and usage-error. Ambient env is fallback; invalid ambient is
# ignored (not exit 2) so a stale COMMS_ROUTE_CURRENT_TIER=high cannot abort
# /auto. /auto never passes the flags, so cache-sticky is env-only there.
if [ "$tier_from_cli" -eq 1 ]; then
  case "$current_tier" in
    fast|balanced|strong) ;;
    *) usage_err "--current-tier must be fast, balanced, or strong" ;;
  esac
else
  current_tier="${COMMS_ROUTE_CURRENT_TIER:-}"
  case "$current_tier" in
    ""|fast|balanced|strong) ;;
    *) current_tier="" ;;
  esac
fi
if [ "$tokens_from_cli" -eq 1 ]; then
  case "$context_tokens" in
    ''|*[!0-9]*) usage_err "--context-tokens must be a non-negative integer" ;;
  esac
else
  context_tokens="${COMMS_ROUTE_CONTEXT_TOKENS:-}"
  case "$context_tokens" in
    ""|*[!0-9]*) context_tokens="" ;;
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

if [ "$shadow_mode" -eq 1 ]; then
  shadow_run   # never returns; never prints the classify keys
fi

case "${COMMS_ROUTE:-}" in
  0|false|no|off|FALSE|NO|OFF) fail_open "COMMS_ROUTE disables the classifier" disabled ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  fail_open "python3 is unavailable"
fi

export COMMS_ROUTE_HOME="$(cd "$(dirname "$0")" && pwd)"
export COMMS_ROUTE_TASK="$task"
# Set unconditionally here, so an inherited value can never redirect the records. And only where
# git CONFIRMS the path is ignored: the helpers are installed globally, so `route` also runs in
# repositories that never ran project init, and there a record would be an ordinary untracked
# file carrying task text that `git add -A` commits. (codex, implement r1.)
# The probe covers EVERY path that will hold task data, not a stand-in name: the directory, the
# exact final `<id>.json`, and the exact temp `.<id>.tmp`. A sample filename proves nothing under
# negation rules (`!…/*-*.json`, or `.comms/**` + `!.comms/**/` re-including files), where the
# probe reads ignored while the real UUID names stay committable. (codex, implement r2.)
_route_root="$(shadow_main_root 2>/dev/null || true)"
COMMS_ROUTE_RECORD_ID="$(shadow_decision_id 2>/dev/null || true)"
COMMS_ROUTE_RECORD_DIR=""
route_record_ignored() {  # <root> <id> -> 0 only when git ignores all three paths
  local rel=".comms/route-decisions/implementer" p
  for p in "$rel/" "$rel/$2.json" "$rel/.$2.tmp"; do
    (cd "$1" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git check-ignore -q "$p") 2>/dev/null || return 1
  done
}
if [ -n "$_route_root" ] && [ -n "$COMMS_ROUTE_RECORD_ID" ]; then
  if route_record_ignored "$_route_root" "$COMMS_ROUTE_RECORD_ID"; then
    COMMS_ROUTE_RECORD_DIR="$_route_root/.comms/route-decisions/implementer"
  else
    echo "route.sh: not recording this decision: git does not ignore .comms/route-decisions/implementer/ in $_route_root (run install.sh --scope=project there)" >&2
  fi
fi
export COMMS_ROUTE_RECORD_DIR COMMS_ROUTE_RECORD_ID
export COMMS_ROUTE_CURRENT_TIER="$current_tier"
export COMMS_ROUTE_CONTEXT_TOKENS="${context_tokens:-0}"

python3 - <<'PY' || fail_open "classifier python exited non-zero"
import hashlib, json, os, re, sys, time

KEYS = (
    "plan", "effort", "complexity", "tier", "gate",
    "plan_p", "effort_p", "complexity_confidence", "source", "reason",
)
# THE NAMED POLICY VARIANT this helper applies. The one-step bump below is part of it; a
# different mapping must get a different name so logged rows stay comparable.
POLICY_VARIANT = "implementer-bump-v1"

# What the record needs beyond the ten keys; filled in as the run gets that far.
TRACE = {"state": None, "sent": False, "backend": None, "answers": None}

def _record(fields):
    """Persist this decision; returns the route id, or "" when nothing could be recorded."""
    rdir = os.environ.get("COMMS_ROUTE_RECORD_DIR") or ""
    rid = os.environ.get("COMMS_ROUTE_RECORD_ID") or ""
    if not rdir or not re.fullmatch(r"[0-9a-f-]{8,64}", rid):
        return ""
    try:
        return _record_write(rdir, rid, fields)
    except Exception as e:  # recording must never cost the decision (e.g. a vanished cwd)
        sys.stderr.write(f"route.sh: could not record decision in {rdir}: {e}\n")
        return ""

def _record_write(rdir, rid, fields):
    task_raw = os.environ.get("COMMS_ROUTE_TASK") or ""
    rec = {
        "record_version": 1,
        "route_id": rid,
        "role": "implementer",
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "workspace": os.environ.get("COMMS_ROUTE_RECORD_WORKSPACE") or "",
        "cwd": os.getcwd(),
        "policy_variant": POLICY_VARIANT,
        "task_sha256": hashlib.sha256(task_raw.encode("utf-8", "replace")).hexdigest(),
        "task_excerpt": task_raw[:200],
        "current_tier": os.environ.get("COMMS_ROUTE_CURRENT_TIER") or "",
        "context_tokens": os.environ.get("COMMS_ROUTE_CONTEXT_TOKENS") or "",
        "overrides": dict(overrides),
        "backend": TRACE["backend"],
        "sent": TRACE["sent"],
        "state": TRACE["state"],
        "answers": TRACE["answers"],
        "decision": {k: fields[k] for k in KEYS},
    }
    os.makedirs(rdir, exist_ok=True)
    # The temp name is the one the shell proved ignored; O_EXCL so a stale one is never reused.
    tmp = os.path.join(rdir, "." + rid + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, os.path.join(rdir, rid + ".json"))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return rid

def _write(fields):
    reason = " ".join(str(fields["reason"]).split())
    fields = dict(fields)
    fields["reason"] = reason
    rid = _record(fields)
    for k in KEYS:
        sys.stdout.write(f"{k}: {fields[k]}\n")
    if rid:
        sys.stdout.write(f"route_id: {rid}\n")
    log_path = os.environ.get("COMMS_ROUTE_LOG") or ""
    if log_path:
        rec = {
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "task": (os.environ.get("COMMS_ROUTE_TASK") or "")[:110],
        }
        rec.update({k: fields[k] for k in KEYS if k != "reason"})
        rec["reason"] = reason
        rec["policy_variant"] = POLICY_VARIANT
        try:
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except OSError:
            pass
    sys.exit(0)

overrides = {}

def emit(**fields):
    _write(fields)

def emit_overrides(reason):
    emit(
        plan=overrides.get("plan", "no"),
        effort=overrides.get("effort", "medium"),
        complexity="standard",
        tier=overrides.get("tier", "balanced"),
        gate="override",
        plan_p="-", effort_p="-", complexity_confidence="-",
        source="override",
        reason=reason,
    )

def fail_open(reason, source="fail-open"):
    # Human prompt overrides still win when an enabled backend errors or
    # returns an unusable answers object. Empty until detect_overrides runs.
    if overrides:
        emit_overrides(f"prompt override; {reason}")
    _write({
        "plan": "no", "effort": "medium", "complexity": "standard",
        "tier": "balanced", "gate": source,
        "plan_p": "-", "effort_p": "-", "complexity_confidence": "-",
        "source": source, "reason": reason,
    })

_home = os.environ.get("COMMS_ROUTE_HOME") or ""
if _home:
    sys.path.insert(0, _home)
try:
    import route_backend
except ImportError:
    fail_open("route_backend.py is not installed next to route.sh")

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
    r"\b(?:use|switch to)\s+plan\b|\bplan first\b", re.I)
# Routing command, not adjective+noun: "use fast to rename" / "use fast." match;
# "use fast algorithms" / "use low latency" / "use fast, in-memory caching"
# do not. Comma is not a tail: it is how English lists adjectives. Intentionally
# not `with`/`on` as prefixes and not a bare word boundary after the token.
_OV_TAIL = r"(?=\s*$|[.;:!]|\s+(?:to|and|then|for)\b)"
_OV_TIER = (
    (re.compile(r"\b(?:use|switch to)\s+(?:fast|haiku|luna)(?:\s+tier)?" + _OV_TAIL, re.I), "fast"),
    (re.compile(r"\b(?:use|switch to)\s+(?:balanced|sonnet|terra)(?:\s+tier)?" + _OV_TAIL, re.I), "balanced"),
    (re.compile(r"\b(?:use|switch to)\s+(?:strong|opus|sol)(?:\s+tier)?" + _OV_TAIL, re.I), "strong"),
)
_OV_EFFORT = re.compile(
    r"\b(?:use|switch to)\s+(low|medium|high|xhigh)(?:\s+effort)?" + _OV_TAIL, re.I)
# "use max": the strongest tier at the highest implementer effort. The same phrase makes /auto
# export COMMS_REVIEW_MAX=1, which raises every reviewer to the map's ceiling.
_OV_MAX = re.compile(r"\b(?:use|switch to)\s+max(?:imum)?(?:\s+(?:tier|effort))?" + _OV_TAIL, re.I)

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
    if _OV_MAX.search(text):
        ov["tier"] = "strong"
        ov["effort"] = "xhigh"
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

# ONE state builder, shared with the shadow collector so an observation can never be made
# under a different prompt than production sends. (codex P2 + grok, implement r1.)
state = route_backend.build_state(task)
TRACE["state"] = state
try:
    _bname, _bfn = route_backend.resolve()
    TRACE["backend"] = _bname
    # "sent" = the backend was asked. For the stub nothing leaves the machine, but it is the
    # same code path; the record names the backend, so a reader can tell.
    TRACE["sent"] = _bfn is not None
    backend_name, answers = route_backend.classify(state, timeout)
except route_backend.BackendError as e:
    fail_open(e.reason, e.source)
TRACE["answers"] = answers

if answers is None:
    fail_open(
        "no decision backend enabled "
        "(set COMMS_ROUTE_BACKEND=typesafe or COMMS_ROUTE=1)"
    )

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
gate = "classify"
# Low confidence refuses fast (and plan). The later one-step bump then
# raises this middle pick to strong. Gate name records the refuse-fast
# choice, not the post-bump tier.
if cconf < COMPLEXITY_CONFIDENCE_MIN:
    tier = "balanced"
    gate = "low-confidence-middle"

def _step_up(seq, value):
    try:
        i = seq.index(value)
    except ValueError:
        return value
    return seq[min(i + 1, len(seq) - 1)]

# Prefer slightly more reasoning / a stronger model than the raw classification.
# Fail-open and prompt overrides skip this. Cache-sticky still refuses a
# downgrade after the bump.
effort = _step_up(EFFORTS, effort)
if effort != choice:
    effort_p = None
tier = _step_up(TIERS, tier)

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
    f"policy={POLICY_VARIANT} needs_plan={plan_p_s} complexity={complexity} "
    f"(level {best_level}, conf {cconf_s}) effort={effort} "
    f"(classified {choice}, conf {econf:.3f}) tier={tier} gate={gate}"
)
emit(
    plan=plan, effort=effort, complexity=complexity, tier=tier, gate=gate,
    plan_p=plan_p_s, effort_p=effort_p_s, complexity_confidence=cconf_s,
    source=backend_name, reason=reason,
)
PY
