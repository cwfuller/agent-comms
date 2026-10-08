# Task 421: bind a Claude review leg on its mounted ACP runner, attested from Claude's own transcript

Status: plan, not yet implemented; revised after plan round 1 (codex B1, A1, A2) and round 2
(codex B1, B2, A1). Scope is agent-comms only; the Basis side already accepts a
`bindable` kernel route (bind-context.ts `kernelRouteProblem`). Settled before this plan: Q3, Q6,
Q7, Q11, the route id `kernel-claude`, the access key `claude` (inherited by `claude-review`), the
unchanged containment (`claude-plan`, network open, no config-home override), the unchanged class
vocabulary and version numbers, and (operator, this task) **claude-agent-acp 0.88.0 pinned for
bound legs**, with no gate on an operator-run live trial.

## Goal

`review-route capability` reports `claude` and `claude-review` as `bindable`. A bound Claude leg
runs exactly the model and native effort its caller names, on the pinned adapter, in the existing
mounted `claude-plan` arm, and the runner proves what ran from Claude's own transcript before the
review is published. A codex-authored request can then be reviewed by a bound Claude leg.
Unbound Claude reviews, codex bound legs, grok and gemini behave exactly as before.

## What this plan adds to the brief's evidence

Read for this plan (local, read-only; no provider was called):

1. FACT, transcript fields. Claude Code assistant records carry `message.model` (the served id,
   e.g. `claude-opus-5-5`) and a top-level `effort` (`low`..`max`). Newer CLIs (2.1.27+) also write
   `perTurnEffort`; in every record surveyed it is either absent/null or equal to `effort`.
   Records of a model without an effort scale (a Haiku 4.5 id) carry no `effort` key. Synthetic
   records (`message.model == "<synthetic>"`, errors and interruptions) carry no effort.
   Records from mounted ACP review turns (entrypoint `sdk-ts`, the 0.60.0 adapter's bundled CLI)
   also carry `effort`.
2. FACT, subagents. Mounted ACP reviews already spawn subagents: their records sit in
   `<project>/<session>/subagents/*.jsonl` with `isSidechain: true`. In the survey they ran the main
   model; a few CLI sessions show subagents on a different model.
3. FACT, the 0.60.0 adapter (acp-agent.js): `set model` resolves an inexact value fuzzily
   (`resolveModelPreference`) and reports the canonical option value (often an alias), so the
   adapter's `model` option is not a reliable spelling of the bound id. The `effort` option exists
   only when the model `supportsEffort`. On **both** `session/new` and `session/load` the adapter
   seeds effort from the operator's `settings.json` `effortLevel` and applies it to the SDK
   (acp-agent.js:4184-4192). A model switch never removes `plan` mode (only `auto` can be clamped).
4. FACT, acpx 0.13.1: with no queue owner running, `set` is a direct connection (spawn adapter,
   load, set, exit). It persists `session_options.model` and `desired_config_options`. On every
   later reconnect on the prompt path it re-applies the pinned **model**
   (`reapplyPinnedModelAfterConnect`), but replays saved **config options** (effort) only onto a
   freshly created replacement session (`replayFreshSessionPreferences`).
5. FACT, the operator's default Claude profile's `settings.json` sets an `effortLevel`.
   INFERENCE from 3-5: an effort set over ACP before the first prompt can be overwritten by that
   settings value when the canary's queue owner loads the session, so the ACP `set` alone is not
   a reliable application of effort. The 2026-09-22 probe that saw `set effort low` honoured does
   not record whether settings carried an effort.
6. FACT, the 0.60.0-bundled Claude CLI reads `CLAUDE_CODE_EFFORT_LEVEL` and its `/effort` command
   reports that this variable "overrides effort this session". It also reads `ANTHROPIC_MODEL`,
   `ANTHROPIC_DEFAULT_*_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL`,
   each a second source of the model a session or alias runs.
7. FACT, `helpers/access_profiles.py adapter_of` has no caller; `classify` in leg_binding.py is
   the function that decides bindability. This plan changes `classify` and leaves `adapter_of`
   alone (mentioned, not fixed).
8. FACT (plan round 1, codex B1, then a survey of the 0.60.0-bundled CLI's strings): Claude reads
   credentials from variables that no scrub pattern (`*_API_KEY`, `*_TOKEN`, `*_AUTH_TOKEN`,
   `*_SECRET*`, `*_ACCESS_KEY*`) and no `credential-env.tsv` row matches today:
   `ANTHROPIC_CUSTOM_HEADERS` (headers, which Anthropic documents can carry `Authorization`),
   `ANTHROPIC_IDENTITY_TOKEN_FILE` and `CLAUDE_SESSION_INGRESS_TOKEN_FILE` (a token read from a
   file), `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR`, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` and
   `CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR` (a credential read from an inherited descriptor),
   `CLAUDE_CODE_HOST_AUTH_ENV_VAR` (names another variable to authenticate with),
   `CLAUDE_CODE_CLIENT_CERT`, `CLAUDE_CODE_CLIENT_KEY` and `CLAUDE_CODE_CLIENT_KEY_PASSPHRASE`
   (mTLS client credentials), `CLAUDE_CODE_CUSTOM_OAUTH_URL` and `CLAUDE_LOCAL_OAUTH_*_BASE`
   (OAuth endpoint selectors, the analogue of the already-scrubbed `ANTHROPIC_BASE_URL`), and
   `CLAUDE_BG_AUTH_SNAPSHOT_PATH` and `CLAUDE_BG_SOCKET_TOKENS_PATH`. The codex reviewer reports
   that `claude auth status` derives its three fields from token and key sources without
   looking at custom headers. So a credential in one of these names can survive the scrub and
   still read back as `claude.ai` / `firstParty`, and a correct model and effort in the transcript
   cannot show that the authentication route differed. Neither profile on this machine sets an
   `env` block or `apiKeyHelper` in `settings.json` (key names checked; no values read).

## Mechanism

### 1. Classification and capability (leg_binding.py)

- `classify`: provider `claude` over `acp` returns adapter `claude`. grok and gemini keep their
  refusals.
- `capability`: class `bindable` for adapter `codex` **or** `claude` (both bind model and native
  effort); `bindable-model-only` stays OpenCode's. With an access entry whose auth row is
  supported, `billing` is the entry's; with none, `-`. No new class, no version change.
- `check_leg` calls `resolve_pair` without `--custom-profile` for claude (the `adapter ==
  "opencode"` test already does this) and runs `observe_auth` for it (section 4).

### 2. The policy map (helpers/policy-map.tsv, read by acp.sh)

Three additions, each validated by `policy_map_check`; the map `version` is bumped.

- **Capability `bound`**: "applied and attested for a bound leg only". `claude acp-mounted` becomes
  `bound`, with the mechanism (ACP `set model`/`set effort` before the first prompt, plus the
  effort variable below), the evidence source (Claude's transcript, canary and review windows),
  and a versions cell that names only what was exercised (`stub only` until a live run is
  recorded). An unbound resolution reads `bound` as `unsupported`, before the applied-combination
  check, so an unbound Claude record is byte-identical to today's (`capability unsupported`,
  `fallback capability-unsupported`). That is why no `baseline`, `tier`, `effort` or `ceiling` row
  exists for claude: agent-comms chooses no Claude model. `claude acp` and `claude headless` stay
  `unsupported`, their reasons updated ("an unmounted turn has no transcript window bounded to the
  leg" / "claude review turns are ACP-only").
- **`recorded <provider> <transport> <launch id> <transcript model id>`**: the model id Claude's
  transcript records for a launch id (an alias such as `sonnet`, or a full id). Full ids get an
  explicit identity row. A launch id with no `recorded` row refuses `model-unservable` at
  resolution and can never count as matched.
- **Pair efforts `none`**: a `pair` row whose effort list is exactly `none` declares a model with no
  effort scale (Haiku per ROADMAP 2026-09-22). `none` mixed with other efforts is a map defect.
  The `pair` row's optional minimum is the adapter version for claude: rows for
  `claude-opus-5-5` and `claude-fable-5-1` carry `0.88.0` (operator: 0.60.0's CLI cannot serve
  them), so a pin moved back below it refuses them by name rather than letting the adapter's fuzzy
  match pick a sibling.

Which rows ship: a `recorded` row only from a transcript record whose request named that launch id
(the live probe in "Showing it work", or a local transcript whose `requestedModel` equals it), with
the evidence cited in the map comment; `pair` efforts from the adapter's `effort` option list seen
in `sessions show`, or, where no probe ran, the operator policy route `claude`'s efforts
(`low`..`max`) labelled "adapter list not observed". A launch id without evidence gets no row and
refuses until it has one. `policy_applied_combo` gains `claude/acp-mounted`.

### 3. Bound resolution (acp.sh)

- `cmd_resolve`: `claude` goes to `resolve_bound` (no `--custom-profile`); grok and gemini still
  refuse `capability-unsupported`.
- `policy_runtime_for claude` sets the runtime from **one** constant, `CLAUDE_ACP_VERSION=0.88.0`
  (`RT_PATH` the adapter package, `RT_VERSION` 0.88.0), so the adapter version is part of the
  policy digest: an adapter bump is a fresh session, as a codex runtime change is.
- `resolve_bound` accepts capability `eligible|fixed|bound` on an applied combination, then for
  claude applies two provider rules from one place: no `unverified-pin` (the model needs a `pair`
  and a `recorded` row, else `model-unservable`), and the null-effort rule (a `none` row admits only
  a null effort; any effort for it, or a null effort for a model with efforts, is
  `effort-mismatch`; an effort outside the list is `effort-refused`). codex keeps its rules (no
  `none` rows exist for it).
- The record stays version 2. A claude record adds one key, `attest_model` (the `recorded` id), and
  an effortless one has `effort n/a`, `verify model`. Readers already accept extra keys; codex and
  version 1 records are unchanged. `route-view` is unchanged (it shows `capability=bound`).
- `adapter_command_for claude` prints the pinned
  `npx -y @agentclientprotocol/claude-agent-acp@0.88.0` only when asked for a bound leg
  (`acp.sh adapter claude --bound`); `acp.sh adapter claude` still prints nothing, so unbound
  reviews stay on acpx's built-in profile (0.60.x), untouched.

### 4. Access, scrub and the login read-back

- `credential-env.tsv` gains `auth claude subscription supported - - login-readback <notes>` (the
  leg runs on the login of its own `CLAUDE_CONFIG_DIR`, the dispatch's, unchanged; `claude auth
  status --json` is read back and only `loggedIn`, `authMethod`, `apiProvider` are kept; a
  subscription is `true` / `claude.ai` / `firstParty`), and `auth claude api|local|free
  unsupported`.
- The same table gains `scrub` rows for **Claude's credential-bearing variables that no pattern
  matches** (FACT 8): `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_IDENTITY_TOKEN_FILE`,
  `CLAUDE_SESSION_INGRESS_TOKEN_FILE`, the three `*_FILE_DESCRIPTOR` names,
  `CLAUDE_CODE_HOST_AUTH_ENV_VAR`, the three `CLAUDE_CODE_CLIENT_*` mTLS names,
  `CLAUDE_CODE_CUSTOM_OAUTH_URL`, `CLAUDE_BG_AUTH_SNAPSHOT_PATH`, `CLAUDE_BG_SOCKET_TOKENS_PATH`,
  and `scrub-prefix CLAUDE_LOCAL_OAUTH_`. The table comment cites the survey that found them and
  the CLI bundle it read. The implement phase repeats the survey (a strings search for
  `ANTHROPIC_*` / `CLAUDE_*` names carrying KEY, TOKEN, SECRET, HEADER, CERT, PASS, AUTH or
  CREDENTIAL) on the 0.88.0 bundle. It fetches that bundle into the same `$TMPDIR` npm cache as
  the optional probe, and adds a row for any further name that carries or selects a credential.
  If the bundle cannot be fetched, the 0.60.0 rows ship and the comment says which bundle was
  surveyed. `ANTHROPIC_CUSTOM_HEADERS` ships whatever the survey finds, because Anthropic documents
  it.
- It also gains `scrub` rows for the Claude model and effort selectors of FACT 6:
  `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`,
  `CLAUDE_CODE_EFFORT_LEVEL`, and `scrub-prefix ANTHROPIC_DEFAULT_`. They are second sources of the
  pair (an `ANTHROPIC_DEFAULT_SONNET_MODEL` silently redefines `sonnet`), so no bound leg of any
  provider inherits them. `CLAUDE_CONFIG_DIR` is not scrubbed.
- The scrub and the surviving-credential guard below read **one** set:
  `access_profiles.scrub_list`, which is configured names plus table rows plus patterns. Each new
  row therefore extends both by construction, and no second list exists to drift.
- **Dispatch time** (`observe_auth`, so `review-route plan`, `panel dispatch --bindings` and the
  run-time re-check agree): run the installed `claude auth status --json` under the dispatch
  environment minus the same scrub the leg gets, bounded (process-group kill at a deadline, the
  `runtime_version_probe` pattern), the CLI found by the PATH walk codex's runtime resolver already
  uses (shim directories skipped; one accessor shared by both). Not logged in, or no CLI, is
  `auth-login-missing`; another `authMethod` or `apiProvider` is `auth-selected-type-conflict`.
- **Launch time** (`bound_leg_readback`, before the first acpx call): the same read, run under the
  leg's exact acpx environment. One function builds that environment for both `acp_exec` and this
  read, so what was checked is what the leg gets. Two further checks follow:
  - In that environment, no credential was restored for the leg. No name in the scrub set is
    present, except the names the runner itself injects (plan round 2, codex B1). Each injected
    name must hold exactly the value the intact persisted record gives it. The injection is
    defined once: `acp.sh claude-env --policy-file <record>` (the record's hash checked first)
    prints `CLAUDE_CODE_EFFORT_LEVEL<TAB><effort>` for a record with an effort, and nothing for an
    effortless one. The claude arm builds `acp_iso` from that output, and the guard compares the
    leg's environment against the same output, so the guard can never refuse the runner's own
    effort and never admits any other value. An inherited `CLAUDE_CODE_EFFORT_LEVEL` is still
    scrubbed first. Any other scrub-set name, an injected name holding another value, or an
    injected name present for an effortless record is `binding-mismatch`.
  - The leg's user settings file (`<config dir>/settings.json`, the file the CLI loads from the
    same `CLAUDE_CONFIG_DIR`) defines no `apiKeyHelper` and has no `env` key in the scrub set. That
    is the door the environment scrub cannot close, because the CLI copies settings `env` into its
    own process. The check reads key names only; no value is printed, logged or compared.

  Any failure is `binding-mismatch`, and nothing is launched. Success is `auth_evidence: observed`.
  Project settings inside the mount are already refused by the mounted-turn checks (ROADMAP,
  2026-09-01). Managed (enterprise) settings files are not read and are named as a residual.
- The read-back's three fields prove a first-party subscription login. They do not prove that no
  other credential rides along: header-borne and settings-borne credentials are invisible to them
  (FACT 8), and so is the transcript. Those credentials are excluded by the scrub and the
  settings-names check, which is why both run before the first acpx call.
- The CLI's JSON is parsed in memory and only the three fields are kept; its stderr is discarded.
  No email, organisation, account id or token reaches runner.log, turn.tsv, result.json or an
  event. The read-back proves the route (a first-party subscription login), not which account:
  `account: main` stays operator-declared (Q7).

### 5. The runner (runphase.sh)

The bound branch passes no `--custom-profile` for claude (`case codex|claude`). In the `claude)`
arm, for a bound leg only:

- `acp_agent_cmd` is the pinned adapter from `acp.sh adapter claude --bound` (refuse if empty;
  `acp_adapter` recorded in turn.tsv), so acpx keys these sessions apart from unbound ones.
- `acp_iso=(env CLAUDE_CODE_EFFORT_LEVEL=<bound effort>)` when the effort is not null, built from
  `acp.sh claude-env` (section 4), the accessor the read-back guard also reads. It follows the
  scrub in `acp_exec`, so it reaches every adapter process the leg spawns (each direct-connect
  `set` and the queue owner) and outranks the operator's `settings.json` effort that the adapter
  re-seeds at every session load (FACT 3-6). The ACP `set effort` stays: it is what the adapter
  reports to the preflight and what acpx replays onto a replacement session. Both come from the
  same persisted record; the transcript decides whether either took effect.
- `acp_attest=transcript` (codex sets `acp_attest=rollout` where it sets `acp_iso_home`). The
  preflight and post-turn attestation blocks that are gated on `acp_iso_home` today are gated on
  `acp_attest` and dispatch on its value; for codex the condition is the same, so codex is
  unchanged. Containment is untouched: `claude-plan`, mode `plan`, `--approve-reads
  --non-interactive-permissions deny`, open network, no config-home override.

Order of a bound Claude turn (each refusal before the canary bills nothing):

1. Re-check the stamp, resolve the bound record, prepare the scrubbed environment (existing).
2. Mount; claude arm as above; login read-back (section 4).
3. `sessions ensure`, cwd and tree checks (existing `acp_session_bind`).
4. `set model <launch id>`, then `set effort <effort>` (skipped when null), each confirmed by
   acpx's exact stdout (`model set: <id>`, `config set: effort=<e> `), the `acp_confirm_mode`
   pattern. Model first because a model switch rebuilds the effort option. Failure:
   `policy-unapplied`.
5. `set-mode plan`, confirmed (existing). Mode last: plan is offered for every model (FACT 3).
6. Preflight (`acp.sh policy-check claude`): from `sessions show --format json`, the saved model
   preference `session_options.model` must equal the launch id (what acpx re-applies on every
   reconnect); the `effort` option must exist exactly when the map gives the model efforts
   (otherwise `effort-mismatch`) and read the bound effort, as must a saved
   `desired_config_options.effort`. The adapter's own `model` option value is recorded
   (`adapter_report`) but not gated, because the adapter reports an alias of its choosing
   (FACT 3). Failure: `policy-unapplied`, with the retire command.
7. Snapshot Claude's records for the mount cwd into `transcript-canary-snapshot.json`
   (`claude_transcript.py snapshot`, section 6; it refuses a mount whose project directory name
   Claude would truncate, so that case is refused before any prompt). Then run the
   canary (existing, 60 s budget) and attest the canary's window (section 6). A wrong or
   undecidable canary refuses `policy-unapplied` **before the review prompt is billed**, and its
   observation is what `binding.observed` reports.
8. Snapshot again, into `transcript-snapshot.json`. Then send the review prompt and attest the
   review window. A mismatch or an undecidable reading is refused unpublished
   (`acp_refuse policy-unapplied`, as codex's at runphase.sh:5000-5045), and no verdict is
   delivered. Otherwise `binding.observed` is the transcript's model and effort.

The two attestation snapshots are their own files (plan round 1, codex A1). The usage snapshot
(`usage-snapshot.json`, taken before the canary so the leg's spend includes it) is neither reused
nor overwritten. Each attestation snapshot calls `claude_transcript.py snapshot` directly, which
applies the directory rule and then `leg_usage.snapshot`. It does not go through the
`leg_usage_snapshot` wrapper, which deliberately never fails (runphase.sh:345-351). The runner
first removes any file at the snapshot path. It requires exit 0 and a file present afterwards,
because a failed enumeration leaves an earlier file in place (leg_usage.py:574-579), and that
earlier file would let the canary's records satisfy the review gate. A snapshot that fails at
either boundary refuses `policy-unapplied` before that prompt is sent, as codex's rollout
snapshot does.

The codex-only canary extras stay codex-only: the compaction budget and the retire-and-recreate
retry (no Claude evidence for either), and the rollout sandbox attestation (Claude has none).
Session naming needs no change: a bound record has a `policy_digest` (model, effort, adapter and
version, access digest), so the session is `agent-comms+mount+<ident>+p<digest>`; a changed pair or
adapter is a fresh session and an unchanged one stays warm.

### 6. The transcript window and the verdict

New `helpers/claude_transcript.py` (stdlib, `python3 -I`), two operations, reusing
`leg_usage.snapshot` and `leg_usage.window_records` so the window rules exist once, and owning the
one attribution rule below:

```
claude_transcript.py snapshot <records-root> <cwd> <out-file>
  exit 0  -> the snapshot written
  exit 21 -> refused: the cwd's project directory would be truncated, or the root is unreadable
claude_transcript.py observe <records-root> <cwd> <snapshot-file>
  exit 0  -> "<effort or empty>\t<model>\t<sessions>\t<records>\t<cli version or empty>"
  exit 21 -> undecidable; the reason on stderr, never record content
```

The helper joins the explicit `HELPERS` manifest in `install.sh` (line 54; plan round 2, codex
A1), so an installed copy carries it, and the install group asserts that the installed helper runs.

- Records root: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects`, from the accessor
  `leg_usage_root` already uses, so usage, attestation and the read-back read the same directory.
  The mount cwd is unique per (thread, agent) and only one turn holds a mount, so the window is
  this leg's.
- Undecidable (inherited from `window_records`): a file vanished, replaced or truncated, a partial
  last line, a malformed or non-UTF-8 record, an unreadable root.
- Attested records are every `type: assistant` record in the window, main chain **and** subagent.
  Subagents are not skipped the way codex child turn_contexts are, because criterion 4 refuses a
  window holding more than one model and FACT 2 shows mounted reviews use subagents.
- A `<synthetic>` record is exempt only while its usage proves zero tokens (plan round 1, codex
  A2). This is the usage reader's own rule (`leg_usage.is_zero_usage`, leg_usage.py:461-465),
  reused rather than restated. A synthetic record with nonzero or missing usage makes the reading
  undecidable.
- Attribution is by directory and file, never by a record's own `cwd` field, which moves when the
  reviewer changes directory (plan round 2, codex B2). The window is every `.jsonl` file, subagent
  files included, under each project directory whose name is the mount cwd's slug, or that slug
  followed by `-`. The second form is the slug of any path under the mount, including a truncated
  one, since its first 200 characters still start with the mount's slug. No record in those
  directories is filtered out.
  - INFERENCE: Claude Code keeps a session's file in the project directory it started in. The
    second form covers the case where it does not and a reviewer that changed directory writes
    elsewhere. The mount layout (`<base>/<ident>/view/tree`) puts no other agent-comms path under
    that prefix.
  - Including too much can only add records and so refuse. Including too little could hide a
    second model, so the rule includes.
  - The same enumeration feeds `snapshot` and `observe`: `leg_usage.window_records` takes the file
    list as an argument, and the usage reader keeps its own.
- A **truncated** mount directory is refused, never filtered. Claude truncates a slug longer than
  200 characters and appends a hash this code does not reproduce (`leg_usage.CLAUDE_SLUG_MAX`;
  `claude_dirs`, leg_usage.py:89-106). The truncated prefix can be shared with another mount, so
  the usage reader keeps only records whose `cwd` names the mount, which is acceptable for an
  advisory spend figure. For attestation it would drop a record written after a `cd`, possibly one
  from another model. So when any form of the mount cwd (logical or physical) has a slug over the
  limit:
  - `snapshot` exits 21, and the runner refuses `policy-unapplied` before the canary;
  - `observe` also exits 21 if it ever finds only a prefix-matched directory.

  Mount slugs on this machine measure 124 characters, so only a long `COMMS_MOUNT_BASE` or home
  path reaches this refusal, and its note names the remedy (a shorter mount base). The usage
  reader's own prefix rule is unchanged.
- Each attested record needs a `message.model`. The reading is undecidable when the window holds
  no attested record, when a `perTurnEffort` is set and differs from `effort`, or when records
  disagree on (model, effort). Disagreement is how "more than one model" and an SDK model fallback
  mid-turn surface.
- Verdict: `acp.sh policy-attest claude <effort|null> <model> --policy-file` through
  `policy_verdict`, the function codex uses. For a record with `attest_model`, the observed model is
  compared with it; for `verify model` (no effort scale), an observed effort is a mismatch (20) and
  its absence passes; for `verify model,effort`, a missing effort is undecidable (21). Codex
  records have neither key, so their verdict is unchanged. `turn_observe` records the observation
  and the CLI version from the records.

`binding.expected` keeps the caller's launch id; `binding.observed` is the transcript's id, so an
alias reads `expected sonnet`, `observed claude-sonnet-5-5`. The `recorded` row (persisted in the
record as `attest_model`) is what joins them; the docs say so.

## Interfaces that change shape

- policy-map.tsv: capability value `bound`; row kind `recorded`; pair effort `none`.
- Bound policy record (v2): optional `attest_model`; `verify model` with `effort n/a` allowed for
  claude.
- `acp.sh adapter claude --bound`; `acp.sh policy-attest` accepts `null` as the observed effort;
  `acp.sh policy-check claude`; `acp.sh capabilities` prints `recorded` rows and `doctor` prints the
  bound Claude adapter pin.
- `leg_binding.py auth-readback --adapter claude --billing subscription` (no `--home`: the
  environment carries the config directory).
- credential-env.tsv rows above; `claude_transcript.py snapshot|observe` (in the `install.sh`
  manifest); `leg_usage.window_records` takes the file list it reads; `acp.sh claude-env
  --policy-file <record>`, the one definition of what the runner injects into a bound Claude leg's
  environment, read by the arm and by the read-back guard.

## How errors propagate and what a partial failure leaves

- Resolution refusals keep the `code=<token>` contract, so `review-route plan` and `panel dispatch`
  print the same codes (`model-unservable`, `effort-mismatch`, `effort-refused`,
  `auth-login-missing`, `auth-selected-type-conflict`, `auth-route-unsupported`). The panel stays
  all-or-nothing: one refused leg refuses the dispatch.
- Run-time refusals before the first prompt: `binding-mismatch` (re-check, environment, read-back)
  or `policy-unapplied` (set, mode, preflight), with `binding.status refused`, nothing billed. The
  session may hold a partly applied preference; it is named by the policy digest, so the next
  attempt with the same pair re-sets it, and another pair uses another session.
- After the canary: `binding.status ran`. A canary refusal bills one short prompt; a review
  refusal bills the review and publishes nothing. Usage is still collected; the mount is unmounted
  as today; a runner crash is recovered by `await` from turn.tsv as today.
- Sibling interfaces that need the same change, all listed above: capability, plan, dispatch
  check, run-time re-check, `env-class` (through `classify`), resolve, runner arm, verdict,
  docs and the `comms.sh` help banner. Basis needs none; it waits for the operator's access entry
  and `kernel-claude` route.

## Invariants it must not break

- An unbound Claude turn: same adapter (built-in profile), same environment, same record bytes,
  same session name, same containment.
- Codex bound and unbound turns: same records, preflight, rollout attestation and results.
- grok and gemini stay unbindable with the same reasons and codes.
- `capability_version`, `leg_bindings`, `route_view`, `leg_metadata` stay 1, 1, 2, 1; no new class.
- `observed` is never copied from `expected`; an undecidable reading is never a pass; a review is
  never published past a failed attestation.
- The persisted record is the only expectation: the runner checks its hash before the preflight
  and before each attestation, as for codex.
- No secret, email, organisation or account id is written anywhere; no credential is restored for
  a subscription leg.
- No credential reaches a bound Claude leg except the login in its own config directory. The
  environment scrub covers names in the scrub set, and the settings-names check covers the user
  settings `env` block and `apiKeyHelper`. Both run before the first acpx call.
- agent-comms names no Claude model: every id comes from the caller; the map only says which ids
  can be attested and how they are recorded.

## What it deliberately will not do

- Widen what a Claude leg can do: no network or credential isolation, no config-home override (the
  INTERNALS residual stays and is restated for bound legs).
- Move unbound reviews to 0.88.0, or apply any Claude policy to an unbound leg.
- Add a Claude baseline, tier, ceiling, routing or "use max".
- Bind grok, gemini, Claude over the unmounted transport, or a Claude `api|local|free` route.
- Verify the account or the remote bill; read `oauthAccount` or any token.
- Add a Claude canary retry or compaction budget, or set `CLAUDE_CODE_SUBAGENT_MODEL` or
  `CLAUDE_CODE_NO_MODEL_FALLBACK` (a different-model subagent or fallback is refused, not
  prevented; revisit only with evidence that it happens).
- Fix `adapter_of` (unused) or anything else outside the change.

## Showing it work

Hermetic, in the test groups (no provider, account or network):

- Fixtures: the acpx stub learns `set model|effort` (prints acpx's lines, records the call order,
  `AX_SET_FAIL` to reject), claude `sessions show --format json` (options `model`, `effort` or none,
  `mode`, saved preferences), and writes assistant records for the canary and the review prompt to
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<slug>/` (main and subagent files), with knobs for a
  wrong model, a wrong or missing effort, two models, a subagent on another model, a synthetic
  record, a replaced or truncated file, and records written to the other config directory. It
  records `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_EFFORT_LEVEL` per call. The stub's per-profile
  environment dump learns the pinned claude adapter command. A `claude` CLI stub answers
  `auth status --json` with the three fields plus canary email, organisation and account values,
  and records the config directory and the named variables it saw. Fixtures stay a few small
  files.
- binding:
  - the capability rows with and without an entry in a temporary `AGENT_COMMS_HOME` (text and
    `--json`);
  - the flips of binding.sh:73-77, :159-161 (the brief's :160-162; codes become
    `no-access-profile` plus the resolution's code) and :312-314 (claude resolves, grok still
    refused); :278-280 stays unchanged;
  - resolve cases: `recorded` missing, `none` with an effort, a null effort with a list, an effort
    outside the list, record keys and digest;
  - map validation of the new rows, and `access_profiles.py scrub-set` listing the new table names;
  - `auth-readback` called directly. It refuses when `ANTHROPIC_CUSTOM_HEADERS` (and, separately,
    a pattern-shaped credential) is present, when the user `settings.json` `env` block names a
    variable in the scrub set, and when it defines `apiKeyHelper`. A settings `env` block holding
    only unrelated names passes.
- bindrun:
  - A codex-authored request, `panel dispatch --bindings` with one `claude-review` leg, completes.
    The order log reads set model, set effort, set-mode, canary, review. `binding.observed` is the
    stub transcript's pair, and `auth_evidence` is `observed`.
  - The same run with `CLAUDE_CONFIG_DIR` set to a temporary directory, and again unset (temporary
    HOME). Each shows that the launch, the transcript window and the read-back used that directory.
  - Credential canaries:
    - `ANTHROPIC_CUSTOM_HEADERS=Authorization: Bearer <canary>` and an mTLS passphrase canary
      planted in the dispatch environment both read `<unset>` at every acpx call of the Claude leg
      and in the `claude` stub's environment.
    - No canary string appears anywhere under `.comms` or the mount logs.
  - Refusals:
    - before any prompt: a failed set, a preflight effort mismatch, a non-subscription login, a
      missing login, and a settings `env` block naming `ANTHROPIC_CUSTOM_HEADERS`;
    - a canary mismatch, with no review prompt sent;
    - after the review: a review mismatch, two models, a subagent on another model, a synthetic
      record that carries tokens, and an unbounded window;
    - snapshot failure at each boundary: the canary snapshot fails, so no prompt is sent; the review
      snapshot fails after a passing canary, so no review prompt is sent. A stale snapshot file at
      the path does not stand in for either.
  - Passes: an effortless model bound with a null effort, a zero-usage synthetic record, and a
    record whose `cwd` moved into a subdirectory of the mount.
  - The effort injection under the guard (plan round 2, B1):
    - The successful end-to-end run binds a non-null effort, so the read-back guard sees
      `CLAUDE_CODE_EFFORT_LEVEL` present and passes.
    - With `CLAUDE_CODE_EFFORT_LEVEL=max` inherited from the dispatch environment and `low`
      bound, the leg passes, and the stub records `low` at every acpx call.
    - Calling the guard directly refuses the variable holding another value than the record's,
      and refuses the variable present for an effortless record.
  - Attribution after a `cd` (plan round 2, B2), in the exact mount directory, main chain and
    subagent file alike:
    - a matching record at the mount root followed by a matching record whose `cwd` is a
      subdirectory passes;
    - the same pair with the second record on another model is refused as two models;
    - a record of another model written to a project directory named for a subdirectory of the
      mount is refused, not missed.

    With a mount base long enough to truncate the slug, the leg is refused before the canary
    with no prompt sent, even when every record would have matched, which proves no filtering
    path exists. `observe` given only a prefix-matched directory returns 21.
- install: the installed copy of `claude_transcript.py` exists and runs (plan round 2, A1).
- route and usage: unbound `review-route plan` lines for `claude-review` unchanged; the usage
  reader unchanged.
- `tests/expected-counts.tsv` and `tests/section-counts.tsv` change in the same commit, by the
  delta against the contract at the commit under test.

Checks the implement phase runs: `bash tests/run.sh --group binding`, `--group bindrun`,
`--group route`, `--group usage`, `--group install` (the manifest), and `--group isolation`, which
reads the claude arm. Then
`comms.sh review-route capability --json` against a temporary `AGENT_COMMS_HOME` holding the
operator entry, to see the two rows.

Live, optional and not a blocker (operator, this task): if the implement phase can, it runs a
bounded probe on the pinned adapter, with its npm cache under `$TMPDIR` (never the global cache,
never deleted inline) and a scratch repo: per launch id one `set model`, `sessions show`, `set
effort` where offered, `set-mode plan` and one PONG prompt, read back from the transcript; one
pair run with and without `CLAUDE_CODE_EFFORT_LEVEL` while settings carry an effort; and the
ROADMAP containment table (workspace and `/tmp` writes, the five bash evasions, a forced
`ExitPlanMode`, reads and `git log`), ground-truthed on the filesystem, under the runner's
permission shape. At most about ten short prompts. The results go into the ROADMAP entry and the
map's versions cell, and decide which `recorded` and `pair` rows ship. Without it the cell says
`stub only` and only evidenced rows ship. The operator's full trial (one bound `claude-review`
leg on codex-authored work, `binding.expected` against `binding.observed`) stays the operator's.

## Docs in the same change

docs/AGENT_PROFILES.md (bindable agents), docs/INTERNALS.md (the binding section's "not here"
drops claude; the Claude residual restated for bound legs: open network, shared settings and
login, settings effort and model overridden or attested rather than isolated), docs/COMMANDS.md
(`review-route capability` and the plan's `capability=bound`, the capability values), the
`comms.sh` help banner and the comment above `review_route_capability`, the policy-map header
(new rows and value) and the claude capability cell, the credential-env header (the Claude rows
and the survey that found them), the INTERNALS credential-scrub and authentication-route bullets
(the settings-names check, and why the read-back alone cannot see header-borne credentials), and a
docs/ROADMAP.md entry with what was and was not exercised.

## Risks the plan carries

- 0.88.0's behaviour is read from 0.60.0's source: whether `set effort` survives a session load,
  whether `CLAUDE_CODE_EFFORT_LEVEL` outranks the adapter's flag setting and accepts `max`, the
  `sessions show` shape, and the transcript fields. Every one of them is checked per turn by the
  canary attestation, so a wrong guess refuses for the price of one PONG; it cannot pass a wrong
  pair.
- Plan-mode containment on 0.88.0 is unmeasured unless the optional probe runs (operator accepted).
- The scrub is still a list. If a later Claude CLI adds a credential variable that matches no
  pattern and has no row, it passes until the survey is repeated: this is the existing scrub
  residual, now with a named survey to repeat on each adapter pin change. Managed (enterprise)
  settings files are not read.
- Subagents on another model and SDK fallbacks refuse a paid review. If the live trial shows this
  is common, the remedy is a follow-up with evidence, not a looser verdict here.
