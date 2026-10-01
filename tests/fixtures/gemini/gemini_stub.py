#!/usr/bin/env python3
"""Hermetic stand-in for the Gemini CLI: `--version`, `--help`, and enough of `--acp` for a turn.

It speaks newline-delimited JSON-RPC 2.0 on stdio like `gemini --acp` does, and it behaves the way the
real CLI's state handling does where the suite needs to observe it: the model comes from
$GEMINI_CLI_HOME/.gemini/settings.json (`model.name`), so an isolated home is what binds it; every
answered prompt appends a chat record under $GEMINI_CLI_HOME/.gemini/tmp/<project>/chats/ in the
shape the real CLI writes (a `gemini` message carrying the answering model and a tokens object, appended
a second time once the tokens arrive).

Levers (environment):
  GM_VERSION        what `--version` prints (default 0.62.0)
  GM_COUNT          a file counting prompts across processes (acpx starts a fresh agent per call)
  GM_LOG            append one `key<TAB>value` line per observation (argv, home, env, settings, prompt)
  GM_MODE           ok (default) | auth (session/new refuses: Authentication required)
                    | ratelimit (every prompt refused with a 429) | ratelimit-real (only the prompt
                    AFTER the first one is refused: the canary passes, the review is refused)
                    | ratelimit-partial (as ratelimit-real, but the review streams some text first)
  GM_ANSWER_FILE    a file whose bytes are the reply to a non-canary prompt
  GM_ANSWER_MODEL   the model the chat record names (default: the model in force)
  GM_NO_MODEL       write the answered message with no model field
"""
import json
import os
import sys
import time
import uuid

args = sys.argv[1:]


def log(key, value):
    path = os.environ.get("GM_LOG")
    if path:
        with open(path, "a") as fh:
            fh.write("%s\t%s\n" % (key, value))


if "--version" in args or "-v" in args:
    print(os.environ.get("GM_VERSION", "0.62.0"))
    sys.exit(0)
if "--help" in args or "-h" in args:
    print("Usage: gemini [options]\n      --acp  Starts the agent in ACP mode")
    sys.exit(0)
if "--acp" not in args:
    sys.stderr.write("stub gemini: only --acp is implemented (got %s)\n" % " ".join(args))
    sys.exit(2)

home = os.environ.get("GEMINI_CLI_HOME") or os.path.expanduser("~")
gdir = os.path.join(home, ".gemini")
log("argv", " ".join(args))
log("gemini_cli_home", os.environ.get("GEMINI_CLI_HOME", "<unset>"))
log("env_GEMINI_MODEL", os.environ.get("GEMINI_MODEL", "<unset>"))
log("env_GEMINI_SANDBOX", os.environ.get("GEMINI_SANDBOX", "<unset>"))
log("env_GEMINI_CLI", os.environ.get("GEMINI_CLI", "<unset>"))
log("env_GEMINI_CLI_SYSTEM_SETTINGS_PATH", os.environ.get("GEMINI_CLI_SYSTEM_SETTINGS_PATH", "<unset>"))
log("env_GEMINI_API_KEY", "set" if os.environ.get("GEMINI_API_KEY") else "<unset>")
log("env_COMMS_SELF", os.environ.get("COMMS_SELF", "<unset>"))


def settings():
    try:
        with open(os.path.join(gdir, "settings.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


cfg = settings()
log("settings", json.dumps(cfg, sort_keys=True, separators=(",", ":")))
for name in ("oauth_creds.json", "google_accounts.json", "gemini-credentials.json"):
    p = os.path.join(gdir, name)
    if os.path.isfile(p):
        with open(p) as fh:
            log("cred_" + name, "%s mode=%o" % (fh.read().strip(), os.stat(p).st_mode & 0o777))
    else:
        log("cred_" + name, "<absent>")

state = {"model": (cfg.get("model") or {}).get("name") or "gemini-default", "prompts": 0, "chat": None}


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(rid, result):
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def fail(rid, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    send({"jsonrpc": "2.0", "id": rid, "error": err})


def chat_file():
    if state["chat"]:
        return state["chat"]
    d = os.path.join(gdir, "tmp", "stub-project", "chats")
    os.makedirs(d, exist_ok=True)
    sid = str(uuid.uuid4())
    path = os.path.join(d, "session-%s-%s.jsonl" % (time.strftime("%Y-%m-%dT%H-%M"), sid[:8]))
    with open(path, "a") as fh:
        fh.write(json.dumps({"sessionId": sid, "projectHash": "stub", "startTime": "2026-09-30T00:00:00Z",
                             "lastUpdated": "2026-09-30T00:00:00Z", "kind": "main"}) + "\n")
    state["chat"] = path
    return path


def record_answer(text):
    path = chat_file()
    mid = str(uuid.uuid4())
    model = os.environ.get("GM_ANSWER_MODEL") or state["model"]
    msg = {"id": mid, "timestamp": "2026-09-30T00:00:01Z", "type": "gemini", "content": text}
    if not os.environ.get("GM_NO_MODEL"):
        msg["model"] = model
    with open(path, "a") as fh:
        fh.write(json.dumps({"id": str(uuid.uuid4()), "type": "user", "content": "prompt"}) + "\n")
        fh.write(json.dumps(msg) + "\n")
        # the CLI appends a message again when its tokens arrive: a reader must count it once
        msg = dict(msg, tokens={"input": 100, "output": 20, "cached": 40, "thoughts": 10, "tool": 0, "total": 130})
        fh.write(json.dumps(msg) + "\n")


def text_of(params):
    return "".join(b.get("text", "") for b in params.get("prompt", []) if isinstance(b, dict))


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    rid, method, params = req.get("id"), req.get("method"), req.get("params") or {}
    if method == "initialize":
        reply(rid, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True},
                    "authMethods": [{"id": "gemini-api-key", "name": "Gemini API key"}]})
    elif method == "authenticate":
        reply(rid, {})
    elif method == "session/new":
        if os.environ.get("GM_MODE") == "auth":
            fail(rid, -32000, "Authentication required.")
            continue
        log("session_cwd", params.get("cwd", ""))
        reply(rid, {"sessionId": "stub-session-1",
                    "modes": {"currentModeId": "default", "availableModes": [
                        {"id": "default", "name": "Default"}, {"id": "autoEdit", "name": "Auto Edit"},
                        {"id": "yolo", "name": "YOLO"}, {"id": "plan", "name": "Plan"}]},
                    "models": {"currentModelId": state["model"], "availableModels": [
                        {"modelId": state["model"], "name": state["model"]}]}})
    elif method == "session/set_model":
        state["model"] = params.get("modelId") or state["model"]
        log("set_model", state["model"])
        reply(rid, {})
    elif method == "session/set_mode":
        log("set_mode", params.get("modeId", ""))
        reply(rid, {})
    elif method == "session/prompt":
        state["prompts"] += 1
        # acpx starts a fresh agent process per call, so "the second prompt" is counted in a file
        counter = os.environ.get("GM_COUNT")
        if counter:
            try:
                n = int(open(counter).read() or 0)
            except (OSError, ValueError):
                n = 0
            state["prompts"] = n + 1
            with open(counter, "w") as fh:
                fh.write(str(state["prompts"]))
        mode = os.environ.get("GM_MODE", "ok")
        if mode == "auth":
            fail(rid, -32000, "Authentication required.")
            continue
        if mode == "ratelimit-partial" and state["prompts"] > 1:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "stub-session-1", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "VERDICT: APPR"}}}})
        if mode == "ratelimit" or (mode in ("ratelimit-real", "ratelimit-partial") and state["prompts"] > 1):
            fail(rid, -32603, "[429] You have exhausted your capacity on this model. Your quota will reset after 59m30s.",
                 {"status": 429})
            continue
        prompt = text_of(params)
        log("prompt_bytes", str(len(prompt)))
        if "PONG" in prompt and len(prompt) < 200:
            answer = "PONG"
        else:
            path = os.environ.get("GM_ANSWER_FILE")
            answer = open(path).read() if path else "VERDICT: APPROVE\n\n## Summary\nstub gemini review\n\n### Blocking\n- None.\n"
        record_answer(answer)
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "stub-session-1", "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": answer}}}})
        reply(rid, {"stopReason": "end_turn"})
    elif rid is not None:
        fail(rid, -32601, "Method not found: %s" % method)
