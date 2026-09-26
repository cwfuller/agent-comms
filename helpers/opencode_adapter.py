"""OpenCode ACP adapter: an isolated read/search-only profile, with a pinned runtime."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from profile_io import private_directory, place

VERSION = "1.18.32"
MODE = "comms-review"


def validate_profile(profile):
    # Adapter-specific values stay out of the registry and the generic ACP launcher.
    from agent_profiles import fields, text, ProfileError
    from urllib.parse import urlsplit
    import re
    if len(profile["command"]) != 1 or "/" not in profile["model"]:
        raise ProfileError("opencode requires one executable and a provider/model pin")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", text(profile.get("runtime_version"))):
        raise ProfileError("opencode requires an explicit runtime_version")
    connection = profile.get("connection")
    if connection is None:
        return
    keys = ("base_url", "api_key_env", "context", "output")
    fields(connection, keys, keys)
    url = urlsplit(text(connection["base_url"]))
    if url.scheme not in ("https", "http") or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ProfileError("connection needs an HTTP(S) base URL without credentials/query/fragment")
    if url.scheme == "http" and url.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise ProfileError("plain HTTP is allowed only for local inference")
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", text(connection["api_key_env"])):
        raise ProfileError("invalid API key environment reference")
    for key in ("context", "output"):
        if type(connection[key]) is not int or not 0 < connection[key] <= 10_000_000:
            raise ProfileError(f"invalid connection {key}")


def check_runtime_profile(profile):
    if profile["runtime_version"] != VERSION:
        raise ValueError(f"opencode containment requires runtime_version {VERSION}")


def check_session(state, wanted, options):
    modes = [o for o in options if o.get("id") == "mode"]
    if (state.get("available_models") != [wanted] or len(modes) != 1
            or modes[0].get("currentValue") != MODE
            or [o.get("value") for o in modes[0].get("options", [])] != [MODE]):
        raise ValueError("OpenCode must expose exactly the pinned model and the read-only reviewer mode")


def config(profile):
    provider, model = profile["model"].split("/", 1)
    entry = {"whitelist": [model]}
    connection = profile.get("connection")
    if connection:
        entry.update({
            "npm": "@ai-sdk/openai-compatible",
            "name": provider,
            "options": {"baseURL": connection["base_url"], "apiKey": "{env:" + connection["api_key_env"] + "}"},
            "models": {model: {"name": model, "limit": {"context": connection["context"], "output": connection["output"]}}},
        })
    permission = {"*": "deny", "read": "allow", "glob": "allow", "grep": "allow", "external_directory": "deny"}
    return {
        "model": profile["model"], "small_model": profile["model"],
        "default_agent": MODE, "enabled_providers": [provider], "provider": {provider: entry},
        "permission": permission,
        "agent": {**{name: {"disable": True} for name in ("build", "plan", "general", "explore")},
                  MODE: {"mode": "primary", "model": profile["model"], "permission": permission}},
        "share": "disabled", "autoupdate": False, "snapshot": False, "lsp": False,
        "formatter": False, "plugin": [], "mcp": {},
    }


def environment(profile, state_home, inherited):
    check_runtime_profile(profile)
    root = private_directory(state_home)
    env = {k: v for k, v in inherited.items() if not k.startswith("OPENCODE_")}
    for key, folder in (("CONFIG", "config"), ("DATA", "data"), ("STATE", "state"), ("CACHE", "cache")):
        env[f"XDG_{key}_HOME"] = str(private_directory(root / folder))
    env.update({
        "OPENCODE_TEST_HOME": str(private_directory(root / "home")),
        "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_DISABLE_AUTOUPDATE": "1",
        "OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER": "1",
        "OPENCODE_SERVER_PASSWORD": secrets.token_hex(32), "PWD": os.getcwd(),
    })
    if profile.get("connection") and not env.get(profile["connection"]["api_key_env"]):
        raise ValueError("configured inference credential is unavailable")
    config_dir = private_directory(root / "config" / "opencode")
    place(config_dir / "opencode.json", config(profile))
    version = subprocess.run([profile["command"][0], "--version"], env=env, capture_output=True, text=True, timeout=15)
    if version.returncode or version.stdout.strip() != VERSION:
        raise ValueError(f"OpenCode reviewer requires verified runtime {VERSION}")
    return env


def check_tree(directory):
    """The runtime's read tool checks lexical paths, so reject escaping symlinks."""
    root = Path(directory).resolve(strict=True)
    def unreadable(error):
        raise ValueError("cannot inspect reviewer tree for escaping symlinks") from error
    for parent, directories, files in os.walk(root, followlinks=False, onerror=unreadable):
        for name in [*directories, *files]:
            path = Path(parent) / name
            if not path.is_symlink():
                continue
            try:
                target = path.resolve(strict=True)
            except (OSError, RuntimeError) as error:
                raise ValueError(f"cannot resolve reviewer symlink: {path.relative_to(root)}") from error
            try:
                target.relative_to(root)
            except ValueError:
                raise ValueError(f"reviewer tree contains an escaping symlink: {path.relative_to(root)}")


def launch(profile, state_home, inherited):
    check_tree(os.getcwd())
    env = environment(profile, state_home, inherited)
    command = [profile["command"][0], "acp", "--pure", "--cwd", os.getcwd()]
    os.execve(command[0], command, env)


def attest(profile, state_home, inherited, record, snapshot, phase):
    """Check newly appended assistant records, not merely the requested ACP preference."""
    session = record.get("acpSessionId", record.get("acp_session_id"))
    if not isinstance(session, str) or not session.startswith("ses_") or not session.isascii() or not session.replace("_", "").isalnum():
        raise ValueError("missing OpenCode session identity for model evidence")
    env = environment(profile, state_home, inherited)
    # OpenCode 1.18.32 exits before a large piped stdout buffer is flushed. A
    # private, anonymous regular file receives the complete export synchronously.
    with tempfile.TemporaryFile(mode="w+b") as output:
        exported = subprocess.run([profile["command"][0], "export", session], env=env,
                                  stdout=output, stderr=subprocess.PIPE, timeout=30)
        if exported.returncode:
            raise ValueError("could not export OpenCode's model evidence")
        output.seek(0)
        data = json.load(output)
    if data.get("info", {}).get("id") != session:
        raise ValueError("OpenCode export belongs to a different session")
    messages = [m["info"] for m in data.get("messages", []) if m.get("info", {}).get("role") == "assistant"]
    ids = [m["id"] for m in messages]
    snapshot = Path(snapshot)
    if phase == "before":
        place(snapshot, {"session": session, "ids": ids})
        return {"session": session, "assistant_records_before": len(ids)}
    before = json.loads(snapshot.read_text())
    if before.get("session") != session or not set(before["ids"]).issubset(ids):
        raise ValueError("OpenCode session history changed or was replaced during the turn")
    fresh = [m for m in messages if m["id"] not in before["ids"]]
    if not fresh:
        raise ValueError("no new OpenCode assistant model evidence")
    for message in fresh:
        observed = message.get("providerID", "") + "/" + message.get("modelID", "")
        if observed != profile["model"] or message.get("sessionID") != session or message.get("agent") != MODE:
            raise ValueError("OpenCode ran a different model, session, or reviewer mode")
    return {"model": profile["model"], "session": session, "mode": MODE,
            "evidence": "opencode-assistant-records", "assistant_records": len(fresh),
            "message_ids": [m["id"] for m in fresh]}
