#!/usr/bin/env python3
"""Reading an Antigravity CLI (`agy`) print-mode turn: the gemini provider's only wire format.

runphase.sh launches `agy -p= --input-format stream-json --output-format stream-json --mode plan
--model <model>-<effort>` and keeps its stdout as events.ndjson, one JSON object per line:

  {"event":"init","conversation_id":..,"init":{"model":"gemini-3.1-pro-high","permission_mode":..}}
  {"event":"step_update","step_update":{..}}                       (tool calls, text deltas, per-step usage)
  {"event":"result","result":{"status":"SUCCESS|ERROR","response":"<all answer text>","error":"..",
                              "usage":{..},"denied_actions":[{"action":"command",..}]}}

Anything that is not JSON (agy's diagnostics are interleaved on the same stream when the caller
merges stderr) is read as diagnostics, never as an event.

Verbs (every one reads files only, prints one fact per line, and exits non-zero when it cannot say):
  reply   <events>            the final answer text, verbatim (the `result.response` of a SUCCESS turn)
  model   <events>            the model id the `init` event named: the PER-TURN evidence of model AND effort,
                              because the launcher passes the combined id `<model>-<effort>`
  attest  <events>            `effort<TAB>model` split from that id, the shape `acp.sh policy-attest` takes
  facts   <events> [stderr]   key<TAB>value lines: status, denied (actions headless mode auto-denied),
                              refused (tools whose call failed a permission check), failure, error
  classify <file>...          why a provider REFUSED a turn, read from diagnostics only
  usage   <events>...         the one-line JSON usage object result.json carries (the SUM over every stream that
                              has one: the canary is part of what a leg cost), or `null`
  input   <prompt-file>       the one stdin line that sends that file's text as a turn (`--input-format stream-json`)

Failure classes (`classify`, and `facts`' failure line) are matched against the stream's diagnostics and
the result event's `error`, NEVER the answer text — a review may legitimately discuss a 429:
  model-unavailable  the account is not entitled to the model (SUBSCRIPTION_REQUIRED); checked first
  rate-limited       a rate limit, quota or capacity refusal (429, RESOURCE_EXHAUSTED, quota exhausted)
  auth-failed        no usable login
The wording is matched case-insensitively and is NOT yet confirmed against a live refusal; see
docs/ROADMAP.md.
"""
import json
import re
import sys

EFFORTS = ("low", "medium", "high", "xhigh", "max")

MODEL_UNAVAILABLE_RE = re.compile(
    r"subscription[ _-]?required|not (entitled|eligible) (to|for)|model .{0,60}(is )?not (available|enabled|supported) "
    r"(for|on|to) (this|your) (account|plan|subscription)|requires? (a|an) (paid )?(google )?(ai )?(subscription|plan)",
    re.I)
RATE_RE = re.compile(
    r"rate[ _-]?limit|resource_exhausted|too many requests|quota|exhausted your capacity|"
    r"usage limit|capacity (is )?(exhausted|unavailable)|(^|[^0-9])429([^0-9]|$)", re.I)
AUTH_RE = re.compile(
    r"unauthenticated|authentication (is )?(required|failed)|not (logged|signed) in|"
    r"(log|sign) ?in (is )?required|please (log|sign) ?in|sign in to view|no valid authentication|"
    r"invalid (api )?key|api key not valid|api_key_invalid|unauthori[sz]ed|(^|[^0-9])401([^0-9]|$)|"
    r"oauth.*(expired|invalid|revoked)|credentials? (expired|invalid|not found)", re.I)


def read_events(path):
    """-> (events, diagnostics). A line that is not a JSON object is a diagnostic."""
    events, diag = [], []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                diag.append(line)
                continue
            if isinstance(e, dict) and isinstance(e.get("event"), str):
                events.append(e)
            else:
                diag.append(line)
    return events, diag


def last(events, name):
    found = [e for e in events if e.get("event") == name]
    return found[-1] if found else None


def result_of(events):
    r = last(events, "result")
    body = r.get("result") if r else None
    return body if isinstance(body, dict) else None


def init_model(events):
    e = last(events, "init")
    body = e.get("init") if e else None
    m = body.get("model") if isinstance(body, dict) else None
    return m if isinstance(m, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", m) else None


def split_model(model):
    """`gemini-3.1-pro-high` -> ("high", "gemini-3.1-pro"); an id with no effort suffix has no effort."""
    base, _, tail = model.rpartition("-")
    if base and tail in EFFORTS:
        return tail, base
    return "", model


def classify_text(text):
    if MODEL_UNAVAILABLE_RE.search(text):
        return "model-unavailable"
    if RATE_RE.search(text):
        return "rate-limited"
    if AUTH_RE.search(text):
        return "auth-failed"
    return ""


def diagnostics_text(events, diag):
    """The text a refusal is read from: non-JSON lines and the result event's own `error`. Never `response`."""
    parts = list(diag)
    body = result_of(events)
    if body and isinstance(body.get("error"), str):
        parts.append(body["error"])
    return "\n".join(parts)


def usage_json(events):
    """result.json's usage object, from the provider's own result event, in codex's convention:
    input_tokens INCLUDES cached reads, total = input + output. null when the event carries none."""
    body = result_of(events)
    u = body.get("usage") if body else None
    if not isinstance(u, dict):
        return None
    try:
        cached = int(u.get("cache_read_tokens", 0))
        inp = int(u["input_tokens"]) + cached
        out = int(u["output_tokens"])
        thought = int(u.get("thinking_tokens", 0))
    except (KeyError, TypeError, ValueError):
        return None
    return {"input_tokens": inp, "cached_input_tokens": cached, "cache_write_input_tokens": None,
            "output_tokens": out, "reasoning_output_tokens": thought, "total_tokens": inp + out,
            "turns": 1, "responses": None}


def one_line(s, limit=300):
    return re.sub(r"\s+", " ", s).strip()[:limit]


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    verb, path = argv[1], argv[2]
    if verb == "input":
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError) as e:
            sys.stderr.write("agy_stream: cannot read %s: %s\n" % (path, e))
            return 1
        print(json.dumps({"event": "user", "message": {"content": text}}, ensure_ascii=False))
        return 0
    if verb == "usage":
        total, seen = {}, 0
        for p in argv[2:]:
            try:
                u = usage_json(read_events(p)[0])
            except OSError:
                u = None
            if not u:
                continue
            seen += 1
            for k, v in u.items():
                if isinstance(v, int):
                    total[k] = total.get(k, 0) + v
                else:
                    total.setdefault(k, v)
        if seen:
            total["turns"] = seen
        print(json.dumps(total, separators=(",", ":")) if seen else "null")
        return 0
    if verb == "classify":
        text = ""
        for p in argv[2:]:
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    text += fh.read() + "\n"
            except OSError:
                pass
        cls = classify_text(text)
        if cls:
            print(cls)
        return 0
    try:
        events, diag = read_events(path)
    except OSError as e:
        sys.stderr.write("agy_stream: cannot read %s: %s\n" % (path, e))
        return 1
    if verb == "reply":
        body = result_of(events)
        if not body or body.get("status") != "SUCCESS" or not isinstance(body.get("response"), str):
            return 1
        sys.stdout.write(body["response"])
        return 0
    if verb in ("model", "attest"):
        m = init_model(events)
        if not m:
            sys.stderr.write("agy_stream: no init event names a model\n")
            return 1
        if verb == "model":
            print(m)
        else:
            eff, base = split_model(m)
            print("%s\t%s" % (eff, base))
        return 0
    if verb == "facts":
        extra = ""
        if len(argv) > 3:
            try:
                with open(argv[3], encoding="utf-8", errors="replace") as fh:
                    extra = fh.read()
            except OSError:
                pass
        body = result_of(events)
        text = diagnostics_text(events, diag + ([extra] if extra else []))
        denied = []
        if body and isinstance(body.get("denied_actions"), list):
            for d in body["denied_actions"]:
                a = d.get("action") if isinstance(d, dict) else None
                if isinstance(a, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", a):
                    denied.append(a)
        refused = []
        for e in events:
            su = e.get("step_update") if e.get("event") == "step_update" else None
            err = su.get("tool_info", {}).get("error") if isinstance(su, dict) and isinstance(su.get("tool_info"), dict) else None
            if isinstance(err, dict) and re.search(r"permission", str(err.get("message", "")), re.I):
                t = su.get("tool_name")
                if isinstance(t, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", t):
                    refused.append(t)
        print("status\t%s" % (body.get("status") if body and isinstance(body.get("status"), str) else "none"))
        print("denied\t%s" % (",".join(denied) or "-"))
        print("refused\t%s" % (",".join(refused) or "-"))
        print("failure\t%s" % (classify_text(text) or "-"))
        print("error\t%s" % (one_line(body["error"]) if body and isinstance(body.get("error"), str) and body["error"] else "-"))
        return 0
    sys.stderr.write("agy_stream: unknown verb '%s'\n" % verb)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
