#!/usr/bin/env python3
"""The prompt half of an acpx stand-in: drive `gemini --acp` (found on PATH, as acpx's `gemini` profile
does) through one ACP turn and behave like `acpx --format quiet` — the answer on stdout and exit 0, or a
diagnostic on stderr and exit 1 when the agent refuses.

  acpx_lite.py <model|-> <prompt-file|-> [prompt words...]
"""
import json
import os
import subprocess
import sys

model, pfile = sys.argv[1], sys.argv[2]
text = open(pfile).read() if pfile != "-" else " ".join(sys.argv[3:])
proc = subprocess.Popen(["gemini", "--acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
nid = [0]


def call(method, params):
    nid[0] += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": nid[0], "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    chunks = []
    while True:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit(_die("the agent exited without answering %s" % method))
        msg = json.loads(line)
        if msg.get("method") == "session/update":
            u = msg["params"]["update"]
            if u.get("sessionUpdate") == "agent_message_chunk":
                chunks.append(u["content"].get("text", ""))
            continue
        if msg.get("id") == nid[0]:
            if "error" in msg:
                e = msg["error"]
                raise SystemExit(_die("%s (code %s)%s" % (e.get("message"), e.get("code"),
                                                          " " + json.dumps(e["data"]) if "data" in e else "")))
            return msg["result"], "".join(chunks)


def _die(message):
    sys.stderr.write("[error] RUNTIME PROMPT_FAILED: %s\n" % message)
    try:
        proc.kill()
    except OSError:
        pass
    return 1


call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
res, _ = call("session/new", {"cwd": os.getcwd(), "mcpServers": []})
if model != "-":
    call("session/set_model", {"sessionId": res["sessionId"], "modelId": model})
_, out = call("session/prompt", {"sessionId": res["sessionId"], "prompt": [{"type": "text", "text": text}]})
sys.stdout.write(out + ("" if out.endswith("\n") else "\n"))
proc.stdin.close()
proc.wait(timeout=10)
