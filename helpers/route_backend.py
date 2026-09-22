# Decision backends for helpers/route.sh.
#
# Policy (plan / effort / abstract tier) lives in route.sh and never imports a
# vendor SDK. A backend only answers three atomic questions against a state and
# returns a System One-shaped `answers` object:
#
#   needs_plan  {noul: 0..1}
#   complexity  {probabilities: {"0".."3"}, confidence: 0..1}
#   effort      {choice, confidence, probabilities?}
#
# Add a backend by decorating a function with @register("name", "alias"...).
# Select it with COMMS_ROUTE_BACKEND=<name>. Jev/TypeSafe is one implementation.
"""Swappable decision backends for comms.sh route."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import urllib.error
import urllib.request

QUESTIONS = {
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
}

# THE OUTBOUND STATE, built in ONE place. Both the live classify path and the shadow collector
# call this: a collector that sent `{"task": ...}` without `kind` recorded decisions made under
# a DIFFERENT prompt from the one production sends, which makes the observation worthless for
# the comparison it exists to support. Same class of bug as hand-writing QUESTIONS.
# (codex P2 + grok, shadow-collector implement r1 — corroborated.)
STATE_KIND = (
    "agent-comms /auto query. Decide whether an approach-review "
    "phase is warranted, and how much reasoning effort the "
    "implementer needs. Do not pick a reviewer or a vendor model."
)


def build_state(task):
    """The exact outbound state both callers send."""
    return {"task": task, "kind": STATE_KIND}


# ---------------------------------------------------------------------------------------------
# THE REVIEWER RUBRIC — a DIFFERENT question from the one above. `QUESTIONS` asks how hard a task
# is for the IMPLEMENTER, from the initiating sentence alone; using that answer to price a REVIEW
# would reuse a judgement about the wrong actor made from the wrong input. A reviewer's cost is
# set by the change it must attack: what was done, the acceptance criteria, the files touched, and
# what earlier rounds already found. (handoff 2026-09-22, "reviewer-specific classification
# contract"; docs/ROADMAP.md "a reviewer classifier would need the artifact, phase, risk and prior
# findings".)
#
# Versioned: every decision record carries REVIEW_RUBRIC_VERSION and a hash of these questions,
# and the live decider and the shadow collector both import them from HERE, so an observation can
# never be made under a different prompt from the one production sends.
REVIEW_RUBRIC_VERSION = "reviewer-v1"
# The NAMED policy variants that map raw answers to a candidate. route.sh applies the implementer
# one (with its one-step bump) and names it in `reason:`; route_review.py applies the reviewer one
# (no bump). Recorded on every decision and shadow row so rows made under different mappings are
# never pooled by accident.
IMPLEMENTER_POLICY_VARIANT = "implementer-bump-v1"
REVIEWER_POLICY_VARIANT = "reviewer-v1"
REVIEW_QUESTIONS = {
    "review_depth": {
        "type": "score",
        "instructions": (
            "How much reasoning does an adequate adversarial review of THIS change need, to "
            "find the defects that would block it from landing? Judge the change described "
            "(what was done, the files, the acceptance criteria, earlier findings), not the "
            "length of the request."
        ),
        "criteria": [
            {
                "what": "Mechanical: the change is trivially checkable.",
                "signals": [
                    "Docs, comments, a rename, or formatting only",
                    "A one-line fix whose correctness is visible in the diff",
                ],
                "not_for": "Any change to control flow, state, concurrency, security, or data.",
            },
            {
                "what": "Standard: an ordinary bounded change with a clear shape.",
                "signals": [
                    "A well-specified function or test change in one module",
                    "A localized fix whose cause is stated and whose blast radius is small",
                ],
                "not_for": "Multi-module interactions, lifecycle/race reasoning, or trust boundaries.",
            },
            {
                "what": "Hard: defects hide in interactions the diff does not show directly.",
                "signals": [
                    "Concurrency, lifecycle, retries, caching, or state across rounds",
                    "Security, sandboxing, permissions, or input validation",
                    "Several modules or a protocol other code depends on",
                ],
                "not_for": "Changes a careful reviewer can verify line by line.",
            },
            {
                "what": "Architectural: a wrong direction would be expensive to undo after landing.",
                "signals": [
                    "A new abstraction or contract other code must follow",
                    "Safety-critical gates, or a change to what the review process itself trusts",
                ],
                "not_for": "A localized change whose first pass is cheap to correct.",
            },
        ],
    },
    "review_effort": {
        "type": "choice",
        "instructions": (
            "Pick the cheapest reasoning effort at which a reviewer would reliably find the "
            "blocking defects in this change in one pass. Missing a real defect is far more "
            "expensive than extra reasoning."
        ),
        "criteria": {
            "low": {
                "what": "The change is mechanical and its correctness is visible directly.",
                "not_for": "Anything with behaviour a reviewer must reason about.",
            },
            "medium": {
                "what": "An ordinary bounded change with a clear shape and small blast radius.",
                "not_for": "Interactions across modules, rounds, processes, or trust boundaries.",
            },
            "high": {
                "what": "Interactions, lifecycle, or security reasoning the diff does not show directly.",
                "not_for": "Changes a careful reviewer can verify line by line.",
            },
            "xhigh": {
                "what": "Long chains of constraints, safety-critical gates, or a new contract.",
                "not_for": "Anything a single focused high-effort pass would finish.",
            },
        },
    },
}

REVIEW_STATE_KIND = (
    "agent-comms reviewer routing. Decide how much reasoning an adversarial code REVIEW of "
    "the described change needs. Do not pick a reviewer, a vendor model, or whether to plan."
)

# The bounded input, section by section. Headings are the ones the /auto review-request
# template and AGENTS.md prescribe; a request that lacks one records it as OMITTED rather than
# silently sending less. Limits are characters of each section's body after the heading.
REVIEW_SECTIONS = (
    ("intent", ("intent / approach", "intent"), 1500),
    ("done", ("what was done", "what was done this round"), 2500),
    ("criteria", ("acceptance criteria",), 1500),
    ("files", ("files changed",), 2000),
    ("decisions", ("key decisions",), 1200),
    ("focus", ("review focus", "review ask"), 1000),
    ("prior", ("prior review context", "prior findings"), 2000),
)
REVIEW_TOTAL_LIMIT = 10000


def _split_request(text):
    """(frontmatter dict, body) of a review-request file. Only the leading --- block counts."""
    fm, body = {}, text
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                for ln in lines[1:i]:
                    if ":" in ln:
                        k, v = ln.split(":", 1)
                        k = k.strip()
                        if k and k not in fm:  # first match, as every shell reader does
                            fm[k] = v.strip()
                body = "\n".join(lines[i + 1:])
                break
    return fm, body


def _sections(body):
    """{normalized heading: text} for every `## ` heading (first occurrence wins)."""
    out, cur, buf = {}, None, []
    for ln in body.splitlines():
        if ln.startswith("## "):
            if cur is not None and cur not in out:
                out[cur] = "\n".join(buf).strip()
            cur = ln[3:].strip().lower()
            buf = []
        elif cur is not None:
            buf.append(ln)
    if cur is not None and cur not in out:
        out[cur] = "\n".join(buf).strip()
    return out


# The branches a change under review is measured against, in order. The artifact's own base
# (head_sha) is only a last resort: send stamps artifact == base for a committed (clean) tree, and
# a dirty tree's base is HEAD, so diffing against it measures nothing, or only the uncommitted tail.
INTEGRATION_REFS = ("refs/heads/main", "refs/heads/master", "refs/remotes/origin/HEAD")


def _git(repo, *args):
    import subprocess
    env = {k: v for k, v in os.environ.items() if k not in GIT_SELECTORS}
    try:
        out = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True,
                             timeout=20, env=env)
    except Exception:
        return None
    return out.stdout if out.returncode == 0 else None


def measure_change(repo, artifact, base=None):
    """(numstat, measured_from, ref) for the change under review, or (None, None, why).

    The helper measures the change itself. The request's own `## Files changed` section is written
    by the author whose work is under review, so it is sent only as request text and never drives
    the signals. The change is `merge-base(artifact, integration branch)..artifact`; an artifact that
    IS the integration tip, an unresolvable id, or an EMPTY diff is UNMEASURED — never a measured
    zero, which would read as "trivially small" and steer toward the cheapest reviewer.
    """
    import re
    if not (repo and re.fullmatch(r"[0-9a-f]{40}", artifact or "")):
        return None, None, "no full artifact id"
    frm, ref = None, None
    for r in INTEGRATION_REFS:
        mb = (_git(repo, "merge-base", artifact, r) or "").strip()
        if re.fullmatch(r"[0-9a-f]{40}", mb) and mb != artifact:
            frm, ref = mb, r
            break
    if frm is None and re.fullmatch(r"[0-9a-f]{40}", base or "") and base != artifact:
        frm, ref = base, "head_sha"
    if frm is None:
        return None, None, "no integration base distinct from the artifact"
    ns = _git(repo, "diff", "--numstat", frm, artifact)
    if ns is None:
        return None, None, "git diff failed"
    if not ns.strip():
        return None, None, "the measured diff is empty"
    return ns, frm, ref


def prepare_review_input(text, repo, artifact=None, base=None):
    """(state, meta, unsendable_reason) — the ONE path from a request to the outbound reviewer
    state, used by the live decider AND the shadow collector, so an observation is never made
    under an input production would not send. unsendable_reason is None when it may be sent."""
    fm, _ = _split_request(text)
    artifact = artifact or fm.get("artifact_id", "")
    base = base or fm.get("head_sha", "")
    numstat, frm, ref_or_why = measure_change(repo, artifact, base)
    state, meta = build_review_state(text, numstat=numstat, artifact=artifact)
    meta["measured_from"] = frm
    meta["measured_ref"] = ref_or_why if numstat is not None else None
    if numstat is None:
        return state, meta, "the change under review could not be measured (%s)" % ref_or_why
    if meta["sent_chars"] == 0:
        return state, meta, "the request has none of the reviewable sections"
    return state, meta, None


def risk_signals(numstat):
    """Deterministic counts from a numstat block: files, insertions, deletions, binary files, and
    changed files per top-level path. Counts only — no judgement is encoded here."""
    sig = {"files_changed": 0, "insertions": 0, "deletions": 0, "binary_files": 0, "top_level": {}}
    for line in (numstat or "").splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        add, rem, path = parts[0], parts[1], parts[-1]
        sig["files_changed"] += 1
        if add == "-" or rem == "-":
            sig["binary_files"] += 1
        else:
            try:
                sig["insertions"] += int(add)
                sig["deletions"] += int(rem)
            except ValueError:
                continue
        top = path.split("/", 1)[0] if "/" in path else "(root)"
        sig["top_level"][top] = sig["top_level"].get(top, 0) + 1
    return sig


def build_review_state(request_text, numstat=None, artifact=None):
    """(state, input_meta) for a reviewer-routing decision — the ONE builder live and shadow share.

    The state carries role/workflow/phase/round, the artifact id (IDENTITY ONLY — it conveys which
    snapshot, not its content), each bounded section of the request, and count-only risk signals
    MEASURED from `numstat` (the helper's own `git diff --numstat` of the artifact; None when it
    could not be measured). The author's `## Files changed` text is sent as a request section like
    any other and never feeds the signals. input_meta records exactly what was sent, what was
    truncated, what was absent, and whether the signals were measured.
    """
    fm, body = _split_request(request_text)
    secs = _sections(body)
    sent, meta_secs, omitted = {}, {}, []
    total = 0
    for name, headings, limit in REVIEW_SECTIONS:
        text = None
        for h in headings:
            if h in secs:
                text = secs[h]
                break
        if text is None or not text.strip():
            omitted.append(name)
            continue
        room = max(0, min(limit, REVIEW_TOTAL_LIMIT - total))
        piece = text[:room]
        sent[name] = piece
        total += len(piece)
        meta_secs[name] = {"chars": len(text), "sent_chars": len(piece),
                           "truncated": len(piece) < len(text)}
    state = {
        "kind": REVIEW_STATE_KIND,
        "role": "reviewer",
        "workflow": fm.get("workflow", ""),
        "phase": fm.get("phase", ""),
        "round": fm.get("round", ""),
        "artifact": {"id": artifact or fm.get("artifact_id", ""),
                     "note": "identity only; no code content is sent"},
        "request": sent,
        "risk_signals": risk_signals(numstat) if numstat is not None else None,
    }
    meta = {
        "sections": meta_secs,
        "omitted": omitted,
        "sent_chars": total,
        "request_chars": len(request_text),
        "total_limit": REVIEW_TOTAL_LIMIT,
        "signals_measured": numstat is not None,
    }
    return state, meta


# Git variables that can point a command at a DIFFERENT repository than the cwd.
GIT_SELECTORS = {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_PREFIX",
}

def canonical_project():
    """sha256 of the canonical MAIN repo root of the CURRENT working tree.

    Derived here, never taken from the environment: permission that trusts a caller-supplied
    identity is not permission. Mirrors route.sh's shadow_repo_key and runphase's
    mount_repo_key so one clone is one project across worktrees and mounts. Shared by the shadow
    collector and the live reviewer decider.
    """
    import subprocess
    env = {k: v for k, v in os.environ.items() if k not in GIT_SELECTORS}
    try:
        out = subprocess.run(["git", "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=10, env=env)
        if out.returncode != 0:
            return "", ""
        first = out.stdout.splitlines()[0] if out.stdout.splitlines() else ""
        if not first.startswith("worktree "):
            return "", ""
        root = os.path.realpath(first[len("worktree "):].strip())
    except Exception:
        return "", ""
    if not root:
        return "", ""
    return hashlib.sha256(root.encode("utf-8")).hexdigest(), root


def transmission_permitted(key):
    """The per-project allowlist for sending project text to a third-party classifier.

    Enforced at every path that transmits: the shadow collector (here AND in route.sh) and the
    live reviewer decider. Absent by default, outside the tree, keyed by project hash.

    route_shadow.py is installed executable with its own __main__, so a caller that ran it
    directly — including the suite — bypassed the shell-side gate entirely and could reach
    HTTP with an empty project key. Permission is a property of the backend-call boundary,
    not of one entry path. (codex P1, implement r1.)
    """
    if not key:
        return False
    allow = os.environ.get("COMMS_ROUTE_SHADOW_ALLOW") or os.path.join(
        os.environ.get("AGENT_COMMS_HOME") or os.path.expanduser("~/.agent-comms"),
        "route-shadow-allow")
    try:
        with open(allow, "r", encoding="utf-8") as fh:
            return any(line.strip() == key for line in fh)
    except OSError:
        return False


BACKENDS = {}
ALIASES = {}


def register(name, *aliases):
    """Register a classify(state, questions, timeout) -> answers function."""

    def deco(fn):
        BACKENDS[name] = fn
        ALIASES[name] = name
        for alias in aliases:
            ALIASES[alias] = name
        return fn

    return deco


class BackendError(Exception):
    def __init__(self, reason, source="fail-open"):
        super().__init__(reason)
        self.reason = reason
        self.source = source


def _parse_answers(body_text):
    try:
        parsed = json.loads(body_text)
    except json.JSONDecodeError as e:
        raise BackendError("response is not JSON") from e
    if not isinstance(parsed, dict):
        raise BackendError("response JSON is not an object")
    answers = parsed.get("answers")
    if not isinstance(answers, dict):
        raise BackendError("response has no answers object")
    return answers


@register("stub")
def backend_stub(state, questions, timeout):
    _reset_raw()
    path = os.environ.get("COMMS_ROUTE_STUB") or ""
    if not path:
        raise BackendError("COMMS_ROUTE_STUB is unset")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            body = fh.read()
    except OSError as e:
        raise BackendError(f"COMMS_ROUTE_STUB unreadable ({type(e).__name__})") from e
    _observe(body)
    return _parse_answers(body)


# LAST RAW OBSERVATION, captured before any parsing can raise. `_parse_answers` throws on a
# malformed body and its BackendError carries only reason/source, so returning (raw, answers)
# on the success path alone would still discard exactly the responses worth studying. Kept
# module-level rather than returned, because route.sh unpacks classify() as a 2-tuple and a
# third element would become a non-zero python exit — a fail-open on the LIVE path.
# Distinguishes "no response received" from "response received but unusable".
LAST_RAW = {"body": None, "body_b64": None, "http_status": None, "received": False,
            "decodable": None}


def _reset_raw():
    LAST_RAW["body"] = None
    LAST_RAW["http_status"] = None
    LAST_RAW["received"] = False
    LAST_RAW["decodable"] = None
    LAST_RAW["body_b64"] = None


def _observe(raw, http_status=None):
    """Record a received body losslessly. Returns bytes; callers decode as THEY require.

    The record wants every byte that arrived; classification wants strict UTF-8. Conflating
    those let a lossy decode change a live routing decision. (codex P2, implement r2.)
    """
    if isinstance(raw, bytes):
        try:
            raw.decode("utf-8")
            LAST_RAW["decodable"] = True
        except UnicodeDecodeError:
            LAST_RAW["decodable"] = False
        LAST_RAW["body"] = raw.decode("utf-8", "replace")
        LAST_RAW["body_b64"] = base64.b64encode(raw).decode("ascii")
    else:
        LAST_RAW["decodable"] = True
        LAST_RAW["body"] = raw
        LAST_RAW["body_b64"] = base64.b64encode(raw.encode("utf-8")).decode("ascii")
    LAST_RAW["http_status"] = http_status
    LAST_RAW["received"] = True
    return raw


@register("typesafe", "jev")
def backend_typesafe(state, questions, timeout):
    _reset_raw()
    key = os.environ.get("TYPESAFE_API_KEY") or ""
    if not key:
        raise BackendError("TYPESAFE_API_KEY is unset")
    payload = {
        "model": os.environ.get("COMMS_ROUTE_MODEL") or "jev-latest",
        "state": state,
        "questions": questions,
    }
    url = os.environ.get("COMMS_ROUTE_URL") or "https://api.typesafe.ai/v1/systemone"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            # Observe the BYTES, then decode STRICTLY for classification — unchanged from
            # pre-collector behaviour, so an undecodable body still fails closed.
            body = _observe(resp.read(), getattr(resp, "status", None)).decode("utf-8")
    except urllib.error.HTTPError as e:
        # An error body is evidence too: a 4xx explaining a bad model id is exactly what the
        # smoke test exists to surface, and discarding it leaves "request failed (HTTPError)".
        try:
            _observe(e.read(), getattr(e, "code", None))
        except Exception:
            pass
        raise BackendError(f"request failed (HTTPError {getattr(e, 'code', '?')})") from e
    except Exception as e:
        raise BackendError(f"request failed ({type(e).__name__})") from e
    return _parse_answers(body)


def resolve():
    """Pick a backend or (None, None) if none is enabled.

    Enable with COMMS_ROUTE_BACKEND=<name>, COMMS_ROUTE_STUB (implies stub),
    or COMMS_ROUTE=1 (implies typesafe). A TypeSafe key alone does not enable
    a network call — the classifier is opt-in.
    """
    explicit = (os.environ.get("COMMS_ROUTE_BACKEND") or "").strip().lower()
    if explicit:
        name = ALIASES.get(explicit)
        if not name:
            raise BackendError(f"unknown decision backend '{explicit}'")
        return name, BACKENDS[name]
    if os.environ.get("COMMS_ROUTE_STUB"):
        return "stub", BACKENDS["stub"]
    flag = (os.environ.get("COMMS_ROUTE") or "").strip().lower()
    if flag in ("1", "true", "yes", "on"):
        return "typesafe", BACKENDS["typesafe"]
    return None, None


def classify(state, timeout, questions=None):
    """Run the enabled backend. Returns (name, answers) or (None, None).

    `questions` defaults to the implementer rubric; the reviewer decider passes REVIEW_QUESTIONS.
    """
    name, fn = resolve()
    if fn is None:
        return None, None
    return name, fn(state, QUESTIONS if questions is None else questions, timeout)
