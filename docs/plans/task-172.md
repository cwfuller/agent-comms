# Task 172: exact per-leg binding for `panel dispatch` (capability layer Slice 7.4)

Status: plan, not yet implemented. Scope is agent-comms only. The Basis side (`Kernel.bindsLegs`,
`planLegs`, `dispatchCommand`: Slice 7.5) and reviewer resolution (7.6, #174) are separate tasks that
consume the contract defined here. Nothing here depends on the native-kernel migration (task 89).

## Goal

Today agent-comms decides a review leg's model and effort itself: `route_decision_for` classifies a
tier per thread, `acp.sh resolve` maps it through `policy-map.tsv`, and the account/billing a leg
spends under is whatever the harness's login or environment happens to hold. Basis's capability layer
(DESIGN.md "Capability layer", decision 3 and "Reviewers: bound before dispatch") needs the opposite:
the caller names, per leg, the exact **model**, **native effort** and **expected access profile**, and
agent-comms either runs exactly that or refuses the whole dispatch before any leg starts. It never
reclassifies a tier and never picks its own route. Afterwards each leg's `result.json` states what
actually ran, in a versioned contract Basis can read, so a mismatch is evidence and not an assumption.

Seven identities stay separate throughout and are never inferred from one another: harness/runtime
(Codex, Claude Code, OpenCode, Gemini CLI), model and family, native thinking effort, hosting
service, account/access route, billing class, quota pool. OpenCode or Venice never implies GLM: a
Venice-hosted model is whatever the agent's profile pins (`agents.json`, unchanged), and one OpenCode
agent per pinned model may share one access route.

## What the code does today (verified against e112fc5)

- `panel dispatch` (`helpers/comms.sh` `cmd_panel`): roster check, tree check, snapshot, routing
  decision (`route_decision_for`), plan events, then legs sent sequentially. Per-leg model/effort is
  resolved later, inside runphase, by `acp.sh resolve` from the stamped decision, env pins
  (`COMMS_ACP_<P>_MODEL/EFFORT`, `COMMS_REVIEW_MAX`) and the map.
- Applied-and-attested policy exists only where `policy-map.tsv` says so: `codex/acp-mounted`
  `eligible`, `gemini/acp-mounted` `fixed` (pins apply), custom `agents.json` profiles (fixed model
  pin, verified through ACP/OpenCode evidence, no effort). `claude` and `grok` are `unsupported`: no
  model or effort is applied or attested for them.
- Reviewer child environments are scrubbed only of identity variables (`TURN_CHILD_SCRUB`). Provider
  API keys in the driver's environment reach every leg, and `agent_profiles.py credentials()` and
  `opencode_adapter.environment()` start from the full inherited environment. Nothing today stops a
  subscription-logged-in leg from using an API key found in the environment.
- `review-route plan` is read-only and all-or-nothing; its view fields (`ACP_ROUTE_FIELDS`) feed
  `result.json` `route`. `result.json` also carries `usage`, `rate_limits` (Codex only: Grok, Claude,
  Gemini and custom profiles emit `null`, indistinguishable from "no records") and `profile`.
- Classified provider refusals exist only for Gemini (`acp.sh failure-reason`: `rate-limited`,
  `auth-failed`), recorded as the result's `reason`; no provider reports a reset time through them.
- `comms.sh version --json` has a pinned three-key shape; `acp.sh capabilities` already means the
  policy map. Neither is extended or reused for negotiation.

## Mechanism

### 1. Capability negotiation, new mode is opt-in

A new read-only verb `comms.sh review-route capability` prints one machine line
`leg-binding-capability v1 leg-bindings=1 route-view=2 leg-metadata=1` (and `--json`). Basis's
`bindsLegs` reads it. A dispatch binds legs only when invoked with `--bindings FILE`; without it every
existing caller, template and test follows exactly the current path (no new frontmatter, no new
`result.json` keys except those listed under "Compatibility"). The capability line also lists, per
registered agent, whether it is `bindable` (model+effort), `bindable-model-only` (custom profile: pin,
no effort) or `unbindable` with the reason (`claude`, `grok`: no applied/attested policy today). That
is a statement of fact, not a roadmap: making Claude or Grok bindable needs their own adapter work
and is out of scope.

### 2. One immutable access profile per kernel agent: `access.json`

New operator-owned file `~/.agent-comms/access.json` (or `$AGENT_COMMS_HOME/access.json`), keyed by
agent name, loaded with the same rules as `agents.json` (regular file, no symlink, no group/other
write, never read from the reviewed project). It is a new file, not new keys in `agents.json`,
because `agents.json` `version: 1` is read strictly and an older install would refuse an unknown key;
a separate file leaves every existing agent configuration byte-for-byte valid. Strict reader
(`helpers/access_profiles.py`, sharing `unique_object`/`fields` helpers with `agent_profiles.py`):

```json
{ "version": 1,
  "agents": {
    "codex":     { "route_id": "codex-subscription", "transport": "acp", "provider": "openai",
                   "account": "primary", "billing": "subscription", "credential": null },
    "codex-api": { "route_id": "codex-api", "transport": "acp", "provider": "openai",
                   "account": "metered", "billing": "api", "credential": "env:CODEX_METERED_KEY" },
    "glm":       { "route_id": "venice-api", "transport": "acp", "provider": "venice",
                   "account": "primary", "billing": "api", "credential": "env:VENICE_API_KEY" } } }
```

- Fields mirror Basis's route identity (`adapter` is implicit: `kernel:<agent>`): `route_id` (an
  opaque token Basis compares and never interprets), `transport` (`acp` | `cli`; `cli` is the headless
  runner; `mailbox` is never bindable, nobody drives it), `provider` (hosting service), `account`
  (a label), `billing` (`subscription|api|local|free`), `credential` (a reference `env:NAME` or
  `keychain:service`, never a value; a value-shaped string fails the reader; `null` for
  subscription/local/free). All values are bare tokens so they can be printed and embedded in JSON
  without escaping (the `ACP_ROUTE_VALUE_RE` rule).
- **Immutable per agent**: one entry per kernel agent. A second account, billing class, hosting
  service or credential is a second agent identity (`codex-api` beside `codex`), configured in
  `agents.json` (custom profiles) with its own access entry. There is no per-dispatch override of any
  field. Built-in names (`claude`, `codex`, `grok`, `gemini`) and their `-review` twins may carry an
  entry; a review twin shares its driver's provider and must carry the same entry or none (the loader
  refuses a twin whose entry differs).
- **Consistency with the profile, not a second source of truth**: for a custom profile the entry's
  `provider` must equal the profile's `api_provider` when that is set, and `credential` must equal
  the profile's single `credentials` reference (`{"env":X}` ↔ `env:X`, `{"keychain_service":S}` ↔
  `keychain:S`); a subscription/local/free entry on a profile that declares credentials is refused,
  and an `api` entry whose profile declares none is refused. Reading the pair together is the one
  validation both `agents --access` and dispatch use, so they cannot disagree.
- Several agents may share a `route_id` (one Venice account, one agent per pinned model); the loader
  refuses two agents sharing a `route_id` with any other differing access field, so a route is one
  identity regardless of how many agents reach it.
- `access_digest` = sha256 of the canonical access entry (route_id, transport, provider, account,
  billing, credential). `comms.sh agents --access <agent>` prints the entry and digest read-only (no
  credential value is ever read to print it).
- **What this does and does not establish** (stated in the result as `evidence`): the account label
  and provider are operator-declared; agent-comms checks that the *declaration matches* what the caller
  expects and that the *credential reference is the one that is passed*, and (for built-in
  subscription agents) observes the harness's own local auth mode where the provider exposes it
  without reading a secret. It does not prove which account a remote service billed. Where nothing can
  be observed the result says `auth_evidence: configured`, never `observed`.

### 3. The leg-bindings request (`--bindings FILE`)

`panel dispatch --bindings FILE [--to a,b] <review-request>`; `--to` is optional and, when given, must
equal the file's agents in order (a gate is the first, as today). File: strict JSON, unique keys,
bounded size/leg count, `schema: "leg-bindings/1"`:

```json
{ "schema": "leg-bindings/1",
  "legs": [ { "ref": "res-123", "agent": "codex", "role": "gate", "requirement": "required",
              "route_id": "codex-subscription", "model": "gpt-6-sol", "effort": "high",
              "access": { "transport": "acp", "provider": "openai", "account": "primary",
                          "billing": "subscription", "credential": null } } ] }
```

- `model` is the exact launch id the harness accepts; `effort` is the provider-native value (`high`,
  `low`, `default`...) or `null` where the model has no scale. Neither is an abstract tier: the
  existing tier/`effort` map is not consulted, and there is no classifier call (`route_decision_for` is
  skipped in this mode; no `route_decision` is stamped).
- `ref` is Basis's opaque resolution reference, echoed verbatim into the event rows, the leg request
  and `result.json` so Basis can join a leg to its resolution record. `role` (`gate|extra`) and
  `requirement` (`required|optional`) are likewise recorded and echoed, never interpreted: selecting
  which legs exist, and which are optional, is Basis's decision (#174). agent-comms dispatches exactly
  the legs listed, no more and no fewer; an unselected or skipped leg is not in the file and is never
  sent. Because selection is upstream, **any** listed leg failing validation (optional included)
  refuses the dispatch; Basis re-plans and re-submits.

### 4. All-or-nothing validation before the first durable write

A single function `leg_bind_check` (one accessor, used by both `panel dispatch` and `review-route
plan`, so a plan can never promise what dispatch refuses) runs for every leg before `request_tree_check`
/ snapshot / events / any leg file. Per leg, in order, collecting a stable refusal `code` rather than
stopping at the first:

1. roster rules unchanged (`panel_roster_check`): registered, no duplicates, author never a leg, one
   leg per **family** (the existing family semantics: `registry_family`; a custom profile's family is
   the profile's, e.g. a Venice-hosted model whose profile family is `glm` and a Codex leg are
   independent, two routes to one family never are, whatever the account);
2. `agent-unbindable` (claude/grok/mailbox/unmounted), `no-access-profile`;
3. access match, field-wise exact against the configured entry: `route-mismatch`,
   `transport-mismatch`, `provider-mismatch`, `account-mismatch`, `billing-mismatch`,
   `credential-mismatch`; plus the expected `access` object must be *complete* (a missing field is a
   refusal, not a wildcard);
4. model/effort: `acp.sh resolve --bound-model M --bound-effort E` (new candidate source `bound`,
   below): `model-unservable` (disabled, runtime lacks it, runtime version too old), `model-mismatch`
   (custom profile pins a different model), `effort-refused` / `effort-mismatch` (outside the model's
   `pair` row; non-null effort on a no-scale profile; null on a scaled model), `capability-unsupported`;
5. `credential-unavailable` for an `api` leg whose referenced variable/keychain item is not present
   (checked for presence only, never printed or logged);
6. `pin-conflict`: `COMMS_ACP_<P>_MODEL/EFFORT` set to a different value, or `COMMS_REVIEW_MAX` set,
   in the dispatching environment (an equal pin is accepted). Bound mode never lets an environment pin
   or "use max" override or be silently overridden.

Any refusal exits the dispatch with a nonzero status and a per-leg `refused <agent> <code> <detail>`
list on stderr **before** the snapshot is taken and before any event, index row or file is written, so
a refused dispatch pins nothing (the property `request_tree_check` already has).

### 5. Binding travels with the leg and is re-enforced at run time

Passing the pre-check does not end enforcement: legs run detached, later, and configuration can
change in between. Dispatch stamps, per leg, helper-written frontmatter `leg_binding: <base64
canonical JSON>` and `leg_binding_digest` (new internal `send --bound-leg`, used only by `panel`; any
hand-typed `leg_binding*` key is stripped by `send`, as `route_decision` and `agent_profile` are). The
stamp holds the expected model/effort/access, the configured `access_digest`, `ref`, `role`,
`requirement`. `runphase` runs `leg_bind_check` again, from the stamp, before it launches the provider
or sends any prompt, and also before the canary. A changed access file, profile, credential reference or
map yields a refused turn (`reason=binding-mismatch`, nothing launched, `result.json` states the
differences). This closes the per-leg drift; it cannot make an already-running sibling leg un-run, so
the honest guarantee is: *no leg starts unless every leg was valid at dispatch; a leg whose
configuration changed afterwards refuses itself rather than run something else*. Basis's `unbound`
hold handles the second case from `result.json`.

### 6. `bound` candidate source in `acp.sh resolve`

`resolve` gains `--bound-model` / `--bound-effort` (both validated bare tokens). In that mode:
precedence is `bound` only (pin and max are conflicts, above); `candidate_source=bound`, `model_source`
and `effort_source` = `bound`; routing off, decision `none`; the phase exclusion does not apply (Basis
binds every phase it dispatches). Bound pairs go through the same `policy_pair_verdict`,
`policy_model_disabled`, `policy_unservable_reason` and runtime checks as pins, and a failure is a
refusal, never the baseline substitution a routed value gets. `capability` must be `eligible` or
`fixed` (applied and attested); `unsupported` refuses. The persisted policy record gains
`route_id`, `access_digest` and `bound`; `ACP_POLICY_RECORD_VERSION` bumps to 2 and the reader accepts
exactly the version the writer wrote (current behaviour). The policy digest already keys the warm
session on model/effort/runtime, so a different bound pair is a fresh session; the access digest is
added to the session identity so two accounts never share one warm session. No model-to-tier mapping,
no new `pair`/`tier` row and no default is added: every model id enters from the caller, so nothing in
this task approves any mapping Basis has not evaluated.

### 7. Credential isolation: each leg gets only its own route's credential

In bound mode the leg's child environment is computed once by a single function (`bound_leg_env`)
that every launch path uses (runphase ACP launch, direct launch, `agent_profiles.py acpx/serve`,
OpenCode `environment`/`attest`). Rule: start from the inherited environment, remove (a) every variable
matching a provider-credential pattern (`*_API_KEY`, `*_TOKEN`, `*_AUTH_TOKEN`, `*_SECRET*`,
`*_ACCESS_KEY*`) plus an explicit table of non-pattern credential/endpoint selectors
(`helpers/credential-env.tsv`: `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_GENAI_USE_VERTEXAI`,
`CLAUDE_CODE_USE_BEDROCK/VERTEX`, `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `AWS_*`, ...), then (b) add
back **only** the bound leg's own credential: for an `api` access entry the variable its `credential`
reference names (and, for custom profiles, the profile's own `credentials` map entries), resolved
exactly as `agent_profiles.credentials()` resolves them today, minus the full-environment copy. A
`subscription`/`local`/`free` leg receives no credential variable at all, so there is no API fallback
for it to find in the environment. The pattern-plus-table is a denylist and so can miss an unknown
name: the test corpus plants canary variables under both known and pattern-matching unknown names and
asserts none reaches a stub provider; the table is the single place to extend. Residual, stated in
the docs and in `result.json` `auth_evidence`: a harness's *own* on-disk login state (for example an
API key stored in a harness's config) is not an environment variable and is not controlled by the
scrub; mounted legs already run in isolated homes that copy only login files, and the implementation
records what each copied login file exposes about its auth mode where it is machine-readable without
reading a secret, refusing a subscription-bound leg whose observed mode is API.

### 8. `review-route plan` in bound mode (read-only)

`review-route plan --bindings FILE` runs `leg_bind_check` for every leg and prints **all** legs'
verdicts, not only the first failure (Basis needs each candidate's answer to choose among them; #174
owns that choice):

`route-plan v2 ref=<r> agent=<a> status=ok|refused code=<c> route_id=<id> transport=<t> provider=<p> account=<a> billing=<b> credential=<ref|-> access_digest=<d> model=<m> effort=<e|-> model_source=bound ... capability_version=1`

with the configured (not expected) access values, so a mismatch shows both sides. Exit 0 only if every
leg would run exactly as asked; 1 if any refuses (lines still printed on stdout, unlike the legacy
verb, which stays all-or-nothing and unchanged). It reads configuration and the map only: it makes no
decision, writes no event, reads no credential value, and sends nothing.

### 9. `result.json`: route identity, binding evidence, per-provider quota metadata

New top-level keys, placed with the existing raw-embedded keys (each on its own line, no key sharing a
top-level name with the string fields above):

- `binding`: `null` for unbound legs; for bound legs `{schema:1, capability_version:1, ref, role,
  requirement, status: ran|refused, route_id, access_digest, transport, provider, account, billing,
  credential_ref (the reference or null, never a value), expected:{model,effort}, observed:{model,effort},
  auth_evidence: observed|configured, mismatches:[codes]}`. `observed` comes from the existing
  attestation (Codex rollout/ACP session evidence, Gemini settings, OpenCode assistant-record evidence)
  and is `null` per field where the harness gives none: never copied from `expected`.
- `quota` (`leg-metadata v1`): an explicit state, because `null` today cannot distinguish "unsupported"
  from "missing". `{schema:1, provider, state: observed|unsupported|unavailable|refused, source,
  limit_id, window_minutes, used_percent, resets_at, refusal: null | {kind: rate-limited|auth-failed,
  reset_at: null, reset_state: not_provided}}`. Rules: `observed` only where a provider ledger yields a
  snapshot (Codex rollout `rate_limits`; the existing `rate_limits` key is retained unchanged for
  current readers); `unsupported` for providers whose collector has no rate-limit source (Grok, Claude,
  Gemini, custom/OpenCode today; the collector's gaps are stated per provider, never papered over to
  look equivalent); `unavailable` for a supported provider with no bounded record in the window;
  `refused` only when the runner's existing classifier (`acp.sh failure-reason`, today Gemini) named a
  rate limit or auth failure, with `reset_at` always `null` unless a structured provider record
  carries one (none does today), so a reset is never manufactured. Credentials, tokens and account
  identifiers beyond the operator's own label never appear. Capacity policy, fallback and reset
  interpretation stay #174's.
- `route` keeps its shape for unbound legs; for bound legs `route-view` adds `route_id` and
  `access_digest` (route-view fields version 2, listed in the capability line).
- `capability_version` is on the plan lines, `binding` and the capability verb, so Basis can read the
  version from any of them.

### 10. Refusal and failure surfaces

Dispatch-time refusals: exit 2 (usage: malformed/unknown-key bindings file, roster violation) or 1
(binding refusal), with the per-leg list; no coordinator row. Run-time refusals: result `status=failed`
`reason=binding-mismatch`, folded into the existing `reason` vocabulary; `degrade_reason` handling is
**not** extended, so a refused bound leg is never silently dropped from the roster by compose; it
stays an unanswered leg for Basis to see as `unbound`.

## Invariants this must not break

1. No-arg and existing-flag invocations behave exactly as before (same output, files, exit codes);
   the existing suite assertions pass unchanged, and the new mode adds assertions only.
2. A refused dispatch writes nothing: no snapshot, event, index row, attempts marker or leg file.
3. Existing `agents.json`, `.comms/config`, review twins, family/provider independence, the
   one-leg-per-family rule, parent-brokered stamping, profile digest/`check-binding` semantics, session
   naming and the consult path are untouched. Operator profiles remain exact pins; nothing is added to
   `policy-map.tsv`, no model default, no tier mapping.
3a. Basis's runner authority, pauses and holds are upstream of this layer: agent-comms never starts a
   leg it was not told to, never retries a refused leg on another route, and has no fallback path
   (API or otherwise). Pausing is Basis's; agent-comms only fails closed.
4. Secrets: no credential value in argv, files, frontmatter, events, logs, result.json or plan output;
   only references and presence checks.
5. `result.json` stays machine-parseable by current readers (`json_get` one-key-per-line reads; new
   keys appended after the existing string fields) and absent keys mean "legacy leg".
6. Evidence is never invented: `observed` never copies `expected`; `quota.state` is explicit;
   no reset is manufactured; no provider is presented as equivalent to another.

## Deliberately not in scope

- Choosing models, tiers, efforts, routes, budgets, review reserves or fallbacks (Basis policy, #174);
  seeding or approving any mapping; any real model id beyond hermetic fixtures.
- Making `claude` or `grok` bindable (no applied/attested policy exists; they report `unbindable`);
  unmounted ACP and mailbox legs; a classifier in bound mode.
- Basis-side `Kernel` code, `runner.json`, quota gate or hold logic (7.5/7.6), and Basis DESIGN/ROADMAP
  edits, which land in that repository; this repository's ROADMAP and docs record the contract.
- Verifying a remote account or bill; an OS-level network or credential sandbox; kernel-level
  protection of harness-owned login files beyond the isolated homes that exist today.
- Any live provider call, release of a hold, or routing change: all tests are hermetic stubs; a live
  trial needs separate authorization.

## Tests (hermetic; stub acpx/providers; counts pinned as a delta)

New group `binding` (registered in `tests/groups.tsv`; parallel) plus additions to `panel`, `usage`,
`profiles`. `tests/expected-counts.tsv` and `tests/section-counts.tsv` change in the same commit by
`+N` computed against the contract at the commit under test.

- Exact binding: codex and gemini legs run with the bound model and effort and nothing else (stub
  records the resolved pair); a custom OpenCode/Venice-style profile binds its pinned model with a
  null effort; the same Venice route on two agents/models; a model the profile does not pin refuses.
- Mismatch matrix: wrong route id, transport, provider, account, billing, credential reference; API
  credential expected where the agent is subscription and the reverse; incomplete `access` object;
  agent with no access entry; each yields its code and nothing is written.
- No partial panel: a 3-leg dispatch whose last leg is bad leaves no snapshot, events, index rows,
  attempts marker or leg files (asserted by directory comparison), and no stub was invoked; a config
  edit between dispatch and run makes the leg refuse itself without launching the provider.
- Plan: all verdicts printed, exit 1 on any refusal, byte-identical output across repeated runs,
  no file or event written, no credential value printed; legacy plan output unchanged.
- Credential scrub: canary variables under known and pattern-matching unknown names never reach the
  stub; only the bound `api` leg sees its own reference's value, never another leg's; a subscription
  leg sees none; custom-profile launch no longer inherits the full environment in bound mode.
- Env pin / `COMMS_REVIEW_MAX` conflicts refuse; equal pin accepted; no classifier call occurs.
- Roster family semantics: two routes/accounts to one family refuse; a custom family-`glm` leg and a
  codex leg are independent; review-twin entry mismatch refused.
- Result contract: `binding`, `route`, `quota` present and exact; Codex `observed`, Grok/Claude/Gemini/
  custom `unsupported`, supported-but-empty `unavailable`, Gemini `rate-limited` fixture `refused`
  with `reset_at: null`; no secret strings anywhere in result/plan/log output (grep-asserted);
  `capability` verb output and version fields; legacy legs have `binding: null`.
- Compatibility: the whole pre-existing panel/route/profiles/usage assertions unchanged.
- Focused runs only (`bash tests/run.sh --group binding|panel|route|profiles|usage`); the full suite
  runs at integrate.

## Docs updated in the implementing commits

`docs/COMMANDS.md` (`panel dispatch --bindings`, `review-route plan --bindings`, `review-route
capability`, `agents --access`, `result.json` fields), `docs/PROTOCOL.md` (leg-bindings and stamped
frontmatter, refusal codes, run-time re-check), `docs/INTERNALS.md` (access profiles, `bound` source,
credential scrub and its residuals, quota metadata states), `docs/AGENT_PROFILES.md` (access.json and
its consistency rules with Venice/OpenCode examples), `docs/ROADMAP.md` (Slice 7.4 as built, honest
residuals), `README.md` (feature/command list), and the `comms.sh` header banner (changed together
with COMMANDS.md, per repo rule).

## Recommendations needing operator decision (not assumed approved)

1. **Separate `access.json`** rather than extending `agents.json` (recommended: no compatibility
   break). Alternative: a version bump of `agents.json`, which older installs would refuse.
2. **Env pins and `COMMS_REVIEW_MAX` refuse in bound mode** (recommended: nothing silently overrides
   or is overridden). Alternative: ignore them with a warning.
3. **Denylist-plus-table credential scrub** (recommended: keeps harnesses working) versus an
   allowlist environment, which is stricter but breaks harnesses that need proxy/certificate/node
   variables.
4. **Whole dispatch refuses when any listed leg, optional included, is invalid** (recommended: the
   brief's contract; Basis re-plans). Alternative: agent-comms drops optional legs, which would make it
   a selector and is rejected.
5. **Claude and Grok reported `unbindable`** until applied/attested policy exists for them; Basis
   must treat them as ineligible for bound review, which affects which families can gate under 7.6.
6. **Quota `refused` limited to providers with a classifier** (Gemini today); extending provider
   classification and any real reset parsing is left to #173/#174 once provider evidence exists.
