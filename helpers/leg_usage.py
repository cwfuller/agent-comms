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
  (gemini has no reader here: agy keeps no record of a turn on disk that this module could bound, so its
          usage comes from its own `result` event, read by helpers/agy_stream.py `usage`.)

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
import hashlib
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


def absent(path):
    """True when path does not exist — an empty record set, which is a fact. A path that exists
    but cannot be listed RAISES: that is not evidence of absence, and the window stays unbounded.
    So does a path whose existence cannot be told (a directory above it that cannot be searched):
    only ENOENT is absence. os.path.lexists would answer False for EACCES too, and an empty
    snapshot taken then lets every record already there count as the next window's. (code review
    r1, task 421.)"""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return True
    os.listdir(path)
    return False


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
    if absent(root):
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
        if absent(root) or absent(base):
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
    if absent(root):
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

def read_grok_doc(f):
    """(sessionId, turns[]) of one usage.json."""
    try:
        with open(f) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        raise Undecidable("a grok usage.json could not be read or parsed")
    turns = doc.get("turns") if isinstance(doc, dict) else None
    if not isinstance(turns, list):
        raise Undecidable("a grok usage.json carries no turns[] list")
    return doc.get("sessionId"), turns


def grok_turn_print(t):
    """A completed turn's identity: its whole record. grok REWRITES usage.json, so a file that
    survived by name can still have had its history replaced or reset; only the content of each
    snapshotted turn shows that the turns before the window are the ones we snapshotted."""
    return hashlib.sha256(json.dumps(t, sort_keys=True).encode("utf-8")).hexdigest()


def grok_turn_key(t):
    n = t.get("turnNumber") if isinstance(t, dict) else None
    if not isinstance(n, int) or isinstance(n, bool):
        raise Undecidable("a grok turn carries no integer turnNumber")
    return n


def grok_state(f):
    sid, turns = read_grok_doc(f)
    prints = {}
    for t in turns:
        n = str(grok_turn_key(t))
        if n in prints:
            raise Undecidable("a grok usage.json numbers two turns alike")
        prints[n] = grok_turn_print(t)
    return {"session": sid, "turns": prints}


def snapshot(provider, root, cwd):
    if provider == "grok":
        return {"grok": {f: grok_state(f) for f in grok_files(root, cwd)}}
    return snapshot_files(jsonl_files(provider, root, cwd))


def snapshot_files(files):
    """The (inode, size) of each append-only record file, the state a window is measured from."""
    state = {}
    for f in files:
        st = os.stat(f)
        state[f] = [st.st_ino, st.st_size]
    return {"files": state}


# ---------- the window ----------

def window_records(files, snap):
    """(file, window_start_offset, [records appended during the turn]) per file with growth. `files` is
    every record file the caller attributes to the window NOW (the usage reader and claude_transcript.py
    each enumerate their own); the window rules below are the same for both."""
    prev = snap.get("files")
    if not isinstance(prev, dict):
        raise Undecidable("the snapshot does not describe any record files")
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
                fh.seek(start)
                raw = fh.read()
        except OSError:
            raise Undecidable("a record file could not be read")
        if len(raw) != st.st_size - start:
            raise Undecidable("an incomplete read of a record file")
        out.append((f, start, parse_jsonl(raw)))
    return out


def parse_jsonl(raw):
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
            raise Undecidable("a malformed record")
    return recs


# ---------- summing ----------

def add_usage(rows):
    """Field-wise sum. A field any row lacks is null for the whole leg, not a partial sum."""
    if not rows:
        return None
    total = {}
    for k in FIELDS:
        vals = [r.get(k) for r in rows]
        if all(is_count(v) for v in vals):
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
    for f, _start, recs in windows:
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
    for f, start, recs in windows:
        end = last_running_total(recs)
        if end is None:
            continue
        base = codex_baseline(pre_records(f, start))
        d = {}
        for k in FIELDS:
            a, b = end.get(k), base.get(k)
            if is_count(a) and is_count(b) and a >= b:
                d[k] = a - b
            elif is_count(a) and is_count(b):
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


def is_count(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def is_billing(r):
    """A record that says tokens were spent: a token_usage_record, or a token_count whose info
    is present (a token_count with info null carries only a rate-limit update)."""
    if not isinstance(r, dict):
        return False
    if r.get("type") == "token_usage_record":
        return True
    p = r.get("payload")
    return (r.get("type") == "event_msg" and isinstance(p, dict)
            and p.get("type") == "token_count" and p.get("info") is not None)


def running_total(r):
    """The token_count running total a record carries, or None. The total OBJECT must be there;
    a field it omits stays null and nulls only that field of the delta (the per-field rule), so
    a runtime that never reports, say, cache writes still measures everything else."""
    if not is_billing(r) or r.get("type") != "event_msg":
        return None
    info = r["payload"]["info"]
    return codex_norm(info.get("total_token_usage")) if isinstance(info, dict) else None


def last_running_total(recs):
    """The running total as of the END of recs: the last billing record must itself carry a
    complete total. Billing evidence after the last total (a token_count reporting only
    last_token_usage, a token_usage_record) means spend the total does not include, so the
    total is not the endpoint — unbounded, never a stale value. None when recs hold no billing
    evidence at all."""
    billing = [r for r in recs if is_billing(r)]
    if not billing:
        return None
    t = running_total(billing[-1])
    if t is None:
        raise Undecidable("codex recorded spend after its last running token total")
    return t


def codex_baseline(pre):
    """The running total the window starts from. ZERO ONLY WHEN PROVEN: the bytes before the
    window carry no billing evidence at all (a file the leg itself created, or one holding only
    session metadata). Otherwise the last billing record must carry the total (see
    last_running_total) — earlier work that cannot be subtracted is never billed to this leg."""
    t = last_running_total(pre)
    return t if t is not None else {k: 0 for k in FIELDS}


def pre_records(f, start):
    """Records written BEFORE the window, for the token_count baseline — read only on this
    fallback path, and held to the same strict reader as the window: a baseline read past a
    malformed record could be an older total than the true one."""
    if not start:
        return []
    try:
        with open(f, "rb") as fh:
            pre = fh.read(start)
    except OSError:
        raise Undecidable("a record file could not be re-read for its baseline")
    if len(pre) != start:
        raise Undecidable("an incomplete read of a record file's baseline")
    return parse_jsonl(pre)


def token_count_events(recs):
    for r in recs:
        if isinstance(r, dict) and r.get("type") == "event_msg":
            p = r.get("payload")
            if isinstance(p, dict) and p.get("type") == "token_count":
                yield r, p


def codex_rate_limits(windows):
    latest, latest_ts = None, None
    for _f, _start, recs in windows:
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


def is_zero_usage(u):
    keys = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
    return isinstance(u, dict) and all(u.get(k) == 0 and not isinstance(u.get(k), bool) for k in keys)


def thinking_tokens(u):
    d = u.get("output_tokens_details")
    v = d.get("thinking_tokens") if isinstance(d, dict) else None
    return v if is_count(v) else None


def claude_usage(windows, root, cwd):
    _, exact = claude_dirs(root, cwd)
    forms = set(cwd_forms(cwd))
    last = {}
    order = []
    for f, _start, recs in windows:
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
            m = m if isinstance(m, dict) else {}
            # Claude Code's own synthetic messages (an interrupted or failed request) name the
            # model "<synthetic>" and made no API call. Exempt only while they SAY so — zero
            # tokens everywhere; one carrying a real bill is counted like any response.
            if m.get("model") == "<synthetic>" and is_zero_usage(m.get("usage")):
                continue
            mid, req = m.get("id"), r.get("requestId")
            key = (mid, req) if (mid or req) else (f, r.get("uuid") or "line%d" % i)
            if key not in last:
                order.append(key)
            # The LAST copy carries the final output count. A response with NO usage object is
            # unknown spend: it stays a row, and every field it cannot supply goes null for the
            # leg — dropping it would present a partial sum as the total.
            u = m.get("usage")
            last[key] = u if isinstance(u, dict) else {}
    rows = []
    for key in order:
        u = last[key]
        inp, cw, cr, out = (u.get("input_tokens"), u.get("cache_creation_input_tokens"),
                            u.get("cache_read_input_tokens"), u.get("output_tokens"))
        ok = all(is_count(v) for v in (inp, cw, cr, out))
        rows.append({
            "input_tokens": inp + cw + cr if ok else None,
            "cached_input_tokens": cr if is_count(cr) else None,
            "cache_write_input_tokens": cw if is_count(cw) else None,
            "output_tokens": out if is_count(out) else None,
            # Reported as output_tokens_details.thinking_tokens (a subset of output_tokens) by
            # runtimes that record it; absent elsewhere, and then null like any missing field.
            "reasoning_output_tokens": thinking_tokens(u),
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
        was = prev.get(f, {"session": None, "turns": {}})
        if not isinstance(was, dict) or not isinstance(was.get("turns"), dict):
            raise Undecidable("an unreadable grok snapshot entry")
        sid, turns = read_grok_doc(f)
        now = {}
        for t in turns:
            n = str(grok_turn_key(t))
            if n in now:
                raise Undecidable("a grok usage.json numbers two turns alike")
            now[n] = t
        # THE HISTORY MUST BE THE ONE WE SNAPSHOTTED: same session, and every earlier turn still
        # present with the same content. A replaced or reset history (turn numbers reused, turns
        # dropped) cannot be split into "before" and "this leg", so the window is unbounded.
        if f in prev and sid != was.get("session"):
            raise Undecidable("a grok usage.json now belongs to a different session")
        for n, fp in was["turns"].items():
            if n not in now or grok_turn_print(now[n]) != fp:
                raise Undecidable("a grok usage.json's earlier turns were replaced during the leg")
        for n, t in now.items():
            if n in was["turns"]:
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
    windows = window_records(jsonl_files(provider, root, cwd), snap)
    if provider == "codex":
        # The rate-limit snapshot is its own fact: a window whose spend cannot be bounded still
        # carries a readable latest snapshot, so an unmeasurable usage does not null it.
        rate = codex_rate_limits(windows)
        try:
            return codex_usage(windows), rate
        except Undecidable as e:
            sys.stderr.write("usage unavailable: %s\n" % e)
            return None, rate
    return claude_usage(windows, root, cwd), None


def main(argv):
    if len(argv) != 6 or argv[1] not in ("snapshot", "collect") \
            or argv[2] not in ("codex", "claude", "grok"):
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
