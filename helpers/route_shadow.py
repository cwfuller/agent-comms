#!/usr/bin/env python3
"""Shadow collector for the /auto query classifier.

Observes what Jev WOULD decide and records it. It can tell /auto nothing: it shares no
stdout contract with the classify path, writes no file the loop reads, and returns its
result only as a record on disk plus a decision id on stderr-free stdout in route.sh.

Everything here exists so a policy variant can be replayed OFFLINE against the SAME calls.
That is why the raw response is retained verbatim and why the effective policy inputs are
stored beside it: cache-stickiness (route.sh) depends on the current tier and the context
size, so a replay that lacked them could attribute a context difference to the policy
variant it was trying to measure. (codex, plan r1.)
"""
import hashlib
import re
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import route_backend  # noqa: E402

# Bumped whenever the recorded shape or the transmitted state changes, so a replay can refuse
# rows it does not understand rather than silently comparing incomparable records.
SHADOW_RECORD_VERSION = 1

# Git variables that can point a command at a DIFFERENT repository than the cwd.
_GIT_SELECTORS = {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_PREFIX",
}

# A decision id names a FILE. Anything but a bare token can traverse out of the record root.
_ID_OK = re.compile(r"\A[0-9a-zA-Z][0-9a-zA-Z._-]{0,127}\Z")

# route.sh truncates the task at 8000 characters BEFORE the call, so the transmitted state is
# not the same string as the task. Store what was actually sent.
TASK_LIMIT = 8000

# THE PRODUCTION QUESTION SET, never a copy. A hand-written version of this sent
# `questions` as a LIST and the live API answered HTTP 422 ("Input should be a valid
# dictionary") on the very first real call — a shadow decision measuring a payload
# production never sends is worse than no decision at all.
QUESTIONS = route_backend.QUESTIONS


def _canonical_project():
    """sha256 of the canonical MAIN repo root of the CURRENT working tree.

    Derived here, never taken from the environment: permission that trusts a caller-supplied
    identity is not permission. Mirrors route.sh's shadow_repo_key and runphase's
    mount_repo_key so one clone is one project across worktrees and mounts.
    """
    import subprocess
    env = {k: v for k, v in os.environ.items() if k not in _GIT_SELECTORS}
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


def _permitted(key):
    """The allowlist check, enforced HERE as well as in route.sh.

    This module is installed executable and has its own __main__, so a caller that runs it
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


def _die(msg):
    sys.stderr.write("route_shadow: %s\n" % msg)
    raise SystemExit(1)


def main():
    env = os.environ.get
    decision_id = env("COMMS_ROUTE_SHADOW_ID") or _die("no decision id")
    if not _ID_OK.match(decision_id):
        _die("decision id %r is not a bare token — refusing to use it as a path" % decision_id)
    task = env("COMMS_ROUTE_TASK") or ""
    if not task.strip():
        _die("empty task")
    sent = task[:TASK_LIMIT]

    rec = {
        "record_version": SHADOW_RECORD_VERSION,
        # UTC-Z, matching events.tsv and grades/rounds.tsv. The classify path's own writer
        # stamps local time with no offset, which would make even a temporal join wrong.
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "decision_id": decision_id,
        "project_key": env("COMMS_ROUTE_SHADOW_KEY") or "",
        # Allocated BEFORE any loop exists, so this is the join key. `unknown` is honest and
        # is never backfilled from a later similar task.
        "thread": env("COMMS_ROUTE_SHADOW_THREAD") or "unknown",
        "workspace": env("COMMS_ROUTE_SHADOW_WORKSPACE") or "",
        "sent_sha256": hashlib.sha256(sent.encode("utf-8")).hexdigest(),
        "sent_chars": len(sent),
        "task_chars": len(task),
        "truncated": len(task) > TASK_LIMIT,
        # The EFFECTIVE POLICY INPUTS, without which a replay cannot reproduce `tier`.
        "policy_inputs": {
            "current_tier": env("COMMS_ROUTE_SHADOW_CURRENT_TIER") or "",
            "context_tokens": env("COMMS_ROUTE_SHADOW_CONTEXT_TOKENS") or "",
        },
        "model": env("COMMS_ROUTE_MODEL") or "jev-latest",
        "url": env("COMMS_ROUTE_URL") or "https://api.typesafe.ai/v1/systemone",
    }
    # The transmitted text itself. This is the content the permission gate governs; it is
    # written only because the project was explicitly permitted before the call was made.
    rec["sent"] = sent

    # BEFORE the backend is resolved and long before any socket. The key is DERIVED from the
    # current tree; a supplied one that disagrees is a caller trying to borrow another
    # project's permit, and is refused rather than honoured.
    derived, derived_root = _canonical_project()
    supplied = rec["project_key"]
    if not derived:
        _die("cannot derive the project identity (not a git worktree?) — refusing")
    if supplied and supplied != derived:
        _die("supplied project key does not identify this repository — refusing")
    rec["project_key"] = derived
    if not _permitted(derived):
        _die("project %s is not permitted to transmit task text" % derived)
    # The destination follows from the derived root. Nothing a caller says can move it.
    out_dir = os.path.join(derived_root, ".comms", "route-shadow")
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as e:
        _die("cannot create %s (%s)" % (out_dir, type(e).__name__))

    state = route_backend.build_state(sent)
    rec["questions_sha256"] = hashlib.sha256(
        json.dumps(QUESTIONS, sort_keys=True).encode("utf-8")).hexdigest()
    # The COMPLETE outbound payload, so a replay can prove it matched production.
    rec["state_sha256"] = hashlib.sha256(
        json.dumps(state, sort_keys=True).encode("utf-8")).hexdigest()
    name, fn = route_backend.resolve()
    if not fn:
        _die("no backend resolved (the collector sets COMMS_ROUTE_BACKEND for its own call only)")
    rec["backend"] = name

    timeout = env("COMMS_ROUTE_TIMEOUT_SECS") or "8"
    try:
        timeout = float(timeout)
    except ValueError:
        timeout = 8.0

    try:
        answers = fn(state, QUESTIONS, timeout)
        rec["status"] = "success"
        rec["answers"] = answers
    except route_backend.BackendError as e:
        # "no response received" and "a response arrived but was unusable" are different
        # observations and must not collapse into one status.
        rec["status"] = "error" if not route_backend.LAST_RAW["received"] else "unusable"
        rec["error"] = str(e)
    except Exception as e:  # noqa: BLE001 - an unexpected failure is still an observation
        rec["status"] = "error"
        rec["error"] = "%s: %s" % (type(e).__name__, e)

    # The RAW BODY, captured before parsing could throw. Never the Authorization header.
    rec["raw_response"] = route_backend.LAST_RAW["body"]
    # Lossless: `replace` collapses distinct invalid bytes, so 0xff and 0xfe would store the
    # same text and a replay could not tell them apart. (codex advisory, implement r4.)
    rec["raw_response_b64"] = route_backend.LAST_RAW["body_b64"]
    rec["raw_decodable"] = route_backend.LAST_RAW["decodable"]
    rec["http_status"] = route_backend.LAST_RAW["http_status"]
    rec["response_received"] = route_backend.LAST_RAW["received"]

    # ONE FILE PER DECISION, written by rename. The raw body plus the task is far past the
    # single-write budget that makes an append atomic, so two worktrees appending one JSONL
    # would tear lines — and a torn raw_response cannot be replayed. (grok, plan r1.)
    final = os.path.join(out_dir, "%s.json" % decision_id)
    tmp = final + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.rename(tmp, final)
    except OSError as e:
        # LOUD. A decision we paid for and could not record is a failure, not a success.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        _die("could not write %s (%s)" % (final, type(e).__name__))
    sys.stderr.write("route_shadow: recorded %s status=%s\n" % (final, rec["status"]))


if __name__ == "__main__":
    main()
