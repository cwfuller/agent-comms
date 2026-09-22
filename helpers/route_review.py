#!/usr/bin/env python3
"""Reviewer routing decisions for agent-comms: the abstract CANDIDATE, never a vendor model.

    route_review.py decide --root <.comms> --workspace <ws> [--by <agent>]
                           (--request <file> [--artifact <sha> --base <sha>] [--thread-override <t>]
                            | --thread <t> --phase <p>)
                           [--tier fast|balanced|strong|none] [--effort low|medium|high|xhigh|none]
                           [--replace]
    route_review.py lookup --root <.comms> --workspace <ws> --thread <t> --phase <p>
    route_review.py show   --root <.comms> <decision-id> [--thread <t>] [--phase <p>]
    route_review.py verify --root <.comms> <decision-id> --thread <t> --phase <p> [--leg-agents a,b]

A decision is made ONCE per (workspace, base thread, phase) and reused by every later round of that
phase: a sticky pointer names it, so round N resolves to the same concrete policy as round 1 and
keeps the provider's warm session. `--replace` is the only way to change it, and it mints a NEW
id — a deliberate policy change is a new decision identity, never an edit of an old one.

This module decides nothing concrete. It records an abstract tier/effort candidate (or `none`,
meaning "keep the baseline") with its provenance; acp.sh resolves that against the versioned
policy map, the operator's pins and the provider's capability, per turn, in runphase.

Policy `reviewer-v1` has NO one-step bump: a confident mechanical review may reach fast/low, a
split or tied answer goes DEEPER, and a low-confidence or malformed answer selects the baseline
once (candidate `none`), never a raised or lowered guess.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import route_backend  # noqa: E402

RECORD_VERSION = 1
POLICY = route_backend.REVIEWER_POLICY_VARIANT
TIERS = ("fast", "balanced", "strong")
EFFORTS = ("low", "medium", "high", "xhigh")
DEPTH_CONFIDENCE_MIN = 0.5
EFFORT_CONFIDENCE_MIN = 0.6
# A level is chosen only when the probability that the review needs MORE than it is at most this.
# An argmax picked the first maximum starting from the cheapest level, so a tie, a split, or a
# partial answer landed on the cheapest reviewer — the one outcome a cost router must never
# produce by accident. (trust critique, design r1.)
TAIL_MAX = 0.2
SUM_TOLERANCE = 0.05

# A decision id names a FILE, so anything but this exact shape is refused before it is joined
# to a path. uuid4 hex after a fixed prefix.
ID_RE = re.compile(r"\Ard-[0-9a-f]{32}\Z")
TOKEN_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")


def die(msg, code=1):
    sys.stderr.write("route_review: %s\n" % msg)
    raise SystemExit(code)


def decisions_dir(root):
    # The record root is the MAIN repo's gitignored .comms/, which cmd_snapshot strips before
    # `git add -A`, so no decision (and none of the request text it carries) can reach a review
    # artifact. comms.sh supplies it from cmd_root; refuse anything that is not a .comms dir.
    root = os.path.realpath(root)
    if os.path.basename(root) != ".comms" or not os.path.isdir(root):
        die("--root must be an existing .comms directory (got %r)" % root)
    return os.path.join(root, "route-decisions")


def pointer_path(ddir, workspace, thread, phase):
    key = hashlib.sha256(("%s\0%s\0%s" % (workspace, thread, phase)).encode("utf-8")).hexdigest()[:32]
    return os.path.join(ddir, "threads", key)


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.rename(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die("could not write %s (%s)" % (path, type(e).__name__))


def load_record(ddir, did):
    if not ID_RE.match(did or ""):
        die("decision id %r is not a decision id" % did)
    path = os.path.join(ddir, did + ".json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError) as e:
        die("decision %s is missing or unreadable (%s)" % (did, type(e).__name__))
    cand = rec.get("candidate") if isinstance(rec, dict) else None
    if (not isinstance(rec, dict) or rec.get("record_version") != RECORD_VERSION
            or rec.get("decision_id") != did or not isinstance(cand, dict)
            or cand.get("tier") not in TIERS + ("none",)
            or cand.get("effort") not in EFFORTS + ("none",)
            or not isinstance(rec.get("thread"), str) or not rec.get("thread")
            or not isinstance(rec.get("phase"), str) or not rec.get("phase")
            or not TOKEN_RE.match(str(rec.get("source", "")))):
        die("decision %s is malformed — refusing to route on it" % did)
    return rec


def read_pointer(ptr):
    try:
        with open(ptr, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except FileNotFoundError:
        return None
    except OSError as e:
        die("the thread's decision pointer is unreadable (%s)" % type(e).__name__)


def unit(v, what):
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise ValueError("%s is missing or not a number" % what)
    if f != f or f < 0.0 or f > 1.0:
        raise ValueError("%s is out of range" % what)
    return f


def complete_distribution(probs, keys, what):
    """Every key present, each in [0,1], summing to 1 +/- SUM_TOLERANCE — or ValueError."""
    if not isinstance(probs, dict):
        raise ValueError("%s is missing" % what)
    vals = []
    for k in keys:
        if k not in probs:
            raise ValueError("%s[%s] is missing" % (what, k))
        vals.append(unit(probs[k], "%s[%s]" % (what, k)))
    if abs(sum(vals) - 1.0) > SUM_TOLERANCE:
        raise ValueError("%s does not sum to 1" % what)
    return vals


def cheapest_covering(vals):
    """Index of the cheapest level L with P(level > L) <= TAIL_MAX. Ties and splits go deeper."""
    for i in range(len(vals)):
        if sum(vals[i + 1:]) <= TAIL_MAX:
            return i
    return len(vals) - 1


def map_answers(answers):
    """reviewer-v1: raw answers -> (tier, effort, gate, reason). Raises ValueError on a malformed
    answer. Floors and fallbacks are recorded as a GATE beside the raw answers, never blended in."""
    depth, eff = answers.get("review_depth"), answers.get("review_effort")
    if not isinstance(depth, dict) or not isinstance(eff, dict):
        raise ValueError("response is missing review_depth or review_effort")
    dvals = complete_distribution(depth.get("probabilities"), ("0", "1", "2", "3"),
                                  "review_depth.probabilities")
    dconf = unit(depth.get("confidence"), "review_depth.confidence")
    level = cheapest_covering(dvals)
    # levels 0 mechanical, 1 standard, 2 hard, 3 architectural -> fast, balanced, strong, strong
    tier = ("fast", "balanced", "strong", "strong")[level]
    choice = eff.get("choice")
    if choice not in EFFORTS:
        raise ValueError("review_effort.choice is not a known effort")
    econf = unit(eff.get("confidence"), "review_effort.confidence")
    effort = choice
    eprobs = eff.get("probabilities")
    if eprobs is not None:
        # When the distribution is supplied it must be whole, and it can only DEEPEN the choice.
        evals = complete_distribution(eprobs, EFFORTS, "review_effort.probabilities")
        effort = EFFORTS[max(EFFORTS.index(choice), cheapest_covering(evals))]
    gates = []
    if dconf < DEPTH_CONFIDENCE_MIN:
        gates.append("low-depth-confidence")
    if econf < EFFORT_CONFIDENCE_MIN:
        gates.append("low-effort-confidence")
    if gates:
        # EITHER gate keeps the WHOLE baseline. Clearing only the doubtful dimension let the other
        # route cheaper — a confident `low` effort on the baseline model, or a `fast` model at the
        # baseline effort — which is below the baseline the low-confidence guarantee promises.
        # (codex, implement r1.)
        tier, effort = "none", "none"
    gate = "+".join(gates) if gates else "classify"
    reason = ("policy=%s depth=%s conf=%.3f covering-level=%d effort-choice=%s conf=%.3f -> tier=%s effort=%s"
              % (POLICY, ",".join("%.3f" % v for v in dvals), dconf, level, choice, econf, tier, effort))
    return tier, effort, gate, reason


def classifier_disabled():
    return (os.environ.get("COMMS_ROUTE") or "").strip().lower() in ("0", "false", "no", "off")


def emit(rec):
    out = (("decision", rec["decision_id"]), ("thread", rec["thread"]), ("phase", rec["phase"]),
           ("tier", rec["candidate"]["tier"]), ("effort", rec["candidate"]["effort"]),
           ("source", rec.get("source", "")), ("gate", rec.get("gate", "")),
           ("reason", rec.get("reason", "")))
    for k, v in out:
        sys.stdout.write("%s: %s\n" % (k, " ".join(str(v).split())))


def check_pointer_target(rec, workspace, thread, phase):
    if rec.get("thread") != thread or rec.get("workspace") != workspace or rec.get("phase") != phase:
        die("the decision pointer for %s/%s names a decision for another thread or phase — refusing"
            % (thread, phase))


def classify_into(rec, text, args):
    """Fill rec's classification fields for a request. Never raises; every failure is a recorded
    source/gate with candidate none (the baseline)."""
    root = os.path.dirname(os.path.realpath(args.root))
    rec["candidate"] = {"tier": "none", "effort": "none"}
    if classifier_disabled():
        rec["source"], rec["gate"], rec["reason"] = "disabled", "disabled", "COMMS_ROUTE disables the classifier"
        return
    # PERMISSION BEFORE ANY SOCKET, and before any input is retained: request text (intent, what
    # was done, prior findings that quote code) is the same class of content the shadow collector
    # may only send from an operator-permitted project. Same identity, same allowlist.
    key, derived_root = route_backend.canonical_project()
    if not key or derived_root != root:
        rec["source"], rec["gate"] = "not-permitted", "not-permitted"
        rec["reason"] = "cannot establish that --root belongs to this repository"
        return
    rec["project_key"] = key
    if not route_backend.transmission_permitted(key):
        rec["source"], rec["gate"] = "not-permitted", "not-permitted"
        rec["reason"] = "project %s is not permitted to transmit request text (see route-shadow-allow)" % key
        return
    state, meta, unsendable = route_backend.prepare_review_input(text, root, args.artifact, args.base)
    rec["input"] = meta
    if unsendable:
        # An artifact id alone conveys identity, not content; an unmeasurable change or an empty
        # request has nothing to price a review on. Nothing is sent, and the state is not kept.
        rec["source"], rec["gate"] = "fail-open", "fail-open"
        rec["reason"] = unsendable + "; nothing was sent"
        return
    rec["sent"] = state
    rec["state_sha256"] = hashlib.sha256(json.dumps(state, sort_keys=True).encode("utf-8")).hexdigest()
    rec["classifier"] = {"model": os.environ.get("COMMS_ROUTE_MODEL") or "jev-latest",
                         "url": os.environ.get("COMMS_ROUTE_URL") or "https://api.typesafe.ai/v1/systemone"}
    try:
        timeout = float(os.environ.get("COMMS_ROUTE_TIMEOUT_SECS") or "8")
        if timeout <= 0:
            raise ValueError
    except ValueError:
        timeout = 8.0
    try:
        name, answers = route_backend.classify(state, timeout, route_backend.REVIEW_QUESTIONS)
    except route_backend.BackendError as e:
        rec["source"], rec["gate"], rec["reason"] = e.source, e.source, e.reason
        rec["raw_response"] = route_backend.LAST_RAW.get("body")
        rec["http_status"] = route_backend.LAST_RAW.get("http_status")
        return
    rec["classifier"]["backend"] = name
    if answers is None:
        rec["source"], rec["gate"] = "fail-open", "fail-open"
        rec["reason"] = "no decision backend enabled (set COMMS_ROUTE_BACKEND=typesafe or COMMS_ROUTE=1)"
        return
    # The RAW body, retained before parsing so a malformed answer is still evidence; the parsed
    # answers beside it, and the mapped candidate separately — raw, floors and fallbacks never blend.
    rec["raw_response"] = route_backend.LAST_RAW.get("body")
    rec["http_status"] = route_backend.LAST_RAW.get("http_status")
    rec["answers"] = answers
    try:
        tier, effort, gate, reason = map_answers(answers)
    except ValueError as e:
        rec["source"], rec["gate"], rec["reason"] = "fail-open", "fail-open", str(e)
        return
    rec["classified"] = {"tier": tier, "effort": effort}
    rec["source"], rec["gate"], rec["reason"] = name, gate, reason
    if name == "stub":
        # THE TEST SEAM NEVER ROUTES A LIVE TURN. /auto treats `source: stub` as fail-open for the
        # plan decision; the same rule holds here. What it WOULD have chosen stays in `classified`.
        rec["gate"] = "stub-source"
        return
    rec["candidate"] = {"tier": tier, "effort": effort}


def cmd_decide(a):
    ddir = decisions_dir(a.root)
    if a.request and a.thread:
        die("pass --request or --thread, not both", 2)
    fm, text = {}, ""
    if a.request:
        try:
            with open(a.request, "r", encoding="utf-8") as fh:
                text = fh.read()
        except OSError as e:
            die("cannot read the request (%s)" % type(e).__name__)
        fm, _ = route_backend._split_request(text)
        thread = a.thread_override or fm.get("thread", "")
        phase = a.phase or fm.get("phase", "")
    else:
        thread, phase = a.thread or "", a.phase or ""
    if not thread or not phase:
        die("a thread and a phase are required (from the request, or --thread/--phase)", 2)
    explicit = a.tier is not None or a.effort is not None
    if not a.request and not explicit:
        die("--thread alone has nothing to classify: pass --tier/--effort, or --request", 2)
    os.makedirs(os.path.join(ddir, "threads"), exist_ok=True)
    ptr = pointer_path(ddir, a.workspace, thread, phase)
    existing = read_pointer(ptr)
    if existing is not None and not a.replace:
        rec = load_record(ddir, existing)
        check_pointer_target(rec, a.workspace, thread, phase)
        if explicit:
            # An explicit request that would be silently answered with an OLDER decision is not
            # honoured; say so instead of printing a decision the operator did not ask for.
            die("thread %s phase %s already has decision %s — pass --replace to change it"
                % (thread, phase, existing))
        emit(rec)
        return
    did = "rd-" + uuid.uuid4().hex
    rec = {
        "record_version": RECORD_VERSION,
        "decision_id": did,
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "workspace": a.workspace,
        "thread": thread,
        "phase": phase,
        "role": "reviewer",
        "round": fm.get("round", ""),
        "request_message_id": fm.get("message_id", ""),
        "decided_by": a.by or "unknown",
        "policy": POLICY,
        "rubric_version": route_backend.REVIEW_RUBRIC_VERSION,
        "questions_sha256": hashlib.sha256(json.dumps(
            route_backend.REVIEW_QUESTIONS, sort_keys=True).encode("utf-8")).hexdigest(),
        "replaces": existing if a.replace else None,
    }
    if explicit:
        rec["source"], rec["gate"] = "explicit", "explicit"
        rec["candidate"] = {"tier": a.tier or "none", "effort": a.effort or "none"}
        rec["reason"] = "explicit decision by %s" % (a.by or "unknown")
    else:
        classify_into(rec, text, a)
    final = os.path.join(ddir, did + ".json")
    write_atomic(final, json.dumps(rec, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    # THE POINTER. First decision wins without --replace: link() is atomic and refuses an existing
    # name, so two concurrent first sends on one thread converge on ONE decision instead of the
    # last rename silently re-pointing a thread whose earlier leg already launched.
    tmp = "%s.new.%d" % (ptr, os.getpid())
    write_atomic(tmp, did + "\n")
    try:
        if a.replace:
            os.rename(tmp, ptr)
        else:
            try:
                os.link(tmp, ptr)
            except FileExistsError:
                winner = read_pointer(ptr)
                rec = load_record(ddir, winner)
                check_pointer_target(rec, a.workspace, thread, phase)
            finally:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
    except OSError as e:
        die("could not record the thread's decision pointer (%s)" % type(e).__name__)
    emit(rec)


def cmd_lookup(a):
    """The thread+phase's EXISTING decision, or exit 1. Never classifies and never creates: a
    reviewer turn must find the decision its send made, not quietly make a second one."""
    ddir = decisions_dir(a.root)
    did = read_pointer(pointer_path(ddir, a.workspace, a.thread, a.phase))
    if did is None:
        die("no decision is recorded for thread %r phase %r" % (a.thread, a.phase))
    rec = load_record(ddir, did)
    check_pointer_target(rec, a.workspace, a.thread, a.phase)
    emit(rec)


def cmd_verify(a):
    """The id a request CARRIES, checked against the decision IN FORCE — independent of the caller's
    cwd, branch or inferred workspace (the record names its own workspace). The request's thread
    must be the decision's thread, or — for a panel leg only — that thread plus `-<agent>` for one
    of the agents passed in --leg-agents. Nothing is guessed from a suffix: a thread merely named
    `x-grok` never borrows thread `x`'s decision."""
    ddir = decisions_dir(a.root)
    rec = load_record(ddir, a.decision)
    if rec["phase"] != a.phase:
        die("decision %s was made for phase %r, not %r" % (a.decision, rec["phase"], a.phase))
    legs = [x for x in (a.leg_agents or "").split(",") if x]
    if a.thread != rec["thread"] and a.thread not in ["%s-%s" % (rec["thread"], x) for x in legs]:
        die("decision %s was made for thread %r, not %r" % (a.decision, rec["thread"], a.thread))
    cur = read_pointer(pointer_path(ddir, rec.get("workspace", ""), rec["thread"], rec["phase"]))
    if cur != a.decision:
        die("decision %s is not the decision in force for thread %r phase %r (%s)"
            % (a.decision, rec["thread"], rec["phase"], cur or "none"))
    show_tsv(rec)


def show_tsv(rec):
    for k, v in (("decision", rec["decision_id"]), ("thread", rec["thread"]), ("phase", rec["phase"]),
                 ("tier", rec["candidate"]["tier"]), ("effort", rec["candidate"]["effort"]),
                 ("source", rec.get("source", "")), ("decided_by", rec.get("decided_by", "")),
                 ("rubric", rec.get("rubric_version", ""))):
        sys.stdout.write("%s\t%s\n" % (k, " ".join(str(v).split()) or "-"))


def cmd_show(a):
    ddir = decisions_dir(a.root)
    rec = load_record(ddir, a.decision)
    if a.thread is not None and rec["thread"] != a.thread:
        die("decision %s was made for thread %r, not %r — refusing to route on it"
            % (a.decision, rec["thread"], a.thread))
    if a.phase is not None and rec["phase"] != a.phase:
        die("decision %s was made for phase %r, not %r — refusing to route on it"
            % (a.decision, rec["phase"], a.phase))
    show_tsv(rec)


def main(argv):
    p = argparse.ArgumentParser(prog="route_review.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--root", required=True)
    d.add_argument("--workspace", required=True)
    d.add_argument("--by")
    d.add_argument("--request")
    d.add_argument("--artifact")
    d.add_argument("--base")
    d.add_argument("--thread")
    d.add_argument("--thread-override", dest="thread_override")
    d.add_argument("--phase")
    d.add_argument("--tier", choices=TIERS + ("none",))
    d.add_argument("--effort", choices=EFFORTS + ("none",))
    d.add_argument("--replace", action="store_true")
    lk = sub.add_parser("lookup")
    lk.add_argument("--root", required=True)
    lk.add_argument("--workspace", required=True)
    lk.add_argument("--thread", required=True)
    lk.add_argument("--phase", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--root", required=True)
    v.add_argument("decision")
    v.add_argument("--thread", required=True)
    v.add_argument("--phase", required=True)
    v.add_argument("--leg-agents", dest="leg_agents")
    s = sub.add_parser("show")
    s.add_argument("--root", required=True)
    s.add_argument("decision")
    s.add_argument("--thread")
    s.add_argument("--phase")
    a = p.parse_args(argv)
    {"decide": cmd_decide, "lookup": cmd_lookup, "show": cmd_show, "verify": cmd_verify}[a.cmd](a)


if __name__ == "__main__":
    main(sys.argv[1:])
