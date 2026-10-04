#!/usr/bin/env python3
"""Operator-owned access profiles: which account, billing class and credential an agent reaches its model by.

One immutable entry per kernel agent, in ~/.agent-comms/access.json (or $AGENT_COMMS_HOME/access.json).
The file is operator-owned, never read from the reviewed project, and loaded with the same rules as
agents.json. A second account, billing class, hosting service or credential is a second agent identity,
never a per-dispatch override. Values are data and references: a credential is `env:NAME` or
`keychain:service`, never a value.

This module also owns the credential scrub a bound review leg's child environment goes through
(see credential-env.tsv): the scrub set is configuration names UNION name patterns UNION a static table.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from agent_profiles import BUILTINS, NAME, ProfileError, canonical, fields, unique_object

TRANSPORTS = ("acp", "cli")
BILLINGS = ("subscription", "api", "local", "free")
ENTRY_KEYS = ("route_id", "transport", "provider", "account", "billing", "credential")
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
CREDENTIAL = re.compile(r"(env:[A-Z][A-Z0-9_]{0,127}|keychain:[A-Za-z0-9][A-Za-z0-9._-]{0,127})\Z")
# Name patterns for credentials nobody configured. Configuration names come first: an operator-chosen
# name (CODEX_METERED_KEY, MY_INFERENCE_KEY, API_KEY) survives any pattern list.
SCRUB_PATTERNS = tuple(re.compile(p, re.IGNORECASE) for p in
                       (r".*_API_KEY\Z", r".*_TOKEN\Z", r".*_AUTH_TOKEN\Z", r".*_SECRET.*", r".*_ACCESS_KEY.*"))
CAPABILITY_VERSION = 1
# The one name a PREPARED credential travels under, from the runner to a custom harness's launcher. It is
# deliberately not a credential-shaped name (nothing scrubs it, nothing configured can be it) and it is the
# only way a bound custom launch obtains its credential: the profile's own source and destination variables
# are scrubbed like every other, so an inherited value can never stand in for the bound reference.
PREPARED = "AGENT_COMMS_BOUND_CREDENTIAL"


def access_path():
    return Path(os.environ.get("AGENT_COMMS_HOME", str(Path.home() / ".agent-comms"))) / "access.json"


def table_path():
    return Path(__file__).resolve().parent / "credential-env.tsv"


def validate_entry(name, entry):
    fields(entry, ENTRY_KEYS, ENTRY_KEYS)
    for key in ("route_id", "provider", "account"):
        if not isinstance(entry[key], str) or not TOKEN.fullmatch(entry[key]):
            raise ProfileError(f"access entry for {name}: {key} must be a bare token")
    if entry["transport"] not in TRANSPORTS:
        raise ProfileError(f"access entry for {name}: transport must be one of {', '.join(TRANSPORTS)}")
    if entry["billing"] not in BILLINGS:
        raise ProfileError(f"access entry for {name}: billing must be one of {', '.join(BILLINGS)}")
    credential = entry["credential"]
    if credential is not None and (not isinstance(credential, str) or not CREDENTIAL.fullmatch(credential)):
        raise ProfileError(f"access entry for {name}: credential must be null or a reference (env:NAME or keychain:service), never a value")
    if (entry["billing"] == "api") != (credential is not None):
        raise ProfileError(f"access entry for {name}: an api route carries exactly one credential reference; every other billing class carries none")
    return {key: entry[key] for key in ENTRY_KEYS}


def digest(entry):
    return hashlib.sha256(canonical({key: entry[key] for key in ENTRY_KEYS}).encode()).hexdigest()


def load():
    """The access file read strictly, or {} when absent. No consistency with agents.json here."""
    path = access_path()
    if not path.exists() and not path.is_symlink():
        return {}
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o022:
        raise ProfileError(f"{path} must be a regular file, not writable by group or others")
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    fields(data, ("version", "agents"), ("version", "agents"))
    if type(data["version"]) is not int or data["version"] != 1 or not isinstance(data["agents"], dict):
        raise ProfileError("expected version 1 and an agents object")
    return {name: validate_entry(name, entry) for name, entry in data["agents"].items()}


def profile_reference(profile):
    """The single credential reference a custom profile declares, as `env:X` / `keychain:S`, or None."""
    credentials = profile.get("credentials", {})
    if not credentials:
        return None
    if len(credentials) != 1:
        raise ProfileError("a profile with more than one credential cannot carry an access profile")
    reference = next(iter(credentials.values()))
    return "env:" + reference["env"] if "env" in reference else "keychain:" + reference["keychain_service"]


def load_checked(profiles=None):
    """The access file read together with agents.json: the one validation `agents --access`, bound
    dispatch, `review-route plan` and the run-time re-check all use, so they cannot disagree."""
    if profiles is None:
        from agent_profiles import load as load_profiles
        profiles = load_profiles()
    entries = load()
    known = set(BUILTINS) | set(profiles)
    for name, entry in entries.items():
        base = name[:-len("-review")] if name.endswith("-review") else name
        if base not in known or (base != name and not NAME.fullmatch(base) and base not in BUILTINS):
            raise ProfileError(f"access entry for unknown agent: {name}")
        if base != name:
            # A review twin shares its driver's provider and account: the same entry, or none.
            if entries.get(base) != entry:
                raise ProfileError(f"access entry for {name} differs from (or has no) entry for {base}: a twin shares its driver's access")
            continue
        profile = profiles.get(name)
        if profile is None:
            continue
        if profile.get("api_provider") and profile["api_provider"] != entry["provider"]:
            raise ProfileError(f"access entry for {name}: provider {entry['provider']} is not the profile's api_provider {profile['api_provider']}")
        reference = profile_reference(profile)
        if entry["billing"] == "api":
            if reference is None:
                raise ProfileError(f"access entry for {name}: billing api, but the profile declares no credential")
            if reference != entry["credential"]:
                raise ProfileError(f"access entry for {name}: credential is not the profile's declared credential reference")
        elif reference is not None:
            raise ProfileError(f"access entry for {name}: billing {entry['billing']}, but the profile declares a credential")
    routes = {}
    for name, entry in entries.items():
        other = routes.setdefault(entry["route_id"], (name, entry))
        if other[1] != entry:
            raise ProfileError(f"agents {other[0]} and {name} share route_id {entry['route_id']} but differ in another access field: a route is one identity")
    return entries


def effective_entry(agent, entries):
    """The entry an agent runs under: its own, or — for a review twin with none — its driver's."""
    if agent in entries:
        return entries[agent]
    if agent.endswith("-review"):
        return entries.get(agent[:-len("-review")])
    return None


def table():
    """credential-env.tsv: (scrub names, scrub prefixes, auth rows keyed by (adapter, billing))."""
    names, prefixes, auth = set(), [], {}
    path = table_path()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if cols[0] == "scrub" and len(cols) == 2 and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", cols[1]):
            names.add(cols[1])
        elif cols[0] == "scrub-prefix" and len(cols) == 2 and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", cols[1]):
            prefixes.append(cols[1])
        elif cols[0] == "auth" and len(cols) == 8 and cols[3] in ("supported", "unsupported") and cols[2] in BILLINGS:
            auth[(cols[1], cols[2])] = {"status": cols[3], "consumed": None if cols[4] == "-" else cols[4],
                                        "login_files": [] if cols[5] == "-" else cols[5].split(","),
                                        "selector": None if cols[6] == "-" else cols[6], "notes": cols[7]}
        else:
            raise ProfileError(f"{path}: malformed row {number}")
    return names, prefixes, auth


def auth_row(adapter, billing):
    row = table()[2].get((adapter, billing))
    if row is None:
        raise ProfileError(f"no auth-route row for {adapter}/{billing}")
    return row


def adapter_of(agent, provider, profiles):
    """`codex` / `gemini` for a built-in provider, `opencode` for a custom profile that runs it, else None."""
    if provider in ("codex", "gemini"):
        return provider
    profile = profiles.get(provider)
    if profile is not None and profile["adapter"] == "opencode":
        return "opencode"
    return None


def configured_names(entries, profiles):
    """Every credential name configuration can mention. Computed from the files dispatch validated, so a
    name that can be configured as a credential cannot be missing from the scrub."""
    names = set(table()[0]) | {PREPARED}
    for entry in entries.values():
        if entry["credential"] and entry["credential"].startswith("env:"):
            names.add(entry["credential"][4:])
    for profile in profiles.values():
        for variable, reference in profile.get("credentials", {}).items():
            names.add(variable)
            if "env" in reference:
                names.add(reference["env"])
        connection = profile.get("connection")
        if connection:
            names.add(connection["api_key_env"])
    for (_adapter, _billing), row in table()[2].items():
        if row["consumed"]:
            names.add(row["consumed"])
    return names


def scrub_list(environ, entries, profiles, keep=()):
    """The environment variable names present in `environ` that a bound leg must not inherit."""
    names = configured_names(entries, profiles)
    prefixes = tuple(table()[1])
    result = []
    for name in sorted(environ):
        if name in keep:
            continue
        if name in names or (prefixes and name.startswith(prefixes)):
            result.append(name)
        elif any(p.fullmatch(name) for p in SCRUB_PATTERNS):
            result.append(name)
    return result


def resolve_reference(reference, environ):
    """A credential reference resolved to its value. The value is never printed or logged here."""
    kind, _, source = reference.partition(":")
    if kind == "env":
        return environ.get(source, "")
    if sys.platform != "darwin":
        return ""
    response = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", source, "-w"],
                              capture_output=True, text=True, timeout=15)
    return response.stdout.rstrip("\n") if response.returncode == 0 else ""


def credential_present(reference, environ):
    """Presence only. A keychain reference is checked without reading its value where the platform allows."""
    kind, _, source = reference.partition(":")
    if kind == "env":
        return bool(environ.get(source))
    if sys.platform != "darwin":
        return False
    return subprocess.run(["/usr/bin/security", "find-generic-password", "-s", source],
                          capture_output=True, timeout=15).returncode == 0


def bound_environment(environ, profile=None, entries=None, profiles=None):
    """THE one function that computes a bound custom leg's child environment (bound_leg_env).

    Scrub first (every configured and pattern-shaped credential name, the profile's own source and
    destination variables included), then restore only the leg's own credential. That credential was
    resolved ONCE by the runner from the bound reference and arrives under PREPARED; an inherited value
    under the profile's own variable names is never a substitute, so an ambient key cannot override a
    bound Keychain reference. `profile` is a custom profile; None restores nothing."""
    if entries is None or profiles is None:
        from agent_profiles import load as load_profiles
        profiles = load_profiles()
        entries = load_checked(profiles)
    prepared = environ.get(PREPARED, "")
    result = {k: v for k, v in environ.items() if k != PREPARED and k not in scrub_list(environ, entries, profiles)}
    if profile is not None and profile.get("credentials"):
        if len(profile["credentials"]) != 1 or not prepared:
            raise ProfileError("the bound credential was not prepared for this launch; no value was logged")
        result[next(iter(profile["credentials"]))] = prepared
    return result


def env_plan(agent, adapter, billing, environ, profile=None, entries=None, profiles=None):
    """What the runner does to a bound leg's inherited environment, as data: the names to unset and the
    destination variable the leg's own credential is exported under. No value appears in the plan."""
    if entries is None or profiles is None:
        from agent_profiles import load as load_profiles
        profiles = load_profiles()
        entries = load_checked(profiles)
    keep = set()
    destination = None
    if profile is not None:
        # A custom harness receives its one credential under PREPARED; every name its mapping reads or
        # writes is unset like any other credential.
        if profile.get("credentials"):
            destination = PREPARED
            keep.add(PREPARED)
    elif billing == "api":
        # A built-in adapter's own credential is exported by the runner under the name the adapter reads,
        # over whatever the environment held; nothing else configured survives.
        destination = auth_row(adapter, billing)["consumed"]
        if destination:
            keep.add(destination)
    return {"unset": scrub_list(environ, entries, profiles, keep=keep), "destination": destination}


def show(agent, entries):
    entry = effective_entry(agent, entries)
    if entry is None:
        return None
    return {"agent": agent, **entry, "access_digest": digest(entry)}


def line(view):
    return ("access v1 agent=%s route_id=%s transport=%s provider=%s account=%s billing=%s credential=%s access_digest=%s"
            % (view["agent"], view["route_id"], view["transport"], view["provider"], view["account"],
               view["billing"], view["credential"] or "-", view["access_digest"]))


def main():
    args = sys.argv[1:]
    if not args:
        raise ProfileError("expected an access operation")
    operation, args = args[0], args[1:]
    if operation == "show":
        as_json = "--json" in args
        args = [a for a in args if a != "--json"]
        view = show(args[0], load_checked())
        if view is None:
            raise ProfileError(f"no access profile for {args[0]}")
        print(canonical(view) if as_json else line(view))
    elif operation == "check":
        load_checked()
    elif operation == "scrub-set":
        from agent_profiles import load as load_profiles
        profiles = load_profiles()
        entries = load_checked(profiles)
        for name in sorted(configured_names(entries, profiles)):
            print(name)
    elif operation == "env-plan":
        # env-plan <agent> <adapter> <billing>: `unset<TAB>NAME` lines, then `credential<TAB>DEST` when the
        # runner must export the leg's own credential. Names only: a value never appears here.
        from agent_profiles import load as load_profiles
        agent, adapter, billing = args[:3]
        profiles = load_profiles()
        entries = load_checked(profiles)
        profile = profiles.get(agent) if adapter == "opencode" else None
        plan = env_plan(agent, adapter, billing, os.environ, profile, entries, profiles)
        for name in plan["unset"]:
            print(f"unset\t{name}")
        if plan["destination"]:
            print(f"credential\t{plan['destination']}")
    elif operation == "credential-value":
        # credential-value <agent> --stamp S --digest D: the credential the STAMP bound, resolved from the
        # reference the stamped (validated) access snapshot carries — never from whatever the access file
        # says now. A current entry that no longer matches the stamp's digest is drift: refuse. Stdout only.
        import leg_binding
        stamp = leg_binding.stamp_decode(leg_binding.option(args, "--stamp"), leg_binding.option(args, "--digest"))
        agent = args[0]
        if stamp["agent"] != agent:
            raise ProfileError("the leg binding names a different agent")
        entry = effective_entry(agent, load_checked())
        if entry is None or digest(entry) != stamp["access_digest"]:
            raise ProfileError("the access profile changed since dispatch; refusing to prepare a credential")
        reference = stamp["access"]["credential"]
        if reference is None:
            raise ProfileError("the bound leg carries no credential reference")
        value = resolve_reference(reference, os.environ)
        if not value:
            raise ProfileError("credential unavailable; no value was logged")
        sys.stdout.write(value)
    elif operation == "auth-row":
        row = auth_row(args[0], args[1])
        print("\t".join([row["status"], row["consumed"] or "-", ",".join(row["login_files"]) or "-", row["selector"] or "-", row["notes"]]))
    else:
        raise ProfileError(f"unknown access operation: {operation}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError, OSError, subprocess.SubprocessError) as error:
        print(f"access profiles: {error}", file=sys.stderr)
        sys.exit(1)
