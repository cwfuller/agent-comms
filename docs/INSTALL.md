# Installing

## Quick install

```bash
# from your project's root:
curl -fsSL https://raw.githubusercontent.com/cwfuller/agent-comms/main/install.sh | bash -s -- --scope=both
```

Piping a script into a shell runs code you have not read. Cloning and inspecting first gives
the same result:

```bash
git clone https://github.com/cwfuller/agent-comms ~/src/agent-comms
less ~/src/agent-comms/install.sh
cd /path/to/your/project && bash ~/src/agent-comms/install.sh --scope=both
```

`--scope=both` writes driver commands/skills for Claude, Grok and Codex, the shared helpers, a
Codex protocol note, and this project's `.comms/` mailboxes (plus `.gitignore` entries). Nothing
else.

## Requirements

- A git repository.
- At least two agent CLIs. `claude` and `codex` work out of the box; `grok` is registered by
  default, but read the containment note below before using it as a *reviewer*.
- Node >= 22.13 for the ACP transport. `ACPX_BIN` pointing at an installed `acpx` skips the
  `npx` download; the Node floor still applies.
- No pane multiplexer: loops run over ACP in the background.

### Reviewer containment

A reviewer runs against a mounted copy of your tree, so it has to be contained. `claude` and
`codex` have verified isolation backends, though not identical ones: `codex` runs under its own
kernel sandbox; `claude` was measured write-contained but still reaches the network, which is
behavioural defence rather than a kernel boundary. Both measurements are due a re-probe on
current adapters and on the installed codex runtime reviewers now use (docs/ROADMAP.md).

`grok` has no verified backend, so a mounted grok *review* turn is refused rather than run
unconstrained, and a default panel that includes it will not complete. Grok as a *driver* is
fine. Either narrow the roster (`<auto> --reviewers codex`, or drop `grok` from `agents` in
`.comms/config`), or accept an uncontained reviewer deliberately with
`export COMMS_RUNPHASE_ALLOW_UNCONTAINED=1`. An uncontained turn can write outside its mount and
reach the network with your git credentials: fine for your own code on your own machine, not
for code you did not write.

## Interactive install

Run interactively (no `--scope`) and the installer shows a menu:

```
1) Global + project init (recommended)
2) Global only
3) Project init only
4) Local pinned install
5) Cancel
```

## Scopes

| scope | installs | where |
|---|---|---|
| `global` | 5 driver commands for Claude, Grok, and Codex; 8 helper files (scripts plus the reviewer policy map); 2 loopspec fragments; the Codex protocol note | `~/.claude/commands/`, `~/.grok/commands/`, `~/.codex/skills/`, `~/.agent-comms/`, `~/.codex/AGENTS.md` |
| `project` | per-repo state only | `.comms/{to-codex,to-claude,to-grok,archive}/`, `.gitignore` entries |
| `both` | global + project | the recommended pair |
| `local` | pinned copies of everything into the repo | `.claude/commands/`, `.grok/commands/`, `.agents/skills/`, `.agents/loopspec-fragments/`, `.agent-comms/` + project state |

All scopes are idempotent — re-run freely.

**Upgrading a project that has local pins.** `--scope=global` and `--scope=both` deliberately
leave `.claude/commands/`, `.grok/commands/`, `.agents/skills/`, `.agents/loopspec-fragments/` and `.agent-comms/` alone — pinning is
the whole point of them. To bring those pins up to date, re-run `--scope=local` in that
project. Do not hand-copy the files: the installer resolves symlinks, preserves mode and owner,
reports an ACL it cannot carry, and refuses rather than overwriting a file that changed
underneath it.

## Codex permissions

**No socket allowance is required.** Delivery runs over ACP, which needs no network and no
Unix socket. The `workspace-cmux` permission profile this section used to prescribe — along
with the `comms.sh codex-permissions` and `comms.sh doctor` commands that printed and verified
it — was removed in step 4 with the cmux transport itself.

Reviewer turns are contained by Codex's own kernel sandbox (`sandbox_mode = "read-only"` plus
an isolated `CODEX_HOME`), which `runphase.sh` sets up per turn. Nothing needs configuring in
`~/.codex/config.toml` for agent-comms to deliver.

If a sandboxed session still cannot write its reply, the message file persists and Claude is
**not** notified — do not assume passive polling of `.comms/`. Use one manual pickup rather
than re-running the same helper from the unchanged sandbox.

### Global vs local pinning

Global installs are shared: update once (`install.sh --scope=global` from a checkout, or
re-run the curl line) and every project picks the new version up immediately.

A **local pinned** install copies everything into the repo instead. Pinned copies
**never auto-update** — the installer prints exactly this warning. For Claude commands,
Grok commands, and helpers, they also **shadow the global install**: resolution is
*local pin first, then global* (commands via the CLI's own project-command precedence;
helpers via `<repo>/.agent-comms/comms.sh` then `~/.agent-comms/comms.sh`).

**Codex does not shadow.** Same-name skills are not merged. A local pin at
`.agents/skills/auto` and a global copy at `~/.codex/skills/auto` can both appear in
the `$` selector, unlabeled. Pick the copy you mean, or disable the other with
`/skills`. To un-pin, delete the repo's `.claude/commands/`, `.grok/commands/`,
`.agents/skills/`, `.agents/loopspec-fragments/`, and `.agent-comms/` copies.

Stale pins are the classic failure mode: a repo pinned months ago silently runs old
behavior while every other repo runs current. `install.sh --scope=global` warns when it
detects local copies that would shadow it.

### What project init does

- creates `.comms/` (`to-codex/`, `to-claude/`, `to-grok/`, `archive/`)
- gitignores `.comms/`, `.codex/AGENTS.md`, `.agent-comms/` (whole-line matched,
  trailing-newline-safe, idempotent). `.codex/AGENTS.md` is still ignored because older
  installs wrote one there; nothing writes it any more.
- writes NO Codex instructions. The protocol note is a GLOBAL asset (`~/.codex/AGENTS.md`,
  overridable with `CODEX_AGENTS_FILE`) installed by the `global` scope, because a copy of
  prose per repository is the one thing here that reliably drifts: the code was always
  single-sourced, the note was not, and the oldest copies went on naming Codex skills this
  installer had already deleted. The note names the condition it applies under — a
  repository with a `.comms/` directory — so it is inert everywhere else. Because that file is
  the user's own, the block is published through the same path as every other installed file:
  a symlinked destination is written THROUGH rather than replaced, the existing mode and owner
  are preserved, an ACL that cannot survive a replacement is reported, and a file that changed while the
  installer was preparing the write is detected immediately before the atomic replacement and
  refused rather than overwritten. That last one is best-effort, not absolute: the check sits as
  close to the rename as a shell can put it, but a save inside the remaining comparison-and-rename
  interval is still lost, an edit that returns the file to identical bytes reads as unchanged, and
  a symlink retargeted between the check and the rename to a different same-content target is not
  detected.

## Installing from a fork

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/agent-comms/main/install.sh -o /tmp/agent-comms-install.sh
AGENT_COMMS_REPO_RAW="https://raw.githubusercontent.com/<you>/agent-comms/main" \
  bash /tmp/agent-comms-install.sh --scope=both
```

`AGENT_COMMS_REPO_RAW` points template/helper downloads at any raw-file base URL
(including `file:///path/to/checkout` for fully-local testing).

## Settings (`comms.sh setup`)

After installing, run `~/.agent-comms/comms.sh setup` (the installer offers it when it has a
terminal). It checks prerequisites, detects the agent CLIs and registers them for the project,
and asks about reviewer containment, Jev routing, the Codex reviewer runtime and the review
timeout. Detected values are the defaults; re-run it any time to change them.

Answers are saved to files that every helper reads, so a setting works in shells that never
load your shell rc (agent tool shells, cron, CI). Precedence, highest first:

| source | scope |
|---|---|
| the environment (`KEY=v cmd`, `export`) | one command or shell |
| `<repo>/.comms/settings` | one project (gitignored with `.comms/`) |
| `~/.agent-comms/settings` | the user (written by `setup`) |
| `~/.agent-comms/secrets` | `TYPESAFE_API_KEY` only; ignored unless mode `600` |

Files are `KEY=value` lines. They are parsed, never executed, and only known keys are accepted:
`COMMS_REVIEW_ROUTE`, `COMMS_ROUTE`, `COMMS_ROUTE_BACKEND`, `COMMS_ROUTE_MODEL`,
`COMMS_ROUTE_TIMEOUT_SECS`, `COMMS_ACP_CODEX_PATH`, `COMMS_ACP_CODEX_MODEL`,
`COMMS_ACP_CODEX_EFFORT`, `COMMS_ACP_CANARY_SECS`, `COMMS_ACP_RUNTIME_PROBE_SECS`,
`COMMS_RUNPHASE_TIMEOUT_SECS`, `COMMS_RUNPHASE_ALLOW_UNCONTAINED`, `ACPX_BIN`.

```bash
comms.sh setup                 # interactive
comms.sh setup --yes           # accept detected defaults, no prompts
comms.sh setup --show          # current values and where each comes from (the key is never printed)
comms.sh setup --set COMMS_REVIEW_ROUTE=1 --set COMMS_RUNPHASE_TIMEOUT_SECS=   # empty removes
```

`AGENT_COMMS_SETUP=0` stops the installer from offering setup.

## Environment overrides

| variable | default | purpose |
|---|---|---|
| `AGENT_COMMS_REPO_RAW` | this repo's `main` | raw base URL for remote installs |
| `AGENT_COMMS_HOME` | `~/.agent-comms` | where global helpers land |
| `CLAUDE_COMMANDS_DIR` | `~/.claude/commands` | where global Claude commands land |
| `GROK_COMMANDS_DIR` | `~/.grok/commands` | where global Grok commands land |
| `CODEX_SKILLS_DIR` | `~/.codex/skills` | where Codex driver skills land, and where retired reviewer skills are removed from |

## From a clone

```bash
git clone https://github.com/cwfuller/agent-comms.git
cd your-project
../agent-comms/install.sh --scope=both
```

## Upgrading

Re-run the installer with the same scope. Global scope refreshes commands, fragments, and
helpers in place; running sessions pick the new versions up on their next command
invocation (slash commands are read from disk each time). In-flight review loops survive
upgrades — protocol-v2 fields are soft-validated precisely so an older message mid-loop
isn't rejected.
