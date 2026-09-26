# Configurable agents

Agents can have independent names, ACP harnesses and exact model pins. Built-in
`claude`, `codex`, `grok` and their review twins continue to work without this file.
No additional harness or inference account is required for built-in agents.

## Register and enable

Put operator profiles in `~/.agent-comms/agents.json` (or
`$AGENT_COMMS_HOME/agents.json`). This file is never loaded from the reviewed project.
It must be a regular file, must not be a symlink, and must not be writable by other users.
Project `.comms/config` selects enabled names:

```ini
agents = codex analyst
default-target = codex
```

Example for any ACP server that supports model selection:

```json
{
  "version": 1,
  "agents": {
    "analyst": {
      "adapter": "acp",
      "command": ["/absolute/path/to/harness", "acp"],
      "model": "provider/exact-model-id",
      "family": "example-family",
      "api_provider": "example-host",
      "credentials": {"API_KEY": {"env": "MY_INFERENCE_KEY"}}
    }
  }
}
```

`command` is an argv array, never shell code. The executable may be an absolute path
or a name on `PATH`; dispatch resolves it to an absolute path. Model identifiers are
opaque to the framework. `api_provider` is optional descriptive metadata. `family`
is the operator's independence group: aliases and models from the same family count
as one reviewer. A panel rejects duplicate families even if names, hosts or harnesses
differ. Use the real model family consistently across your profiles.

Names follow `[a-z][a-z0-9-]{1,15}`. Built-in names and the `-review` suffix are reserved.
Every enabled driver gets an automatic review twin (`analyst-review`). A custom driving
session sets `COMMS_SELF=analyst`; model choice alone does not identify the driver.

```sh
helpers/comms.sh agents --family analyst
helpers/comms.sh agents --provider analyst-review  # execution profile: analyst
helpers/acp.sh consult analyst 'Read the code and explain the retry policy.'
```

Generic ACP profiles support consults. Mounted reviews require a supported containment
adapter; an arbitrary ACP server is refused even if an uncontained built-in override
is enabled. ACP model confirmation is control-plane evidence, not proof of the model
used by a remote inference service.

## Optional OpenCode reviewer

The `opencode` adapter supports **OpenCode 1.18.32** over ACP. Install that exact
version separately, for example with `npm install --prefix <runtime-directory>
opencode-ai@1.18.32`, and set `command` to its `node_modules/.bin/opencode` executable.
Existing installations and preferences are not modified by agent-comms.

Example: an agent named `glm` using Venice. These are example values, not framework
defaults; other hosts, model families and agent names use the same schema.

```json
{
  "version": 1,
  "agents": {
    "glm": {
      "adapter": "opencode",
      "command": ["/absolute/runtime-directory/node_modules/.bin/opencode"],
      "runtime_version": "1.18.32",
      "model": "venice/z-ai-glm-5-3-flash",
      "family": "glm",
      "api_provider": "venice",
      "credentials": {"VENICE_API_KEY": {"env": "VENICE_API_KEY"}},
      "connection": {
        "base_url": "https://api.venice.ai/api/v1",
        "api_key_env": "VENICE_API_KEY",
        "context": 1048576,
        "output": 131072
      }
    }
  }
}
```

On macOS, replace the credential reference with
`{"keychain_service":"venice-api-token"}` to read that Keychain service at launch.
Only references are saved in requests and logs. Never place a token in this file or
in command arguments. Environment references work across operating systems.

`connection` is optional when the runtime's native provider definition is sufficient.
When supplied, it declares an OpenAI-compatible endpoint with explicit limits. HTTPS
is required except for a local inference server. Runtime authentication is isolated,
so declare any required credential explicitly.

Enable `glm` in `.comms/config`, then use it wherever you name a reviewer or consult
agent. Include the proposed diff and its base in review requests: this adapter can
read/search the mounted tree but cannot run git or a shell.

The adapter isolates runtime settings/state, disables project configuration and external
plugins/MCP servers, exposes only read/glob/grep tools, and locks the model and the
`comms-review` mode. This is an **in-process permission boundary**, not an OS sandbox.
Its inference connection remains available; it is not a network isolation guarantee.
Every successful review also checks newly appended runtime assistant records for the
requested model and mode. This proves the harness's recorded selection, not the
inference host's internal routing.

## Pins and history

Profiles are exact pins. Updating `glm` to another GLM model is an explicit operator
change. There is no automatic catalog selection or silent fallback.

Dispatch freezes the public resolved profile, digest, family and model in the request.
Execution refuses if the operator profile changed; create a fresh request. Resending
a stamped request cannot silently retarget it. Consult/review session names include
identity and profile digest, so two pins do not reuse one session. One-shot custom
consults use a unique named session to permit model inspection.

Parent-brokered replies inherit the same binding. Composition uses the retained request
and stamped family, including after profiles are removed. Built-in historical replies
keep their existing provider semantics. Run records include `profile` metadata;
`profile-model-before.json` / `profile-model-after.json` hold ACP observations, and
`profile-evidence.json` contains the OpenCode assistant-record evidence. Missing or
mismatched evidence fails the turn before a verdict is published.

Adding another contained runtime requires an adapter with its own launch isolation,
mode controls and model-evidence checks. Registry, mailbox, twins, family voting and
profile bindings remain shared infrastructure.
