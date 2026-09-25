#!/usr/bin/env python3
"""route-eval — a small, operator-labelled eval set for the Jev routing classifiers.

  comms.sh route-eval pool  [--project DIR ...]   build/extend the pool from saved decisions
  comms.sh route-eval label [--stdin] [--relabel] [--no-reveal]   blind labelling, one item at a time
  comms.sh route-eval run --live [--missing] [--limit N]           re-ask Jev (paid calls)
  comms.sh route-eval score [--source stored|live] [--policy P,...] [--param role.key=value ...] [--json]
  comms.sh route-eval status

THE POOL HOLDS CLIENT TASK TEXT, so it and the labels live OUTSIDE any repository, under
${AGENT_COMMS_HOME:-~/.agent-comms}/evals/jev/ (directory 0700, files 0600). Only the hand-written
seed tasks (route_eval_seed.json) ship with the tool.

Items come from records the helpers already keep: implementer decisions
(.comms/route-decisions/implementer/*.json) and reviewer decisions (.comms/route-decisions/rd-*.json).
Only answered, non-probe, non-stub (the stub is the test seam) records are pooled; an item's id is a hash of the exact state that was sent,
so re-pooling is idempotent and a duplicate classification is one item.

LABELLING IS BLIND: an item is shown without Jev's answer or the loop's outcome; those are revealed
only after the label is saved (--no-reveal suppresses even that).

SCORING IS OFFLINE by default: stored raw answers are re-mapped by the SAME policy functions
production runs (route_policy.map_implementer, route_review.map_answers) under named candidate
parameters, so a policy change can be judged against the labels without a single API call.
`run --live` is the only path that contacts a backend, and refuses without the flag.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import route_backend  # noqa: E402
import route_policy  # noqa: E402
import route_review  # noqa: E402

LEVELS = route_policy.LEVELS
EFFORTS = route_policy.EFFORTS
LEVEL_KEYS = {"m": "mechanical", "s": "standard", "h": "hard", "a": "architectural"}
EFFORT_KEYS = {"l": "low", "m": "medium", "h": "high", "x": "xhigh"}
# The fields that belong to ONE observation of an item and are only ever replaced together.
OBSERVATION_FIELDS = ("answers", "inputs", "stored", "record", "thread", "outcome", "project", "project_key", "at")
_COUNT_RE = re.compile(r"[0-9]{1,15}")   # ASCII digits only (str.isdigit accepts "²"), bounded length
# Decision sources (and gates) that are not a classification the policy produced.
NOT_A_DECISION = {"stub", "fail-open", "probe", "disabled", "not-permitted"}
BANDS = ((0.0, 0.4), (0.4, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 1.01))

# Named candidate policies. Each maps role -> parameter overrides for the production functions.
POLICIES = {
    "current": {},
    "gate-0.5": {"implementer": {"effort_conf_min": 0.5}, "reviewer": {"effort_conf_min": 0.5}},
    "cover-0.35": {"reviewer": {"tail_max": 0.35}},
    "no-bump": {"implementer": {"bump": False}},
}


def die(msg, code=2):
    sys.stderr.write("route-eval: %s\n" % msg)
    sys.exit(code)


# ---- storage ---------------------------------------------------------------------------------
def _repo_problem(path):
    """Why `path` may not hold eval data, or None. Fails CLOSED: only git's own "not a git
    repository" answer counts as outside. A work tree, a git directory, a bare repository, a `.git`
    path component, or an inspection git could not complete (dubious ownership, git missing) are
    all refusals. (codex, implement r2.)"""
    if ".git" in path.split(os.sep):
        return "it is inside a .git directory"
    # Walk every ancestor on disk. A `.git` entry (directory, or a file pointing elsewhere, valid or
    # broken) or a bare repository's HEAD+objects+refs at ANY level means repository territory,
    # whatever git later says about the nearest one. (codex, implement r3: a broken nested .git
    # makes git print "not a git repository" from inside an enclosing work tree.)
    a = path
    while True:
        if os.path.lexists(os.path.join(a, ".git")):
            return "it is inside a repository (%s)" % a
        if os.path.isfile(os.path.join(a, "HEAD")) and os.path.isdir(os.path.join(a, "objects")) \
                and os.path.isdir(os.path.join(a, "refs")):
            return "it is inside a bare repository (%s)" % a
        parent = os.path.dirname(a)
        if parent == a:
            break
        a = parent
    probe = path
    while not os.path.isdir(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    env = {k: v for k, v in os.environ.items() if k not in route_backend.GIT_SELECTORS}
    env["LC_ALL"] = "C"   # git's own wording is the one signal matched below
    try:
        out = subprocess.run(["git", "-C", probe, "rev-parse", "--is-inside-work-tree",
                              "--is-inside-git-dir", "--is-bare-repository"],
                             capture_output=True, text=True, env=env)
    except OSError as e:
        return "git could not inspect it (%s)" % e
    if out.returncode != 0:
        if "not a git repository" in out.stderr:
            return None
        return "git could not inspect it (%s)" % (out.stderr.strip().splitlines() or ["exit %d" % out.returncode])[0]
    if "true" in out.stdout.split():
        return "it is inside a git repository"
    return None


def eval_dir():
    """The private store. It holds client task text, so it must never resolve into a repository
    (a commit or a review snapshot would carry it): symlinks are resolved and the result refused
    if it lands in any git work tree. (codex, implement r1.)"""
    home = os.environ.get("AGENT_COMMS_HOME") or os.path.join(os.path.expanduser("~"), ".agent-comms")
    d = os.path.realpath(os.path.join(home, "evals", "jev"))
    why = _repo_problem(d)
    if why:
        die("refusing to store eval data at %s: %s (set AGENT_COMMS_HOME elsewhere)" % (d, why))
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def write_private(path, text):
    """Atomic, 0600 from creation (mkstemp), never world-readable in between."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_pool():
    p = os.path.join(eval_dir(), "pool.jsonl")
    items = []
    if os.path.exists(p):
        with open(p, encoding="utf-8") as fh:
            items = [json.loads(line) for line in fh if line.strip()]
    return items


def save_pool(items):
    write_private(os.path.join(eval_dir(), "pool.jsonl"),
                  "".join(json.dumps(i, ensure_ascii=False, sort_keys=True) + "\n" for i in items))


def load_labels():
    p = os.path.join(eval_dir(), "labels.json")
    if not os.path.exists(p):
        return {}
    with open(p, encoding="utf-8") as fh:
        return {lab["id"]: lab for lab in json.load(fh).get("labels", [])}


def save_labels(labels):
    write_private(os.path.join(eval_dir(), "labels.json"),
                  json.dumps({"labels": list(labels.values())}, indent=1, ensure_ascii=False) + "\n")


def load_live():
    """Latest live answers per item id."""
    p = os.path.join(eval_dir(), "live.jsonl")
    out = {}
    if os.path.exists(p):
        with open(p, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    rec = json.loads(line)
                    out[rec["id"]] = rec
    return out


# ---- pool --------------------------------------------------------------------------------------
def main_root(path):
    env = {k: v for k, v in os.environ.items() if k not in route_backend.GIT_SELECTORS}
    out = subprocess.run(["git", "-C", path, "worktree", "list", "--porcelain"],
                         capture_output=True, text=True, env=env)
    if out.returncode != 0 or not out.stdout.startswith("worktree "):
        return None
    return os.path.realpath(out.stdout.splitlines()[0][len("worktree "):])


def item_id(role, state):
    return role[0] + "-" + hashlib.sha256(json.dumps(state, sort_keys=True, default=str).encode()).hexdigest()[:16]


def blockers_in(text):
    m = re.search(r"^### Blocking\s*\n(.*?)(?=^### |\Z)", text, re.M | re.S)
    return len([l for l in m.group(1).splitlines() if re.match(r"\s*- ", l)]) if m else 0


def outcome_index(comms):
    """thread -> {rounds, blockers, verdicts}, and route_id -> thread, from the project's mailbox."""
    threads, route_ids, leg_base = {}, {}, {}
    try:
        inboxes = ["archive"] + sorted(n for n in os.listdir(comms) if n.startswith("to-"))
    except OSError:
        inboxes = []
    for sub in inboxes:
        d = os.path.join(comms, sub)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if not n.endswith(".md"):
                continue
            try:
                with open(os.path.join(d, n), encoding="utf-8", errors="replace") as fh:
                    text = fh.read(200000)
            except OSError:
                continue
            fm = text.split("\n---", 1)[0]
            t = re.search(r"^thread: *(\S+)", fm, re.M)
            if not t:
                continue
            thread = t.group(1)
            rid = re.search(r"^route_id: *(\S+)", fm, re.M)
            if rid:
                route_ids.setdefault(rid.group(1), thread)
            v = re.search(r"^verdict: *(\S+)", fm, re.M)
            if "reply" not in n or not v:
                continue
            # A panel leg's thread is <base>-<reviewer>; strip exactly the replying agent's name,
            # never a pattern, so a base that itself ends in an agent name survives. (grok, r1.)
            frm = re.search(r"^from: *(\S+)", fm, re.M)
            base = thread
            if frm and thread.endswith("-" + frm.group(1)):
                base = thread[: -len(frm.group(1)) - 1]
                leg_base[thread] = base
            rd = re.search(r"^round: *(\d+)", fm, re.M)
            o = threads.setdefault(base, {"rounds": 0, "blockers": 0, "verdicts": []})
            o["rounds"] = max(o["rounds"], int(rd.group(1)) if rd else 0)
            o["blockers"] += blockers_in(text)
            o["verdicts"].append(v.group(1))
    return threads, route_ids, leg_base


def outcome_for(index, thread):
    """The loop outcome for a decision's thread, recorded under its base thread; a panel leg's
    thread maps to its base only through a reply that proved it (<base>-<the replying agent>)."""
    threads, _route_ids, leg_base = index
    if not thread:
        return None
    return threads.get(leg_base.get(thread, thread))


def reviewer_text(sent):
    req = sent.get("request") if isinstance(sent.get("request"), dict) else {}
    parts = ["## %s\n%s" % (k, v) for k, v in req.items() if isinstance(v, str)]
    sig = sent.get("risk_signals")
    if sig:
        parts.append("## risk signals\n" + json.dumps(sig, sort_keys=True))
    return "\n\n".join(parts)


def cmd_pool(args):
    projects = []
    i = 0
    while i < len(args):
        if args[i] == "--project" and i + 1 < len(args):
            projects.append(args[i + 1]); i += 2
        else:
            die("pool: unknown argument '%s'" % args[i])
    if not projects:
        projects = [os.getcwd()]
    pool = load_pool()
    have = {it["id"] for it in pool}
    added = {"implementer": 0, "reviewer": 0, "seed": 0}
    for proj in projects:
        root = main_root(proj)
        if not root:
            die("pool: %s is not inside a git repository" % proj)
        comms = os.path.join(root, ".comms")
        rdir = os.path.join(comms, "route-decisions")
        index = outcome_index(comms)
        route_ids = index[1]
        project_key = hashlib.sha256(root.encode()).hexdigest()
        cands = []
        for path in sorted(_glob(os.path.join(rdir, "implementer"), ".json")):
            rec = _read_json(path)
            dec = rec.get("decision") if rec else None
            # Only decisions the policy actually produced: a fail-open keeps the answers it could not
            # map (and a stub is the test seam), so the SOURCE decides, not the answers' presence.
            if not rec or rec.get("probe") or not rec.get("sent") or not isinstance(rec.get("answers"), dict) \
                    or not isinstance(rec.get("state"), dict) or not isinstance(dec, dict) \
                    or dec.get("source") in NOT_A_DECISION:
                continue
            thread = route_ids.get(rec.get("route_id", ""), "")
            inputs = replay_inputs(rec)
            if inputs is None:   # inputs production could not have run with: not a replayable item
                continue
            cands.append({"role": "implementer", "state": rec["state"], "answers": rec["answers"],
                          "text": rec["state"].get("task", ""), "at": rec.get("at", ""),
                          "stored": dec, "inputs": inputs, "record": path, "thread": thread,
                          "outcome": outcome_for(index, thread), "project_key": project_key})
        for path in sorted(_glob(rdir, ".json")):
            rec = _read_json(path)
            if not rec or not isinstance(rec.get("answers"), dict) or not isinstance(rec.get("sent"), dict) \
                    or rec.get("source") in NOT_A_DECISION or rec.get("gate") in NOT_A_DECISION:
                continue
            cands.append({"role": "reviewer", "state": rec["sent"], "answers": rec["answers"],
                          "text": reviewer_text(rec["sent"]), "at": rec.get("at", ""),
                          "stored": {"tier": rec.get("candidate", {}).get("tier"),
                                     "effort": rec.get("candidate", {}).get("effort"),
                                     "gate": rec.get("gate"), "reason": rec.get("reason")},
                          "record": path, "thread": rec.get("thread", ""),
                          "outcome": outcome_for(index, rec.get("thread", "")),
                          # The project it was READ from, never a key the file itself claims:
                          # live sends are authorised by this. (grok, implement r2.)
                          "project_key": project_key})
        for c in cands:
            if mapping_problem(c, c["answers"]):   # production must turn it into a known decision
                continue
            c["id"] = item_id(c["role"], c["state"])
            c["project"] = os.path.basename(root)
            if c["id"] in have:
                # Same sent state seen again. The item keeps ONE observation as a unit — answers,
                # replay inputs, stored decision, provenance and outcome all from the same record —
                # and that is the newest one; mixing fields across records produced a replay that
                # matched neither. (codex, implement r3.)
                for old in pool:
                    if old["id"] != c["id"]:
                        continue
                    # A real decision replaces a seed row of the same task outright: the row stops
                    # being a seed, so it is scored on real answers and live-sent only under its
                    # project's permit. (grok, implement r4.)
                    if old.get("seed") or c.get("at", "") >= old.get("at", ""):
                        for k in OBSERVATION_FIELDS:
                            old[k] = c.get(k)
                        old.pop("seed", None)
                        old.pop("note", None)
                continue
            have.add(c["id"])
            pool.append(c)
            added[c["role"]] += 1
    seed_path = os.path.join(HERE, "route_eval_seed.json")
    if os.path.exists(seed_path):
        for s in _read_json(seed_path).get("tasks", []):
            state = route_backend.build_state(s["text"])
            sid = item_id("implementer", state)
            if sid in have:
                continue
            have.add(sid)
            pool.append({"id": sid, "role": "implementer", "state": state, "answers": None, "text": s["text"],
                         "project": "seed", "seed": True, "note": s.get("note", ""), "at": "",
                         "stored": {}, "record": "", "thread": "", "outcome": None, "project_key": ""})
            added["seed"] += 1
    save_pool(pool)
    print("pool: %d items (+%d implementer, +%d reviewer, +%d seed) -> %s"
          % (len(pool), added["implementer"], added["reviewer"], added["seed"],
             os.path.join(eval_dir(), "pool.jsonl")))


def replay_inputs(rec):
    """The recorded production inputs of an implementer decision, or None when any is malformed.
    Never coerced: a replay with a guessed input reproduces a decision production never made."""
    tier = rec.get("current_tier") or ""
    raw = rec.get("context_tokens")
    ov = rec.get("overrides")
    if ov is None:
        ov = {}
    if not isinstance(tier, str) or tier not in ("", "fast", "balanced", "strong"):
        return None
    if raw in (None, ""):
        ctx = 0
    elif isinstance(raw, int) and not isinstance(raw, bool) and raw >= 0:
        ctx = raw
    elif isinstance(raw, str) and _COUNT_RE.fullmatch(raw):
        ctx = int(raw)
    else:
        return None
    allowed = {"plan": ("yes", "no"), "effort": EFFORTS, "tier": route_policy.TIERS}
    if not isinstance(ov, dict) or any(k not in allowed or not isinstance(v, str) or v not in allowed[k]
                                       for k, v in ov.items()):
        return None
    return {"current_tier": tier, "context_tokens": ctx, "overrides": ov}


def _glob(d, suffix):
    try:
        return [os.path.join(d, n) for n in os.listdir(d) if n.endswith(suffix) and not n.startswith(".")]
    except OSError:
        return []


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            v = json.load(fh)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


# ---- label -------------------------------------------------------------------------------------
class Prompter:
    def __init__(self, use_stdin):
        if use_stdin:
            self.inp, self.out = sys.stdin, sys.stdout
        else:
            try:
                self.inp = open("/dev/tty", "r")
                self.out = open("/dev/tty", "w")
            except OSError:
                die("label: needs a terminal (or --stdin for scripted answers)")

    def say(self, text):
        self.out.write(text + "\n"); self.out.flush()

    def ask(self, prompt, keys):
        while True:
            self.out.write(prompt + " "); self.out.flush()
            line = self.inp.readline()
            if not line:
                return "q"
            a = line.strip().lower()
            if a in keys or a in ("-", "q"):
                return a
            self.say("  one of: %s, - (skip), q (quit)" % "/".join(keys))


def jev_view(item):
    a = item.get("answers") or {}
    if item["role"] == "implementer":
        c, e, n = a.get("complexity", {}), a.get("effort", {}), a.get("needs_plan", {})
        return "jev: needs_plan=%s complexity=%s conf=%s effort=%s conf=%s" % (
            n.get("noul"), c.get("probabilities"), c.get("confidence"), e.get("choice"), e.get("confidence"))
    d, e = a.get("review_depth", {}), a.get("review_effort", {})
    return "jev: depth=%s conf=%s effort=%s conf=%s" % (
        d.get("probabilities"), d.get("confidence"), e.get("choice"), e.get("confidence"))


def cmd_label(args):
    use_stdin = "--stdin" in args
    relabel = "--relabel" in args
    reveal = "--no-reveal" not in args
    for a in args:
        if a not in ("--stdin", "--relabel", "--no-reveal"):
            die("label: unknown argument '%s'" % a)
    pool, labels = load_pool(), load_labels()
    todo = [it for it in pool if relabel or it["id"] not in labels]
    if not todo:
        print("label: nothing to label (%d items, %d labelled)" % (len(pool), len(labels)))
        return
    pr = Prompter(use_stdin)
    pr.say("Label what YOU would expect. Jev's answer and the outcome are shown only after you answer."
           " '-' skips an item, 'q' saves and quits.")
    for n, it in enumerate(todo, 1):
        text = it.get("text") or ""
        if len(text) > 2500:
            text = text[:2500] + "\n[... %d more chars]" % (len(it["text"]) - 2500)
        pr.say("\n[%d/%d] %s  %s  %s" % (n, len(todo), it["role"], it.get("project", ""), it["id"]))
        pr.say(text)
        lab = {"id": it["id"], "role": it["role"], "labeler": "operator",
               "labeledAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        if it["role"] == "implementer":
            a = pr.ask("  plan first? [y/n]", ("y", "n"))
            if a in ("-", "q"):
                if a == "q":
                    break
                continue
            lab["plan"] = "yes" if a == "y" else "no"
            fields = (("complexity", "  complexity [m/s/h/a]", LEVEL_KEYS),
                      ("effort", "  implementer effort [l/m/h/x]", EFFORT_KEYS))
        else:
            fields = (("depth", "  review depth [m/s/h/a]", LEVEL_KEYS),
                      ("effort", "  review effort [l/m/h/x]", EFFORT_KEYS))
        stop = False
        for key, prompt, table in fields:
            a = pr.ask(prompt, tuple(table))
            if a in ("-", "q"):
                stop = a == "q"
                lab = None
                break
            lab[key] = table[a]
        if lab is None:
            if stop:
                break
            continue
        labels[it["id"]] = lab
        save_labels(labels)
        if reveal:
            pr.say("  " + jev_view(it) if it.get("answers") else "  jev: (no stored answer; run --live)")
            if it.get("outcome"):
                o = it["outcome"]
                pr.say("  outcome: %d round(s), %d blocking finding(s), verdicts %s"
                       % (o["rounds"], o["blockers"], ",".join(o["verdicts"])))
    pr.say("\nlabels: %d saved -> %s" % (len(labels), os.path.join(eval_dir(), "labels.json")))


# ---- live --------------------------------------------------------------------------------------
def cmd_run(args):
    if "--live" not in args:
        die("run: refusing without --live (every item is a real, possibly billed, classification)")
    missing = "--missing" in args
    limit = None
    if "--limit" in args:
        try:
            limit = int(args[args.index("--limit") + 1])
        except (IndexError, ValueError):
            die("run: --limit needs a number")
    name, fn = route_backend.resolve()
    if fn is None:
        die("run: no decision backend enabled (set COMMS_ROUTE_BACKEND=typesafe)")
    live = load_live()
    try:
        timeout = int(os.environ.get("COMMS_ROUTE_TIMEOUT_SECS", "20"))
    except ValueError:
        timeout = 20
    done = skipped = failed = 0
    path = os.path.join(eval_dir(), "live.jsonl")
    for it in load_pool():
        if limit is not None and done >= limit:
            break
        if missing and it["id"] in live:
            continue
        # A client project's text is re-sent only while that project is still permitted, checked
        # IMMEDIATELY before each call so a revocation mid-batch stops the next send. (codex, r1.)
        if not it.get("seed") and not route_backend.transmission_permitted(it.get("project_key", "")):
            skipped += 1
            continue
        questions = route_backend.REVIEW_QUESTIONS if it["role"] == "reviewer" else None
        try:
            bname, answers = route_backend.classify(it["state"], timeout, questions)
        except route_backend.BackendError as e:
            failed += 1
            sys.stderr.write("route-eval: %s: %s\n" % (it["id"], e.reason))
            continue
        rec = {"id": it["id"], "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "backend": bname, "answers": answers}
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        done += 1
    print("run: %d answered, %d skipped (not permitted), %d failed -> %s" % (done, skipped, failed, path))


# ---- score -------------------------------------------------------------------------------------
def argmax_level(probs):
    best, bi = -1.0, 0
    for i in range(4):
        v = float((probs or {}).get(str(i), 0) or 0)
        if v > best:
            best, bi = v, i
    return bi


def band(conf):
    for lo, hi in BANDS:
        if lo <= conf < hi:
            return "%.1f-%.1f" % (lo, min(hi, 1.0))
    return "?"


# Parameter grammar, per key: a probability, a flag, a count, or a set of complexity levels.
_PROB_KEYS = {"plan_noul_min", "complexity_conf_min", "effort_conf_min", "depth_conf_min", "tail_max",
              "effort_tail_max"}


def parse_param(key, raw):
    if key in _PROB_KEYS:
        try:
            v = float(raw)
        except (ValueError, OverflowError):
            v = float("nan")
        if not (0.0 <= v <= 1.0):
            die("score: %s must be a number between 0 and 1" % key)
        return v
    if key == "bump":
        if raw.lower() not in ("true", "false"):
            die("score: bump must be true or false")
        return raw.lower() == "true"
    if key == "downgrade_max_context":
        if not _COUNT_RE.fullmatch(raw):
            die("score: downgrade_max_context must be a non-negative integer")
        return int(raw)
    if key == "plan_levels":
        levels = tuple(x for x in raw.split(",") if x)
        if not levels or any(x not in ("0", "1", "2", "3") for x in levels):
            die("score: plan_levels is a comma list of complexity levels 0-3, e.g. 2,3")
        return levels
    die("score: parameter '%s' has no grammar" % key)


def row_problem(item, lab, answers):
    """Why a labelled row cannot be scored, or None. The production mapping is the validator."""
    want = {"implementer": {"plan": ("yes", "no"), "complexity": LEVELS, "effort": EFFORTS},
            "reviewer": {"depth": LEVELS, "effort": EFFORTS}}.get(item.get("role"))
    if want is None:
        return "unknown role"
    for k, allowed in want.items():
        if lab.get(k) not in allowed:
            return "label %s=%r is not one of %s" % (k, lab.get(k), "/".join(allowed))
    if not isinstance(answers, dict):
        return "answers are not an object"
    return mapping_problem(item, answers)


def mapping_problem(item, answers, params=None):
    """None when the production mapping turns these answers (and the item's recorded inputs) into
    a decision made only of known values; otherwise why not. Never raises."""
    try:
        tier, effort, plan = apply_policy(item, answers, params or {})
        known = (isinstance(tier, str) and tier in route_policy.RANK
                 and isinstance(effort, str) and effort in EFFORTS and plan in (None, "yes", "no"))
    except Exception as e:   # malformed answers or inputs, overflowing numbers, unhashable values
        return "unusable answer: %s: %s" % (type(e).__name__, e)
    if not known:
        return "unusable decision: tier=%r effort=%r plan=%r" % (tier, effort, plan)
    return None


def policy_params(names, custom):
    out = []
    for n in names:
        if n not in POLICIES:
            die("score: unknown policy '%s' (known: %s)" % (n, ", ".join(POLICIES)))
        out.append((n, POLICIES[n]))
    if custom:
        out.append(("custom", custom))
    return out


def apply_policy(item, answers, params):
    """-> (tier, effort, plan|None) under the production function with these parameters."""
    if item["role"] == "implementer":
        inp = item.get("inputs") or {}
        ctx = inp.get("context_tokens", 0)
        if not isinstance(ctx, int) or isinstance(ctx, bool) or ctx < 0:
            # A stored pool row with a bad context is unusable, never replayed as zero context.
            raise ValueError("recorded context_tokens %r is not a non-negative integer" % (ctx,))
        d = route_policy.map_implementer(answers, policy_variant="eval", backend_name="eval",
                                         overrides=inp.get("overrides") or {},
                                         current_tier=inp.get("current_tier") or "",
                                         context_tokens=ctx,
                                         params=params.get("implementer"))
        return d["tier"], d["effort"], d["plan"]
    tier, effort, _gate, _reason = route_review.map_answers(answers, params.get("reviewer"))
    if tier == "none":
        tier, effort = "strong", "xhigh"   # a gated decision runs the full baseline
    return tier, effort, None


def cmd_score(args):
    source, names, custom, as_json = "stored", ["current"], {}, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--source" and i + 1 < len(args):
            source = args[i + 1]; i += 2
        elif a == "--policy" and i + 1 < len(args):
            names = [x for x in args[i + 1].split(",") if x]; i += 2
        elif a == "--param" and i + 1 < len(args):
            m = re.fullmatch(r"(implementer|reviewer)\.([a-z_]+)=(.+)", args[i + 1])
            if not m:
                die("score: --param wants role.key=value")
            role, key, val = m.groups()
            base = route_policy.IMPLEMENTER_DEFAULTS if role == "implementer" else route_review.REVIEWER_DEFAULTS
            if key not in base:
                die("score: unknown %s parameter '%s' (known: %s)" % (role, key, ", ".join(sorted(base))))
            custom.setdefault(role, {})[key] = parse_param(key, val)
            i += 2
        elif a == "--json":
            as_json = True; i += 1
        else:
            die("score: unknown argument '%s'" % a)
    if source not in ("stored", "live"):
        die("score: --source is stored or live")
    pool, labels = load_pool(), load_labels()
    live = load_live() if source == "live" else {}
    rows, unusable = [], []
    for it in pool:
        lab = labels.get(it["id"])
        if not lab:
            continue
        answers = (live.get(it["id"]) or {}).get("answers") if source == "live" else it.get("answers")
        if answers is None:
            continue
        why = row_problem(it, lab, answers)
        if why:
            unusable.append({"id": it["id"], "why": why})   # reported, never a traceback
            continue
        rows.append((it, lab, answers))
    report = {"source": source, "labelled": len(labels), "scored": len(rows), "unusable": unusable,
              "roles": {}, "policies": {}}
    for role, lvl_key, depth_key, eff_key in (("implementer", "complexity", "complexity", "effort"),
                                               ("reviewer", "depth", "review_depth", "review_effort")):
        rr = [(it, lab, a) for it, lab, a in rows if it["role"] == role]
        if not rr:
            continue
        acc = {"level_exact": 0, "level_within1": 0, "effort_exact": 0, "effort_within1": 0, "n": len(rr),
               "level_confusion": {}, "effort_confusion": {}, "level_by_conf": {}, "effort_by_conf": {}}
        for it, lab, a in rr:
            d, e = a.get(depth_key) or {}, a.get(eff_key) or {}
            jl = argmax_level(d.get("probabilities"))
            ll = LEVELS.index(lab[lvl_key])
            je = e.get("choice") if e.get("choice") in EFFORTS else "medium"
            le = lab["effort"]
            hit_l, hit_e = jl == ll, je == le
            acc["level_exact"] += hit_l
            acc["level_within1"] += abs(jl - ll) <= 1
            acc["effort_exact"] += hit_e
            acc["effort_within1"] += abs(EFFORTS.index(je) - EFFORTS.index(le)) <= 1
            key = "%s>%s" % (lab[lvl_key], LEVELS[jl])
            acc["level_confusion"][key] = acc["level_confusion"].get(key, 0) + 1
            key = "%s>%s" % (le, je)
            acc["effort_confusion"][key] = acc["effort_confusion"].get(key, 0) + 1
            for conf, hit, bucket in ((d.get("confidence"), hit_l, "level_by_conf"),
                                      (e.get("confidence"), hit_e, "effort_by_conf")):
                try:
                    b = band(float(conf))
                except (TypeError, ValueError):
                    continue
                s = acc[bucket].setdefault(b, [0, 0])
                s[0] += hit
                s[1] += 1
            if role == "implementer":
                acc.setdefault("plan_hit", 0)
                acc["plan_hit"] += (float((a.get("needs_plan") or {}).get("noul", 0) or 0) >= 0.7) == (lab["plan"] == "yes")
        report["roles"][role] = acc
    for pname, params in policy_params(names, custom):
        out = {}
        for role in ("implementer", "reviewer"):
            rr = [(it, lab, a) for it, lab, a in rows if it["role"] == role]
            if not rr:
                continue
            o = {"n": len(rr), "under": 0, "match": 0, "over": 0, "errors": 0, "plan_hit": 0}
            for it, lab, a in rr:
                if mapping_problem(it, a, params):
                    o["errors"] += 1
                    continue
                tier, effort, plan = apply_policy(it, a, params)
                lvl = lab["complexity" if role == "implementer" else "depth"]
                want_tier = route_policy.TIER_OF[lvl]
                cost = (route_policy.RANK[tier], EFFORTS.index(effort))
                want = (route_policy.RANK[want_tier], EFFORTS.index(lab["effort"]))
                o["under" if cost < want else "over" if cost > want else "match"] += 1
                if plan is not None:
                    o["plan_hit"] += plan == lab["plan"]
            out[role] = o
        report["policies"][pname] = out
    if as_json:
        print(json.dumps(report, indent=1, sort_keys=True))
        return
    print("route-eval score — source=%s, %d labelled, %d scored, %d unusable"
          % (source, len(labels), len(rows), len(unusable)))
    for u in unusable:
        print("  unusable %s: %s" % (u["id"], u["why"]))
    for role, acc in report["roles"].items():
        n = acc["n"]
        name = "complexity" if role == "implementer" else "depth"
        print("\n%s (n=%d)" % (role, n))
        print("  %s: exact %d/%d, within one level %d/%d" % (name, acc["level_exact"], n, acc["level_within1"], n))
        print("  effort: exact %d/%d, within one step %d/%d" % (acc["effort_exact"], n, acc["effort_within1"], n))
        if "plan_hit" in acc:
            print("  plan (needs_plan >= 0.7 vs label): %d/%d" % (acc["plan_hit"], n))
        for bucket, label in (("level_by_conf", name), ("effort_by_conf", "effort")):
            cells = ", ".join("%s: %d/%d" % (b, v[0], v[1]) for b, v in sorted(acc[bucket].items()))
            print("  %s accuracy by confidence: %s" % (label, cells or "-"))
        print("  %s confusion (label>jev): %s" % (name, ", ".join(
            "%s %d" % (k, v) for k, v in sorted(acc["level_confusion"].items()))))
        print("  effort confusion (label>jev): %s" % ", ".join(
            "%s %d" % (k, v) for k, v in sorted(acc["effort_confusion"].items())))
    print("\npolicy outcome vs your label (under = cheaper than you'd run it, over = deeper)")
    for pname, out in report["policies"].items():
        for role, o in out.items():
            extra = ", plan right %d/%d" % (o["plan_hit"], o["n"]) if role == "implementer" else ""
            print("  %-10s %-11s under %d  match %d  over %d%s%s" % (
                pname, role, o["under"], o["match"], o["over"], extra,
                ", %d unusable answers" % o["errors"] if o["errors"] else ""))


def cmd_status(_args):
    pool, labels, live = load_pool(), load_labels(), load_live()
    roles = {}
    for it in pool:
        r = roles.setdefault(it["role"], [0, 0, 0])
        r[0] += 1
        r[1] += it["id"] in labels
        r[2] += it["id"] in live
    print("route-eval: %s" % eval_dir())
    for role, (n, lab, lv) in sorted(roles.items()):
        print("  %-11s %d items, %d labelled, %d with live answers" % (role, n, lab, lv))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return
    cmds = {"pool": cmd_pool, "label": cmd_label, "run": cmd_run, "score": cmd_score, "status": cmd_status}
    if argv[0] not in cmds:
        die("unknown command '%s' (pool, label, run, score, status)" % argv[0])
    cmds[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
