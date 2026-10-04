#!/usr/bin/env python3
"""Exact per-leg binding for `panel dispatch --bindings` (capability layer, Slice 7.4).

The caller names, per review leg, the exact model, native effort and expected access profile; this
either runs exactly that or refuses. It never reclassifies a tier, picks a route or substitutes a
pair. ONE function (`check_leg`) judges a leg, and `panel dispatch`, `review-route plan` and the
runner's run-time re-check all call it, so a plan can never promise what dispatch refuses and a
leg whose configuration changed after dispatch refuses itself instead of running something else.

Evidence is never invented: an `observed` value is read from the harness's own record and left null
where there is none, never copied from `expected`; a quota state is explicit; no reset time is
manufactured; no credential value is read for a check except to prove it is present.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import access_profiles as access
from agent_profiles import ProfileError, canonical, fields, load as load_profiles, unique_object

SCHEMA = "leg-bindings/1"
CAPABILITY_VERSION = 1
ROUTE_VIEW_VERSION = 2
LEG_METADATA_VERSION = 1
MAX_BYTES = 65536
MAX_LEGS = 16
REF = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,127}\Z")
MODEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/:@+\-]{0,255}\Z")
EFFORT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._\-]{0,63}\Z")
ACCESS_KEYS = ("transport", "provider", "account", "billing", "credential")
LEG_KEYS = ("ref", "agent", "role", "requirement", "route_id", "model", "effort", "access")
ROLES = ("gate", "extra")
REQUIREMENTS = ("required", "optional")
ZERO_DIGEST = "0" * 64
MOUNTED = "acp-mounted"

# The refusal codes, in one place. A caller keys on these; the detail wording may change.
CODES = ("agent-unbindable", "no-access-profile", "access-incomplete", "route-mismatch", "transport-mismatch",
         "provider-mismatch", "account-mismatch", "billing-mismatch", "credential-mismatch", "model-unservable",
         "model-mismatch", "effort-refused", "effort-mismatch", "capability-unsupported", "auth-login-missing",
         "auth-selected-type-conflict", "auth-route-unsupported", "credential-unavailable", "pin-conflict")
API_MODES = ("apikey", "api")


def acp_path():
    return Path(__file__).resolve().parent / "acp.sh"


def clean(text, limit=300):
    return re.sub(r"[^\x20-\x7e]+", " ", str(text)).strip()[:limit]


def parse(path):
    """The leg-bindings file: strict JSON, unique keys, bounded. Any defect is a usage error."""
    path = Path(path)
    if not path.is_file():
        raise ProfileError(f"no such bindings file: {clean(path)}")
    raw = path.read_bytes()
    if len(raw) > MAX_BYTES:
        raise ProfileError(f"bindings file is larger than {MAX_BYTES} bytes")
    data = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    fields(data, ("schema", "legs"), ("schema", "legs"))
    if data["schema"] != SCHEMA:
        raise ProfileError(f"bindings schema must be {SCHEMA}")
    legs = data["legs"]
    if not isinstance(legs, list) or not 1 <= len(legs) <= MAX_LEGS:
        raise ProfileError(f"bindings must list 1 to {MAX_LEGS} legs")
    seen, refs = set(), set()
    for leg in legs:
        fields(leg, LEG_KEYS, tuple(k for k in LEG_KEYS if k != "access"))
        if not isinstance(leg["agent"], str) or not re.fullmatch(r"[a-z][a-z0-9-]{1,15}(-review)?", leg["agent"]):
            raise ProfileError("leg agent is not a valid agent name")
        if not isinstance(leg["ref"], str) or not REF.fullmatch(leg["ref"]):
            raise ProfileError("leg ref must be a bare token")
        if leg["role"] not in ROLES or leg["requirement"] not in REQUIREMENTS:
            raise ProfileError("leg role is gate|extra and requirement is required|optional")
        if not isinstance(leg["route_id"], str) or not access.TOKEN.fullmatch(leg["route_id"]):
            raise ProfileError("leg route_id must be a bare token")
        if not isinstance(leg["model"], str) or not MODEL.fullmatch(leg["model"]):
            raise ProfileError("leg model must be a bare token")
        if leg["effort"] is not None and (not isinstance(leg["effort"], str) or not EFFORT.fullmatch(leg["effort"])):
            raise ProfileError("leg effort must be null or a bare token")
        if "access" in leg and not isinstance(leg["access"], dict):
            raise ProfileError("leg access must be an object")
        if leg.get("access"):
            unknown = set(leg["access"]) - set(ACCESS_KEYS)
            if unknown:
                raise ProfileError(f"leg access has unknown fields {sorted(unknown)}")
        if leg["agent"] in seen or leg["ref"] in refs:
            raise ProfileError("a leg agent or ref is listed twice")
        seen.add(leg["agent"]); refs.add(leg["ref"])
    return legs


def parse_ctx(values):
    """`agent:provider:transport` triples the shell resolved from the registry."""
    result = {}
    for value in values:
        agent, provider, transport = value.split(":")
        result[agent] = {"provider": provider, "transport": transport}
    return result


def classify(provider, transport, profiles):
    """(adapter, None) for an agent a mounted ACP runner can bind, else (None, reason)."""
    if transport == "mailbox":
        return None, "mailbox: nobody drives a mailbox leg"
    if transport != "acp":
        return None, f"{transport}: the detached CLI runner applies no attested model policy"
    if provider in ("claude", "grok"):
        return None, f"{provider}-unsupported: no applied and attested model/effort policy exists"
    if provider in ("codex", "gemini"):
        return provider, None
    profile = profiles.get(provider)
    if profile is None:
        return None, f"no operator profile for {provider}"
    if profile["adapter"] != "opencode":
        return None, f"consult-only: the {profile['adapter']} adapter has no mounted review runner"
    return "opencode", None


# ---------------------------------------------------------------- authentication-route observation

def login_mode(path):
    """The machine-readable auth-mode field of a saved codex login, or None. The secret is never read out."""
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    mode = data.get("auth_mode") if isinstance(data, dict) else None
    if isinstance(mode, str):
        return re.sub(r"[^a-z]", "", mode.lower())
    if isinstance(data, dict) and isinstance(data.get("OPENAI_API_KEY"), str) and data["OPENAI_API_KEY"] \
            and not isinstance(data.get("tokens"), dict):
        return "apikey"
    return None


def codex_home(environ):
    return Path(environ.get("CODEX_HOME") or (Path(environ.get("HOME", "")) / ".codex"))


def gemini_dir(environ):
    return Path(environ.get("GEMINI_CLI_HOME") or environ.get("HOME", "")) / ".gemini"


def operator_gemini_type(environ):
    settings = gemini_dir(environ) / "settings.json"
    if not settings.is_file():
        return None
    out = subprocess.run([str(acp_path()), "gemini-auth", str(settings)], capture_output=True, text=True, timeout=15)
    return out.stdout.strip() or None


def observe_auth(adapter, billing, environ):
    """Dispatch-time authentication-route checks: what is observable without reading a secret."""
    row = access.auth_row(adapter, billing)
    if row["status"] != "supported":
        return [("auth-route-unsupported", f"{adapter} has no explicit, readable {billing} route selection: {row['notes']}")]
    found = []
    if adapter == "codex" and billing == "subscription":
        login = codex_home(environ) / "auth.json"
        if login.is_symlink() or not login.is_file():
            found.append(("auth-login-missing", "no saved codex login (auth.json) for a subscription leg"))
        elif login_mode(login) in API_MODES:
            found.append(("auth-selected-type-conflict", "the saved codex login is in API-key mode; a subscription leg would run API-billed"))
    elif adapter == "gemini" and billing == "subscription":
        selected = operator_gemini_type(environ)
        files = [f for f in row["login_files"] if (gemini_dir(environ) / f).is_file() and not (gemini_dir(environ) / f).is_symlink()]
        if selected and selected != "oauth-personal":
            found.append(("auth-selected-type-conflict", f"the operator's selected auth type is {selected}; a subscription leg would run on it, not on a login"))
        elif not files and selected != "oauth-personal":
            found.append(("auth-login-missing", "no saved gemini login file and no selected OAuth auth type for a subscription leg"))
    return found


def auth_readback(adapter, billing, home, credential_set):
    """Launch-time read-back of what the launcher wrote. -> ('observed'|'configured', None) or (None, detail)."""
    row = access.auth_row(adapter, billing)
    if row["status"] != "supported":
        return None, f"{adapter}/{billing} has no explicit route selection"
    home = Path(home)
    if adapter == "opencode":
        return "configured", None
    if adapter == "codex":
        login = home / "auth.json"
        if billing != "subscription":
            return None, "codex binds a subscription route only"
        if credential_set:
            return None, "a credential variable is present for a subscription leg"
        if login.is_symlink() or not login.is_file():
            return None, "the isolated codex login is absent for a subscription leg"
        if login_mode(login) in API_MODES:
            return None, "the isolated codex login is in API-key mode for a subscription leg"
        return "observed", None
    gdir = home / ".gemini"
    selector = (row["selector"] or "").partition("=")[2]
    try:
        settings = json.loads((gdir / "settings.json").read_text())
        selected = settings["security"]["auth"]["selectedType"]
    except (OSError, ValueError, KeyError, TypeError):
        return None, "the isolated gemini settings name no auth type"
    if selected != selector:
        return None, f"the isolated gemini settings select {clean(selected, 40)}, not {selector}"
    present = [f for f in ("oauth_creds.json", "google_accounts.json", "gemini-credentials.json")
               if (gdir / f).exists() or (gdir / f).is_symlink()]
    if billing == "api":
        if present:
            return None, "a saved gemini login is staged for an API leg"
        if not credential_set:
            return None, "no credential variable is set for an API leg"
        return "observed", None
    if credential_set:
        return None, "a credential variable is present for a subscription leg"
    return ("observed" if present else "configured"), None


# ------------------------------------------------------------------------------ the one judgement

def resolve_pair(provider, custom, leg, digest, environ):
    """acp.sh resolve in bound mode -> (record dict | None, [(code, detail)])."""
    command = [str(acp_path()), "resolve", provider, "--transport", MOUNTED, "--bound-model", leg["model"],
               "--bound-effort", leg["effort"] or "-", "--route-id", leg["route_id"], "--access-digest", digest]
    if custom:
        command.append("--custom-profile")
    done = subprocess.run(command, capture_output=True, text=True, timeout=120, env=environ)
    if done.returncode == 0:
        record = {}
        for row in done.stdout.splitlines():
            key, _, value = row.partition("\t")
            record[key] = value
        return record, []
    found = []
    for row in done.stderr.splitlines():
        match = re.search(r"code=([a-z-]+) (.*)", row)
        if match and match.group(1) in CODES:
            found.append((match.group(1), match.group(2)))
    if not found:
        found.append(("model-unservable", clean(done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "the reviewer policy could not be resolved")))
    return None, found


def check_leg(leg, ctx, entries, entries_error, profiles, environ):
    """Judge one leg. Collects every refusal code in a fixed order rather than stopping at the first."""
    agent = leg["agent"]
    provider = ctx.get("provider", "")
    adapter, why = classify(provider, ctx.get("transport", ""), profiles)
    found = []

    def refuse(code, detail):
        if code not in [c for c, _ in found]:
            found.append((code, clean(detail)))

    if adapter is None:
        refuse("agent-unbindable", why)
    entry = None
    if entries_error:
        refuse("no-access-profile", f"the access profiles are unusable: {entries_error}")
    else:
        entry = access.effective_entry(agent, entries)
        if entry is None:
            refuse("no-access-profile", f"{agent} has no entry in access.json")
    digest = access.digest(entry) if entry else ZERO_DIGEST
    expected = leg.get("access")
    if entry is not None:
        if not isinstance(expected, dict) or any(k not in expected for k in ACCESS_KEYS):
            refuse("access-incomplete", "the expected access object must carry transport, provider, account, billing and credential")
        else:
            for code, mine, theirs in (("route-mismatch", leg["route_id"], entry["route_id"]),
                                       ("transport-mismatch", expected["transport"], entry["transport"]),
                                       ("provider-mismatch", expected["provider"], entry["provider"]),
                                       ("account-mismatch", expected["account"], entry["account"]),
                                       ("billing-mismatch", expected["billing"], entry["billing"]),
                                       ("credential-mismatch", expected["credential"], entry["credential"])):
                if mine != theirs:
                    refuse(code, f"expected {mine if mine is not None else 'null'}, configured {theirs if theirs is not None else 'null'}")
    # the operator's pins and "use max" are conflicts in every case, whatever the adapter
    if adapter is not None:
        record, resolved = resolve_pair(provider, adapter == "opencode", leg, digest, environ)
        for code, detail in resolved:
            refuse(code, detail)
    else:
        record = None
    if adapter is not None and entry is not None and not found_codes(found, "billing-mismatch"):
        for code, detail in observe_auth(adapter, entry["billing"], environ):
            refuse(code, detail)
        if entry["billing"] == "api" and entry["credential"] and not access.credential_present(entry["credential"], environ):
            refuse("credential-unavailable", f"the credential {entry['credential']} is not present")
    status = "refused" if found else "ok"
    stamp = None
    if not found:
        stamp = {"schema": 1, "capability_version": CAPABILITY_VERSION, "ref": leg["ref"], "role": leg["role"],
                 "requirement": leg["requirement"], "agent": agent, "route_id": leg["route_id"], "model": leg["model"],
                 "effort": leg["effort"], "access": {k: entry[k] for k in ACCESS_KEYS},
                 "access_digest": digest}
    return {"ref": leg["ref"], "agent": agent, "harness": provider or "-", "status": status,
            "codes": [c for c, _ in found], "details": found, "configured": entry, "digest": digest if entry else None,
            "model": leg["model"], "effort": leg["effort"], "record": record, "stamp": stamp,
            "adapter": adapter}


def found_codes(found, code):
    return code in [c for c, _ in found]


def load_context():
    """The configuration every check reads once: agents.json and the access profiles read TOGETHER."""
    profiles = load_profiles()
    try:
        return profiles, access.load_checked(profiles), None
    except (ValueError, KeyError, TypeError, OSError) as error:
        return profiles, {}, clean(error)


def check_all(legs, contexts, environ=None):
    environ = dict(os.environ if environ is None else environ)
    profiles, entries, entries_error = load_context()
    return [check_leg(leg, contexts.get(leg["agent"], {}), entries, entries_error, profiles, environ) for leg in legs]


def dash(value):
    return "-" if value in (None, "") else value


def plan_line(result):
    configured = result["configured"] or {}
    record = result["record"] or {}
    return " ".join([
        "route-plan v2", f"ref={result['ref']}", f"agent={result['agent']}", f"harness={result['harness']}",
        f"status={result['status']}", f"code={','.join(result['codes']) or '-'}",
        f"route_id={dash(configured.get('route_id'))}", f"transport={dash(configured.get('transport'))}",
        f"provider={dash(configured.get('provider'))}", f"account={dash(configured.get('account'))}",
        f"billing={dash(configured.get('billing'))}", f"credential={dash(configured.get('credential'))}",
        f"access_digest={dash(result['digest'])}", f"model={result['model']}", f"effort={dash(result['effort'])}",
        "model_source=bound", "effort_source=bound", f"capability={dash(record.get('capability'))}",
        f"limit_id={dash(record.get('limit_id'))}", "routing=off", "decision=none", f"phase={dash(record.get('phase'))}",
        f"map_version={dash(record.get('map_version'))}", f"capability_version={CAPABILITY_VERSION}"])


# ----------------------------------------------------------------------------------- the stamp

def stamp_encode(stamp):
    return base64.urlsafe_b64encode(canonical(stamp).encode()).decode()


def stamp_digest(encoded):
    return hashlib.sha256(encoded.encode()).hexdigest()


def stamp_decode(encoded, digest=None):
    if not encoded or len(encoded) > 8192:
        raise ProfileError("missing or oversized leg binding")
    if digest is not None and stamp_digest(encoded) != digest:
        raise ProfileError("the leg binding does not match its digest")
    stamp = json.loads(base64.b64decode(encoded, altchars=b"-_", validate=True), object_pairs_hook=unique_object)
    fields(stamp, ("schema", "capability_version", "ref", "role", "requirement", "agent", "route_id", "model", "effort",
                   "access", "access_digest"), ("schema", "capability_version", "ref", "role", "requirement", "agent",
                                                "route_id", "model", "effort", "access", "access_digest"))
    fields(stamp["access"], ACCESS_KEYS, ACCESS_KEYS)
    if stamp["schema"] != 1 or stamp_encode(stamp) != encoded:
        raise ProfileError("the leg binding is not canonical")
    return stamp


def recheck(encoded, digest, agent, provider, transport, environ=None):
    """The run-time re-check, from the stamp alone: the same judgement dispatch made, against the
    configuration as it is now. -> (stamp, result)."""
    stamp = stamp_decode(encoded, digest)
    if stamp["agent"] != agent:
        raise ProfileError("the leg binding names a different agent")
    leg = {k: stamp[k] for k in ("ref", "agent", "role", "requirement", "route_id", "model", "effort", "access")}
    result = check_all([leg], {agent: {"provider": provider, "transport": transport}}, environ)[0]
    if result["status"] == "ok" and result["digest"] != stamp["access_digest"]:
        result["status"] = "refused"
        result["codes"].append("route-mismatch")
        result["details"].append(("route-mismatch", "the access profile's digest changed since dispatch"))
    return stamp, result


# ------------------------------------------------------------------------------------ result.json

def binding_json(encoded, status, observed_model, observed_effort, auth_evidence, mismatches):
    stamp = stamp_decode(encoded)
    access_ = stamp["access"]
    return canonical({
        "schema": 1, "capability_version": CAPABILITY_VERSION, "ref": stamp["ref"], "role": stamp["role"],
        "requirement": stamp["requirement"], "status": status, "route_id": stamp["route_id"],
        "access_digest": stamp["access_digest"], "transport": access_["transport"], "provider": access_["provider"],
        "account": access_["account"], "billing": access_["billing"], "credential_ref": access_["credential"],
        "expected": {"model": stamp["model"], "effort": stamp["effort"]},
        "observed": {"model": observed_model or None, "effort": observed_effort or None},
        "auth_evidence": auth_evidence if auth_evidence in ("observed", "configured") else "configured",
        "mismatches": [m for m in mismatches if m in CODES or m == "binding-mismatch"]})


COLLECTORS = {"codex": "codex-rollout"}   # providers whose collector has a rate-limit source


def quota_json(provider, hosting, rate, reason):
    """leg-metadata v1. `unsupported` for a provider whose collector has no rate-limit source, `unavailable`
    for one that has a source but no bounded record, `refused` only where the runner's own classifier named
    a rate limit or an authentication failure. A reset time is never manufactured."""
    base = {"schema": LEG_METADATA_VERSION, "provider": hosting or provider, "state": "unsupported", "source": None,
            "limit_id": None, "window_minutes": None, "used_percent": None, "resets_at": None, "refusal": None}
    if reason in ("rate-limited", "auth-failed"):
        base.update(state="refused", source="acp-failure-reason",
                    refusal={"kind": reason, "reset_at": None, "reset_state": "not_provided"})
    elif provider in COLLECTORS:
        base["source"] = COLLECTORS[provider]
        if isinstance(rate, dict):
            base["state"] = "observed"
            for key in ("limit_id", "window_minutes", "used_percent", "resets_at"):
                base[key] = rate.get(key)
        else:
            base["state"] = "unavailable"
    return canonical(base)


# ----------------------------------------------------------------------------------- capability

def capability(contexts):
    profiles, entries, entries_error = load_context()
    rows = []
    for agent, ctx in contexts.items():
        adapter, why = classify(ctx["provider"], ctx["transport"], profiles)
        row = {"agent": agent, "harness": ctx["provider"], "class": None, "reason": None, "billing": None}
        entry = None if entries_error else access.effective_entry(agent, entries)
        if adapter is None:
            row.update({"class": "unbindable", "reason": why.split(":")[0]})
        elif entry is not None and access.auth_row(adapter, entry["billing"])["status"] != "supported":
            row.update({"class": "unbindable-billing", "reason": entry["billing"], "billing": entry["billing"]})
        else:
            row["class"] = "bindable" if adapter in ("codex", "gemini") else "bindable-model-only"
            row["billing"] = entry["billing"] if entry else None
        rows.append(row)
    return rows, entries_error


def capability_line():
    return (f"leg-binding-capability v{CAPABILITY_VERSION} leg-bindings={CAPABILITY_VERSION} "
            f"route-view={ROUTE_VIEW_VERSION} leg-metadata={LEG_METADATA_VERSION}")


# ------------------------------------------------------------------------------------------ CLI

def option(args, name, default=None, many=False):
    values = []
    i = 0
    while i < len(args):
        if args[i] == name:
            values.append(args[i + 1]); i += 2
        else:
            i += 1
    if many:
        return values
    return values[-1] if values else default


def main():
    args = sys.argv[1:]
    if not args:
        raise ProfileError("expected an operation")
    operation, args = args[0], args[1:]
    if operation == "agents":
        # the file's agents, comma-joined, in order: they ARE the roster. A malformed file is a usage error.
        print(",".join(leg["agent"] for leg in parse(option(args, "--bindings"))))
    elif operation == "check":
        # check --bindings FILE --ctx agent:provider:transport... [--stamps-out FILE]
        legs = parse(option(args, "--bindings"))
        contexts = parse_ctx(option(args, "--ctx", many=True))
        if set(contexts) != {leg["agent"] for leg in legs}:
            raise ProfileError("every listed leg needs a resolved agent context")
        results = check_all(legs, contexts)
        for result in results:
            print(plan_line(result))
            for code, detail in result["details"]:
                print(f"refused {result['agent']} {code} {detail}", file=sys.stderr)
        out = option(args, "--stamps-out")
        if out and all(r["status"] == "ok" for r in results):
            with open(out, "w") as handle:
                for r in results:
                    encoded = stamp_encode(r["stamp"])
                    handle.write(f"{r['agent']}\t{encoded}\t{stamp_digest(encoded)}\t{r['ref']}\t{r['stamp']['role']}\t"
                                 f"{r['stamp']['requirement']}\t{r['stamp']['route_id']}\t{r['model']}\t{r['effort'] or '-'}\n")
        sys.exit(0 if all(r["status"] == "ok" for r in results) else 1)
    elif operation == "recheck":
        stamp, result = recheck(option(args, "--stamp"), option(args, "--digest"), option(args, "--agent"),
                                option(args, "--provider"), option(args, "--transport", "acp"))
        for code, detail in result["details"]:
            print(f"mismatch\t{code}\t{detail}")
        if result["status"] != "ok":
            sys.exit(1)
    elif operation == "stamp-field":
        stamp = stamp_decode(option(args, "--stamp"), option(args, "--digest"))
        key = option(args, "--key")
        value = stamp["access"][key[7:]] if key.startswith("access.") else stamp[key]
        print("" if value is None else value)
    elif operation == "env-class":
        # which adapter and billing a stamped leg runs under, for the runner's environment plan
        stamp = stamp_decode(option(args, "--stamp"), option(args, "--digest"))
        profiles = load_profiles()
        adapter, why = classify(option(args, "--provider"), "acp", profiles)
        if adapter is None:
            raise ProfileError(why)
        print(f"{adapter}\t{stamp['access']['billing']}")
    elif operation == "auth-readback":
        evidence, detail = auth_readback(option(args, "--adapter"), option(args, "--billing"), option(args, "--home", ""),
                                         option(args, "--credential-set", "0") == "1")
        if evidence is None:
            print(f"mismatch\t{clean(detail)}")
            sys.exit(1)
        print(evidence)
    elif operation == "result":
        observed_model = option(args, "--observed-model")
        evidence = option(args, "--evidence-file")
        if not observed_model and evidence and Path(evidence).is_file():
            # a custom runtime's own assistant-record evidence names the model that answered
            try:
                found = json.loads(Path(evidence).read_text()).get("model")
                observed_model = found if isinstance(found, str) else None
            except (OSError, ValueError, AttributeError):
                observed_model = None
        print(binding_json(option(args, "--stamp"), option(args, "--status", "refused"), observed_model,
                           option(args, "--observed-effort"), option(args, "--auth-evidence", "configured"),
                           [m for m in option(args, "--mismatches", "").split(",") if m]))
    elif operation == "quota":
        raw = option(args, "--rate-json", "null")
        try:
            rate = json.loads(raw)
        except ValueError:
            rate = None
        print(quota_json(option(args, "--provider"), option(args, "--hosting"), rate, option(args, "--reason", "")))
    elif operation == "capability":
        rows, error = capability(parse_ctx(option(args, "--ctx", many=True)))
        if "--json" in args:
            print(canonical({"schema": 1, "capability_version": CAPABILITY_VERSION, "leg_bindings": CAPABILITY_VERSION,
                             "route_view": ROUTE_VIEW_VERSION, "leg_metadata": LEG_METADATA_VERSION, "agents": rows,
                             "access_error": error}))
        else:
            print(capability_line())
            for row in rows:
                print(" ".join(f"{k}={dash(v)}" if k != "agent" else f"agent={v}" for k, v in
                               (("agent", row["agent"]), ("class", row["class"]), ("harness", row["harness"]),
                                ("reason", row["reason"]), ("billing", row["billing"]))))
        if error:
            print(f"leg-binding-capability: the access profiles are unusable: {error}", file=sys.stderr)
            sys.exit(1)
    else:
        raise ProfileError(f"unknown operation: {operation}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError, OSError, subprocess.SubprocessError) as error:
        print(f"leg binding: {clean(error)}", file=sys.stderr)
        sys.exit(2)
