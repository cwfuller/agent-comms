#!/usr/bin/env python3
"""Hermetic stand-in for the Antigravity CLI (`agy`), for the one launch vector the runner uses:

    agy -p= --input-format stream-json --output-format stream-json --mode plan --model <model>-<effort>

Its wire format is the one observed against agy 1.3.1 (2026-10-07): the prompt arrives on stdin as one
NDJSON line `{"event":"user","message":{"content":"<text>"}}` (a line with no `event` field, or a string
`message`, is an error, as agy treats it); stdout is `init`, `step_update`... and a final `result` event.
A model id that is not one of agy's own variants is refused before any turn, as `agy --model` does.

Levers (environment):
  AGY_VERSION      what `--version` prints (default 1.3.1)
  AGY_LOG          append one `key<TAB>value` line per observation (argv, cwd, stdin size, env vars)
  AGY_ENV_VARS     space-separated variable names whose inherited value is logged as `envvar_<NAME>`
  AGY_COUNT        a file counting turns across processes (the canary is turn 1 of a review)
  AGY_MODE         ok (default) | ratelimit (every turn refused) | ratelimit-review (turn 2 refused: the
                   canary passes, the review does not) | subscription (SUBSCRIPTION_REQUIRED, every turn)
                   | auth (every turn refused: not signed in) | write (the review turn writes pwn.txt into
                   its cwd, then answers) | denied (a command and an out-of-store write are refused, as plan
                   mode does) | hang (the review turn never ends) | exit3 (exit 3, result ERROR, no
                   diagnostics) | silent (exit 3 with nothing at all) | notsuccess (rc 0, result ERROR)
  AGY_ANSWER_FILE  a file whose bytes are the reply to a non-canary prompt
  AGY_INIT_MODEL   the model the init event names (default: the one asked for)
  AGY_NO_MODEL     the init event names no model
  AGY_INIT_FROM    the turn number from which AGY_INIT_MODEL / AGY_NO_MODEL apply (default 1; 2 spares a review's canary)
  AGY_PLANNY       a non-canary prompt is answered with the plan-mode non-answer agy gives by default
  AGY_REPLY_FIRST  extra text emitted BEFORE the answer in the response (a preamble)
"""
import json
import os
import sys
import time

args = sys.argv[1:]
VARIANTS = {"gemini-3.1-pro": ("low", "high"), "gemini-3.8-flash": ("low", "medium", "high"),
            "gemini-3.7-flash": ("low", "medium", "high"), "gemini-3.6-flash": ("low", "medium", "high")}
ALL_IDS = {"%s-%s" % (m, e) for m, es in VARIANTS.items() for e in es}


def log(key, value):
    path = os.environ.get("AGY_LOG")
    if path:
        with open(path, "a") as fh:
            fh.write("%s\t%s\n" % (key, str(value).replace("\n", "\\n")))


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


if args == ["--version"] or args == ["version"]:
    print(os.environ.get("AGY_VERSION", "1.3.1"))
    sys.exit(0)
if args[:1] == ["models"]:
    for i in sorted(ALL_IDS):
        print("%s\t%s" % (i, i))
    sys.exit(0)

log("argv", " ".join(args))
log("cwd", os.path.realpath(os.getcwd()))
for name in os.environ.get("AGY_ENV_VARS", "").split():
    v = os.environ.get(name)
    log("envvar_" + name, "<unset>" if v is None else v)


def flag(name):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return None


model = flag("--model")
mode = flag("--mode")
fail_early = None
if "-p=" not in args and "-p" not in args and "--print" not in args:
    fail_early = "not in print mode"
elif flag("--input-format") != "stream-json" or flag("--output-format") != "stream-json":
    fail_early = "the runner always uses stream-json in and out"
elif model not in ALL_IDS:
    fail_early = 'invalid model selection (--model "%s" --effort ""): model %s is not recognized as a known model or custom model in settings' % (model, model)
if fail_early:
    sys.stderr.write("error: %s\n" % fail_early)
    emit({"event": "result", "result": {"conversation_id": "", "status": "ERROR", "response": "", "error": fail_early}})
    sys.exit(1)

# the prompt, from stdin, in agy's own framing
raw = sys.stdin.read()
prompt = None
for line in raw.splitlines():
    if not line.strip():
        continue
    try:
        m = json.loads(line)
    except ValueError:
        sys.stderr.write("error: failed to decode stream input\n")
        continue
    if "event" not in m:
        sys.stderr.write('error: stream input message is missing the "event" field\n')
        continue
    if m["event"] != "user":
        sys.stderr.write('warning: ignoring unsupported stream input message event "%s"\n' % m["event"])
        continue
    if not isinstance(m.get("message"), dict):
        sys.stderr.write("error: failed to decode stream input: message is not an object\n")
        continue
    prompt = m["message"].get("content")
log("stdin_bytes", len(raw))
log("prompt_head", (prompt or "")[:80])
log("prompt_has_runtime_note", "RUNTIME NOTE" in (prompt or ""))
_p = prompt or ""
log("prompt_change", _p[_p.index("----- BEGIN CHANGE UNDER REVIEW"):_p.index("----- END CHANGE UNDER REVIEW")] if "----- BEGIN CHANGE UNDER REVIEW" in _p and "----- END CHANGE UNDER REVIEW" in _p else "-")
log("mode", mode)
canary = prompt is not None and "single word PONG" in prompt

count_file = os.environ.get("AGY_COUNT")
n = 1
if count_file:
    try:
        n = int(open(count_file).read().strip() or "0") + 1
    except (OSError, ValueError):
        n = 1
    open(count_file, "w").write(str(n))
log("turn_number", n)

conv = "conv-%d-%d" % (os.getpid(), n)
init_from = int(os.environ.get("AGY_INIT_FROM", "1"))
init_model = (os.environ.get("AGY_INIT_MODEL") if n >= init_from else None) or model
init = {"model": init_model, "cwd": os.getcwd(), "tools": ["view_file", "grep_search", "write_to_file", "run_command"],
        "permission_mode": "request-review"}
if os.environ.get("AGY_NO_MODEL") and n >= init_from:
    del init["model"]
emit({"event": "init", "conversation_id": conv, "init": init})
emit({"event": "step_update", "step_update": {"conversation_id": conv, "step_index": 0, "state": "DONE", "step_type": "user_input"}})

amode = os.environ.get("AGY_MODE", "ok")


def result(status, response, error=None, usage=True, denied=None):
    body = {"conversation_id": conv, "status": status, "response": response, "duration_seconds": 0.5, "num_turns": 1}
    if usage:
        body["usage"] = {"input_tokens": 1000, "output_tokens": 100, "thinking_tokens": 40, "cache_read_tokens": 500,
                         "total_tokens": 1100}
    if error:
        body["error"] = error
    if denied:
        body["denied_actions"] = denied
    emit({"event": "result", "result": body})


def refuse(text):
    sys.stderr.write(text + "\n")
    result("ERROR", "", error=text, usage=False)
    sys.exit(1)


if amode == "ratelimit" or (amode == "ratelimit-review" and n >= 2):
    refuse("RESOURCE_EXHAUSTED: 429 Too Many Requests — you have exhausted your capacity on this model; quota resets later")
if amode == "subscription":
    refuse("rpc error: code = PermissionDenied desc = SUBSCRIPTION_REQUIRED: this model requires a subscription")
if amode == "auth":
    refuse("Please sign in to continue: no valid authentication found")
if amode == "silent":
    sys.exit(3)
if amode == "exit3":
    result("ERROR", "", usage=False)
    sys.exit(3)
if amode == "notsuccess":
    result("ERROR", "", error="the turn ended without a response", usage=False)
    sys.exit(0)
if amode == "hang" and not canary:
    time.sleep(600)

if canary:
    result("SUCCESS", "PONG\n")
    sys.exit(0)

denied = None
if amode == "write":
    open(os.path.join(os.getcwd(), "pwn.txt"), "w").write("breach\n")
if amode == "denied":
    emit({"event": "step_update", "step_update": {"conversation_id": conv, "step_index": 2, "state": "ERROR",
          "step_type": "tool", "tool_name": "write_to_file", "tool_info": {"name": "write_to_file", "parameters": {"TargetFile": "/x/pwn.txt"},
          "error": {"type": "TOOL_ERROR", "message": 'permission check failed for write_file "/x/pwn.txt"'}}}})
    denied = [{"action": "command", "display_name": "RunCommand"}]
if os.environ.get("AGY_PLANNY"):
    result("SUCCESS", "I have created an implementation plan. Please review and approve it before I proceed.\n", denied=denied)
    sys.exit(0)
answer = ""
af = os.environ.get("AGY_ANSWER_FILE")
if af:
    answer = open(af).read()
else:
    answer = ("VERDICT: APPROVE\n\n## Summary\nThe change is fine.\n\n## Findings\n### Blocking\n- None.\n"
              "### Advisory\n- None.\n### Process\n- None.\n")
answer = os.environ.get("AGY_REPLY_FIRST", "") + answer
emit({"event": "step_update", "step_update": {"conversation_id": conv, "step_index": 3, "state": "DONE", "step_type": "agent_response",
      "text_delta": answer[:20], "usage": {"input_tokens": 1000, "output_tokens": 100}}})
result("SUCCESS", answer, denied=denied)
