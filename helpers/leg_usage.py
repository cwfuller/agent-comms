#!/usr/bin/env python3
"""Per-leg token usage, read from the PROVIDER'S OWN records.

A review leg's spend is what the provider recorded for that turn, never what a wrapper printed
about it: acpx's `[acpx] tokens:` line and anything in runner.log are summaries by a third party,
and a summary cannot be deduplicated or audited. Each provider keeps its own ledger on disk:

  codex   $CODEX_HOME/sessions/**/rollout-*.jsonl  — token_usage_record per model response,
          summed by turn_id (deduplicated by response_id); falls back to the event_msg
          token_count.info running total when a runtime writes no token_usage_record. The
          newest token_count.rate_limits in the window is the account's rate-limit snapshot.
  claude  <config>/projects/<cwd-slug>/**/*.jsonl  — assistant records; one API response is
          written once PER CONTENT BLOCK with the same usage, so records are deduplicated by
          (message.id, requestId) and the LAST copy wins (streaming finalises output_tokens).
  grok    <home>/sessions/<quoted-cwd>/<session>/usage.json — turns[] per prompt. The file is
          rewritten, not appended, so a turn is identified by (file, turnNumber).

The window is the turn, not the session: `snapshot` records the state of the provider's records
immediately before the billable prompt, and `collect` reads only what appeared after it. A warm
leg resumes one session across rounds, so the session total would bill round 1 again in round 5.

MISSING IS null, NEVER 0. No records in the window, a record set that cannot be bounded (a file
replaced, truncated, or vanished mid-turn; an unreadable or malformed record), or a field no record
carries — all print null. A zero would read as "this leg was free", which is the one thing the
measurement must never claim without evidence.

Normalised fields follow codex's convention so legs are comparable across providers:
input_tokens INCLUDES cached reads and cache writes; cached_input_tokens and
cache_write_input_tokens are subsets of it; reasoning_output_tokens is a subset of output_tokens;
total_tokens = input_tokens + output_tokens. `turns` counts prompts (codex turn_ids, grok turns[];
null where the provider does not number them) and `responses` counts deduplicated model responses.

Usage:
  leg_usage.py snapshot <codex|claude|grok> <records-root> <cwd> <out-file>
  leg_usage.py collect  <codex|claude|grok> <records-root> <cwd> <snapshot-file>
collect prints exactly two lines, `usage\\t<json|null>` and `rate_limits\\t<json|null>`, and exits 0
whenever it could print them; the reason for a null goes to stderr.
"""
import json
import os
import re
import sys
from urllib.parse import quote

FIELDS = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
          "output_tokens", "reasoning_output_tokens", "total_tokens")

# Claude Code names a project directory by replacing every non-alphanumeric character of the
# cwd with "-", and truncates a long one to this many characters plus a hash suffix. The hash is
# not reproduced here: a truncated name is matched by prefix and every record is then held to
# its own `cwd` field, so a neighbouring mount that shares the prefix contributes nothing.
CLAUDE_SLUG_MAX = 200


class Undecidable(Exception):
    """The window cannot be bounded or read — the answer is null, not a partial sum."""


def _boom(e):
    raise e


# ---------- where each provider's records live ----------

def cwd_forms(cwd):
    forms = [cwd]
    real = os.path.realpath(cwd)
    if real not in forms:
        forms.append(real)
    return forms


def claude_slug(path):
    return re.sub(r"[^a-zA-Z0-9]", "-", path)


def claude_dirs(root, cwd):
    """Candidate project directories for cwd, and which of them are EXACT (unsuffixed) names."""
    if not os.path.isdir(root):
        os.listdir(root)                     # absent is empty; unreadable raises
        return [], set()
    names = os.listdir(root)
    out, exact = [], set()
    for form in cwd_forms(cwd):
        slug = claude_slug(form)
        for n in names:
            hit = n == slug
            if not hit and len(slug) > CLAUDE_SLUG_MAX:
                hit = n.startswith(slug[:CLAUDE_SLUG_MAX] + "-")
            if hit:
                p = os.path.join(root, n)
                if p not in out:
                    out.append(p)
                if n == slug:
                    exact.add(p)
    return out, exact


def jsonl_files(provider, root, cwd):
    """Every append-only record file this provider could have written for cwd."""
    files = []
    if provider == "codex":
        base = os.path.join(root, "sessions")
        if not os.path.isdir(base):
            os.listdir(root)
            return files
        for d, _, names in os.walk(base, onerror=_boom):
            for n in names:
                if n.startswith("rollout-") and n.endswith(".jsonl"):
                    files.append(os.path.join(d, n))
    elif provider == "claude":
        dirs, _ = claude_dirs(root, cwd)
        for base in dirs:
            for d, _, names in os.walk(base, onerror=_boom):
                for n in names:
                    if n.endswith(".jsonl"):
                        files.append(os.path.join(d, n))
    return sorted(files)


def grok_files(root, cwd):
    files = []
    if not os.path.isdir(root):
        os.listdir(root)
        return files
    for form in cwd_forms(cwd):
        base = os.path.join(root, quote(form, safe=""))
        if not os.path.isdir(base):
            continue
        for sid in sorted(os.listdir(base)):
            f = os.path.join(base, sid, "usage.json")
            if os.path.isfile(f) and f not in files:
                files.append(f)
    return files


# ---------- snapshot ----------

def read_grok_turns(f):
    try:
        with open(f) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        raise Undecidable("a grok usage.json could not be read or parsed")
    turns = doc.get("turns") if isinstance(doc, dict) else None
    if not isinstance(turns, list):
        raise Undecidable("a grok usage.json carries no turns[] list")
    return turns


def grok_turn_key(t):
    n = t.get("turnNumber") if isinstance(t, dict) else None
    if not isinstance(n, int) or isinstance(n, bool):
        raise Undecidable("a grok turn carries no integer turnNumber")
    return n


def snapshot(provider, root, cwd):
    if provider == "grok":
        return {"grok": {f: sorted(grok_turn_key(t) for t in read_grok_turns(f))
                         for f in grok_files(root, cwd)}}
    files = {}
    for f in jsonl_files(provider, root, cwd):
        st = os.stat(f)
        files[f] = [st.st_ino, st.st_size]
    return {"files": files}


# ---------- the window ----------

def window_records(provider, root, cwd, snap):
    """Yield (file, pre_window_bytes, [records appended during the turn]) per file with growth."""
    prev = snap.get("files")
    if not isinstance(prev, dict):
        raise Undecidable("the snapshot does not describe any record files")
    files = jsonl_files(provider, root, cwd)
    seen = set(files)
    for f in prev:
        if f not in seen:
            raise Undecidable("a record file present at snapshot time is gone")
    out = []
    for f in files:
        try:
            st = os.stat(f)
        except OSError:
            raise Undecidable("a record file became unreadable during the turn")
        start = 0
        if f in prev:
            try:
                ino, size = int(prev[f][0]), int(prev[f][1])
            except (TypeError, ValueError, IndexError):
                raise Undecidable("an unreadable snapshot entry")
            if st.st_ino != ino:
                raise Undecidable("a record file was replaced during the turn")
            if st.st_size < size:
                raise Undecidable("a record file was truncated during the turn")
            start = size
        if st.st_size == start:
            continue
        try:
            with open(f, "rb") as fh:
                pre = fh.read(start)
                raw = fh.read()
        except OSError:
            raise Undecidable("a record file could not be read")
        if len(pre) != start or len(raw) != st.st_size - start:
            raise Undecidable("an incomplete read of a record file")
        try:
            blob = raw.decode("utf-8")
        except UnicodeDecodeError:
            raise Undecidable("a record file is not valid UTF-8")
        # JSONL ends records at "\n" and nowhere else: str.splitlines() would also break on
        # U+2028/U+2029, which JSON allows raw inside a string (the rollout reader learned this).
        if blob and not blob.endswith("\n"):
            raise Undecidable("a record file ends mid-record")
        recs = []
        for line in blob.split("\n"):
            if not line.strip():
                continue
            try:
                recs.append(json.loads(line))
            except ValueError:
                raise Undecidable("a malformed record in the window")
        out.append((f, pre, recs))
    return out


# ---------- summing ----------

def add_usage(rows):
    """Field-wise sum. A field any row lacks is null for the whole leg, not a partial sum."""
    if not rows:
        return None
    total = {}
    for k in FIELDS:
        vals = [r.get(k) for r in rows]
        if all(isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in vals):
            total[k] = sum(vals)
        else:
            total[k] = None
    return total


def codex_norm(u):
    if not isinstance(u, dict):
        return None
    return {k: u.get(k) for k in FIELDS}


def codex_usage(windows):
    # Primary: token_usage_record, one per model response. Summed by turn_id, and a response
    # recorded twice (same turn_id + response_id) counts once.
    per_turn, keys = {}, set()
    for f, _pre, recs in windows:
        for i, r in enumerate(recs):
            if not isinstance(r, dict) or r.get("type") != "token_usage_record":
                continue
            p = r.get("payload")
            if not isinstance(p, dict):
                raise Undecidable("a token_usage_record with no payload")
            tid = p.get("turn_id")
            rid = p.get("response_id")
            key = (tid, rid) if rid else (tid, f, r.get("ordinal", "line%d" % i))
            if key in keys:
                continue
            keys.add(key)
            u = codex_norm(p.get("usage"))
            if u is None:
                raise Undecidable("a token_usage_record with no usage")
            per_turn.setdefault(tid, []).append(u)
    if per_turn:
        total = add_usage([add_usage(rows) for rows in per_turn.values()])
        total["turns"] = len(per_turn)
        total["responses"] = len(keys)
        total["source"] = "codex-token-usage-record"
        return total
    # Fallback: token_count.info carries a RUNNING thread total, so the turn is the last total
    # in the window minus the last total before it — immune to a repeated token_count event,
    # which summing last_token_usage would double-count.
    deltas = []
    for _f, pre, recs in windows:
        after = [codex_norm(i.get("total_token_usage")) for i in token_count_infos(recs)]
        after = [a for a in after if a is not None]
        if not after:
            continue
        before = [codex_norm(i.get("total_token_usage")) for i in token_count_infos(pre_records(pre))]
        before = [b for b in before if b is not None]
        base = before[-1] if before else {k: 0 for k in FIELDS}
        d = {}
        for k in FIELDS:
            a, b = after[-1].get(k), base.get(k)
            if isinstance(a, int) and isinstance(b, int) and a >= b:
                d[k] = a - b
            elif isinstance(a, int) and isinstance(b, int):
                raise Undecidable("the codex running token total went backwards in the window")
            else:
                d[k] = None
        deltas.append(d)
    if not deltas:
        return None
    total = add_usage(deltas)
    total["turns"] = None
    total["responses"] = None
    total["source"] = "codex-token-count"
    return total


def pre_records(pre):
    """Records written BEFORE the window, for the token_count baseline. Unparseable lines are
    skipped here: the baseline is only ever the last good total, and the window itself was
    already held to the strict reader."""
    out = []
    for line in pre.decode("utf-8", "replace").split("\n"):
        if line.strip():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def token_count_events(recs):
    for r in recs:
        if isinstance(r, dict) and r.get("type") == "event_msg":
            p = r.get("payload")
            if isinstance(p, dict) and p.get("type") == "token_count":
                yield r, p


def token_count_infos(recs):
    return [p["info"] for _r, p in token_count_events(recs) if isinstance(p.get("info"), dict)]


def codex_rate_limits(windows):
    latest, latest_ts = None, None
    for _f, _pre, recs in windows:
        for r, p in token_count_events(recs):
            rl = p.get("rate_limits")
            if not isinstance(rl, dict):
                continue
            ts = r.get("timestamp") if isinstance(r.get("timestamp"), str) else ""
            if latest is None or ts >= latest_ts:
                latest, latest_ts = rl, ts
    if latest is None:
        return None
    prim = latest.get("primary") if isinstance(latest.get("primary"), dict) else {}
    return {
        "limit_id": latest.get("limit_id"),
        "window_minutes": prim.get("window_minutes"),
        "used_percent": prim.get("used_percent"),
        "resets_at": prim.get("resets_at"),
    }


def claude_usage(windows, root, cwd):
    _, exact = claude_dirs(root, cwd)
    forms = set(cwd_forms(cwd))
    last = {}
    order = []
    for f, _pre, recs in windows:
        in_exact = any(f.startswith(d + os.sep) for d in exact)
        for i, r in enumerate(recs):
            if not isinstance(r, dict) or r.get("type") != "assistant":
                continue
            # A prefix-matched (truncated) directory can be shared with another mount; a record
            # counts only when it names this cwd. An exact directory is this cwd's by name.
            rc = r.get("cwd")
            if rc is not None and rc not in forms:
                continue
            if rc is None and not in_exact:
                continue
            m = r.get("message")
            if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                continue
            mid, req = m.get("id"), r.get("requestId")
            key = (mid, req) if (mid or req) else (f, r.get("uuid") or "line%d" % i)
            if key not in last:
                order.append(key)
            last[key] = m["usage"]          # the LAST copy carries the final output count
    rows = []
    for key in order:
        u = last[key]
        inp, cw, cr, out = (u.get("input_tokens"), u.get("cache_creation_input_tokens"),
                            u.get("cache_read_input_tokens"), u.get("output_tokens"))
        ok = all(isinstance(v, int) and not isinstance(v, bool) for v in (inp, cw, cr, out))
        rows.append({
            "input_tokens": inp + cw + cr if ok else None,
            "cached_input_tokens": cr if isinstance(cr, int) else None,
            "cache_write_input_tokens": cw if isinstance(cw, int) else None,
            "output_tokens": out if isinstance(out, int) else None,
            "reasoning_output_tokens": None,   # not reported separately by this provider
            "total_tokens": inp + cw + cr + out if ok else None,
        })
    total = add_usage(rows)
    if total is None:
        return None
    total["turns"] = None
    total["responses"] = len(rows)
    total["source"] = "claude-transcript"
    return total


GROK_MAP = {
    "input_tokens": "inputTokens",
    "cached_input_tokens": "cachedReadTokens",
    "cache_write_input_tokens": "cacheCreationTokens",
    "output_tokens": "outputTokens",
    "reasoning_output_tokens": "reasoningTokens",
    "total_tokens": "totalTokens",
}


def grok_usage(root, cwd, snap):
    prev = snap.get("grok")
    if not isinstance(prev, dict):
        raise Undecidable("the snapshot does not describe any grok usage files")
    files = grok_files(root, cwd)
    for f in prev:
        if f not in files:
            raise Undecidable("a grok usage.json present at snapshot time is gone")
    rows, calls = [], []
    for f in files:
        before = set(prev.get(f, []))
        for t in read_grok_turns(f):
            if grok_turn_key(t) in before:
                continue
            rows.append({k: t.get(v) for k, v in GROK_MAP.items()})
            calls.append(t.get("modelCalls"))
    total = add_usage(rows)
    if total is None:
        return None
    total["turns"] = len(rows)
    total["responses"] = sum(calls) if all(isinstance(c, int) and not isinstance(c, bool) for c in calls) else None
    total["source"] = "grok-usage-json"
    return total


def collect(provider, root, cwd, snap):
    if provider == "grok":
        return grok_usage(root, cwd, snap), None
    windows = window_records(provider, root, cwd, snap)
    if provider == "codex":
        return codex_usage(windows), codex_rate_limits(windows)
    return claude_usage(windows, root, cwd), None


def main(argv):
    if len(argv) != 6 or argv[1] not in ("snapshot", "collect") or argv[2] not in ("codex", "claude", "grok"):
        sys.stderr.write("usage: leg_usage.py snapshot|collect codex|claude|grok <records-root> <cwd> <file>\n")
        return 2
    verb, provider, root, cwd, path = argv[1:]
    if verb == "snapshot":
        try:
            snap = snapshot(provider, root, cwd)
        except (OSError, Undecidable) as e:
            sys.stderr.write("usage snapshot failed: %s\n" % e)
            return 1
        try:
            with open(path, "w") as fh:
                json.dump(snap, fh)
        except OSError as e:
            sys.stderr.write("usage snapshot unwritable: %s\n" % e)
            return 1
        return 0
    usage, rate = None, None
    try:
        with open(path) as fh:
            snap = json.load(fh)
        if not isinstance(snap, dict):
            raise Undecidable("the snapshot is not an object")
        usage, rate = collect(provider, root, cwd, snap)
        if usage is None:
            sys.stderr.write("usage unavailable: no %s usage records in this turn's window\n" % provider)
    except (OSError, ValueError, Undecidable) as e:
        sys.stderr.write("usage unavailable: %s\n" % e)
        usage, rate = None, None
    sys.stdout.write("usage\t%s\n" % json.dumps(usage, sort_keys=True, separators=(",", ":")))
    sys.stdout.write("rate_limits\t%s\n" % json.dumps(rate, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
