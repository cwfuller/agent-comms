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
LAST_RAW = {"body": None, "http_status": None, "received": False}


def _observe(body, http_status=None):
    LAST_RAW["body"] = body
    LAST_RAW["http_status"] = http_status
    LAST_RAW["received"] = True
    return body


@register("typesafe", "jev")
def backend_typesafe(state, questions, timeout):
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
            body = _observe(resp.read().decode("utf-8"), getattr(resp, "status", None))
    except urllib.error.HTTPError as e:
        # An error body is evidence too: a 4xx explaining a bad model id is exactly what the
        # smoke test exists to surface, and discarding it leaves "request failed (HTTPError)".
        try:
            _observe(e.read().decode("utf-8", "replace"), getattr(e, "code", None))
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


def classify(state, timeout):
    """Run the enabled backend. Returns (name, answers) or (None, None)."""
    name, fn = resolve()
    if fn is None:
        return None, None
    return name, fn(state, QUESTIONS, timeout)
