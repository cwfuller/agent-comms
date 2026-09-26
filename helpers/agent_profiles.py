#!/usr/bin/env python3
"""Operator-owned agent profiles. Values are data; commands are argv, never shell."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys

BUILTINS = ("claude", "codex", "grok")
NAME = re.compile(r"[a-z][a-z0-9-]{1,15}\Z")
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,255}\Z")
FAMILY = re.compile(r"[a-z][a-z0-9-]{1,63}\Z")


class ProfileError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProfileError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def fields(value, allowed, required=()):
    if not isinstance(value, dict):
        raise ProfileError("expected a JSON object")
    unknown = set(value) - set(allowed)
    missing = set(required) - set(value)
    if unknown or missing:
        raise ProfileError(f"unknown fields {sorted(unknown)}; missing fields {sorted(missing)}")


def text(value):
    if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ProfileError("expected nonempty text without control characters")
    return value


def validate(name, profile):
    if not isinstance(name, str) or not NAME.fullmatch(name) or name in BUILTINS or name.endswith("-review"):
        raise ProfileError(f"invalid or reserved custom agent name: {name}")
    fields(profile, ("adapter", "command", "family", "model", "api_provider", "credentials", "connection", "runtime_version"),
           ("adapter", "command", "family", "model"))
    if profile["adapter"] not in ("acp", "opencode"):
        raise ProfileError("adapter must be acp or opencode")
    if not FAMILY.fullmatch(text(profile["family"])) or not TOKEN.fullmatch(text(profile["model"])):
        raise ProfileError("invalid model or family token")
    command = profile["command"]
    if not isinstance(command, list) or not command or len(command) > 64:
        raise ProfileError("command must be a nonempty argv array (maximum 64 arguments)")
    for arg in command:
        text(arg)
    if not Path(command[0]).is_absolute() and "/" in command[0]:
        raise ProfileError("command executable must be absolute or a name on PATH")
    if "api_provider" in profile and not TOKEN.fullmatch(text(profile["api_provider"])):
        raise ProfileError("invalid api_provider token")
    creds = profile.get("credentials", {})
    if not isinstance(creds, dict):
        raise ProfileError("credentials must map environment names to references")
    for variable, reference in creds.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", variable) or variable in ("HOME", "PATH", "PWD", "BASH_ENV", "ENV", "PYTHONPATH") or variable.startswith(("COMMS_", "OPENCODE_", "XDG_", "LD_", "DYLD_", "NODE_")):
            raise ProfileError("invalid credential environment name")
        fields(reference, ("env", "keychain_service"))
        if len(reference) != 1:
            raise ProfileError("credential requires exactly one env or keychain_service reference")
        text(next(iter(reference.values())))
        if "env" in reference and not re.fullmatch(r"[A-Z][A-Z0-9_]*", reference["env"]):
            raise ProfileError("invalid credential source environment name")
    if profile["adapter"] == "acp":
        if "connection" in profile or "runtime_version" in profile:
            raise ProfileError("this adapter does not support connection or runtime_version")
    else:
        from opencode_adapter import validate_profile
        validate_profile(profile)
    return profile


def config_path():
    return Path(os.environ.get("AGENT_COMMS_HOME", str(Path.home() / ".agent-comms"))) / "agents.json"


def load():
    path = config_path()
    if not path.exists() and not path.is_symlink():
        return {}
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o022:
        raise ProfileError(f"{path} must be a regular file, not writable by group or others")
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    fields(data, ("version", "agents"), ("version", "agents"))
    if type(data["version"]) is not int or data["version"] != 1 or not isinstance(data["agents"], dict):
        raise ProfileError("expected version 1 and an agents object")
    return {name: validate(name, p) for name, p in data["agents"].items()}


def resolve(name):
    profiles = load()
    if name not in profiles:
        raise ProfileError(f"no operator profile for {name}")
    p = dict(profiles[name])
    executable = shutil.which(p["command"][0])
    if not executable:
        raise ProfileError(f"runtime executable not found for {name}: {p['command'][0]}")
    p["command"] = [str(Path(executable).absolute()), *p["command"][1:]]
    return {"name": name, "profile": p}


def encode(binding):
    return base64.urlsafe_b64encode(canonical(binding).encode()).decode()


def decode(encoded):
    if not encoded or len(encoded) > 32768:
        raise ProfileError("missing or oversized agent profile binding")
    binding = json.loads(base64.b64decode(encoded, altchars=b"-_", validate=True), object_pairs_hook=unique_object)
    fields(binding, ("name", "profile"), ("name", "profile"))
    validate(binding["name"], binding["profile"])
    if encode(binding) != encoded:
        raise ProfileError("agent profile binding is not canonical")
    return binding


def digest(binding):
    return hashlib.sha256(canonical(binding).encode()).hexdigest()


def credentials(profile, environment):
    result = dict(environment)
    for variable, reference in profile.get("credentials", {}).items():
        if "env" in reference:
            secret = environment.get(reference["env"], "")
        else:
            if sys.platform != "darwin":
                raise ProfileError("keychain_service credentials require macOS; use an env reference here")
            response = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", reference["keychain_service"], "-w"],
                                      capture_output=True, text=True, timeout=15)
            secret = response.stdout.rstrip("\n") if response.returncode == 0 else ""
        if not secret:
            raise ProfileError(f"credential unavailable for {variable}; no value was logged")
        result[variable] = secret
    return result


BINDING_FIELDS = ("agent_profile", "agent_profile_digest", "review_family", "review_model")


def frontmatter(path):
    lines = Path(path).read_text().splitlines()
    result = {}
    if not lines or lines[0] != "---":
        raise ProfileError("message has no frontmatter")
    for line in lines[1:]:
        if line == "---":
            return result
        key, separator, value = line.partition(":")
        if separator:
            if key in result and key in (*BINDING_FIELDS, "from", "in-reply-to"):
                raise ProfileError(f"duplicate message field: {key}")
            result[key] = value.strip()
    raise ProfileError("message frontmatter is not closed")


def message_binding(path, request=None):
    fm = frontmatter(path)
    binding = decode(fm.get("agent_profile", ""))
    profile = binding["profile"]
    expected = {"agent_profile_digest": digest(binding), "review_family": profile["family"], "review_model": profile["model"]}
    if any(fm.get(k) != v for k, v in expected.items()):
        raise ProfileError("profile/family/model binding does not match its digest")
    if fm.get("type") == "review-feedback":
        if fm.get("from") not in (binding["name"], binding["name"] + "-review"):
            raise ProfileError("reply identity does not match its execution profile")
        if not request:
            raise ProfileError("profile reply needs its retained request")
        req = frontmatter(request)
        if req.get("type") != "review-request" or req.get("message_id") != fm.get("in-reply-to"):
            raise ProfileError("profile reply does not answer this review request")
        if any(req.get(k) != fm.get(k) for k in BINDING_FIELDS):
            raise ProfileError("reply changed the request's agent profile binding")
    return binding


def acpx_arguments(binding, state_home, argv):
    """Translate the existing named-profile call shape to acpx's raw-agent shape."""
    marker = "agent-comms-custom"
    if marker not in argv:
        raise ProfileError("custom ACP invocation has no profile marker")
    index = argv.index(marker)
    before, after = argv[:index], argv[index + 1:]
    session_args = []
    if after[:1] in (["-s"], ["--session"]):
        if len(after) < 3:
            raise ProfileError("custom ACP invocation has no operation")
        session_args, after = after[:2], after[2:]
    operations = ("sessions", "set-mode", "set", "status", "cancel", "exec", "prompt")
    if after and after[0] in operations:
        after = [after[0], *session_args, *after[1:]]
    else:
        after = ["prompt", *session_args, *after]
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), "serve", encode(binding), state_home])
    # A raw --agent wins over project/global agent mappings. Never inherit client MCP servers.
    home = Path(state_home)
    from profile_io import private_directory, place
    private_directory(home)
    place(home / "mcp.json", {"mcpServers": []})
    return [*before, "--agent", command, "--model", binding["profile"]["model"],
            "--no-terminal", "--no-fs", "--mcp-config", str(home / "mcp.json"), *after]


def model_check(binding, record):
    """ACP control-plane confirmation, not a claim of inference-provider attestation."""
    state = record.get("acpx", record)
    wanted = binding["profile"]["model"]
    current = state.get("current_model_id", state.get("currentModelId"))
    options = state.get("config_options", state.get("configOptions", []))
    for option in options:
        if option.get("category") == "model" or option.get("id") == "model":
            if option.get("currentValue") != wanted:
                raise ProfileError("ACP model option disagrees with the configured pin")
            current = option["currentValue"]
    if current != wanted:
        raise ProfileError("ACP did not confirm the configured model pin")
    if binding["profile"]["adapter"] == "opencode":
        from opencode_adapter import check_session
        check_session(state, wanted, options)
    return {"model": wanted, "evidence": "acp-session-control", "inference_attested": False}


def main():
    args = sys.argv[1:]
    if not args:
        raise ProfileError("expected a profile operation")
    operation, args = args[0], args[1:]
    if operation == "names":
        print(" ".join(load()))
    elif operation == "field":
        name, key = args
        profile = load().get(name)
        if profile is None:
            raise ProfileError(f"no operator profile for {name}")
        print(profile[key])
    elif operation == "binding":
        print(encode(resolve(args[0])))
    elif operation == "binding-field":
        binding = decode(args[0])
        key = args[1]
        print(digest(binding) if key == "digest" else binding["name"] if key == "name" else binding["profile"][key])
    elif operation == "state-home":
        binding = decode(args[0])
        root = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
        workspace = hashlib.sha256(os.getcwd().encode()).hexdigest()[:20]
        print((root / "agent-comms/profiles" / workspace / digest(binding)).absolute())
    elif operation == "check-binding":
        binding = decode(args[0])
        if args[1] not in (binding["name"], binding["name"] + "-review") or resolve(binding["name"]) != binding:
            raise ProfileError("agent profile changed since dispatch; send a new request")
    elif operation == "message-check":
        binding = message_binding(args[0], args[1] if len(args) > 1 else None)
        print(binding["profile"]["family"])
    elif operation == "model-check":
        print(canonical(model_check(decode(args[0]), json.load(sys.stdin))))
    elif operation == "result":
        directory = Path(args[0])
        path = directory / "agent-profile.b64"
        if not path.exists():
            print("null")
        else:
            binding = decode(path.read_text().strip())
            evidence = directory / "profile-evidence.json"
            print(canonical({"name": binding["name"], "digest": digest(binding),
                             "family": binding["profile"]["family"], "model": binding["profile"]["model"],
                             "adapter": binding["profile"]["adapter"],
                             "observed": json.loads(evidence.read_text()) if evidence.exists() and evidence.stat().st_size else None}))
    elif operation == "attest":
        binding = decode(args[0])
        if binding["profile"]["adapter"] != "opencode":
            raise ProfileError("no runtime model attestation for this adapter")
        from opencode_adapter import attest
        print(canonical(attest(binding["profile"], args[1], credentials(binding["profile"], os.environ),
                               json.load(sys.stdin), args[2], args[3])))
    elif operation == "acpx":
        encoded, state_home, *argv = args
        split = argv.index("--")
        launcher, arguments = argv[:split], argv[split + 1:]
        command = [*launcher, *acpx_arguments(decode(encoded), state_home, arguments)]
        os.execvpe(command[0], command, {**os.environ, "PWD": os.getcwd()})
    elif operation == "serve":
        binding = decode(args[0])
        profile = binding["profile"]
        env = credentials(profile, os.environ)
        env["PWD"] = os.getcwd()
        if profile["adapter"] == "opencode":
            from opencode_adapter import launch
            launch(profile, args[1], env)
        else:
            os.execvpe(profile["command"][0], profile["command"], env)
    else:
        raise ProfileError(f"unknown profile operation: {operation}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError, OSError, subprocess.SubprocessError) as error:
        print(f"agent profiles: {error}", file=sys.stderr)
        sys.exit(1)
